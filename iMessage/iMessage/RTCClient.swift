import Foundation
import AVFoundation
import WebRTC

final class RTCClient: NSObject {
    static let shared = RTCClient()

    private let rtcBaseURL = URL(string: "https://webrtc.manchik.co.uk")!
    private let urlSession: URLSession

    private var peerConnectionFactory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?

    private var activeSessionID: String?
    private var activeConversationID: String?
    private var currentUserEmail: String?

    private var candidateTimer: Timer?
    private var seenCandidateFingerprints = Set<String>()

    private override init() {
        self.urlSession = URLSession(configuration: .default)
        super.init()
    }

    private func ensureFactory() -> RTCPeerConnectionFactory {
        if let factory = peerConnectionFactory {
            return factory
        }
        RTCPeerConnectionFactory.initialize()
        let factory = RTCPeerConnectionFactory()
        peerConnectionFactory = factory
        return factory
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func makePeerConnection(turn: TurnCredentials?, email: String) throws -> RTCPeerConnection {
        let factory = ensureFactory()
        var config = RTCConfiguration()
        if let turn = turn, !turn.urls.isEmpty {
            let server = RTCIceServer(urlStrings: turn.urls, username: turn.username, credential: turn.credential)
            config.iceServers = [server]
        } else {
            config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        }
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        connection.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack

        currentUserEmail = email
        return connection
    }

    func joinAsCallee(sessionID: String, conversationID: String, remoteEmail: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let email = SessionManager.shared.email else {
            completion(.failure(NSError(domain: "RTCClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing current user email"])))
            return
        }

        do {
            try configureAudioSession()
        } catch {
            completion(.failure(error))
            return
        }

        fetchSession(sessionID: sessionID, participant: email) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                guard let offer = response.session.offer else {
                    completion(.failure(NSError(domain: "RTCClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing offer in session"])))
                    return
                }
                DispatchQueue.main.async {
                    self.handleIncomingOffer(response: response, sessionID: sessionID, conversationID: conversationID, localEmail: email, completion: completion)
                }
            }
        }
    }

    private func handleIncomingOffer(response: SessionResponse, sessionID: String, conversationID: String, localEmail: String, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let connection = try makePeerConnection(turn: response.turn, email: localEmail)
            peerConnection = connection
            activeSessionID = sessionID
            activeConversationID = conversationID
        } catch {
            completion(.failure(error))
            return
        }

        let offer = response.session.offer!
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        peerConnection?.setRemoteDescription(remoteDescription) { [weak self] error in
            if let error = error {
                completion(.failure(error))
                return
            }
            self?.createAndSendAnswer(localEmail: localEmail, completion: completion)
        }
    }

    private func createAndSendAnswer(localEmail: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"])
        peerConnection?.answer(for: constraints) { [weak self] description, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let description = description else {
                completion(.failure(NSError(domain: "RTCClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing answer description"])))
                return
            }

            self.peerConnection?.setLocalDescription(description) { error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let sessionID = self.activeSessionID else {
                    completion(.failure(NSError(domain: "RTCClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing active session"])))
                    return
                }
                self.postAnswer(sessionID: sessionID, sdp: description.sdp, type: description.type.rawValue, from: localEmail) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        self.beginCandidatePolling()
                        completion(.success(()))
                    }
                }
            }
        }
    }

    func endCurrentCall() {
        candidateTimer?.invalidate()
        candidateTimer = nil
        seenCandidateFingerprints.removeAll()
        if let sessionID = activeSessionID {
            deleteSession(sessionID: sessionID)
        }
        peerConnection?.close()
        peerConnection = nil
        activeSessionID = nil
        activeConversationID = nil
        currentUserEmail = nil
    }

    private func beginCandidatePolling() {
        candidateTimer?.invalidate()
        guard let sessionID = activeSessionID, let email = currentUserEmail else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollSessionCandidates(sessionID: sessionID, participant: email)
        }
        candidateTimer = timer
    }

    private func pollSessionCandidates(sessionID: String, participant: String) {
        fetchSession(sessionID: sessionID, participant: participant) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("RTCClient: candidate poll failed: \(error)")
            case .success(let response):
                self.applyRemoteCandidates(from: response.session, for: participant)
            }
        }
    }

    private func applyRemoteCandidates(from session: Session, for localParticipant: String) {
        guard let pc = peerConnection else { return }
        guard let candidates = session.candidates else { return }

        for (email, entries) in candidates {
            if email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == localParticipant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                continue
            }
            for candidate in entries {
                let fingerprint = "\(email):\(candidate.candidate):\(candidate.sdpMid ?? ""):\(candidate.sdpMLineIndex ?? -1)"
                if seenCandidateFingerprints.contains(fingerprint) {
                    continue
                }
                seenCandidateFingerprints.insert(fingerprint)

                let iceCandidate = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0), sdpMid: candidate.sdpMid)
                pc.add(iceCandidate)
            }
        }
    }

    private func fetchSession(sessionID: String, participant: String, completion: @escaping (Result<SessionResponse, Error>) -> Void) {
        var components = URLComponents(url: rtcBaseURL.appendingPathComponent("/sessions/\(sessionID)"), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "participant", value: participant)]
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "RTCClient", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid session URL"])))
            return
        }

        urlSession.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data = data else {
                completion(.failure(NSError(domain: "RTCClient", code: 11, userInfo: [NSLocalizedDescriptionKey: "Invalid session response"])))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func postAnswer(sessionID: String, sdp: String, type: String, from: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: rtcBaseURL.appendingPathComponent("/sessions/\(sessionID)/answer"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = SDPPayload(type: type, sdp: sdp, from: from)
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(error))
            return
        }

        urlSession.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                completion(.failure(NSError(domain: "RTCClient", code: 12, userInfo: [NSLocalizedDescriptionKey: "Answer update failed"])))
                return
            }
            completion(.success(()))
        }.resume()
    }

    private func postCandidate(candidate: RTCIceCandidate, from: String) {
        guard let sessionID = activeSessionID else { return }

        var request = URLRequest(url: rtcBaseURL.appendingPathComponent("/sessions/\(sessionID)/candidates"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let index: UInt16? = candidate.sdpMLineIndex >= 0 ? UInt16(candidate.sdpMLineIndex) : nil
        let payload = CandidatePayload(candidate: candidate.sdp, sdpMid: candidate.sdpMid ?? "", sdpMLineIndex: index, from: from)

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            print("RTCClient: failed to encode candidate: \(error)")
            return
        }

        urlSession.dataTask(with: request) { _, response, error in
            if let error = error {
                print("RTCClient: candidate post error: \(error)")
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("RTCClient: candidate post failed with status \(http.statusCode)")
            }
        }.resume()
    }

    private func deleteSession(sessionID: String) {
        var request = URLRequest(url: rtcBaseURL.appendingPathComponent("/sessions/\(sessionID)"))
        request.httpMethod = "DELETE"
        urlSession.dataTask(with: request).resume()
    }
}

extension RTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("RTCClient: signaling state changed \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("RTCClient: didAdd stream with \(stream.audioTracks.count) audio tracks")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("RTCClient: didRemove stream")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("RTCClient: shouldNegotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("RTCClient: ICE connection state \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("RTCClient: ICE gathering state \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let email = currentUserEmail else { return }
        postCandidate(candidate: candidate, from: email)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("RTCClient: didRemove candidates \(candidates.count)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("RTCClient: didOpen data channel")
    }
}

struct SessionResponse: Decodable {
    let session: Session
    let turn: TurnCredentials?
}

struct Session: Decodable {
    let id: String
    let conversationID: String?
    let initiator: String
    let offer: SDPPayload?
    let answer: SDPPayload?
    let candidates: [String: [RemoteCandidate]]?

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case conversationID = "conversation_id"
        case initiator
        case offer
        case answer
        case candidates
    }
}

struct SDPPayload: Codable {
    let type: String
    let sdp: String
    let from: String

    enum CodingKeys: String, CodingKey {
        case type = "type"
        case sdp = "sdp"
        case from = "from"
    }
}

struct RemoteCandidate: Decodable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_m_line_index"
    }
}

struct CandidatePayload: Codable {
    let candidate: String
    let sdpMid: String
    let sdpMLineIndex: UInt16?
    let from: String

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_m_line_index"
        case from
    }
}

struct TurnCredentials: Decodable {
    let username: String?
    let credential: String?
    let ttlSeconds: Int
    let urls: [String]

    enum CodingKeys: String, CodingKey {
        case username
        case credential
        case ttlSeconds = "ttl_seconds"
        case urls
    }
}

