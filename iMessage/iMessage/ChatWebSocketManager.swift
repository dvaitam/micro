import Foundation

struct ChatSocketEvent: Decodable {
    let type: String
    let conversationID: String?
    let conversationName: String?
    let from: String?
    let text: String?
    let sentAt: String?

    enum CodingKeys: String, CodingKey {
        case type
        case conversationID = "conversation_id"
        case conversationName = "conversation_name"
        case from
        case text
        case sentAt = "sent_at"
    }
}

final class ChatWebSocketManager {
    static let shared = ChatWebSocketManager()

    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnecting = false

    private init() {
        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration)
    }

    func connectIfNeeded() {
        guard webSocketTask == nil, !isConnecting else {
            return
        }

        isConnecting = true

        SessionManager.shared.refreshSession { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let info):
                self.openSocket(token: info.token)
            case .failure(let error):
                self.isConnecting = false
                print("Failed to refresh session for WebSocket: \(error)")
            }
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func openSocket(token: String) {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "ws.manchik.co.uk"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]

        guard let url = components.url else {
            isConnecting = false
            return
        }

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        isConnecting = false
        receive()
    }

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self.scheduleReconnect()

            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text: text)
                    }
                @unknown default:
                    break
                }

                self.receive()
            }
        }
    }

    private func handleMessage(text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        do {
            let event = try JSONDecoder().decode(ChatSocketEvent.self, from: data)
            switch event.type {
            case "message":
                NotificationCenter.default.post(name: .chatMessageReceived, object: nil, userInfo: ["event": event])
            case "conversation":
                NotificationCenter.default.post(name: .chatConversationUpdated, object: nil, userInfo: ["event": event])
            case "presence":
                NotificationCenter.default.post(name: .chatPresenceUpdated, object: nil, userInfo: ["event": event])
            default:
                break
            }
        } catch {
            print("Failed to decode WebSocket event: \(error)")
        }
    }

    private func scheduleReconnect() {
        webSocketTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connectIfNeeded()
        }
    }
}

