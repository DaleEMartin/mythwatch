import MediaPlayer
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback

/// Publishes the playing recording to the system (`MPNowPlayingInfoCenter`) and takes its remote
/// commands (`MPRemoteCommandCenter`), as SPEC 7 asks. Every command becomes a `TransportModel`
/// intent. One per player screen: `attach` when a transport appears, `detach` when it goes.
@MainActor final class NowPlaying {
    private var transport: TransportModel?
    private var targets: [(MPRemoteCommand, Any)] = []
    /// What was last published, so position updates are sent only when they matter.
    private var published: (status: PlayerStatus, position: Duration)?

    func attach(_ transport: TransportModel, skipForward: Int, skipBackward: Int) {
        detach()
        self.transport = transport
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { $0.play() }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.playPause() }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackward)]
        // The Remote app's buttons name their own interval (its "10" skips 10 s), so honour it.
        addSkip(center.skipForwardCommand, sign: 1)
        addSkip(center.skipBackwardCommand, sign: -1)
        let seek = center.changePlaybackPositionCommand
        targets.append((seek, seek.addTarget { [weak self] event in
            guard let self, let transport = self.transport,
                let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            transport.seek(to: .milliseconds(Int(event.positionTime * 1000)))
            return .success
        }))
        published = nil
        update()
    }

    /// Whether a transport is attached (the iPhone player detaches while in the background).
    var isAttached: Bool { transport != nil }

    func detach() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        transport = nil
        published = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Call when the session's snapshot changes. Publishes on a change of status or a jump in
    /// position; the system moves the elapsed time on by itself in between, from the rate.
    func update() {
        guard let transport else { return }
        let snapshot = transport.session.snapshot
        let jump = snapshot.position - (published?.position ?? .zero)
        if let published, published.status == snapshot.status, jump < .seconds(2), jump > .seconds(-2) {
            self.published = (snapshot.status, snapshot.position)
            return
        }
        published = (snapshot.status, snapshot.position)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: Labels.episodeTitle(transport.recording),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Self.seconds(snapshot.position),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if Labels.episodeTitle(transport.recording) != transport.recording.title {
            info[MPMediaItemPropertyArtist] = transport.recording.title
        }
        if let duration = transport.duration {
            info[MPMediaItemPropertyPlaybackDuration] = Self.seconds(duration)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (TransportModel) -> Void) {
        targets.append((command, command.addTarget { [weak self] _ in
            guard let transport = self?.transport else { return .noActionableNowPlayingItem }
            action(transport)
            return .success
        }))
    }

    private func addSkip(_ command: MPSkipIntervalCommand, sign: Int) {
        targets.append((command, command.addTarget { [weak self] event in
            guard let transport = self?.transport else { return .noActionableNowPlayingItem }
            if let event = event as? MPSkipIntervalCommandEvent, event.interval > 0 {
                transport.skip(by: .milliseconds(sign * Int(event.interval * 1000)))
            } else if sign > 0 {
                transport.skipForward()
            } else {
                transport.skipBackward()
            }
            return .success
        }))
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
