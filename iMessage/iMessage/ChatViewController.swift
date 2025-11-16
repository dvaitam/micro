import UIKit

struct ChatMessage: Decodable {
    let id: String
    let sender: String
    let text: String
    let sentAt: String
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let baseURL: URL
    private let urlSession: URLSession
    private let conversation: Conversation

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let messageField = UITextField()
    private let sendButton = UIButton(type: .system)
    private var inputBottomConstraint: NSLayoutConstraint?

    private var messages: [ChatMessage] = []

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
    }

    private func setupUI() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

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
        }, completion: nil)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func loadMessages() {
        guard let url = URL(string: "/api/conversations/\(conversation.id)/messages", relativeTo: baseURL) else {
            return
        }

        let request = URLRequest(url: url)
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let data = data {
                    struct Response: Decodable {
                        let messages: [ChatMessage]
                    }
                    do {
                        let decoded = try JSONDecoder().decode(Response.self, from: data)
                        self.messages = decoded.messages
                        self.tableView.reloadData()
                        if !self.messages.isEmpty {
                            let indexPath = IndexPath(row: self.messages.count - 1, section: 0)
                            self.tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
                        }
                    } catch {
                        print("Failed to decode messages: \(error)")
                    }
                } else if let error = error {
                    print("Failed to load messages: \(error)")
                }
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

        let payload: [String: Any] = ["text": text]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("Failed to encode message payload: \(error)")
            return
        }

        messageField.text = nil

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let data = data {
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                           let msgDict = json["message"] as? [String: Any],
                           let id = msgDict["id"] as? String,
                           let sender = msgDict["sender"] as? String,
                           let text = msgDict["text"] as? String,
                           let sentAt = msgDict["sent_at"] as? String {
                            let message = ChatMessage(id: id, sender: sender, text: text, sentAt: sentAt)
                            self.messages.append(message)
                            self.tableView.reloadData()
                            let indexPath = IndexPath(row: self.messages.count - 1, section: 0)
                            self.tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
                        }
                    } catch {
                        print("Failed to decode created message: \(error)")
                    }
                } else if let error = error {
                    print("Failed to send message: \(error)")
                }
            }
        }.resume()
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let message = messages[indexPath.row]
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.text = "\(message.sender): \(message.text)"
        return cell
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
