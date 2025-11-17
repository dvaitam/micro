import Foundation

final class ConversationUnreadStore {
    static let shared = ConversationUnreadStore()

    private let userDefaults: UserDefaults

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    private func key(for email: String, conversationID: String) -> String {
        return "ConversationUnreadStore.unreadCount.\(email).\(conversationID)"
    }

    func unreadCount(for conversationID: String, email: String) -> Int {
        let key = self.key(for: email, conversationID: conversationID)
        return userDefaults.integer(forKey: key)
    }

    func setUnreadCount(_ count: Int, for conversationID: String, email: String) {
        let key = self.key(for: email, conversationID: conversationID)
        if count <= 0 {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(count, forKey: key)
        }
    }
}

