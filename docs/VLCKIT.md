# VLCKit findings (task M0-3)

Measured 2026-11-15 on the owner's Apple TV HD ("Apple TV LR (2)", AppleTV5,3, tvOS 26.6.1, the
oldest model the app supports) and on simulators (tvOS 26.5, iOS 27.2), streaming
`/Content/GetRecording` from basement (MythTV v35.0). GET requests only.

**Verdict: go.** MPEG-2 1080i with AC-3 audio plays smoothly on the oldest Apple TV, but only
with FFmpeg's demuxer (`:demux=avformat`). VLC's own MPEG-TS demuxer cannot seek these HTTP
streams (section 4).

## 1. Chosen build

| | |
| --- | --- |
| tvOS | **TVVLCKit 3.7.4**, official VideoLAN CocoaPods binary, libVLC **3.0.24** "Vetinari" (changeset `3.0.24-42-g94bb4bd0e6`) |
| iOS (later iPhone app) | **MobileVLCKit 3.7.4**, the same VLCKit version from the same publisher |
| tvOS archive | `https://download.videolan.org/cocoapods/prod/TVVLCKit-3.0-20260930-0854.tar.xz`, SHA-256 `07892cae8e59e95a23f1fcf11692f802eae106312aa5ad9782faa2556b2d65d5` |
| iOS archive | `https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz`, SHA-256 `c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52` |
| Source | `https://code.videolan.org/videolan/VLCKit` (tag `3.7.4`); libVLC `https://code.videolan.org/videolan/vlc` (branch `3.0.x`) |
| Licence | LGPL 2.1 or later (`COPYING.txt` in the archive) |

**How it gets into the app.** VideoLAN does not publish a Swift package, only CocoaPods archives.
CocoaPods is not used here. `Tools/fetch-vlckit.sh` downloads the exact archive the official
podspec names, checks the SHA-256, and unpacks the `.xcframework` into `Vendor/`, which git
ignores. The Xcode project links `Vendor/TVVLCKit.xcframework` and embeds it with "Embed & Sign".
Run `Tools/fetch-vlckit.sh` once after cloning (add `--ios` for MobileVLCKit). To change the
version, edit the URLs and checksums in that script from the new podspecs, and update this file
and `THIRD_PARTY_NOTICES.md` in the same commit.

### Why 3.7.4 and not 4.0

| Candidate | Result |
| --- | --- |
| **VLCKit 4.0.0a26** (one xcframework for iOS, tvOS, macOS, visionOS, watchOS) | Rejected. Alpha, published on VideoLAN's "unstable" channel, on unreleased libVLC 4.0.0-dev. VideoLAN's lead developer has said alpha builds are not for third-party apps. It is dynamic and has no GPL-only codec modules, so it is the upgrade path once 4.0 is stable. |
| **TVVLCKit + MobileVLCKit 3.7.4** | **Chosen.** Stable libVLC 3.0.24, dynamic, iOS and tvOS from the same version. |
| Community wrappers (SwiftVLC, Drastic.VLCKit) | Not considered: an official VideoLAN binary exists. |

The latest MobileVLCKit is 3.7.5 and the latest TVVLCKit is 3.7.4. Both platforms are pinned to
3.7.4 so the API is identical.

## 2. Hard requirements

**Dynamic framework (SPEC §7).** Checked on the built app (`Debug-appletvos`):

```
$ file Mythwatch.app/Frameworks/TVVLCKit.framework/TVVLCKit
Mythwatch.app/Frameworks/TVVLCKit.framework/TVVLCKit: Mach-O 64-bit dynamically linked shared library arm64
$ otool -L Mythwatch.app/Mythwatch | grep -i vlc
	@rpath/TVVLCKit.framework/TVVLCKit (compatibility version 1.0.0, current version 1.0.0)
```

Every slice in both xcframeworks is a dynamic library: tvOS `tvos-arm64` and
`tvos-arm64_x86_64-simulator`; iOS `ios-arm64_armv7_armv7s` and `ios-arm64_x86_64-simulator`.

**iOS coverage (SPEC §11).** A throwaway iOS copy of the app, built from the same spike source
files, linked MobileVLCKit and embedded it dynamically
(`@rpath/MobileVLCKit.framework/MobileVLCKit`) for both iPhone device and simulator. On an iPhone
simulator (iOS 27.2) it played recording 3749 with the same results as tvOS: length 3,598,382 ms,
every seek within 2 s, and the same behaviour for a seek while paused.

API differences between the platforms:

- **Module name.** tvOS is `import TVVLCKit`, iOS is `import MobileVLCKit`.
  `VLCPlayerEngine` uses `#if os(tvOS) import TVVLCKit #else import MobileVLCKit #endif`.
- **Headers.** The public headers are byte-identical apart from the umbrella header. iOS adds
  `VLCRendererDiscoverer`, `VLCRendererItem` (Chromecast) and `VLCTranscoder`; the engine uses none.
- **Modules.** iOS has three more libVLC modules: `stream_extractor_libarchive`,
  `stream_filter_decomp` and `video_filter_ci_filters`. None matter for MythTV recordings.
- **Old 32-bit slices.** The iOS device slice includes armv7 and armv7s, and was built against
  iOS SDK 15.4. An iOS 26 app does not need them. Strip them (`lipo -remove`) in the iPhone app's
  build before any App Store upload.

**No GPL-only modules.** The tvOS binary holds 239 statically linked libVLC modules (listed with
`nm | grep vlc_entry__`). VLC's configure line in the binary has `--disable-a52 --disable-faad
--disable-mad --disable-goom --disable-projectm --disable-dvdread --disable-dvdnav`, and none of
the GPL-only modules is present (`a52`, `dca`, `libmpeg2`, `faad`, `x264`/`x265`, `postproc`,
`goom`). MPEG-2 video and **AC-3 audio decode through FFmpeg's libavcodec (LGPL)**. The binary
does contain some GPL text, but it is template text, not code: libVLC's `--version` banner and
gnulib's version-message templates.

`[verify]` (for M5-4, release documents): the binary bundles third-party libraries (FFmpeg,
GnuTLS, libxml2, libzvbi, live555, libsmb2, libass, taglib and others). VideoLAN ships them under
the LGPL umbrella, but their individual licences were not audited here. Check **libzvbi**
first: older releases had GPL parts.

## 3. Measurements (Apple TV HD unless stated)

| | |
| --- | --- |
| Test streams | 3753 Morning Report (.mpg, 1920×1080 MPEG-2 top-field-first 29.97, 2× AC-3, 12.6 Mbit/s, 90 min); 3749 Amber Street Sessions (.ts, same format, English + Spanish AC-3, 8.8 Mbit/s, 60 min) |
| Time to first frame (`play()` to first displayed picture) | 1.8 to 2.8 s, median 2.3 s, over 12 runs, including resumes at 5 to 30 min. tvOS simulator: 0.55 s |
| Dropped frames, 1080i, default or deinterlace off | 0 to 1 lost pictures per 30 to 60 s; 0 lost audio buffers |
| Deinterlace `blend` | 30 fps output, 0 lost |
| Deinterlace `bob` | 60 fps output, 0 to 2 lost per 20 to 30 s |
| Deinterlace `linear` | 60 fps output, 0 to 1 lost |
| Deinterlace `yadif` | 30 fps output, **251 lost in 20 s (unusable on Apple TV HD)** |
| Deinterlace `yadif2x` | 60 fps output, **634 lost in 30 s (unusable)** |
| Closed captions shown | 89 to 115 lost pictures in about 45 s (about 6 %). Captions are usable on this model but cost frames |
| Around seeks (avformat) | 3 lost pictures and 6 lost audio buffers in 60 s with 6 seeks |
| App size | Debug app 40 MB, of which TVVLCKit.framework is 37 MB (tvOS device slice). Download archives: 125 MB (tvOS), 222 MB (iOS) |
| Audio | AC-3 plays (owner confirmed sound). Switching audio track works (log confirms the switch to track 2, "Spanish") |
| Captions | CEA-608/708 enumerate as "Closed captions 1" to "Closed captions 4" (ids 3 to 6), and they render (owner confirmed) |

The owner could not see a difference between off, blend, bob and linear on this material, at
normal viewing distance. The choice of `bob` is made on the numbers: full 60 fps motion and no
measurable cost on the oldest hardware.

## 4. The demuxer: always use `:demux=avformat`

VLC's own MPEG-TS demuxer fails on these files when they are read over HTTP:

- **`.ts` recordings: no length** (`media.length` stays 0). Time seeks and `:start-time` are
  ignored, and playback starts at 0. Seeking by byte fraction (`player.position`) moves, but the
  reported time then falls to 0 and stays there.
- **`.mpg` recordings: wrong length** (20,355 s for a 5,400 s show). It guesses the bitrate as
  3.3 Mbit/s instead of 12.6, so every seek lands about 0.27× as far as asked: resume at 1,200 s
  landed at 321 s, and +30 s moved 8 s.

With the media option **`:demux=avformat`** (FFmpeg's demuxer, LGPL, already in the build):
length is right (3,598,382 ms for a 3,601 s recording, 5,397,912 ms for a 5,400 s one), the
start time is honoured, seeks land within 0.7 s of the target, and every track enumerates with
language names ("Track 1 - [English]"). Both MythTV file extensions behave the same.

## 5. Options used

```swift
let media = VLCMedia(url: url)                         // http://<backend>/Content/GetRecording?RecordedId=<id>
media.addOption(":demux=avformat")                     // required, section 4
if let startAt { media.addOption(":start-time=\(seconds)") }   // seconds, fractional allowed
player.media = media
player.setDeinterlaceFilter(deinterlace ? "bob" : nil) // after setting the media
player.play()
seek:     player.time = VLCTime(int: Int32(ms))
position: player.time.intValue (ms)        duration: player.media?.length.intValue (ms; 0 = unknown)
tracks:   audioTrackNames / audioTrackIndexes / currentAudioTrackIndex
          videoSubTitlesNames / videoSubTitlesIndexes / currentVideoSubTitleIndex (-1 = off)
```

No network-caching option was needed; VLC's default (1000 ms) gave no rebuffering on the LAN.

## 6. How events arrive

- **Thread.** Every delegate callback (`mediaPlayerStateChanged`, `mediaPlayerTimeChanged`)
  arrives on the **main thread** (VLCKit's default events configuration).
- **Position rate.** `mediaPlayerTimeChanged` fires every 256 ms at the median (95th percentile
  262 ms, 99th 284 ms, up to about 330 ms in the last seconds of a file): about **3.9 per second**,
  not quite 4. Nothing is sent while paused.
- **`player.state` is the last event, not the player's state.** It sits at `ESAdded` or
  `Buffering` while video plays. `Buffering` and `ESAdded` events keep arriving **during normal
  playback**: 100 to 800 `Buffering` events per minute. Use `player.isPlaying` and the
  `Playing`, `Paused`, `Ended`, `Error` and `Stopped` events. Ignore `Buffering` while
  `isPlaying` is true, and never emit one snapshot per buffering event.
- **Duration** is known from the first position callback with avformat.

## 7. Answers to the six questions

1. **Does VLC report a position other than `startAt` before reaching it? Yes, in one way.** With
   `:start-time`, the `Playing` event arrives 1.0 to 1.2 s before the first position callback,
   and during that gap `player.time` reads **0**. The first `mediaPlayerTimeChanged` is the start
   point itself (1,200,010 ms when asked for 1,200,000). No intermediate positions are reported.
   **Rule for the engine:** stay `.loading` at `startAt` until the first position callback, and
   never take a position from `player.time` before then. The session needs no change.
2. **Stale positions after a seek: none.** Setting `player.time` makes `player.time` read the
   **target** within about 10 ms. The next callback, 250 to 350 ms later, carries the real landing
   position, which is within 0.7 s of the target. The 2 s tolerance and 3 s timeout
   (`seekSettleTolerance`, `seekSettleTime`) fit what was measured, so they stay as they are.
   **Seek while paused:** VLC applies the seek but reports nothing until play resumes; the
   first callback then lands on the target (595,174 ms for 595,161). **Rule for the engine:**
   after `seek(to:)` emit a snapshot at the target at once (as `FakePlayerEngine` does), so a
   paused seek shows the new position.
3. **Positions while paused: no.** `Paused` arrives within 5 ms of `pause()`, then nothing until
   `play()`.
4. **A failed load.** A refused port or unknown host gives `Opening`, `Error`, `Stopped` within
   25 to 105 ms. There is no reason text: VLCKit 3 does not expose one. **Trap:** a backend 404
   (unknown `RecordedId`; MythTV sends a 404 with an HTML body) gives `Opening`, `Playing`,
   `Ended`, with no position ever reported. **Rule for the engine:** `Error` becomes
   `.failed(...)`, and so does `Ended` before any position callback. Without that, a missing
   recording would look finished and could be marked watched.
5. **Deinterlacing.** `player.setDeinterlaceFilter("bob")` to turn it on, `setDeinterlaceFilter(nil)`
   to turn it off; call it after setting the media. `PlayerEngine` does not need a call for it:
   the app builds a new engine for each playback, and passes `AppSettings.deinterlace` to
   `VLCPlayerEngine`'s initialiser. `yadif` and `yadif2x` must not be used on Apple TV HD.
6. **End of the snapshot stream.** At the end of a file VLC sends `Ended` about 0.6 s short of
   the length (3,597,792 of 3,598,382 ms), then `Stopped` 140 ms later, then nothing. After
   `stop()` it sends `Stopped` once. **Rule for the engine:** on `Ended`, report
   position = duration. Finish the `snapshots` stream only on deinit, as `FakePlayerEngine`
   does: one engine per playback, and the session cancels its consumer when it finishes.

## 8. Other findings

- **The Apple TV cannot resolve the bare name `basement`.** Playback through
  `http://basement:6544` failed at once (`Opening`, `Error`), while `http://basement.local:6544`
  (Bonjour) and `http://192.168.1.50:6544` played. The Mac resolves the bare name; the Apple TV
  does not. **Settled in M2-7:** `URLSession` on the Apple TV fails the same way (Test Connection
  to `basement` gave "Can't Reach Your MythTV Backend"; `basement.local` found v35.0). The
  address hint now suggests `<name>.local` or the IP address for a bare name (SPEC 6.4 "Address
  rules"); M5-2 discovery should store the resolved `.local` host.
- **No Local Network permission prompt appeared** on tvOS 26.6.1 for plain HTTP to the backend.
- **Track ids** are VLC's stream indexes: audio 1, 2 and captions 3 to 6 on these recordings,
  with -1 meaning "Disable". `VLCPlayerEngine` should drop the "Disable" entry from the lists and
  map `selectedSubtitleTrack = nil` to -1.

## 9. Known problems

- Captions cost about 6 % of frames on Apple TV HD (section 3).
- The position rate is just under 4 per second (section 6). SPEC §5 now says "about every 250 ms".
- VLCKit 3 gives no reason text for a failure, so `.failed` carries a fixed internal message.
  Users only ever see the session's `problem` sentence.
- **A still-growing recording ends early** (section 10). The engine has to reopen it.

## 10. A recording still in progress

Tested at 18:04 on 2026-11-15 on recording 3755 (*Counter Offers*, KMWC, `.ts`), which started at
18:00. Nothing crashed, but **VLC reads the file size once, when it opens the stream.**

- Started 8 s behind the live point, it took the length then current (238,416 ms), played to it,
  and reported `Ended` then `Stopped` 12 s later, although the recording carried on.
- The backend reports the current size on every request
  (`Content-Range: bytes 0-0/79639432`, growing between requests), so a fresh open sees more.
- **Reopening at the last position works.** Four rounds on the Apple TV, each reopening with
  `:start-time` at the position where VLC stopped: it resumed within 10 ms of that position,
  after a gap of 0.9 to 1.8 s with no lost frames. Each open saw the length recorded so far
  (441, 461, 484, 509 s).

**Rule for `VLCPlayerEngine`:** when VLC reports `Ended`, check the file's current size with a
1-byte range GET (`Range: bytes=0-0`, read the total from `Content-Range`). If it is larger
than when the media was opened, reopen at the last position and do not report `.ended`. Report
`.ended` only when the file has not grown. Close behind the live point this means a short pause
about every 20 s. The engine needs no flag for this, and `PlayerEngine` does not change. Without
it, the session would finish a show that is still recording, and could mark it watched.

## 11. LGPL obligations

What distributing an app that embeds VLCKit requires (LGPL 2.1, section 6). This is a summary,
not legal advice:

1. **Link dynamically.** VLCKit stays a separate `.framework` in the bundle (done, section 2), so
   a user could in principle replace it with a modified build.
2. **Give notice and the licence.** Say the app uses VLCKit/libVLC under the LGPL, include the
   LGPL 2.1 text, and say where the source is. This goes in `THIRD_PARTY_NOTICES.md` and the
   in-app licences screen (SPEC §7).
3. **Make the source available.** Point to the exact VLCKit and libVLC source for the version
   shipped (section 1). The URLs above are VideoLAN's own; keeping a copy of the source archive
   with each release is the safe way to honour a source request for up to three years.
4. **Do not forbid reverse engineering** of the app for debugging such changes. Mythwatch is MIT
   and open source, so this is already met.
5. **App Store.** Apple's terms add use restrictions that some people consider incompatible with
   the LGPL. VLC itself ships on the App Store and VideoLAN publishes VLCKit for exactly this use,
   but it has not been tested in court. It only matters if the owner submits to the App Store.

## 12. Changes to SPEC §5 `PlayerEngine`

The protocol does not change. The comment on `snapshots` now says "about every 250 ms" instead
of "at least 4x per second". SPEC §5 gains the engine rules from sections 7 and 10 (hold positions
until the first real one, echo seek targets, a premature `Ended` is a failure, a growing file is
reopened rather than ended, coalesce buffering events, finish the stream on deinit). SPEC §7 records the demuxer option, the deinterlace filter,
and how the dependency is fetched.

## 13. `VLCPlayerEngine` checklist (M3-3)

Run 2026-11-15 on the Apple TV HD with a temporary harness (not committed) that drove the real
engine and logged every snapshot. Recordings 3753 (*Morning Report*), 3749 (*Amber Street
Sessions*) and 3757 (*Counter Offers*, being recorded at the time). GET requests only.

| Check | Result |
| --- | --- |
| Load from the beginning, play | `.loading` at 0, then `.playing` from the first position with duration 5397 s; picture and sound |
| Snapshot rate | 3.91 positions per second while playing (3.87 on the simulator); VLC's buffering events while playing never reached the stream |
| Pause | `.paused` within 2 ms of the call; no positions while paused |
| Seek while paused | +60 s shown at once at the target; play resumed from it |
| Seek while playing | −10 s shown at once; the next positions continued from the landing point |
| Resume at an offset | load at 1200 s: `.loading` at 1200 s, first position 1200.9 s, never 0 |
| End of file | `.ended` at exactly the duration (5397.9 s), after the size check found the file unchanged |
| Missing recording (404) | `.failed` within 40 ms (VLC sent Error this time, not the Ended of §7.4; both are covered) |
| Unreachable address | `.failed` within 30 ms |
| Recording in progress | started 25 s behind live; VLC ended twice at the size it had seen, the engine reopened each time (gaps 0.88 s and 1.09 s, positions continuous), never `.ended` |
| Audio tracks | both listed (3749: "English", "Spanish"; 3753: "Track 1", "Track 2", no language); switching to track 2 took effect according to VLC. The owner did not hear Spanish on 3753; its second track may not be a second language |
| Captions | four caption tracks listed; captions showed on screen (owner: "quite large") and went away when turned off |
| Deinterlace on / off | both played with no errors; no visible difference reported (as in §3) |
| Stream end | every released engine finished its `snapshots` stream |

On the simulator, `basement.local` does not resolve (VLC stays in Opening with no further
event); the bare name works there. On the Apple TV it is the other way round (§8).
