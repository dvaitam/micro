import Foundation
import CallKit
import PushKit

final class CallManager: NSObject, CXProviderDelegate {
    static let shared = CallManager()

    private let provider: CXProvider
    private let callController = CXCallController()

    private var currentCallUUID: UUID?
    private var currentConversationID: String?
    private var currentSessionID: String?
    private var currentRemoteEmail: String?
    private var currentDisplayName: String?

    private override init() {
        let configuration = CXProviderConfiguration(localizedName: "iMessage")
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.includesCallsInRecents = true
        configuration.supportedHandleTypes = [.emailAddress]
        provider = CXProvider(configuration: configuration)

        super.init()

        provider.setDelegate(self, queue: nil)
    }

    func reportIncomingCall(conversationID: String, sessionID: String, fromEmail: String, displayName: String?) {
        if currentCallUUID != nil {
            print("CallManager: incoming call already active, ignoring new invite")
            return
        }
        let name = displayName?.isEmpty == false ? displayName! : fromEmail

        let uuid = UUID()
        currentCallUUID = uuid
        currentConversationID = conversationID
        currentSessionID = sessionID
        currentRemoteEmail = fromEmail
        currentDisplayName = name

        let handle = CXHandle(type: .emailAddress, value: fromEmail)
        let update = CXCallUpdate()
        update.remoteHandle = handle
        update.localizedCallerName = name
        update.hasVideo = true

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("Failed to report incoming call: \(error)")
            } else {
                print("Reported incoming call from \(fromEmail) for conversation \(conversationID)")
            }
        }
    }

    func handleIncomingRtcInvite(conversationID: String, sessionID: String, fromEmail: String, displayName: String?) {
        reportIncomingCall(conversationID: conversationID, sessionID: sessionID, fromEmail: fromEmail, displayName: displayName)
    }

    func handleIncomingVoIPPush(payload: PKPushPayload) {
        let dict = payload.dictionaryPayload
        let aps = dict["aps"] as? [String: Any]

        let kind = (aps?["kind"] as? String) ?? (dict["kind"] as? String)
        guard kind == "rtc_invite" || kind == "invite" else {
            return
        }

        let conversationID = (aps?["conversation_id"] as? String) ?? (dict["conversation_id"] as? String)
        let sessionID = (aps?["session_id"] as? String) ?? (dict["session_id"] as? String)
        let fromEmail = (aps?["from"] as? String) ?? (dict["from"] as? String)
        let displayName = (aps?["display_name"] as? String) ?? (dict["display_name"] as? String) ?? fromEmail

        guard let conversationID, let sessionID, let fromEmail else {
            return
        }

        reportIncomingCall(conversationID: conversationID, sessionID: sessionID, fromEmail: fromEmail, displayName: displayName)
    }

    func providerDidReset(_ provider: CXProvider) {
        currentCallUUID = nil
        currentConversationID = nil
        currentSessionID = nil
        currentRemoteEmail = nil
        currentDisplayName = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let sessionID = currentSessionID, let conversationID = currentConversationID, let remoteEmail = currentRemoteEmail else {
            action.fail()
            return
        }
        RTCClient.shared.joinAsCallee(sessionID: sessionID, conversationID: conversationID, remoteEmail: remoteEmail) { result in
            switch result {
            case .success:
                print("RTC call started for session \(sessionID)")
                action.fulfill()
            case .failure(let error):
                print("Failed to start RTC call: \(error)")
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        RTCClient.shared.endCurrentCall()
        action.fulfill()
        currentCallUUID = nil
        currentConversationID = nil
        currentSessionID = nil
        currentRemoteEmail = nil
        currentDisplayName = nil
    }
}
