import Foundation

enum SSHAuthMethod: String, Codable, CaseIterable {
    case password = "Password"
    case key = "Key"
}

enum ConnectionStatus: Equatable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    case failed(reason: String)

    var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }

    var actionTitle: String {
        switch self {
        case .connected, .connecting:
            return "Disconnect"
        case .disconnected, .failed:
            return "Connect"
        }
    }
}

struct SSHProfile: Codable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: SSHAuthMethod
    var hasSavedPassword: Bool
    var hasSavedPrivateKey: Bool
    var hasSavedPassphrase: Bool
}

struct SSHSecrets {
    var password: String?
    var privateKey: String?
    var passphrase: String?
}

struct SSHCredentials {
    var profile: SSHProfile
    var secrets: SSHSecrets
}
