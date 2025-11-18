import UIKit
import WebRTC

final class CallsViewController: UIViewController {

    private var remoteVideoView: RTCMTLVideoView?
    private var remoteVideoTrack: RTCVideoTrack?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Call"
        view.backgroundColor = .black

        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.videoContentMode = .scaleAspectFill
        view.addSubview(videoView)
        remoteVideoView = videoView

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])

        RTCClient.shared.setRemoteVideoTrackHandler { [weak self] track in
            DispatchQueue.main.async {
                guard let self = self, let renderer = self.remoteVideoView else { return }
                self.remoteVideoTrack?.remove(renderer)
                self.remoteVideoTrack = track
                track.add(renderer)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        RTCClient.shared.startLocalVideoIfNeeded()
    }

    deinit {
        if let renderer = remoteVideoView {
            remoteVideoTrack?.remove(renderer)
        }
    }
}
