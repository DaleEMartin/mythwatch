import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythBackendV35

// Regression for the live finding of 2026-11-15 (docs/BACKEND-V35.md, "A recording in progress"):
// for a recording being recorded, GetRecordedList reports the in-use flags and a "Recording"
// status, GetRecorded does not. The bodies are derived from the committed `recorded-one.json`
// with the two flag strings observed live.

private let listedFlags = "AUTOEXP|COMMPROCESSING|INUSERECORDING|INUSEOTHER"
private let fetchedFlags = "AUTOEXP|EDITING|COMMPROCESSING"

private func recordedOne() throws -> String {
    let data = try FixtureLoader.data(named: "recorded-one", in: Bundle.module, subdirectory: "Fixtures")
    return String(decoding: data, as: UTF8.self)
}

private func withFlags(_ body: String, _ flags: String, status: (Int, String)) -> String {
    body.replacingOccurrences(of: "\"ProgramFlagNames\": \"COMMFLAG\"", with: "\"ProgramFlagNames\": \"\(flags)\"")
        .replacingOccurrences(of: "\"Status\": -3, \"StatusName\": \"Recorded\"",
                              with: "\"Status\": \(status.0), \"StatusName\": \"\(status.1)\"")
}

private func service(list: String, single: String) -> V35RecordingsService {
    let t = FixtureTransport()
    // Strip {"Program": ...} to wrap the same programme object as one list row.
    let program = String(list.dropFirst("{\"Program\": ".count).dropLast())
    t.stub(.get, path: "/Dvr/GetRecordedList",
           body: "{\"ProgramList\": {\"StartIndex\": 0, \"Count\": 1, \"TotalAvailable\": 1, \"Programs\": [\(program)]}}")
    t.stub(.get, path: "/Dvr/GetRecorded", body: single)
    return V35RecordingsService(
        connection: BackendConnection(baseURL: URL(string: "http://backend:6544")!),
        transport: t, pageSize: 200)
}

@Suite("V35 recording in progress")
struct V35InProgressRecordingTests {
    @Test func listCarriesRecordingInProgressAndSingleFetchDoesNot() async throws {
        let base = try recordedOne()
        let s = service(
            list: withFlags(base, listedFlags, status: (-2, "Recording")),
            single: withFlags(base, fetchedFlags, status: (-3, "Recorded")))
        let listed = try #require(try await s.allRecordings().first)
        let fetched = try await s.recording(id: listed.id)
        #expect(listed.flags.contains(.recordingInProgress))
        #expect(!fetched.flags.contains(.recordingInProgress))
    }

    @Test func onlyFlagsDifferBetweenListAndSingleFetch() async throws {
        let base = try recordedOne()
        let s = service(
            list: withFlags(base, listedFlags, status: (-2, "Recording")),
            single: withFlags(base, fetchedFlags, status: (-3, "Recorded")))
        let listed = try #require(try await s.allRecordings().first)
        var fetched = try await s.recording(id: listed.id)
        #expect(fetched.flags != listed.flags)
        fetched.flags = listed.flags
        #expect(fetched == listed)
    }

    @Test func finishedRecordingIsIdenticalFromBothEndpoints() async throws {
        let base = try recordedOne()
        let s = service(list: base, single: base)
        let listed = try #require(try await s.allRecordings().first)
        #expect(try await s.recording(id: listed.id) == listed)
        #expect(!listed.flags.contains(.recordingInProgress))
    }
}
