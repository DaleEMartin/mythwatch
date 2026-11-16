import Foundation
import MythwatchPlayback
import Testing

/// SPEC 5 "Engine rules", as the pure state machine `VLCPlayerEngine` drives (M3-3).
@Suite("PlayerEventMachine")
struct PlayerEventMachineTests {
    var m = PlayerEventMachine()

    /// Feeds inputs, returning every snapshot emitted and every command, in order.
    @discardableResult
    mutating func feed(_ inputs: PlayerEventMachine.Input...) -> (snapshots: [PlayerSnapshot], commands: [PlayerEventMachine.Command]) {
        var snapshots: [PlayerSnapshot] = []
        var commands: [PlayerEventMachine.Command] = []
        for input in inputs {
            let out = m.handle(input)
            if out.emit { snapshots.append(m.snapshot) }
            commands += out.commands
        }
        return (snapshots, commands)
    }

    var status: PlayerStatus { m.snapshot.status }
    var position: Duration { m.snapshot.position }

    /// Loaded at 600 s, VLC playing, first real position at 600 s of a 3600 s recording.
    mutating func running() {
        feed(.load(startAt: .seconds(600)), .openedSize(1_000), .playerPlaying,
             .playerPosition(.seconds(600), duration: .seconds(3600)))
    }

    // MARK: Start

    @Test mutating func startsIdle() {
        #expect(m.snapshot == PlayerSnapshot(status: .idle, position: .zero, duration: nil, rate: 0))
    }

    @Test mutating func loadReportsLoadingAtTheStartPointAndAsksForTheFileSize() {
        let out = feed(.load(startAt: .seconds(1200)))
        #expect(out.snapshots == [PlayerSnapshot(status: .loading, position: .seconds(1200), duration: nil, rate: 0)])
        #expect(out.commands == [.measureOpenedSize])
    }

    @Test mutating func loadWithoutAStartPointIsAtZero() {
        feed(.load(startAt: nil))
        #expect(status == .loading)
        #expect(position == .zero)
    }

    @Test mutating func playingBeforeTheFirstPositionStaysLoadingAtTheStartPoint() {
        feed(.load(startAt: .seconds(1200)))
        let out = feed(.playerPlaying, .playerBuffering(isPlaying: false), .playerBuffering(isPlaying: true))
        #expect(out.snapshots.isEmpty)
        #expect(status == .loading)
        #expect(position == .seconds(1200))
    }

    @Test mutating func theFirstPositionStartsPlayingWithTheDuration() {
        feed(.load(startAt: .seconds(1200)), .playerPlaying)
        let out = feed(.playerPosition(.milliseconds(1_200_010), duration: .seconds(3600)))
        #expect(out.snapshots == [
            PlayerSnapshot(status: .playing, position: .milliseconds(1_200_010), duration: .seconds(3600), rate: 1),
        ])
    }

    @Test mutating func anUnknownDurationIsNotReportedAsZero() {
        feed(.load(startAt: nil), .playerPosition(.seconds(1), duration: nil))
        #expect(m.snapshot.duration == nil)
        feed(.playerPosition(.seconds(2), duration: .zero))
        #expect(m.snapshot.duration == nil)
    }

    // MARK: Rate and noise

    @Test mutating func everyPositionIsEmitted() {
        running()
        let out = feed(.playerPosition(.milliseconds(600_256), duration: .seconds(3600)),
                       .playerPosition(.milliseconds(600_512), duration: .seconds(3600)))
        #expect(out.snapshots.map(\.position) == [.milliseconds(600_256), .milliseconds(600_512)])
    }

    @Test mutating func bufferingWhilePlayingIsNoise() {
        running()
        let out = feed(.playerBuffering(isPlaying: true), .playerBuffering(isPlaying: true))
        #expect(out.snapshots.isEmpty)
        #expect(status == .playing)
    }

    @Test mutating func aRealStallIsBufferingOnceAndThePlayerPlayingAgainEndsIt() {
        running()
        let stall = feed(.playerBuffering(isPlaying: false), .playerBuffering(isPlaying: false))
        #expect(stall.snapshots.map(\.status) == [.buffering])
        #expect(stall.snapshots.first?.rate == 0)
        let back = feed(.playerPlaying)
        #expect(back.snapshots.map(\.status) == [.playing])
    }

    @Test mutating func aPositionAfterAStallIsPlayingAgain() {
        running()
        feed(.playerBuffering(isPlaying: false))
        feed(.playerPosition(.seconds(601), duration: .seconds(3600)))
        #expect(status == .playing)
    }

    // MARK: Pause

    @Test mutating func pausedKeepsThePositionAndAPlayingEventResumes() {
        running()
        let paused = feed(.playerPaused)
        #expect(paused.snapshots == [PlayerSnapshot(status: .paused, position: .seconds(600), duration: .seconds(3600), rate: 0)])
        #expect(feed(.playerBuffering(isPlaying: false)).snapshots.isEmpty)
        #expect(feed(.playerPlaying).snapshots.map(\.status) == [.playing])
    }

    @Test mutating func aPositionArrivingJustAfterPausingDoesNotUnpause() {
        running()
        feed(.playerPaused)
        feed(.playerPosition(.milliseconds(600_100), duration: .seconds(3600)))
        #expect(status == .paused)
        #expect(position == .milliseconds(600_100))
    }

    @Test mutating func pausingWhileLoadingIsPausedAtTheStartPoint() {
        feed(.load(startAt: .seconds(300)), .playerPaused)
        #expect(status == .paused)
        #expect(position == .seconds(300))
    }

    // MARK: Seek

    @Test mutating func aSeekIsReportedAtTheTargetAtOnceWithTheStatusUnchanged() {
        running()
        let out = feed(.seekRequested(.seconds(900)))
        #expect(out.snapshots == [PlayerSnapshot(status: .playing, position: .seconds(900), duration: .seconds(3600), rate: 1)])
    }

    @Test mutating func aSeekWhilePausedIsReportedToo() {
        running()
        feed(.playerPaused)
        let out = feed(.seekRequested(.seconds(30)))
        #expect(out.snapshots.map(\.position) == [.seconds(30)])
        #expect(status == .paused)
    }

    @Test mutating func aSeekWhileLoadingMovesTheHeldPosition() {
        feed(.load(startAt: .seconds(300)), .seekRequested(.seconds(400)), .playerPlaying)
        #expect(status == .loading)
        #expect(position == .seconds(400))
    }

    @Test mutating func aSeekBeforeLoadOrAfterTheEndIsIgnored() {
        #expect(feed(.seekRequested(.seconds(5))).snapshots.isEmpty)
        running()
        feed(.playerEnded, .currentSize(1_000))
        #expect(feed(.seekRequested(.seconds(5))).snapshots.isEmpty)
    }

    // MARK: End

    @Test mutating func theEndAsksWhetherTheFileHasGrownBeforeReportingAnything() {
        running()
        let out = feed(.playerEnded)
        #expect(out.commands == [.checkCurrentSize])
        #expect(status != .ended)
    }

    @Test mutating func aFileThatHasNotGrownEndsAtTheDuration() {
        running()
        feed(.playerPosition(.milliseconds(3_597_792), duration: .seconds(3600)), .playerEnded)
        let out = feed(.currentSize(1_000))
        #expect(out.snapshots == [PlayerSnapshot(status: .ended, position: .seconds(3600), duration: .seconds(3600), rate: 0)])
        #expect(out.commands.isEmpty)
    }

    @Test mutating func anEndWithoutADurationKeepsTheLastPosition() {
        feed(.load(startAt: nil), .openedSize(10), .playerPosition(.seconds(42), duration: nil), .playerEnded, .currentSize(10))
        #expect(status == .ended)
        #expect(position == .seconds(42))
    }

    @Test mutating func aGrowingFileIsReopenedAtTheLastPositionAndNeverEnds() {
        running()
        feed(.playerPosition(.seconds(1000), duration: .seconds(1000)), .playerEnded)
        let out = feed(.currentSize(2_000))
        #expect(out.commands == [.reopen(at: .seconds(1000))])
        #expect(status == .buffering)
        // VLC's own Stopped, then the reopened media playing again from the last position.
        let again = feed(.playerStopped, .playerPlaying, .playerPosition(.milliseconds(1_000_010), duration: .seconds(1200)))
        #expect(again.snapshots.last?.status == .playing)
        #expect(m.snapshot.duration == .seconds(1200))
        #expect(!again.snapshots.contains { $0.status == .ended })
    }

    @Test mutating func whileReopeningVLCsZeroPositionIsNeverReported() {
        running()
        feed(.playerPosition(.seconds(1000), duration: .seconds(1000)), .playerEnded, .currentSize(2_000))
        let out = feed(.playerPlaying, .playerBuffering(isPlaying: false))
        #expect(out.snapshots.isEmpty)
        #expect(position == .seconds(1000))
    }

    @Test mutating func aReopenedFileComparesWithTheSizeItWasReopenedAt() {
        running()
        feed(.playerPosition(.seconds(1000), duration: .seconds(1000)), .playerEnded, .currentSize(2_000))
        feed(.playerPlaying, .playerPosition(.seconds(1001), duration: .seconds(1200)), .playerEnded)
        let out = feed(.currentSize(2_000))
        #expect(status == .ended)
        #expect(out.commands.isEmpty)
    }

    @Test mutating func anEndRightAfterAReopenChecksAgainRatherThanFailing() {
        running()
        feed(.playerEnded, .currentSize(2_000))
        let out = feed(.playerEnded)
        #expect(out.commands == [.checkCurrentSize])
        if case .failed = status { Issue.record("a reopened file that ends at once is not a failure") }
    }

    @Test mutating func whenTheOpenedSizeIsUnknownTheEndIsTheEnd() {
        feed(.load(startAt: nil), .openedSize(nil), .playerPosition(.seconds(5), duration: .seconds(5)), .playerEnded)
        feed(.currentSize(9_999))
        #expect(status == .ended)
    }

    @Test mutating func aSizeCheckThatFailsIsAFailureNotAnEnd() {
        running()
        feed(.playerEnded)
        let out = feed(.currentSize(nil))
        guard case .failed = status else { Issue.record("expected .failed, got \(status)"); return }
        #expect(out.snapshots.last?.rate == 0)
    }

    @Test mutating func reachingTheEndBeforeAnyPositionIsAFailure() {
        // A backend 404 "plays" to its end: Opening, Playing, Ended, no position (VLCKIT.md §7.4).
        feed(.load(startAt: nil), .openedSize(nil), .playerPlaying)
        let out = feed(.playerEnded)
        guard case .failed = status else { Issue.record("expected .failed, got \(status)"); return }
        #expect(out.commands.isEmpty)
        #expect(feed(.currentSize(5)).snapshots.isEmpty)
    }

    // MARK: Failure and stop

    @Test mutating func aPlayerErrorIsAFailure() {
        feed(.load(startAt: nil))
        let out = feed(.playerError)
        #expect(out.snapshots.count == 1)
        guard case .failed(let message) = status else { Issue.record("expected .failed"); return }
        #expect(!message.isEmpty)
        #expect(feed(.playerStopped, .playerPosition(.seconds(1), duration: nil)).snapshots.isEmpty)
    }

    @Test mutating func stopIsIdleAtZeroKeepingTheDurationAndLaterEventsAreIgnored() {
        running()
        let out = feed(.stopRequested)
        #expect(out.snapshots == [PlayerSnapshot(status: .idle, position: .zero, duration: .seconds(3600), rate: 0)])
        #expect(feed(.playerStopped, .playerError, .playerEnded, .playerPosition(.seconds(3), duration: nil)).snapshots.isEmpty)
        #expect(status == .idle)
    }

    @Test mutating func aSecondLoadStartsAfresh() {
        running()
        feed(.playerEnded, .currentSize(1_000))
        let out = feed(.load(startAt: .seconds(10)))
        #expect(out.snapshots == [PlayerSnapshot(status: .loading, position: .seconds(10), duration: nil, rate: 0)])
        // The 404 rule applies again to the new media.
        feed(.playerEnded)
        if case .failed = status {} else { Issue.record("expected .failed") }
    }

    @Test mutating func aLateOpenedSizeFromAnEarlierLoadIsStillJustASize() {
        feed(.load(startAt: nil), .playerPosition(.seconds(1), duration: .seconds(2)), .openedSize(100), .playerEnded)
        #expect(feed(.currentSize(100)).snapshots.last?.status == .ended)
    }

    // MARK: Tracks

    @Test func trackListsDropDisableAndReadTheLanguage() {
        let tracks = PlayerEventMachine.tracks(
            names: ["Disable", "Track 1 - [English]", "Track 2 - [Spanish]", "Closed captions 1"],
            ids: [-1, 1, 2, 3])
        #expect(tracks == [
            MediaTrack(id: 1, name: "English", language: "English"),
            MediaTrack(id: 2, name: "Spanish", language: "Spanish"),
            MediaTrack(id: 3, name: "Closed captions 1", language: nil),
        ])
    }

    @Test func mismatchedTrackListsUseTheShorter() {
        #expect(PlayerEventMachine.tracks(names: ["Track 1"], ids: [1, 2]).map(\.id) == [1])
    }
}
