import Foundation

struct SessionInfo {
    let email: String
    let accessToken: String
    let refreshToken: String?

    var token: String {
        return accessToken
    }
}

final class SessionManager {
    static let shared = SessionManager()

    private let baseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession: URLSession
    private let userDefaults: UserDefaults
    private let emailKey = "SessionManager.email"
    private let legacyTokenKey = "SessionManager.token"
    private let accessTokenKey = "SessionManager.accessToken"
    private let refreshTokenKey = "SessionManager.refreshToken"

    private(set) var email: String? {
        didSet {
            if let email = email {
                userDefaults.set(email, forKey: emailKey)
            } else {
                userDefaults.removeObject(forKey: emailKey)
            }
        }
    }

    private(set) var accessToken: String? {
        didSet {
            if let token = accessToken {
                userDefaults.set(token, forKey: accessTokenKey)
            } else {
                userDefaults.removeObject(forKey: accessTokenKey)
            }
        }
    }

    private(set) var refreshToken: String? {
        didSet {
            if let token = refreshToken {
                userDefaults.set(token, forKey: refreshTokenKey)
            } else {
                userDefaults.removeObject(forKey: refreshTokenKey)
            }
        }
    }

    var token: String? {
        return accessToken
    }

    private var isRefreshing = false
    private var pendingCompletions: [(Result<SessionInfo, Error>) -> Void] = []

    private init(urlSession: URLSession = .shared, userDefaults: UserDefaults = .standard) {
        self.urlSession = urlSession
        self.userDefaults = userDefaults
        self.email = userDefaults.string(forKey: emailKey)

        let storedAccess = userDefaults.string(forKey: accessTokenKey)
        let storedRefresh = userDefaults.string(forKey: refreshTokenKey)
        let legacy = userDefaults.string(forKey: legacyTokenKey)

        // Prefer explicitly stored tokens; fall back to legacy token for compatibility.
        self.accessToken = storedAccess ?? legacy
        self.refreshToken = storedRefresh ?? legacy
    }

    func updateSession(email: String, accessToken: String, refreshToken: String) {
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func clearSession() {
        email = nil
        accessToken = nil
        refreshToken = nil
    }

    func refreshSession(force: Bool = false, completion: ((Result<SessionInfo, Error>) -> Void)? = nil) {
        if let completion = completion {
            pendingCompletions.append(completion)
        }

        if isRefreshing {
            return
        }

        guard let url = URL(string: "/api/session", relativeTo: baseURL) else {
            let error = NSError(domain: "SessionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid session URL"])
            finishRefresh(with: .failure(error))
            return
        }

        // Prefer refresh token when available; fall back to access token for older sessions.
        guard let authToken = refreshToken ?? accessToken else {
            let error = NSError(domain: "SessionManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing auth token"])
            finishRefresh(with: .failure(error))
            return
        }

        isRefreshing = true

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRefreshing = false

                if let error = error {
                    self.finishRefresh(with: .failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    let error = NSError(domain: "SessionManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                    self.finishRefresh(with: .failure(error))
                    return
                }

                guard httpResponse.statusCode == 200, let data = data else {
                    let error = NSError(domain: "SessionManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Unable to load session"])
                    self.finishRefresh(with: .failure(error))
                    return
                }

                do {
                    struct APIResponse: Decodable {
                        let email: String
                        let token: String
                        let accessToken: String?
                        let tokenType: String?
                        let expiresIn: Int?

                        enum CodingKeys: String, CodingKey {
                            case email
                            case token
                            case accessToken = "access_token"
                            case tokenType = "token_type"
                            case expiresIn = "expires_in"
                        }
                    }

                    let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
                    let newAccessToken = decoded.accessToken ?? self.accessToken ?? authToken
                    let info = SessionInfo(email: decoded.email, accessToken: newAccessToken, refreshToken: decoded.token)

                    self.email = info.email
                    self.accessToken = info.accessToken
                    self.refreshToken = info.refreshToken

                    self.finishRefresh(with: .success(info))
                } catch {
                    self.finishRefresh(with: .failure(error))
                }
            }
        }.resume()
    }

    private func finishRefresh(with result: Result<SessionInfo, Error>) {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0(result) }
    }
}
