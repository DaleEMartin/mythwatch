import Foundation
import MythwatchBackend
import MythwatchFeatures
import MythwatchTestSupport
import Testing

private func backend(_ name: String) -> DiscoveredBackend {
    DiscoveredBackend(
        id: name, name: name,
        connection: BackendConnection(baseURL: URL(string: "http://\(name):6544")!))
}

@Suite("InMemorySettingsStore")
struct InMemorySettingsStoreTests {
    @Test func startsWithDefaults() {
        #expect(InMemorySettingsStore().load() == AppSettings())
    }

    @Test func startsWithAGivenValue() {
        let given = AppSettings(deinterlace: false, askBeforeDelete: false)
        #expect(InMemorySettingsStore(given).load() == given)
    }

    @Test func saveThenLoadRoundTrips() {
        let store = InMemorySettingsStore()
        var settings = AppSettings()
        settings.skipForwardSeconds = 60
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func countsSavesAndLoadsAndKeepsSavedValues() {
        let store = InMemorySettingsStore()
        #expect(store.saveCount == 0 && store.loadCount == 0)
        var a = AppSettings()
        a.deinterlace = false
        let b = AppSettings(askBeforeDelete: false)
        store.save(a)
        store.save(b)
        _ = store.load()
        #expect(store.saveCount == 2)
        #expect(store.loadCount == 1)
        #expect(store.saved == [a, b])
    }

    @Test func givenInitialValueIsNotCountedAsASave() {
        #expect(InMemorySettingsStore(AppSettings(deinterlace: false)).saveCount == 0)
    }
}

@Suite("FakeBackendDiscovery")
struct FakeBackendDiscoveryTests {
    @Test func pushedListsArriveInOrder() async {
        let discovery = FakeBackendDiscovery()
        var stream = discovery.discover().makeAsyncIterator()
        discovery.push([backend("a")])
        discovery.push([backend("a"), backend("b")])
        discovery.push([])
        #expect(await stream.next() == [backend("a")])
        #expect(await stream.next() == [backend("a"), backend("b")])
        #expect(await stream.next() == [])
    }

    @Test func nothingArrivesBeforeAPush() async {
        let discovery = FakeBackendDiscovery()
        let stream = discovery.discover()
        discovery.finish()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }

    @Test func aSecondDiscoverGetsItsOwnStreamStartingWithTheLatestList() async {
        let discovery = FakeBackendDiscovery()
        var first = discovery.discover().makeAsyncIterator()
        discovery.push([backend("a")])
        var second = discovery.discover().makeAsyncIterator()
        discovery.push([backend("b")])
        #expect(await first.next() == [backend("a")])
        #expect(await first.next() == [backend("b")])
        #expect(await second.next() == [backend("a")])  // replay of the latest
        #expect(await second.next() == [backend("b")])
        #expect(discovery.discoverCount == 2)
    }

    @Test func aDroppedStreamIsForgotten() async {
        let discovery = FakeBackendDiscovery()
        do {
            var stream = discovery.discover().makeAsyncIterator()
            discovery.push([backend("a")])
            _ = await stream.next()
            #expect(discovery.activeStreamCount == 1)
        }
        #expect(discovery.activeStreamCount == 0)
    }

    @Test func finishEndsEveryStreamAndLaterDiscoversEndImmediately() async {
        let discovery = FakeBackendDiscovery()
        let stream = discovery.discover()
        discovery.push([backend("a")])
        discovery.finish()
        var lists: [[DiscoveredBackend]] = []
        for await list in stream { lists.append(list) }
        #expect(lists == [[backend("a")]])
        var later = 0
        for await _ in discovery.discover() { later += 1 }
        #expect(later == 0)
    }

    @Test func deinitEndsOpenStreams() async {
        var discovery: FakeBackendDiscovery? = FakeBackendDiscovery()
        let stream = discovery!.discover()
        discovery!.push([backend("a")])
        discovery = nil
        var lists: [[DiscoveredBackend]] = []
        for await list in stream { lists.append(list) }  // would hang if the stream leaked open
        #expect(lists == [[backend("a")]])
    }

    @Test func pushingAfterEveryConsumerWentAwayIsHarmless() {
        let discovery = FakeBackendDiscovery()
        _ = discovery.discover()
        discovery.push([backend("a")])
        #expect(discovery.activeStreamCount == 0)
    }
}
