import Foundation
import MythwatchFeatures
import MythwatchTestSupport
import Testing

/// The fake app the UI tests launch (SPEC 7 "UI tests") must connect and fill every shelf.
@MainActor
@Suite("DemoBackend")
struct DemoBackendTests {
    @Test func withABackendSavedItConnectsAndEveryShelfHasSomething() async throws {
        let app = DemoBackend.appModel(backendSaved: true)
        await app.connect()
        let session = try #require(app.session.value)
        #expect(session.adapterName == DemoBackend.adapterName)
        #expect(session.info.hostName == DemoBackend.hostName)
        let library = app.makeLibraryModel()
        await library.load()
        let value = try #require(library.library.value)
        #expect(value.continueWatching.count == 3)
        #expect(!value.recentlyRecorded.isEmpty)
        #expect(value.shows.count == 9)
        #expect(value.shows.contains { $0.kind == .movie })
    }

    @Test func withoutABackendSavedTheAppIsIdleAndDiscoveryOffersTheDemoBackend() async throws {
        let app = DemoBackend.appModel(backendSaved: false)
        await app.connect()
        #expect(app.session.isIdle)
        let onboarding = app.makeOnboardingModel()
        onboarding.startDiscovery()
        await waitUntil(onboarding) { !$0.discovered.isEmpty }
        #expect(onboarding.discovered.map(\.connection) == [DemoBackend.connection])
        onboarding.select(onboarding.discovered[0])
        await onboarding.connect()
        #expect(onboarding.connectState.value?.hostName == DemoBackend.hostName)
        #expect(app.session.value != nil)
        onboarding.stopDiscovery()
    }
}
