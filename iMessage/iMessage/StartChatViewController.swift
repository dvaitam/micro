import UIKit

struct ChatUserSummary: Decodable {
    let email: String
    let name: String
    let hasAvatar: Bool

    enum CodingKeys: String, CodingKey {
        case email
        case name
        case hasAvatar = "has_avatar"
    }
}

protocol StartChatViewControllerDelegate: AnyObject {
    func startChatViewController(_ controller: StartChatViewController, didCreate conversation: Conversation)
}

final class StartChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    weak var delegate: StartChatViewControllerDelegate?

    private let baseURL: URL
    private let urlSession: URLSession

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchBar = UISearchBar()
    private let nameTextField = UITextField()
    private let imageView = UIImageView()
    private let changePhotoButton = UIButton(type: .system)
    private let createButton = UIButton(type: .system)

    private var allUsers: [ChatUserSummary] = []
    private var filteredUsers: [ChatUserSummary] = []
    private var avatarCache: [String: UIImage] = [:]
    private var selectedEmails = Set<String>()

    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Chat"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        setupUI()
        loadUsers()
    }

    private func setupUI() {
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.placeholder = "Search by name or email"
        searchBar.delegate = self

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self

        nameTextField.translatesAutoresizingMaskIntoConstraints = false
        nameTextField.borderStyle = .roundedRect
        nameTextField.placeholder = "Group name (optional for 1:1)"

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground

        changePhotoButton.translatesAutoresizingMaskIntoConstraints = false
        changePhotoButton.setTitle("Group Photo", for: .normal)
        changePhotoButton.addTarget(self, action: #selector(changePhotoTapped), for: .touchUpInside)

        createButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.setTitle("Create", for: .normal)
        createButton.setTitleColor(.white, for: .normal)
        createButton.backgroundColor = .systemBlue
        createButton.layer.cornerRadius = 8
        createButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        createButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)

        view.addSubview(searchBar)
        view.addSubview(tableView)
        view.addSubview(nameTextField)
        view.addSubview(imageView)
        view.addSubview(changePhotoButton)
        view.addSubview(createButton)

        let guide = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: guide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            tableView.heightAnchor.constraint(equalTo: guide.heightAnchor, multiplier: 0.5),

            imageView.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            imageView.widthAnchor.constraint(equalToConstant: 64),
            imageView.heightAnchor.constraint(equalToConstant: 64),

            changePhotoButton.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            changePhotoButton.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),

            nameTextField.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            nameTextField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            nameTextField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            createButton.topAnchor.constraint(equalTo: nameTextField.bottomAnchor, constant: 16),
            createButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor)
        ])

        imageView.layer.cornerRadius = 32
    }

    private func loadUsers() {
        guard let url = URL(string: "/api/users/all", relativeTo: baseURL) else {
            return
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        if let q = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            components?.queryItems = [URLQueryItem(name: "q", value: q)]
        }

        guard let finalURL = components?.url else {
            return
        }

        var request = URLRequest(url: finalURL)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    print("Failed to load users: \(error)")
                    return
                }
                guard let data = data else {
                    return
                }

                struct UsersResponse: Decodable {
                    let users: [ChatUserSummary]
                }

                do {
                    let decoded = try JSONDecoder().decode(UsersResponse.self, from: data)
                    self.allUsers = decoded.users
                    self.applyFilter()
                } catch {
                    print("Failed to decode users: \(error)")
                }
            }
        }.resume()
    }

    private func applyFilter() {
        let q = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if q.isEmpty {
            filteredUsers = allUsers
        } else {
            filteredUsers = allUsers.filter { user in
                let name = user.name.lowercased()
                let email = user.email.lowercased()
                return name.contains(q) || email.contains(q)
            }
        }
        tableView.reloadData()
    }

    // MARK: Actions

    @objc private func cancelTapped() {
        dismiss(animated: true, completion: nil)
    }

    @objc private func changePhotoTapped() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        present(picker, animated: true, completion: nil)
    }

    @objc private func createTapped() {
        let participants = Array(selectedEmails)
        if participants.isEmpty {
            let alert = UIAlertController(title: "Select Users", message: "Please select at least one user.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            present(alert, animated: true, completion: nil)
            return
        }

        guard let url = URL(string: "/api/conversations", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let name = nameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload: [String: Any] = [
            "name": name,
            "participants": participants
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

                if let error = error {
                    print("Failed to create conversation: \(error)")
                    return
                }

                guard let data = data else {
                    print("Create conversation: empty response")
                    return
                }

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

                        if let image = self.imageView.image {
                            self.uploadGroupPhoto(image: image, conversationID: id) {
                                self.delegate?.startChatViewController(self, didCreate: conversation)
                                self.dismiss(animated: true, completion: nil)
                            }
                        } else {
                            self.delegate?.startChatViewController(self, didCreate: conversation)
                            self.dismiss(animated: true, completion: nil)
                        }
                    }
                } catch {
                    print("Failed to decode new conversation: \(error)")
                }
            }
        }.resume()
    }

    private func uploadGroupPhoto(image: UIImage, conversationID: String, completion: @escaping () -> Void) {
        guard let url = URL(string: "/api/conversations/\(conversationID)/photo", relativeTo: baseURL) else {
            completion()
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            completion()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlSession.uploadTask(with: request, from: data) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to upload group photo: \(error)")
                } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    print("Upload group photo failed with status: \(http.statusCode)")
                }
                completion()
            }
        }.resume()
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredUsers.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "UserCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let user = filteredUsers[indexPath.row]
        cell.textLabel?.text = user.name.isEmpty ? user.email : user.name
        cell.detailTextLabel?.text = user.email

        if let image = avatarCache[user.email] {
            cell.imageView?.image = image
        } else if user.hasAvatar {
            loadAvatar(for: user.email)
            cell.imageView?.image = nil
        } else {
            cell.imageView?.image = nil
        }

        if let imageView = cell.imageView {
            imageView.layer.cornerRadius = 18
            imageView.layer.masksToBounds = true
            imageView.contentMode = .scaleAspectFill
        }

        cell.accessoryType = selectedEmails.contains(user.email) ? .checkmark : .none
        return cell
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let user = filteredUsers[indexPath.row]
        if selectedEmails.contains(user.email) {
            selectedEmails.remove(user.email)
        } else {
            selectedEmails.insert(user.email)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    // MARK: Search

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // MARK: Image picker

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true, completion: nil)
        if let image = info[.originalImage] as? UIImage {
            imageView.image = image
        }
    }

    // MARK: Avatar loading

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
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let image = UIImage(data: data) else {
                return
            }

            DispatchQueue.main.async {
                self.avatarCache[email] = image
                self.tableView.reloadData()
            }
        }.resume()
    }
}

