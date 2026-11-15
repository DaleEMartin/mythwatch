import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchTestSupport
import Testing

/// The conformance suite (SPEC 9.1) run against `FakeBackendAdapter`, which keeps the fake as
/// honest as the real adapters.
struct FakeConformanceScenario: ConformanceScenario {
    let connection = BackendConnection(baseURL: URL(string: "http://fake-backend:6544")!)
    let absentID = RecordingID(rawValue: 999)
    let idWithBreaks = RecordingID(rawValue: 1)
    let idWithoutStoredPosition = RecordingID(rawValue: 2)
    let idWithResumePosition: RecordingID? = RecordingID(rawValue: 3)
    let idWithBookmark: RecordingID? = RecordingID(rawValue: 4)

    func makeAdapter() async throws -> any BackendAdapter {
        let store = FakeBackendStore()
        let poster = ArtworkReference(kind: .poster, locator: "poster one")
        store.add(
            .fixture(id: RecordingID(rawValue: 1), artwork: [poster]),
            commercialBreaks: [
                TimeRange(start: .seconds(60), end: .seconds(120))!,
                TimeRange(start: .seconds(300), end: .seconds(360))!,
            ])
        store.add(.fixture(id: RecordingID(rawValue: 2)))
        store.add(.fixture(id: RecordingID(rawValue: 3)), resumePosition: .seconds(600))
        store.add(.fixture(id: RecordingID(rawValue: 4)), bookmark: .seconds(120))
        store.add(.fixture(id: RecordingID(rawValue: 5), flags: [.deletePending]))
        store.add(.fixture(id: RecordingID(rawValue: 6), flags: [.recordingInProgress]))
        return FakeBackendAdapter(store: store, baseURL: connection.baseURL)
    }
}

@Suite("Adapter conformance: FakeBackendAdapter")
struct FakeAdapterConformanceTests {
    @Test(arguments: AdapterConformance.Check.allCases)
    func passes(_ check: AdapterConformance.Check) async {
        let violations = await check.violations(in: FakeConformanceScenario())
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }
}
