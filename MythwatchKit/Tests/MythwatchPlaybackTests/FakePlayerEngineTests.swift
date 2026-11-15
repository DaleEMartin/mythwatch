import Foundation
import MythwatchPlayback
import MythwatchTestSupport
import Testing

private let url = URL(string: "http://fake-backend:6544/fake/stream/1")!

/// Collects what a consumer task receives, in order.
@MainActor private final class Received {
    var snapshots: [PlayerSnapshot] = []
}

/// One consumer reading the engine's stream, as `PlaybackSession` will.
@MainActor private func consume(_ engine: FakePlayerEngine, into received: Received) -> Task<Void, Never> {
    let stream = engine.snapshots
    return Task { @MainActor in
        for await s in stream { received.snapshots.append(s) }
    }
}

@MainActor @Suite struct FakePlayerEngineTests {
    // MARK: call log

    @Test func callLogRecordsEveryCallWithArgumentsInOrder() {
        let e = FakePlayerEngine()
        e.load(url: url, startAt: .seconds(30))
        e.play()
        e.seek(to: .seconds(60))
        e.pause()
        e.stop()
        e.load(url: url, startAt: nil)
        #expect(
            e.calls == [
                .load(url: url, startAt: .seconds(30)), .play, .seek(to: .seconds(60)), .pause, .stop,
                .load(url: url, startAt: nil),
            ])
    }

    @Test func startsIdleWithNoCalls() {
        let e = FakePlayerEngine()
        #expect(e.calls.isEmpty)
        #expect(e.snapshot == PlayerSnapshot(status: .idle, position: .zero, duration: nil, rate: 0))
    }

    // MARK: automatic responses

    @Test func loadGoesToLoadingAtStartPositionAndEmits() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.load(url: url, startAt: .seconds(30))
        #expect(e.snapshot.status == .loading)
        #expect(e.snapshot.position == .seconds(30))
        await e.waitUntilDelivered()
        #expect(r.snapshots == [e.snapshot])
        e.finish()
        await t.value
    }

    @Test func loadWithoutStartPointStartsAtZero() {
        let e = FakePlayerEngine()
        e.setPosition(.seconds(99))
        e.load(url: url, startAt: nil)
        #expect(e.snapshot.position == .zero)
    }

    @Test func loadKeepsAConfiguredDuration() {
        let e = FakePlayerEngine()
        e.setDuration(.seconds(600))
        e.load(url: url, startAt: nil)
        #expect(e.snapshot.duration == .seconds(600))
    }

    @Test func playPauseStopGoToTheirStatusesAndEmit() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.load(url: url, startAt: nil)
        e.play()
        #expect(e.snapshot.status == .playing)
        #expect(e.snapshot.rate == 1)
        e.pause()
        #expect(e.snapshot.status == .paused)
        #expect(e.snapshot.rate == 0)
        e.stop()
        #expect(e.snapshot.status == .idle)
        #expect(e.snapshot.position == .zero)
        await e.waitUntilDelivered()
        #expect(r.snapshots.map(\.status) == [.loading, .playing, .paused, .idle])
        e.finish()
        await t.value
    }

    @Test func seekUpdatesPositionImmediatelyAndEmitsWithoutChangingStatus() async {
        let e = FakePlayerEngine()
        e.load(url: url, startAt: nil)
        e.play()
        let r = Received()
        let t = consume(e, into: r)
        e.seek(to: .seconds(120))
        #expect(e.snapshot.position == .seconds(120))
        #expect(e.snapshot.status == .playing)
        await e.waitUntilDelivered()
        #expect(r.snapshots.last?.position == .seconds(120))
        e.finish()
        await t.value
    }

    @Test func automaticResponsesOffOnlyLogsAndEmitsNothing() async {
        let e = FakePlayerEngine()
        e.automaticResponses = false
        let r = Received()
        let t = consume(e, into: r)
        e.load(url: url, startAt: .seconds(5))
        e.play()
        e.seek(to: .seconds(50))
        e.pause()
        e.stop()
        #expect(e.calls.count == 5)
        #expect(e.snapshot == PlayerSnapshot(status: .idle, position: .zero, duration: nil, rate: 0))
        await e.waitUntilDelivered()
        #expect(r.snapshots.isEmpty)
        // The test then plays the engine by hand, e.g. a stale position after a seek.
        e.emit(PlayerSnapshot(status: .playing, position: .seconds(3), duration: nil, rate: 1))
        await e.waitUntilDelivered()
        #expect(r.snapshots.count == 1)
        e.finish()
        await t.value
    }

    // MARK: emit and convenience emitters

    @Test func emitSetsSnapshotAndDeliversIt() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        let s = PlayerSnapshot(status: .buffering, position: .seconds(7), duration: .seconds(70), rate: 0)
        e.emit(s)
        #expect(e.snapshot == s)
        await e.waitUntilDelivered()
        #expect(r.snapshots == [s])
        e.finish()
        await t.value
    }

    @Test func emitOfAnUnchangedSnapshotIsStillDelivered() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        let s = e.snapshot
        e.emit(s)
        e.emit(s)
        await e.waitUntilDelivered()
        #expect(r.snapshots == [s, s])
        e.finish()
        await t.value
    }

    @Test func advancePlaybackMovesPositionOnlyWhilePlaying() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.advancePlayback(by: .seconds(5))  // idle: nothing happens
        #expect(e.snapshot.position == .zero)
        e.load(url: url, startAt: .seconds(10))
        e.play()
        e.advancePlayback(by: .seconds(2))
        e.advancePlayback(by: .milliseconds(250))
        #expect(e.snapshot.position == .milliseconds(12250))
        e.pause()
        e.advancePlayback(by: .seconds(5))
        #expect(e.snapshot.position == .milliseconds(12250))
        await e.waitUntilDelivered()
        #expect(r.snapshots.map(\.position) == [.seconds(10), .seconds(10), .seconds(12), .milliseconds(12250), .milliseconds(12250)])
        e.finish()
        await t.value
    }

    @Test func setStatusSetsOnlyTheStatusAndEmits() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.setPosition(.seconds(4))
        e.setStatus(.buffering)
        #expect(e.snapshot.status == .buffering)
        #expect(e.snapshot.position == .seconds(4))
        await e.waitUntilDelivered()
        #expect(r.snapshots.count == 2)
        e.finish()
        await t.value
    }

    @Test func setDurationSetsOnlyTheDurationAndEmits() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.setDuration(.seconds(1800))
        #expect(e.snapshot.duration == .seconds(1800))
        #expect(e.snapshot.status == .idle)
        e.setDuration(nil)
        #expect(e.snapshot.duration == nil)
        await e.waitUntilDelivered()
        #expect(r.snapshots.map(\.duration) == [.seconds(1800), nil])
        e.finish()
        await t.value
    }

    @Test func emitEndedMovesToTheEndWhenDurationIsKnown() async {
        let e = FakePlayerEngine()
        e.setDuration(.seconds(100))
        e.setPosition(.seconds(40))
        e.emitEnded()
        #expect(e.snapshot.status == .ended)
        #expect(e.snapshot.position == .seconds(100))
        let f = FakePlayerEngine()
        f.setPosition(.seconds(40))
        f.emitEnded()
        #expect(f.snapshot.status == .ended)
        #expect(f.snapshot.position == .seconds(40))
    }

    @Test func emitFailedCarriesTheMessage() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.emitFailed("boom")
        #expect(e.snapshot.status == .failed("boom"))
        await e.waitUntilDelivered()
        #expect(r.snapshots.last?.status == .failed("boom"))
        e.finish()
        await t.value
    }

    // MARK: the stream

    @Test func oneConsumerSeesEveryEmissionInOrderAcrossABurst() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        let n = 500
        for i in 0..<n {
            e.emit(PlayerSnapshot(status: .playing, position: .milliseconds(i), duration: nil, rate: 1))
        }
        await e.waitUntilDelivered()
        #expect(r.snapshots.count == n)
        #expect(r.snapshots.map(\.position) == (0..<n).map { .milliseconds($0) })
        e.finish()
        await t.value
    }

    @Test func emissionsBeforeSubscribingAreBufferedNotLost() async {
        let e = FakePlayerEngine()
        e.load(url: url, startAt: nil)
        e.play()
        let r = Received()
        let t = consume(e, into: r)
        await e.waitUntilDelivered()
        #expect(r.snapshots.map(\.status) == [.loading, .playing])
        e.finish()
        await t.value
    }

    @Test func readingSnapshotsTwiceReturnsTheSameStream() async {
        let e = FakePlayerEngine()
        var first = e.snapshots.makeAsyncIterator()
        var second = e.snapshots.makeAsyncIterator()
        e.setPosition(.seconds(1))
        e.setPosition(.seconds(2))
        // Both iterators read one underlying stream: they share elements, not each get a copy.
        let a = await first.next()
        let b = await second.next()
        #expect(a?.position == .seconds(1))
        #expect(b?.position == .seconds(2))
    }

    @Test func finishEndsTheStreamAfterBufferedElementsAreDrained() async {
        let e = FakePlayerEngine()
        e.setPosition(.seconds(1))
        e.finish()
        var it = e.snapshots.makeAsyncIterator()
        #expect(await it.next()?.position == .seconds(1))
        #expect(await it.next() == nil)
        // Emitting after finish still updates `snapshot` but delivers nothing.
        e.setPosition(.seconds(2))
        #expect(e.snapshot.position == .seconds(2))
        #expect(await it.next() == nil)
    }

    @Test func finishEndsAConsumerThatIsWaiting() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.setPosition(.seconds(1))
        await e.waitUntilDelivered()
        e.finish()
        await t.value
        #expect(r.snapshots.count == 1)
    }

    @Test func streamEndsWhenTheFakeIsDeallocated() async {
        var e: FakePlayerEngine? = FakePlayerEngine()
        let stream = e!.snapshots
        weak let weakEngine = e
        e = nil
        #expect(weakEngine == nil)
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == nil)
    }

    @Test func deallocationEndsAConsumerThatIsWaiting() async {
        var e: FakePlayerEngine? = FakePlayerEngine()
        let stream = e!.snapshots
        let done = Received()
        let t = Task { @MainActor in
            for await s in stream { done.snapshots.append(s) }
        }
        e!.setPosition(.seconds(1))
        await e!.waitUntilDelivered()
        e = nil
        await t.value
        #expect(done.snapshots.count == 1)
    }

    @Test func cancellingTheConsumerEndsItsLoop() async {
        let e = FakePlayerEngine()
        let r = Received()
        let t = consume(e, into: r)
        e.setPosition(.seconds(1))
        await e.waitUntilDelivered()
        t.cancel()
        await t.value
        #expect(r.snapshots.count == 1)
    }

    // MARK: deterministic wait

    @Test func waitUntilDeliveredReturnsAtOnceWhenNothingWasEmitted() async {
        let e = FakePlayerEngine()
        await e.waitUntilDelivered()
    }

    @Test func waitUntilDeliveredCoversTheConsumersProcessingOfTheLastSnapshot() async {
        let e = FakePlayerEngine()
        // The loop body runs to completion before the consumer asks for the next snapshot, so
        // when the wait returns the body has finished for everything emitted so far.
        let r = Received()
        let t = Task { @MainActor in
            for await s in e.snapshots {
                r.snapshots.append(s)
                r.snapshots.append(s)  // a second step in the same body
            }
        }
        e.setPosition(.seconds(1))
        e.setPosition(.seconds(2))
        await e.waitUntilDelivered()
        #expect(r.snapshots.count == 4)
        e.setPosition(.seconds(3))
        await e.waitUntilDelivered()
        #expect(r.snapshots.count == 6)
        e.finish()
        await t.value
    }

    @Test func waitUntilDeliveredCanBeCancelled() async {
        let e = FakePlayerEngine()
        e.setPosition(.seconds(1))  // no consumer: this can never be delivered
        let waiter = Task { @MainActor in await e.waitUntilDelivered() }
        waiter.cancel()
        await waiter.value
    }

    // MARK: tracks

    @Test func trackListsAreSettable() {
        let e = FakePlayerEngine()
        let en = MediaTrack(id: 1, name: "English", language: "eng")
        let fr = MediaTrack(id: 2, name: "French", language: "fra")
        #expect(e.audioTracks.isEmpty && e.subtitleTracks.isEmpty)
        e.audioTracks = [en, fr]
        e.subtitleTracks = [fr]
        #expect(e.audioTracks == [en, fr])
        #expect(e.subtitleTracks == [fr])
        #expect(e.calls.isEmpty)  // setting the lists is not a call
    }

    @Test func selectingTracksIsStoredAndLogged() {
        let e = FakePlayerEngine()
        #expect(e.selectedAudioTrack == nil)
        #expect(e.selectedSubtitleTrack == nil)
        e.selectedAudioTrack = 2
        e.selectedSubtitleTrack = 5
        e.selectedSubtitleTrack = nil
        #expect(e.selectedAudioTrack == 2)
        #expect(e.selectedSubtitleTrack == nil)
        #expect(e.calls == [.selectAudioTrack(2), .selectSubtitleTrack(5), .selectSubtitleTrack(nil)])
    }

    @Test func selectingTracksEmitsNoSnapshot() async {
        let e = FakePlayerEngine()
        e.selectedAudioTrack = 1
        await e.waitUntilDelivered()  // nothing emitted, returns at once
        #expect(e.snapshot.status == .idle)
    }
}
