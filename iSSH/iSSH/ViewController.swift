import UIKit

final class ViewController: UIViewController, UITextFieldDelegate {
    private let api = SSHAPIClient.shared
    private let webSocketSession = URLSession(configuration: .default)

    private var connections: [SSHConnectionDTO] = []
    private var liveSessions: [SSHLiveSessionDTO] = []
    private var selectedConnectionID: Int?

    private var liveTask: URLSessionWebSocketTask?
    private var commandTask: URLSessionWebSocketTask?

    // MARK: - UI

    private lazy var scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private lazy var contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var baseURLField = ViewController.makeTextField(placeholder: "https://ssh.manchik.co.uk")
    private lazy var saveBaseButton = makeActionButton(title: "Save Base URL", color: .systemBlue, action: #selector(saveBaseURLTapped))

    private lazy var currentUserLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private lazy var emailField = ViewController.makeTextField(placeholder: "Email")
    private lazy var otpField = ViewController.makeTextField(placeholder: "One-time password")
    private lazy var requestOtpButton = makeActionButton(title: "Request OTP", color: .systemBlue, action: #selector(requestOtpTapped))
    private lazy var verifyOtpButton = makeActionButton(title: "Verify OTP", color: .systemGreen, action: #selector(verifyOtpTapped))
    private lazy var signOutButton = makeActionButton(title: "Sign Out", color: .systemRed, action: #selector(signOutTapped))

    private lazy var messageLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .systemOrange
        label.numberOfLines = 0
        return label
    }()

    private lazy var nameField = ViewController.makeTextField(placeholder: "Connection name")
    private lazy var hostField = ViewController.makeTextField(placeholder: "Host")
    private lazy var portField: UITextField = {
        let field = ViewController.makeTextField(placeholder: "22")
        field.keyboardType = .numberPad
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return field
    }()
    private lazy var usernameField = ViewController.makeTextField(placeholder: "Username")
    private lazy var passwordField: UITextField = {
        let field = ViewController.makeTextField(placeholder: "Password (optional if key set)")
        field.isSecureTextEntry = true
        return field
    }()
    private lazy var keyTextView: UITextView = {
        let view = UITextView()
        view.layer.borderColor = UIColor.secondaryLabel.cgColor
        view.layer.borderWidth = 1
        view.layer.cornerRadius = 8
        view.font = .systemFont(ofSize: 14)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 140).isActive = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        return view
    }()
    private lazy var passphraseField: UITextField = {
        let field = ViewController.makeTextField(placeholder: "Passphrase (optional)")
        field.isSecureTextEntry = true
        return field
    }()
    private lazy var createButton = makeActionButton(title: "Create Connection", color: .systemBlue, action: #selector(createConnectionTapped))

    private lazy var connectionsHeaderLabel: UILabel = {
        let label = UILabel()
        label.text = "Connections"
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }()
    private lazy var refreshConnectionsButton = makeActionButton(title: "Refresh", color: .systemGray, action: #selector(refreshConnectionsTapped))

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 68
        table.isScrollEnabled = false
        return table
    }()
    private lazy var tableHeightConstraint: NSLayoutConstraint = tableView.heightAnchor.constraint(equalToConstant: 240)

    private lazy var liveHeaderLabel: UILabel = {
        let label = UILabel()
        label.text = "Live sessions"
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }()
    private lazy var refreshLiveButton = makeActionButton(title: "Refresh Live", color: .systemGray, action: #selector(refreshLiveTapped))
    private lazy var liveListStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }()

    private lazy var runConnectionField: UITextField = {
        let field = ViewController.makeTextField(placeholder: "Connection ID")
        field.keyboardType = .numberPad
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return field
    }()
    private lazy var commandField: UITextField = {
        let field = ViewController.makeTextField(placeholder: "Command")
        field.text = "uname -a"
        return field
    }()
    private lazy var keepaliveField: UITextField = {
        let field = ViewController.makeTextField(placeholder: "Keepalive seconds")
        field.keyboardType = .numberPad
        field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.text = "300"
        return field
    }()
    private lazy var runButton = makeActionButton(title: "Run", color: .systemGreen, action: #selector(runCommandTapped))
    private lazy var trackpadLabel: UILabel = {
        let label = UILabel()
        label.text = "Trackpad (sends echo \"M, dx,dy\" > /dev/ttyAMA0)"
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()
    private lazy var trackpadView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.secondarySystemBackground
        view.layer.cornerRadius = 12
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 200).isActive = true
        view.layer.borderColor = UIColor.separator.cgColor
        view.layer.borderWidth = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadPan(_:)))
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTrackpadTap(_:)))
        tap.numberOfTapsRequired = 1
        view.addGestureRecognizer(tap)
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        view.addGestureRecognizer(twoFingerTap)
        let twoFingerDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(twoFingerDoubleTap)
        twoFingerTap.require(toFail: twoFingerDoubleTap)
        return view
    }()
    private lazy var trackpadStatusLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = "Idle"
        return label
    }()

    private lazy var logView: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.layer.borderColor = UIColor.secondaryLabel.cgColor
        view.layer.borderWidth = 1
        view.layer.cornerRadius = 8
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 180).isActive = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        return view
    }()

    private lazy var newConnectionSection = makeSection(title: "New Connection", views: [])
    private lazy var connectionsSection = makeSection(title: "Connections", views: [])
    private lazy var liveSection = makeSection(title: "Live sessions", views: [])
    private lazy var runSection = makeSection(title: "Run command", views: [])

    private var isAuthenticated: Bool { api.accessToken != nil }
    private var lastPanTranslation: CGPoint?
    private var lastTrackpadSend = Date.distantPast
    private let trackpadThrottle: TimeInterval = 0.08
    private var trackpadInFlight = false
    private var pendingTrackpadDelta: (dx: Int, dy: Int)?
    private var liveRetryWorkItem: DispatchWorkItem?
    private var livePollTimer: Timer?
    private var isRunningCommand = false {
        didSet { updateRunButtonState() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bootstrapSession()
    }

    deinit {
        liveTask?.cancel()
        commandTask?.cancel()
    }

    // MARK: - Setup

    private func setupUI() {
        title = "iSSH"
        view.backgroundColor = .systemBackground
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32)
        ])

        let titleLabel = UILabel()
        titleLabel.text = "SSH Manager"
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)

        let baseRow = UIStackView(arrangedSubviews: [baseURLField, saveBaseButton])
        baseRow.axis = .horizontal
        baseRow.spacing = 10
        baseRow.distribution = .fill
        saveBaseButton.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let authRow1 = UIStackView(arrangedSubviews: [emailField, requestOtpButton])
        authRow1.axis = .horizontal
        authRow1.spacing = 8
        requestOtpButton.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let authRow2 = UIStackView(arrangedSubviews: [otpField, verifyOtpButton])
        authRow2.axis = .horizontal
        authRow2.spacing = 8
        verifyOtpButton.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let authSection = makeSection(title: "Login via email OTP", views: [
            currentUserLabel,
            authRow1,
            authRow2,
            signOutButton
        ])

        // New connection section content
        let hostPortRow = UIStackView(arrangedSubviews: [hostField, portField])
        hostPortRow.axis = .horizontal
        hostPortRow.spacing = 10
        hostPortRow.distribution = .fill
        portField.text = "22"

        newConnectionSection.addArrangedSubview(nameField)
        newConnectionSection.addArrangedSubview(hostPortRow)
        newConnectionSection.addArrangedSubview(usernameField)
        newConnectionSection.addArrangedSubview(passwordField)
        newConnectionSection.addArrangedSubview(keyTextView)
        newConnectionSection.addArrangedSubview(passphraseField)
        newConnectionSection.addArrangedSubview(createButton)

        // Connections section content
        let connectionsHeader = UIStackView(arrangedSubviews: [connectionsHeaderLabel, refreshConnectionsButton])
        connectionsHeader.axis = .horizontal
        connectionsHeader.spacing = 8
        connectionsHeader.alignment = .center
        refreshConnectionsButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        connectionsSection.addArrangedSubview(connectionsHeader)
        connectionsSection.addArrangedSubview(tableView)
        tableHeightConstraint.isActive = true

        // Live section content
        let liveHeader = UIStackView(arrangedSubviews: [liveHeaderLabel, refreshLiveButton])
        liveHeader.axis = .horizontal
        liveHeader.spacing = 8
        liveHeader.alignment = .center
        refreshLiveButton.widthAnchor.constraint(equalToConstant: 120).isActive = true
        liveSection.addArrangedSubview(liveHeader)
        liveSection.addArrangedSubview(liveListStack)

        // Run section content
        let runRow = UIStackView(arrangedSubviews: [runConnectionField, keepaliveField, runButton])
        runRow.axis = .horizontal
        runRow.spacing = 8
        runRow.alignment = .center
        runRow.distribution = .fillProportionally
        runButton.widthAnchor.constraint(equalToConstant: 90).isActive = true
        runSection.addArrangedSubview(runRow)
        runSection.addArrangedSubview(commandField)
        runSection.addArrangedSubview(logView)
        runSection.addArrangedSubview(trackpadLabel)
        runSection.addArrangedSubview(trackpadView)
        runSection.addArrangedSubview(trackpadStatusLabel)

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(baseRow)
        contentStack.addArrangedSubview(authSection)
        contentStack.addArrangedSubview(messageLabel)
        contentStack.addArrangedSubview(newConnectionSection)
        contentStack.addArrangedSubview(connectionsSection)
        contentStack.addArrangedSubview(liveSection)
        contentStack.addArrangedSubview(runSection)

        assignDelegates()
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        updateVisibility()
    }

    private func bootstrapSession() {
        baseURLField.text = api.baseURL
        emailField.text = api.email
        updateVisibility()
        if api.sessionToken != nil {
            Task { await refreshSessionAndLoad() }
        }
    }

    // MARK: - Actions

    @objc private func saveBaseURLTapped() {
        view.endEditing(true)
        api.updateBaseURL(baseURLField.text ?? "")
        showMessage("Updated base URL")
    }

    @objc private func requestOtpTapped() {
        view.endEditing(true)
        let email = emailField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !email.isEmpty else { showMessage("Email is required"); return }
        Task {
            do {
                try await api.requestOTP(email: email)
                await MainActor.run { self.showMessage("If the email exists, an OTP was sent") }
            } catch {
                await MainActor.run { self.showMessage(error.localizedDescription) }
            }
        }
    }

    @objc private func verifyOtpTapped() {
        view.endEditing(true)
        let email = emailField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let otp = otpField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !email.isEmpty, !otp.isEmpty else { showMessage("Email and OTP are required"); return }
        Task {
            do {
                let tokens = try await api.verifyOTP(email: email, otp: otp)
                await MainActor.run {
                    self.applyAuth(email: tokens.email)
                    self.showMessage("Logged in")
                }
                await loadDataAfterLogin()
            } catch {
                await MainActor.run { self.showMessage(error.localizedDescription) }
            }
        }
    }

    @objc private func signOutTapped() {
        api.clearSession()
        liveTask?.cancel()
        commandTask?.cancel()
        liveTask = nil
        liveRetryWorkItem?.cancel()
        livePollTimer?.invalidate()
        commandTask = nil
        connections = []
        liveSessions = []
        selectedConnectionID = nil
        tableView.reloadData()
        updateTableHeight()
        updateLiveList()
        logView.text = ""
        isRunningCommand = false
        updateVisibility()
        showMessage("Signed out")
    }

    @objc private func createConnectionTapped() {
        view.endEditing(true)
        guard isAuthenticated else { showMessage("Login first"); return }
        let host = hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = usernameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty, !username.isEmpty else { showMessage("Host and username are required"); return }
        let payload = SSHNewConnectionPayload(
            name: nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            host: host,
            port: Int(portField.text ?? "") ?? 22,
            username: username,
            password: passwordField.text ?? "",
            privateKey: keyTextView.text ?? "",
            passphrase: passphraseField.text ?? ""
        )
        Task {
            do {
                try await api.createConnection(payload)
                await MainActor.run {
                    self.showMessage("Connection saved")
                    self.clearNewConnectionForm()
                }
                await loadConnections()
            } catch {
                await MainActor.run { self.showMessage(error.localizedDescription) }
            }
        }
    }

    @objc private func refreshConnectionsTapped() {
        Task { await loadConnections() }
    }

    @objc private func refreshLiveTapped() {
        Task { await loadLiveSessions() }
    }

    @objc private func runCommandTapped() {
        view.endEditing(true)
        guard isAuthenticated else { showMessage("Login first"); return }
        let cmd = commandField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cmd.isEmpty else { showMessage("Command is required"); return }
        let idInput = runConnectionField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let id = Int(idInput.isEmpty ? "\(selectedConnectionID ?? 0)" : idInput), id > 0 else {
            showMessage("Select a connection")
            return
        }
        let keepalive = Int(keepaliveField.text ?? "") ?? 300
        startCommandStream(id: id, command: cmd, keepalive: keepalive)
    }

    // MARK: - Data loading

    private func refreshSessionAndLoad() async {
        do {
            let tokens = try await api.refreshSession()
            await MainActor.run {
                self.applyAuth(email: tokens.email)
                self.showMessage("Session restored")
            }
            await loadDataAfterLogin()
        } catch {
            await MainActor.run {
                self.showMessage("Session refresh failed: \(error.localizedDescription)")
                self.updateVisibility()
            }
        }
    }

    private func loadDataAfterLogin() async {
        await loadConnections()
        await loadLiveSessions()
        await MainActor.run {
            self.startLiveWebSocket()
            self.startLivePolling()
            self.updateVisibility()
        }
    }

    private func loadConnections() async {
        do {
            let list = try await api.fetchConnections()
            await MainActor.run {
                self.connections = list
                if self.selectedConnectionID == nil {
                    self.selectedConnectionID = list.first?.id
                }
                self.syncSelectedConnectionField()
                self.tableView.reloadData()
                self.updateTableHeight()
            }
        } catch {
            await MainActor.run { self.showMessage(error.localizedDescription) }
        }
    }

    private func loadLiveSessions() async {
        do {
            let live = try await api.fetchLiveSessions()
            await MainActor.run {
                self.liveSessions = live
                self.updateLiveList()
            }
        } catch {
            await MainActor.run { self.showMessage(error.localizedDescription) }
        }
    }

    // MARK: - WebSockets

    private func startLiveWebSocket() {
        liveTask?.cancel(with: .goingAway, reason: nil)
        liveRetryWorkItem?.cancel()
        guard isAuthenticated, var url = try? api.liveWebSocketURL() else { return }
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "wss"
            url = comps.url ?? url
        }
        let task = webSocketSession.webSocketTask(with: url)
        liveTask = task
        task.resume()
        listenForLiveMessages(task)
    }

    private func listenForLiveMessages(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if let payload = self.parseLiveMessage(message), let live = payload.live {
                    DispatchQueue.main.async {
                        self.liveSessions = live
                        self.updateLiveList()
                    }
                }
                if task.state == .running { self.listenForLiveMessages(task) }
            case .failure(let error):
                DispatchQueue.main.async { self.showMessage("Live stream error: \(error.localizedDescription)") }
                self.scheduleLiveRetry()
            }
        }
    }

    private func scheduleLiveRetry() {
        liveRetryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.loadLiveSessions() }
            self.startLiveWebSocket()
        }
        liveRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func startLivePolling() {
        livePollTimer?.invalidate()
        livePollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.loadLiveSessions() }
        }
    }

    private func startCommandStream(id: Int, command: String, keepalive: Int) {
        commandTask?.cancel(with: .goingAway, reason: nil)
        guard let url = try? api.commandWebSocketURL(id: id, command: command, keepalive: keepalive) else {
            showMessage("Unable to open command stream")
            return
        }
        logView.text = ""
        showMessage("Running command on #\(id)…")
        isRunningCommand = true
        let task = webSocketSession.webSocketTask(with: url)
        commandTask = task
        task.resume()
        listenForCommandOutput(task)
    }

    private func listenForCommandOutput(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let str): text = str
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text {
                    if text == "__CMD_DONE__" {
                        DispatchQueue.main.async {
                            self.isRunningCommand = false
                            self.showMessage("Command finished")
                        }
                        task.cancel(with: .normalClosure, reason: nil)
                        return
                    }
                    DispatchQueue.main.async { self.appendOutput(text) }
                }
                if task.state == .running { self.listenForCommandOutput(task) }
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isRunningCommand = false
                    self.showMessage("Stream error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - UI updates

    private func applyAuth(email: String) {
        currentUserLabel.text = "Signed in as \(email)"
        emailField.text = email
        updateVisibility()
    }

    private func updateVisibility() {
        let authed = isAuthenticated
        otpField.isHidden = authed
        verifyOtpButton.isHidden = authed
        requestOtpButton.isHidden = authed
        signOutButton.isHidden = !authed
        newConnectionSection.isHidden = !authed
        connectionsSection.isHidden = !authed
        liveSection.isHidden = !authed
        runSection.isHidden = !authed
        currentUserLabel.text = authed ? "Signed in as \(api.email ?? "")" : "Not signed in"
        updateRunButtonState()
    }

    private func showMessage(_ text: String) {
        messageLabel.text = text
    }

    private func clearNewConnectionForm() {
        nameField.text = ""
        hostField.text = ""
        portField.text = "22"
        usernameField.text = ""
        passwordField.text = ""
        keyTextView.text = ""
        passphraseField.text = ""
    }

    private func syncSelectedConnectionField() {
        if let id = selectedConnectionID {
            runConnectionField.text = "\(id)"
        }
    }

    private func appendOutput(_ text: String) {
        let existing = logView.text ?? ""
        logView.text = existing.isEmpty ? text : existing + "\n" + text
        if !logView.text.isEmpty {
            let idx = max(0, logView.text.count - 1)
            logView.scrollRangeToVisible(NSRange(location: idx, length: 1))
        }
    }

    private func updateRunButtonState() {
        runButton.isEnabled = !isRunningCommand
        if isRunningCommand {
            runButton.setTitle("Running…", for: .normal)
            runButton.alpha = 0.6
        } else {
            runButton.setTitle("Run", for: .normal)
            runButton.alpha = 1.0
        }
    }

    private func trackpadConnectionID() -> Int? {
        let idText = runConnectionField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = idText, !text.isEmpty, let id = Int(text) {
            return id
        }
        if let selectedConnectionID {
            return selectedConnectionID
        }
        return nil
    }

    private func keepaliveSeconds() -> Int {
        Int(keepaliveField.text ?? "") ?? 300
    }

    private func sendTrackpadMove(dx: Int, dy: Int) async {
        guard dx != 0 || dy != 0 else { return }
        guard let connID = trackpadConnectionID() else {
            await MainActor.run { self.showMessage("Select a connection before using the trackpad") }
            return
        }
        let cmd = "echo \"M, \(dx),\(dy)\" > /dev/ttyAMA0"
        if trackpadInFlight {
            pendingTrackpadDelta = (dx, dy)
            return
        }
        trackpadInFlight = true
        pendingTrackpadDelta = nil
        await MainActor.run { self.trackpadStatusLabel.text = "Sending (\(dx), \(dy))…" }
        do {
            _ = try await api.runCommand(connectionID: connID, command: cmd, timeoutSeconds: 3, keepaliveSeconds: keepaliveSeconds())
            await MainActor.run {
                self.trackpadStatusLabel.text = "Sent (\(dx), \(dy)) at \(Date().formatted(date: .omitted, time: .standard))"
            }
        } catch {
            await MainActor.run {
                self.trackpadStatusLabel.text = "Failed: \(error.localizedDescription)"
                self.showMessage("Trackpad send failed: \(error.localizedDescription)")
            }
        }
        trackpadInFlight = false
        if let next = pendingTrackpadDelta {
            pendingTrackpadDelta = nil
            Task { await self.sendTrackpadMove(dx: next.dx, dy: next.dy) }
        }
    }

    private func sendClick(type: ClickType) async {
        guard let connID = trackpadConnectionID() else {
            await MainActor.run { self.showMessage("Select a connection before clicking") }
            return
        }
        let cmd = "echo \"C, \(type.rawValue)\" > /dev/ttyAMA0"
        await MainActor.run { self.trackpadStatusLabel.text = "Sending click \(type.rawValue)…" }
        do {
            _ = try await api.runCommand(connectionID: connID, command: cmd, timeoutSeconds: 3, keepaliveSeconds: keepaliveSeconds())
            await MainActor.run { self.trackpadStatusLabel.text = "Click \(type.rawValue) sent" }
        } catch {
            await MainActor.run {
                self.trackpadStatusLabel.text = "Click failed: \(error.localizedDescription)"
                self.showMessage("Trackpad send failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateTableHeight() {
        let rows = max(1, min(connections.count, 8))
        tableHeightConstraint.constant = CGFloat(rows) * tableView.rowHeight
    }

    private func updateLiveList() {
        liveListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if liveSessions.isEmpty {
            let label = UILabel()
            label.text = "No live sessions"
            label.textColor = .secondaryLabel
            label.font = .systemFont(ofSize: 14)
            liveListStack.addArrangedSubview(label)
            return
        }
        for entry in liveSessions {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center

            let title = UILabel()
            title.text = "#\(entry.id)"
            title.font = .systemFont(ofSize: 15, weight: .medium)

            let detail = UILabel()
            detail.text = "expires \(entry.expiresAt)"
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabel

            let textStack = UIStackView(arrangedSubviews: [title, detail])
            textStack.axis = .vertical
            textStack.spacing = 2

            let disconnect = UIButton(type: .system)
            disconnect.setTitle("Disconnect", for: .normal)
            disconnect.setTitleColor(.systemRed, for: .normal)
            disconnect.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            disconnect.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                Task {
                    do {
                        try await self.api.disconnectLive(id: entry.id)
                        await self.loadLiveSessions()
                    } catch {
                        await MainActor.run { self.showMessage(error.localizedDescription) }
                    }
                }
            }, for: .touchUpInside)

            row.addArrangedSubview(textStack)
            row.addArrangedSubview(disconnect)
            liveListStack.addArrangedSubview(row)
        }
    }

    private func parseLiveMessage(_ message: URLSessionWebSocketTask.Message) -> LiveStreamPayload? {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let d):
            data = d
        @unknown default:
            data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(LiveStreamPayload.self, from: data)
    }

    // MARK: - Helpers

    private func makeActionButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = color.withAlphaComponent(0.14)
        button.setTitleColor(color, for: .normal)
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private static func makeTextField(placeholder: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeSection(title: String, views: [UIView]) -> UIStackView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layer.borderColor = UIColor.separator.cgColor
        stack.layer.borderWidth = 1
        stack.layer.cornerRadius = 10
        views.forEach { stack.addArrangedSubview($0) }
        return stack
    }
}

// MARK: - Keyboard helpers

extension ViewController {
    func assignDelegates() {
        [
            baseURLField,
            emailField,
            otpField,
            nameField,
            hostField,
            portField,
            usernameField,
            passwordField,
            passphraseField,
            runConnectionField,
            commandField,
            keepaliveField
        ].forEach { $0.delegate = self }
    }

    @objc func dismissKeyboard() {
        view.endEditing(true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Trackpad click types

private enum ClickType: Int {
    case single = 1
    case double = 2
}

// MARK: - Trackpad gestures

extension ViewController {
    @objc private func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: trackpadView)
        switch gesture.state {
        case .began:
            lastPanTranslation = translation
            lastTrackpadSend = Date.distantPast
        case .changed:
            guard let last = lastPanTranslation else { lastPanTranslation = translation; return }
            let dxRaw = translation.x - last.x
            let dyRaw = translation.y - last.y
            lastPanTranslation = translation
            let dx = Int(round(dxRaw)) * 10
            let dy = Int(round(dyRaw)) * 10
            guard dx != 0 || dy != 0 else { return }
            let now = Date()
            guard now.timeIntervalSince(lastTrackpadSend) >= trackpadThrottle else { return }
            lastTrackpadSend = now
            Task { await self.sendTrackpadMove(dx: dx, dy: dy) }
        default:
            lastPanTranslation = nil
        }
    }

    @objc private func handleTrackpadTap(_ gesture: UITapGestureRecognizer) {
        // Single tap: send a small move to wake / click if the remote script maps it.
        Task { await self.sendTrackpadMove(dx: 0, dy: 0) }
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        Task { await self.sendClick(type: .single) }
    }

    @objc private func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
        Task { await self.sendClick(type: .double) }
    }
}

// MARK: - Table view

extension ViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        connections.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "ConnCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let conn = connections[indexPath.row]
        cell.textLabel?.text = conn.name.isEmpty ? conn.host : conn.name
        let cred = conn.hasPrivateKey ? "Key" : (conn.hasPassword ? "Password" : "No creds")
        cell.detailTextLabel?.text = "\(conn.username)@\(conn.host):\(conn.port) • \(cred)"
        cell.accessoryType = (conn.id == selectedConnectionID) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let conn = connections[indexPath.row]
        selectedConnectionID = conn.id
        syncSelectedConnectionField()
        tableView.reloadData()
    }
}

private struct LiveStreamPayload: Decodable {
    let type: String?
    let live: [SSHLiveSessionDTO]?
}
