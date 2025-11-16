import UIKit

struct Conversation: Decodable {
    let id: String
    let name: String
    let participants: [String]
    let lastActivityAt: String

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

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

        loadConversations()
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
                            let conversation = Conversation(id: id, name: name, participants: participants, lastActivityAt: lastActivityAt)
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let conversation = conversations[indexPath.row]
        cell.textLabel?.text = conversation.name.isEmpty ? conversation.participants.joined(separator: ", ") : conversation.name
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let conversation = conversations[indexPath.row]
        showConversation(conversation)
    }
}
