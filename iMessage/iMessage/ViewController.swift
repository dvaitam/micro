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
        guard let url = URL(string: "/request-otp", relativeTo: baseURL) else {
            statusLabel.text = "Invalid API URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: allowed) ?? email
        request.httpBody = "email=\(encodedEmail)".data(using: .utf8)

        statusLabel.text = "Requesting OTP..."

        urlSession.dataTask(with: request) { [weak self] _, response, error in
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

                if !(200...399).contains(httpResponse.statusCode) {
                    self.statusLabel.text = "OTP request failed with status \(httpResponse.statusCode)."
                    return
                }

                let finalURL = httpResponse.url
                if let query = finalURL?.query, query.contains("error=") {
                    self.statusLabel.text = "Unable to send OTP. Please try again."
                    return
                }

                self.statusLabel.text = "OTP sent if the email exists."
            }
        }.resume()
    }

    private func verifyOTP(email: String, code: String) {
        guard let url = URL(string: "/verify-otp", relativeTo: baseURL) else {
            statusLabel.text = "Invalid API URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: allowed) ?? email
        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: allowed) ?? code
        request.httpBody = "email=\(encodedEmail)&otp=\(encodedCode)".data(using: .utf8)

        statusLabel.text = "Verifying OTP..."

        urlSession.dataTask(with: request) { [weak self] _, response, error in
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

                if !(200...399).contains(httpResponse.statusCode) {
                    self.statusLabel.text = "OTP verification failed with status \(httpResponse.statusCode)."
                    return
                }

                let finalURL = httpResponse.url
                if let query = finalURL?.query, query.contains("error=") {
                    self.statusLabel.text = "Invalid OTP. Please try again."
                    return
                }

                // Treat any successful response without error as a successful login.
                self.statusLabel.text = "Login successful."
                self.userDidLogin()
                self.showMessages()
            }
        }.resume()
    }

    private func attemptAutoLogin() {
        guard let url = URL(string: "/api/conversations", relativeTo: baseURL) else {
            return
        }

        let request = URLRequest(url: url)
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
        let nav = UINavigationController(rootViewController: messagesVC)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true, completion: nil)
    }
}
