import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

/// SPEC 6.4 "Episode detail rules": Delete on the episode page (owner, 2026-11-15).
@MainActor
@Suite("EpisodeDetailModel delete")
struct EpisodeDetailDeleteTests {
    let recording = episode(1)
    let adapter: FakeBackendAdapter
    let log = ChangeLog()
    let model: EpisodeDetailModel

    init() {
        adapter = FakeBackendAdapter(recordings: [episode(1), episode(2)])
        let log = self.log
        model = EpisodeDetailModel(
            recording: episode(1), state: adapter.playbackState, recordings: adapter.recordings,
            onChange: { log.record($0) })
    }

    var fake: FakeRecordingsService { adapter.recordingsFake }

    @Test func beforeADeleteThePageIsNeitherDeletingNorDeleted() {
        #expect(!model.isDeleting)
        #expect(!model.isDeleted)
    }

    @Test(arguments: [false, true])
    func deleteSendsOneDeleteWithTheRerecordChoice(_ allowRerecord: Bool) async {
        await model.delete(allowRerecord: allowRerecord).value
        #expect(fake.calls == [.delete(rid(1), allowRerecord: allowRerecord)])
    }

    @Test func aSecondDeleteJoinsTheFirstAndItsChoiceStands() async throws {
        fake.suspend(.delete)
        let first = model.delete(allowRerecord: true)
        try await fake.waitForParked(1, of: .delete)
        let second = model.delete(allowRerecord: false)
        fake.releaseAll()
        await first.value
        await second.value
        #expect(fake.calls == [.delete(rid(1), allowRerecord: true)])
    }

    @Test func whileTheDeleteIsInFlightThePageIsDeletingButNotYetDeleted() async throws {
        fake.suspend(.delete)
        let task = model.delete(allowRerecord: false)
        try await fake.waitForParked(1, of: .delete)
        #expect(model.isDeleting)
        #expect(!model.isDeleted)
        #expect(log.changes.isEmpty)
        fake.releaseAll()
        await task.value
        #expect(!model.isDeleting)
    }

    @Test func aSuccessfulDeleteMarksThePageDeletedAndReportsTheChange() async {
        await model.delete(allowRerecord: false).value
        #expect(model.isDeleted)
        #expect(!model.isDeleting)
        #expect(model.problem == nil)
        #expect(log.changes == [.deleted(rid(1))])
    }

    @Test func aFailedDeleteKeepsThePageAndSaysWhyInPlainEnglish() async {
        fake.failNext(.rejected("DIAG"), on: .delete)
        await model.delete(allowRerecord: false).value
        #expect(!model.isDeleted)
        #expect(!model.isDeleting)
        #expect(model.problem == UserMessage(.rejected("DIAG")))
        #expect(log.changes.isEmpty)
    }

    @Test func aSecondDeleteWhileOneIsInFlightSendsNothing() async throws {
        fake.suspend(.delete)
        let first = model.delete(allowRerecord: false)
        try await fake.waitForParked(1, of: .delete)
        let second = model.delete(allowRerecord: false)
        fake.releaseAll()
        await first.value
        await second.value
        #expect(fake.calls == [.delete(rid(1), allowRerecord: false)])
        #expect(log.changes == [.deleted(rid(1))])
    }

    @Test func deleteAfterASuccessfulDeleteSendsNothing() async {
        await model.delete(allowRerecord: false).value
        await model.delete(allowRerecord: false).value
        #expect(fake.calls.count == 1)
    }

    @Test func aDeleteAfterAFailureTriesAgainAndClearsTheProblemWhenItStarts() async throws {
        fake.failNext(.timedOut, on: .delete)
        await model.delete(allowRerecord: false).value
        #expect(model.problem != nil)
        fake.suspend(.delete)
        let task = model.delete(allowRerecord: false)
        #expect(model.problem == nil)
        try await fake.waitForParked(1, of: .delete)
        fake.releaseAll()
        await task.value
        #expect(model.isDeleted)
        #expect(fake.calls.count == 2)
    }

    @Test func cancellingTheCallerDoesNotCancelTheDelete() async throws {
        fake.suspend(.delete)
        let caller = Task { await model.delete(allowRerecord: false).value }
        try await fake.waitForParked(1, of: .delete)
        caller.cancel()
        fake.releaseAll()
        await caller.value
        #expect(model.isDeleted)
        #expect(log.changes == [.deleted(rid(1))])
    }

    @Test func aDeleteProblemIsClearedByTheNextLoadToo() async {
        fake.failNext(.timedOut, on: .delete)
        await model.delete(allowRerecord: false).value
        await model.load()
        #expect(model.problem == nil)
    }

    // MARK: Offer to delete after playback (M5-1, owner 2026-11-16)

    private func outcome(reachedEnd: Bool) -> PlaybackOutcome {
        PlaybackOutcome(position: .seconds(60), reachedEnd: reachedEnd, markedWatched: reachedEnd)
    }

    @Test func nothingIsOfferedBeforePlayback() {
        #expect(!model.offersDelete)
    }

    @Test func playbackThatReachedTheEndOffersADelete() {
        model.playbackFinished(outcome(reachedEnd: true))
        #expect(model.offersDelete)
        #expect(fake.calls.isEmpty)
    }

    @Test func playbackThatStoppedEarlyOffersNothing() {
        model.playbackFinished(outcome(reachedEnd: false))
        #expect(!model.offersDelete)
    }

    @Test func decliningTheOfferClearsIt() {
        model.playbackFinished(outcome(reachedEnd: true))
        model.dismissDeleteOffer()
        #expect(!model.offersDelete)
        #expect(fake.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func deletingClearsTheOfferAndSendsTheChoice(_ allowRerecord: Bool) async {
        model.playbackFinished(outcome(reachedEnd: true))
        let task = model.delete(allowRerecord: allowRerecord)
        #expect(!model.offersDelete)
        await task.value
        #expect(fake.calls == [.delete(rid(1), allowRerecord: allowRerecord)])
    }

    @Test func aLaterPlaybackThatStoppedEarlyWithdrawsTheOffer() {
        model.playbackFinished(outcome(reachedEnd: true))
        model.playbackFinished(outcome(reachedEnd: false))
        #expect(!model.offersDelete)
    }

    @Test func nothingIsOfferedOnceDeleted() async {
        await model.delete(allowRerecord: false).value
        model.playbackFinished(outcome(reachedEnd: true))
        #expect(!model.offersDelete)
    }

    @Test func nothingIsOfferedWhileADeleteIsInFlight() async throws {
        fake.suspend(.delete)
        let task = model.delete(allowRerecord: false)
        try await fake.waitForParked(1, of: .delete)
        model.playbackFinished(outcome(reachedEnd: true))
        #expect(!model.offersDelete)
        fake.releaseAll()
        await task.value
    }
}
