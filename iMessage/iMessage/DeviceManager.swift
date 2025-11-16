import Foundation

final class DeviceManager {
    static let shared = DeviceManager()

    private let apiBaseURL = URL(string: "https://chat.manchik.co.uk")!
    private let urlSession: URLSession
    private let userDefaults: UserDefaults
    private let deviceTokenKey = "DeviceManager.deviceToken"

    private(set) var deviceToken: String? {
        didSet {
            if let token = deviceToken {
                userDefaults.set(token, forKey: deviceTokenKey)
            } else {
                userDefaults.removeObject(forKey: deviceTokenKey)
            }
        }
    }

    private init(userDefaults: UserDefaults = .standard, urlSession: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.urlSession = urlSession
        self.deviceToken = userDefaults.string(forKey: deviceTokenKey)
    }

    struct DeviceTokenPayload: Encodable {
        let device_token: String
        let platform: String?
    }

    func registerDeviceToken(_ token: String) {
        deviceToken = token

        let payload = DeviceTokenPayload(device_token: token, platform: "ios")
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
        guard let token = deviceToken else {
            completion?(.failure(NSError(domain: "DeviceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing device token"])))
            return
        }

        let payload = DeviceTokenPayload(device_token: token, platform: nil)
        let url = apiBaseURL.appendingPathComponent("/api/device/associate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion?(.failure(error))
            return
        }

        urlSession.dataTask(with: request) { _, response, error in
            if let error = error {
                completion?(.failure(error))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let err = NSError(domain: "DeviceManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected status code \(httpResponse.statusCode)"])
                completion?(.failure(err))
                return
            }
            completion?(.success(()))
        }.resume()
    }
}

