# Opus handoff

For a direct Opus session started by the owner in this directory. Written 2026-11-15 by the
orchestrating session. To start, paste the line under "How to start" and name the task.

## How to start

> Read `opus-handoff.md` and do task **M0-3** with me.

Replace `M0-3` with the task you want. Do one task per session.

## Your role in this session

You are the **implementer**, working with the owner present. You write the code yourself.

`CLAUDE.md` tells a session started in this directory to read `docs/ORCHESTRATION.md`, and that
file says the orchestrator "does not write application code". That rule is for the Fable
orchestrating session that delegates to subagents. It does not apply to you: the owner has
chosen to run these tasks directly because each needs them in the loop. Do not spawn subagents
unless the owner asks.

Everything else in `CLAUDE.md` applies to you in full: test first, the dependency rule, no real
I/O in package tests, the live-backend rule, spec changes travel with code, stay inside the task.

## Read before you touch anything

1. `CLAUDE.md`: the working rules.
2. `docs/SPEC.md`: the contract. Read the sections your task names, plus §2 and §11.
3. Your task's entry in `docs/TASKS.md`.
4. `docs/ORCHESTRATION.md`, "Status": what each finished task left for later ones. The notes
   addressed to your task are repeated below, but the file is the full record.
5. `docs/BACKEND-V35.md` for anything that touches the backend.

## Where the project stands

- Everything is committed on `main`, locally. **Nothing has been pushed and no GitHub repo
  exists; do not push or create one unless the owner asks.**
- `MythwatchKit` (the Swift package) holds all the logic and is done up to the UI and the real
  player engine: domain, backend seam, v35 read path, settings, library builder, every view
  model, the playback session, and the commercial skipper wired into it. 868 tests, under 2 s.
- `Mythwatch/` (the tvOS app) is still the placeholder shell from M0-2: one `Text("Mythwatch")`
  view and one UI launch test. It links `MythwatchFeatures` and `MythBackendV35`. No VLCKit yet.
- Every write method in the v35 adapter is a stub that sends nothing and throws `.rejected`.
  No code in the repo can POST to a backend until M3-5.

## Tasks left, in the order I recommend

| Task | What | Needs |
| --- | --- | --- |
| ~~M0-3~~ | Done 2026-11-15: go. See `docs/VLCKIT.md`. | |
| ~~M2-7~~ | Done 2026-11-15. See `docs/ORCHESTRATION.md`. | |
| **M3-3** | `VLCPlayerEngine` | M0-3 done; real Apple TV |
| **M3-4** | Player screen | M3-3 |
| **M3-5** | Write path in the v35 adapter | **A recording the owner nominates** |
| **M4-3** | Commercial UI | M3-4 |
| **M5-1** | Delete | **A recording the owner nominates** |
| **M5-2, M5-3, M5-4** | Bonjour discovery, states and accessibility, release documents | |

M0-3 and M2-7 do not depend on each other. Do M0-3 first: if MPEG-2 playback through VLCKit is
not acceptable on real hardware, the plan changes and `TASKS.md` says to stop and report.

## Rules that are easy to break

- **The backend is the owner's working DVR** (`http://basement:6544`, MythTV v35.0).
  GET is fine. **Never send a POST** unless the task is M3-5 or M5-1 and the owner has named
  the recording in this session, and then only for that recording.
- **Requesting a scaled image writes a file on the backend.** `/Content/GetImageFile` with
  `Width` saves a cached copy the first time each size is asked for. Only request the widths
  `V35MediaLocator` produces (160, 320, 640, 1280).
- **Run every package test under a time limit:** `cd MythwatchKit && timeout 120 swift test`.
  Tests here use suspension points; one once hung for 38 minutes on a parked call. Treat a
  timeout as a failing test.
- **No `UserDefaults(suiteName:)` in tests.** It leaves a plist in `~/Library/Preferences` per
  suite. Use `InMemorySettingsStore`, or the in-memory subclass in `AppSettingsTests.swift`.
- **`Tools/check-deps.sh` enforces the dependency rule.** The build only warns. Run it before
  you finish.
- **The package must stay buildable for iOS** (an iPhone app is planned; SPEC §11). No UIKit,
  SwiftUI or tvOS-only API in any package target. If you add a framework import to the package,
  run: `cd MythwatchKit && xcodebuild -scheme MythwatchKit-Package -destination 'generic/platform=iOS' build`.
- **`../mythtv` is read-only and GPL.** Read it for behaviour; never copy or translate code from
  it, and never switch its branch (it must stay on `fixes/35`).
- **Views hold no logic and call no service.** They bind to the view models in
  `MythwatchFeatures`. If a screen needs behaviour a model lacks, add it to the model with a
  test, and update SPEC §6.4.
- **User-facing text is plain English and built in one place.** Backend errors go through
  `UserMessage`; never show a raw error.

## Commands

```
cd MythwatchKit && timeout 120 swift test                       # all package tests
cd MythwatchKit && timeout 120 swift test --filter <Name>       # one suite or test
Tools/check-deps.sh                                             # dependency rule
MYTHWATCH_LIVE_BACKEND=http://basement:6544 timeout 120 swift test --filter V35Live   # GET only
xcodebuild -project Mythwatch/Mythwatch.xcodeproj -scheme Mythwatch \
  -destination 'platform=tvOS Simulator,name=Apple TV' test     # app build + UI tests
```

Tooling on this machine: Xcode 27.2, Swift 6.4.2, tvOS simulators 26.5 / 27.0 / 27.2. There is
no project generator; `Mythwatch.xcodeproj` is hand-written with file-system-synchronised groups,
so new source files under `Mythwatch/Mythwatch/` are picked up without editing the project.

## Notes for each task

### M0-3 VLCKit spike

The task text in `TASKS.md` is the brief. On top of it:

- The chosen VLCKit build **must also ship an iOS build** of the same version with the same API,
  dynamically linked (SPEC §11). A tvOS-only build is rejected.
- It must be a **dynamic framework** embedded in the app (LGPL; SPEC §7). Confirm with
  `file` / `otool -L` and record the output. Reject static-only builds and builds with GPL-only
  modules.
- The package already depends on answers to these. Find them out and write them into
  `docs/VLCKIT.md`:
  1. After `load(url:startAt:)`, does VLC ever report playing or buffering at a position other
     than `startAt` (for example 0) before it reaches the start position? If so, a commercial
     break at 0 could fire when resuming at 20 minutes, and the session must hold its first
     ticks until the position is near `startAt`.
  2. How long does VLC report a stale, pre-seek position after a seek? The session trusts a
     seek target until the engine reports within 2 s of it or 3 s pass
     (`PlaybackSession.seekSettleTolerance` / `seekSettleTime`). Tune both to what you measure.
  3. Does VLC report positions while paused? Nothing depends on it today.
  4. How should a failed load surface? The protocol can only show it as a `.failed` snapshot.
  5. How is deinterlacing switched? `PlayerEngine` has no call for it and
     `AppSettings.deinterlace` is not part of `PlaybackSettings`.
  6. How does the snapshot stream end? The protocol has no teardown signal; the session reads
     `snapshots` once and cancels its consumer.
- If `PlayerEngine` (SPEC §5) has to change, change the spec, the protocol, `FakePlayerEngine`
  and the session together, and keep every existing session test passing.
- The owner is new to Apple-platform dependency and licensing conventions. Explain those
  plainly as they come up.

### M2-7 Library and settings UI

Screens are in SPEC §7; the models they bind to are in SPEC §6.3 and §6.4, with a rules list
per model. Things the models already decided that the views must respect:

- **Root decides Onboarding from settings, not from `AppModel.session == .idle`.** `.idle` means
  "not connected and not connecting".
- **A failed onboarding connect keeps the saved address.** So Root must keep the Onboarding
  screen and its model on screen until `connectState` is `.loaded`, and must not rebuild it
  when settings change.
- **Settings auto-saves on leaving the screen when `canSave`** (owner decision). If the address
  is invalid, show `addressHint` instead.
- **A failed library refresh keeps the library on screen** and sets `refreshProblem`; show it as
  a banner. A failed first load is `.failed` with Retry when `canRetry`.
- **A film's season has an empty title.** Do not draw a season header for it.
- **`ShowViewModel.isEmpty` means close the page** (its last recording was deleted).
- **Confirming a delete is the view's job**, honouring `AppSettings.askBeforeDelete`. The model
  only exposes `delete`.
- **Toggling watched or deleting against basement fails today.** The write stubs throw, the
  model rolls back, and the user sees "Your MythTV Backend Turned That Down". That is expected
  until M3-5 and sends nothing to the backend.
- **Delete on the episode detail page: wanted** (owner, 2026-11-15). `EpisodeDetailModel` has no
  delete yet: add it, test first, with a SPEC §6.4 line. Confirmation stays the view's job.
  After a delete, close the page.
- Start and stop discovery from the view's appear and disappear (`startDiscovery()` /
  `stopDiscovery()` on the settings and onboarding models).
- **UI tests use the real fakes** (owner, 2026-11-15). Link `MythwatchTestSupport` into the app
  for **debug builds only**; a launch argument switches the composition root to the fakes.
  Release builds must neither link nor contain it: check the Release product with `otool -L`
  / `nm`. Record the arrangement in SPEC §7, and update the app row of the SPEC §2 dependency
  table and `Tools/check-deps.sh` to match.
- **Backend address on tvOS** (owner agreed, 2026-11-15). In M0-3 the Apple TV could not resolve
  the bare name `basement` through VLC; `basement.local` and the IP address worked
  (`docs/VLCKIT.md` §8). First check whether `URLSession` on the Apple TV (or the simulator)
  resolves a bare name. If it does not, the address field's hint and the onboarding text
  should steer the user to a `.local` name or an IP address. Wording goes through the
  existing `addressHint` / `UserMessage` rules.

### M3-3 `VLCPlayerEngine` and M3-4 player screen

- `VLCPlayerEngine` is the only file that imports VLCKit and must use nothing tvOS-only, so the
  iPhone app can share it later (SPEC §11).
- **The player screen must call `PlaybackSession.finish()` when it closes.** Nothing can be
  saved if the session is simply released. After `finish()` call
  `LibraryViewModel.reloadAfterPlayback()`.
- The session finishes itself when the engine reports `.ended`; a later `finish()` returns the
  same outcome.
- There is no retry API on the session. Retry means a new session with `.resume`.
- `problem` on the session is a ready-to-show sentence. The eight strings are in SPEC §5.2.

### M3-5 Write path (owner must nominate a recording)

- Ask the owner which recording to use before sending anything. Use only that one.
- This task settles the two write-side `[verify]` items in `BACKEND-V35.md`: the shape of the
  `{"bool": ...}` reply, and whether `Offset=0` clears a stored position. Update the markers.
- `FakeBackendStore` assumes a zero position clears and a delete marks the recording
  delete-pending. If basement behaves differently, fix the fake too.
- Once writes work, check the adapter's capabilities still match what is implemented.

### M4-3 Commercial UI

- Show `.skipped(distance, undoUntil:)` with Go back (`undoCommercialSkip()`), and `.offer(break)`
  with Skip (`acceptSkipOffer()`). Draw `breaks` on the scrubber in every mode.
- **The view must hide the skipped banner when its own clock passes `undoUntil`.** While paused
  the engine sends nothing, so the session may still hold the banner. A Go back pressed after
  `undoUntil` clears it in the session.
- All banner wording is this task's. None exists yet.

### M5-1 Delete

- `ShowViewModel.delete` always sends `allowRerecord: false`. Ask the owner whether deleting
  should let MythTV record the programme again; it changes how their DVR behaves.
- Same rule as M3-5: only the recording the owner nominates.

## Decisions already made (do not reopen)

- Fixtures stay as captured, with the real titles and channel names.
- A show's kind is its most common recording kind; unknown kinds do not vote.
- Commercial skips chain across breaks less than 2 s apart (SPEC §5.1 R2 "Chaining").
- Resuming inside a break skips it; starting at a bookmark inside a break plays it.
- The `UserMessage` wording in SPEC §6 stands.
- The on-screen defaults recorded in SPEC §6.1, §6.3 and §6.4 stand.

Older decisions (name, architecture, VLCKit, licence, tvOS 26) are in `docs/ORCHESTRATION.md`.

## Finishing a task

1. Run the checks: `timeout 120 swift test`, `Tools/check-deps.sh`, the app's `xcodebuild test`,
   and the iOS package build if you added a framework import to the package.
2. Give the owner the task report `CLAUDE.md` asks for: what was built, tests added, the final
   test output, spec changes, `[verify]` items settled or found, and what you could not check.
   For UI tasks, attach a screenshot of each screen.
3. Add a "done and committed" entry for the task to the Status section of
   `docs/ORCHESTRATION.md`, with anything the next task needs to know.
4. Commit once the owner accepts: one commit per task, message starting with the task id.
   **Do not push.**
