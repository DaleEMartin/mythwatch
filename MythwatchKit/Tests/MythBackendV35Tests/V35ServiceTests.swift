import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythBackendV35

// MARK: - Expected values (the one place to edit if the fixtures' real titles are replaced)

private enum Expect {
    static let baseURL = URL(string: "http://backend:6544")!
    static let firstTitle = "Amber Street Sessions"
    static let firstID = 33
    /// Locator of the first poster in `recorded-list-page1.json`, with its percent-escapes.
    static let locator =
        "/Content/GetImageFile?StorageGroup=Coverart&FileName=%2FAmber%20Street%20Sessions%20Season%2050_coverart.jpg"
    static let page1IDs = [33, 35, 45, 53]
    static let page2IDs = [64, 66, 69, 86]
    static let missingID = 99_999_999
}

// MARK: - Helpers

private func fixture(_ name: String) throws -> Data {
    try FixtureLoader.data(named: name, in: Bundle.module, subdirectory: "Fixtures")
}

private let connection = BackendConnection(baseURL: Expect.baseURL)

private func ids(_ recordings: [Recording]) -> [Int] { recordings.map(\.id.rawValue) }

private func query(_ request: HTTPRequest) -> [String: String] {
    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

private func path(_ request: HTTPRequest) -> String {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.path ?? ""
}

private func listBody(start: Int, total: Int, ids: [Int]) -> String {
    let rows = ids.map { id in
        """
        {"StartTime": "2025-01-19T04:00:00Z", "EndTime": "2025-01-19T05:00:00Z", "Title": "T\(id)", \
        "LastModified": "2025-01-19T05:00:10Z", "Recording": {"RecordedId": \(id), \
        "StartTs": "2025-01-19T04:00:00Z", "EndTs": "2025-01-19T05:00:00Z", "RecGroup": "Default"}}
        """
    }.joined(separator: ",")
    return """
        {"ProgramList": {"StartIndex": \(start), "Count": \(ids.count), "TotalAvailable": \(total), \
        "Programs": [\(rows)]}}
        """
}

private func recordingsService(_ t: FixtureTransport, pageSize: Int = 200) -> V35RecordingsService {
    V35RecordingsService(connection: connection, transport: t, pageSize: pageSize)
}

/// A transport answering both fixture pages of 4 rows (`TotalAvailable` 307 in the fixtures),
/// then an empty page.
private func pagedTransport() throws -> FixtureTransport {
    let t = FixtureTransport()
    t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0"],
           body: try fixture("recorded-list-page1"))
    t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "4"],
           body: try fixture("recorded-list-page2"))
    t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "8"],
           body: listBody(start: 8, total: 307, ids: []))
    return t
}

// MARK: - Recordings list

@Suite("V35RecordingsService.allRecordings")
struct V35ListTests {
    @Test func firstRequestHasExactQueryAndHeaders() async throws {
        let t = try pagedTransport()
        _ = try await recordingsService(t).allRecordings()
        let first = try #require(t.requests.first)
        #expect(first.method == .get)
        #expect(first.headers["Accept"] == "application/json")
        #expect(first.body == nil)
        #expect(path(first) == "/Dvr/GetRecordedList")
        #expect(
            query(first) == [
                "Descending": "true", "StartIndex": "0", "Count": "200", "IgnoreLiveTV": "true",
                "IgnoreDeleted": "true", "IncCast": "false", "IncChannel": "true",
                "IncArtWork": "true", "IncRecording": "true",
            ])
        #expect(t.requests.allSatisfy { query($0)["Sort"] == nil })
        #expect(first.url.absoluteString.hasPrefix("http://backend:6544/Dvr/GetRecordedList?"))
    }

    @Test func defaultPageSizeIsTwoHundred() {
        #expect(V35RecordingsService.defaultPageSize == 200)
    }

    @Test func pagesUntilTotalAvailable() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0"],
               body: listBody(start: 0, total: 5, ids: [1, 2]))
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "2"],
               body: listBody(start: 2, total: 5, ids: [3, 4]))
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "4"],
               body: listBody(start: 4, total: 5, ids: [5]))
        let result = try await recordingsService(t, pageSize: 2).allRecordings()
        #expect(ids(result) == [1, 2, 3, 4, 5])
        #expect(t.requests.count == 3)
        #expect(t.requests.map { query($0)["StartIndex"] } == ["0", "2", "4"])
        #expect(t.requests.allSatisfy { query($0)["Count"] == "2" })
    }

    @Test func fixturePagesMapToDomain() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0"],
               body: try fixture("recorded-list-page1"))
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "4"],
               body: try fixture("recorded-list-page2"))
        // Pretend the backend only has these 8: rewrite the totals.
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0", "Count": "4"],
               body: String(decoding: try fixture("recorded-list-page1"), as: UTF8.self)
                   .replacingOccurrences(of: "\"TotalAvailable\": 307", with: "\"TotalAvailable\": 8"))
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "4", "Count": "4"],
               body: String(decoding: try fixture("recorded-list-page2"), as: UTF8.self)
                   .replacingOccurrences(of: "\"TotalAvailable\": 307", with: "\"TotalAvailable\": 8"))
        let result = try await recordingsService(t, pageSize: 4).allRecordings()
        #expect(ids(result) == Expect.page1IDs + Expect.page2IDs)
        #expect(result.first?.title == Expect.firstTitle)
        #expect(t.requests.count == 2)
        #expect(t.unmatchedRequests.isEmpty)
    }

    @Test func stopsOnEmptyPageEvenIfTotalSaysMore() async throws {
        let t = try pagedTransport()
        let result = try await recordingsService(t, pageSize: 4).allRecordings()
        #expect(ids(result) == Expect.page1IDs + Expect.page2IDs)
        #expect(t.requests.count == 3)
        #expect(t.unmatchedRequests.isEmpty)
    }

    @Test func failingSecondPageFailsTheCall() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0"],
               body: try fixture("recorded-list-page1"))
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "4"],
               status: 500, body: "boom")
        await #expect(throws: BackendError.http(status: 500, message: "boom")) {
            _ = try await recordingsService(t, pageSize: 4).allRecordings()
        }
    }

    @Test func transportFailureOnSecondPagePassesThrough() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0"],
               body: try fixture("recorded-list-page1"))
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "4"], failure: .timedOut)
        await #expect(throws: BackendError.timedOut) {
            _ = try await recordingsService(t, pageSize: 4).allRecordings()
        }
    }

    @Test func idRepeatedAcrossPagesAppearsOnceFirstKept() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "0"],
               body: listBody(start: 0, total: 4, ids: [1, 2]))
        // Row 2 repeats with a different title; the first occurrence must win.
        t.stub(.get, path: "/Dvr/GetRecordedList", query: ["StartIndex": "2"],
               body: listBody(start: 2, total: 4, ids: [2, 3]).replacingOccurrences(of: "\"T2\"", with: "\"Again\""))
        let result = try await recordingsService(t, pageSize: 2).allRecordings()
        #expect(ids(result) == [1, 2, 3])
        #expect(result.first { $0.id.rawValue == 2 }?.title == "T2")
    }

    @Test func emptyListIsEmpty() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecordedList", body: listBody(start: 0, total: 0, ids: []))
        #expect(try await recordingsService(t).allRecordings().isEmpty)
        #expect(t.requests.count == 1)
    }
}

// MARK: - Single recording

@Suite("V35RecordingsService.recording")
struct V35OneTests {
    @Test func fixtureMapsToDomainAndRequestIsExact() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecorded", body: try fixture("recorded-one"))
        let r = try await recordingsService(t).recording(id: RecordingID(rawValue: Expect.firstID))
        #expect(r.id.rawValue == Expect.firstID)
        #expect(r.title == Expect.firstTitle)
        let req = try #require(t.requests.first)
        #expect(path(req) == "/Dvr/GetRecorded")
        #expect(query(req) == ["RecordedId": "33"])
        #expect(req.headers["Accept"] == "application/json")
    }

    @Test func blankProgrammeIsNotFound() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecorded", body: try fixture("recorded-missing"))
        await #expect(throws: BackendError.notFound) {
            _ = try await recordingsService(t).recording(id: RecordingID(rawValue: Expect.missingID))
        }
    }
}

// MARK: - Commercial breaks

private func marks(_ pairs: [(Int, Int)]) -> String {
    let items = pairs.map { "{\"Mark\": \($0.0), \"Offset\": \($0.1)}" }.joined(separator: ",")
    return "{\"CutList\": {\"Cuttings\": [\(items)]}}"
}

private func breaks(body: String) async throws -> [CommercialBreak] {
    let t = FixtureTransport()
    t.stub(.get, path: "/Dvr/GetRecordedCommBreak", body: body)
    return try await V35MarkupService(connection: connection, transport: t)
        .commercialBreaks(for: RecordingID(rawValue: 7))
}

private func range(_ a: Int, _ b: Int) -> CommercialBreak {
    CommercialBreak(start: .milliseconds(a), end: .milliseconds(b))!
}

@Suite("V35MarkupService")
struct V35MarkupTests {
    @Test func balancedListAndExactRequest() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecordedCommBreak", body: try fixture("commbreak"))
        let result = try await V35MarkupService(connection: connection, transport: t)
            .commercialBreaks(for: RecordingID(rawValue: 33))
        #expect(result == [range(0, 156_990), range(3_183_681, 3_526_990)])
        let req = try #require(t.requests.first)
        #expect(query(req) == ["RecordedId": "33", "OffsetType": "Duration"])
        #expect(query(req)["IncludeFps"] == nil)
        #expect(!req.url.absoluteString.contains("IncludeFps"))
        #expect(req.headers["Accept"] == "application/json")
    }

    @Test func unbalancedFixtureAppliesEveryRule() async throws {
        let result = try await breaks(body: String(decoding: try fixture("commbreak-unbalanced"), as: UTF8.self))
        #expect(result == [range(0, 156_990), range(3_183_681, 3_526_990)])
    }

    @Test func emptyIsEmpty() async throws {
        #expect(try await breaks(body: String(decoding: try fixture("commbreak-empty"), as: UTF8.self)).isEmpty)
    }

    @Test func mark32IsIgnored() async throws {
        let body = marks([(32, 29_970), (4, 10_000), (5, 70_000)])
        #expect(try await breaks(body: body) == [range(10_000, 70_000)])
    }

    @Test func onlyMark32IsEmpty() async throws {
        #expect(try await breaks(body: marks([(32, 29_970)])).isEmpty)
    }

    @Test func mark32DoesNotCountAsFirstMark() async throws {
        // The first 4/5 mark is the end, so it opens at 0 even though mark 32 sorts before it.
        let body = marks([(32, 100), (5, 60_000)])
        #expect(try await breaks(body: body) == [range(0, 60_000)])
    }

    @Test func sortsByOffsetFirst() async throws {
        let body = marks([(5, 70_000), (4, 10_000), (5, 200_000), (4, 150_000)])
        #expect(try await breaks(body: body) == [range(10_000, 70_000), range(150_000, 200_000)])
    }

    @Test func startThenEndMakesABreak() async throws {
        #expect(try await breaks(body: marks([(4, 1_000), (5, 61_000)])) == [range(1_000, 61_000)])
    }

    @Test func startFollowedByStartKeepsFirst() async throws {
        let body = marks([(4, 10_000), (4, 20_000), (5, 90_000)])
        #expect(try await breaks(body: body) == [range(10_000, 90_000)])
    }

    @Test func leadingEndStartsAtZero() async throws {
        #expect(try await breaks(body: marks([(5, 60_000)])) == [range(0, 60_000)])
    }

    @Test func endWithNoOpenStartIsDroppedWhenNotFirst() async throws {
        let body = marks([(4, 10_000), (5, 70_000), (5, 120_000)])
        #expect(try await breaks(body: body) == [range(10_000, 70_000)])
    }

    @Test func trailingStartIsDropped() async throws {
        #expect(try await breaks(body: marks([(4, 10_000), (5, 70_000), (4, 200_000)])) == [range(10_000, 70_000)])
        #expect(try await breaks(body: marks([(4, 10_000)])).isEmpty)
    }

    @Test func breaksShorterThanFiveSecondsAreDropped() async throws {
        let body = marks([(4, 10_000), (5, 14_999), (4, 20_000), (5, 25_000), (4, 30_000), (5, 90_000)])
        #expect(try await breaks(body: body) == [range(20_000, 25_000), range(30_000, 90_000)])
    }

    @Test func zeroLengthLeadingBreakIsDropped() async throws {
        #expect(try await breaks(body: marks([(5, 0), (4, 10_000), (5, 70_000)])) == [range(10_000, 70_000)])
    }

    @Test func overlappingOrTouchingBreaksAreMerged() async throws {
        // Possible only through the sort: a start-start-end-end run keeps the first start, so build
        // touching breaks (end and next start at the same offset).
        let body = marks([(4, 10_000), (5, 70_000), (4, 70_000), (5, 130_000)])
        #expect(try await breaks(body: body) == [range(10_000, 130_000)])
    }

    @Test func entriesWithoutMarkOrOffsetAreIgnored() async throws {
        let body = #"{"CutList": {"Cuttings": [{"Offset": 5}, {"Mark": 4, "Offset": 1000}, {"Mark": 5, "Offset": 61000}, {"Mark": 5}]}}"#
        #expect(try await breaks(body: body) == [range(1_000, 61_000)])
    }

    @Test func offsetsAreExactMilliseconds() async throws {
        let result = try await breaks(body: marks([(4, 700_266), (5, 880_279)]))
        #expect(result.first?.start == .seconds(700) + .milliseconds(266))
        #expect(result.first?.end == .seconds(880) + .milliseconds(279))
    }
}

// MARK: - Playback positions

enum PositionCall: CaseIterable, CustomTestStringConvertible {
    case resume, bookmark
    var testDescription: String { self == .resume ? "resumePosition" : "bookmark" }
    var path: String { self == .resume ? "/Dvr/GetLastPlayPos" : "/Dvr/GetSavedBookmark" }

    func run(_ t: FixtureTransport) async throws -> Duration? {
        let s = V35PlaybackStateService(connection: connection, transport: t)
        let id = RecordingID(rawValue: 33)
        return self == .resume ? try await s.resumePosition(for: id) : try await s.bookmark(for: id)
    }
}

@Suite("V35PlaybackStateService getters")
struct V35PositionTests {
    @Test(arguments: PositionCall.allCases)
    func requestIsExact(_ call: PositionCall) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: call.path, body: #"{"long": "0"}"#)
        _ = try await call.run(t)
        let req = try #require(t.requests.first)
        #expect(req.method == .get)
        #expect(req.headers["Accept"] == "application/json")
        #expect(query(req) == ["RecordedId": "33", "OffsetType": "Duration"])
    }

    @Test(arguments: PositionCall.allCases)
    func zeroFixtureIsNil(_ call: PositionCall) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: call.path, body: try fixture("lastplaypos-zero"))
        #expect(try await call.run(t) == nil)
    }

    @Test(arguments: PositionCall.allCases)
    func minusOneIsNil(_ call: PositionCall) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: call.path, body: #"{"long": "-1"}"#)
        #expect(try await call.run(t) == nil)
    }

    @Test(arguments: PositionCall.allCases)
    func milliseconds(_ call: PositionCall) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: call.path, body: #"{"long": "700266"}"#)
        let value = try await call.run(t)
        #expect(value == .milliseconds(700_266))
        #expect(value == .seconds(700) + .milliseconds(266))
    }

    @Test(arguments: PositionCall.allCases)
    func numberInsteadOfStringIsAccepted(_ call: PositionCall) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: call.path, body: #"{"long": 700266}"#)
        #expect(try await call.run(t) == .milliseconds(700_266))
    }

    @Test func capturedSetFixture() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetLastPlayPos", body: try fixture("lastplaypos-set"))
        #expect(try await PositionCall.resume.run(t) == .milliseconds(581_614))
    }
}

// MARK: - Media locator

@Suite("V35MediaLocator")
struct V35MediaTests {
    let media = V35MediaLocator(connection: connection)

    @Test func streamURL() {
        let url = media.streamURL(for: .fixture(id: RecordingID(rawValue: 33)))
        #expect(url.absoluteString == "http://backend:6544/Content/GetRecording?RecordedId=33")
    }

    @Test func artworkKeepsPercentEncodingAndAppendsWidth() throws {
        let ref = ArtworkReference(kind: .poster, locator: Expect.locator)
        let url = try #require(media.artworkURL(for: ref, maxWidth: 320))
        #expect(url.absoluteString == "http://backend:6544" + Expect.locator + "&Width=320")
        #expect(url.absoluteString.contains("%2FAmber%20Street%20Sessions"))
        #expect(!url.absoluteString.contains("%252F"))
    }

    @Test func artworkLocatorWithoutQueryGetsQuestionMark() throws {
        let ref = ArtworkReference(kind: .poster, locator: "/Content/x.jpg")
        let url = try #require(media.artworkURL(for: ref, maxWidth: 160))
        #expect(url.absoluteString == "http://backend:6544/Content/x.jpg?Width=160")
    }

    @Test(arguments: ["", "relative?a=b", "http://elsewhere/x?a=b", "//elsewhere/x", "/a b?c=d"])
    func unusableLocatorIsNil(_ locator: String) {
        #expect(media.artworkURL(for: ArtworkReference(kind: .poster, locator: locator), maxWidth: 160) == nil)
    }

    @Test func previewURL() {
        let url = media.previewImageURL(for: .fixture(id: RecordingID(rawValue: 33)), maxWidth: 1280)
        #expect(url.absoluteString == "http://backend:6544/Content/GetPreviewImage?RecordedId=33&Width=1280")
    }

    @Test func widthSetIsFixed() {
        #expect(V35MediaLocator.widths == [160, 320, 640, 1280])
    }

    @Test(arguments: [
        (-5, 160), (0, 160), (1, 160), (160, 160), (161, 320), (320, 320), (321, 640), (640, 640),
        (641, 1280), (1280, 1280), (1281, 1280), (4000, 1280),
    ])
    func widthsRoundUpToTheFixedSet(requested: Int, expected: Int) throws {
        let ref = ArtworkReference(kind: .poster, locator: Expect.locator)
        let artwork = try #require(media.artworkURL(for: ref, maxWidth: requested))
        #expect(artwork.absoluteString.hasSuffix("&Width=\(expected)"))
        let preview = media.previewImageURL(for: .fixture(), maxWidth: requested)
        #expect(preview.absoluteString.hasSuffix("&Width=\(expected)"))
    }

    @Test func urlsAreAbsoluteAndUnderBase() throws {
        let base = BackendConnection(baseURL: URL(string: "http://backend:6544/")!)
        let m = V35MediaLocator(connection: base)
        let ref = ArtworkReference(kind: .poster, locator: Expect.locator)
        let urls = [
            m.streamURL(for: .fixture()), try #require(m.artworkURL(for: ref, maxWidth: 200)),
            m.previewImageURL(for: .fixture(), maxWidth: 200),
        ]
        for url in urls {
            #expect(url.absoluteString.hasPrefix("http://backend:6544/"))
            #expect(!url.absoluteString.contains("//Content"))
        }
    }
}

// MARK: - Errors, shared by every service

struct ErrorCase: CustomTestStringConvertible, Sendable {
    let name: String
    let pathStub: String
    let run: @Sendable (FixtureTransport) async throws -> Void
    var testDescription: String { name }

    static let all: [ErrorCase] = [
        ErrorCase(name: "list", pathStub: "/Dvr/GetRecordedList") {
            _ = try await recordingsService($0).allRecordings()
        },
        ErrorCase(name: "one", pathStub: "/Dvr/GetRecorded") {
            _ = try await recordingsService($0).recording(id: RecordingID(rawValue: 1))
        },
        ErrorCase(name: "breaks", pathStub: "/Dvr/GetRecordedCommBreak") {
            _ = try await V35MarkupService(connection: connection, transport: $0)
                .commercialBreaks(for: RecordingID(rawValue: 1))
        },
        ErrorCase(name: "resumePosition", pathStub: "/Dvr/GetLastPlayPos") {
            _ = try await PositionCall.resume.run($0)
        },
        ErrorCase(name: "bookmark", pathStub: "/Dvr/GetSavedBookmark") {
            _ = try await PositionCall.bookmark.run($0)
        },
    ]
}

@Suite("V35 error mapping")
struct V35ErrorTests {
    @Test(arguments: ErrorCase.all)
    func html404IsHTTPError(_ c: ErrorCase) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: c.pathStub, status: 404, headers: ["Content-Type": "text/html"],
               body: try fixture("not-found.html"))
        await #expect(throws: BackendError.http(status: 404, message: "404 Not Found")) {
            try await c.run(t)
        }
    }

    @Test(arguments: ErrorCase.all)
    func status400IsRejectedWithMessage(_ c: ErrorCase) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: c.pathStub, status: 400, headers: ["Content-Type": "text/html"],
               body: "<html><body><h1>400 Bad Request</h1><p>RecordedId is invalid</p></body></html>")
        await #expect(throws: BackendError.rejected("400 Bad Request RecordedId is invalid")) {
            try await c.run(t)
        }
    }

    @Test(arguments: ErrorCase.all)
    func status400WithoutBodyIsStillRejected(_ c: ErrorCase) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: c.pathStub, status: 400, body: "")
        await #expect(throws: BackendError.rejected("HTTP 400")) { try await c.run(t) }
    }

    @Test(arguments: ErrorCase.all)
    func wrongShapeIsMalformed(_ c: ErrorCase) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: c.pathStub, body: #"{"Unexpected": [1, 2, 3]}"#)
        do {
            try await c.run(t)
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test(arguments: ErrorCase.all)
    func notJSONIsMalformed(_ c: ErrorCase) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: c.pathStub, body: "<html>not json</html>")
        do {
            try await c.run(t)
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test(arguments: ErrorCase.all)
    func transportErrorsPassThroughUnchanged(_ c: ErrorCase) async throws {
        let t = FixtureTransport()
        t.stub(.get, path: c.pathStub, failure: .unreachable("no route"))
        await #expect(throws: BackendError.unreachable("no route")) { try await c.run(t) }
    }

    @Test func scalarWithMissingValueIsMalformed() async throws {
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetLastPlayPos", body: #"{"long": "abc"}"#)
        do {
            _ = try await PositionCall.resume.run(t)
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }
}

// MARK: - Write stubs: no request, a BackendError

@Suite("V35 write stubs (not implemented until M3-5 / M5-1)")
struct V35WriteStubTests {
    private let id = RecordingID(rawValue: 33)

    private func expectStub(_ t: FixtureTransport, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected a throw")
        } catch let error as BackendError {
            guard case .rejected = error else {
                Issue.record("expected .rejected, got \(error)")
                return
            }
        } catch {
            Issue.record("expected BackendError, got \(error)")
        }
        #expect(t.requests.isEmpty)
        #expect(t.unmatchedRequests.isEmpty)
    }

    @Test func setWatchedSendsNothing() async {
        let t = FixtureTransport()
        await expectStub(t) { try await recordingsService(t).setWatched(true, id: id) }
    }

    @Test func deleteSendsNothing() async {
        let t = FixtureTransport()
        await expectStub(t) { try await recordingsService(t).delete(id: id, allowRerecord: false) }
    }

    @Test func setResumePositionSendsNothing() async {
        let t = FixtureTransport()
        let s = V35PlaybackStateService(connection: connection, transport: t)
        await expectStub(t) { try await s.setResumePosition(.seconds(5), for: id) }
        await expectStub(t) { try await s.setResumePosition(nil, for: id) }
    }

    @Test func setBookmarkSendsNothing() async {
        let t = FixtureTransport()
        let s = V35PlaybackStateService(connection: connection, transport: t)
        await expectStub(t) { try await s.setBookmark(.seconds(5), for: id) }
        await expectStub(t) { try await s.setBookmark(nil, for: id) }
    }
}

// MARK: - Factory and adapter

@Suite("V35AdapterFactory")
struct V35FactoryTests {
    let factory = V35AdapterFactory()

    @Test func name() { #expect(factory.name == "MythTV v35") }

    @Test(arguments: [("v35.0", true), ("v35.1", true), ("v35.0-12-gabcdef", true),
                      ("v34.0", false), ("v36.0", false), ("v37-Pre-676-g5474cf09b0", false)])
    func supports(_ raw: String, _ expected: Bool) throws {
        let version = try #require(BackendVersion(parsing: raw))
        #expect(factory.supports(version) == expected)
    }

    @Test func adapterCapabilitiesAndOptionalServices() throws {
        let version = try #require(BackendVersion(parsing: "v35.0"))
        let t = FixtureTransport()
        let adapter = factory.makeAdapter(connection: connection, version: version, transport: t)
        #expect(adapter.version == version)
        #expect(
            adapter.capabilities
                == [.recordings, .resumePosition, .bookmarks, .commercialBreaks, .deleteRecording])
        #expect(!adapter.capabilities.contains(.liveTV))
        #expect(!adapter.capabilities.contains(.videoLibrary))
        #expect(!adapter.capabilities.contains(.login))
        #expect(adapter.liveTV == nil)
        #expect(adapter.videoLibrary == nil)
        #expect(t.requests.isEmpty)
    }

    @Test func adapterServicesShareTheTransportAndConnection() async throws {
        let version = try #require(BackendVersion(parsing: "v35.0"))
        let t = FixtureTransport()
        t.stub(.get, path: "/Dvr/GetRecorded", body: try fixture("recorded-one"))
        let adapter = factory.makeAdapter(connection: connection, version: version, transport: t)
        let r = try await adapter.recordings.recording(id: RecordingID(rawValue: Expect.firstID))
        #expect(adapter.media.streamURL(for: r).absoluteString.hasPrefix("http://backend:6544/"))
        #expect(t.requests.count == 1)
    }

    @Test func connectsThroughRegistryAndConnector() async throws {
        var registry = AdapterRegistry()
        registry.register(factory)
        let t = FixtureTransport()
        t.stub(.get, path: "/Myth/GetBackendInfo", body: try fixture("backend-info"))
        t.stub(.get, path: "/Myth/GetHostName", body: try fixture("hostname"))
        let connected = try await BackendConnector(registry: registry, transport: t).connect(connection)
        #expect(connected.adapter.version.major == 35)
        #expect(connected.info.version.major == 35)
    }
}
