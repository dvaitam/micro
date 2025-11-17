import UIKit

struct Conversation: Decodable {
    let id: String
    let name: String
    let participants: [String]
    var lastActivityAt: String
    var unreadCount: Int = 0
    var lastMessagePreview: String?
    let isGroup: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case participants
        case lastActivityAt = "last_activity_at"
        case isGroup = "is_group"
    }
}

struct UserProfileSummary: Decodable {
    let email: String
    let name: String
    let hasAvatar: Bool

    enum CodingKeys: String, CodingKey {
        case email
        case name
        case hasAvatar = "has_avatar"
    }
}

final class MessagesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, StartChatViewControllerDelegate {

    private let baseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession = URLSession.shared

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var conversations: [Conversation] = []
    private var userProfiles: [String: UserProfileSummary] = [:]
    private var avatarCache: [String: UIImage] = [:]
    private var hasLoadedConversations = false

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

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !hasLoadedConversations {
            hasLoadedConversations = true
            loadConversations()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func loadConversations() {
        guard let url = URL(string: "/api/conversations", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("Failed to load conversations: \(error)")
                return
            }

            guard let data = data else {
                return
            }

            struct Response: Decodable {
                let conversations: [Conversation]
            }

            let decodedConversations: [Conversation]
            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                decodedConversations = decoded.conversations
            } catch {
                print("Failed to decode conversations: \(error)")
                return
            }

            DispatchQueue.main.async {
                var conversations = decodedConversations

                if let currentEmail = SessionManager.shared.email {
                    for index in conversations.indices {
                        let id = conversations[index].id
                        let storedCount = ConversationUnreadStore.shared.unreadCount(for: id, email: currentEmail)
                        conversations[index].unreadCount = storedCount
                    }
                }

                self.conversations = conversations
                self.loadLastMessagesForConversations()
                self.tableView.reloadData()
                self.loadParticipantProfiles()
            }
        }.resume()
    }

    private func loadLastMessagesForConversations() {
        for conversation in conversations {
            loadLastMessage(for: conversation)
        }
    }

    private func loadParticipantProfiles() {
        guard let currentEmail = SessionManager.shared.email else {
            return
        }

        var emailSet = Set<String>()
        for convo in conversations {
            for email in convo.participants {
                let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    continue
                }
                // We can still load profile for current user in case we want name/avatar,
                // but "Me" label is used for display.
                emailSet.insert(trimmed)
            }
        }

        if emailSet.isEmpty {
            return
        }

        let emails = Array(emailSet)

        guard var components = URLComponents(url: URL(string: "/api/users", relativeTo: baseURL)!, resolvingAgainstBaseURL: true) else {
            return
        }
        components.queryItems = [
            URLQueryItem(name: "emails", value: emails.joined(separator: ","))
        ]
        guard let url = components.url else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("Failed to load user profiles: \(error)")
                return
            }
            guard let data = data else {
                return
            }

            struct UsersResponse: Decodable {
                let users: [UserProfileSummary]
            }

            let users: [UserProfileSummary]
            do {
                let decoded = try JSONDecoder().decode(UsersResponse.self, from: data)
                users = decoded.users
            } catch {
                print("Failed to decode user profiles: \(error)")
                return
            }

            DispatchQueue.main.async {
                for profile in users {
                    self.userProfiles[profile.email] = profile
                }
                self.tableView.reloadData()
            }
        }.resume()
    }

    private func loadLastMessage(for conversation: Conversation) {
        // Fetch a limited window of recent messages so we can
        // determine the latest preview.
        guard let url = URL(string: "/api/conversations/\(conversation.id)/messages?limit=50", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("Failed to load last message: \(error)")
                return
            }

            guard let data = data else {
                return
            }

            struct Response: Decodable {
                let messages: [ChatMessage]
            }

            let messages: [ChatMessage]
            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                messages = decoded.messages
            } catch {
                print("Failed to decode last message: \(error)")
                return
            }

            guard let last = messages.last else {
                return
            }

            DispatchQueue.main.async {
                if let index = self.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    self.conversations[index].lastMessagePreview = last.text
                    self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
                }
            }
        }.resume()
    }

    @objc private func didTapNewChat() {
        let controller = StartChatViewController(baseURL: baseURL, urlSession: urlSession)
        controller.delegate = self
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true, completion: nil)
    }

    private func createConversation(with participantEmail: String) {
        guard let url = URL(string: "/api/conversations", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
                            let isGroup = (conversationDict["is_group"] as? Bool) ?? false
                            var conversation = Conversation(id: id, name: name, participants: participants, lastActivityAt: lastActivityAt, isGroup: isGroup)
                            conversation.unreadCount = 0
                            if let email = SessionManager.shared.email {
                                ConversationUnreadStore.shared.setUnreadCount(0, for: id, email: email)
                            }
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

    // MARK: StartChatViewControllerDelegate

    func startChatViewController(_ controller: StartChatViewController, didCreate conversation: Conversation) {
        var updatedConversation = conversation
        updatedConversation.unreadCount = 0
        if let email = SessionManager.shared.email {
            ConversationUnreadStore.shared.setUnreadCount(0, for: conversation.id, email: email)
        }
        conversations.insert(updatedConversation, at: 0)
        tableView.reloadData()
        showConversation(updatedConversation)
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
        cell.textLabel?.text = title(for: conversation)

        if conversation.unreadCount > 0 {
            // Show latest message preview only.
            cell.detailTextLabel?.text = conversation.lastMessagePreview
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.textLabel?.font = UIFont.systemFont(ofSize: UIFont.labelFontSize, weight: .semibold)

            // Configure unread count badge as a green pill with white text.
            let badgeLabel = UILabel()
            badgeLabel.text = "\(conversation.unreadCount)"
            badgeLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            badgeLabel.textColor = .white
            badgeLabel.textAlignment = .center
            badgeLabel.backgroundColor = .systemGreen
            badgeLabel.layer.masksToBounds = true

            let padding: CGFloat = 14
            let textSize = (badgeLabel.text ?? "").size(withAttributes: [.font: badgeLabel.font as Any])
            let height: CGFloat = 22
            let width = max(height, textSize.width + padding)
            badgeLabel.frame = CGRect(x: 0, y: 0, width: width, height: height)
            badgeLabel.layer.cornerRadius = height / 2

            cell.accessoryView = badgeLabel
        } else {
            cell.detailTextLabel?.text = conversation.lastMessagePreview
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.textLabel?.font = UIFont.systemFont(ofSize: UIFont.labelFontSize, weight: .regular)
            cell.accessoryView = nil
        }
        cell.accessoryType = .none

        // Configure avatar image for the primary participant in this conversation.
        if let email = primaryEmail(for: conversation) {
            if let image = avatarCache[email] {
                cell.imageView?.image = image
            } else if let profile = userProfiles[email], profile.hasAvatar {
                // Start loading avatar if we know one exists.
                loadAvatar(for: email)
                cell.imageView?.image = nil
            } else {
                cell.imageView?.image = nil
            }
        } else {
            cell.imageView?.image = nil
        }

        if let imageView = cell.imageView {
            imageView.layer.cornerRadius = 18
            imageView.layer.masksToBounds = true
            imageView.contentMode = .scaleAspectFill
        }

        return cell
    }

    private func title(for conversation: Conversation) -> String {
        guard let currentEmail = SessionManager.shared.email else {
            // No logged-in user; fall back to stored name or raw participants.
            if !conversation.name.isEmpty {
                return conversation.name
            }
            return conversation.participants.isEmpty ? "Chat" : conversation.participants.joined(separator: ", ")
        }

        let participants = conversation.participants

        // Self-chat: only you in the participants list.
        if participants.count == 1, let first = participants.first, first == currentEmail {
            return "Me"
        }

        // One-to-one direct chat (not a group): show the other participant.
        if !conversation.isGroup, participants.count == 2, let other = participants.first(where: { $0 != currentEmail }) {
            return displayName(for: other, currentEmail: currentEmail)
        }

        // Group chat (including 2-person groups): use the explicit name when present.
        if !conversation.name.isEmpty {
            return conversation.name
        }

        // Fallback: list participants with profile names and "Me" for self.
        let displayParticipants = participants.map { participant -> String in
            if participant == currentEmail {
                return "Me"
            }
            return displayName(for: participant, currentEmail: currentEmail)
        }
        return displayParticipants.isEmpty ? "Chat" : displayParticipants.joined(separator: ", ")
    }

    private func displayName(for email: String, currentEmail: String) -> String {
        if email == currentEmail {
            return "Me"
        }
        if let profile = userProfiles[email], !profile.name.isEmpty {
            return profile.name
        }
        return email
    }

    private func primaryEmail(for conversation: Conversation) -> String? {
        guard let currentEmail = SessionManager.shared.email else {
            return conversation.participants.first
        }

        let participants = conversation.participants

        // Self-chat: show own avatar.
        if participants.count == 1, let first = participants.first, first == currentEmail {
            return currentEmail
        }

        // One-to-one direct chat (not a group): avatar is the other participant.
        if !conversation.isGroup, participants.count == 2, let other = participants.first(where: { $0 != currentEmail }) {
            return other
        }

        // For group chats (including 2-person groups), we don't show a specific avatar here.
        return nil
    }

    private func loadAvatar(for email: String) {
        if avatarCache[email] != nil {
            return
        }

        guard var components = URLComponents(url: URL(string: "/api/users/photo", relativeTo: baseURL)!, resolvingAgainstBaseURL: true) else {
            return
        }
        components.queryItems = [URLQueryItem(name: "email", value: email)]
        guard let url = components.url else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                print("Failed to load avatar for \(email): \(error)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let data = data, let image = UIImage(data: data) else {
                return
            }

            DispatchQueue.main.async {
                self.avatarCache[email] = image
                self.tableView.reloadData()
            }
        }.resume()
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

        let currentEmail = SessionManager.shared.email

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
                if let email = currentEmail {
                    ConversationUnreadStore.shared.setUnreadCount(convo.unreadCount, for: convo.id, email: email)
                }
            }

            conversations.insert(convo, at: 0)
        } else {
            let name = event.conversationName ?? "Chat"
            let sentAt = event.sentAt ?? ""
            let participants = event.participants ?? []
            let isGroup = participants.count > 2
            var convo = Conversation(id: conversationID, name: name, participants: participants, lastActivityAt: sentAt, isGroup: isGroup)
            convo.lastMessagePreview = event.text
            if let activeID = ChatViewController.activeConversationID, activeID == conversationID {
                convo.unreadCount = 0
            } else {
                convo.unreadCount = 1
                if let email = currentEmail {
                    ConversationUnreadStore.shared.setUnreadCount(convo.unreadCount, for: convo.id, email: email)
                }
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
            if let email = SessionManager.shared.email {
                ConversationUnreadStore.shared.setUnreadCount(0, for: conversationID, email: email)
            }
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }
    }
}
