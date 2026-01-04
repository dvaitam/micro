import Foundation
import Security

final class ProfileStore {
    static let shared = ProfileStore()

    private let profilesKey = "ssh.profiles"
    private let keychainService = "iSSH"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaults = UserDefaults.standard

    func loadProfiles() -> [SSHProfile] {
        guard let data = defaults.data(forKey: profilesKey) else { return [] }
        do {
            return try decoder.decode([SSHProfile].self, from: data)
        } catch {
            return []
        }
    }

    func saveProfiles(_ profiles: [SSHProfile]) {
        guard let data = try? encoder.encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    func loadSecrets(for profile: SSHProfile) -> SSHSecrets {
        SSHSecrets(
            password: string(for: passwordKey(for: profile)),
            privateKey: string(for: privateKeyKey(for: profile)),
            passphrase: string(for: passphraseKey(for: profile))
        )
    }

    func saveSecrets(for profile: SSHProfile, secrets: SSHSecrets, clearExisting: Bool = false) {
        if clearExisting {
            deleteSecrets(for: profile)
        }

        if let password = secrets.password, !password.isEmpty {
            save(password, for: passwordKey(for: profile))
        }

        if let privateKey = secrets.privateKey, !privateKey.isEmpty {
            save(privateKey, for: privateKeyKey(for: profile))
        }

        if let passphrase = secrets.passphrase, !passphrase.isEmpty {
            save(passphrase, for: passphraseKey(for: profile))
        }
    }

    func deleteSecrets(for profile: SSHProfile) {
        deleteValue(for: passwordKey(for: profile))
        deleteValue(for: privateKeyKey(for: profile))
        deleteValue(for: passphraseKey(for: profile))
    }

    private func passwordKey(for profile: SSHProfile) -> String {
        "ssh.password.\(profile.id.uuidString)"
    }

    private func privateKeyKey(for profile: SSHProfile) -> String {
        "ssh.privateKey.\(profile.id.uuidString)"
    }

    private func passphraseKey(for profile: SSHProfile) -> String {
        "ssh.passphrase.\(profile.id.uuidString)"
    }

    private func save(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: value.data(using: .utf8) ?? Data(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [kSecValueData as String: value.data(using: .utf8) ?? Data()]
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    private func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteValue(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
