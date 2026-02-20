import Foundation
import Combine

@MainActor
final class CodeforcesAPIClient: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var email: String?
    @Published var baseURL: String

    private let defaults = UserDefaults.standard
    private let baseKey = "cf.baseURL"
    private let accessKey = "cf.accessToken"
    private let refreshKey = "cf.refreshToken"
    private let emailKey = "cf.email"

    init() {
        let savedBase = defaults.string(forKey: baseKey) ?? "https://codeforces-api.manchik.co.uk"
        baseURL = CodeforcesAPIClient.normalizeBase(savedBase)
        accessToken = defaults.string(forKey: accessKey)
        refreshToken = defaults.string(forKey: refreshKey)
        email = defaults.string(forKey: emailKey)
    }

    func updateBaseURL(_ newValue: String) {
        let normalized = CodeforcesAPIClient.normalizeBase(newValue.isEmpty ? baseURL : newValue)
        baseURL = normalized
        defaults.set(normalized, forKey: baseKey)
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        email = nil
        defaults.removeObject(forKey: accessKey)
        defaults.removeObject(forKey: refreshKey)
        defaults.removeObject(forKey: emailKey)
    }

    func requestOTP(email: String) async throws {
        let payload = ["email": email]
        _ = try await send(path: "/auth/request-otp", method: "POST", body: payload)
    }

    func verifyOTP(email: String, code: String, stayLoggedIn: Bool) async throws -> AuthTokens {
        struct Payload: Encodable { let email: String; let code: String; let stay_logged_in: Bool }
        let payload = Payload(email: email, code: code, stay_logged_in: stayLoggedIn)
        let data = try await send(path: "/auth/verify-otp", method: "POST", body: payload)
        let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard let token = decoded.accessToken ?? decoded.token else { throw APIError.message("No access token returned") }
        let session = AuthTokens(accessToken: token, refreshToken: decoded.refreshToken, email: decoded.email ?? email)
        apply(tokens: session)
        return session
    }

    func refreshSession() async -> Bool {
        guard let refreshToken else { return false }
        struct Payload: Encodable { let refresh_token: String }
        do {
            let data = try await send(path: "/auth/refresh", method: "POST", body: Payload(refresh_token: refreshToken))
            let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
            guard let token = decoded.accessToken ?? decoded.token else { return false }
            let session = AuthTokens(accessToken: token, refreshToken: decoded.refreshToken ?? refreshToken, email: decoded.email ?? email ?? "")
            apply(tokens: session)
            return true
        } catch {
            return false
        }
    }

    func fetchTags() async throws -> [String] {
        let data = try await send(path: "/tags", method: "GET")
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func fetchProblems(limit: Int, offset: Int, tags: [String], tagsMode: String, sort: String = "") async throws -> (problems: [Problem], total: Int) {
        var components = URLComponents(string: baseURL + "/problems")
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if !tags.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "tags", value: tags.joined(separator: ",")))
            components?.queryItems?.append(URLQueryItem(name: "tags_mode", value: tagsMode))
        }
        if !sort.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "sort", value: sort))
        }
        guard let url = components?.url else { throw APIError.invalidURL }
        let data = try await send(url: url, method: "GET")
        let decoded = try JSONDecoder().decode(ProblemsResponse.self, from: data)
        return (decoded.problems.map { $0.toProblem() }, decoded.total)
    }

    func searchProblems(query: String, limit: Int = 20, offset: Int = 0) async throws -> [Problem] {
        var components = URLComponents(string: baseURL + "/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        guard let url = components?.url else { throw APIError.invalidURL }
        let data = try await send(url: url, method: "GET")
        let decoded = try JSONDecoder().decode([ProblemDTO].self, from: data)
        return decoded.map { $0.toProblem() }
    }

    func fetchProblem(contest: String, index: String) async throws -> Problem {
        let data = try await send(path: "/problems/\(contest)/\(index)", method: "GET")
        let dto = try JSONDecoder().decode(ProblemDTO.self, from: data)
        return dto.toProblem()
    }

    func submit(contest: String, index: String, lang: LanguageOption, code: String) async throws -> SubmissionCreateResponse {
        try await ensureAuthorized()
        let payload: [String: AnyEncodable] = [
            "contest_id": AnyEncodable(contest),
            "index": AnyEncodable(index),
            "lang": AnyEncodable(lang.rawValue),
            "code": AnyEncodable(code)
        ]
        do {
            let data = try await authorizedRequest(path: "/submissions", method: "POST", body: payload)
            return try JSONDecoder().decode(SubmissionCreateResponse.self, from: data)
        } catch APIError.unauthorized {
            guard await refreshSession() else { throw APIError.unauthorized }
            let data = try await authorizedRequest(path: "/submissions", method: "POST", body: payload)
            return try JSONDecoder().decode(SubmissionCreateResponse.self, from: data)
        }
    }

    func fetchFavorites() async throws -> [Problem] {
        try await ensureAuthorized()
        do {
            let data = try await authorizedRequest(path: "/me/favorites", method: "GET")
            let dtos = try JSONDecoder().decode([ProblemDTO].self, from: data)
            return dtos.map { $0.toProblem() }
        } catch APIError.unauthorized {
            guard await refreshSession() else { throw APIError.unauthorized }
            let data = try await authorizedRequest(path: "/me/favorites", method: "GET")
            let dtos = try JSONDecoder().decode([ProblemDTO].self, from: data)
            return dtos.map { $0.toProblem() }
        }
    }

    func addFavorite(contestId: String, index: String) async throws {
        try await ensureAuthorized()
        let payload: [String: AnyEncodable] = [
            "contest_id": AnyEncodable(contestId),
            "index": AnyEncodable(index)
        ]
        do {
            _ = try await authorizedRequest(path: "/me/favorites", method: "POST", body: payload)
        } catch APIError.unauthorized {
            guard await refreshSession() else { throw APIError.unauthorized }
            _ = try await authorizedRequest(path: "/me/favorites", method: "POST", body: payload)
        }
    }

    func removeFavorite(contestId: String, index: String) async throws {
        try await ensureAuthorized()
        do {
            _ = try await authorizedRequest(path: "/me/favorites?contest_id=\(contestId)&index=\(index)", method: "DELETE")
        } catch APIError.unauthorized {
            guard await refreshSession() else { throw APIError.unauthorized }
            _ = try await authorizedRequest(path: "/me/favorites?contest_id=\(contestId)&index=\(index)", method: "DELETE")
        }
    }

    func fetchSubmission(id: Int) async throws -> SubmissionDetail {
        let data = try await send(path: "/submissions?id=\(id)", method: "GET")
        return try JSONDecoder().decode(SubmissionDetail.self, from: data)
    }

    func fetchProblemSubmissions(contest: String, index: String, limit: Int = 50) async throws -> [SubmissionDetail] {
        let data = try await send(path: "/submissions?contest=\(contest)&index=\(index)&limit=\(limit)", method: "GET")
        return (try? JSONDecoder().decode([SubmissionDetail].self, from: data)) ?? []
    }

    func fetchUserSubmissions(limit: Int = 50, offset: Int = 0) async throws -> [SubmissionDetail] {
        try await ensureAuthorized()
        do {
            let data = try await authorizedRequest(path: "/me/submissions?limit=\(limit)&offset=\(offset)", method: "GET")
            return (try? JSONDecoder().decode([SubmissionDetail].self, from: data)) ?? []
        } catch APIError.unauthorized {
            guard await refreshSession() else { throw APIError.unauthorized }
            let data = try await authorizedRequest(path: "/me/submissions?limit=\(limit)&offset=\(offset)", method: "GET")
            return (try? JSONDecoder().decode([SubmissionDetail].self, from: data)) ?? []
        }
    }

    // MARK: - Helpers

    private func apply(tokens: AuthTokens) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        email = tokens.email
        defaults.set(baseURL, forKey: baseKey)
        defaults.set(tokens.accessToken, forKey: accessKey)
        if let refresh = tokens.refreshToken { defaults.set(refresh, forKey: refreshKey) }
        defaults.set(tokens.email, forKey: emailKey)
    }

    private func ensureAuthorized() async throws {
        guard accessToken != nil else { throw APIError.unauthorized }
    }

    private func authorizedRequest(path: String, method: String, body: [String: AnyEncodable]? = nil) async throws -> Data {
        guard let accessToken else { throw APIError.unauthorized }
        return try await send(path: path, method: method, headers: ["Authorization": "Bearer \(accessToken)"], body: body)
    }

    private func send(path: String, method: String, headers: [String: String]? = nil, body: Encodable? = nil) async throws -> Data {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        return try await send(url: url, method: method, headers: headers, body: body)
    }

    private func send(url: URL, method: String, headers: [String: String]? = nil, body: Encodable? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        var combined = headers ?? [:]
        combined["Accept"] = "application/json"
        for (k, v) in combined { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.message("Invalid response") }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if !(200...299).contains(http.statusCode) {
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data).error {
                throw APIError.message(err)
            }
            throw APIError.message("Request failed (\(http.statusCode))")
        }
        return data
    }

    private static func normalizeBase(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "https://codeforces-api.manchik.co.uk" }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        return value
    }
}

private struct AuthResponse: Decodable {
    let accessToken: String?
    let token: String?
    let refreshToken: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case token
        case refreshToken = "refresh_token"
        case email
    }
}

private struct ErrorResponse: Decodable {
    let error: String?
}

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void

    init(_ value: Encodable) {
        encodeFunc = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
