import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures

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

    /// An `AppModel` over fakes. With `backendSaved` the settings already hold `connection`
    /// (the app opens on the tabs); without it the app opens on Onboarding.
    public static func appModel(backendSaved: Bool) -> AppModel {
        let adapter = FakeBackendAdapter(baseURL: URL(string: "http://127.0.0.1:9")!)
        for (recording, resume) in library() { adapter.store.add(recording, resumePosition: resume) }

        let transport = FixtureTransport()
        // BackendProbe's two version-neutral requests (SPEC 4); the fake adapter takes any version.
        transport.stub(.get, path: "/Myth/GetBackendInfo", body: #"{"BackendInfo": {"Build": {"Version": "v35.0"}}}"#)
        transport.stub(.get, path: "/Myth/GetHostName", body: #"{"String": "\#(hostName)"}"#)
        var registry = AdapterRegistry()
        registry.register(FakeAdapterFactory(name: adapterName, adapter: adapter))

        let discovery = FakeBackendDiscovery()
        discovery.push([DiscoveredBackend(id: hostName, name: "Demo Backend", connection: connection)])
        return AppModel(
            settings: InMemorySettingsStore(AppSettings(backend: backendSaved ? connection : nil)),
            connector: BackendConnector(registry: registry, transport: transport),
            makeEngine: { FakePlayerEngine() },
            discovery: discovery,
            now: { ContinuousClock.now })
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
