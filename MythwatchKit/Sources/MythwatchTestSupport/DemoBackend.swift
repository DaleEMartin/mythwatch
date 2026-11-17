import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import Synchronization

/// A whole `AppModel` over the fakes, with a small invented library, for the app's UI tests and
/// for screenshots (SPEC 7 "UI tests"). The app builds it only in debug builds, when launched
/// with `-MythwatchFakes`. Nothing here touches the network: the probe is answered by a
/// `FixtureTransport`, and image URLs point at a closed local port so they fail at once and the
/// screens show their titled placeholders.
@MainActor
public enum DemoBackend {
    /// The address the fake backend answers on, and the one discovery offers.
    public static let connection = BackendConnection(baseURL: URL(string: "http://demo-backend:6544")!)
    public static let hostName = "demo-backend"
    public static let adapterName = "Demo backend"

    /// What goes wrong, for the M5-3 UI tests. The app picks one from a launch argument (SPEC 7
    /// "UI tests").
    public enum Scenario: Sendable {
        /// Everything works.
        case normal
        /// A backend with no recordings.
        case emptyLibrary
        /// The first connect cannot reach the backend; every later one works.
        case unreachableAtLaunch
        /// The backend drops when an episode page first fetches its positions: those fetches
        /// fail, and so does the next library fetch. After that it answers again.
        case outage
    }

    /// An `AppModel` over fakes. With `backendSaved` the settings already hold `connection`
    /// (the app opens on the tabs); without it the app opens on Onboarding.
    public static func appModel(backendSaved: Bool, scenario: Scenario = .normal) -> AppModel {
        let adapter = FakeBackendAdapter(baseURL: URL(string: "http://127.0.0.1:9")!)
        var lengths: [String: Duration] = [:]
        for (recording, resume) in scenario == .emptyLibrary ? [] : library() {
            adapter.store.add(recording, resumePosition: resume, commercialBreaks: commercialBreaks(for: recording))
            let seconds = recording.recordingEnd.timeIntervalSince(recording.recordingStart)
            lengths[String(recording.id.rawValue)] = .seconds(Int(seconds))
        }

        let transport = FixtureTransport()
        // BackendProbe's two version-neutral requests (SPEC 4); the fake adapter takes any version.
        transport.stub(.get, path: "/Myth/GetBackendInfo", body: #"{"BackendInfo": {"Build": {"Version": "v35.0"}}}"#)
        transport.stub(.get, path: "/Myth/GetHostName", body: #"{"String": "\#(hostName)"}"#)
        var registry = AdapterRegistry()
        if scenario == .outage {
            registry.register(OutageAdapterFactory(adapter: OutageAdapter(inner: adapter), name: adapterName))
        } else {
            registry.register(FakeAdapterFactory(name: adapterName, adapter: adapter))
        }

        let discovery = FakeBackendDiscovery()
        discovery.push([DiscoveredBackend(id: hostName, name: "Demo Backend", connection: connection)])
        return AppModel(
            settings: InMemorySettingsStore(AppSettings(backend: backendSaved ? connection : nil)),
            connector: BackendConnector(
                registry: registry,
                transport: scenario == .unreachableAtLaunch ? FirstProbeFails(inner: transport) : transport),
            makeEngine: { DemoPlayerEngine(lengths: lengths) },
            discovery: discovery,
            now: { ContinuousClock.now })
    }

    /// The film (M4-3): three breaks, the middle one around its resume point (1:02:03), so
    /// resuming it skips a break at once and shows the banner. Nothing else has breaks.
    static func commercialBreaks(for recording: Recording) -> [CommercialBreak] {
        guard recording.title == "The Long Voyage" else { return [] }
        return [(1_500, 1_680), (3_600, 3_780), (5_400, 5_580)].compactMap {
            CommercialBreak(start: .seconds($0.0), end: .seconds($0.1))
        }
    }

    /// Invented shows: a few series over two seasons, a film, a show with no season numbers.
    /// Some are watched and some part-watched, so every shelf has something on it.
    public static func library() -> [(Recording, Duration?)] {
        var out: [(Recording, Duration?)] = []
        var id = 100
        let base = Date(timeIntervalSince1970: 1_762_000_000)  // early November 2025
        func add(
            _ title: String, key: String?, season: Int?, episode: Int?, subtitle: String?,
            kind: ProgramKind = .series, daysAgo: Double, watched: Bool = false,
            resume: Duration? = nil, minutes: Double = 30, channel: String = "WDMO"
        ) {
            id += 1
            let start = base.addingTimeInterval(-daysAgo * 86_400)
            var flags: RecordingFlags = watched ? [.watched] : []
            if resume != nil { flags.insert(.hasResumePosition) }
            let recording = Recording.fixture(
                id: RecordingID(rawValue: id), title: title, subtitle: subtitle,
                synopsis: "An invented programme for the demo backend. \(subtitle ?? title) is where the story picks up.",
                kind: kind, category: kind == .movie ? "Film" : "Drama", season: season, episode: episode,
                originalAirDate: CalendarDay(year: 2025, month: 10, day: max(1, 28 - Int(daysAgo))),
                seriesKey: key, scheduledStart: start, scheduledEnd: start.addingTimeInterval(minutes * 60),
                recordingStart: start, recordingEnd: start.addingTimeInterval(minutes * 60),
                lastModified: start.addingTimeInterval(minutes * 60 + (resume == nil ? 0 : 3600)),
                channel: ChannelSummary(number: "4", callSign: channel, name: "Demo Channel"),
                flags: flags)
            out.append((recording, resume))
        }
        for e in 1...4 {
            add("Garden Tales", key: "DEMO-GARDEN", season: 1, episode: e, subtitle: "Spring Planting \(e)",
                daysAgo: Double(20 - e), watched: e < 3)
        }
        for e in 1...3 {
            add("Garden Tales", key: "DEMO-GARDEN", season: 2, episode: e, subtitle: "Autumn Harvest \(e)",
                daysAgo: Double(10 - e), resume: e == 1 ? .seconds(754) : nil)
        }
        for e in 1...5 {
            add("Harbour Lights", key: "DEMO-HARBOUR", season: 3, episode: e, subtitle: "The Tide Turns \(e)",
                daysAgo: Double(15 - e * 2), resume: e == 5 ? .seconds(1_410) : nil, minutes: 60, channel: "WHBR")
        }
        add("The Long Voyage", key: "DEMO-VOYAGE", season: nil, episode: nil, subtitle: nil, kind: .movie,
            daysAgo: 3, resume: .seconds(3_723), minutes: 120, channel: "WFLM")
        for e in 1...2 {
            add("Morning Market", key: nil, season: nil, episode: nil, subtitle: "Market Day \(e)",
                kind: .tvShow, daysAgo: Double(e), minutes: 60)
        }
        for (n, title) in ["Quiet Peaks", "Night Kitchen", "River Road", "Signal Fire", "Copper Valley"]
            .enumerated()
        {
            add(title, key: "DEMO-\(n)", season: 1, episode: 1, subtitle: "Pilot", daysAgo: Double(30 + n))
        }
        return out
    }
}

/// `FakePlayerEngine` that also knows each demo recording's length, so the player shows the
/// remaining time and the breaks on the scrubber. The length comes from the stream URL's last
/// component, the recording id (`FakeMediaLocator`). A seek to the end ends playback, as a real
/// engine does (M5-1: the UI test skips to the end to see the delete offer).
@MainActor final class DemoPlayerEngine: PlayerEngine {
    private let inner = FakePlayerEngine()
    private let lengths: [String: Duration]

    init(lengths: [String: Duration]) { self.lengths = lengths }

    var snapshot: PlayerSnapshot { inner.snapshot }
    var snapshots: AsyncStream<PlayerSnapshot> { inner.snapshots }

    func load(url: URL, startAt: Duration?) {
        if let length = lengths[url.lastPathComponent] { inner.setDuration(length) }
        inner.load(url: url, startAt: startAt)
    }

    func play() { inner.play() }
    func pause() { inner.pause() }
    func seek(to position: Duration) {
        inner.seek(to: position)
        if let length = inner.snapshot.duration, length > .zero, position >= length { inner.emitEnded() }
    }
    func stop() { inner.stop() }
    var audioTracks: [MediaTrack] { inner.audioTracks }
    var subtitleTracks: [MediaTrack] { inner.subtitleTracks }
    var selectedAudioTrack: MediaTrack.ID? {
        get { inner.selectedAudioTrack }
        set { inner.selectedAudioTrack = newValue }
    }
    var selectedSubtitleTrack: MediaTrack.ID? {
        get { inner.selectedSubtitleTrack }
        set { inner.selectedSubtitleTrack = newValue }
    }
}

// MARK: - Scenario helpers (M5-3)

/// Fails the first probe request with `.unreachable`, as a backend that is switched off would,
/// then passes every request to `inner`.
final class FirstProbeFails: HTTPTransport {
    private let inner: any HTTPTransport
    private let failed = Mutex(false)

    init(inner: any HTTPTransport) { self.inner = inner }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let fail = failed.withLock { done in
            defer { done = true }
            return !done
        }
        if fail { throw BackendError.unreachable("DemoBackend: switched off for the first connect") }
        return try await inner.send(request)
    }
}

/// `DemoBackend.Scenario.outage`: the fake adapter, with its recordings and playback state
/// failing for a while once an episode page has asked for a position.
final class OutageAdapter: BackendAdapter, RecordingsService, PlaybackStateService {
    private struct Outage {
        var started = false
        var positionFailuresLeft = 2
        var libraryFailuresLeft = 1
    }

    private let inner: FakeBackendAdapter
    private let outage = Mutex(Outage())

    init(inner: FakeBackendAdapter) { self.inner = inner }

    var version: BackendVersion { inner.version }
    var capabilities: BackendCapabilities { inner.capabilities }
    var recordings: any RecordingsService { self }
    var playbackState: any PlaybackStateService { self }
    var markup: any MarkupService { inner.markup }
    var media: any MediaLocator { inner.media }
    var liveTV: (any LiveTVService)? { nil }
    var videoLibrary: (any VideoLibraryService)? { nil }

    private static let down = BackendError.unreachable("DemoBackend: outage")

    private func positionFetch() throws {
        let fail = outage.withLock { o in
            o.started = true
            guard o.positionFailuresLeft > 0 else { return false }
            o.positionFailuresLeft -= 1
            return true
        }
        if fail { throw Self.down }
    }

    func allRecordings() async throws -> [Recording] {
        let fail = outage.withLock { o in
            guard o.started, o.libraryFailuresLeft > 0 else { return false }
            o.libraryFailuresLeft -= 1
            return true
        }
        if fail { throw Self.down }
        return try await inner.recordings.allRecordings()
    }

    func recording(id: RecordingID) async throws -> Recording { try await inner.recordings.recording(id: id) }
    func setWatched(_ watched: Bool, id: RecordingID) async throws {
        try await inner.recordings.setWatched(watched, id: id)
    }
    func delete(id: RecordingID, allowRerecord: Bool) async throws {
        try await inner.recordings.delete(id: id, allowRerecord: allowRerecord)
    }

    func resumePosition(for id: RecordingID) async throws -> Duration? {
        try positionFetch()
        return try await inner.playbackState.resumePosition(for: id)
    }
    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {
        try await inner.playbackState.setResumePosition(position, for: id)
    }
    func bookmark(for id: RecordingID) async throws -> Duration? {
        try positionFetch()
        return try await inner.playbackState.bookmark(for: id)
    }
    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {
        try await inner.playbackState.setBookmark(position, for: id)
    }
}

struct OutageAdapterFactory: BackendAdapterFactory {
    let adapter: OutageAdapter
    let name: String
    func supports(_ version: BackendVersion) -> Bool { true }
    func makeAdapter(
        connection: BackendConnection, version: BackendVersion, transport: any HTTPTransport
    ) -> any BackendAdapter { adapter }
}
