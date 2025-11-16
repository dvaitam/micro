import UIKit

struct Conversation: Decodable {
    let id: String
    let name: String
    let participants: [String]
    var lastActivityAt: String
    var unreadCount: Int = 0
    var lastMessagePreview: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case participants
        case lastActivityAt = "last_activity_at"
    }
}

final class MessagesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let baseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession = URLSession.shared

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var conversations: [Conversation] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chats"
        view.backgroundColor = .systemBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self

        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(didTapNewChat))

        SessionManager.shared.refreshSession { _ in
            ChatWebSocketManager.shared.connectIfNeeded()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleIncomingMessage(_:)), name: .chatMessageReceived, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleConversationRead(_:)), name: .chatConversationRead, object: nil)

        loadConversations()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func loadConversations() {
        guard let url = URL(string: "/api/conversations", relativeTo: baseURL) else {
            return
        }

        let request = URLRequest(url: url)
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let data = data {
                    struct Response: Decodable {
                        let conversations: [Conversation]
                    }
                    do {
                        let decoded = try JSONDecoder().decode(Response.self, from: data)
                        self.conversations = decoded.conversations
                        self.loadLastMessagesForConversations()
                        self.tableView.reloadData()
                    } catch {
                        print("Failed to decode conversations: \(error)")
                    }
                } else if let error = error {
                    print("Failed to load conversations: \(error)")
                }
            }
        }.resume()
    }

    private func loadLastMessagesForConversations() {
        for conversation in conversations {
            loadLastMessage(for: conversation)
        }
    }

    private func loadLastMessage(for conversation: Conversation) {
        guard let url = URL(string: "/api/conversations/\(conversation.id)/messages?limit=1", relativeTo: baseURL) else {
            return
        }

        let request = URLRequest(url: url)
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data else {
                    if let error = error {
                        print("Failed to load last message: \(error)")
                    }
                    return
                }

                struct Response: Decodable {
                    let messages: [ChatMessage]
                }

                do {
                    let decoded = try JSONDecoder().decode(Response.self, from: data)
                    guard let last = decoded.messages.last else {
                        return
                    }
                    if let index = self.conversations.firstIndex(where: { $0.id == conversation.id }) {
                        self.conversations[index].lastMessagePreview = last.text
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
                    }
                } catch {
                    print("Failed to decode last message: \(error)")
                }
            }
        }.resume()
    }

    @objc private func didTapNewChat() {
        let alert = UIAlertController(title: "New Chat", message: "Enter recipient email", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "email@example.com"
            textField.keyboardType = .emailAddress
            textField.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Start", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            guard let email = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                return
            }
            self.createConversation(with: email)
        }))
        present(alert, animated: true, completion: nil)
    }

    private func createConversation(with participantEmail: String) {
        guard let url = URL(string: "/api/conversations", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "name": "",
            "participants": [participantEmail]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("Failed to encode conversation payload: \(error)")
            return
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let data = data {
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                           let conversationDict = json["conversation"] as? [String: Any],
                           let id = conversationDict["id"] as? String,
                           let name = conversationDict["name"] as? String,
                           let participants = conversationDict["participants"] as? [String],
                           let lastActivityAt = conversationDict["last_activity_at"] as? String {
                            var conversation = Conversation(id: id, name: name, participants: participants, lastActivityAt: lastActivityAt)
                            conversation.unreadCount = 0
                            self.conversations.insert(conversation, at: 0)
                            self.tableView.reloadData()
                            self.showConversation(conversation)
                        }
                    } catch {
                        print("Failed to decode new conversation: \(error)")
                    }
                } else if let error = error {
                    print("Failed to create conversation: \(error)")
                }
            }
        }.resume()
    }

    private func showConversation(_ conversation: Conversation) {
        let controller = ChatViewController(conversation: conversation, baseURL: baseURL, urlSession: urlSession)
        navigationController?.pushViewController(controller, animated: true)
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return conversations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "Cell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ??
            UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let conversation = conversations[indexPath.row]
        let title = conversation.name.isEmpty ? conversation.participants.joined(separator: ", ") : conversation.name
        cell.textLabel?.text = title

        if conversation.unreadCount > 0 {
            if let preview = conversation.lastMessagePreview, !preview.isEmpty {
                cell.detailTextLabel?.text = "\(preview)   • Unread: \(conversation.unreadCount)"
            } else {
                cell.detailTextLabel?.text = "Unread: \(conversation.unreadCount)"
            }
            cell.detailTextLabel?.textColor = .systemBlue
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.detailTextLabel?.text = conversation.lastMessagePreview
            cell.accessoryType = .disclosureIndicator
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let conversation = conversations[indexPath.row]
        conversations[indexPath.row].unreadCount = 0
        tableView.reloadRows(at: [indexPath], with: .none)
        showConversation(conversation)
    }

    @objc private func handleIncomingMessage(_ notification: Notification) {
        guard let event = notification.userInfo?["event"] as? ChatSocketEvent else {
            return
        }
        guard event.type == "message", let conversationID = event.conversationID else {
            return
        }

        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            var convo = conversations.remove(at: index)
            if let sentAt = event.sentAt {
                convo.lastActivityAt = sentAt
            }

            if let text = event.text {
                convo.lastMessagePreview = text
            }

            if let activeID = ChatViewController.activeConversationID, activeID == conversationID {
                // Conversation currently open; don't increment unread.
            } else {
                convo.unreadCount += 1
            }

            conversations.insert(convo, at: 0)
        } else {
            let name = event.conversationName ?? "Chat"
            let sentAt = event.sentAt ?? ""
            var convo = Conversation(id: conversationID, name: name, participants: [], lastActivityAt: sentAt)
            convo.lastMessagePreview = event.text
            if let activeID = ChatViewController.activeConversationID, activeID == conversationID {
                convo.unreadCount = 0
            } else {
                convo.unreadCount = 1
            }
            conversations.insert(convo, at: 0)
        }

        tableView.reloadData()
    }

    @objc private func handleConversationRead(_ notification: Notification) {
        guard let conversationID = notification.userInfo?["conversationID"] as? String else {
            return
        }
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].unreadCount = 0
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }
    }
}
