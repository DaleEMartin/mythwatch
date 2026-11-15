import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythBackendV35

/// The v35 adapter, built by `V35AdapterFactory`, over a `FixtureTransport` answering from the
/// committed fixtures (Fixtures/README.md). Where the suite needs a reply no fixture file holds,
/// it is derived here from a captured file, never invented:
///
/// - `GetRecordedList`: both captured pages with `TotalAvailable` rewritten from 307 to 8, so the
///   adapter's paging (page size 200) stops after the 8 captured rows.
/// - `GetRecorded`: the captured `recorded-one.json` for id 33 (the first listed row; this is the
///   real cross-endpoint comparison); for the other 7 listed ids, the list row itself wrapped as
///   `{"Program": row}`, which is the shape BACKEND-V35 documents for that call; any other id gets
///   the captured blank programme `recorded-missing.json`.
/// - `GetRecordedCommBreak`: `commbreak.json` for 33, `commbreak-unbalanced.json` for 45,
///   `commbreak-empty.json` for every other id.
/// - `GetLastPlayPos`: `lastplaypos-set.json` for 69 (the row flagged `LASTPLAYPOS`),
///   `lastplaypos-zero.json` for every other id.
/// - `GetSavedBookmark`: `lastplaypos-zero.json` for every id (BACKEND-V35: same reply shape). No
///   bookmark reply was captured, so `idWithBookmark` is nil.
struct V35ConformanceScenario: ConformanceScenario {
    static let page1IDs = [33, 35, 45, 53]
    static let page2IDs = [64, 66, 69, 86]

    let connection = BackendConnection(baseURL: URL(string: "http://backend:6544")!)
    let absentID = RecordingID(rawValue: 99_999_999)
    let idWithBreaks = RecordingID(rawValue: 33)
    let idWithoutStoredPosition = RecordingID(rawValue: 33)
    let idWithResumePosition: RecordingID? = RecordingID(rawValue: 69)
    let idWithBookmark: RecordingID? = nil

    /// Shared by every adapter this scenario makes, so a test can inspect the requests.
    let transport: FixtureTransport

    init() throws {
        let t = FixtureTransport()
        let page1 = try Self.text("recorded-list-page1")
        let page2 = try Self.text("recorded-list-page2")
        let total = "\"TotalAvailable\": 307"
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0"],
               body: page1.replacingOccurrences(of: total, with: "\"TotalAvailable\": 8"))
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "4"],
               body: page2.replacingOccurrences(of: total, with: "\"TotalAvailable\": 8"))

        t.stub(.get, path: "/Dvr/GetRecorded", body: try Self.data("recorded-missing"))
        for (id, body) in try Self.programmes(fromListPages: [page1, page2]) where id != 33 {
            t.stub(.get, path: "/Dvr/GetRecorded", query: ["RecordedId": String(id)], body: body)
        }
        t.stub(.get, path: "/Dvr/GetRecorded", query: ["RecordedId": "33"],
               body: try Self.data("recorded-one"))

        t.stub(.get, path: "/Dvr/GetRecordedCommBreak", body: try Self.data("commbreak-empty"))
        t.stub(.get, path: "/Dvr/GetRecordedCommBreak", query: ["RecordedId": "33"],
               body: try Self.data("commbreak"))
        t.stub(.get, path: "/Dvr/GetRecordedCommBreak", query: ["RecordedId": "45"],
               body: try Self.data("commbreak-unbalanced"))

        t.stub(.get, path: "/Dvr/GetLastPlayPos", body: try Self.data("lastplaypos-zero"))
        t.stub(.get, path: "/Dvr/GetLastPlayPos", query: ["RecordedId": "69"],
               body: try Self.data("lastplaypos-set"))
        t.stub(.get, path: "/Dvr/GetSavedBookmark", body: try Self.data("lastplaypos-zero"))
        transport = t
    }

    func makeAdapter() async throws -> any BackendAdapter {
        let version = try #require(BackendVersion(parsing: "v35.0"))
        return V35AdapterFactory().makeAdapter(
            connection: connection, version: version, transport: transport)
    }

    // MARK: Fixture helpers

    static func data(_ name: String) throws -> Data {
        try FixtureLoader.data(named: name, in: .module, subdirectory: "Fixtures")
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    /// Each list row as a `GetRecorded` reply body, keyed by its id, in list order.
    static func programmes(fromListPages pages: [String]) throws -> [(Int, Data)] {
        try pages.flatMap { page -> [(Int, Data)] in
            let root = try JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any]
            let list = try #require(root?["ProgramList"] as? [String: Any])
            let rows = try #require(list["Programs"] as? [[String: Any]])
            return try rows.map { row in
                let recording = try #require(row["Recording"] as? [String: Any])
                let id = try #require(recording["RecordedId"] as? Int)
                return (id, try JSONSerialization.data(withJSONObject: ["Program": row]))
            }
        }
    }
}

@Suite("Adapter conformance: MythTV v35")
struct V35ConformanceTests {
    /// One test case per check, over every check the suite has: a check added to
    /// `AdapterConformance.Check` runs here without an edit.
    @Test(arguments: AdapterConformance.Check.allCases)
    func passes(_ check: AdapterConformance.Check) async throws {
        let violations = await check.violations(in: try V35ConformanceScenario())
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    /// The whole suite reads only: every request is a GET and every one matched a fixture route.
    @Test func wholeSuiteSendsOnlyMatchedGETs() async throws {
        let scenario = try V35ConformanceScenario()
        for check in AdapterConformance.Check.allCases {
            _ = await check.violations(in: scenario)
        }
        let requests = scenario.transport.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.method == .get })
        #expect(scenario.transport.unmatchedRequests.isEmpty)

        // Not vacuous: every listed id (and the absent one) was fetched, and every listed id's
        // breaks were read.
        func ids(_ path: String) -> Set<Int> {
            Set(requests.compactMap { request -> Int? in
                let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
                guard parts?.path == path else { return nil }
                return parts?.queryItems?.first { $0.name == "RecordedId" }?.value.flatMap { Int($0) }
            })
        }
        let listed = Set(V35ConformanceScenario.page1IDs + V35ConformanceScenario.page2IDs)
        #expect(ids("/Dvr/GetRecorded") == listed.union([scenario.absentID.rawValue]))
        #expect(ids("/Dvr/GetRecordedCommBreak") == listed)
    }

    /// The derived `GetRecorded` replies cover exactly the listed ids.
    @Test func derivedProgrammesCoverTheListedIDs() throws {
        let pages = [
            try V35ConformanceScenario.text("recorded-list-page1"),
            try V35ConformanceScenario.text("recorded-list-page2"),
        ]
        let ids = try V35ConformanceScenario.programmes(fromListPages: pages).map(\.0)
        #expect(ids == V35ConformanceScenario.page1IDs + V35ConformanceScenario.page2IDs)
    }
}
