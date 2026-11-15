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

public struct ConnectedBackend: Sendable { public let info: BackendInfo; public let adapter: any BackendAdapter }

public struct BackendConnector: Sendable {                      // probe + resolve + make
    public init(registry: AdapterRegistry, transport: any HTTPTransport)
    public func connect(_ connection: BackendConnection) async throws -> ConnectedBackend
}
```

`connect` returns the probed `BackendInfo` with the adapter (changed in M2-4), so a caller that
needs the host name never probes a second time. `ConnectedBackend` lives here rather than in
`MythwatchFeatures` because the connector cannot depend on that target; `AppModel` copies it into
a `BackendSession`.

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

```swift
public struct URLSessionTransport: HTTPTransport {
    public static let requestTimeout: TimeInterval        // 10
    public init(configuration: URLSessionConfiguration = .default,
                authorizer: (any RequestAuthorizer)? = nil)
}
```

`URLSessionTransport` (in `MythwatchBackend`): 10 s request timeout, follows redirects, returns
non-2xx responses as values (the adapter decides what they mean). Accepts an optional
`RequestAuthorizer`; v35 passes none. The initialiser copies `configuration` (tests inject an
ephemeral one with a stub `URLProtocol`) and sets its request timeout to 10 s. The authorizer is
applied to each request before sending. It throws `BackendError` only, mapped as follows:

| Failure | Result |
| --- | --- |
| `URLError.timedOut` | `.timedOut` |
| `badServerResponse`, `cannotParseResponse`, `cannotDecodeRawData`, `cannotDecodeContentData`, `zeroByteResource`, `httpTooManyRedirects`, `redirectToNonExistentLocation`, `dataLengthExceedsMaximum` | `.malformedResponse(description)` |
| every other `URLError` (refused, DNS, offline, lost connection, roaming, TLS, bad URL, cancelled, unknown) | `.unreachable(description)` |
| a reply that is not an HTTP response | `.malformedResponse` |
| any non-`URLError` failure from the session | `.unreachable(description)` |
| authorizer throws a `BackendError` | passed through unchanged, nothing is sent |
| authorizer throws a `URLError` | mapped by the rows above |
| authorizer throws anything else | `.notAuthorized` |

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
extension Loadable { var value: Value?; var message: UserMessage?; var isIdle: Bool; var isLoading: Bool }
extension Loadable: Equatable where Value: Equatable {}
public struct UserMessage: Sendable, Equatable { title: String; detail: String; canRetry: Bool }
extension UserMessage {
    init(_ error: BackendError)          // the one place BackendError becomes user text
    static let unexpected: UserMessage   // any other failure; never shows the error's description
}
```

**Wording.** Written for someone on a sofa with a remote: what happened and what to try, in
short sentences; no error codes, no jargon, no exclamation marks, no blame. Titles use title
case (tvOS alert style). The strings inside `BackendError` cases (transport descriptions, HTML
bodies, internal notes) are diagnostics and are **never shown**; the one exception is the version
string of `.unsupportedVersion`, which the detail names. `canRetry` means trying the same thing
again could succeed (the view offers Try Again); when it is false the detail says what to do
instead.

| Case | Title | Detail | `canRetry` |
| --- | --- | --- | --- |
| `.unreachable` | Can't Reach Your MythTV Backend | Make sure the backend is turned on and connected to your home network, then try again. If that doesn't help, check the address in Settings. | yes |
| `.timedOut` | Your MythTV Backend Didn't Answer in Time | It may be busy or still starting up. Wait a moment, then try again. | yes |
| `.http` | Your MythTV Backend Had a Problem | It couldn't answer just now. Try again in a moment. If this keeps happening, check that the address in Settings is your MythTV backend. | yes |
| `.malformedResponse` | Mythwatch Didn't Understand the Reply | The address in Settings may not be a MythTV backend, or the backend sent something unexpected. Check the address, then try again. | yes |
| `.notFound` | This Recording Is No Longer Available | It may have been deleted. Go back and refresh to see what's on the backend now. | no |
| `.rejected` | Your MythTV Backend Turned That Down | It wouldn't do what Mythwatch asked, so nothing was changed. | no |
| `.unsupportedVersion(v)` | This Version of MythTV Isn't Supported | Your backend is running MythTV *v*, which this version of Mythwatch can't work with. (Blank *v*: "running a version of MythTV, which …".) | no |
| `.notAuthorized` | Your MythTV Backend Wants a Sign-In | Mythwatch can't sign in to a backend yet, so it can only use one that doesn't ask for a password. | no |
| any other error (`unexpected`) | Something Went Wrong | Mythwatch ran into a problem it didn't expect. Try again. | yes |

`.malformedResponse` is retryable because a cut-off reply from a busy backend is transient; a
host that is not a MythTV backend fails the same way again and the detail points at Settings.

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

Input order never matters: the same recordings in any order give an identical `Library`. All
string comparison is Swift's `String <` (Unicode canonical order, no locale), so "10" sorts before
"2". `deletePending` recordings are dropped first and take no part in anything below; a show whose
recordings are all `deletePending` does not exist. "Newer" means later `recordingStart`, then
higher `id`.

- **Normalised title:** case- and diacritic-folded (`locale: nil`), surrounding whitespace removed,
  inner whitespace runs collapsed to one space.
- **Grouping key and `Show.id`:** `"series:" + seriesKey` when `seriesKey` is non-blank, otherwise
  `"title:" + normalised title`. The id is the key, so it is stable across refreshes and a keyed
  show cannot collide with a title show. A keyless recording never joins a keyed group; two
  recordings with the same title but different keys are different shows.
- **Show title:** the most common title in the group (compared after trimming surrounding
  whitespace); a tie goes to the smaller title.
- **Show fields:** `kind` is the newest recording's kind. `poster` is the first `.poster` artwork of
  the newest recording that has one, else nil. `newest` is the latest `recordingStart`.
  `recordings` is newest first. `episodeCount` counts recordings (the same episode recorded twice
  counts twice); `unwatchedCount` counts those without `watched`.
- **`sortTitle`:** the normalised title with leading non-alphanumeric characters dropped, then a
  leading "the ", "a " or "an " dropped only when more text follows it ("The", "A" and "An" keep
  their names). A title with no letters or digits keeps its punctuation; a blank title gives "".
- **Shows order:** by `sortTitle`, then by title, then by id.
- **Continue Watching:** `hasResumePosition && !watched` (recordings still being recorded are
  included), newest `lastModified` first, ties newer first, at most 20 after filtering and sorting.
- **Recently Recorded:** newer first, at most 20. Watched and in-progress recordings are included.
- **Seasons:** grouped by `season`; numbered seasons ascending (`id` the number, title "Season 3"),
  then the `nil` group (`id` nil, title "Other Episodes"), which is also the only season of a show
  with no season numbers. Inside a season: `episode` ascending with no episode number last, then
  `recordingStart` ascending, then `id` ascending. A show whose `kind` is `.movie` gets one season
  (`id` nil, title "") holding all its recordings (several airings), ordered by `recordingStart`
  ascending then `id`. A show with no recordings has no seasons.

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
`UserDefaults` in `init`. It is `@unchecked Sendable` (the SDK does not declare `UserDefaults`
`Sendable`; the store holds one immutable reference to a thread-safe object). `InMemorySettingsStore`
lives in test support.

Loading never throws and never discards more than it must:

- No value, a value under the key that is not `Data`, empty data, data that is not JSON, or JSON
  that is not an object: the whole of `AppSettings()` (defaults).
- Unknown keys are ignored. A missing key loads as that field's default and the other fields keep
  their stored values (`AppSettings` has a hand-written `init(from:)`, so settings added in a later
  version never wipe an existing user's).
- A field whose value has the wrong type, an unknown `commercialSkipMode` string, or a skip step
  outside its choices (forward 10/15/30/60, backward 5/10/15/30; exposed as
  `AppSettings.skipForwardChoices` / `skipBackwardChoices`) loads as that field's default; the other
  fields are unaffected. Values are not clamped to the nearest choice.

`CommercialSkipMode` (section 5.1) is the only `MythwatchPlayback` type `AppSettings` needs; it
was added ahead of task M4-1 so M2-1 could build.

`BackendAddress.parse(_ text: String) -> BackendConnection?` is pure and makes no request. Rules,
applied after trimming surrounding whitespace and newlines:

- Accepts `host`, `host:port`, `http://host`, `http://host:port`, and the same with `https://`.
  Default scheme `http`; default port 6544 whatever the scheme (`https://host` gives
  `https://host:6544`). The result's `baseURL` always has scheme, host and explicit port, and no
  path, query or fragment, e.g. `http://host:6544`.
- The scheme is case-insensitive and must be `http` or `https`; anything else (`ftp://host`) is nil.
- The host is lower-cased (`MyBackend.LOCAL` gives `mybackend.local`). It must be a name of
  dot-separated non-empty labels of ASCII letters, digits, `-` and `_` (so IPv4 literals and
  `.local` names are accepted unchanged), or a bracketed IPv6 literal (`[::1]`, with or without a
  port). An unbracketed IPv6 address, an empty host, or a leading, trailing or doubled dot is nil.
- The port must be 1 to 65535, ASCII digits only; `host:0`, `host:70000`, `host:`, `host:notaport`
  are nil.
- A single trailing `/` alone is ignored (`http://host/` gives `http://host:6544`). Any other path
  (`host/path`, `host//`), any query (`host?x=1`), any fragment, user-info (`user@host`), or space
  inside the address is nil.

### 6.3 Composition

```swift
@MainActor @Observable public final class AppModel {
    public init(settings: any SettingsStore, connector: BackendConnector,
                makeEngine: @escaping @MainActor () -> any PlayerEngine,
                discovery: any BackendDiscovery,
                now: @escaping @MainActor () -> ContinuousClock.Instant)
    public private(set) var session: Loadable<BackendSession>      // .idle = not connected and not connecting
    public func connect() async                                    // reads settings, probes, builds the adapter
    public func makeLibraryModel() -> LibraryViewModel             // added by M2-5
    public func makeShowModel(_ show: Show) -> ShowViewModel       // added by M2-5
    public func makePlaybackSession(_ recording: Recording, start: StartPoint) -> PlaybackSession   // added by M3-2
    public func makeSettingsModel() -> SettingsViewModel           // added by M2-6
}
public struct BackendSession: Sendable { let info: BackendInfo; let adapter: any BackendAdapter }   // public init(info:adapter:)

public protocol BackendDiscovery: Sendable { func discover() -> AsyncStream<[DiscoveredBackend]> }
public struct DiscoveredBackend: Identifiable, Hashable, Sendable { id: String; name: String; connection: BackendConnection }
```

The app target builds exactly one `AppModel` with production implementations. Tests build it
with fakes. This is the only place concrete types are chosen.

**Connection flow** (`AppModel.connect()`, built in M2-4). `init` does nothing: `session` starts
`.idle` and settings are not read until `connect()`. Each `connect()` reads the backend address
from the settings store, then:

- **No backend configured:** any attempt in flight is cancelled, `session` becomes `.idle`, and
  nothing is sent. So `.idle` means "not connected and not connecting": no backend configured, or
  `connect()` not called yet. (Root decides whether to show Onboarding from the settings, not
  from `.idle` alone.)
- **Same address as the attempt in flight:** the call joins that attempt and returns when it
  finishes. It does not probe again, so two concurrent calls send one probe.
- **Different address from the attempt in flight:** the old attempt is cancelled and its outcome
  is ignored, success or failure, whenever it arrives; only the newest attempt may change
  `session`.
- **While connecting:** `session` is `.loading`, except when it already holds a session loaded
  from the same address: that session stays visible until the new outcome replaces it (as a
  library refresh keeps old content visible, §6.4). After a failure, or for a different address,
  it is `.loading`: an old backend's session is never shown for a new address.
- **Outcome:** success gives `.loaded(BackendSession)`; failure gives `.failed(UserMessage)`
  (from the `BackendError`, or `UserMessage.unexpected` for anything else), replacing any earlier
  session. A backend that stops answering is reported, not hidden behind a stale session.
- **Cancellation:** an attempt belongs to the model, not to the caller. Cancelling the task that
  called `connect()` does not cancel the attempt (the caller still waits for it, and the result
  is applied). The model cancels an attempt only when it supersedes it, and a superseded attempt
  never touches `session`, so a cancelled request (which `URLSessionTransport` reports as
  `.unreachable`) never becomes a message.

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
| `FakeRecordingsService`, `FakePlaybackStateService`, `FakeMarkupService`, `FakeMediaLocator` | In-memory state (one shared `FakeBackendStore`), call log, per-call injectable error, optional suspension point to test in-flight behaviour (rules below; the synchronous `FakeMediaLocator` has the call log only) |
| `FakeBackendAdapter`, `FakeAdapterFactory` | Bundle of the four fakes over one store, settable `version` and `capabilities`, `liveTV` / `videoLibrary` nil by default; the factory has a configurable `supports` closure and records each `makeAdapter` call in `makeRequests` |
| `FakePlayerEngine` | Records calls; `emit(_ snapshot:)` drives the stream; `seek` updates position immediately |
| `TestClock` | `@MainActor` class: `now` is a `@MainActor () -> ContinuousClock.Instant`; `advance(by:)` moves it. The origin is one `ContinuousClock.now` reading taken at `init` (the type has no public initialiser); nothing else reads real time |
| `InMemorySettingsStore`, `FakeBackendDiscovery` | Settings kept in memory with `saveCount`, `loadCount` and `saved`; discovery driven by `push(_:)` (rules below) |
| `Recording.fixture(...)` | Builder with defaults for every field |
| `FixtureLoader` | `data(named:in:subdirectory:)` and `decode(_:named:in:subdirectory:)` read a file from a `Bundle` the caller passes (its own `Bundle.module`). A `named` without an extension means `.json`; a name with one (`not-found.html`) is used as given. A missing or unreadable file throws `FixtureError` whose description names the file |

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

### Service fake rules

- **Shape.** The async fakes are `final class`es made `Sendable` by a `Mutex`, not actors, so a test
  configures and inspects them synchronously (`fake.calls`, `fake.failNext(...)`, `fake.suspend(...)`).
  Only the service calls and `waitForParked` are awaited. The log, injection and suspension live in
  `FakeCallRecorder` and are exposed on each fake through the `FakeCallControls` protocol.
- **State.** The four fakes of one adapter share a `FakeBackendStore` (`add(_:resumePosition:bookmark:commercialBreaks:)`,
  `recording(id:)`, `allRecordings`, `setCommercialBreaks(_:for:)`). `hasResumePosition` and `hasBookmark`
  are derived from the stored positions, whatever flags a recording was added with. List order is
  insertion order.
- **Write semantics (docs/BACKEND-V35.md).** A write to an unknown id throws `.rejected("no such recording")`;
  reading an unknown id's position gives nil, its breaks `[]`, and `recording(id:)` throws `.notFound`.
  `delete` is asynchronous on a real backend, so the fake sets `deletePending`: `allRecordings()` then skips the
  recording and `recording(id:)` still returns it. `setResumePosition` / `setBookmark` store a position; nil
  and zero clear it; a negative position throws `.http(status: 400, message: nil)`. (The conformance suite
  never writes, so none of this is checked by it.)
- **Call log.** `calls` is every call in arrival order as an `Equatable` enum
  (`FakeRecordingsService.Call.setWatched(true, id)`, `.delete(id, allowRerecord: false)`, ...), including calls
  that failed or are parked. Each `Call` has a `method` (its `Call.Method` case, no arguments).
- **Error injection.** `failNext(_ error, on: method = nil)` makes the next call (of that method, or any) throw
  once; several `failNext` calls queue. `failAlways(_:on:)` makes every such call throw until
  `clearFailures()`, which clears both kinds. A one-shot error is used before a persistent one. A failing call is
  logged, has no effect and never parks.
- **Suspension.** `suspend(method = nil)` parks every later call of that method (any when nil) until
  `stopSuspending()`; `suspendNext(method = nil)` parks only the next one. A parked call has been logged but has
  not yet changed anything. `parked` lists the parked calls, oldest first. `try await waitForParked(n = 1, of: method = nil)`
  returns once at least n are parked (at once if they already are); it is signalled by the fake, not polled.
  `release(_ parked, throwing: error = nil)`, `releaseNext(of:throwing:)` and `releaseAll(throwing:)` resume
  parked calls, in any order, normally or by throwing; each returns false if nothing was parked. Cancelling
  a parked call's task removes it from `parked` and throws `CancellationError` (no continuation leaks, a
  call whose task is already cancelled never parks); cancelling a waiter ends `waitForParked` with `CancellationError`.
- **`FakeMediaLocator`** builds `<baseURL path>/fake/stream/<id>`, `/fake/preview/<id>?width=` and
  `/fake/artwork/<kind>?locator=&width=` under its `baseURL` (default `http://fake-backend:6544`), so URLs are
  absolute and deterministic.
- **`InMemorySettingsStore`** starts with the given value (defaults when omitted; not counted as a save).
- **`FakeBackendDiscovery`**: `push(_ list)` delivers to every open stream. Each `discover()` returns its own
  unbounded stream that starts with the latest pushed list, if any, so a second call does not steal from the first.
  A dropped stream is forgotten (`activeStreamCount`); `finish()` and `deinit` end all streams, and `discover()`
  after `finish()` returns a finished stream. `discoverCount` counts calls.

## 9. Testing rules

- Test first. A task is done when its listed tests exist, were seen to fail, and now pass.
- `cd MythwatchKit && swift test` must finish in under 10 s and touch no network, no disk outside
  the bundle's fixtures, and no real clock (`Task.sleep` is banned in tests).
- **Adapter conformance suite:** `AdapterConformance` in `MythwatchTestSupport` is a set of
  behaviour checks written against `BackendAdapter` plus a small `ConformanceScenario` protocol
  that each adapter's test target implements to supply fixtures. Every adapter must pass it.
  Details in section 9.1.

### 9.1 Adapter conformance suite

The suite is version-neutral: it names no endpoint path or wire key, and knows an adapter only
through `BackendAdapter` and the domain ports. It never calls a write method (`setWatched`,
`delete`, `setResumePosition`, `setBookmark`); **write behaviour is outside the suite for now**,
so an adapter that advertises a write capability whose method is still a stub (v35 until M3-5)
is not in violation.

```swift
public protocol ConformanceScenario: Sendable {
    var connection: BackendConnection { get }              // media URLs must lie under its baseURL
    func makeAdapter() async throws -> any BackendAdapter  // fresh adapter over canned data; once per check
    var absentID: RecordingID { get }                      // not listed; recording(id:) must throw .notFound
    var idWithBreaks: RecordingID { get }                  // has at least one commercial break
    var idWithoutStoredPosition: RecordingID { get }       // no resume position and no bookmark
    var idWithResumePosition: RecordingID? { get }         // has a resume position; nil if the data has none
    var idWithBookmark: RecordingID? { get }               // has a bookmark; nil if the data has none
}

public enum AdapterConformance {
    public enum Check: String, CaseIterable, Sendable, Codable {
        case listIDsAreUnique, listOrderIsStable, recordingByIDEqualsListedValue,
             unknownIDThrowsNotFound, commercialBreaksAreWellFormed, positionIsNilWhenNoneStored,
             mediaURLsAreUnderBaseURL, capabilitiesMatchOptionalServices
        public func violations(in scenario: any ConformanceScenario) async -> [String]  // empty = pass
    }
    public static func isAbsolute(_ url: URL) -> Bool
    public static func isURL(_ url: URL, under base: URL) -> Bool
    public static func breakViolations(_ spans: [(start: Duration, end: Duration)]) -> [String]
}
```

A scenario's data must list at least two recordings, and every listed id must be fetchable with
`recording(id:)`; a list shorter than two is reported as a violation by every check that reads
the list, so a check cannot pass on data too thin to tell anything apart.

**Reporting without `Testing`.** `MythwatchTestSupport` cannot import `Testing` (section 8), so a
check does not assert: it returns its violations as plain-English messages naming the call, the
id and the values involved. Anything that throws inside a check (including `makeAdapter`) becomes a
violation, never an escaping error. Each adapter's test target runs the whole suite with one
parameterised test over `allCases`:

```swift
@Test(arguments: AdapterConformance.Check.allCases)
func passes(_ check: AdapterConformance.Check) async {
    let violations = await check.violations(in: MyScenario())   // `try` if its init throws
    #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
}
```

Each check is a separate test case, reported under its case name. A new case added to `Check`
runs in every adapter's test target without an edit there; targets must iterate `allCases`, never
a hand-picked list. One check can be re-run alone from Xcode's test navigator (the argument is
`Codable`, so its test case has a stable id) or by calling `violations(in:)`; `swift test --filter`
(Swift 6.4.2) cannot select a single argument, only the whole test, which runs in milliseconds.

**The checks.**

| Check | Passes when |
| --- | --- |
| `listIDsAreUnique` | `allRecordings()` lists no id twice |
| `listOrderIsStable` | two `allRecordings()` calls on the same adapter list the same ids in the same order (no particular order is required) |
| `recordingByIDEqualsListedValue` | for every listed recording, `recording(id:)` returns a value `==` to the listed one (every field of `Recording`; a mismatch is reported field by field) |
| `unknownIDThrowsNotFound` | `absentID` is not listed and `recording(id: absentID)` throws exactly `BackendError.notFound` |
| `commercialBreaksAreWellFormed` | for every listed id and `idWithBreaks`, `commercialBreaks(for:)` satisfies `breakViolations` (below), and `idWithBreaks` has at least one break |
| `positionIsNilWhenNoneStored` | `resumePosition(for:)` and `bookmark(for:)` both return nil for `idWithoutStoredPosition`; each returns a duration above zero for `idWithResumePosition` / `idWithBookmark` when the scenario names one |
| `mediaURLsAreUnderBaseURL` | for every listed recording and widths 1, 320 and 4096, `streamURL`, `previewImageURL` and `artworkURL` of every artwork reference are absolute and under the connection's base URL. `artworkURL` may return nil |
| `capabilitiesMatchOptionalServices` | `.liveTV ∈ capabilities` ⇔ `liveTV != nil`, and `.videoLibrary ∈ capabilities` ⇔ `videoLibrary != nil` |

Definitions:

- **Absolute:** the `URL` has no `baseURL` and has a non-empty scheme and host of its own.
- **Under the base URL:** absolute, with the same scheme and host as the base (compared
  case-insensitively) and the same port, where an absent port means 80 for `http` and 443 for
  `https`; and the path (percent-encoded) equals the base's path or continues it after a `/`,
  with trailing slashes on the base path ignored and an empty base path admitting every path. So
  `http://backendx:6544/`, `http://backend.evil:6544/`, `http://backend:6544@evil/`,
  `https://backend:6544/` and `http://backend:65440/` are not under `http://backend:6544`, and
  `/mythtv/x` is not under a base path `/myth`.
- **Well-formed breaks** (`breakViolations`): each range is non-empty (`start < end`); ranges are
  sorted by `start`; each starts at or after the previous one's `end` (touching is allowed,
  overlapping is not). `TimeRange` cannot hold an empty range, so that part is tested on raw spans.
- **Capabilities:** only the two capabilities with an optional service are checked. The others
  (`.recordings`, `.resumePosition`, `.bookmarks`, `.commercialBreaks`, `.deleteRecording`,
  `.login`) belong to non-optional services or to the transport and are not checked by the suite.

**Adopting it.** An adapter's test target (which depends on `MythwatchTestSupport`) adds a type
conforming to `ConformanceScenario` that builds its adapter over its own canned data (v35:
`V35ConformanceScenario`, a `FixtureTransport` answering from the committed fixtures) and the
parameterised test above. `FakeBackendAdapter` has the same in `MythwatchFeaturesTests` (added in M2-3; it passed unchanged).

**The suite can fail.** `MythBackendV35Tests` holds, for each check, deliberately broken adapters
(the v35 adapter with one service or property replaced) and asserts the check reports them:
duplicate ids, unstable order, a fetched value differing from the listed one, an unknown id that
returns a value or throws another error, overlapping, unsorted and missing breaks, a stored
position where none is, a missing stored position, stream, preview and artwork URLs on another
host or relative, and capabilities disagreeing with the optional services in both directions.
When a check is added, add its broken-adapter test there too.
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
