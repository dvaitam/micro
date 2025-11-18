import Foundation

final class DeviceManager {
    static let shared = DeviceManager()

    private let apiBaseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession: URLSession
    private let userDefaults: UserDefaults
    private let legacyDeviceTokenKey = "DeviceManager.deviceToken"
    private let apnsDeviceTokenKey = "DeviceManager.apnsDeviceToken"
    private let voipDeviceTokenKey = "DeviceManager.voipDeviceToken"

    private(set) var apnsDeviceToken: String? {
        didSet {
            if let token = apnsDeviceToken {
                userDefaults.set(token, forKey: apnsDeviceTokenKey)
            } else {
                userDefaults.removeObject(forKey: apnsDeviceTokenKey)
            }
        }
    }

    private(set) var voipDeviceToken: String? {
        didSet {
            if let token = voipDeviceToken {
                userDefaults.set(token, forKey: voipDeviceTokenKey)
            } else {
                userDefaults.removeObject(forKey: voipDeviceTokenKey)
            }
        }
    }

    var deviceToken: String? {
        return apnsDeviceToken
    }

    private init(userDefaults: UserDefaults = .standard, urlSession: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.urlSession = urlSession

        let storedAPNSToken = userDefaults.string(forKey: apnsDeviceTokenKey)
        let storedVoIPToken = userDefaults.string(forKey: voipDeviceTokenKey)
        let legacyToken = userDefaults.string(forKey: legacyDeviceTokenKey)

        self.apnsDeviceToken = storedAPNSToken ?? legacyToken
        self.voipDeviceToken = storedVoIPToken
    }

    struct DeviceTokenPayload: Encodable {
        let device_token: String
        let platform: String?
    }

    func registerDeviceToken(_ token: String) {
        apnsDeviceToken = token

        let payload = DeviceTokenPayload(device_token: token, platform: "ios")
        postDeviceToken(payload)
    }

    func registerVoIPToken(_ token: String) {
        voipDeviceToken = token

        let payload = DeviceTokenPayload(device_token: token, platform: "ios_voip")
        postDeviceToken(payload)
    }

    private func postDeviceToken(_ payload: DeviceTokenPayload) {
        let url = apiBaseURL.appendingPathComponent("/api/device")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            print("Failed to encode device token payload: \(error)")
            return
        }

        urlSession.dataTask(with: request) { _, response, error in
            if let error = error {
                print("Device token registration error: \(error)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("Device token registration failed with status: \(httpResponse.statusCode)")
            }
        }.resume()
    }

    func associateDeviceWithCurrentUser(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let authToken = SessionManager.shared.token else {
            completion?(.failure(NSError(domain: "DeviceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing auth token"])))
            return
        }

        let tokens = [apnsDeviceToken, voipDeviceToken].compactMap { $0 }
        if tokens.isEmpty {
            completion?(.failure(NSError(domain: "DeviceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing device token"])))
            return
        }

        let group = DispatchGroup()
        var lastError: Error?

        for token in tokens {
            group.enter()
            associate(token: token, authToken: authToken) { error in
                if let error = error {
                    lastError = error
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let error = lastError {
                completion?(.failure(error))
            } else {
                completion?(.success(()))
            }
        }
    }

    private func associate(token: String, authToken: String, completion: @escaping (Error?) -> Void) {
        let payload = DeviceTokenPayload(device_token: token, platform: nil)
        let url = apiBaseURL.appendingPathComponent("/api/device/associate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(error)
            return
        }

        urlSession.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(error)
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let err = NSError(domain: "DeviceManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected status code \(httpResponse.statusCode)"])
                completion(err)
                return
            }
            completion(nil)
        }.resume()
    }
}
