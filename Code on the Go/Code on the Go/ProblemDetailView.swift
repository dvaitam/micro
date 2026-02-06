import SwiftUI

struct ProblemDetailView: View {
    @EnvironmentObject private var apiClient: CodeforcesAPIClient
    let problem: Problem
    @State private var problemDetails: Problem?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
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
        .navigationBarHidden(true)
        .task { await loadProblem() }
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
