import Foundation

extension Notification.Name {
    static let chatMessageReceived = Notification.Name("ChatMessageReceived")
    static let chatConversationUpdated = Notification.Name("ChatConversationUpdated")
    static let chatPresenceUpdated = Notification.Name("ChatPresenceUpdated")
    static let chatConversationRead = Notification.Name("ChatConversationRead")
}
