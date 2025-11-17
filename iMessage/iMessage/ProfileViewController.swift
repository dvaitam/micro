import UIKit

final class ProfileViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    private let baseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession = URLSession.shared

    private let emailLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let nameTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.borderStyle = .roundedRect
        textField.placeholder = "Name"
        return textField
    }()

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = UIColor.secondarySystemBackground
        return iv
    }()

    private let changePhotoButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Change Photo", for: .normal)
        return button
    }()

    private let saveButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Save", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Profile"
        view.backgroundColor = .systemBackground
        setupUI()

        changePhotoButton.addTarget(self, action: #selector(changePhotoTapped), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        if let email = SessionManager.shared.email {
            emailLabel.text = email
        } else {
            emailLabel.text = "Not signed in"
        }

        loadProfile()
        loadAvatar()
    }

    private func setupUI() {
        view.addSubview(imageView)
        view.addSubview(changePhotoButton)
        view.addSubview(emailLabel)
        view.addSubview(nameTextField)
        view.addSubview(saveButton)

        let guide = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            imageView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 96),
            imageView.heightAnchor.constraint(equalToConstant: 96),

            changePhotoButton.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            changePhotoButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),

            emailLabel.topAnchor.constraint(equalTo: changePhotoButton.bottomAnchor, constant: 24),
            emailLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            emailLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            nameTextField.topAnchor.constraint(equalTo: emailLabel.bottomAnchor, constant: 16),
            nameTextField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            nameTextField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            saveButton.topAnchor.constraint(equalTo: nameTextField.bottomAnchor, constant: 24),
            saveButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor)
        ])

        imageView.layer.cornerRadius = 48
    }

    private func loadProfile() {
        guard let url = URL(string: "/api/profile", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    print("Failed to load profile: \(error)")
                    return
                }
                guard let data = data else {
                    return
                }

                struct ProfileResponse: Decodable {
                    let email: String
                    let name: String
                }

                do {
                    let profile = try JSONDecoder().decode(ProfileResponse.self, from: data)
                    self.emailLabel.text = profile.email
                    self.nameTextField.text = profile.name
                } catch {
                    print("Failed to decode profile: \(error)")
                }
            }
        }.resume()
    }

    private func loadAvatar() {
        guard let url = URL(string: "/api/profile/photo", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    print("Failed to load avatar: \(error)")
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    return
                }
                guard httpResponse.statusCode == 200, let data = data else {
                    return
                }

                if let image = UIImage(data: data) {
                    self.imageView.image = image
                }
            }
        }.resume()
    }

    @objc private func changePhotoTapped() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        present(picker, animated: true, completion: nil)
    }

    @objc private func saveTapped() {
        guard let url = URL(string: "/api/profile", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let name = nameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload: [String: Any] = ["name": name]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("Failed to encode profile payload: \(error)")
            return
        }

        urlSession.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to save profile: \(error)")
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("Save profile failed: invalid response")
                    return
                }
                if !(200...299).contains(httpResponse.statusCode) {
                    print("Save profile failed with status: \(httpResponse.statusCode)")
                }
            }
        }.resume()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true, completion: nil)

        guard let image = info[.originalImage] as? UIImage else {
            return
        }

        imageView.image = image
        uploadAvatar(image: image)
    }

    private func uploadAvatar(image: UIImage) {
        guard let url = URL(string: "/api/profile/photo", relativeTo: baseURL) else {
            return
        }

        guard let data = image.jpegData(compressionQuality: 0.8) else {
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
                    print("Failed to upload avatar: \(error)")
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("Upload avatar failed: invalid response")
                    return
                }
                if !(200...299).contains(httpResponse.statusCode) {
                    print("Upload avatar failed with status: \(httpResponse.statusCode)")
                }
            }
        }.resume()
    }
}

