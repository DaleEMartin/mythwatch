// The only file that imports VLCKit (SPEC 7). It must use nothing tvOS-only, so the iPhone app
// can share it (SPEC 11).
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif
import Foundation
import MythwatchPlayback
import UIKit

/// `PlayerEngine` over VLCKit 3.7.4 (SPEC 5 "Engine rules", 7, `docs/VLCKIT.md`).
///
/// Every decision is `PlayerEventMachine`'s: this class turns VLC's events into its inputs,
/// emits the snapshots it says to, and carries out its commands (measure the file's size with a
/// 1-byte range GET, reopen a recording that is still growing). One engine serves one playback;
/// `snapshots` finishes when the engine is released.
final class VLCPlayerEngine: NSObject, PlayerEngine {
    /// The view VLC draws into. The player screen (M3-4) puts it on screen.
    let videoView: UIView

    let snapshots: AsyncStream<PlayerSnapshot>
    var snapshot: PlayerSnapshot { machine.snapshot }

    private let player = VLCMediaPlayer()
    private let deinterlace: Bool
    private let sizeSession: URLSession
    private let continuation: AsyncStream<PlayerSnapshot>.Continuation
    private var machine = PlayerEventMachine()
    private var url: URL?
    /// Bumped by every `load`, so a size answer for earlier media is dropped.
    private var generation = 0

    /// `deinterlace` is `AppSettings.deinterlace` at the moment playback starts: `bob` when true
    /// (60 fps, no measurable cost on Apple TV HD), none when false. Never `yadif`.
    init(deinterlace: Bool, sizeSession: URLSession = .shared) {
        self.deinterlace = deinterlace
        self.sizeSession = sizeSession
        (snapshots, continuation) = AsyncStream.makeStream(of: PlayerSnapshot.self, bufferingPolicy: .unbounded)
        videoView = UIView()
        videoView.backgroundColor = .black
        super.init()
        player.delegate = self
        player.drawable = videoView
    }

    deinit {
        continuation.finish()
    }

    // MARK: PlayerEngine

    func load(url: URL, startAt: Duration?) {
        generation += 1
        self.url = url
        // The machine must know about the load before VLC can report on the new media: an
        // unreachable host gives Opening and Error at once.
        handle(.load(startAt: startAt))
        open(url, at: startAt)
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to position: Duration) {
        player.time = VLCTime(int: Int32(clamping: Self.milliseconds(position)))
        handle(.seekRequested(position))
    }

    func stop() {
        generation += 1
        player.stop()
        handle(.stopRequested)
    }

    var audioTracks: [MediaTrack] {
        PlayerEventMachine.tracks(names: Self.strings(player.audioTrackNames), ids: Self.ints(player.audioTrackIndexes))
    }

    var subtitleTracks: [MediaTrack] {
        PlayerEventMachine.tracks(
            names: Self.strings(player.videoSubTitlesNames), ids: Self.ints(player.videoSubTitlesIndexes))
    }

    var selectedAudioTrack: MediaTrack.ID? {
        get { player.currentAudioTrackIndex < 0 ? nil : Int(player.currentAudioTrackIndex) }
        set { player.currentAudioTrackIndex = Int32(newValue ?? -1) }
    }

    /// nil = off (VLC's -1, "Disable").
    var selectedSubtitleTrack: MediaTrack.ID? {
        get { player.currentVideoSubTitleIndex < 0 ? nil : Int(player.currentVideoSubTitleIndex) }
        set { player.currentVideoSubTitleIndex = Int32(newValue ?? -1) }
    }

    // MARK: The machine

    private func handle(_ input: PlayerEventMachine.Input) {
        let output = machine.handle(input)
        if output.emit { continuation.yield(machine.snapshot) }
        for command in output.commands { perform(command) }
    }

    private func perform(_ command: PlayerEventMachine.Command) {
        guard let url else { return }
        let generation = self.generation
        switch command {
        case .measureOpenedSize:
            Task { [weak self, sizeSession] in
                let size = await Self.fileSize(of: url, session: sizeSession)
                guard let self, self.generation == generation else { return }
                self.handle(.openedSize(size))
            }
        case .checkCurrentSize:
            Task { [weak self, sizeSession] in
                let size = await Self.fileSize(of: url, session: sizeSession)
                guard let self, self.generation == generation else { return }
                self.handle(.currentSize(size))
            }
        case .reopen(let position):
            open(url, at: position)
            player.play()
        }
    }

    /// Sets new media on the player with the options every MythTV recording needs.
    private func open(_ url: URL, at startAt: Duration?) {
        let media = VLCMedia(url: url)
        // VLC's own MPEG-TS demuxer cannot find the length of, or seek in, these files over HTTP.
        media.addOption(":demux=avformat")
        if let startAt, startAt > .zero {
            media.addOption(":start-time=\(Double(Self.milliseconds(startAt)) / 1000)")
        }
        player.media = media
        player.setDeinterlaceFilter(deinterlace ? "bob" : nil)  // after the media is set
    }

    // MARK: VLC events (VLCKit delivers them on the main thread, VLCKIT.md §6)

    fileprivate func stateChanged() {
        switch player.state {
        case .playing: handle(.playerPlaying)
        case .paused: handle(.playerPaused)
        case .buffering: handle(.playerBuffering(isPlaying: player.isPlaying))
        case .ended: handle(.playerEnded)
        case .error: handle(.playerError)
        case .stopped: handle(.playerStopped)
        case .opening, .esAdded: break
        @unknown default: break
        }
    }

    fileprivate func timeChanged() {
        let length = player.media?.length.intValue ?? 0
        handle(.playerPosition(
            .milliseconds(Int(player.time.intValue)), duration: length > 0 ? .milliseconds(Int(length)) : nil))
    }

    // MARK: Helpers

    /// The file's total size from a 1-byte range GET (`Content-Range: bytes 0-0/<total>`), or nil.
    private nonisolated static func fileSize(of url: URL, session: URLSession) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
            let total = range.split(separator: "/").last, let size = Int64(total)
        {
            return size
        }
        if http.statusCode == 200, http.expectedContentLength > 0 { return http.expectedContentLength }
        return nil
    }

    private static func milliseconds(_ d: Duration) -> Int64 {
        d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
    }

    private static func strings(_ array: [Any]) -> [String] { array.map { "\($0)" } }
    private static func ints(_ array: [Any]) -> [Int] { array.map { ($0 as? NSNumber)?.intValue ?? -1 } }
}

extension VLCPlayerEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { stateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { timeChanged() }
    }
}
