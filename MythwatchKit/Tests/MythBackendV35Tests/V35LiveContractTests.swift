import Foundation
import MythwatchBackend
import MythwatchDomain
import Testing

@testable import MythBackendV35

// Live, read-only contract tests (task M1-9). Skipped unless MYTHWATCH_LIVE_BACKEND is set.
//
// Rules for this file (CLAUDE.md rule 4): GET requests only; nothing here may call a write method
// of any service; no artwork or preview images; the only request to a stream URL is one GET with
// `Range: bytes=0-0`. Nothing here writes files or prints programme titles.

extension Tag {
    @Tag static var live: Self
}

/// The raw value of the gate variable, or nil when unset or blank. Reading the environment does
/// no I/O on the network.
private func liveBackendSetting() -> String? {
    let raw = ProcessInfo.processInfo.environment["MYTHWATCH_LIVE_BACKEND"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (raw?.isEmpty ?? true) ? nil : raw
}

private struct LiveSetupError: Error, CustomStringConvertible {
    let description: String
}

/// Everything a live test needs. Built inside a test body only, so with the variable unset
/// nothing here ever runs.
private struct LiveContext {
    let connection: BackendConnection
    let transport: URLSessionTransport

    init() throws {
        guard let raw = liveBackendSetting() else {
            throw LiveSetupError(description: "MYTHWATCH_LIVE_BACKEND is not set.")
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else {
            throw LiveSetupError(
                description:
                    "MYTHWATCH_LIVE_BACKEND must be a base URL such as http://host:6544, but it is not a valid http(s) URL."
            )
        }
        connection = BackendConnection(baseURL: url)
        transport = URLSessionTransport()
    }

    func adapter() async throws -> any BackendAdapter {
        var registry = AdapterRegistry()
        registry.register(V35AdapterFactory())
        return try await BackendConnector(registry: registry, transport: transport).connect(connection).adapter
    }

    /// The listing, fetched through the adapter's production path (default page size).
    func listing() async throws -> (adapter: any BackendAdapter, recordings: [Recording]) {
        let adapter = try await adapter()
        return (adapter, try await adapter.recordings.allRecordings())
    }
}

/// Names of the fields whose values differ between two recordings (never the values).
private func differingFields(_ a: Recording, _ b: Recording) -> [String] {
    var names: [String] = []
    for (x, y) in zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children) {
        guard let label = x.label else { continue }
        if "\(x.value)" != "\(y.value)" { names.append(label) }
    }
    return names
}

@Suite(
    "V35 live backend (read-only)", .tags(.live),
    .enabled(if: liveBackendSetting() != nil, "MYTHWATCH_LIVE_BACKEND is not set"),
    .serialized)
struct V35LiveContractTests {
    @Test func probeSucceedsAndReportsVersion35() async throws {
        let ctx = try LiveContext()
        let info = try await BackendProbe(transport: ctx.transport).probe(ctx.connection)
        print("LIVE probe: version \(info.version.raw), host name present: \(info.hostName != nil)")
        #expect(info.version.major == 35)
    }

    @Test func listHasRecordingsWithUniqueIDs() async throws {
        let ctx = try LiveContext()
        let started = ContinuousClock.now
        let (_, recordings) = try await ctx.listing()
        print("LIVE list: \(recordings.count) recordings, connect plus list took \(ContinuousClock.now - started)")
        #expect(recordings.count > 0)
        #expect(Set(recordings.map(\.id)).count == recordings.count, "listed ids are not unique")
    }

    @Test func singleFetchOfFirstListedMatchesListedValue() async throws {
        let ctx = try LiveContext()
        let (adapter, recordings) = try await ctx.listing()
        let first = try #require(recordings.first)
        let fetched = try await adapter.recordings.recording(id: first.id)
        let differing = differingFields(first, fetched)
        print("LIVE single fetch: fields differing from the list entry: \(differing)")
        #expect(fetched.id == first.id)
        #expect(differing.isEmpty, "recording(id:) differs from the list entry in: \(differing)")
    }

    @Test func commercialBreaksOfFirstFlaggedRecordingAreOrdered() async throws {
        let ctx = try LiveContext()
        let (adapter, recordings) = try await ctx.listing()
        let flaggedCount = recordings.filter { $0.flags.contains(.commercialsFlagged) }.count
        guard let flagged = recordings.first(where: { $0.flags.contains(.commercialsFlagged) })
        else {
            print("LIVE breaks: no recording has commercialsFlagged (of \(recordings.count))")
            Issue.record("no listed recording has the commercialsFlagged flag, so breaks were not exercised")
            return
        }
        let breaks = try await adapter.markup.commercialBreaks(for: flagged.id)
        print("LIVE breaks: \(flaggedCount) flagged recordings; first has \(breaks.count) breaks")
        for (i, b) in breaks.enumerated() {
            #expect(b.start < b.end, "break \(i) is empty or inverted")
            if i > 0 {
                #expect(breaks[i - 1].end <= b.start, "break \(i) overlaps or precedes the previous one")
            }
        }
    }

    @Test func rangedGetOnStreamURLReturns206() async throws {
        let ctx = try LiveContext()
        let (adapter, recordings) = try await ctx.listing()
        let first = try #require(recordings.first)
        let url = adapter.media.streamURL(for: first)
        let response = try await ctx.transport.send(
            HTTPRequest(method: .get, url: url, headers: ["Range": "bytes=0-0"]))
        let lower = Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key.lowercased(), $0.value) })
        print(
            "LIVE range: status \(response.status), body bytes \(response.body.count), "
                + "Content-Range \(lower["content-range"] ?? "none"), "
                + "Content-Type \(lower["content-type"] ?? "none")")
        #expect(response.status == 206)
    }
}

/// With a malformed base URL the suite must fail clearly, not crash. Runs only when the variable
/// is set to something that is not a valid base URL, so it never touches the network.
@Suite("V35 live backend setting")
struct V35LiveSettingTests {
    @Test(.tags(.live), .enabled(if: liveBackendSetting() != nil))
    func settingIsAValidBaseURL() throws {
        _ = try LiveContext()
    }
}
