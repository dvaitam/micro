import SwiftUI

struct ProblemDetailView: View {
    @EnvironmentObject private var apiClient: CodeforcesAPIClient
    let problem: Problem
    @State private var problemDetails: Problem?
    @State private var loading = false
    @State private var error: String?
    @State private var selectedTab = 0
    @State private var mySubmissions: [SubmissionDetail] = []
    @State private var allSubmissions: [SubmissionDetail] = []
    @State private var loadingSubs = false
    @State private var expandedSubmissionId: Int?

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text("Statement").tag(0)
                Text("My Subs").tag(1)
                Text("All Subs").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case 0:
                statementContent
            case 1:
                mySubmissionsContent
            default:
                allSubmissionsContent
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProblem()
            await loadSubmissions()
        }
    }

    @ViewBuilder
    private var statementContent: some View {
        if let statementURL = (problemDetails ?? problem).statementURL {
            WebStatementView(url: statementURL)
        } else if let error {
            VStack {
                Spacer()
                Text(error).foregroundColor(.red)
                Spacer()
            }
        } else {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }

    private var mySubmissionsContent: some View {
        Group {
            if apiClient.accessToken == nil {
                ContentUnavailableView("Sign in to see your submissions", systemImage: "person.crop.circle")
            } else if loadingSubs {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else if mySubmissions.isEmpty {
                ContentUnavailableView("No submissions yet", systemImage: "tray")
            } else {
                submissionsList(mySubmissions)
            }
        }
    }

    private var allSubmissionsContent: some View {
        Group {
            if loadingSubs {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else if allSubmissions.isEmpty {
                ContentUnavailableView("No submissions", systemImage: "tray")
            } else {
                submissionsList(allSubmissions)
            }
        }
    }

    private func submissionsList(_ submissions: [SubmissionDetail]) -> some View {
        List {
            ForEach(submissions) { sub in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        verdictDot(sub)
                        Text("#\(sub.id)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if let lang = sub.lang, !lang.isEmpty {
                            Text(lang)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text(sub.status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let verdict = sub.verdict, !verdict.isEmpty {
                        Text(verdict)
                            .font(.caption)
                            .foregroundColor(verdict.lowercased().contains("accepted") ? .green : .red)
                    }
                    if let ts = sub.timestamp {
                        Text(ts)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if expandedSubmissionId == sub.id {
                        SubmissionExpandedDetail(detail: sub)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation {
                        expandedSubmissionId = expandedSubmissionId == sub.id ? nil : sub.id
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func verdictDot(_ sub: SubmissionDetail) -> some View {
        let color: Color = {
            if let v = sub.verdict?.lowercased() {
                if v.contains("accepted") { return .green }
                if v.contains("wrong") || v.contains("error") || v.contains("limit") { return .red }
            }
            let s = sub.status.lowercased()
            if s == "completed" || s == "done" { return .orange }
            if s == "queued" || s == "pending" || s == "running" { return .blue }
            return .gray
        }()
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private func loadProblem(force: Bool = false) async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            if force || problemDetails == nil {
                let loaded = try await apiClient.fetchProblem(contest: String(problem.contestId), index: problem.index)
                problemDetails = loaded
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func loadSubmissions() async {
        loadingSubs = true
        async let allTask: () = loadAllSubmissions()
        async let myTask: () = loadMySubmissions()
        _ = await (allTask, myTask)
        loadingSubs = false
    }

    private func loadAllSubmissions() async {
        do {
            allSubmissions = try await apiClient.fetchProblemSubmissions(contest: problem.contestId, index: problem.index)
        } catch {
            allSubmissions = []
        }
    }

    private func loadMySubmissions() async {
        guard apiClient.accessToken != nil else {
            mySubmissions = []
            return
        }
        do {
            let all = try await apiClient.fetchUserSubmissions(limit: 200)
            mySubmissions = all.filter {
                $0.contestId == problem.contestId && $0.index?.uppercased() == problem.index.uppercased()
            }
        } catch {
            mySubmissions = []
        }
    }
}

struct SubmissionExpandedDetail: View {
    let detail: SubmissionDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let code = detail.code, !code.isEmpty {
                DisclosureGroup("Code") {
                    ScrollView(.horizontal) {
                        Text(code)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .frame(maxHeight: 200)
                }
            }
            if let stdout = detail.stdout, !stdout.isEmpty {
                DisclosureGroup("Stdout") {
                    ScrollView {
                        Text(stdout)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .frame(maxHeight: 120)
                }
            }
            if let stderr = detail.stderr, !stderr.isEmpty {
                DisclosureGroup("Stderr") {
                    ScrollView {
                        Text(stderr)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(.top, 4)
    }
}

struct WrapTags: View {
    let tags: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
            }
        }
    }
}

struct LoginCard: View {
    @EnvironmentObject private var apiClient: CodeforcesAPIClient
    @Binding var email: String
    @Binding var otp: String
    @Binding var stayLoggedIn: Bool
    @State private var message: String?
    @State private var isSending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Login via email OTP")
                    .font(.headline)
                if let email = apiClient.email, !email.isEmpty {
                    Spacer()
                    Text("Signed in as \(email)")
                        .foregroundColor(.secondary)
                }
            }
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Send OTP") { Task { await sendOtp() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                if isSending { ProgressView() }
            }
            HStack(spacing: 12) {
                TextField("Code", text: $otp)
                    .keyboardType(.numberPad)
                Toggle("Stay logged in", isOn: $stayLoggedIn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Stay logged in")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
            Button("Verify & Login") { Task { await verify() } }
                .buttonStyle(.bordered)
                .disabled(otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || email.isEmpty)
            if let message {
                Text(message)
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
        }
    }

    private func sendOtp() async {
        isSending = true
        do {
            try await apiClient.requestOTP(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
            message = "OTP sent"
        } catch {
            message = error.localizedDescription
        }
        isSending = false
    }

    private func verify() async {
        do {
            let tokens = try await apiClient.verifyOTP(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: otp.trimmingCharacters(in: .whitespacesAndNewlines), stayLoggedIn: stayLoggedIn)
            message = "Logged in as \(tokens.email)"
        } catch {
            message = error.localizedDescription
        }
    }
}
