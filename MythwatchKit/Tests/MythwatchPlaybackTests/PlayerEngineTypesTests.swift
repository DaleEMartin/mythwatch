import Foundation
import MythwatchPlayback
import Testing

/// Pins the shape of the `PlayerEngine` declarations (SPEC §5) until M3-1 adds the fake. If a
/// requirement changes, this stops compiling.
@MainActor
private final class ShapeCheckEngine: PlayerEngine {
    var snapshot = PlayerSnapshot(status: .idle, position: .zero, duration: nil, rate: 0)
    var snapshots: AsyncStream<PlayerSnapshot> { AsyncStream { $0.finish() } }
    func load(url: URL, startAt: Duration?) {}
    func play() {}
    func pause() {}
    func seek(to position: Duration) {}
    func stop() {}
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudioTrack: MediaTrack.ID?
    var selectedSubtitleTrack: MediaTrack.ID?
}

@Suite struct PlayerEngineTypesTests {
    @Test func snapshotMemberwiseInitialiserAndEquality() {
        let a = PlayerSnapshot(status: .playing, position: .seconds(5), duration: .seconds(60), rate: 1)
        #expect(a.status == .playing)
        #expect(a.position == .seconds(5))
        #expect(a.duration == .seconds(60))
        #expect(a.rate == 1)
        #expect(a == PlayerSnapshot(status: .playing, position: .seconds(5), duration: .seconds(60), rate: 1))
        var b = a
        b.position = .seconds(6)
        #expect(a != b)
    }

    @Test func statusEqualityIncludesTheFailureText() {
        #expect(PlayerStatus.failed("a") == .failed("a"))
        #expect(PlayerStatus.failed("a") != .failed("b"))
        #expect(PlayerStatus.paused != .buffering)
    }

    @Test func mediaTrackIsIdentifiedByItsID() {
        let track = MediaTrack(id: 2, name: "English", language: "eng")
        #expect(track.id == 2)
        #expect(track.name == "English")
        #expect(track.language == "eng")
        #expect(Set([track, MediaTrack(id: 2, name: "English", language: "eng")]).count == 1)
    }

    @MainActor @Test func anEngineCanBeUsedThroughTheProtocol() {
        let engine: any PlayerEngine = ShapeCheckEngine()
        engine.selectedSubtitleTrack = 3
        #expect(engine.selectedSubtitleTrack == 3)
        #expect(engine.snapshot.status == .idle)
    }
}
