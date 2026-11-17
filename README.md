# Mythwatch

A native Apple TV app for watching recordings from a [MythTV](https://www.mythtv.org) backend.

Mythwatch talks to the backend's HTTP services API. You can browse your recordings by show and
season, pick up where you left off, skip commercials, and mark recordings watched or delete them.
Resume points, bookmarks and watched flags are saved on the backend, so mythfrontend sees the same
state.

- Continue Watching and Recently Recorded shelves, a grid of shows, and a page for each show and
  episode.
- Playback through VLCKit, with skip, scrub, resume, play from bookmark, audio and subtitle
  tracks, and optional deinterlacing for 1080i recordings.
- Commercial skipping from MythTV's commercial flags: skip automatically with a Go Back option
  (the default), show a Skip button, or turn it off.
- Finds the backend on your network by Bonjour, or you can type its address.
- VoiceOver labels, Reduce Motion and large text are supported.

## Requirements

- An Apple TV running **tvOS 26** or later.
- A **MythTV v35** backend reachable from the Apple TV (the services API, port 6544 by default).
  Other MythTV versions are refused with a message saying so; see "Adding a backend version".
- To build: a Mac with **Xcode 27** (Swift 6 language mode). Package tests run on macOS 15 or
  later.

## Building

VLCKit is not kept in git. Fetch it once after cloning; the script downloads VideoLAN's pinned
release, checks its SHA-256, and unpacks it into `Vendor/`:

```
Tools/fetch-vlckit.sh            # tvOS framework into Vendor/ (add --ios for the iPhone one)
```

Then open `Mythwatch/Mythwatch.xcodeproj`, choose the **Mythwatch** scheme, and run it on the
Apple TV simulator or, after choosing your signing team, on an Apple TV. On first launch the app
lists the backends it found on the network; choose one or type its address.

`docs/VLCKIT.md` explains the choice of VLCKit and the pinned version.

## Testing

```
cd MythwatchKit && swift test                      # all package tests; must stay under 10 s
cd MythwatchKit && swift test --filter <Name>      # one suite or test
Tools/check-deps.sh                                # the dependency rule between targets
xcodebuild -project Mythwatch/Mythwatch.xcodeproj -scheme Mythwatch \
  -destination 'platform=tvOS Simulator,name=Apple TV' test          # app build and UI tests
```

Package tests use fakes and recorded fixtures only: no network, no real clock. The UI tests run
the app on an invented demo library (the `-MythwatchFakes` launch argument), so they need no
backend either.

Optional tests against a real backend send **GET requests only**:

```
MYTHWATCH_LIVE_BACKEND=http://mybackend:6544 swift test --filter Live
```

A backend is usually someone's working DVR. Do not point anything that writes (watched,
position, bookmark, delete) at one you do not own.

## How it is built

The app target is SwiftUI with no logic beyond layout, focus and navigation. Everything else is in
the `MythwatchKit` Swift package:

| Target | What it holds |
| --- | --- |
| `MythwatchDomain` | Recordings, shows, positions and the service protocols ("ports") |
| `MythwatchBackend` | The HTTP transport, version probe, and the adapter registry |
| `MythBackendV35` | The MythTV v35 adapter: the only code that knows v35 endpoints and JSON |
| `MythwatchPlayback` | Playback sessions, resume, and commercial skipping, over a `PlayerEngine` |
| `MythwatchFeatures` | View models and the app's composition |
| `MythwatchTestSupport` | Fakes, fixtures, the demo backend, and the adapter conformance suite |

`docs/SPEC.md` is the specification, `docs/BACKEND-V35.md` the v35 wire contract, and
`docs/TASKS.md` the task list.

## Adding a backend version

MythTV's services API changes between versions, so each version gets its own adapter behind the
same protocols. The app asks the backend for its version and picks the first registered adapter
that supports it.

1. Add a package target `MythBackendVNN` that depends on `MythwatchBackend` and
   `MythwatchDomain` only.
2. Implement `BackendAdapterFactory` and the ports (`RecordingsService`, `PlaybackStateService`,
   `MarkupService`, `MediaLocator`). Start from a copy of the nearest version.
3. Capture fixtures from a live backend of that version with `Tools/capture-fixtures.sh` (GET
   requests only), and write that version's wire contract alongside `docs/BACKEND-V35.md`.
4. Make the shared adapter conformance suite (`AdapterConformance`, SPEC §9.1) pass for the new
   adapter.
5. Register the factory in `Mythwatch/Mythwatch/App/Composition.swift`, and add the target to
   the dependency table in SPEC §2 and `Tools/check-deps.sh`.

The full procedure is in SPEC §4, "Adding a backend version".

## Licence

Mythwatch is MIT-licensed (see `LICENSE`). It contains no code from MythTV.

The app embeds VideoLAN's VLCKit, which is under the GNU LGPL and contains other open-source
libraries, one with a GPL-2 part. `THIRD_PARTY_NOTICES.md` lists them with their licences and
where to get their source; the app shows the same text under Settings › About › Licences.

The app icon and Top Shelf images are placeholders.
