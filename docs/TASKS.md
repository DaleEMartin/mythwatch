# Mythwatch task list

Tasks are sized for one agent session each. Do them in order within a milestone; tasks marked
**∥** can run in parallel with their siblings once their dependencies are done. Every task
follows `CLAUDE.md`: tests first, `swift test` green, `Tools/check-deps.sh` clean, one commit.

"Model" is a suggestion: **Sonnet** for tasks fully pinned down by the spec, **Opus** for tasks
with design judgement, concurrency, or unknowns.

Section references: `SPEC §n` is `docs/SPEC.md`; `V35` is `docs/BACKEND-V35.md`.

---

## Milestone 0: scaffold and de-risk playback

### M0-1 Repository and package skeleton — Sonnet
- `git init`; `.gitignore` (copy `../cable-82-tv/.gitignore`); `LICENSE` (MIT); `README.md` stub.
- `MythwatchKit/Package.swift`: swift-tools-version 6.0, platforms `.macOS(.v15)`, `.tvOS("26.0")`, `.iOS("26.0")`,
  the six targets and five test targets with exactly the dependencies in SPEC §2. Swift 6
  language mode.
- One placeholder source file and one trivial passing test per target.
- **Done when:** `swift build` and `swift test` pass; importing `MythBackendV35` from
  `MythwatchFeatures` is rejected by `Tools/check-deps.sh` (try it, then remove it). The debug
  build itself only warns about such an import; see SPEC §2.

### M0-2 tvOS app shell — Sonnet (after M0-1)
- `Mythwatch/Mythwatch.xcodeproj` by hand, modelled on `../cable-82-tv/CableTV/CableTV.xcodeproj`
  (file-system-synchronised groups, local package reference to `../MythwatchKit`, same signing
  team and bundle-id prefix, tvOS 26.0). No project generator is installed.
- `Info.plist` keys from SPEC §7. App shows a placeholder view. A UI test target with one launch test.
- **Done when:** `xcodebuild build` and `xcodebuild test` succeed for the tvOS simulator.

### M0-3 VLCKit playback spike — Opus (after M0-2)
Throwaway code on a branch; the deliverable is `docs/VLCKIT.md` plus the pinned dependency.
- Candidates: official VideoLAN VLCKit 4.x (check whether upstream now ships a `Package.swift`)
  and the 3.x `TVVLCKit` line. Prefer an official VideoLAN binary; if only a community wrapper
  works, pin an exact version and checksum and record who built it.
- Prove on the tvOS simulator and on a real Apple TV, against `/Content/GetRecording` on the
  owner's backend: an MPEG-2 1080i `.ts` plays with audio; deinterlacing works; seek to an
  arbitrary time lands within 2 s; position and duration are reported in ms; a still-growing
  recording does not crash; audio and subtitle (CEA-608/708) tracks enumerate.
- **Hard requirement:** the chosen build must be a dynamic framework embedded in the app bundle
  (SPEC §7, "VLCKit linking"). Confirm it with `file` / `otool -L` on the built app and record the
  output. Reject any candidate that only ships as a static library.
- **iPhone coverage (SPEC §11):** the chosen distribution must also ship an iOS build of the same
  version with the same API, also as a dynamic framework. Check that the binary has iOS device
  and simulator slices and that a trivial iOS simulator target links and plays the same stream.
  Record any API or option that differs between tvOS and iOS. Reject a tvOS-only candidate.
- Confirm which licence the chosen binary is actually under: libVLC is LGPL, but some builds
  bundle GPL-only modules. Reject a build that includes GPL-only modules, or record exactly
  which ones and stop for the owner's decision.
- Measure: time to first frame, dropped frames at 1080i on the oldest Apple TV available, app size.
- **Write down:** chosen version and why; the exact media/player options used; how position
  updates arrive (callback rate, thread); known problems; LGPL obligations for App Store
  distribution; anything in SPEC §5 `PlayerEngine` that must change.
- **Stop and report** if MPEG-2 playback is not acceptable on real hardware. Do not continue to M3
  on a bad result.

---

## Milestone 1: domain, seam, v35 read path

### M1-1 Domain types and errors — Sonnet
SPEC §3. Tests: `CalendarDay` ordering and parsing of `yyyy-MM-dd` (valid, empty, garbage);
`TimeRange` rejects `start >= end`; `RecordingFlags` set algebra sanity.

### M1-2 Test support, part 1 — Sonnet (after M1-1)
`FixtureTransport`, `TestClock`, `Recording.fixture`, fixture loader (SPEC §8). Also add the
"HTTP transport" types of SPEC §4 (`HTTPRequest`, `HTTPResponse`, `HTTPTransport`,
`RequestAuthorizer`) to `MythwatchBackend`, since `FixtureTransport` conforms to them; nothing
else from §4. Tests go in `MythwatchBackendTests` (SPEC §2): matching by method and path; query
matching; unmatched request reports the URL; request log order.

### M1-3 Version parsing, registry, probe, connector — Sonnet (after M1-1, M1-2)
SPEC §4. Tests:
- `BackendVersion(parsing:)`: `v35.0` → 35.0; `v35.0-12-gabcdef` → 35.0; `v37-Pre-676-g5474cf09b0`
  → 37.0; `v0.28.1` → 0.28; `35` → 35.0; `""`, `"garbage"` → nil; ordering 34.0 < 35.0 < 35.1 < 36.0.
- Registry: resolves the first supporting factory in registration order; none → `.unsupportedVersion(raw)`.
- Probe: parses the `backend-info.json` fixture; sends `Accept: application/json`; ignores unknown
  fields; missing `Build.Version` → `.malformedResponse`; HTML body → `.malformedResponse`;
  status 500 → `.http`; transport error passes through; `GetHostName` failure still succeeds.
- Connector: probe then factory then adapter; unsupported version surfaces unchanged.

### M1-4 `URLSessionTransport` — Sonnet ∥
Tests with a custom `URLProtocol` stub (no network): GET and POST bodies and headers pass through;
non-2xx returned as a value; `URLError.timedOut` → `.timedOut`; cannot-connect/DNS → `.unreachable`;
authorizer is applied when present.

### M1-5 Capture fixtures — Opus (after M1-2; needs the live backend)
Write `Tools/capture-fixtures.sh` (GET only), run it, sanitise and extend per V35 "Fixtures".
While there, settle the **[verify]** read-side items in V35: `{"bool": ...}` shape (use
`/Dvr/version`-style safe GETs only; if no GET returns a bool, leave it and keep lenient
decoding), `GetImageFile` `Width` scaling. Update `BACKEND-V35.md` markers.

### M1-6 v35 DTOs and mappers — Sonnet (after M1-1, M1-5)
V35 "Recordings". Pure functions DTO → domain. Tests, one per row of the mapping tables, plus:
empty strings become nil; season/episode 0 become nil; null `Airdate`; null `Artwork`; unknown
`CatType`; flag-name parsing incl. `NONE` and unknown names; `VideoPropNames` → traits and
`.damaged`; artwork type mapping and locator preserved verbatim; a row without a valid
`RecordedId` is skipped while its neighbours survive; a row with every optional field missing
still decodes; lenient scalar decoding for bool and long (JSON value or string).
Use the committed fixtures (their `README.md` says which file covers which case). Also from the
M1-5 capture: `Channel`, `Recording`, `Artwork` and `Cast` may each be `null`; `Artwork` may be
`{"ArtworkInfos": []}`; a flag name written as hex (`0x00100000`) counts as unknown.

### M1-7 v35 adapter: read path — Sonnet (after M1-3, M1-6)
`V35RecordingsService.allRecordings` / `recording(id:)`, `V35MarkupService`, `V35PlaybackStateService`
getters, `V35MediaLocator`, `V35AdapterFactory`. Tests (all through `FixtureTransport`):
- list: exact query parameters of the first request; pages until `TotalAvailable`; stops on an
  empty page even if the total says more; a failing second page fails the call; the request
  does not contain `Sort`; an id repeated across pages appears once (first occurrence kept).
- one: fixture → domain; the blank-programme fixture → `.notFound`.
- commercial breaks: balanced list; every pairing rule in V35; mark 32 ignored; empty → `[]`;
  request does not contain `IncludeFps`.
- positions: `"0"` → nil; `"-1"` → nil; `"700266"` → 700.266 s; number instead of string accepted.
- media: stream URL; artwork URL keeps existing percent-encoding and appends the width; preview URL;
  requested widths are rounded up to the fixed set in V35 (each distinct width makes the backend
  write a cached copy of the image).
- errors: 404 HTML → `.http(404, ...)`; 400 → `.rejected` with the message when extractable;
  JSON of the wrong shape → `.malformedResponse`.
- factory: supports 35.x only; capabilities as listed in V35.

### M1-8 Conformance suite — Opus (after M1-7)
`AdapterConformance` + `ConformanceScenario` (SPEC §9), run against the v35 adapter. (M2-3 adds
the run against `FakeBackendAdapter`, which keeps the fake honest; the fake does not exist yet.) Checks: list returns sorted-stable unique
ids; `recording(id:)` of a listed id equals the listed value; unknown id → `.notFound`; breaks
are sorted, non-overlapping, non-empty ranges; nil when no position; media URLs are absolute and
under the connection's base URL; capabilities agree with which optional services are non-nil.

### M1-9 Live read-only contract tests — Sonnet ∥
Tagged `.live`, gated on `MYTHWATCH_LIVE_BACKEND`. Probe, list (count > 0, all ids unique),
fetch the first id, breaks for the first `commercialsFlagged` recording, HEAD-equivalent range
request on the stream URL returns 206. **No POSTs.**

---

## Milestone 2: settings, onboarding, library

### M2-1 Settings — Sonnet
SPEC §6.2. Tests: defaults; round trip; corrupt blob → defaults; unknown JSON keys tolerated;
`BackendAddress.parse` table (`host`, `host:6544`, `http://host`, `https://host:1234`, padded
whitespace, IPv4, bracketed IPv6, empty → nil, `host/path` → nil, `host:notaport` → nil).

### M2-2 `LibraryBuilder` — Sonnet ∥
SPEC §6.1. Tests: grouping by `seriesKey`; fallback to normalised title; same title with
different keys stays separate; show title is the most common; `sortTitle` articles and case;
shows order; Continue Watching filter, order and cap; Recently Recorded order and cap;
`deletePending` excluded everywhere; seasons order with "Other Episodes" last; episode order with
ties broken by `recordingStart`; movie has one season; counts (`episodeCount`, `unwatchedCount`);
empty input → empty library.

### M2-3 Test support, part 2 — Sonnet ∥
Service fakes, `FakeBackendAdapter`, `FakeAdapterFactory`, `InMemorySettingsStore`,
`FakeBackendDiscovery` (SPEC §8). Tests for call logs, injected errors and suspension points.
Also run the M1-8 conformance suite against `FakeBackendAdapter` from `MythwatchFeaturesTests`.
`FakeBackendDiscovery` needs `BackendDiscovery` and `DiscoveredBackend` (SPEC §6.3), which no
earlier task builds: add just those two declarations to `MythwatchFeatures` here.

### M2-4 `UserMessage`, `AppModel`, connection flow — Opus (after M2-1, M2-3)
SPEC §6.3. Tests: no backend configured → `.idle`; success → `.loaded` with info and adapter;
each `BackendError` case → a distinct, plain-language `UserMessage` (assert titles and `canRetry`);
unsupported version message names the version; `connect()` called twice concurrently probes once;
changing the address and reconnecting replaces the session.
Note: `BackendConnector.connect` returns only the adapter, but `BackendSession` also needs the
`BackendInfo` (host name). Do not probe twice to get it: change `connect` to return both (and
update SPEC §4 and the M1-3 connector tests) as part of this task.

### M2-5 Library, Show, EpisodeDetail view models — Sonnet (after M2-2, M2-4)
SPEC §6.4. Tests: load → loaded; failure → failed with retry; refresh keeps old content visible
while loading; `toggleWatched` optimistic update and rollback on error; `delete` removes
immediately, rolls back on error, and respects `askBeforeDelete` being the view's concern (model
exposes `delete` only); episode detail offers the right start points for each combination of
resume position and bookmark; a failed position fetch still offers Play from Beginning.

### M2-6 Settings and Onboarding view models — Sonnet ∥ (after M2-4)
Tests: test-connection states; shows adapter name; invalid address disables connect; save persists
and triggers reconnect only when the backend changed; selecting a discovered backend fills the address.

### M2-7 Library and settings UI — Opus (after M2-5, M2-6)
Views per SPEC §7 (Root, Onboarding, Recordings, Show, Episode detail, Settings), wired through
`AppModel`. Image loading with `AsyncImage` or a small cache behind a protocol; poster fallback to
the preview image, then to a titled placeholder. UI tests with a launch argument that swaps in
fakes: onboarding → library; focus moves shelf → grid; open a show → episode → back.
**Done when:** runs on the simulator against the live backend and against fakes; screenshots of
each screen attached to the task report.

---

## Milestone 3: playback

### M3-1 `FakePlayerEngine` and playback value types — Sonnet
SPEC §5, §8.

### M3-2 `PlaybackSession` without commercials — Opus (after M3-1, M2-3)
SPEC §5.2, with the skipper stubbed to `.off`. Tests:
- start: beginning / resume / bookmark each call `load` with the right `startAt`; position and
  breaks are fetched concurrently; failure of either still plays and sets `problem`.
- saving: saves after `saveInterval` of clock time while playing, not while paused; saves on
  pause; never below `minimumResumePosition`; only one save in flight and the newest queued
  position wins; a failed save sets `problem` and playback continues.
- seeking: skip forward/back use settings; clamped at 0 and at duration; unknown duration only
  clamps at 0.
- finish: below threshold saves position and `markedWatched == false`; at or past threshold marks
  watched and clears the position; `.ended` counts as watched; `finish()` twice does the work once;
  finish while a save is in flight ends with the final position stored.
- bookmark: `setBookmarkHere` stores the current position.

### M3-3 `VLCPlayerEngine` — Opus (after M0-3, M3-1)
Implements `PlayerEngine` per `docs/VLCKIT.md`. Not unit-testable; verify with a manual checklist
in the task report (load, play, pause, seek, resume at offset, end of file, bad URL → `.failed`,
track switching, deinterlace on/off, snapshot rate ≥ 4/s).

### M3-4 Player screen — Opus (after M3-2, M3-3)
Transport overlay and remote handling per SPEC §7; Now Playing info and remote commands; Info /
Audio / Subtitles panel; error state with Retry and Close. On close call `finish()` and refresh
the library. Put scrub and auto-hide logic in a small `@Observable` `TransportModel` in
`MythwatchFeatures` with tests (auto-hide after 5 s of fake clock; scrub preview vs commit vs
cancel; time formatting `m:ss` / `h:mm:ss` and remaining time).

### M3-5 Write path in the v35 adapter — Opus (after M1-7; needs the owner present)
`setWatched`, `setResumePosition`, `setBookmark`. Fixture tests: method POST, form-urlencoded
body with exact fields, ms conversion, `{"bool": true}` success, `false` → `.rejected`, 400 →
`.rejected`. Then, **on one recording the owner nominates**, verify the [verify] items in V35 by
hand: POST encoding accepted, bool shape, clearing with `Offset=0`, flags change in
`GetRecorded`, mythfrontend sees the same position. Update `BACKEND-V35.md` markers.

---

## Milestone 4: commercial skip

### M4-1 `CommercialSkipper` — Opus
SPEC §5.1. One test (or more) per rule R1–R11, named after the rule, plus: `normalise` (unsorted,
overlapping, touching, empty, zero-length); two breaks back to back; break at position 0; tick
granularity of 250 ms that steps over a break start; ticks arriving with a position that goes
backwards; undo after a second skip only undoes the second; mode switched mid-break; no breaks.
A property-style test: for random break lists and tick sequences without user seeks, in `.auto`
the engine position never rests inside a non-suppressed, non-guarded break for more than one tick.

### M4-2 Wire the skipper into `PlaybackSession` — Opus (after M4-1, M3-2)
Tests: effects become engine seeks and `banner` changes; a user skip that lands in a break plays
it (R3 end to end); undo; prompt mode accept; breaks exposed for the scrubber; mode read from
settings at start.

### M4-3 Commercial UI — Sonnet (after M4-2, M3-4)
"Skipped commercials · Go back" banner, Skip button in prompt mode, break segments on the
scrubber, Settings picker. UI test with fakes: banner appears and undo returns.

---

## Milestone 5: delete and polish

### M5-1 Delete — Sonnet (owner present for the live check)
Adapter `delete` (fixture tests as in M3-5), confirmation dialog honouring `askBeforeDelete`,
"Delete" offered when playback ends having reached the end. Live check on a nominated recording.

### M5-2 Bonjour discovery — Opus ∥
`BonjourBackendDiscovery` over `NWBrowser` for `_mythbackend._tcp`. First verify what the backend
advertises (port, TXT) and record it in `BACKEND-V35.md`. Resolution logic behind a small
protocol so the mapping from browse results to `DiscoveredBackend` is unit-tested.

### M5-3 States, accessibility, resilience — Sonnet ∥
Empty library, backend unreachable at launch, backend lost mid-session (retry without losing
navigation), VoiceOver labels, Reduce Motion, large text checks on every screen.

### M5-4 Release documents — Sonnet ∥
`README.md` (what it is, requirements, build, test, adding a backend version),
`THIRD_PARTY_NOTICES.md` (VLCKit/libVLC LGPL text and source offer per `docs/VLCKIT.md`), app
icon and Top Shelf image placeholders, in-app About/licences screen.

---

## Manual acceptance (end of M4, repeated at M5)

On a real Apple TV against the owner's backend:

1. Fresh install → onboarding → connect → library appears with posters.
2. Open a show, pick an episode, Play from Beginning; picture is deinterlaced, audio in sync.
3. Skip forward/back, scrub, pause; leave the player; the episode shows progress and appears in
   Continue Watching; mythfrontend shows the same resume point.
4. Resume; let a commercial break arrive: it is skipped, the banner shows, Go back returns to the
   break and it then plays through.
5. Switch to Skip button mode and to Off; behaviour matches.
6. Watch to the end: marked watched in Mythwatch and in mythfrontend.
7. Set a bookmark; Play from Bookmark starts there.
8. Delete a nominated recording; it disappears and is gone from the backend.
9. Stop the backend: a clear message with Retry; start it: Retry recovers.
10. Point Settings at a host that is not a MythTV backend, and at a fake reporting v99: each
    gives its own clear message.
