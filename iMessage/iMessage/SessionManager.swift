import Foundation

struct SessionInfo: Decodable {
    let email: String
    let token: String
}

final class SessionManager {
    static let shared = SessionManager()

    private let baseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession: URLSession

    private(set) var email: String?
    private(set) var token: String?

    private var isRefreshing = false
    private var pendingCompletions: [(Result<SessionInfo, Error>) -> Void] = []

    private init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
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

        let request = URLRequest(url: url)
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRefreshing = false

                var result: Result<SessionInfo, Error>

                if let error = error {
                    result = .failure(error)
                } else if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    do {
                        let info = try JSONDecoder().decode(SessionInfo.self, from: data)
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

