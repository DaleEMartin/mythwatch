# Orchestration handoff

Written 2026-11-14 by the planning session (Fable), which ran from the MythTV checkout at
`../mythtv`. That session's memory does not carry over to sessions started in this directory, so
this note is the full handoff. Update the "Status" section as work proceeds.

## Status

- Spec complete: `docs/SPEC.md`, `docs/BACKEND-V35.md`, `docs/TASKS.md`, `CLAUDE.md`.
- **M0-1 done and committed** (2026-11-14): git repo on `main`, `MythwatchKit` package skeleton,
  `Tools/check-deps.sh`.
- **M0-2 done and committed** (2026-11-14): `Mythwatch/Mythwatch.xcodeproj`, placeholder app,
  one UI launch test. Next task: **M0-3**, which needs the owner and a real Apple TV; do not
  launch it unattended. Milestone 1 can proceed alongside it.
- **M1-1 done and committed** (2026-11-14): domain types, ports, `BackendError`.
- **M1-2 done and committed** (2026-11-14): HTTP transport types, `FixtureTransport`, `TestClock`,
  `Recording.fixture`, `FixtureLoader`. Run tasks one at a time unless isolated ( agents
  sharing this working tree break each other's builds; use worktree isolation to go parallel).
- **M1-3 done and committed** (2026-11-14): version, registry, probe, connector. Its
  `backend-info.json` fixture is hand-written; M1-5 must replace it with the real capture.
- **M1-4 done and committed** (2026-11-14): `URLSessionTransport`. A cancelled request maps to
  `.unreachable` (SPEC §4); view models that cancel loads must check `Task.isCancelled` rather
  than show that error.
- **M1-5 done and committed** (2026-11-14): `Tools/capture-fixtures.sh`, 19 fixtures, a guard
  test, and many corrections to `BACKEND-V35.md` from the live capture. 15 GETs were sent to
  basement, no other method. One GET had a side effect: `/Content/GetImageFile` with `Width`
  makes the backend write a scaled cache copy beside the original (one 120-wide cover was
  requested). Raw captures are in `/private/tmp/claude-501/mythwatch-m15-raw/`, not in the repo.
  The fixtures' programme and channel data was swapped for invented values on 2026-11-19,
  before the repo went public (history rewritten too; see the fixtures README).
- **M1-6 done and committed** (2026-11-14): v35 DTOs, lenient decoding, `RecordingMapper`. Row
  rules (which rows are skipped) are in `BACKEND-V35.md`.
- **M1-7 done and committed** (2026-11-14): v35 read path and `V35AdapterFactory`. Every write
  method is a stub that sends nothing and throws `.rejected` until M3-5 / M5-1, so no code in
  the repo can POST to a backend yet; the adapter still advertises the write capabilities
  (as `BACKEND-V35.md` lists them). Image widths are rounded up to 160/320/640/1280.
- **M1-8 done and committed** (2026-11-14): `AdapterConformance` (8 checks, SPEC §9.1), passing
  for v35 and proven to fail against broken adapters. M2-3 must add `MythwatchTestSupport` to
  `MythwatchFeaturesTests` and run the suite against `FakeBackendAdapter`.
- **M1-9 done and committed** (2026-11-14): live read-only suite, skipped unless
  `MYTHWATCH_LIVE_BACKEND` is set. Passed against basement (307 recordings, list in 0.24 s,
  list and single-recording endpoints agree, stream URL answers a ranged GET with 206).
  **Milestone 1 is complete.** Still `[verify]`: the `{"bool": ...}` reply and clearing with
  `Offset=0` (both need a write, M3-5), Bonjour TXT (M5-2).
- **M2-1 done and committed** (2026-11-14): `AppSettings`, `UserDefaultsSettingsStore`,
  `BackendAddress.parse`, and `CommercialSkipMode` added early to `MythwatchPlayback`. Tests
  must never use `UserDefaults(suiteName:)`: it leaves a plist in `~/Library/Preferences` per
  suite; use the in-memory subclass in `AppSettingsTests.swift`.
- **M2-2 done and committed** (2026-11-14): `LibraryBuilder`, `Show`, `Library`, `Season`. SPEC
  §6.1 now fixes every ordering and tie-break. On-screen choices put to the owner: watched and
  in-progress recordings appear in Recently Recorded; a repeat recording counts twice; show
  kind and poster come from the newest recording.
- **M2-3 done and committed** (2026-11-14): service fakes over a shared `FakeBackendStore`, with
  call logs, error injection and continuation-based suspension (SPEC §8 "Service fake rules"),
  `FakeBackendAdapter`, `FakeAdapterFactory`, `InMemorySettingsStore`, `FakeBackendDiscovery`.
  The conformance suite passes against the fake unchanged.
- **M2-4 done and committed** (2026-11-14): `Loadable`, `UserMessage` (wording table in SPEC §6,
  put to the owner for review), `AppModel.connect()` with the "Connection flow" rules in SPEC
  §6.3, `ConnectedBackend` returned by the connector, and the `PlayerEngine` declarations.
  `.idle` means "not connected and not connecting", so the Root view decides Onboarding from
  settings, not from `.idle`.
- **M2-5 done and committed** (2026-11-14): `LibraryViewModel`, `ShowViewModel`,
  `EpisodeDetailModel`, the `AppModel` factories, `StartPoint`. Rules are in SPEC §6.4. Open
  for later tasks: `EpisodeDetailModel` has no delete although SPEC §7 puts a Delete button on
  that page (settle in M2-7 or M5-1); `ShowViewModel.delete` always sends
  `allowRerecord: false` (ask the owner in M5-1).
- **M2-6 done and committed** (2026-11-14): `SettingsViewModel`, `OnboardingViewModel`, their
  `AppModel` factories, `adapterName` on `ConnectedBackend` / `BackendSession`. Rules in SPEC
  §6.4. For M2-7: a failed onboarding connect keeps the saved address, so Root must keep the
  Onboarding screen up until `connectState` is `.loaded`; Settings should auto-save on exit
  when `canSave`. The tvOS app build and UI test were re-run after this task and pass.
  **Milestone 2 is complete except M2-7 (UI), which needs the owner.**
  M3-1, M3-2 and M4-2 can run without the owner. They do not need VLCKit, but M0-3 may change
  `PlayerEngine` (SPEC §5); if it does, M3-1/M3-2 need a follow-up.
- **M4-1 done and committed** (2026-11-14): `CommercialSkipper` with rules R1-R11, refinements
  written under each rule in SPEC §5.1, a seeded property test and a 23-mutation check.
  Open question put to the owner (SPEC R4): two breaks less than 2 s apart show about 1 s of
  the second before it is skipped; a chained-landing rule is proposed, not applied.
  `[verify]` for M0-3 / M4-2: whether VLC reports stale positions just after a seek (prompt mode
  would re-offer a break for a tick).
- **M3-1 done and committed** (2026-11-14): `PlaybackSettings`, `PlaybackOutcome`, `SkipBanner`,
  `AppSettings.playbackSettings`, and `FakePlayerEngine` with a deterministic
  `waitUntilDelivered()` (SPEC §8 "`FakePlayerEngine` rules").
  Questions for M0-3 about `PlayerEngine` (SPEC §5): a failed load is only visible as a
  `.failed` snapshot; there is no way to set deinterlacing through the protocol; the stream has
  no teardown signal; `snapshots` should be read once.
- **M3-2 done and committed** (2026-11-15): `PlaybackSession` without commercials and
  `AppModel.makePlaybackSession`. Save and finish sequencing is in SPEC §5.2 "Refinements";
  34 mutations all caught. For M3-4: the player screen must call `finish()` when it closes
  (nothing can be written from `deinit`), and there is no retry API (retry = a new session
  with `.resume`). For M0-3: tune the seek-settle values (2 s tolerance, 3 s timeout) against
  VLC. Lesson: a subagent's mutation run hung for 38 minutes on an unreleased parked call.
  Tell every agent that runs tests with suspension points to run `swift test` under
  `timeout 120` and never wait on an unbounded run.
- **Show kind follow-up done and committed** (2026-11-15): most common kind, `.unknown` ignored
  unless all are unknown (SPEC §6.1).
- **Chained landing done and committed** (2026-11-15): SPEC §5.1 R2 "Chaining". One skip lands
  after every break that would start during its quiet period; undo suppresses the whole chain.
  Told to the owner: programme in gaps under 2 s between chained breaks is skipped too.
- **M4-2 done and committed** (2026-11-15): the skipper is wired into `PlaybackSession` (SPEC
  §5.2 "Commercials"); 27 mutations checked. Package tests, the tvOS app UI test and the iOS
  package build were re-run after it and pass. The live read-only suite was re-run and one
  check failed for a reason unrelated to M4-2: while a recording is in progress, the list
  reports `INUSERECORDING` and status "Recording" for it but `GetRecorded` does not (seen on
  id 3753, 2026-11-15). Fixed in the next commit: `BACKEND-V35.md`, SPEC §3 and §9.1 now say
  `recordingInProgress` is reliable only from `allRecordings()`; the adapter is unchanged; the
  live suite passes again (no recording was in progress at that run, so the new in-progress
  live test has not yet met a real one and may be strict about a growing file's size).
  For M4-3: the view must hide the skipped banner when its own clock passes `undoUntil`
  (no ticks arrive while paused); all banner wording is M4-3's.
  For M0-3, in addition to the earlier questions: does VLC report `.playing` / `.buffering` at
  a position other than `startAt` just after `load` (a break at 0 could then fire on resume)?
  How long are positions stale after a seek (over 3 s defeats the settle rule)? Does it emit
  snapshots while paused?
- **M0-3 done and committed** (2026-11-15, direct Opus session with the owner): **go.**
  `docs/VLCKIT.md` holds every measurement. Pinned VideoLAN TVVLCKit / MobileVLCKit **3.7.4**
  (libVLC 3.0.24, dynamic, no GPL-only modules); VLCKit 4.0 is alpha-only and rejected.
  `Tools/fetch-vlckit.sh` puts it in the git-ignored `Vendor/` (run it after cloning); the
  project embeds it, unused until M3-3. The throwaway spike harness stays on the
  unmerged branch `m0-3-vlckit-spike`. `PlayerEngine` is unchanged; SPEC §5 gained "engine
  rules" and SPEC §7 the VLC options. For M3-3: **every media needs `:demux=avformat`** (VLC's
  own TS demuxer cannot seek MythTV recordings over HTTP); deinterlace is `bob`; ignore VLC's
  `player.state` and its flood of Buffering/ESAdded events, use `isPlaying`; `Ended` before
  any position is a failure (a backend 404 "plays" to its end); on an in-progress recording VLC
  stops at the size it saw on opening, so the engine must reopen at the last position when the
  file has grown (tested: 0.9 to 1.8 s gap, no lost frames; `VLCKIT.md` §10). Seek-settle values stay at
  2 s / 3 s (VLC echoes the target at once, lands within 0.7 s). For M2-7: **the Apple TV
  could not resolve the bare host name `basement`** in VLC (`basement.local` and the IP
  work); check `URLSession` and guide the address field accordingly. For M5-4: audit the
  licences of the libraries bundled in VLCKit (libzvbi first). For the iPhone app: strip
  MobileVLCKit's armv7 slices before an App Store upload.
- **M2-7 done and committed** (2026-11-15, direct Opus session with the owner): the six screens
  (Root, Onboarding, Recordings, Show, Episode detail, Settings) in `Mythwatch/Mythwatch/`, five UI
  tests on the fakes, screenshots against the fakes and against basement (GET only; no write was
  sent). Model additions, all tested first: `EpisodeDetailModel.delete()` (not optimistic; closes
  the page on success), `ShowViewModel.apply(_:)`, `ArtworkURLs` / `AppModel.makeArtwork()`,
  `AppModel.savedSettings`, `BackendSession.id`, and a bare-host-name `addressHint`.
  `MythwatchTestSupport` is linked into Debug only (`EXCLUDED_SOURCE_FILE_NAMES` on Release;
  `nm` shows 0 of its symbols in Release); `DemoBackend` drives `-MythwatchFakes`;
  `check-deps.sh` now checks the app target too. **Settled:** tvOS does not resolve the bare
  name `basement` through `URLSession` either; `basement.local` works. For M3-4: the start
  buttons on the episode page do nothing yet; wire them to the player and call
  `reloadAfterPlayback()` on close. For later: Continue Watching shows a part-watched mark, not
  a progress bar (the list has no positions); the context menu on episode rows was not driven by
  a UI test.
- **M3-3 done and committed** (2026-11-15, same direct Opus session): `PlayerEventMachine` in
  `MythwatchPlayback` (the SPEC §5 engine rules as a pure struct, 33 tests, 8 mutations caught) and
  `Player/VLCPlayerEngine.swift`, a thin adapter that feeds it VLC's events and performs its
  commands (1-byte range GET, reopen). The composition root makes one engine per playback with
  the saved deinterlace setting. Checklist run on the Apple TV, results in `docs/VLCKIT.md` §13:
  everything passed, including reopening a recording in progress. For M3-4: the screen hosts
  `VLCPlayerEngine.videoView`, but `PlaybackSession` takes `any PlayerEngine` and does not expose
  it, so the player screen needs a way to reach the view (for example make the engine in the
  screen and pass it through, or a small app-side protocol); captions draw large (VLC's default).
  Open: the owner did not hear Spanish on 3753's second audio track.
- **M3-4 done and committed** (2026-11-15, direct Opus session with the owner): the player screen.
  `TransportModel` in `MythwatchFeatures` (auto-hide only while playing, scrub preview / commit /
  cancel, Back layering, time text, panel and tracks, failure as `UserMessage.playbackFailed`);
  `PlaybackSession` gained public `engine` (for the picture only), track pass-throughs and
  `skip(by:)`; `AppModel.finishPlayback` (finish, then `reloadAfterPlayback`) and `retryPlayback`
  (finish, then a new `.resume` session). App: `Player/PlayerScreen.swift`, `RemoteInputView.swift`
  (UIKit presses and touch-surface pans), `NowPlaying.swift`; the episode page's start buttons open
  it. Owner decisions: hide controls only while playing; close the player at the end; Set Bookmark in
  the Info tab; captions smaller. Checked on the Apple TV against basement (GET only; every write
  is still a stub, so the player shows "Couldn't save your place."): play, pause, skips, scrub, panel,
  tracks, captions, Menu, Remote app ±10, no double toggle. **Captions:** `sub-text-scale` does
  nothing for CEA-608 (grid mode); `freetype-rel-fontsize` works, set to 2.5 % of the height times
  the tvOS caption size (`docs/VLCKIT.md` §14). For M4-3: the transport bar has no break segments
  and no banner yet; `TransportModel` is where banner-expiry logic belongs (it has the clock and
  `tick()`). For later: the show page underneath is not refreshed after playback (the library and
  episode page are); the swipe-down panel and scrubbing cannot be driven by XCUIRemote, so they were
  checked by hand only.
- **M3-5 done and committed** (2026-11-16, direct Opus session with the owner): the v35 write path.
  `V35Client.postExpectingTrue` (form-urlencoded body, no query, `{"bool": false}` → `.rejected`);
  `setWatched`, `setResumePosition`, `setBookmark` implemented; `delete` is still a stub for M5-1.
  **Clearing sends `OffsetType=Frame&Offset=0`**, not `Duration` 0: the source shows Duration 0 is
  snapped to the first keyframe at or after 0 ms when the seek table has no entry at 0, so it may
  store a position instead of clearing (`BACKEND-V35.md`, "Playback state"). Live on 3749 only (14
  POSTs): bool shape is a bare `true`; flags change at once in `GetRecorded` and the list; 600000 ms
  reads back 598698; mythfrontend offered 9:58 (the owner played it; the position was unchanged);
  both clear forms worked on 3749. Left as found (unwatched, no position, no bookmark).
  `FakeBackendStore` already matched (zero clears). Capabilities unchanged. For M5-1: reuse
  `postExpectingTrue`; the player's "Couldn't save your place." should no longer appear.
- **M4-3 done and committed** (2026-11-16, direct Opus session with the owner): commercial UI.
  `TransportModel` gained `commercialBanner` (`.skipped(distance)` / `.offer`), `bannerHidesAt`,
  `breakSegments`, `goBack()` and `skipCommercials()`; `select()` acts on a showing banner instead of
  toggling (Play/Pause still pauses); the model hides the skipped banner by its own clock at
  `undoUntil` even while paused (SPEC 6.4 "Commercials"). Screen: banner bottom right drawn as a
  focused button ("Skipped commercials · 0:56" + Go Back; Skip Commercials in prompt mode), yellow
  break segments on the scrubber. The Settings mode picker already existed (M2-7). `DemoBackend`'s
  engine now reports each recording's length and the film has three breaks, one around its resume
  point; new UI test `testResumingIntoABreakSkipsItAndGoBackReturns`. **Fixed an M3-4 bug** found on
  the way: the player called `tick()` from `onChange(of: snapshot)`, which SwiftUI drops when several
  snapshots land in one frame, so a missed `.playing` left the controls up for good; it now uses an
  `Observations` loop. Not checked on the Apple TV: the banner with real breaks on basement, and
  prompt mode on screen (prompt mode is covered by model tests only).
- **M4-3 follow-up done and committed** (2026-11-16, owner on the Apple TV): player input.
  A touch on the pad shows the transport bar; the panel opens only on a deliberate swipe down
  (a third of the surface, mostly vertical) and closes on a swipe up that starts on its tabs (a pan
  recognizer on the window while the panel is open; a focus-strip attempt closed it on every
  swipe and was dropped); the tabs row and the content under it are full-width focus sections so
  Set Bookmark Here (far right) is reachable both ways. `TransportModel.status` is now copied by
  `tick()`, so position updates no longer redraw the whole player (that made panel focus hard to
  move while playing). Checked by the owner on the Apple TV: works.
- **Scrub frame preview done and committed** (2026-11-16, owner on the Apple TV): a paused scrub
  that rests 0.4 s seeks the video there so its frame shows (VLC does redraw a paused seek); Back,
  cancel and opening the panel put it back; commit and skips stay (SPEC 6.4 "Frame preview").
- **M5-1 done and committed** (2026-11-16, direct Opus session with the owner): delete.
  `V35RecordingsService.delete` posts `DeleteRecording` (`RecordedId`, `ForceDelete=false`,
  `AllowRerecord`) through `postExpectingTrue`; the stub and `V35NotImplemented` are gone.
  `ShowViewModel.delete(_:allowRerecord:)` and `EpisodeDetailModel.delete(allowRerecord:)` take the
  choice (no default). Every Delete opens a dialog, even with Ask Before Deleting off (owner,
  2026-11-16: the re-record question is asked each time; the setting only drops the "can't be
  undone" warning): Delete / Delete and Let MythTV Record It Again / Cancel, built once in
  `DeleteChoices`. Playback that reached the end offers the same dialog on the episode page
  (`EpisodeDetailModel.offersDelete`, `playbackFinished(_:)`, `dismissDeleteOffer()`; Keep cancels).
  `DemoPlayerEngine` ends on a seek to the end, for the new UI test. **Live:** the owner deleted 3749
  from the Apple TV (no re-record) and, unprompted, 622, 745 and 1913 (Amber Street Sessions); the owner
  chose to leave all four in the backend's `Deleted` group (recoverable from mythfrontend until
  auto-expiry). Basement moves deletes to `Deleted` with `AUTOEXP` rather than flagging
  `DELETEPENDING` (BACKEND-V35.md). Earlier the same evening basement's HTTP API was slow (8-13 s
  per GET, one 40 s timeout) for a while and then recovered on its own; cause not found.
- **M5-2 done and committed** (2026-11-16, direct Opus session): Bonjour discovery. Basement
  advertises `_mythbackend._tcp` as "Mythbackend on basement" at `basement.local.:6550`, TXT
  `master` (mDNS only; settles the last Bonjour `[verify]`). 6550 is the UPnP server at status port
  + 6 (since v34), so the API port is advertised − 6. `MythBackendAdvertisement` (pure mapping),
  `BonjourBackendDiscovery` over two small ports (`BonjourBrowsing`, `BonjourResolving`), and the
  production `NetworkBonjourBrowser` (`NWBrowser`) and `DNSServiceBonjourResolver`
  (`DNSServiceResolve`, so the offered address is the `.local` name, not an IP) in
  `MythwatchFeatures`; the composition root uses `BonjourBackendDiscovery.onLocalNetwork()`.
  Slaves are skipped. Rules in SPEC 6.3 "Bonjour discovery". 29 tests with fakes local to the test
  file, 11 mutations caught (3 of them as hangs, which the suite's `.timeLimit` turns into
  failures); a live test in `BonjourLiveDiscoveryTests` runs with `MYTHWATCH_LIVE_BACKEND` and
  found basement in 0.14 s. The package still builds for iOS. **Checked by the owner on the Apple
  TV** after a fresh install: Onboarding listed "basement", selecting it filled
  `basement.local:6544`, Connect loaded the library. No local-network permission prompt appeared
  (tvOS appears not to have that permission; the usage string stays for the iPhone app).
- **M5-3 done and committed** (2026-11-17, direct Opus session, resumed after a reboot): states,
  accessibility, resilience. `AppModel.returnedToForeground()` reconnects after a retryable failed
  connect (Root calls it on background to active); `EpisodeDetailModel.canRetryLoad` puts Try Again
  on the episode page's banner for a failed load only; the library's refresh banner has Try Again;
  VoiceOver labels in `Labels` for cards, posters, rows and the player's position; Reduce Motion
  fades the player panels. `DemoBackend.Scenario` (empty, unreachable at launch, outage) chosen by
  launch arguments. Rules in SPEC 6.3 "Return to the foreground", 6.4 episode detail "Try Again",
  7 "Accessibility" and "UI tests", 8 `DemoBackend`. Package: all 1066 tests pass (new suite
  "EpisodeDetailModel retry", 8 tests; 6 in `AppModelTests`, 4 in `DemoBackendTests`). UI: 5 new
  tests (empty library, unreachable at launch, lost backend, VoiceOver labels, largest text size).
  **Known simulator problem:** in the full 14-test UI run, the last test's app launch fails with
  Mach error -308 "(ipc/mig) server died" (2 of 2 runs); XCTest restarts and the test passes, but
  xcodebuild reports TEST FAILED. Every test passes in shorter runs, and the pre-M5-3 suite (9
  tests) succeeds, so it looks tied to the number of launches, not to a test. Not checked by the
  owner with VoiceOver on a real Apple TV.
- **M5-4 done and committed** (2026-11-17, direct Opus session): release documents. `README.md`
  rewritten (what it is, requirements, build, test, how it is built, adding a backend version,
  licence). The About section and Licences screen already existed (M2-7); a UI test now opens
  Settings › About › Licences and checks the VLCKit version and source, the LGPL, libzvbi and the
  GPL 2 (`testLicencesNameVLCKitAndItsLicences`). Placeholder app icon (three layers, 400×240 @1x/@2x
  and 1280×768) and Top Shelf images (1920×720 and 2320×720, @1x/@2x) in
  `Mythwatch/Mythwatch/Assets.xcassets`, drawn by a throwaway script (eye and "Mythwatch" on flat
  violet; 780 KB), set as the app icon in both configurations. Settled the VLCKit `[verify]`:
  **TVVLCKit 3.7.4 contains GPL-2-only code** from zvbi 0.2.45 (`src/packet-830.c`, all four of its
  functions linked; `docs/VLCKIT.md` §2). `THIRD_PARTY_NOTICES.md` now has a libzvbi entry, a table
  of the other bundled libraries (licences as their projects publish them, not audited), and the
  GPL 2 text. The full 15-test UI run succeeded this time (no Mach -308 relaunch failure).
- **zvbi removed from VLCKit** (owner, 2026-11-17: "get rid of zvbi"; done the same day, direct
  Opus session). `Tools/build-vlckit.sh` builds TVVLCKit 3.7.4 from source with VideoLAN's own
  script, zvbi off and deployment target 15.0 (Xcode 27's minimum), using a GNU make 4.4.1 it
  builds itself (macOS's 3.81 breaks parallel contrib builds). The work tree is
  `~/Library/Caches/mythwatch-vlckit` (VLCKit's scripts fail on paths with spaces). Result: no
  `vbi_` symbols in either slice, one module fewer than VideoLAN's binary (`codec_libzvbi`), the
  same 367 public symbols, `cc` and `telx` present. App builds and the full UI suite passes on it
  (15 tests, 1 skipped). `THIRD_PARTY_NOTICES.md` dropped libzvbi and the GPL 2 text; the licences
  test checks "libzvbi is left out". `Tools/fetch-vlckit.sh` now fetches only the prebuilt
  MobileVLCKit (still with zvbi) for the later iPhone app. VideoLAN's binary is kept for comparison
  at `build/TVVLCKit-prebuilt-3.7.4.xcframework` (git-ignored). **Checked by the owner on the
  Apple TV** (2026-11-17, Debug build installed with `devicectl`): start, picture and sound,
  deinterlace, captions, seeking, commercial skip and resume all as expected. Switching to an audio
  track labelled Spanish changed the sound but was not Spanish on several shows; the same was seen
  in M0-3 with VideoLAN's binary (recording 3753), so not caused by this build. Likely the
  broadcast (a second track that is audio description or another mix, labelled Spanish); not
  confirmed. Still open for any public release: the permissive libraries' notice
  texts (BSD, MIT, ISC, libpng, zlib) are named but not reproduced.
- **App icon and Top Shelf replaced** (owner, 2026-11-18): the M5-4 placeholder (eye on violet)
  is now a cartoon Medusa on a blue gradient, wearing chunky "blue blocker" glasses with
  see-through amber lenses; seven snakes, two winking with tongues out; no earrings. Layers:
  back = gradient and glow, middle = face, hair and four upper snakes, front = three snakes.
  Exported from the owner-approved vector sketch (claude.ai artifact, not in the repo) with
  headless Chrome at every catalogue size. Sketch-quality art, not final illustration. The images
  total 6.5 MB (was 780 KB), mostly the faint scanline texture; shrink before any public release.
  Installed on the owner's Apple TV (Debug, `devicectl`) the same day.
- **Remote arrows in the player** (owner, 2026-11-19, from using a TV remote over HDMI-CEC):
  down opens the panel, up from the tabs closes it, up with the panel closed shows the transport
  bar (as a swipe up does). SPEC §7 table updated; `testUpAndDownPressesOpenAndCloseThePanel`.
  Checked by the owner on the Apple TV. The owner calls this state **version 0** (2026-11-19).
  Signing: the owner joined the paid Developer Program on 2026-11-19. The team ID is unchanged
  (D637HR5735), so the project needed no change; Xcode had cached the free 7-day profiles, which
  were moved aside to force new ones. The new profile runs to 2027-11-20, and that build is
  installed on the owner's Apple TV.
- **Milestone 6 (iPhone app) planned and M6-1 done** (2026-11-21, direct Opus session; the owner
  asked for a plan and work to proceed while away). Plan in `TASKS.md` Milestone 6; SPEC §11 now
  has "Layout". `MythwatchPhone` (iOS 26, iPhone and iPad) and `MythwatchPhoneUITests` targets and
  scheme; shared files moved to `Mythwatch/Common/` (in both targets) instead of a package target
  for the engine (reason in SPEC §11). `check-deps.sh` covers `Common/` and `MythwatchPhone/`.
  Placeholder phone root, one launch UI test (passes on the iPhone 18 Pro simulator); iPhone icon
  is the tvOS App Store layers flattened and centre-cropped to 1024 (sketch quality). The tvOS
  UI suite passes after the move (16 tests, 1 skipped). **Planner's defaults to confirm:** iPad
  included; same bundle id as tvOS (`com.daleemartin.Mythwatch`, universal purchase); home
  network or VPN only.
- **M6-2 done and committed** (2026-11-21, same session): `TransportModel.leftForeground()` (cancel
  a scrub, then `pause()`, which saves), 4 tests in "TransportLeavingTheForegroundTests"; the tvOS
  player calls it on `.background`; the phone app sets the `.playback` audio session at launch.
  The phone player (M6-4) must call it too. Not checked on hardware.
- **M6-3 done and committed** (2026-11-21, same session): iPhone/iPad screens in
  `Mythwatch/MythwatchPhone/` (Root, Onboarding, Recordings, Show, Episode detail, Settings,
  Licences, phone-sized messages); `WatchMark` and `AboutInfo` moved to `Common/`. 7 UI tests in
  `MythwatchPhoneUITests` pass on the iPhone 18 Pro simulator (onboarding, library, show to
  episode and back, delete dialog, settings and licences, empty, unreachable). The episode page's
  start buttons do nothing until M6-4. Not looked at on iPad or in landscape. **The Licences
  screen bundles the tvOS notices** (TVVLCKit without zvbi), which is wrong for the iPhone build
  while it embeds VideoLAN's MobileVLCKit with zvbi: M6-6 fixes it before any release.
- **M6-4 done and committed** (2026-11-21, same session): the iPhone player
  (`MythwatchPhone/Player/PlayerScreen.swift`), rules in SPEC §11 "iPhone player". Model
  additions, tests first: `TransportModel.scrub(to:)` and `toggleControls()` (6 tests in
  "TransportTouchTests", SPEC 6.4 "Touch"). The phone's delete dialogs became alerts (iOS 26 hides
  a confirmation dialog's cancel button on iPhone). 11 phone UI tests pass (new: play and close,
  resume into a break and Go Back, the info sheet, watch to the end and Keep). iOS 26 lists alert
  and dialog buttons twice to XCUITest; the tests take `firstMatch`. Not checked: real VLC
  playback on an iPhone (simulator played only the fakes in this task; M0-3 did play a real
  stream in an iOS simulator), rotation, iPad layout.
- **M6-6 done and committed** (2026-11-21, same session): `Tools/build-vlckit.sh ios` builds
  MobileVLCKit 3.7.4 without zvbi (7.5 min; arm64 device, arm64 + x86_64 simulator, iOS 15.0
  minimum, 241 of VideoLAN's 242 modules, same 373 API symbols, no `vbi_`). `fetch-vlckit.sh`
  removed; VideoLAN's binary kept for comparison at `build/MobileVLCKit-prebuilt-3.7.4.xcframework`.
  Notices name both frameworks; the phone licences test checks MobileVLCKit and "libzvbi is left
  out"; the tvOS licences test still passes. All 11 phone UI tests pass on the new build. README
  and CLAUDE.md list the phone scheme. **After cloning, run both `Tools/build-vlckit.sh` and
  `Tools/build-vlckit.sh ios`.** Not checked: real playback with this build (the UI tests use the
  fakes; playing a live recording would POST its position, rule 4).
- **iPad and landscape** (2026-11-21, same session): the phone UI suite passes on the iPad mini
  (A20 Pro) simulator after one test fix (iPad's tabs are not reported as a tab bar); library and
  player screenshots look right there. New `testThePlayerWorksInLandscape` passes on the iPhone
  (rotates, skips, Close is hittable), but its screenshot came out clipped (captured in portrait
  while the app was in landscape), so the landscape *look* is unchecked. 12 phone UI tests.
- **M6-5 closed by the owner** (2026-11-21): "it doesn't need to play while the screen is
  locked." Pausing on `.background` stays; no background-audio mode. `NowPlaying` stays attached
  (Control Centre while the app is in front). **Planner's defaults confirmed** the same day: iPad
  included, same bundle id as tvOS, home network or VPN only. M6-7 next, with the owner.
- **Backend commercial detection** (owner, 2026-11-16, authorised changing backend settings):
  global `CommercialSkipMethod` is 7 (All, v1 detector) with `AggressiveCommDetect` 1. Channel
  WBTS-CD 15_1 (chanid 16859) set from CommMethod -1 to **261** (Experimental: logo + blank) through
  `Channel/UpdateDBChannel`, and job 8805 queued (`Dvr/ManageJobQueue`, Commflag) to re-flag
  recording 2465 (Seth Meyers / Jon Hamm; old breaks 0:00-0:12, 44:06-45:36, 55:37-59:57; ads
  around 25:27 were missed). **Outcome:** the experimental detector was killed within 30 s both
  times (jobs 8805, 8807: "Failed with Exit Status 140"), so the channel was set back to -1 (global)
  the same evening. A normal re-flag (job 8808, method 7) completed in about 20 min with the same 3
  breaks. Backend settings are as they were before; only 2465's markup was regenerated (unchanged).
- **M6-7 on the owner's iPhone** (2026-11-21, iPhone18,2; Debug build installed with `devicectl`,
  over Wi-Fi after the first time; profile to 2027-11-21; the device was registered with
  `-allowProvisioningDeviceRegistration`). Checked by the owner on 3774: connect, browse, play,
  skips, scrubbing, commercial skip and Go Back, rotation, Control Centre, the sheet, captions,
  bookmark, close. Read back by GET: lock at 16:17 saved 16:16.7; after closing, position 19:23,
  bookmark 19:04.6, flags BOOKMARK and LASTPLAYPOS. **Two bugs found and fixed** (committed with
  this note): (1) no sound after locking and unlocking: VLC's iOS audio output (`audiounit_ios`)
  marks itself silent on an audio-session interruption and only recovers on "should resume",
  which iOS does not send after a suspension; `VLCPlayerEngine` (iOS only) now notes an
  interruption or a move to the background, and the next `play()` re-selects the audio track,
  which makes VLC restart its output. Owner: sound came back. (2) Play on the lock screen started
  VLC unseen and unheard and the position ran on; the phone player now detaches Now Playing on
  `.background` and attaches it again on `.active`. Owner: works. **Captions:** CC1-CC4 listed;
  the text is small on a phone and was hidden under the controls' dimming; the owner is fine with
  the size (no change). Delete of 3774 still to do. Not done: a call or Siri interruption.
- **Nominated recording for M6-7** (owner, 2026-11-21: "pick any Pawn Stars episode", may be
  deleted at the end): recording id **3774**, *Pawn Stars*, "Man. Make. Fire." (DEFY, recorded
  2026-11-16 06:00 UTC, group Default). Found by GET: two breaks (13:54-15:54, 30:06-30:30), not
  watched, no position, no bookmark. Only 3774 may receive a POST in M6-7. The real backend host
  name is not "basement" (that is the placeholder from the 2026-11-19 history rewrite); the owner
  gave it in the session; keep it out of the repo.
- **Nominated recording for M3-5 and M5-1** (owner, 2026-11-15): recording id **3749**, *Austin
  City Limits*, "Sebastián Yatra" (KMWA-HD, recorded 2026-11-15 04:00 UTC, file
  `16817_20261115040000.ts`, status Recorded, group Default; confirmed by GET). M3-5 may write its
  watched flag, resume position and bookmark; M5-1 may delete it, and the owner is fine with it
  being deleted at the end. No other recording may receive a POST.
- **Delete and re-recording** (owner, 2026-11-15, for M5-1): **ask each time.** The delete
  confirmation offers both choices (let MythTV record the episode again, or not), on the show
  page and the episode page; `allowRerecord` follows the choice. Today `ShowViewModel.delete`
  always sends `false`, and `EpisodeDetailModel.delete()` must be checked too; both need a
  parameter, test first, with SPEC §6.4 lines.
- **Every task that can run without the owner is done.** Remaining, all needing the owner:
  M3-4, M3-5 (nominated recording), M4-3, and Milestone 5. Offer each as a direct Opus
  session; do not launch them unattended.
- The owner will run **M0-3** in a direct Opus session (agreed 2026-11-14).
- **iPhone app wanted later** (owner, 2026-11-14). Not scheduled. SPEC §11 holds the rules that
  apply now: the package declares iOS 26 and must stay platform-neutral, view models must not
  assume the remote, and M0-3 must pick a VLCKit build that also covers iOS. When reviewing a
  task that adds a framework import to the package, run the iOS build check in SPEC §11.
- Confirmed by the owner 2026-11-14: bundle-id prefix `com.daleemartin` (the "e" is a middle
  initial); the `NSLocalNetworkUsageDescription` wording in `Mythwatch/Info.plist`.
- **GitHub** (owner, 2026-11-15): repo `DaleEMartin/mythwatch`, remote `origin` over HTTPS
  (gh's login; this Mac has no SSH key for GitHub). Push `main` after each committed task. Do not
  push the `m0-3-vlckit-spike` branch. On 2026-11-19, to prepare going public, the history was
  rewritten: commit email to the GitHub noreply address, the backend's host name and LAN address,
  and the fixtures' programme and channel data replaced. Commit with the noreply email.
## Owner decisions of 2026-11-15 (approved; apply after M3-2, one at a time)

1. **Fixtures: leave as captured.** Superseded on 2026-11-19: before going public the owner
   had the programme and channel data replaced with invented values, history included.
2. **Skip rules (SPEC §5.1 R4):** chain the landing. When R2 skips a break and the next armed,
   eligible break starts before `landing + quietPeriod`, land at that break's landing point
   instead, and repeat. A follow-up to M4-1, before or with M4-2.
3. **Library (SPEC §6.1):** a show's `kind` is the most common kind in the group, not the newest
   recording's. Poster rule unchanged. All other M2-2 choices stand.
4. **Settings UI (M2-7):** auto-save on leaving the screen when `canSave`.
5. Every other on-screen default from M2-4, M2-5, M2-6 and M4-1 stands as built, including the
   `UserMessage` wording.

## Roles the owner chose

A direct Opus session run by the owner is an implementer, not the orchestrator: it writes code
itself, following `CLAUDE.md` and the Status section above. (Its earlier brief,
`opus-handoff.md`, was removed on 2026-11-19 before the repo went public; it is in git history.)

- **Fable orchestrates and reviews; it does not write application code.** Implementation is done
  by Sonnet and Opus subagents (the Agent tool's `model` parameter), per the model suggestion on
  each task in `TASKS.md`. Writing or editing the spec documents is the orchestrator's job.
- The owner explicitly asked for subagents here, so spawning them is authorised for this project.
- Tasks that need the owner in the loop are better run by the owner in a direct Opus session
  than as background subagents: **M0-3** (VLCKit spike, needs a real Apple TV), **M3-3**, **M3-4**
  (engine and player screen), **M3-5**, **M5-1** (live writes and delete), and the UI tasks
  **M2-7**, **M4-3**. Offer that choice when each comes up; do not launch them unattended.

## How to run a task

1. Give the subagent one task id. Tell it to read `CLAUDE.md`, `docs/SPEC.md`, its task in
   `docs/TASKS.md`, and `docs/BACKEND-V35.md` for backend work. Subagents start cold; the
   documents are written for that.
2. Run tasks marked ∥ in parallel once their dependencies are done. Milestone 1 does not depend
   on the M0-3 spike and can proceed alongside it. Parallel agents editing the same package
   should use worktree isolation or be given disjoint files.
3. When a task reports back, review before starting anything that depends on it:
   - run `cd MythwatchKit && swift test` yourself; do not trust the reported output alone;
   - check the listed tests exist and test what the task names, not something weaker;
   - run `Tools/check-deps.sh` for the dependency rule (SPEC §2; the debug build only warns),
     and check that no v35 path or JSON key leaked outside `MythBackendV35`;
   - check any spec change the agent made is justified and consistent with the other documents.
4. Commit after each accepted task (the owner approved "one commit per task" as the working
   rule in `CLAUDE.md`). Do not push.
5. At the end of each milestone, give the owner a short status: what is done, what was verified,
   what is still marked `[verify]`.

## The backend

- The owner's MythTV backend is host `basement`, `http://basement:6544`, version **v35.0**.
  It is a working DVR.
- GET requests are fine. **No POST of any kind** unless the owner has nominated a recording for
  that specific check. The only POSTs ever sent from this project went to recording 3749 in M3-5
  (watched, last play position, bookmark; left as found). `DeleteRecording` is still unverified.
- MythTV source reference: `../mythtv`, branch `fixes/35`. Read-only, GPL: never copy code from it.
  Do not switch its branch to `master`; master's DB schema (1385) is newer than basement's (1384).
- The owner's other tvOS project `../cable-82-tv` is the model for project layout and the
  hand-written `.xcodeproj` (no project generator is installed on this machine).
- Tooling seen on this machine: Xcode 27.2, Swift 6.4.2, tvOS simulators 26.5 / 27.0 / 27.2.

## Decisions made by the owner (do not reopen)

Name Mythwatch; separate repo; Swift 6 + SwiftUI over the HTTP services API; VLCKit behind
`PlayerEngine`, dynamically linked; v35 adapter only for now behind the version seam; open
source, maybe App Store later; commercial auto-skip with undo as the default, with Skip-button
and Off modes; shelves plus shows grid; write-back of resume position, watched, delete,
bookmarks; TDD with fast, injected-fake tests; future room for Live TV, the Videos library and
an iPhone app.

## Defaults the planner chose, not yet confirmed by the owner

tvOS 26 deployment target; MIT licence; Swift Testing; land 1 s before a break ends; 8 s undo
window; mark watched at 95 %; save position every 30 s; skip steps 30 s forward / 10 s back. The
owner was told about these twice and raised no objection, but never said yes. If one becomes
load-bearing, ask.

## Open risks and unknowns

- **VLCKit on tvOS** is the go/no-go. No clear official tvOS Swift package was found in a web
  search on 2026-11-14: options were 4.0 alpha builds (mostly community wrappers) or the older
  3.6 line. M0-3 must pick on real hardware, prove dynamic linking, and confirm the build has no
  GPL-only modules. If MPEG-2 playback is not acceptable, stop and take it to the owner.
- Every recording on basement is MPEG-2 in `.ts`/`.mpg`; AVPlayer cannot play them. That is why
  VLCKit was chosen. Backend HLS transcoding was considered and rejected.
- LGPL and App Store terms: commonly shipped (VLC itself is on the store) but not legally
  settled. Only matters if the owner goes to the App Store.
- The name "Mythwatch" passed a quick web search only. "Mythic" and "MythTV" are taken.
- `[verify]` markers in `BACKEND-V35.md` list each unconfirmed wire assumption and the task that
  must settle it.

## Owner preferences observed

- Wants to be asked real questions up front, then left alone; approves quickly when given a
  recommendation.
- Is new to Apple-platform dependency and licensing conventions; explain those plainly when they
  come up.
- Needs to be present for anything touching real hardware or writing to basement, and must
  nominate a sacrificial recording before M3-5 and M5-1.
