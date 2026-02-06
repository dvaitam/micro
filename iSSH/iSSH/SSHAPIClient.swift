import Foundation

struct SSHConnectionDTO: Decodable {
    let id: Int
    let name: String
    let host: String
    let port: Int
    let username: String
    let hasPassword: Bool
    let hasPrivateKey: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username
        case hasPassword = "has_password"
        case hasPrivateKey = "has_private_key"
    }
}

struct SSHLiveSessionDTO: Decodable {
    let id: Int
    let lastUsed: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case lastUsed = "last_used"
        case expiresAt = "expires_at"
    }
}

struct SSHAuthTokens {
    let email: String
    let sessionToken: String
    let accessToken: String
}

enum SSHAPIError: LocalizedError {
    case message(String)
    case invalidBaseURL
    case unauthorized
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .message(let msg): return msg
        case .invalidBaseURL: return "Invalid API base URL"
        case .unauthorized: return "Unauthorized"
        case .invalidResponse: return "Invalid server response"
        }
    }
}

struct SSHNewConnectionPayload: Encodable {
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var privateKey: String
    var passphrase: String

    private enum CodingKeys: String, CodingKey {
        case name, host, port, username, password
        case privateKey = "private_key"
        case passphrase
    }
}

final class SSHAPIClient {
    static let shared = SSHAPIClient()

    private let defaults = UserDefaults.standard
    private let legacyBaseKey = "ssh.api.base"
    private let authBaseKey = "ssh.api.authBase"
    private let sshBaseKey = "ssh.api.sshBase"
    private let sessionKey = "ssh.api.session"
    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
    private let session: URLSession = .shared

    private(set) var authBaseURL: String
    private(set) var sshBaseURL: String
    private(set) var sessionToken: String?
    private(set) var accessToken: String?
    private(set) var email: String?

    private init() {
        let legacyBase = defaults.string(forKey: legacyBaseKey)
        let storedAuth = defaults.string(forKey: authBaseKey) ?? legacyBase
        let storedSSH = defaults.string(forKey: sshBaseKey) ?? legacyBase
        authBaseURL = Self.normalizeBase(storedAuth ?? "https://ssh.manchik.co.uk")
        sshBaseURL = Self.normalizeBase(storedSSH ?? authBaseURL)
        defaults.set(authBaseURL, forKey: authBaseKey)
        defaults.set(sshBaseURL, forKey: sshBaseKey)
        defaults.set(sshBaseURL, forKey: legacyBaseKey)
        sessionToken = defaults.string(forKey: sessionKey)
    }

    var baseURL: String { sshBaseURL }

    func updateBaseURL(_ newValue: String) {
        updateBaseURLs(auth: newValue, ssh: newValue)
    }

    func updateBaseURLs(auth: String?, ssh: String?) {
        let normalizedAuth = Self.normalizeBase(Self.nonEmpty(auth) ?? authBaseURL)
        let normalizedSSH = Self.normalizeBase(Self.nonEmpty(ssh) ?? sshBaseURL)
        authBaseURL = normalizedAuth
        sshBaseURL = normalizedSSH
        defaults.set(normalizedAuth, forKey: authBaseKey)
        defaults.set(normalizedSSH, forKey: sshBaseKey)
        defaults.set(normalizedSSH, forKey: legacyBaseKey)
    }

    func clearSession() {
        sessionToken = nil
        accessToken = nil
        email = nil
        defaults.removeObject(forKey: sessionKey)
    }

    func requestOTP(email: String) async throws {
        let payload = ["email": email]
        _ = try await send(path: "/api/request-otp", method: "POST", base: authBaseURL, body: payload)
    }

    func verifyOTP(email: String, otp: String) async throws -> SSHAuthTokens {
        let payload = ["email": email, "otp": otp]
        let data = try await send(path: "/api/verify-otp", method: "POST", base: authBaseURL, body: payload)
        let resp = try decoder.decode(VerifyResponse.self, from: data)
        guard let access = resp.accessToken else { throw SSHAPIError.message("No access token returned") }
        let tokens = SSHAuthTokens(email: resp.email, sessionToken: resp.sessionToken, accessToken: access)
        apply(tokens: tokens)
        return tokens
    }

    func refreshSession(using token: String? = nil) async throws -> SSHAuthTokens {
        let bearer = token ?? sessionToken
        guard let bearer else { throw SSHAPIError.unauthorized }
        let data = try await send(path: "/api/session", method: "GET", headers: ["Authorization": "Bearer \(bearer)"], base: authBaseURL)
        let resp = try decoder.decode(SessionResponse.self, from: data)
        guard let access = resp.accessToken else { throw SSHAPIError.message("Unable to refresh access token") }
        let tokens = SSHAuthTokens(email: resp.email, sessionToken: resp.token ?? bearer, accessToken: access)
        apply(tokens: tokens)
        return tokens
    }

    func fetchConnections() async throws -> [SSHConnectionDTO] {
        let data = try await authorizedRequest(path: "/api/ssh/connections")
        let resp = try decoder.decode(ConnectionListResponse.self, from: data)
        return resp.connections
    }

    func createConnection(_ payload: SSHNewConnectionPayload) async throws {
        _ = try await authorizedRequest(path: "/api/ssh/connections", method: "POST", body: payload)
    }

    func fetchLiveSessions() async throws -> [SSHLiveSessionDTO] {
        let data = try await authorizedRequest(path: "/api/ssh/live")
        let resp = try decoder.decode(LiveListResponse.self, from: data)
        return resp.live
    }

    func fetchCommandHistory() async throws -> [String] {
        let data = try await authorizedRequest(path: "/api/ssh/commands")
        let resp = try decoder.decode(CommandHistoryResponse.self, from: data)
        return resp.commands
    }

    func disconnectLive(id: Int) async throws {
        _ = try await authorizedRequest(path: "/api/ssh/live/\(id)", method: "DELETE")
    }

    func runCommand(connectionID: Int, command: String, timeoutSeconds: Int = 5, keepaliveSeconds: Int = 300) async throws -> RunCommandResponse {
        let payload = RunCommandPayload(connectionID: connectionID, command: command, timeoutSeconds: timeoutSeconds, keepaliveSeconds: keepaliveSeconds)
        let data = try await authorizedRequest(path: "/api/ssh/run", method: "POST", body: payload)
        return try decoder.decode(RunCommandResponse.self, from: data)
    }

    func liveWebSocketURL() throws -> URL {
        guard let token = accessToken else { throw SSHAPIError.unauthorized }
        return try websocketURL(path: "/api/ssh/live/ws", query: ["access_token": token], base: sshBaseURL)
    }

    func commandWebSocketURL(id: Int, command: String, keepalive: Int, timeout: Int = 60) throws -> URL {
        guard let token = accessToken else { throw SSHAPIError.unauthorized }
        return try websocketURL(
            path: "/api/ssh/stream",
            query: [
                "id": "\(id)",
                "cmd": command,
                "keepalive_seconds": "\(keepalive)",
                "timeout_seconds": "\(timeout)",
                "access_token": token
            ],
            base: sshBaseURL
        )
    }

    func controlWebSocketURL(id: Int, keepalive: Int) throws -> URL {
        guard let token = accessToken else { throw SSHAPIError.unauthorized }
        return try websocketURL(
            path: "/api/ssh/control/ws",
            query: [
                "id": "\(id)",
                "keepalive_seconds": "\(keepalive)",
                "access_token": token
            ],
            base: sshBaseURL
        )
    }

    // MARK: - Helpers

    private func apply(tokens: SSHAuthTokens) {
        email = tokens.email
        accessToken = tokens.accessToken
        sessionToken = tokens.sessionToken
        defaults.set(tokens.sessionToken, forKey: sessionKey)
    }

    private func authorizedRequest(path: String, method: String = "GET", body: Encodable? = nil) async throws -> Data {
        guard let accessToken else { throw SSHAPIError.unauthorized }
        var headers = ["Authorization": "Bearer \(accessToken)"]
        headers["Content-Type"] = "application/json"
        if body == nil {
            return try await send(path: path, method: method, headers: headers)
        }
        return try await send(path: path, method: method, headers: headers, body: body)
    }

    private func send(path: String, method: String, headers: [String: String]? = nil, base: String? = nil) async throws -> Data {
        try await send(path: path, method: method, headers: headers, base: base, body: nil as Encodable?)
    }

    private func send(path: String, method: String, headers: [String: String]? = nil, base: String? = nil, body: Encodable?) async throws -> Data {
        let url = try buildURL(for: path, base: base ?? sshBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = method
        var combinedHeaders = headers ?? [:]
        combinedHeaders["Accept"] = "application/json"
        for (k, v) in combinedHeaders { request.setValue(v, forHTTPHeaderField: k) }

        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SSHAPIError.invalidResponse }
        if http.statusCode == 401 { throw SSHAPIError.unauthorized }
        if !(200...299).contains(http.statusCode) {
            if let message = try? decoder.decode(ErrorResponse.self, from: data).error {
                throw SSHAPIError.message(message)
            }
            throw SSHAPIError.message("Request failed (\(http.statusCode))")
        }
        return data
    }

    private func buildURL(for path: String, base: String) throws -> URL {
        var trimmedBase = Self.normalizeBase(base)
        while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
        guard var base = URL(string: trimmedBase) else { throw SSHAPIError.invalidBaseURL }
        var trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedPath.hasPrefix("/") { trimmedPath.removeFirst() }
        return base.appendingPathComponent(trimmedPath)
    }

    private func websocketURL(path: String, query: [String: String], base: String) throws -> URL {
        let httpURL = try buildURL(for: path, base: base)
        var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)
        components?.scheme = (httpURL.scheme == "https") ? "wss" : "ws"
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw SSHAPIError.invalidBaseURL }
        return url
    }

    private static func normalizeBase(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "https://ssh.manchik.co.uk" }
        if !value.contains("://") {
            value = "https://" + value
        }
        if value.lowercased().hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        } else if value.lowercased().hasPrefix("ws://") {
            value = "https://" + value.dropFirst("ws://".count)
        } else if value.lowercased().hasPrefix("wss://") {
            value = "https://" + value.dropFirst("wss://".count)
        }
        return value
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let str = string?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else { return nil }
        return str
    }
}

private struct VerifyResponse: Decodable {
    let email: String
    let sessionToken: String
    let accessToken: String?

    private enum CodingKeys: String, CodingKey {
        case email
        case sessionToken = "session_token"
        case accessToken = "access_token"
    }
}

private struct SessionResponse: Decodable {
    let email: String
    let token: String?
    let accessToken: String?

    private enum CodingKeys: String, CodingKey {
        case email, token
        case accessToken = "access_token"
    }
}

private struct ConnectionListResponse: Decodable {
    let connections: [SSHConnectionDTO]
}

private struct LiveListResponse: Decodable {
    let live: [SSHLiveSessionDTO]
}

private struct ErrorResponse: Decodable {
    let error: String?
}

private struct RunCommandPayload: Encodable {
    let connectionID: Int
    let command: String
    let timeoutSeconds: Int
    let keepaliveSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case command
        case timeoutSeconds = "timeout_seconds"
        case keepaliveSeconds = "keepalive_seconds"
    }
}

struct RunCommandResponse: Decodable {
    let output: String?
    let exitStatus: Int?
    let reused: Bool?

    private enum CodingKeys: String, CodingKey {
        case output
        case exitStatus = "exit_status"
        case reused
    }
}

private struct CommandHistoryResponse: Decodable {
    let commands: [String]
}

// Wrapper to encode an arbitrary Encodable value while erasing its static type.
private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void

    init(_ value: Encodable) {
        encodeFunc = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
