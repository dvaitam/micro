import Foundation

final class ConversationReadStore {
    static let shared = ConversationReadStore()

    private let userDefaults: UserDefaults

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    private lazy var iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func key(for email: String, conversationID: String) -> String {
        return "ConversationReadStore.lastReadAt.\(email).\(conversationID)"
    }

    func lastReadDate(for conversationID: String, email: String) -> Date? {
        let key = self.key(for: email, conversationID: conversationID)
        guard let value = userDefaults.string(forKey: key) else {
            return nil
        }
        return iso8601Formatter.date(from: value)
    }

    func updateLastReadDate(_ date: Date, for conversationID: String, email: String) {
        let key = self.key(for: email, conversationID: conversationID)
        let value = iso8601Formatter.string(from: date)
        userDefaults.set(value, forKey: key)
    }

    func parseTimestamp(_ value: String) -> Date? {
        return iso8601Formatter.date(from: value)
    }
}

