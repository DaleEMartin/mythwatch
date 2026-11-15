import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport
import Testing

@MainActor
@Suite("ShowViewModel")
struct ShowViewModelTests {
    let adapter: FakeBackendAdapter
    let log = ChangeLog()
    let model: ShowViewModel

    /// Season 1: episodes 1, 2 (id 1, 2). Season 2: episode 3 (id 3). Other: id 4 (no season).
    init(recordings: [Recording]? = nil) {
        let recs = recordings ?? [
            episode(1, season: 1), episode(2, season: 1), episode(3, season: 2),
            episode(4, season: nil, episode: nil),
        ]
        let adapter = FakeBackendAdapter(recordings: recs)
        self.adapter = adapter
        let show = LibraryBuilder.build(from: adapter.store.allRecordings).shows[0]
        let log = self.log
        model = ShowViewModel(show: show, recordings: adapter.recordings, onChange: { log.record($0) })
    }

    var fake: FakeRecordingsService { adapter.recordingsFake }

    func isWatched(_ n: Int) -> Bool? {
        model.seasons.flatMap(\.episodes).first { $0.id == rid(n) }?.flags.contains(.watched)
    }

    func ids(_ season: Season?) -> [Int] { season?.episodes.map(\.id.rawValue) ?? [] }

    // MARK: Seasons

    @Test func seasonsComeFromTheLibraryBuilderAndTheFirstOneIsSelected() {
        #expect(model.seasons == LibraryBuilder.seasons(of: model.show))
        #expect(model.seasons.map(\.title) == ["Season 1", "Season 2", "Other Episodes"])
        #expect(model.selectedSeason?.id == 1)
        #expect(ids(model.selectedSeason) == [1, 2])
        #expect(!model.isEmpty)
    }

    @Test func selectingASeasonChangesTheSelection() {
        model.select(season: model.seasons[1])
        #expect(ids(model.selectedSeason) == [3])
        model.select(season: model.seasons[2])
        #expect(model.selectedSeason?.title == "Other Episodes")
        #expect(model.selectedSeason?.id == nil)
    }

    @Test func selectingASeasonTheShowDoesNotHaveIsIgnored() {
        model.select(season: Season(id: 9, title: "Season 9", episodes: []))
        #expect(model.selectedSeason?.id == 1)
    }

    @Test func aShowWithOnlyUnnumberedEpisodesSelectsOtherEpisodes() {
        let h = ShowViewModelTests(recordings: [episode(1, season: nil, episode: nil)])
        #expect(h.model.selectedSeason?.title == "Other Episodes")
    }

    // MARK: toggleWatched

    @Test func toggleWatchedUpdatesLocalStateAtOnceAndKeepsItOnSuccess() async throws {
        fake.suspend(.setWatched)
        let ep = model.seasons[0].episodes[0]
        let task = model.toggleWatched(ep)
        #expect(isWatched(1) == true)  // before the call has even been made
        #expect(model.show.unwatchedCount == 3)
        try await fake.waitForParked()
        #expect(isWatched(1) == true)
        fake.releaseAll()
        await task.value
        #expect(isWatched(1) == true)
        #expect(fake.calls == [.setWatched(true, rid(1))])
        #expect(adapter.store.recording(id: rid(1))?.flags.contains(.watched) == true)
        #expect(model.problem == nil)
        #expect(log.changes == [.watched(rid(1), true)])
    }

    @Test func toggleWatchedOnAWatchedEpisodeMarksItUnwatched() async {
        let h = ShowViewModelTests(recordings: [episode(1, watched: true), episode(2)])
        await h.model.toggleWatched(h.model.seasons[0].episodes[0]).value
        #expect(h.isWatched(1) == false)
        #expect(h.fake.calls == [.setWatched(false, rid(1))])
        #expect(h.model.show.unwatchedCount == 2)
    }

    @Test func toggleWatchedRollsBackAndSaysWhyWhenTheCallFails() async throws {
        fake.failNext(.rejected("DIAG nope"), on: .setWatched)
        let ep = model.seasons[0].episodes[0]
        await model.toggleWatched(ep).value
        #expect(isWatched(1) == false)
        #expect(model.show.unwatchedCount == 4)
        #expect(model.problem == UserMessage(.rejected("DIAG nope")))
        #expect(model.problem?.title == "Your MythTV Backend Turned That Down")
        #expect(log.changes.isEmpty)
        model.dismissProblem()
        #expect(model.problem == nil)
    }

    @Test func theLocalStateIsOptimisticWhileAFailingCallIsStillInFlight() async throws {
        fake.suspend(.setWatched)
        let task = model.toggleWatched(model.seasons[0].episodes[0])
        try await fake.waitForParked()
        #expect(isWatched(1) == true)
        fake.releaseAll(throwing: .timedOut)
        await task.value
        #expect(isWatched(1) == false)
        #expect(model.problem == UserMessage(.timedOut))
    }

    @Test func aNewActionClearsTheOldProblem() async {
        fake.failNext(.timedOut)
        await model.toggleWatched(model.seasons[0].episodes[0]).value
        #expect(model.problem != nil)
        await model.toggleWatched(model.seasons[0].episodes[1]).value
        #expect(model.problem == nil)
    }

    @Test func twoQuickTogglesEndInTheRightStateAndAreSentOneAtATime() async throws {
        fake.suspendNext(.setWatched)
        let ep = model.seasons[0].episodes[0]
        let first = model.toggleWatched(ep)  // on
        try await fake.waitForParked()
        let second = model.toggleWatched(ep)  // off, before the first call returned
        #expect(isWatched(1) == false)
        #expect(fake.calls == [.setWatched(true, rid(1))])  // the second waits for the first
        fake.releaseAll()
        await first.value
        await second.value
        #expect(isWatched(1) == false)
        #expect(fake.calls == [.setWatched(true, rid(1)), .setWatched(false, rid(1))])
        #expect(adapter.store.recording(id: rid(1))?.flags.contains(.watched) == false)
        #expect(model.problem == nil)
        #expect(log.changes == [.watched(rid(1), true), .watched(rid(1), false)])
    }

    @Test func threeQuickTogglesSendOnlyWhatIsNeeded() async throws {
        fake.suspendNext(.setWatched)
        let ep = model.seasons[0].episodes[0]
        let t1 = model.toggleWatched(ep)  // on
        try await fake.waitForParked()
        model.toggleWatched(ep)  // off
        let t3 = model.toggleWatched(ep)  // on again
        fake.releaseAll()
        await t1.value
        await t3.value
        #expect(isWatched(1) == true)
        #expect(fake.calls == [.setWatched(true, rid(1))])
    }

    @Test func aWriteThatFailsAfterALaterToggleDoesNotUndoTheLaterOne() async throws {
        fake.suspendNext(.setWatched)
        let ep = model.seasons[0].episodes[0]
        let first = model.toggleWatched(ep)  // on, will fail
        try await fake.waitForParked()
        let second = model.toggleWatched(ep)  // off: already what the backend has
        fake.releaseAll(throwing: .timedOut)
        await first.value
        await second.value
        #expect(isWatched(1) == false)  // the later toggle stands; it is never rolled back to "on"
        #expect(fake.calls == [.setWatched(true, rid(1))])
        #expect(model.problem == UserMessage(.timedOut))
    }

    @Test func aLaterWriteThatFailsRollsBackToWhatTheBackendConfirmed() async throws {
        fake.suspendNext(.setWatched)
        let ep = model.seasons[0].episodes[0]
        let first = model.toggleWatched(ep)  // on, succeeds
        try await fake.waitForParked()
        let second = model.toggleWatched(ep)  // off, will fail
        fake.failNext(.timedOut, on: .setWatched)
        fake.releaseAll()
        await first.value
        await second.value
        #expect(isWatched(1) == true)  // confirmed by the first write
        #expect(fake.calls == [.setWatched(true, rid(1)), .setWatched(false, rid(1))])
        #expect(log.changes == [.watched(rid(1), true)])
    }

    @Test func togglesOnDifferentRecordingsDoNotWaitForEachOther() async throws {
        fake.suspend(.setWatched)
        let one = model.toggleWatched(model.seasons[0].episodes[0])
        let two = model.toggleWatched(model.seasons[0].episodes[1])
        try await fake.waitForParked(2)
        fake.releaseAll()
        await one.value
        await two.value
        #expect(isWatched(1) == true && isWatched(2) == true)
    }

    @Test func togglingAnEpisodeTheShowDoesNotHaveDoesNothing() async {
        await model.toggleWatched(episode(99)).value
        #expect(fake.calls.isEmpty)
    }

    @Test func theSelectedSeasonSurvivesAToggle() async {
        model.select(season: model.seasons[1])
        await model.toggleWatched(model.seasons[1].episodes[0]).value
        #expect(model.selectedSeason?.id == 2)
    }

    // MARK: delete

    @Test func deleteRemovesTheRecordingAtOnceAndKeepsItGoneOnSuccess() async throws {
        fake.suspend(.delete)
        let ep = model.seasons[0].episodes[0]
        let task = model.delete(ep)
        #expect(isWatched(1) == nil)
        #expect(model.show.episodeCount == 3)
        try await fake.waitForParked()
        fake.releaseAll()
        await task.value
        #expect(isWatched(1) == nil)
        #expect(fake.calls == [.delete(rid(1), allowRerecord: false)])
        #expect(model.problem == nil)
        #expect(log.changes == [.deleted(rid(1))])
    }

    @Test func deleteRollsBackInTheRightPlaceAndSaysWhyWhenTheCallFails() async {
        fake.failNext(.unreachable("DIAG"), on: .delete)
        let before = model.seasons
        await model.delete(model.seasons[0].episodes[0]).value
        #expect(model.seasons == before)
        #expect(model.problem == UserMessage(.unreachable("DIAG")))
        #expect(log.changes.isEmpty)
    }

    @Test func theRecordingIsGoneWhileAFailingDeleteIsStillInFlight() async throws {
        fake.suspend(.delete)
        let task = model.delete(model.seasons[0].episodes[0])
        try await fake.waitForParked()
        #expect(isWatched(1) == nil)
        fake.releaseAll(throwing: .timedOut)
        await task.value
        #expect(isWatched(1) == false)
    }

    @Test func aRollbackOfADeleteKeepsAWatchedChangeMadeInTheMeantime() async throws {
        fake.suspend(.setWatched)
        fake.failNext(.timedOut, on: .delete)
        let ep = model.seasons[0].episodes[0]
        let toggle = model.toggleWatched(ep)
        try await fake.waitForParked()
        await model.delete(ep).value  // fails at once; the episode comes back
        #expect(isWatched(1) == true)
        fake.releaseAll()
        await toggle.value
        #expect(isWatched(1) == true)
    }

    @Test func deletingTheSameRecordingTwiceSendsOneCall() async {
        let ep = model.seasons[0].episodes[0]
        let first = model.delete(ep)
        let second = model.delete(ep)
        await first.value
        await second.value
        #expect(fake.calls == [.delete(rid(1), allowRerecord: false)])
    }

    @Test func deletingTheLastEpisodeOfTheSelectedSeasonSelectsTheFirstSeasonLeft() async {
        model.select(season: model.seasons[1])
        await model.delete(model.seasons[1].episodes[0]).value
        #expect(model.seasons.map(\.title) == ["Season 1", "Other Episodes"])
        #expect(model.selectedSeason?.id == 1)
    }

    @Test func aFailedDeleteOfThatLastEpisodeBringsTheSeasonAndItsSelectionBack() async {
        model.select(season: model.seasons[1])
        fake.failNext(.timedOut, on: .delete)
        await model.delete(model.seasons[1].episodes[0]).value
        #expect(model.selectedSeason?.id == 2)
    }

    @Test func deletingTheLastRecordingOfTheShowMakesItEmptySoTheViewCanClose() async {
        let h = ShowViewModelTests(recordings: [episode(1)])
        let task = h.model.delete(h.model.seasons[0].episodes[0])
        #expect(h.model.isEmpty)
        #expect(h.model.seasons.isEmpty)
        #expect(h.model.selectedSeason == nil)
        await task.value
        #expect(h.model.isEmpty)
        #expect(h.model.show.title == "Garden Tales")  // still there for a closing transition
    }

    @Test func aFailedDeleteOfTheLastRecordingMakesTheShowNonEmptyAgain() async {
        let h = ShowViewModelTests(recordings: [episode(1)])
        h.fake.failNext(.timedOut)
        await h.model.delete(h.model.seasons[0].episodes[0]).value
        #expect(!h.model.isEmpty)
        #expect(h.model.selectedSeason != nil)
    }

    @Test func aMovieShowDeletesAnAiringLikeAnyOtherRecording() async {
        let h = ShowViewModelTests(recordings: [
            .fixture(id: rid(1), title: "Moonlit Road", kind: .movie, season: nil, episode: nil, seriesKey: nil),
            .fixture(id: rid(2), title: "Moonlit Road", kind: .movie, season: nil, episode: nil, seriesKey: nil),
        ])
        #expect(h.model.seasons.count == 1)
        await h.model.delete(h.model.seasons[0].episodes[0]).value
        #expect(h.model.seasons[0].episodes.count == 1)
    }

    @Test func theModelExposesDeleteOnlyAndHasNoConfirmationState() {
        // askBeforeDelete is the view's concern (SPEC 6.4): nothing here knows about it.
        let names = Mirror(reflecting: model).children.compactMap(\.label).map { $0.lowercased() }
        #expect(!names.contains { $0.contains("confirm") || $0.contains("askbefore") })
        #expect(names.contains { $0.contains("problem") })
    }

    // MARK: Without a change callback

    @Test func aModelWithoutACallbackStillWorks() async {
        let model = ShowViewModel(
            show: LibraryBuilder.build(from: adapter.store.allRecordings).shows[0],
            recordings: adapter.recordings)
        await model.toggleWatched(model.seasons[0].episodes[0]).value
        #expect(model.show.unwatchedCount == 3)
    }
}
