import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchTestSupport
import Synchronization
import Testing

// Proof that each conformance check can fail: deliberately broken adapters, built by patching one
// part of the real v35 adapter from `V35ConformanceScenario`, must make the relevant check report a
// violation. Nothing here is v35-specific beyond the scenario it starts from.

// MARK: - Patchable adapter and scenario

/// A `BackendAdapter` whose every member can be replaced; starts as a copy of `base`.
private struct PatchedAdapter: BackendAdapter {
    var version: BackendVersion
    var capabilities: BackendCapabilities
    var recordings: any RecordingsService
    var playbackState: any PlaybackStateService
    var markup: any MarkupService
    var media: any MediaLocator
    var liveTV: (any LiveTVService)?
    var videoLibrary: (any VideoLibraryService)?

    init(_ base: any BackendAdapter) {
        version = base.version
        capabilities = base.capabilities
        recordings = base.recordings
        playbackState = base.playbackState
        markup = base.markup
        media = base.media
        liveTV = base.liveTV
        videoLibrary = base.videoLibrary
    }
}

/// The v35 scenario's facts and data, with `patch` applied to every adapter it makes.
private struct PatchedScenario: ConformanceScenario {
    let base: V35ConformanceScenario
    var absentIDOverride: RecordingID?
    let patch: @Sendable (inout PatchedAdapter) -> Void

    init(absentID: RecordingID? = nil, _ patch: @escaping @Sendable (inout PatchedAdapter) -> Void)
        throws
    {
        base = try V35ConformanceScenario()
        absentIDOverride = absentID
        self.patch = patch
    }

    var connection: BackendConnection { base.connection }
    var absentID: RecordingID { absentIDOverride ?? base.absentID }
    var idWithBreaks: RecordingID { base.idWithBreaks }
    var idWithoutStoredPosition: RecordingID { base.idWithoutStoredPosition }
    var idWithResumePosition: RecordingID? { base.idWithResumePosition }
    var idWithBookmark: RecordingID? { base.idWithBookmark }

    func makeAdapter() async throws -> any BackendAdapter {
        var adapter = PatchedAdapter(try await base.makeAdapter())
        patch(&adapter)
        return adapter
    }
}

/// Runs `check` against the patched scenario and returns its violations.
private func violations(
    _ check: AdapterConformance.Check, absentID: RecordingID? = nil,
    _ patch: @escaping @Sendable (inout PatchedAdapter) -> Void
) async throws -> [String] {
    await check.violations(in: try PatchedScenario(absentID: absentID, patch))
}

/// The check found something, and at least one message mentions `phrase`.
private func expectCaught(
    _ found: [String], mentioning phrase: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!found.isEmpty, "the check reported nothing", sourceLocation: sourceLocation)
    #expect(
        found.contains { $0.localizedCaseInsensitiveContains(phrase) },
        "no message mentions \"\(phrase)\": \(found)", sourceLocation: sourceLocation)
}

// MARK: - Broken services

/// Pass-through recordings service with replaceable reads. Writes are recorded in `writes` (when
/// given) and throw.
private struct RecordingsOverride: RecordingsService {
    let base: any RecordingsService
    var all: (@Sendable (any RecordingsService) async throws -> [Recording])?
    var one: (@Sendable (any RecordingsService, RecordingID) async throws -> Recording)?
    var writes: WriteLog?

    func allRecordings() async throws -> [Recording] {
        if let all { return try await all(base) }
        return try await base.allRecordings()
    }

    func recording(id: RecordingID) async throws -> Recording {
        if let one { return try await one(base, id) }
        return try await base.recording(id: id)
    }

    func setWatched(_ watched: Bool, id: RecordingID) async throws {
        writes?.record("setWatched")
        throw BackendError.rejected("test double")
    }

    func delete(id: RecordingID, allowRerecord: Bool) async throws {
        writes?.record("delete")
        throw BackendError.rejected("test double")
    }
}

/// Positions that are fixed for every id. Writes are recorded (when a log is given) and throw.
private struct FixedPositions: PlaybackStateService {
    var resume: Duration?
    var stored: Duration?
    var writes: WriteLog?

    func resumePosition(for id: RecordingID) async throws -> Duration? { resume }
    func bookmark(for id: RecordingID) async throws -> Duration? { stored }

    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {
        writes?.record("setResumePosition")
        throw BackendError.rejected("test double")
    }

    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {
        writes?.record("setBookmark")
        throw BackendError.rejected("test double")
    }
}

/// The same breaks for every id.
private struct FixedBreaks: MarkupService {
    let breaks: [CommercialBreak]
    func commercialBreaks(for id: RecordingID) async throws -> [CommercialBreak] { breaks }
}

/// Pass-through media locator with replaceable URLs.
private struct MediaOverride: MediaLocator {
    let base: any MediaLocator
    var stream: (@Sendable (Recording) -> URL)?
    var preview: (@Sendable (Recording) -> URL)?
    var artwork: (@Sendable (ArtworkReference) -> URL?)?

    func streamURL(for recording: Recording) -> URL {
        stream?(recording) ?? base.streamURL(for: recording)
    }
    func previewImageURL(for recording: Recording, maxWidth: Int) -> URL {
        preview?(recording) ?? base.previewImageURL(for: recording, maxWidth: maxWidth)
    }
    func artworkURL(for reference: ArtworkReference, maxWidth: Int) -> URL? {
        if let artwork { return artwork(reference) }
        return base.artworkURL(for: reference, maxWidth: maxWidth)
    }
}

private struct StubLiveTV: LiveTVService {}
private struct StubVideoLibrary: VideoLibraryService {}

/// Counts calls; `Mutex` makes it `Sendable` without `@unchecked`.
private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}

/// Names of write methods called on a spy.
private final class WriteLog: Sendable {
    private let names = Mutex<[String]>([])
    func record(_ name: String) { names.withLock { $0.append(name) } }
    var all: [String] { names.withLock { $0 } }
}

private func range(_ startSeconds: Int, _ endSeconds: Int) -> CommercialBreak {
    CommercialBreak(start: .seconds(startSeconds), end: .seconds(endSeconds))!
}

/// `url` with its host replaced.
private func moved(_ url: URL, toHost host: String) -> URL {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.host = host
    return parts.url!
}

/// `url` reduced to its path and query, with no scheme or host.
private func relative(_ url: URL) -> URL {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.scheme = nil
    parts.host = nil
    parts.port = nil
    return parts.url!
}

// MARK: - Each check catches its breakage

@Suite("Adapter conformance catches broken adapters")
struct ConformanceCatchesTests {
    // List: unique ids

    @Test func duplicateIDs() async throws {
        let found = try await violations(.listIDsAreUnique) { a in
            a.recordings = RecordingsOverride(base: a.recordings, all: { base in
                let list = try await base.allRecordings()
                return list + [list[2]]
            })
        }
        expectCaught(found, mentioning: "45")
    }

    // List: stable order

    @Test func unstableOrder() async throws {
        let calls = Counter()
        let found = try await violations(.listOrderIsStable) { a in
            a.recordings = RecordingsOverride(base: a.recordings, all: { base in
                let list = try await base.allRecordings()
                return calls.next().isMultiple(of: 2) ? list.reversed() : list
            })
        }
        expectCaught(found, mentioning: "order")
    }

    @Test func listThatChangesLengthIsUnstable() async throws {
        let calls = Counter()
        let found = try await violations(.listOrderIsStable) { a in
            a.recordings = RecordingsOverride(base: a.recordings, all: { base in
                let list = try await base.allRecordings()
                return calls.next() == 1 ? list : Array(list.dropLast())
            })
        }
        expectCaught(found, mentioning: "86")
    }

    // recording(id:) equals the listed value

    @Test func fetchedValueDiffersFromListedValue() async throws {
        let found = try await violations(.recordingByIDEqualsListedValue) { a in
            a.recordings = RecordingsOverride(base: a.recordings, one: { base, id in
                var r = try await base.recording(id: id)
                if id.rawValue == 64 { r.title += " (changed)" }
                return r
            })
        }
        #expect(found.count == 1)
        expectCaught(found, mentioning: "title")
        expectCaught(found, mentioning: "64")
    }

    @Test func fetchedValueDiffersOnlyBelowASecond() async throws {
        // Dates print to the second; the check must still see the difference.
        let found = try await violations(.recordingByIDEqualsListedValue) { a in
            a.recordings = RecordingsOverride(base: a.recordings, one: { base, id in
                var r = try await base.recording(id: id)
                r.lastModified += 0.25
                return r
            })
        }
        expectCaught(found, mentioning: "lastModified")
    }

    /// The list reports `recordingInProgress` for id 64; the fetch (as on a real backend) does not.
    private static func listsInProgress(_ a: inout PatchedAdapter) {
        a.recordings = RecordingsOverride(
            base: a.recordings,
            all: { base in
                try await base.allRecordings().map { r in
                    var r = r
                    if r.id.rawValue == 64 { r.flags.insert(.recordingInProgress) }
                    return r
                }
            })
    }

    @Test func inProgressRecordingMayDifferInFlagsOnly() async throws {
        let found = try await violations(.recordingByIDEqualsListedValue) { a in Self.listsInProgress(&a) }
        #expect(found.isEmpty, "\(found)")
    }

    @Test func inProgressRecordingDifferingInAnotherFieldIsCaught() async throws {
        let found = try await violations(.recordingByIDEqualsListedValue) { a in
            Self.listsInProgress(&a)
            let all = a.recordings
            a.recordings = RecordingsOverride(
                base: all,
                all: { _ in try await all.allRecordings() },
                one: { base, id in
                    var r = try await base.recording(id: id)
                    if id.rawValue == 64 { r.fileSize += 1 }
                    return r
                })
        }
        expectCaught(found, mentioning: "fileSize")
        expectCaught(found, mentioning: "64")
    }

    @Test func finishedRecordingDifferingInFlagsIsCaught() async throws {
        let found = try await violations(.recordingByIDEqualsListedValue) { a in
            a.recordings = RecordingsOverride(base: a.recordings, one: { base, id in
                var r = try await base.recording(id: id)
                if id.rawValue == 64 { r.flags.insert(.watched) }
                return r
            })
        }
        expectCaught(found, mentioning: "flags")
        expectCaught(found, mentioning: "64")
    }

    @Test func listedIDThatCannotBeFetched() async throws {
        let found = try await violations(.recordingByIDEqualsListedValue) { a in
            a.recordings = RecordingsOverride(base: a.recordings, one: { base, id in
                if id.rawValue == 35 { throw BackendError.notFound }
                return try await base.recording(id: id)
            })
        }
        expectCaught(found, mentioning: "35")
    }

    // Unknown id → .notFound

    @Test func unknownIDReturnsAValue() async throws {
        let found = try await violations(.unknownIDThrowsNotFound) { a in
            a.recordings = RecordingsOverride(base: a.recordings, one: { base, id in
                if let found = try? await base.recording(id: id) { return found }
                return try await base.allRecordings()[0]
            })
        }
        expectCaught(found, mentioning: "notFound")
    }

    @Test func unknownIDThrowsTheWrongError() async throws {
        let found = try await violations(.unknownIDThrowsNotFound) { a in
            a.recordings = RecordingsOverride(base: a.recordings, one: { _, _ in
                throw BackendError.malformedResponse("blank programme")
            })
        }
        expectCaught(found, mentioning: "malformedResponse")
    }

    @Test func scenarioWhoseAbsentIDIsListed() async throws {
        let found = try await violations(.unknownIDThrowsNotFound, absentID: RecordingID(rawValue: 33)) { _ in }
        expectCaught(found, mentioning: "listed")
    }

    // Commercial breaks

    @Test func overlappingBreaks() async throws {
        let found = try await violations(.commercialBreaksAreWellFormed) { a in
            a.markup = FixedBreaks(breaks: [range(0, 60), range(30, 90)])
        }
        expectCaught(found, mentioning: "overlap")
    }

    @Test func unsortedBreaks() async throws {
        let found = try await violations(.commercialBreaksAreWellFormed) { a in
            a.markup = FixedBreaks(breaks: [range(200, 260), range(0, 60)])
        }
        expectCaught(found, mentioning: "sorted")
    }

    @Test func noBreaksForTheRecordingThatHasThem() async throws {
        let found = try await violations(.commercialBreaksAreWellFormed) { a in
            a.markup = FixedBreaks(breaks: [])
        }
        expectCaught(found, mentioning: "33")
    }

    // Positions

    @Test func resumePositionWhenNoneIsStored() async throws {
        let found = try await violations(.positionIsNilWhenNoneStored) { a in
            a.playbackState = FixedPositions(resume: .seconds(5), stored: nil)
        }
        expectCaught(found, mentioning: "resumePosition")
    }

    @Test func bookmarkWhenNoneIsStored() async throws {
        let found = try await violations(.positionIsNilWhenNoneStored) { a in
            a.playbackState = FixedPositions(resume: nil, stored: .seconds(5))
        }
        expectCaught(found, mentioning: "bookmark")
    }

    @Test func noResumePositionForTheRecordingThatHasOne() async throws {
        let found = try await violations(.positionIsNilWhenNoneStored) { a in
            a.playbackState = FixedPositions(resume: nil, stored: nil)
        }
        expectCaught(found, mentioning: "69")
    }

    // Media URLs

    @Test func streamURLOnAnotherHost() async throws {
        let found = try await violations(.mediaURLsAreUnderBaseURL) { a in
            let base = a.media
            a.media = MediaOverride(base: base, stream: { moved(base.streamURL(for: $0), toHost: "elsewhere") })
        }
        expectCaught(found, mentioning: "streamURL")
    }

    @Test func streamURLOnAHostThatOnlyStartsTheSame() async throws {
        let found = try await violations(.mediaURLsAreUnderBaseURL) { a in
            let base = a.media
            a.media = MediaOverride(base: base, stream: { moved(base.streamURL(for: $0), toHost: "backend.evil") })
        }
        expectCaught(found, mentioning: "streamURL")
    }

    @Test func relativeStreamURL() async throws {
        let found = try await violations(.mediaURLsAreUnderBaseURL) { a in
            let base = a.media
            a.media = MediaOverride(base: base, stream: { relative(base.streamURL(for: $0)) })
        }
        expectCaught(found, mentioning: "not absolute")
    }

    @Test func previewURLOnAnotherHost() async throws {
        let found = try await violations(.mediaURLsAreUnderBaseURL) { a in
            let base = a.media
            a.media = MediaOverride(base: base, preview: {
                moved(base.previewImageURL(for: $0, maxWidth: 320), toHost: "elsewhere")
            })
        }
        expectCaught(found, mentioning: "previewImageURL")
    }

    @Test func artworkURLOnAnotherHost() async throws {
        let found = try await violations(.mediaURLsAreUnderBaseURL) { a in
            let base = a.media
            a.media = MediaOverride(base: base, artwork: { ref in
                base.artworkURL(for: ref, maxWidth: 320).map { moved($0, toHost: "elsewhere") }
            })
        }
        expectCaught(found, mentioning: "artworkURL")
    }

    @Test func relativeArtworkURL() async throws {
        let found = try await violations(.mediaURLsAreUnderBaseURL) { a in
            let base = a.media
            a.media = MediaOverride(base: base, artwork: { ref in
                base.artworkURL(for: ref, maxWidth: 320).map(relative)
            })
        }
        expectCaught(found, mentioning: "not absolute")
    }

    // Capabilities and optional services

    @Test func advertisesLiveTVWithoutTheService() async throws {
        let found = try await violations(.capabilitiesMatchOptionalServices) { a in
            a.capabilities.insert(.liveTV)
        }
        expectCaught(found, mentioning: "liveTV")
    }

    @Test func liveTVServiceWithoutTheCapability() async throws {
        let found = try await violations(.capabilitiesMatchOptionalServices) { a in
            a.liveTV = StubLiveTV()
        }
        expectCaught(found, mentioning: "liveTV")
    }

    @Test func advertisesVideoLibraryWithoutTheService() async throws {
        let found = try await violations(.capabilitiesMatchOptionalServices) { a in
            a.capabilities.insert(.videoLibrary)
        }
        expectCaught(found, mentioning: "videoLibrary")
    }

    @Test func videoLibraryServiceWithoutTheCapability() async throws {
        let found = try await violations(.capabilitiesMatchOptionalServices) { a in
            a.videoLibrary = StubVideoLibrary()
        }
        expectCaught(found, mentioning: "videoLibrary")
    }

    @Test func bothOptionalServicesWithTheirCapabilitiesPass() async throws {
        let found = try await violations(.capabilitiesMatchOptionalServices) { a in
            a.capabilities.formUnion([.liveTV, .videoLibrary])
            a.liveTV = StubLiveTV()
            a.videoLibrary = StubVideoLibrary()
        }
        #expect(found.isEmpty, "\(found)")
    }

    // Failures and thin data are reported, not swallowed

    @Test(arguments: [
        AdapterConformance.Check.listIDsAreUnique, .listOrderIsStable,
        .recordingByIDEqualsListedValue, .commercialBreaksAreWellFormed, .mediaURLsAreUnderBaseURL,
    ])
    func failingListIsReported(_ check: AdapterConformance.Check) async throws {
        let found = try await violations(check) { a in
            a.recordings = RecordingsOverride(base: a.recordings, all: { _ in throw BackendError.timedOut })
        }
        expectCaught(found, mentioning: "timedOut")
    }

    @Test(arguments: [
        AdapterConformance.Check.listIDsAreUnique, .listOrderIsStable,
        .recordingByIDEqualsListedValue, .commercialBreaksAreWellFormed, .mediaURLsAreUnderBaseURL,
    ])
    func listShorterThanTwoIsReported(_ check: AdapterConformance.Check) async throws {
        let found = try await violations(check) { a in
            a.recordings = RecordingsOverride(base: a.recordings, all: { base in
                Array(try await base.allRecordings().prefix(1))
            })
        }
        expectCaught(found, mentioning: "at least two")
    }

    @Test func scenarioThatCannotMakeAnAdapterFailsEveryCheck() async {
        struct Failing: ConformanceScenario {
            let connection = BackendConnection(baseURL: URL(string: "http://backend:6544")!)
            let absentID = RecordingID(rawValue: 0)
            let idWithBreaks = RecordingID(rawValue: 1)
            let idWithoutStoredPosition = RecordingID(rawValue: 1)
            let idWithResumePosition: RecordingID? = nil
            let idWithBookmark: RecordingID? = nil
            func makeAdapter() async throws -> any BackendAdapter { throw BackendError.timedOut }
        }
        for check in AdapterConformance.Check.allCases {
            expectCaught(await check.violations(in: Failing()), mentioning: "makeAdapter")
        }
    }

    // The suite never writes

    @Test func noCheckCallsAWriteMethod() async throws {
        let log = WriteLog()
        let scenario = try PatchedScenario { a in
            a.recordings = RecordingsOverride(base: a.recordings, writes: log)
            a.playbackState = SpyPositions(base: a.playbackState, writes: log)
        }
        for check in AdapterConformance.Check.allCases {
            let found = await check.violations(in: scenario)
            #expect(found.isEmpty, "\(check): \(found)")
        }
        #expect(log.all.isEmpty)
    }
}

/// Pass-through positions with writes recorded.
private struct SpyPositions: PlaybackStateService {
    let base: any PlaybackStateService
    let writes: WriteLog

    func resumePosition(for id: RecordingID) async throws -> Duration? {
        try await base.resumePosition(for: id)
    }
    func bookmark(for id: RecordingID) async throws -> Duration? { try await base.bookmark(for: id) }
    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {
        writes.record("setResumePosition")
        throw BackendError.rejected("test double")
    }
    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {
        writes.record("setBookmark")
        throw BackendError.rejected("test double")
    }
}

// MARK: - The rules themselves

@Suite("Adapter conformance rules: URLs and break ranges")
struct ConformanceRuleTests {
    private static let base = URL(string: "http://backend:6544")!

    @Test(arguments: [
        "http://backend:6544/Content/x?a=b",
        "http://backend:6544",
        "http://backend:6544/",
        "HTTP://BACKEND:6544/Content/x",
    ])
    func underTheBase(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(AdapterConformance.isAbsolute(url))
        #expect(AdapterConformance.isURL(url, under: Self.base))
    }

    @Test(arguments: [
        "http://backendx:6544/Content/x",       // host that merely starts the same
        "http://backend.evil:6544/Content/x",   // ditto, with a dot
        "http://xbackend:6544/Content/x",       // host that merely ends the same
        "http://backend:6544@evil/Content/x",   // base as user info, real host elsewhere
        "https://backend:6544/Content/x",       // scheme differs
        "http://backend:65440/Content/x",       // port that merely starts the same
        "http://backend/Content/x",             // default port 80, not 6544
        "http://elsewhere:6544/Content/x",
    ])
    func notUnderTheBase(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!AdapterConformance.isURL(url, under: Self.base))
    }

    @Test func relativeURLsAreNotAbsoluteAndNotUnderTheBase() throws {
        for text in ["/Content/x?a=b", "Content/x", "//backend:6544/Content/x"] {
            let url = try #require(URL(string: text))
            #expect(!AdapterConformance.isAbsolute(url), "\(text)")
            #expect(!AdapterConformance.isURL(url, under: Self.base), "\(text)")
        }
        // Relative to the base still needs the base to resolve, so it does not stand alone.
        let resolved = try #require(URL(string: "/Content/x", relativeTo: Self.base))
        #expect(!AdapterConformance.isAbsolute(resolved))
    }

    @Test func defaultPortsAreEquivalentToExplicitOnes() throws {
        let base = try #require(URL(string: "http://backend"))
        #expect(AdapterConformance.isURL(try #require(URL(string: "http://backend:80/x")), under: base))
        #expect(AdapterConformance.isURL(try #require(URL(string: "http://backend/x")), under: base))
        #expect(!AdapterConformance.isURL(try #require(URL(string: "http://backend:8080/x")), under: base))
    }

    @Test func basePathIsAWholeSegmentPrefix() throws {
        let base = try #require(URL(string: "http://backend:6544/myth"))
        let slashBase = try #require(URL(string: "http://backend:6544/myth/"))
        for b in [base, slashBase] {
            #expect(AdapterConformance.isURL(try #require(URL(string: "http://backend:6544/myth")), under: b))
            #expect(AdapterConformance.isURL(try #require(URL(string: "http://backend:6544/myth/x?a=b")), under: b))
            #expect(!AdapterConformance.isURL(try #require(URL(string: "http://backend:6544/mythtv/x")), under: b))
            #expect(!AdapterConformance.isURL(try #require(URL(string: "http://backend:6544/x")), under: b))
        }
    }

    @Test func wellFormedBreaksHaveNoViolations() {
        let spans: [(start: Duration, end: Duration)] = [
            (.zero, .seconds(60)), (.seconds(60), .seconds(90)), (.seconds(200), .seconds(260)),
        ]
        #expect(AdapterConformance.breakViolations(spans).isEmpty)
        #expect(AdapterConformance.breakViolations([]).isEmpty)
    }

    /// `TimeRange` cannot hold an empty range (its initialiser returns nil), so an adapter cannot
    /// return one today; the rule is checked on raw spans instead.
    @Test func emptyRangesAreViolations() {
        #expect(CommercialBreak(start: .seconds(5), end: .seconds(5)) == nil)
        let zero = AdapterConformance.breakViolations([(.seconds(5), .seconds(5))])
        #expect(zero.count == 1)
        #expect(zero.first?.contains("empty") == true)
        let backwards = AdapterConformance.breakViolations([(.seconds(9), .seconds(5))])
        #expect(backwards.first?.contains("empty") == true)
    }

    @Test func unsortedAndOverlappingSpansAreViolations() {
        let unsorted = AdapterConformance.breakViolations([(.seconds(100), .seconds(160)), (.zero, .seconds(60))])
        #expect(unsorted.count == 1)
        #expect(unsorted.first?.contains("sorted") == true)
        let overlapping = AdapterConformance.breakViolations([(.zero, .seconds(60)), (.seconds(59), .seconds(90))])
        #expect(overlapping.count == 1)
        #expect(overlapping.first?.contains("overlap") == true)
    }
}
