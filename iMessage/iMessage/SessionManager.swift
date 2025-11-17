import Foundation

struct SessionInfo {
    let email: String
    let token: String
}

final class SessionManager {
    static let shared = SessionManager()

    private let baseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession: URLSession
    private let userDefaults: UserDefaults
    private let emailKey = "SessionManager.email"
    private let tokenKey = "SessionManager.token"

    private(set) var email: String? {
        didSet {
            if let email = email {
                userDefaults.set(email, forKey: emailKey)
            } else {
                userDefaults.removeObject(forKey: emailKey)
            }
        }
    }

    private(set) var token: String? {
        didSet {
            if let token = token {
                userDefaults.set(token, forKey: tokenKey)
            } else {
                userDefaults.removeObject(forKey: tokenKey)
            }
        }
    }

    private var isRefreshing = false
    private var pendingCompletions: [(Result<SessionInfo, Error>) -> Void] = []

    private init(urlSession: URLSession = .shared, userDefaults: UserDefaults = .standard) {
        self.urlSession = urlSession
        self.userDefaults = userDefaults
        self.email = userDefaults.string(forKey: emailKey)
        self.token = userDefaults.string(forKey: tokenKey)
    }

    func updateSession(email: String, token: String) {
        self.email = email
        self.token = token
    }

    func clearSession() {
        email = nil
        token = nil
    }

    func refreshSession(force: Bool = false, completion: ((Result<SessionInfo, Error>) -> Void)? = nil) {
        if !force, let email = email, let token = token {
            let info = SessionInfo(email: email, token: token)
            completion?(.success(info))
            return
        }

        if let completion = completion {
            pendingCompletions.append(completion)
        }

        if isRefreshing {
            return
        }

        guard let url = URL(string: "/api/session", relativeTo: baseURL) else {
            if let completion = completion {
                let error = NSError(domain: "SessionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid session URL"])
                completion(.failure(error))
            }
            return
        }

        isRefreshing = true

        var request = URLRequest(url: url)
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRefreshing = false

                var result: Result<SessionInfo, Error>

                if let error = error {
                    result = .failure(error)
                } else if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    do {
                        struct APIResponse: Decodable {
                            let email: String
                            let token: String
                        }
                        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
                        let info = SessionInfo(email: decoded.email, token: decoded.token)
                        self.email = info.email
                        self.token = info.token
                        result = .success(info)
                    } catch {
                        result = .failure(error)
                    }
                } else {
                    let error = NSError(domain: "SessionManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to load session"])
                    result = .failure(error)
                }

                let completions = self.pendingCompletions
                self.pendingCompletions.removeAll()
                completions.forEach { $0(result) }
            }
        }.resume()
    }
}
