import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

/// The player screen's view of the engine through the session (M3-4, SPEC 5.2 "Screen access").
@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionTrackTests {
    private let english = MediaTrack(id: 1, name: "English", language: "English")
    private let spanish = MediaTrack(id: 2, name: "Spanish", language: "Spanish")
    private let captions = MediaTrack(id: 3, name: "Track 1", language: nil)

    @Test func theEngineIsTheOneTheSessionWasGiven() {
        let rig = SessionRig()
        #expect(rig.session.engine === rig.engine)
    }

    @Test func tracksAreTheEngines() async {
        let rig = SessionRig()
        rig.engine.audioTracks = [english, spanish]
        rig.engine.subtitleTracks = [captions]
        rig.engine.selectedAudioTrack = 1
        await rig.playing(at: .seconds(20))
        #expect(rig.session.audioTracks == [english, spanish])
        #expect(rig.session.subtitleTracks == [captions])
        #expect(rig.session.selectedAudioTrack == 1)
        #expect(rig.session.selectedSubtitleTrack == nil)
    }

    @Test func selectingTracksReachesTheEngineWhileActive() async {
        let rig = SessionRig()
        rig.engine.audioTracks = [english, spanish]
        rig.engine.subtitleTracks = [captions]
        await rig.playing(at: .seconds(20))
        let before = rig.engine.calls.count

        rig.session.selectAudioTrack(2)
        rig.session.selectSubtitleTrack(3)
        rig.session.selectSubtitleTrack(nil)

        #expect(rig.engineCalls(after: before) == [
            .selectAudioTrack(2), .selectSubtitleTrack(3), .selectSubtitleTrack(nil),
        ])
        #expect(rig.session.selectedAudioTrack == 2)
        #expect(rig.session.selectedSubtitleTrack == nil)
    }

    @Test func selectingTracksBeforeStartOrAfterFinishDoesNothing() async {
        let rig = SessionRig()
        rig.session.selectAudioTrack(2)
        rig.session.selectSubtitleTrack(3)
        #expect(rig.engine.calls.isEmpty)

        await rig.playing(at: .seconds(20))
        _ = await rig.finish()
        let before = rig.engine.calls.count
        rig.session.selectAudioTrack(2)
        rig.session.selectSubtitleTrack(3)
        #expect(rig.engineCalls(after: before).isEmpty)
    }
}

/// `skip(by:)`: a skip of a given length, for remote commands that carry their own interval (M3-4).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionSkipByTests {
    @Test func skipsByTheGivenAmountEitherWay() async {
        let rig = SessionRig()
        await rig.playing(at: .seconds(100))
        rig.session.skip(by: .seconds(10))
        rig.session.skip(by: .seconds(-25))
        #expect(rig.seeks == [.seconds(110), .seconds(85)])  // adds up from the pending target
    }

    @Test func clampsToTheRecording() async {
        let rig = SessionRig()
        await rig.playing(at: .seconds(5), duration: .seconds(60))
        rig.session.skip(by: .seconds(-10))
        rig.session.skip(by: .seconds(600))
        #expect(rig.seeks == [.zero, .seconds(60)])
    }

    @Test func beforeStartDoesNothing() {
        let rig = SessionRig()
        rig.session.skip(by: .seconds(10))
        #expect(rig.engine.calls.isEmpty)
    }
}
