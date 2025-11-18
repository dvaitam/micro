import UIKit
import WebRTC

final class VideoCallViewController: UIViewController {

    enum Mode {
        case outgoing
        case incoming
    }

    private let conversationID: String
    private let peerEmail: String
    private let mode: Mode

    private let statusLabel = UILabel()
    private let remoteVideoView = RTCMTLVideoView(frame: .zero)
    private let localVideoView = RTCMTLVideoView(frame: .zero)

    private var remoteTrack: RTCVideoTrack?

    init(conversationID: String, peerEmail: String, mode: Mode) {
        self.conversationID = conversationID
        self.peerEmail = peerEmail
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        statusLabel.numberOfLines = 0
        statusLabel.text = mode == .outgoing ? "Calling…" : "Incoming call"

        remoteVideoView.translatesAutoresizingMaskIntoConstraints = false
        remoteVideoView.videoContentMode = .scaleAspectFill

        localVideoView.translatesAutoresizingMaskIntoConstraints = false
        localVideoView.videoContentMode = .scaleAspectFill
        localVideoView.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        localVideoView.layer.borderWidth = 1
        localVideoView.layer.cornerRadius = 8
        localVideoView.layer.masksToBounds = true

        let hangupButton = UIButton(type: .system)
        hangupButton.translatesAutoresizingMaskIntoConstraints = false
        hangupButton.setTitle("Hang Up", for: .normal)
        hangupButton.setTitleColor(.white, for: .normal)
        hangupButton.backgroundColor = .systemRed
        hangupButton.layer.cornerRadius = 24
        hangupButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        hangupButton.addTarget(self, action: #selector(didTapHangup), for: .touchUpInside)

        view.addSubview(remoteVideoView)
        view.addSubview(localVideoView)
        view.addSubview(statusLabel)
        view.addSubview(hangupButton)

        NSLayoutConstraint.activate([
            remoteVideoView.topAnchor.constraint(equalTo: view.topAnchor),
            remoteVideoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteVideoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remoteVideoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            localVideoView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.3),
            localVideoView.heightAnchor.constraint(equalTo: localVideoView.widthAnchor, multiplier: 4.0 / 3.0),
            localVideoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            localVideoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            hangupButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hangupButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])

        RTCClient.shared.setRemoteVideoTrackHandler { [weak self] track in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.attachRemoteTrack(track)
            }
        }
    }

    private func attachRemoteTrack(_ track: RTCVideoTrack) {
        if let existing = remoteTrack {
            existing.remove(remoteVideoView)
        }
        remoteTrack = track
        track.add(remoteVideoView)
        statusLabel.text = "In call with \(peerEmail)"
    }

    @objc private func didTapHangup() {
        RTCClient.shared.endCurrentCall()
        dismiss(animated: true, completion: nil)
    }
}
