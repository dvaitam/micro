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
    private let logPrefix = "[ChatWebSocket]"

    private init() {
        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration)
    }

    func connectIfNeeded() {
        guard webSocketTask == nil, !isConnecting else {
            print("\(logPrefix) connectIfNeeded skipped (existing task: \(webSocketTask != nil), isConnecting: \(isConnecting))")
            return
        }

        print("\(logPrefix) connectIfNeeded starting session refresh")
        isConnecting = true

        SessionManager.shared.refreshSession { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let info):
                print("\(self.logPrefix) session refreshed for \(info.email), opening socket")
                self.openSocket(token: info.token)
            case .failure(let error):
                self.isConnecting = false
                print("\(self.logPrefix) failed to refresh session for WebSocket: \(error)")
            }
        }
    }

    func disconnect() {
        print("\(logPrefix) disconnect requested")
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
            print("\(logPrefix) failed to build WebSocket URL")
            isConnecting = false
            return
        }

        print("\(logPrefix) opening WebSocket: \(url.absoluteString)")

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        print("\(logPrefix) WebSocket task resumed")
        isConnecting = false
        receive()
    }

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                print("\(self.logPrefix) receive error: \(error)")
                self.scheduleReconnect()

            case .success(let message):
                switch message {
                case .string(let text):
                    print("\(self.logPrefix) received text frame: \(text)")
                    self.handleMessage(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        print("\(self.logPrefix) received binary frame (utf8): \(text)")
                        self.handleMessage(text: text)
                    }
                @unknown default:
                    print("\(self.logPrefix) received unknown message type")
                    break
                }

                self.receive()
            }
        }
    }

    private func handleMessage(text: String) {
        guard let data = text.data(using: .utf8) else {
            print("\(logPrefix) handleMessage: unable to convert text to data")
            return
        }
        do {
            let event = try JSONDecoder().decode(ChatSocketEvent.self, from: data)
            print("\(logPrefix) decoded event type=\(event.type), conversationID=\(event.conversationID ?? "nil"), from=\(event.from ?? "nil"), sentAt=\(event.sentAt ?? "nil")")
            DispatchQueue.main.async {
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
            }
        } catch {
            print("\(logPrefix) failed to decode WebSocket event: \(error)")
        }
    }

    private func scheduleReconnect() {
        print("\(logPrefix) scheduling reconnect in 5 seconds")
        webSocketTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            print("\(self?.logPrefix ?? "[ChatWebSocket]") attempting reconnect")
            self?.connectIfNeeded()
        }
    }
}
