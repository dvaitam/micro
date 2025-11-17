//
//  ViewController.swift
//  iMessage
//
//  Created by Anil Manchikatla on 16/11/2025.
//

import UIKit

class ViewController: UIViewController {

    private let baseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession = URLSession.shared

    private var hasAttemptedAutoLogin = false

    private let emailTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = "Email"
        textField.keyboardType = .emailAddress
        textField.autocapitalizationType = .none
        textField.borderStyle = .roundedRect
        return textField
    }()

    private let requestOTPButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Request OTP", for: .normal)
        return button
    }()

    private let otpTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = "OTP"
        textField.keyboardType = .numberPad
        textField.borderStyle = .roundedRect
        return textField
    }()

    private let verifyOTPButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Verify OTP", for: .normal)
        return button
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        requestOTPButton.addTarget(self, action: #selector(requestOTPTapped), for: .touchUpInside)
        verifyOTPButton.addTarget(self, action: #selector(verifyOTPTapped), for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasAttemptedAutoLogin && presentedViewController == nil {
            hasAttemptedAutoLogin = true
            attemptAutoLogin()
        }
    }

    private func setupUI() {
        view.addSubview(emailTextField)
        view.addSubview(requestOTPButton)
        view.addSubview(otpTextField)
        view.addSubview(verifyOTPButton)
        view.addSubview(statusLabel)

        let guide = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            emailTextField.topAnchor.constraint(equalTo: guide.topAnchor, constant: 40),
            emailTextField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            emailTextField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            requestOTPButton.topAnchor.constraint(equalTo: emailTextField.bottomAnchor, constant: 16),
            requestOTPButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),

            otpTextField.topAnchor.constraint(equalTo: requestOTPButton.bottomAnchor, constant: 32),
            otpTextField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            otpTextField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            verifyOTPButton.topAnchor.constraint(equalTo: otpTextField.bottomAnchor, constant: 16),
            verifyOTPButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: verifyOTPButton.bottomAnchor, constant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20)
        ])
    }

    @objc private func requestOTPTapped() {
        statusLabel.text = ""
        guard let email = emailTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            statusLabel.text = "Please enter your email."
            return
        }

        requestOTP(email: email)
    }

    @objc private func verifyOTPTapped() {
        statusLabel.text = ""
        guard let email = emailTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            statusLabel.text = "Please enter your email."
            return
        }
        guard let code = otpTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            statusLabel.text = "Please enter the OTP."
            return
        }

        verifyOTP(email: email, code: code)
    }

    private func requestOTP(email: String) {
        guard let url = URL(string: "/api/request-otp", relativeTo: baseURL) else {
            statusLabel.text = "Invalid API URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["email": email]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            statusLabel.text = "Failed to encode request."
            return
        }

        statusLabel.text = "Requesting OTP..."

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.statusLabel.text = "Failed to request OTP: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.statusLabel.text = "Unexpected response."
                    return
                }

                if httpResponse.statusCode != 200 {
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let message = json["error"] as? String {
                        self.statusLabel.text = message
                    } else {
                        self.statusLabel.text = "OTP request failed with status \(httpResponse.statusCode)."
                    }
                    return
                }

                self.statusLabel.text = "OTP sent if the email exists."
            }
        }.resume()
    }

    private func verifyOTP(email: String, code: String) {
        guard let url = URL(string: "/api/verify-otp", relativeTo: baseURL) else {
            statusLabel.text = "Invalid API URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "email": email,
            "otp": code
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            statusLabel.text = "Failed to encode request."
            return
        }

        statusLabel.text = "Verifying OTP..."

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.statusLabel.text = "Failed to verify OTP: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.statusLabel.text = "Unexpected response."
                    return
                }

                if httpResponse.statusCode != 200 {
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let message = json["error"] as? String {
                        self.statusLabel.text = message
                    } else {
                        self.statusLabel.text = "OTP verification failed with status \(httpResponse.statusCode)."
                    }
                    return
                }

                guard let data = data else {
                    self.statusLabel.text = "Empty response from server."
                    return
                }

                struct VerifyResponse: Decodable {
                    let email: String
                    let accessToken: String

                    enum CodingKeys: String, CodingKey {
                        case email
                        case accessToken = "access_token"
                    }
                }

                do {
                    let response = try JSONDecoder().decode(VerifyResponse.self, from: data)
                    SessionManager.shared.updateSession(email: response.email, token: response.accessToken)
                    self.statusLabel.text = "Login successful."
                    self.userDidLogin()
                    self.showMessages()
                } catch {
                    self.statusLabel.text = "Failed to parse login response."
                }
            }
        }.resume()
    }

    private func attemptAutoLogin() {
        guard let url = URL(string: "/api/conversations", relativeTo: baseURL) else {
            return
        }

        var request = URLRequest(url: url)
        if let token = SessionManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlSession.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.presentedViewController != nil {
                    return
                }
                if let _ = error {
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    return
                }
                if httpResponse.statusCode == 200 {
                    self.showMessages()
                }
            }
        }.resume()
    }

    // Call this method when the user has successfully logged in
    // (for example, after OTP verification or any other auth flow).
    func userDidLogin() {
        DeviceManager.shared.associateDeviceWithCurrentUser { result in
            switch result {
            case .success:
                print("Device token associated with user")
            case .failure(let error):
                print("Failed to associate device token: \(error)")
            }
        }
    }

    private func showMessages() {
        let messagesVC = MessagesViewController()
        let messagesNav = UINavigationController(rootViewController: messagesVC)
        messagesNav.tabBarItem = UITabBarItem(title: "Messages", image: UIImage(systemName: "message"), tag: 1)

        let callsVC = CallsViewController()
        let callsNav = UINavigationController(rootViewController: callsVC)
        callsNav.tabBarItem = UITabBarItem(title: "Calls", image: UIImage(systemName: "phone"), tag: 0)

        let profileVC = ProfileViewController()
        let profileNav = UINavigationController(rootViewController: profileVC)
        profileNav.tabBarItem = UITabBarItem(title: "Profile", image: UIImage(systemName: "person.circle"), tag: 2)

        let tabBarController = UITabBarController()
        tabBarController.viewControllers = [callsNav, messagesNav, profileNav]
        tabBarController.selectedIndex = 1
        tabBarController.modalPresentationStyle = .fullScreen

        present(tabBarController, animated: true, completion: nil)
    }
}
