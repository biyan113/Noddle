import AVFoundation
import MediaPlayer
import NoddleCore

/// Plays silence to the current output.
///
/// macOS streams head tracking most reliably while the AirPods are the active route, and only
/// sends stem presses to an app that is really playing. Starting this re-centres yaw once;
/// PoseTracker absorbs that jump.
@MainActor
final class AudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false
    private var wanted = false
    private var observer: NSObjectProtocol?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    func start() {
        wanted = true
        if !configured {
            configured = true
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.play() }
            }
        }
        play()
    }

    func stop() {
        wanted = false
        guard configured else { return }
        player.stop()
        engine.stop()
    }

    private func play() {
        guard wanted, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity // AVAudioPCMBuffer memory is zeroed: silence.
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !player.isPlaying {
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.play()
            }
        } catch {
            Log.write("keep-alive failed: \(error.localizedDescription)")
        }
    }
}

/// Claims AirPods stem presses. They arrive as media commands sent to the Now Playing app:
/// one press = play/pause, two = next, three = previous.
@MainActor
final class StemService {
    var onPress: ((GestureID) -> Void)?
    private(set) var isActive = false
    private var targets: [(MPRemoteCommand, Any)] = []
    private var lastSingle = 0.0

    func start() {
        guard !isActive else { return }
        isActive = true
        let center = MPRemoteCommandCenter.shared()
        claim(center.togglePlayPauseCommand, as: .stemSingle)
        claim(center.playCommand, as: .stemSingle)
        claim(center.pauseCommand, as: .stemSingle)
        claim(center.nextTrackCommand, as: .stemDouble)
        claim(center.previousTrackCommand, as: .stemTriple)
        publish()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func claim(_ command: MPRemoteCommand, as gesture: GestureID) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(gesture) } }
            return .success
        }
        targets.append((command, target))
    }

    private func received(_ gesture: GestureID) {
        if gesture == .stemSingle {
            // One press can arrive as pause + play.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSingle > 0.3 else { return }
            lastSingle = now
        }
        publish()
        onPress?(gesture)
    }

    private func publish() {
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Noddle",
            MPMediaItemPropertyArtist: L("头部控制已开启", "Head control on"),
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        info.playbackState = .playing
    }
}
