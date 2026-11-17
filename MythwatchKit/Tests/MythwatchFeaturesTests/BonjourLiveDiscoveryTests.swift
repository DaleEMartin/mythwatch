import Foundation
import MythwatchFeatures
import Testing

// Live Bonjour check (task M5-2). Skipped unless MYTHWATCH_LIVE_BACKEND is set, like the v35
// live suite, so the same command runs both. It only browses and resolves over mDNS: no request
// of any kind is sent to the backend.

private func liveBackendURL() -> URL? {
    let raw = ProcessInfo.processInfo.environment["MYTHWATCH_LIVE_BACKEND"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return nil }
    return URL(string: raw)
}

@Suite("Bonjour live discovery", .enabled(if: liveBackendURL() != nil, "MYTHWATCH_LIVE_BACKEND is not set"))
struct BonjourLiveDiscoveryTests {
    /// The real browser and resolver find a backend whose API port is the live backend's.
    @Test(.timeLimit(.minutes(1)))
    func findsTheLiveBackendOnItsAPIPort() async throws {
        let url = try #require(liveBackendURL())
        let port = url.port ?? 6544
        for await list in BonjourBackendDiscovery.onLocalNetwork().discover() {
            if let found = list.first(where: { $0.connection.baseURL.port == port }) {
                #expect(found.connection.baseURL.scheme == "http")
                #expect(found.connection.baseURL.host()?.hasSuffix(".local") == true)
                return
            }
        }
        Issue.record("Browsing ended without finding a backend on port \(port)")
    }
}
