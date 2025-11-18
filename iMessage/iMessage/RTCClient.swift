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
    private var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var lastRemoteVideoTrack: RTCVideoTrack?
    private var remoteVideoTrackHandler: ((RTCVideoTrack) -> Void)?

    private var activeSessionID: String?
    private var activeConversationID: String?
    private var currentUserEmail: String?

    private var candidateTimer: Timer?
    private var seenCandidateFingerprints = Set<String>()

    private override init() {
        self.urlSession = URLSession(configuration: .default)
        super.init()
    }

    private func sanitizeSDP(_ sdp: String) -> String {
        let lines = sdp.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { String($0) }
        var filtered: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("a=ssrc-group:FID ") {
                continue
            }
            filtered.append(trimmed)
        }
        return filtered.joined(separator: "\r\n") + "\r\n"
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

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("RTCClient: audio session setup error: \(error)")
        }
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

        let videoSource = factory.videoSource()
        self.videoSource = videoSource
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        connection.add(videoTrack, streamIds: ["stream0"])
        localVideoTrack = videoTrack

        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoCapturer = capturer

        currentUserEmail = email
        return connection
    }

    func setRemoteVideoTrackHandler(_ handler: @escaping (RTCVideoTrack) -> Void) {
        remoteVideoTrackHandler = handler
        if let track = lastRemoteVideoTrack {
            handler(track)
        }
    }

    func startLocalVideoIfNeeded() {
        print("RTCClient: startLocalVideoIfNeeded called")
        guard let capturer = videoCapturer else {
            print("RTCClient: startLocalVideoIfNeeded: no videoCapturer available")
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            print("RTCClient: camera authorized")
            startCapture(with: capturer)
        case .notDetermined:
            print("RTCClient: camera auth notDetermined, requesting")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                if granted {
                    DispatchQueue.main.async {
                        self.startLocalVideoIfNeeded()
                    }
                } else {
                    print("RTCClient: camera access denied by user")
                }
            }
        default:
            print("RTCClient: camera access not granted (status=\(status.rawValue))")
        }
    }

    private func startCapture(with capturer: RTCCameraVideoCapturer) {
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
            print("RTCClient: no capture devices available")
            return
        }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.first else {
            print("RTCClient: no supported formats for device \(device)")
            return
        }

        let maxFps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 15
        let fps = max(10, min(Int(maxFps), 30))

        print("RTCClient: starting capture on device=\(device.localizedName), fps=\(fps)")
        DispatchQueue.main.async {
            capturer.startCapture(with: device, format: format, fps: fps) { error in
                print("RTCClient: video capture callback: \(error)")
            }
        }
    }

    func joinAsCallee(sessionID: String, conversationID: String, remoteEmail: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let email = SessionManager.shared.email else {
            completion(.failure(NSError(domain: "RTCClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing current user email"])))
            return
        }

        configureAudioSession()

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
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: sanitizeSDP(offer.sdp))
        peerConnection?.setRemoteDescription(remoteDescription) { [weak self] error in
            if let error = error {
                completion(.failure(error))
                return
            }
            self?.createAndSendAnswer(localEmail: localEmail, completion: completion)
        }
    }

    private func createAndSendAnswer(localEmail: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"])
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
                let typeString: String
                switch description.type {
                case .offer:
                    typeString = "offer"
                case .answer:
                    typeString = "answer"
                case .prAnswer:
                    typeString = "pranswer"
                @unknown default:
                    typeString = "answer"
                }
                self.postAnswer(sessionID: sessionID, sdp: description.sdp, type: typeString, from: localEmail) { result in
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
        if let capturer = videoCapturer {
            capturer.stopCapture {}
        }
        videoCapturer = nil
        videoSource = nil
        localVideoTrack = nil
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
                self.updateSessionState(from: response.session)
                self.applyRemoteCandidates(from: response.session, for: participant)
            }
        }
    }

    private func updateSessionState(from session: Session) {
        guard let pc = peerConnection else { return }
        if pc.remoteDescription == nil, let answer = session.answer {
            let sanitized = sanitizeSDP(answer.sdp)
            let remoteDescription = RTCSessionDescription(type: .answer, sdp: sanitized)
            pc.setRemoteDescription(remoteDescription) { error in
                if let error = error {
                    print("RTCClient: failed to set remote answer: \(error)")
                } else {
                    print("RTCClient: remote answer applied")
                }
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

    func startOutgoingCall(conversationID: String, peerEmail: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let email = SessionManager.shared.email else {
            completion(.failure(NSError(domain: "RTCClient", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing current user email"])))
            return
        }

        configureAudioSession()

        var request = URLRequest(url: rtcBaseURL.appendingPathComponent("/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct CreatePayload: Encodable {
            let conversation_id: String
            let initiator: String
        }
        let payload = CreatePayload(conversation_id: conversationID, initiator: email)

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(error))
            return
        }

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let self = self else {
                completion(.failure(NSError(domain: "RTCClient", code: 21, userInfo: [NSLocalizedDescriptionKey: "RTCClient deallocated"])))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data = data else {
                completion(.failure(NSError(domain: "RTCClient", code: 22, userInfo: [NSLocalizedDescriptionKey: "Invalid session create response"])))
                return
            }
            do {
                let response = try JSONDecoder().decode(SessionResponse.self, from: data)
                DispatchQueue.main.async {
                    self.handleOutgoingSessionCreated(response: response, initiator: email, peerEmail: peerEmail, completion: completion)
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func handleOutgoingSessionCreated(response: SessionResponse, initiator: String, peerEmail: String, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let pc = try makePeerConnection(turn: response.turn, email: initiator)
            peerConnection = pc
            activeSessionID = response.session.id
            activeConversationID = response.session.conversationID
            beginCandidatePolling()
            startLocalVideoIfNeeded()
        } catch {
            completion(.failure(error))
            return
        }

        Task { @MainActor in
            do {
                guard let pc = peerConnection else {
                    throw NSError(domain: "RTCClient", code: 23, userInfo: [NSLocalizedDescriptionKey: "Peer connection missing"])
                }
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"])
                let offer = try await pc.offer(for: constraints)
                try await pc.setLocalDescription(offer)

                guard let sessionID = activeSessionID else {
                    throw NSError(domain: "RTCClient", code: 24, userInfo: [NSLocalizedDescriptionKey: "Missing active session"])
                }

                try await postOffer(sessionID: sessionID, sdp: offer.sdp, type: "offer", from: initiator)
                sendRtcInvite(conversationID: response.session.conversationID ?? "", sessionID: sessionID, initiator: initiator, displayName: peerEmail)
                completion(.success(sessionID))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func postOffer(sessionID: String, sdp: String, type: String, from: String) async throws {
        var request = URLRequest(url: rtcBaseURL.appendingPathComponent("/sessions/\(sessionID)/offer"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = SDPPayload(type: type, sdp: sdp, from: from)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "RTCClient", code: 25, userInfo: [NSLocalizedDescriptionKey: "Offer update failed: \(String(data: data, encoding: .utf8) ?? "")"])
        }
    }

    private func sendRtcInvite(conversationID: String, sessionID: String, initiator: String, displayName: String?) {
        guard !conversationID.isEmpty else {
            return
        }
        let payload: [String: Any] = [
            "kind": "invite",
            "session_id": sessionID,
            "from": initiator,
            "display_name": displayName ?? initiator
        ]
        let envelope: [String: Any] = [
            "type": "rtc_signal",
            "conversation_id": conversationID,
            "text": (try? JSONSerialization.data(withJSONObject: payload, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        ]
        ChatWebSocketManager.shared.sendJSON(envelope)
    }
}

extension RTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("RTCClient: signaling state changed \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("RTCClient: didAdd stream with \(stream.audioTracks.count) audio tracks and \(stream.videoTracks.count) video tracks")
        if let videoTrack = stream.videoTracks.first {
            lastRemoteVideoTrack = videoTrack
            remoteVideoTrackHandler?(videoTrack)
        }
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
