import UIKit

struct ChatMessage: Decodable {
    let id: String
    let sender: String
    let text: String
    let sentAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sender
        case text
        case sentAt = "sent_at"
    }
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    static var activeConversationID: String?

    private let baseURL: URL
    private let urlSession: URLSession
    private let conversation: Conversation

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageField = UITextField()
    private let sendButton = UIButton(type: .system)
    private var inputBottomConstraint: NSLayoutConstraint?

    private var messages: [ChatMessage] = []
    private var hasAppeared = false

    init(conversation: Conversation, baseURL: URL, urlSession: URLSession = .shared) {
        self.conversation = conversation
        self.baseURL = baseURL
        self.urlSession = urlSession
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = conversation.name.isEmpty ? conversation.participants.joined(separator: ", ") : conversation.name
        view.backgroundColor = .systemBackground
        setupUI()
        loadMessages()
        registerForKeyboardNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(handleIncomingMessage(_:)), name: .chatMessageReceived, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ChatViewController.activeConversationID = conversation.id
        NotificationCenter.default.post(name: .chatConversationRead, object: nil, userInfo: ["conversationID": conversation.id])
        ChatWebSocketManager.shared.connectIfNeeded()
        hasAppeared = true
        updateReadStateIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if ChatViewController.activeConversationID == conversation.id {
            ChatViewController.activeConversationID = nil
        }
    }

    private func setupUI() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ChatMessageCell.self, forCellReuseIdentifier: "MessageCell")
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.keyboardDismissMode = .interactive

        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.borderStyle = .roundedRect
        messageField.placeholder = "Type a message"

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("Send", for: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tableView.addGestureRecognizer(tap)

        view.addSubview(tableView)
        view.addSubview(messageField)
        view.addSubview(sendButton)

        let guide = view.safeAreaLayoutGuide

        inputBottomConstraint = messageField.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8)

        NSLayoutConstraint.activate([
            messageField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            inputBottomConstraint!,

            sendButton.leadingAnchor.constraint(equalTo: messageField.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: messageField.centerYAnchor),

            tableView.topAnchor.constraint(equalTo: guide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: messageField.topAnchor, constant: -8)
        ])
    }

    private func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboard(notification:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboard(notification:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleKeyboard(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let bottomConstraint = inputBottomConstraint else {
            return
        }

        let keyboardFrame = frameValue.cgRectValue
        let keyboardInView = view.convert(keyboardFrame, from: view.window)
        let overlap = max(0, view.bounds.height - keyboardInView.origin.y)

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? UIView.AnimationCurve.easeInOut.rawValue
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))

        bottomConstraint.constant = -8 - overlap

        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.view.layoutIfNeeded()
        }, completion: { _ in
            if overlap > 0 {
                self.scrollToBottom(animated: true)
            }
        })
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func loadMessages() {
        guard let url = URL(string: "/api/conversations/\(conversation.id)/messages", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("Failed to load messages: \(error)")
                return
            }

            guard let data = data else {
                return
            }

            struct Response: Decodable {
                let messages: [ChatMessage]
            }

            let decodedMessages: [ChatMessage]
            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                decodedMessages = decoded.messages
            } catch {
                print("Failed to decode messages: \(error)")
                return
            }

            DispatchQueue.main.async {
                self.messages = decodedMessages
                self.tableView.reloadData()
                self.scrollToBottom(animated: false)
                self.updateReadStateIfNeeded()
            }
        }.resume()
    }

    @objc private func sendTapped() {
        guard let text = messageField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }

        guard let url = URL(string: "/api/conversations/\(conversation.id)/messages", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = ["text": text]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("Failed to encode message payload: \(error)")
            return
        }

        messageField.text = nil

        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to send message: \(error)")
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("Send message failed: invalid response")
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    print("Send message failed with status: \(httpResponse.statusCode)")
                    return
                }

                guard let data = data else {
                    return
                }

                struct SendResponse: Decodable {
                    let message: ChatMessage
                }

                if let decoded = try? JSONDecoder().decode(SendResponse.self, from: data) {
                    let newMessage = decoded.message

                    if let last = self.messages.last,
                       last.sender == newMessage.sender,
                       last.text == newMessage.text,
                       last.sentAt == newMessage.sentAt {
                        // Already added via WebSocket; skip duplicate.
                        return
                    }

                    self.messages.append(newMessage)
                    let indexPath = IndexPath(row: self.messages.count - 1, section: 0)
                    self.tableView.insertRows(at: [indexPath], with: .none)
                    self.scrollToBottom(animated: true)
                }
            }
        }.resume()
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "MessageCell", for: indexPath) as? ChatMessageCell else {
            return UITableViewCell()
        }
        let message = messages[indexPath.row]
        let isOutgoing = (message.sender == SessionManager.shared.email)
        cell.configure(with: message, isOutgoing: isOutgoing)
        return cell
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    @objc private func handleIncomingMessage(_ notification: Notification) {
        guard let event = notification.userInfo?["event"] as? ChatSocketEvent else {
            return
        }
        guard event.type == "message", event.conversationID == conversation.id else {
            return
        }
        guard let sender = event.from, let text = event.text, let sentAt = event.sentAt else {
            return
        }

        if let last = messages.last,
           last.sender == sender,
           last.text == text,
           last.sentAt == sentAt {
            return
        }

        let message = ChatMessage(id: UUID().uuidString, sender: sender, text: text, sentAt: sentAt)
        messages.append(message)
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.insertRows(at: [indexPath], with: .automatic)
        scrollToBottom(animated: true)
        updateReadStateIfNeeded()
    }

    private func scrollToBottom(animated: Bool) {
        guard !messages.isEmpty else { return }
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: animated)
    }

    private func updateReadStateIfNeeded() {
        guard hasAppeared else { return }
        guard let currentEmail = SessionManager.shared.email else { return }
        guard let last = messages.last else { return }
        guard let date = ConversationReadStore.shared.parseTimestamp(last.sentAt) else { return }

        ConversationReadStore.shared.updateLastReadDate(date, for: conversation.id, email: currentEmail)
    }
}
