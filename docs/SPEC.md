# Mythwatch specification

Mythwatch is a native Apple TV client for MythTV. This document is the contract for implementers.
Read it with:

- `docs/BACKEND-V35.md`: the v35 wire contract (endpoints, JSON shapes, quirks).
- `docs/TASKS.md`: the ordered task list with tests to write first.
- `CLAUDE.md`: working rules for implementing agents.

Type and member names here are normative. Exact Swift spelling may change where the compiler
requires it; when it does, update this file in the same commit.

## 1. Scope

**First release**

- Connect to one MythTV backend over its HTTP services API (default port 6544).
- Browse recordings: Continue Watching and Recently Recorded shelves, a shows grid, a show page
  with episodes by season, an episode detail page.
- Play a recording with standard controls: play/pause, skip forward/back, scrub, resume, audio
  and subtitle track selection, info panel.
- Commercial skipping: auto-skip with undo (default), skip button, or off.
- Write back: resume position, bookmark, watched status, delete.
- Settings: backend address, connection test, playback and commercial-skip options.

**Designed for, not built yet:** more backend versions, Live TV, the Videos library, backend
login, Bonjour discovery of backends (built in the last milestone), an AVPlayer engine, an
iPhone app (section 11).

**Fixed decisions:** Swift 6 language mode with strict concurrency; SwiftUI; tvOS 26 deployment
target; macOS 15 for package tests; iOS 26 declared in the package so it stays buildable for
the later iPhone app; Swift Testing (`import Testing`); VLCKit for playback; MIT
licence; no code copied from MythTV.

## 2. Repository layout

```
mythwatch/
  CLAUDE.md  README.md  LICENSE  THIRD_PARTY_NOTICES.md  .gitignore
  docs/                            SPEC.md, BACKEND-V35.md, TASKS.md
  MythwatchKit/                    Swift package, no UI, no VLCKit
    Package.swift
    Sources/
      MythwatchDomain/
      MythwatchBackend/
      MythBackendV35/
      MythwatchPlayback/
      MythwatchFeatures/
      MythwatchTestSupport/
    Tests/
      MythwatchDomainTests/  MythwatchBackendTests/  MythBackendV35Tests/
      MythwatchPlaybackTests/  MythwatchFeaturesTests/
      MythBackendV35Tests/Fixtures/     captured, sanitised JSON
  Mythwatch/                       tvOS app
    Mythwatch.xcodeproj
    Info.plist
    Mythwatch/                     SwiftUI views, VLCPlayerEngine, AppEnvironment wiring
    MythwatchUITests/
  Tools/capture-fixtures.sh  Tools/check-deps.sh
```

### Target dependency rule (declared in `Package.swift`, enforced by `Tools/check-deps.sh`)

`Package.swift` declares these dependencies but does not enforce them on its own: in a debug
build SwiftPM (seen on Swift 6.4.2) lets a target import any module that is already built and
only prints a "missing a dependency" warning. `Tools/check-deps.sh` scans the imports and fails
on any that the table does not allow. Run it with `swift test`; keep its table identical to this one.

| Target | May depend on |
| --- | --- |
| `MythwatchDomain` | nothing (Foundation only) |
| `MythwatchBackend` | `MythwatchDomain` |
| `MythBackendV35` | `MythwatchBackend`, `MythwatchDomain` |
| `MythwatchPlayback` | `MythwatchDomain` |
| `MythwatchFeatures` | `MythwatchDomain`, `MythwatchBackend`, `MythwatchPlayback` |
| `MythwatchTestSupport` | all of the above except `MythBackendV35` |
| App target | `MythwatchFeatures`, `MythBackendV35` (registration only), VLCKit |

Each test target depends on the target it tests and may also depend on `MythwatchTestSupport`
(and through it on the targets that one may use). `MythwatchTestSupport` has no test target of
its own: tests of the fakes live in the test target of the layer the fake stands in for (for
example `FixtureTransport` is tested in `MythwatchBackendTests`).

`MythwatchFeatures` must not import `MythBackendV35`. Only the app's composition root names it.
No target other than `MythBackendV35` may contain a v35 endpoint path or JSON key.

## 3. Domain (`MythwatchDomain`)

All types are `Sendable` value types, `Hashable` where sensible. Time offsets use `Duration`.
Wall-clock instants use `Date`.

```swift
public struct RecordingID: Hashable, Sendable { public let rawValue: Int }

public enum ProgramKind: Sendable { case series, movie, tvShow, sports, unknown }

public struct RecordingFlags: OptionSet, Sendable, Hashable {
    static let watched, hasBookmark, hasResumePosition, commercialsFlagged, hasCutList,
               recordingInProgress, deletePending, damaged
}

public struct CalendarDay: Hashable, Sendable, Comparable {   // original air date
    public let year: Int, month: Int, day: Int
    public init?(year: Int, month: Int, day: Int)   // nil unless the date exists (year 1...9999)
    public init?(parsing text: String)              // exactly "yyyy-MM-dd", ASCII digits; nil for empty,
                                                    // garbage and impossible dates ("2025-02-30", "2025-13-01")
}

public struct ChannelSummary: Hashable, Sendable { number: String, callSign: String, name: String }

public enum ArtworkKind: Sendable { case poster, fanart, banner }
public struct ArtworkReference: Hashable, Sendable { kind: ArtworkKind; locator: String }  // opaque to everyone but the adapter

public struct VideoTraits: Hashable, Sendable { isHD: Bool; isWidescreen: Bool; verticalResolution: Int? }

public struct Recording: Identifiable, Hashable, Sendable {
    id: RecordingID
    title: String
    subtitle: String?            // nil when empty
    synopsis: String?            // nil when empty
    kind: ProgramKind
    category: String?
    season: Int?                 // nil when the backend reports 0
    episode: Int?                // nil when the backend reports 0
    originalAirDate: CalendarDay?
    seriesKey: String?           // stable id for "the same show"; nil when the backend has none
    scheduledStart: Date, scheduledEnd: Date
    recordingStart: Date, recordingEnd: Date
    lastModified: Date
    fileSize: Int64
    channel: ChannelSummary?
    recordingGroup: String
    flags: RecordingFlags
    video: VideoTraits
    artwork: [ArtworkReference]
}

public struct TimeRange: Hashable, Sendable {
    public let start: Duration, end: Duration
    public init?(start: Duration, end: Duration)    // nil unless start < end
}
public typealias CommercialBreak = TimeRange
```

### Ports

```swift
public struct RecordingQuery: Sendable { /* v1: no fields; fetches every non-deleted, non-LiveTV recording */ }

public protocol RecordingsService: Sendable {
    func allRecordings() async throws -> [Recording]            // adapter pages internally
    func recording(id: RecordingID) async throws -> Recording   // throws BackendError.notFound
    func setWatched(_ watched: Bool, id: RecordingID) async throws
    func delete(id: RecordingID, allowRerecord: Bool) async throws
}

public protocol PlaybackStateService: Sendable {
    func resumePosition(for id: RecordingID) async throws -> Duration?   // nil = none
    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws   // nil clears
    func bookmark(for id: RecordingID) async throws -> Duration?
    func setBookmark(_ position: Duration?, for id: RecordingID) async throws
}

public protocol MarkupService: Sendable {
    func commercialBreaks(for id: RecordingID) async throws -> [CommercialBreak]   // sorted, non-overlapping
}

public protocol MediaLocator: Sendable {
    func streamURL(for recording: Recording) -> URL
    func artworkURL(for reference: ArtworkReference, maxWidth: Int) -> URL?
    func previewImageURL(for recording: Recording, maxWidth: Int) -> URL
}

// Reserved. Declare as empty protocols now so BackendAdapter's shape does not change later.
public protocol LiveTVService: Sendable {}
public protocol VideoLibraryService: Sendable {}
```

### Errors

```swift
public enum BackendError: Error, Sendable, Equatable {
    case unreachable(String)          // DNS, refused, no route
    case timedOut
    case http(status: Int, message: String?)
    case malformedResponse(String)    // JSON did not match the expected shape
    case notFound
    case rejected(String)             // backend said no (returned false or a service exception)
    case unsupportedVersion(String)   // raw version string
    case notAuthorized
}
```

Every adapter and transport maps its failures to `BackendError`. Nothing above the adapter ever
sees `URLError` or `DecodingError`.

## 4. The backend seam (`MythwatchBackend`)

```swift
public struct BackendConnection: Hashable, Sendable, Codable { public var baseURL: URL }   // http://host:6544

public struct BackendVersion: Hashable, Sendable, Comparable {
    public let major: Int, minor: Int, raw: String
    public init?(parsing raw: String)   // "v35.0", "v35.0-12-gabcdef", "v37-Pre-676-g5474cf09b0" (minor 0)
}
// ==, hash and < use (major, minor) only; `raw` is kept for diagnostics and does not take part,
// so "v35.0" == "v35.0-12-gabcdef".

public struct BackendCapabilities: OptionSet, Sendable {
    static let recordings, resumePosition, bookmarks, commercialBreaks, deleteRecording,
               liveTV, videoLibrary, login
}

public protocol BackendAdapter: Sendable {
    var version: BackendVersion { get }
    var capabilities: BackendCapabilities { get }
    var recordings: any RecordingsService { get }
    var playbackState: any PlaybackStateService { get }
    var markup: any MarkupService { get }
    var media: any MediaLocator { get }
    var liveTV: (any LiveTVService)? { get }
    var videoLibrary: (any VideoLibraryService)? { get }
}

public protocol BackendAdapterFactory: Sendable {
    var name: String { get }                                   // "MythTV v35"
    func supports(_ version: BackendVersion) -> Bool
    func makeAdapter(connection: BackendConnection, version: BackendVersion,
                     transport: any HTTPTransport) -> any BackendAdapter
}

public struct AdapterRegistry: Sendable {
    public mutating func register(_ factory: any BackendAdapterFactory)
    public func factory(for version: BackendVersion) throws -> any BackendAdapterFactory
    // first registered factory whose supports() is true; else BackendError.unsupportedVersion(raw)
}

public struct BackendInfo: Sendable, Equatable { version: BackendVersion; hostName: String? }

public struct BackendProbe: Sendable {
    public init(transport: any HTTPTransport)
    public func probe(_ connection: BackendConnection) async throws -> BackendInfo
}

public struct BackendConnector: Sendable {                      // probe + resolve + make
    public init(registry: AdapterRegistry, transport: any HTTPTransport)
    public func connect(_ connection: BackendConnection) async throws -> any BackendAdapter
}
```

`BackendProbe` is the only version-neutral wire code in the app. It calls `GET /Myth/GetBackendInfo`
with `Accept: application/json` and reads `BackendInfo.Build.Version` using a tolerant decoder
that ignores every other field. `/Myth/GetHostName` is optional: any failure (transport error,
non-2xx, unexpected body) gives `hostName == nil`, never an error. A non-2xx reply to
`GetBackendInfo` throws `.http(status:message: nil)`; an undecodable body, a missing
`Build.Version`, or a version string `BackendVersion` cannot parse throws `.malformedResponse`;
transport errors pass through unchanged. `BackendConnector.connect` lets each step's error
surface unchanged.

### HTTP transport

```swift
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }
    var method: Method; var url: URL; var headers: [String: String]; var body: Data?
}
public struct HTTPResponse: Sendable { var status: Int; var headers: [String: String]; var body: Data }

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse   // throws BackendError only
}
public protocol RequestAuthorizer: Sendable {                  // hook for LoginUser on newer backends
    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest
}
```

`URLSessionTransport` (in `MythwatchBackend`): 10 s request timeout, follows redirects, maps
`URLError` to `.unreachable` / `.timedOut`, returns non-2xx responses as values (the adapter
decides what they mean). Accepts an optional `RequestAuthorizer`; v35 passes none.

### Adding a backend version (the procedure the seam exists for)

1. Add target `MythBackendVNN` depending on `MythwatchBackend` and `MythwatchDomain`.
2. Implement `BackendAdapterFactory` and the ports. Copy from the nearest version; do not share
   DTOs between version targets until three versions exist.
3. Capture fixtures from a live backend of that version with `Tools/capture-fixtures.sh`.
4. Make the shared conformance suite (section 9) pass for the new adapter.
5. Register the factory in the app's composition root.

## 5. Playback (`MythwatchPlayback`)

Everything in this target is `@MainActor` and has no I/O of its own.

```swift
public enum PlayerStatus: Sendable, Equatable { case idle, loading, playing, paused, buffering, ended, failed(String) }

public struct PlayerSnapshot: Sendable, Equatable {
    var status: PlayerStatus; var position: Duration; var duration: Duration?; var rate: Double
}
public struct MediaTrack: Identifiable, Sendable, Hashable { id: Int; name: String; language: String? }

@MainActor public protocol PlayerEngine: AnyObject {
    var snapshot: PlayerSnapshot { get }
    var snapshots: AsyncStream<PlayerSnapshot> { get }   // emits on every change; position at least 4x per second while playing
    func load(url: URL, startAt: Duration?)
    func play()
    func pause()
    func seek(to position: Duration)
    func stop()
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var selectedAudioTrack: MediaTrack.ID? { get set }
    var selectedSubtitleTrack: MediaTrack.ID? { get set }   // nil = off
}
```

Time is injected as `now: @MainActor () -> ContinuousClock.Instant`. No timers: all periodic work
is driven by engine snapshots, so tests advance time by feeding snapshots and moving a fake clock.

### 5.1 `CommercialSkipper`

A value type holding state; every method returns effects and performs none.

```swift
public enum CommercialSkipMode: String, Sendable, CaseIterable, Codable { case auto, prompt, off }

public struct CommercialSkipConfig: Sendable, Equatable {
    var mode: CommercialSkipMode = .auto
    var landBeforeEnd: Duration = .seconds(1)       // land this long before the break ends
    var quietPeriod: Duration = .seconds(3)         // no automatic action this soon after a user seek or a skip
    var endGuard: Duration = .seconds(10)           // never skip to within this of the end of the file
    var undoWindow: Duration = .seconds(8)
    var undoRewind: Duration = .seconds(2)
}

public enum SkipEffect: Sendable, Equatable {
    case seek(to: Duration)
    case showSkipped(skipped: Duration, undoUntil: ContinuousClock.Instant)   // banner with "Go back"
    case hideSkipped
    case offerSkip(CommercialBreak)                // prompt mode: show the Skip button
    case withdrawOffer
}

public struct CommercialSkipper: Sendable {
    public init(breaks: [CommercialBreak], config: CommercialSkipConfig)
    public mutating func tick(position: Duration, duration: Duration?, now: ContinuousClock.Instant) -> [SkipEffect]
    public mutating func userSeeked(to position: Duration, now: ContinuousClock.Instant) -> [SkipEffect]
    public mutating func acceptOffer(position: Duration, now: ContinuousClock.Instant) -> [SkipEffect]
    public mutating func undo(now: ContinuousClock.Instant) -> [SkipEffect]
    public static func normalise(_ breaks: [CommercialBreak]) -> [CommercialBreak]   // sort, drop empty, merge overlaps
}
```

Rules (derived from mythfrontend's `CommBreakMap`, restated in time instead of frames):

- **R1 Armed break.** The skipper keeps the index of the *armed* break: the first break whose
  `start` is at or after the current position. It is set at init (position 0), and recomputed by
  `userSeeked`.
- **R2 Auto trigger.** In `.auto`, `tick` fires when `position >= armed.start` and
  `position < armed.end`. It emits `.seek(to: max(armed.start, armed.end - landBeforeEnd))` and
  `.showSkipped`, then arms the next break.
- **R3 Seeking into a break does not skip it.** Because R1 arms the first break starting at or
  after the new position, a break the user lands inside is never armed. It plays.
- **R4 Quiet period.** `tick` takes no automatic action within `quietPeriod` of the last
  `userSeeked` or the last skip. When the quiet period ends, R2 applies only if the armed break
  still qualifies.
- **R5 End guard.** If `duration` is known and `armed.end + endGuard > duration`, do not skip
  that break; arm the next one (there will be none).
- **R6 Passed breaks.** If `position >= armed.end` (playback jumped past it without a seek
  notification), arm the next break without emitting anything.
- **R7 Undo.** `undo` within `undoWindow` of a skip emits `.seek(to: max(0, skipOrigin - undoRewind))`
  and `.hideSkipped`, marks that break *suppressed* for the life of the skipper, and starts a quiet
  period. After the window, `tick` emits `.hideSkipped` once and `undo` does nothing.
- **R8 Suppressed breaks** are never armed again, in any mode.
- **R9 Prompt mode.** `tick` emits `.offerSkip(break)` once when the position enters an armed
  break and `.withdrawOffer` once when it leaves. `acceptOffer` behaves like R2's skip, including
  the banner and undo. R3, R5 and R8 apply; R4 does not delay the offer.
- **R10 Off.** No effects, ever. Breaks are still exposed for the scrubber.
- **R11 Mode change mid-playback** takes effect on the next `tick`, re-arming from the current position.

### 5.2 `PlaybackSession`

```swift
public struct PlaybackSettings: Sendable, Equatable {
    var commercialSkip: CommercialSkipConfig = .init()
    var skipForward: Duration = .seconds(30)
    var skipBackward: Duration = .seconds(10)
    var saveInterval: Duration = .seconds(30)
    var watchedFraction: Double = 0.95
    var minimumResumePosition: Duration = .seconds(10)
}

public enum StartPoint: Sendable, Equatable { case beginning, resume, bookmark }

@MainActor @Observable public final class PlaybackSession {
    public init(recording: Recording, start: StartPoint, engine: any PlayerEngine,
                state: any PlaybackStateService, markup: any MarkupService,
                recordings: any RecordingsService, media: any MediaLocator,
                settings: PlaybackSettings, now: @escaping @MainActor () -> ContinuousClock.Instant)

    public private(set) var snapshot: PlayerSnapshot
    public private(set) var breaks: [CommercialBreak]          // for the scrubber
    public private(set) var banner: SkipBanner?                // .skipped(Duration) or .offer
    public private(set) var problem: String?                   // non-fatal, e.g. "Couldn't save position"

    public func start() async          // loads breaks and start position, then loads the engine and plays
    public func togglePlayPause()
    public func skipForward(); public func skipBackward()
    public func seek(to: Duration)     // user scrub commit
    public func undoCommercialSkip(); public func acceptSkipOffer()
    public func setBookmarkHere() async
    public func finish() async -> PlaybackOutcome   // called when the player screen closes or playback ends
}

public struct PlaybackOutcome: Sendable, Equatable { var position: Duration; var reachedEnd: Bool; var markedWatched: Bool }
```

Behaviour:

- **Start.** Fetch commercial breaks and, for `.resume` / `.bookmark`, the stored position, in
  parallel. A failure to fetch either is not fatal: play from the beginning with no breaks and
  set `problem`. Then `engine.load(url:startAt:)` and `play()`.
- **Position saving.** Save the resume position when `saveInterval` of clock time has passed
  since the last save while playing, on every transition to paused, and in `finish()`. Never save
  a position below `minimumResumePosition`. Saves are fire-and-forget; a failed save sets
  `problem` and never interrupts playback. At most one save in flight; a newer position replaces
  a queued one.
- **Watched.** In `finish()`, if `duration` is known and `position >= duration * watchedFraction`,
  or the engine reported `.ended`: call `setWatched(true)` and clear the resume position (`nil`).
  Otherwise save the position.
- **Seeking.** `skipForward`, `skipBackward` and `seek` clamp to `0...duration`, call
  `engine.seek`, and call `skipper.userSeeked`.
- **Commercials.** Every engine snapshot goes to `skipper.tick`; effects are applied to the
  engine and to `banner`.
- **Failure.** `.failed` from the engine surfaces as `snapshot.status`; the view shows the error
  with Retry and Close.

## 6. Features (`MythwatchFeatures`)

View models are `@MainActor @Observable final class`. They take their dependencies in `init`.
Views never call a service directly.

```swift
public enum Loadable<Value: Sendable>: Sendable { case idle, loading, loaded(Value), failed(UserMessage) }
public struct UserMessage: Sendable, Equatable { title: String; detail: String; canRetry: Bool }
extension UserMessage { init(_ error: BackendError) }   // the one place BackendError becomes user text
```

### 6.1 Library building (pure functions)

```swift
public struct Show: Identifiable, Hashable, Sendable {
    id: String; title: String; kind: ProgramKind; poster: ArtworkReference?
    episodeCount: Int; unwatchedCount: Int; newest: Date; recordings: [Recording]
}
public struct Library: Sendable, Equatable { continueWatching: [Recording]; recentlyRecorded: [Recording]; shows: [Show] }
public struct Season: Identifiable, Hashable, Sendable { id: Int?; title: String; episodes: [Recording] }

public enum LibraryBuilder {
    public static func build(from recordings: [Recording]) -> Library
    public static func seasons(of show: Show) -> [Season]
    public static func sortTitle(_ title: String) -> String
}
```

- **Grouping key:** `seriesKey` when present, otherwise the title lower-cased and trimmed. Two
  recordings with the same title but different `seriesKey` are different shows.
- **Show title:** the most common title in the group. **Poster:** the newest recording's poster.
- **Shows order:** by `sortTitle` (case-insensitive, leading "The ", "A ", "An " ignored).
- **Continue Watching:** `hasResumePosition && !watched && !deletePending`, newest `lastModified`
  first, at most 20.
- **Recently Recorded:** newest `recordingStart` first, at most 20, excluding `deletePending`.
- **Seasons:** grouped by `season`; numbered seasons ascending, then `nil` titled "Other
  Episodes". Inside a season: by `episode` ascending, then `recordingStart`. Movies (`kind ==
  .movie`) get one unnamed season.
- `deletePending` recordings are excluded everywhere.

### 6.2 Settings

```swift
public struct AppSettings: Sendable, Equatable, Codable {
    var backend: BackendConnection?
    var commercialSkipMode: CommercialSkipMode = .auto
    var skipForwardSeconds: Int = 30          // choices 10, 15, 30, 60
    var skipBackwardSeconds: Int = 10         // choices 5, 10, 15, 30
    var deinterlace: Bool = true
    var askBeforeDelete: Bool = true
}
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}
```

`UserDefaultsSettingsStore` stores one JSON blob under the key `settings.v1` and takes its
`UserDefaults` in `init`. Unknown or corrupt data loads as defaults. `InMemorySettingsStore` lives
in test support.

`BackendAddress.parse(_ text: String) -> BackendConnection?` accepts `host`, `host:port`,
`http://host`, `http://host:port`, with surrounding whitespace; default scheme `http`, default
port 6544; rejects empty input and anything with a path or query.

### 6.3 Composition

```swift
@MainActor @Observable public final class AppModel {
    public init(settings: any SettingsStore, connector: BackendConnector,
                makeEngine: @escaping @MainActor () -> any PlayerEngine,
                discovery: any BackendDiscovery,
                now: @escaping @MainActor () -> ContinuousClock.Instant)
    public private(set) var session: Loadable<BackendSession>      // .idle = no backend configured
    public func connect() async                                    // reads settings, probes, builds the adapter
    public func makeLibraryModel() -> LibraryViewModel
    public func makeShowModel(_ show: Show) -> ShowViewModel
    public func makePlaybackSession(_ recording: Recording, start: StartPoint) -> PlaybackSession
    public func makeSettingsModel() -> SettingsViewModel
}
public struct BackendSession: Sendable { let info: BackendInfo; let adapter: any BackendAdapter }

public protocol BackendDiscovery: Sendable { func discover() -> AsyncStream<[DiscoveredBackend]> }
public struct DiscoveredBackend: Identifiable, Hashable, Sendable { id: String; name: String; connection: BackendConnection }
```

The app target builds exactly one `AppModel` with production implementations. Tests build it
with fakes. This is the only place concrete types are chosen.

### 6.4 View models

| View model | State | Actions |
| --- | --- | --- |
| `LibraryViewModel` | `library: Loadable<Library>` | `load()`, `refresh()`; reloads when the player closes |
| `ShowViewModel` | `seasons: [Season]`, selected season | `toggleWatched(_:)`, `delete(_:)` |
| `EpisodeDetailModel` | recording, `resumePosition: Duration?`, `bookmark: Duration?` | `load()`, start points offered: Resume (if position), Play from Bookmark (if bookmark), Play from Beginning |
| `SettingsViewModel` | editable `AppSettings`, `connectionTest: Loadable<BackendInfo>`, `adapterName: String?`, discovered backends | `testConnection()`, `save()`, `select(_ discovered:)` |
| `OnboardingViewModel` | address text, discovered backends, test state | `connect()` |

After a write (`toggleWatched`, `delete`), update local state optimistically and roll back with a
`UserMessage` on failure. Delete removes the recording from the library immediately; the backend
deletes asynchronously, so a refresh shortly after must also filter `deletePending`.

## 7. App target (`Mythwatch`)

SwiftUI only; no logic beyond layout, focus and navigation. Follow Apple's tvOS Human Interface
Guidelines: system fonts and materials, focus engine defaults, no custom focus effects unless a
stock control cannot do the job.

| Screen | Notes |
| --- | --- |
| Root | No backend configured: Onboarding. Otherwise `TabView` with Recordings and Settings. Tabs come from `capabilities` (Live TV and Videos appear when an adapter offers them). |
| Onboarding | Discovered backends list, manual address field, Connect. Shows the detected version, or the unsupported-version message. |
| Recordings | Vertical scroll: Continue Watching shelf (landscape cards with progress), Recently Recorded shelf, then a poster grid of shows. Loading, empty and error states with Retry. |
| Show | Fanart header, season picker, episode list (title, S/E, air date, duration, watched mark, progress). Context menu: Mark Watched/Unwatched, Delete. |
| Episode detail | Synopsis, channel, recorded date, buttons per `EpisodeDetailModel` start points, Delete. |
| Player | Full-screen video with our transport overlay. See below. |
| Settings | Backend (address, detected version, adapter, Test Connection), Playback (skip steps, deinterlace), Commercials (mode), About (version, licences). |

**Player controls** (Siri Remote):

| Input | Action |
| --- | --- |
| Play/Pause, or click centre | Toggle play/pause; shows the transport bar |
| Click left / right | Skip back / forward by the configured step |
| Swipe on the touch surface while paused | Scrub; click to commit, Menu to cancel |
| Swipe down | Panel with Info, Audio, Subtitles tabs |
| Menu / Back | Close panel, else leave the player (calls `finish()`) |
| Select while the "Skipped commercials" banner is focused | Undo |
| Select while the Skip button is shown (prompt mode) | Skip |

The transport bar shows elapsed and remaining time, a scrubber with commercial breaks drawn as
marked segments, and the title. It hides after 5 s of no input. Publish Now Playing info and
handle remote commands through `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`.

`VLCPlayerEngine` implements `PlayerEngine` over VLCKit. It is the only file that imports VLCKit.
It applies deinterlacing when `AppSettings.deinterlace` is true. Requirements beyond that come
from task M0-3's findings.

**VLCKit linking (licence requirement).** VLCKit/libVLC is LGPL. It must be linked
**dynamically**: a separate `.framework` embedded in the app bundle ("Embed & Sign"), never
merged into the app binary. Do not use a static VLCKit build. No Mythwatch source file other than
`VLCPlayerEngine` may import it, and no VLCKit source is copied into this repo. The exact VLCKit
version, where its source can be obtained, and the LGPL text go in `THIRD_PARTY_NOTICES.md` and
the in-app licences screen.

`Info.plist` additions: `NSAppTransportSecurity > NSAllowsLocalNetworking = true`,
`NSLocalNetworkUsageDescription`, `NSBonjourServices = ["_mythbackend._tcp"]`.

## 8. Test support (`MythwatchTestSupport`)

| Fake | Behaviour |
| --- | --- |
| `FixtureTransport` | Maps method + path (+ optional query match) to a canned response or `BackendError`; records every request; an unmatched request throws `.unreachable` whose message includes the full URL (rules below) |
| `FakeRecordingsService`, `FakePlaybackStateService`, `FakeMarkupService`, `FakeMediaLocator` | In-memory state, call log, per-call injectable error, optional suspension point to test in-flight behaviour |
| `FakeBackendAdapter`, `FakeAdapterFactory` | Bundle of the fakes; configurable `supports` |
| `FakePlayerEngine` | Records calls; `emit(_ snapshot:)` drives the stream; `seek` updates position immediately |
| `TestClock` | `@MainActor` class: `now` is a `@MainActor () -> ContinuousClock.Instant`; `advance(by:)` moves it. The origin is one `ContinuousClock.now` reading taken at `init` (the type has no public initialiser); nothing else reads real time |
| `InMemorySettingsStore`, `FakeBackendDiscovery` | as named |
| `Recording.fixture(...)` | Builder with defaults for every field |
| `FixtureLoader` | `data(named:in:subdirectory:)` and `decode(_:named:in:subdirectory:)` read a `.json` file (extension optional in `named`) from a `Bundle` the caller passes (its own `Bundle.module`). A missing or unreadable file throws `FixtureError` whose description names the file |

### `FixtureTransport` rules

- It is a `final class` made `Sendable` by a `Mutex` (from `Synchronization`, available on every
  declared platform), not an actor, so tests register stubs and read the log synchronously.
  It cannot import `Testing`, so failure is a thrown error plus a record: an unmatched request
  throws `BackendError.unreachable("FixtureTransport: no route for GET <full URL>")` and is
  also kept in `unmatchedRequests`, so a test can assert it is empty even if production code
  swallowed the error.
- `requests` holds every request in arrival order, matched or not.
- Stubs: `stub(_ method, path:, query:, response:)`, the same with `status:headers:body:` (String or
  Data), and `stub(_ method, path:, query:, failure:)`.
- A route matches when the method is equal, the path equals the request URL's path exactly, and
  every `query` item is present in the request with an equal value. Extra request items are
  allowed and order is ignored. An empty `query` matches any query string.
- Several matches: the route with the most query items wins. On a tie the route registered first
  wins.

## 9. Testing rules

- Test first. A task is done when its listed tests exist, were seen to fail, and now pass.
- `cd MythwatchKit && swift test` must finish in under 10 s and touch no network, no disk outside
  the bundle's fixtures, and no real clock (`Task.sleep` is banned in tests).
- **Adapter conformance suite:** `AdapterConformance` in `MythwatchTestSupport` is a set of
  behaviour checks written against `BackendAdapter` plus a small `ConformanceScenario` protocol
  that each adapter's test target implements to supply fixtures. Every adapter must pass it.
- **Live tests:** tagged `.live`, skipped unless the environment variable
  `MYTHWATCH_LIVE_BACKEND` is set. Read-only endpoints only.
- **Write tests against a real backend** are manual, on a recording the owner nominates, and are
  listed in `TASKS.md`.

## 10. Later features and where they attach

| Feature | Attaches at |
| --- | --- |
| Another backend version | New `MythBackendVNN` target + registry line (section 4) |
| Backend login | `RequestAuthorizer` + `.login` capability + a Settings section |
| Live TV | `LiveTVService` port, `.liveTV` capability, a new tab; `PlayerEngine` already handles a URL |
| Videos library | `VideoLibraryService` port, `.videoLibrary` capability, a new tab; `PlaybackSession` needs its state/markup ports implemented for videos |
| AVPlayer for H.264/HEVC | Second `PlayerEngine`; `makeEngine` chooses by `VideoTraits` |
| Cut lists | `MarkupService.cutList(for:)`; feed into `CommercialSkipper` as non-undoable ranges |
| Top Shelf extension | Reads `Library.continueWatching` via an app group |
| iPhone app | Second app over the same `MythwatchKit`; see section 11 |

## 11. The later iPhone app

The owner wants an iPhone version eventually. It is not built in the first release, but the
first release must not make it harder. The intended shape: a second app (or a second
destination of the same app target; decide when it is built) with its own SwiftUI views for
touch, sharing all of `MythwatchKit` and the VLC engine.

Rules that apply now:

- **`MythwatchKit` stays platform-neutral.** `Package.swift` declares iOS 26 alongside tvOS 26.
  No package target may import UIKit, TVUIKit or SwiftUI, or use an API marked unavailable on iOS.
  Check with `xcodebuild -scheme MythwatchKit-Package -destination 'generic/platform=iOS' build`
  (run from `MythwatchKit/`) whenever a task adds a new framework import to the package.
- **View models describe intent, not the remote.** Names and state in `MythwatchFeatures` and
  `MythwatchPlayback` must not assume the Siri Remote or the focus engine: `seek(to:)`,
  `skipForward()`, "scrub preview / commit / cancel", not "swipe" or "click". Mapping inputs to
  those calls (section 7, "Player controls") belongs to the tvOS views.
- **The VLCKit choice must cover iOS.** The distribution picked in M0-3 must also ship an iOS
  build of the same version with the same API, dynamically linked. A tvOS-only build is rejected.
- **`VLCPlayerEngine` uses nothing tvOS-only.** It will be shared by both apps. When the iPhone
  app is started it moves out of the tvOS app target into a place both apps can link (a small
  package target that depends on VLCKit); until then it stays where section 7 puts it.

Known work the iPhone app will add, none of it scheduled:

- Touch layouts for every screen and touch player controls; compact-width versions of the shelves.
- App lifecycle: iOS suspends a backgrounded app, so the player must pause (which saves the
  position, section 5.2) when the scene leaves the foreground. tvOS has the same need less often.
- Lock-screen and Control Centre controls: the same Now Playing and remote-command code as tvOS,
  which should then move out of the tvOS views into shared code.
- Away from home: `NSAllowsLocalNetworking` only permits plain HTTP to local addresses. The
  phone app works on the home network or over a VPN into it; reaching a backend by a public
  host name would need HTTPS in front of the backend and is out of scope until asked for.
- Things phone users expect that VLCKit does not give for free: AirPlay video, Picture in
  Picture, and downloads for offline viewing. Each is a separate decision when the app is planned.
