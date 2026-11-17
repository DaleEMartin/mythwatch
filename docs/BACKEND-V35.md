# MythTV v35 services API: wire contract for `MythBackendV35`

Source of truth: the MythTV source at `../mythtv` on branch `fixes/35`, directory
`mythtv/programs/mythbackend/servicesv2/` (`v2dvr.h/.cpp`, `v2content.h/.cpp`, `v2myth.h/.cpp`)
and `mythtv/libs/libmythbase/http/`. Read those files when this document is silent.

Each statement below is marked:

- **[live]** observed on a real v35.0 backend with a read-only call on 2026-11-14 (the
  committed fixtures in `MythwatchKit/Tests/MythBackendV35Tests/Fixtures/` are from these calls).
- **[source]** read from the v35 source, not exercised live.
- **[verify]** an assumption; the task that depends on it must check it first.
- **[live write]** observed on the owner's v35.0 backend with a POST to the one nominated
  recording (id 3749), M3-5, 2026-11-16.

`UpdateRecordedWatchedStatus`, `SetLastPlayPos` and `SetSavedBookmark` are [live write].
`DeleteRecording` is [live write] too (M5-1, 2026-11-16: 3749, and by the owner 622, 745, 1913).

## General

- Base URL `http://<host>:6544`. No authentication in v35. [live]
- Send `Accept: application/json` on every request. Without it the backend returns XML. [live]
- Parameter names are case-insensitive. [source]
- GET parameters go in the query string. POST parameters may be sent as
  `application/x-www-form-urlencoded` or as a flat JSON object body; when a body is present the
  query string is ignored. [source] **Use form-urlencoded for every POST.**
- Scalar results are wrapped by type name: `{"String": "x"}`, `{"bool": true}`, `{"long": "0"}`.
  A `long` arrives as a **string**. [live for String and long] The serialiser writes `int`,
  `uint`, `qlonglong` and `qulonglong` as JSON numbers, `bool` as a bare `true`/`false`, and every
  other scalar type (including `long`) as a quoted string. [source] `{"bool": true}` with a bare
  JSON `true`, `Content-Type: application/json; charset="UTF-8"`, HTTP 200. [live write] Decode
  bool and numeric scalars leniently anyway: accept a JSON bool/number or a string holding one.
- JSON replies carry `Content-Type: application/json; charset="UTF-8"` (quoted charset) and
  escape `/` as `\/`; any JSON decoder handles both. Doubles are written with six decimals
  (`"Stars": 0.000000`). [live]
- Timestamps are ISO 8601 UTC with `Z`, no fractional seconds: `2026-11-14T20:30:00Z`. [live]
- Errors:
  - Unknown method: HTTP 404, `Content-Type: text/html; charset="UTF-8"`, body
    `<!DOCTYPE html><HTML><HEAD><TITLE>404 Not Found</TITLE>...<H1>404 Not Found</H1></BODY></HTML>`
    (fixture `not-found.html`). [live]
  - A service exception: HTTP 400 with an HTML body carrying the message. [source]
  - Many "not found" cases return HTTP 200 with an empty object, not an error (see below). [live]
- A multi-backend setup can answer a file request with a redirect to the host that holds the
  file. [source] The transport follows redirects.
- Each service reports an API version at `/<Service>/version`, e.g. `/Dvr/version` returns
  `{"String": "7.1"}`. [live] Not used for adapter selection; record it in diagnostics.

## Version probe (implemented in `MythwatchBackend`, listed here for reference)

`GET /Myth/GetBackendInfo` [live]

```json
{"BackendInfo": {"Build": {"Version": "v35.0", "LibX264": true, "LibDNS_SD": true},
                 "Env": {"...": "..."}, "Log": {"...": "..."}}}
```

`Build` holds exactly those three keys. `Env` exposes the backend's home directory, service
user, web root and locale, and `Log` its command-line log arguments: never log or display them.
[live]

`GET /Myth/GetHostName` returns `{"String": "<host>"}` (the bare host name, no domain). [live]

## Recordings

### `GET /Dvr/GetRecordedList` [live]

Parameters used: `Descending=true`, `StartIndex`, `Count`, `IgnoreLiveTV=true`,
`IgnoreDeleted=true`, `IncCast=false`, `IncChannel=true`, `IncArtWork=true`,
`IncRecording=true`. Other parameters exist (`TitleRegEx`, `RecGroup`, `StorageGroup`,
`Category`, `Details`, `Sort`); see `v2dvr.h`.

**Do not send `Sort`.** When `Sort` is present the backend orders by the named field(s),
ascending unless a field is suffixed ` desc`, and ignores `Descending` entirely. [source]
`Sort=starttime&Descending=true` returned the **oldest** recordings first; `Descending=true`
without `Sort` returned the newest first (`ORDER BY` recording start time descending). [live]
Start times can tie (two channels at once), so the order between pages is not guaranteed
stable: the adapter must de-duplicate by `RecordedId`.

`IncCast=false`, `IncChannel=false` and `IncArtWork=false` are honoured by this call: the key
stays and its value is `null`. [live] (`GetRecorded` takes none of these and always includes
`Cast`, `Channel` and `Artwork`.) [live] Every `Inc*` parameter defaults to true when absent.
[source]

Paging: request pages of 200 until `StartIndex + Count >= TotalAvailable`; the adapter also stops on a page with no programmes, even if the total says more, and a failing page fails the whole call. (`V35RecordingsService.defaultPageSize` is 200; tests inject a smaller one.) All six paging
fields are always present; `StartIndex`, `Count` and `TotalAvailable` are JSON numbers,
`Version` and `ProtoVer` strings. [live] `Count` in the reply is the number of programmes
returned; `TotalAvailable` counts rows after filtering. Rows whose deletion is pending are
**always skipped** by this call, whatever the parameters. [source] The reference backend has
307 recordings across 37 titles.

```json
{"ProgramList": {
  "StartIndex": 0, "Count": 1, "TotalAvailable": 307,
  "AsOf": "2026-11-14T22:14:40Z", "Version": "35.20220913-1", "ProtoVer": "91",
  "Programs": [ { "...Program..." } ]}}
```

**Program object** (fields the adapter reads; all observed types are [live]):

| JSON field | Type | Maps to | Notes |
| --- | --- | --- | --- |
| `Title` | string | `title` | null only in the not-found case |
| `SubTitle` | string | `subtitle` | `""` becomes nil (29 of 307 are empty) |
| `Description` | string | `synopsis` | `""` becomes nil |
| `Category` | string | `category` | `""` becomes nil |
| `CatType` | string | `kind` | `series`, `movie`, `tvshow`, `sports`, `""` (21 of 307 empty) → `.unknown` |
| `Season`, `Episode` | int | `season`, `episode` | 0 becomes nil (19 of 307 have season 0) |
| `Airdate` | string or **null** | `originalAirDate` | `yyyy-MM-dd`; null and `""` become nil. With no original air date but a release year the backend sends `<year>-01-01` (seen on every movie captured) [live, source] |
| `Inetref` | string | `seriesKey` | e.g. `ttvdb4.py_78193`; `""` becomes nil (4 of 307) |
| `StartTime`, `EndTime` | timestamp | `scheduledStart/End` | the programme's listing times |
| `LastModified` | timestamp | `lastModified` | |
| `FileSize` | int | `fileSize` | bytes; exceeds 32 bits |
| `ProgramFlagNames` | string | `flags` | `|`-separated names, or `NONE`. See below |
| `VideoPropNames` | string | `video`, `flags.damaged` | `|`-separated, `UNKNOWN` when none. Defined: `WIDESCREEN`, `HDTV`, `MPEG2`, `AVC`, `HEVC`, `720`, `1080`, `4K`, `3DTV`, `PROGRESSIVE`, `DAMAGED` [source]; seen: `WIDESCREEN\|HDTV\|MPEG2\|1080`, `WIDESCREEN\|MPEG2` [live] |
| `Channel` | object or **null** | `channel` | `ChanNum`, `CallSign`, `ChannelName` (strings; `ChanNum` like `7_1`). `null` with `IncChannel=false`; only `ChanId` filled when the channel no longer exists [source] |
| `Recording` | object or **null** | see below | `null` with `IncRecording=false` and in the not-found reply |
| `Artwork` | object or **null** | `artwork` | `{"ArtworkInfos": [{"URL","FileName","StorageGroup","Type"}]}`. `null` when `Inetref` is `""` or `IncArtWork=false`; `{"ArtworkInfos": []}` when the programme has an `Inetref` but no artwork (2 of 8 captured rows) [live, source] |
| `Cast` | object or **null** | ignored in v1 | `{"CastMembers": [...]}`; `null` with `IncCast=false` |

Other keys present on every programme and not read in v1: `Repeat` (bool), `SeriesId`,
`ProgramId`, `Stars` (double), `ProgramFlags`, `VideoProps`, `AudioProps`, `AudioPropNames`,
`SubProps`, `SubPropNames`, `TotalEpisodes`, `FileName`, `HostName`. [live]

Parse flags from the **names**, never from the numeric `ProgramFlags`: bit values can change
between versions. Names are written in bit order; a set bit with no name is written as hex,
e.g. `0x00100000`, which falls under "anything else". [source] Names seen or defined in
`libs/libmythbase/programtypeflags.h`:

| Name | Domain flag |
| --- | --- |
| `WATCHED` | `.watched` |
| `BOOKMARK` | `.hasBookmark` |
| `LASTPLAYPOS` | `.hasResumePosition` |
| `COMMFLAG` | `.commercialsFlagged` |
| `CUTLIST` | `.hasCutList` |
| `INUSERECORDING` | `.recordingInProgress` |
| `DELETEPENDING` | `.deletePending` |
| anything else (`AUTOEXP`, `REPEAT`, `TRANSCODED`, ...) | ignored |

**A recording in progress (list and single fetch disagree).** For a recording still being
recorded, `GetRecordedList` reports `INUSERECORDING` (and usually `INUSEOTHER`) in
`ProgramFlagNames` and `Recording.Status`/`StatusName` of "Recording", while `GetRecorded` for the
same `RecordedId`, seconds apart, reports neither: the in-use flags are absent and the status is
`Recorded`. [live 2026-11-15, GET only: list row `AUTOEXP|COMMPROCESSING|INUSERECORDING|INUSEOTHER`
with `Recording`; single fetch `AUTOEXP|EDITING|COMMPROCESSING` with `Recorded`; the finished
recording next in the list was identical from both endpoints.] Why: the list loader merges two
extra sources into each row, the table of in-use programs (the in-use flags) and the scheduler's
set of active recordings (status "Recording" when the recording's end is still ahead and it is
active); the single fetch builds one programme from the database row alone, which has no in-use
information and always starts with status `Recorded`. [source: `v2dvr.cpp`,
`libmythbase/programinfo.cpp`] `EDITING` showing only on the single fetch is a separate cause:
both paths derive it from "really editing" or "comm-flag processing", but the list's version of
that test compares against a comm-flag status constant instead of the flag, so it never sets
`EDITING` from `COMMPROCESSING`. [source] The list also clears `COMMPROCESSING` when no comm-flag
job is running. `EDITING` is not mapped, so it does not matter to the adapter.
Consequence: `recordingInProgress` (and any in-use state) is **reliable only from
`allRecordings()`**; `recording(id:)` of an in-progress recording comes back without it. Decision:
the adapter does not work around this (no field of the single-fetch reply shows in-progress state
reliably, and an `EndTs` in the future is only a scheduled end). Nothing in the package fetches a
single recording to decide in-progress state; `LibraryBuilder` works from the list. Other fields
(for example `FileSize`, `Recording.EndTs`) may also change between two requests while the file
grows; the live test compares only recordings it can expect to be stable plus, for an in-progress
one, every field except `flags`.

**Recording object:**

| JSON field | Type | Maps to |
| --- | --- | --- |
| `RecordedId` | int | `id` |
| `StartTs`, `EndTs` | timestamp | `recordingStart`, `recordingEnd` |
| `RecGroup` | string | `recordingGroup` |
| `FileName` | string | not exposed; `.ts` (287) or `.mpg` (13) on the reference backend |
| `Status`, `StatusName` | int, string | not exposed in v1 (`-3` / `Recorded` for every row) |

`VideoTraits`: `isHD` when `HDTV` present; `isWidescreen` when `WIDESCREEN` present;
`verticalResolution` from `1080` / `720` when present.

Artwork `Type` → `ArtworkKind`: `coverart` → `.poster`, `fanart` → `.fanart`, `banner` →
`.banner`; other types dropped. `ArtworkReference.locator` is the `URL` value verbatim (a
server-relative path such as `/Content/GetImageFile?StorageGroup=Coverart&FileName=...`). Only
`coverart` was present on the reference backend (273 of 307 programmes).

Decode every DTO string as optional and every number with a default, so one odd row cannot fail
the whole list. A row with no `Recording.RecordedId` or with `RecordedId <= 0` is skipped.

Row rules implemented by the mapper (`RecordingMapper`, M1-6), chosen so that no data is invented:
a row is **skipped** (the neighbours survive) when it has no `Recording` object or `RecordedId <= 0`,
a null or empty `Title`, or any of `StartTime`, `EndTime`, `LastModified`, `Recording.StartTs`,
`Recording.EndTs` that is missing or not `yyyy-MM-ddTHH:mm:ssZ`. An unparseable `Airdate` becomes
nil (the row is kept). Missing `RecGroup` becomes `""`, missing `FileSize` 0. `Channel` becomes nil
when it is null or has no `ChanNum`, `CallSign` and `ChannelName`; otherwise missing parts are `""`.
`VideoPropNames` `4K` sets neither a resolution nor anything else (only `1080` and `720` are mapped).
Scalar envelopes (`long`, `bool`, `String`) throw a decoding error when the value is missing or not
convertible; unknown keys are ignored everywhere. Pairing commercial marks into breaks is left to
the adapter (M1-7); the mapper layer only decodes the cut list.

### `GET /Dvr/GetRecorded?RecordedId=<id>` [live]

Returns `{"Program": {...}}` with the same shape, always with `Channel`, `Recording`, `Artwork`
and `Cast` objects for a real recording. **An unknown id returns HTTP 200 with a blank
programme** (fixture `recorded-missing.json`): `"Title": null` and most strings `null`,
`"CatType": ""`, zeroed numbers, `"ProgramFlagNames": "NONE"`, `"VideoPropNames": "UNKNOWN"`,
`StartTime`/`EndTime`/`LastModified` set to the current time, a `Channel` object of nulls and
zeros, and **`"Recording": null`** and `"Artwork": null`. [live] The adapter must map that to
`BackendError.notFound`: treat `Title == null`, `Recording == null`, or a missing/zero
`Recording.RecordedId` as not found.

### `POST /Dvr/UpdateRecordedWatchedStatus` [live write]

Every write goes through `V35Client.postExpectingTrue`: no query string, headers
`Accept: application/json` and `Content-Type: application/x-www-form-urlencoded`, body
`name=value&...`. `{"bool": false}` → `.rejected("<path> returned false")`; HTTP and decoding
errors map as for reads. [live write: the form body is accepted]

Form fields `RecordedId`, `Watched=true|false`. Returns `{"bool": true}`, and `WATCHED` appears
in (or leaves) `ProgramFlagNames` at once, from both `GetRecorded` and `GetRecordedList`. [live
write] Returns `false` when the recording does not exist or has no file → `.rejected`. [source;
not tried live: only the nominated recording may receive a POST]

### `POST /Dvr/DeleteRecording` [live write]

Implemented in M5-1 through `postExpectingTrue`, like every write. Form fields `RecordedId`, `ForceDelete=false`, `AllowRerecord=<bool>`. Returns `{"bool": true}`
when the delete was **queued**; deletion is asynchronous. `false` → `.rejected` (the backend answers `false` when the recording has no channel or no file
path). `AllowRerecord=true` makes the backend forget the recording in its history so the scheduler
may record it again; the app asks the user each time. Until it
completes, `GetRecorded` can still return the recording with the `DELETEPENDING` flag;
`GetRecordedList` skips delete-pending rows. [source] Afterwards it may sit in the `Deleted`
recording group, which `IgnoreDeleted=true` filters out.
`POST /Dvr/UnDeleteRecording` exists; not used in v1.

**Seen on basement** (M5-1, 2026-11-16, deletes from the app on the Apple TV with
`AllowRerecord=false` for 3749): the reply is `{"bool": true}`, and the recording leaves
`GetRecordedList` (`IgnoreDeleted=true`) at once. `DELETEPENDING` never appeared: this backend
moves a deleted recording to the **`Deleted` recording group** with `AUTOEXP` added to
`ProgramFlagNames`, and `GetRecorded` still returns it there (`RecGroup: "Deleted"`). The file
stays until auto-expiry removes it, so mythfrontend can still undelete it. The `Deleted` group is
the "auto-expire instead of delete" behaviour; a backend with it off deletes the file and may show
`DELETEPENDING` meanwhile [source]. `FakeRecordingsService` models the second case; the app only
relies on the recording leaving the list, which both cases share. `Myth/GetSetting` returned an
empty string for `AutoExpireInsteadOfDelete` and `DeletedMaxAge`, so how long basement keeps the
`Deleted` group was not read.

## Playback state

Use `OffsetType=Duration` (offsets in **milliseconds** from the start of the file) everywhere
except clearing, below.

| Call | Parameters | Result |
| --- | --- | --- |
| `GET /Dvr/GetLastPlayPos` [live] | `RecordedId`, `OffsetType=Duration` | `{"long": "<ms>"}` (seen `"0"` and `"581614"`); `"0"` means none → nil. `"-1"` when the stored position cannot be converted to a duration (no seek table) [source] → nil |
| `GET /Dvr/GetSavedBookmark` [live] | same | same (including `"-1"`) [source] |
| `POST /Dvr/SetLastPlayPos` [live write] | `RecordedId`, `OffsetType=Duration`, `Offset=<ms>` | `{"bool": true}`; sets `LASTPLAYPOS` |
| `POST /Dvr/SetSavedBookmark` [live write] | same | `{"bool": true}`; sets `BOOKMARK` |

The adapter sends whole milliseconds, truncated; a position under 1 ms clears, and a negative
one is rejected by the adapter without a request.

- The backend converts the duration to a keyframe using the recording's seek table and returns
  `false` if that lookup fails (for example no seek table). [source] Map `false` to `.rejected`;
  `PlaybackSession` treats a failed save as non-fatal.
- A negative `Offset` raises a service exception (HTTP 400). [source]
- **Clearing: the adapter sends `OffsetType=Frame&Offset=0`.** Any offset type other than
  `Position` or `Duration` is taken as a raw frame number, and saving frame 0 removes the mark and
  clears the `LASTPLAYPOS` / `BOOKMARK` flag. [source, live write] `OffsetType=Duration&Offset=0`
  is not used: the backend first maps 0 ms to a keyframe (the last seek-table entry at or before
  0 ms, else the **first one after it**) and saves that frame, so on a recording whose seek table
  has no entry at 0 ms it stores a small position instead of clearing. [source] On recording 3749
  it did clear, because that table has an entry at 0. [live write] Both forms reply `{"bool": true}`.
- Writing 600000 ms read back as 598698 ms (the keyframe at or before it), for both calls, and
  mythfrontend offered to resume at 9:58 on the same recording. [live write]
- A value read back can differ slightly from the value written because of the keyframe
  round trip. Tests must not assert exact equality against a live backend.

## Commercial breaks

`GET /Dvr/GetRecordedCommBreak?RecordedId=<id>&OffsetType=Duration` [live]

```json
{"CutList": {"Cuttings": [{"Mark": 4, "Offset": 700266}, {"Mark": 5, "Offset": 880279}]}}
```

- `Mark` 4 = commercial start, 5 = commercial end; `Offset` in ms (a JSON number here). A
  break may start at offset 0 (fixture `commbreak.json`). [live]
- Do **not** send `IncludeFps=true`; it prepends an extra entry `{"Mark": 32, "Offset": 29970}`
  (frame rate × 1000). If any entry with a mark other than 4 or 5 appears, ignore it. [live]
- An unknown id or an unflagged recording returns an empty list with HTTP 200. [live]
- Pairing rules for the adapter (the list is not guaranteed balanced):
  - sort by offset;
  - a start followed by an end makes a break;
  - a start followed by another start: keep the first, drop the second;
  - an end with no open start: treat the start as 0 only if it is the first mark, otherwise drop it;
  - a trailing start with no end: drop it;
  - drop breaks shorter than 5 s; then pass through `CommercialSkipper.normalise`.
  - "first mark" means the first mark 4 or 5 after sorting (mark 32 and entries without a mark or offset do not count); at equal offsets an end sorts before a start.
  - `MythBackendV35` may not import `MythwatchPlayback`, so `V35MarkupService` applies an equivalent private normalise (sort, drop empty, merge overlapping **and touching** ranges). M4-1 must keep `CommercialSkipper.normalise` consistent with that.
- `GET /Dvr/GetRecordedCutList` has the same shape (marks 1 = cut start, 0 = cut end). Not used in v1.
- 304 of 307 recordings on the reference backend carry the `COMMFLAG` flag.

## Media URLs (built by `MediaLocator`, never fetched by the adapter)

| Purpose | URL | Notes |
| --- | --- | --- |
| Stream | `/Content/GetRecording?RecordedId=<id>` | Honours `Range` (HTTP 206, `Accept-Ranges: bytes`), `Content-Type: video/mp2t`. [live] |
| Artwork | `<ArtworkReference.locator>&Width=<w>` | `/Content/GetImageFile` scales. [live] A 680×1000 cover returned 214 KB unscaled and, with `Width=120`, a 119×176 JPEG of 4.8 KB: aspect kept, height derived, width may come out a pixel under the request. Scaled copies are JPEG at quality 60. **Side effect:** the first request for a size writes `<original>.<W>x<H>.jpg` next to the original on the backend and serves it from there afterwards [source], so `MediaLocator` must use a small fixed set of widths, not arbitrary view sizes. `V35MediaLocator` rounds a requested width up to one of **160, 320, 640, 1280** (the largest for anything bigger, the smallest for 0 or negative). |
| Preview frame | `/Content/GetPreviewImage?RecordedId=<id>&Width=<w>` | 200 with an image. [live] Used when a recording has no poster. |

All are resolved against `BackendConnection.baseURL`. Percent-encoding already present in a
locator must be preserved, not double-encoded. A locator that is not a server-relative path (no leading `/`, a leading `//`, whitespace or non-ASCII) gives no artwork URL.

## Discovery

The backend advertises Bonjour service type `_mythbackend._tcp` (`mediaserver.cpp`). [source]
Seen on basement on 2026-11-16 with `dns-sd -B` / `-L` (mDNS only, nothing sent to the API): [live]

| Field | Value | Meaning |
| --- | --- | --- |
| Instance name | `Mythbackend on basement` | `"Mythbackend on " + ` the MythTV host name [source] |
| Host target | `basement.local.` | mDNS name of the machine; resolves to 192.168.1.50 and an IPv6 ULA |
| Port | **6550** | The UPnP server, at `BackendStatusPort + 6` (since v34, commit `dd35e85329`, 2023-07-20; before v34 it was the status port itself). The services API is on the status port, so **API port = advertised port − 6** (6544). |
| TXT | one string, `master` | `master` or `slave`, from whether this backend is the master [source] |

The backend's web server separately registers a generic `_http._tcp` instance (`mythbackend on
basement`, port 6544; `mythhttpserver.cpp`). It is not used: mythfrontend registers the same
kind of record (`mythfrontend on <host>`), so only the name tells them apart.

Mythwatch browses `_mythbackend._tcp` only, resolves each instance, skips a `slave`, and offers
`http://<host target without the dot>:<port − 6>` (SPEC 6.3 "Bonjour discovery"). The port rule
lives in `MythBackendAdvertisement` in `MythwatchFeatures`, not in this adapter, because discovery
runs before the backend's version is known. A later adapter for a backend older than v34 would
need the offset to be 0, which discovery cannot tell from the advertisement; the probe then reports
the address as unreachable and the user types it.

## Errors in the adapter

Every read goes through one helper (`V35Client`): `Accept: application/json`; HTTP 400 → `.rejected(<text of the HTML body, or "HTTP 400">)`; any other non-2xx → `.http(status, <text of the body or nil>)` (the 404 page gives `"404 Not Found"`); an undecodable or wrong-shaped 2xx body → `.malformedResponse`; transport errors pass through unchanged.

## Capabilities reported by the v35 adapter

`.recordings`, `.resumePosition`, `.bookmarks`, `.commercialBreaks`, `.deleteRecording`.
Every write capability is implemented: watched (under `.recordings`), `.resumePosition` and `.bookmarks` as of M3-5, `.deleteRecording` as of M5-1. `liveTV` and `videoLibrary` are nil.
`supports(version)` is true for `major == 35` only.

## Known differences in later versions (for whoever writes the next adapter)

Comparing `fixes/35` with `master` (v37-Pre): `Myth/LoginUser` and `Myth/GetUsers` are added;
the HLS `Content/*LiveStream` calls are removed; `Dvr/GetRecordedList` and `Dvr/GetRecGroupList`
gain parameters; `Video/*` signatures change. Run
`git diff origin/fixes/35 master -- mythtv/programs/mythbackend/servicesv2` in the MythTV checkout.

## Fixtures

`Tools/capture-fixtures.sh <base-url> <out-dir>` performs only plain GETs (with
`Accept: application/json`) and writes the raw files below, plus `capture-log.txt` (each request,
its status and content type, and the ids chosen). It picks ids from the two list pages, never
hard-coded ones. Write the raw output outside the repository; it is never committed.

| File | Source |
| --- | --- |
| `backend-info.json` | `/Myth/GetBackendInfo` |
| `hostname.json` | `/Myth/GetHostName` |
| `recorded-list-page1.json`, `-page2.json` | `/Dvr/GetRecordedList` with `Count=4`, two pages. The script deliberately keeps `Sort=starttime`, so these are the **oldest** recordings: they change less often than the newest, which keeps re-captures comparable |
| `recorded-one.json` | `/Dvr/GetRecorded` for the first listed id |
| `recorded-missing.json` | `/Dvr/GetRecorded?RecordedId=99999999` |
| `commbreak.json` | `/Dvr/GetRecordedCommBreak` for the first listed `COMMFLAG` recording with breaks |
| `commbreak-empty.json` | the same for a listed recording without `COMMFLAG`, else for id 99999999 |
| `lastplaypos-zero.json` | `/Dvr/GetLastPlayPos` for a listed recording without `LASTPLAYPOS` |
| `lastplaypos-set.json` | the same for one with `LASTPLAYPOS`, when the pages contain one |
| `not-found.html` | `/Dvr/NoSuchMethod` (status 404) |

Before committing: replace the backend's host name everywhere with `backend` (including the
`myth://<group>@<host>/` artwork file names), drop the `Env` and `Log` objects from
`backend-info.json`, remove `Cast`, and check for IP or MAC addresses, file-system paths, user
names and e-mail addresses. Edit as text, not by re-serialising, so formatting and number
formats stay as captured. Then hand-edit copies to cover cases the capture may miss: null
`Airdate`, null `Artwork`, empty `SubTitle`, `Season` 0, a `LASTPLAYPOS|WATCHED|BOOKMARK` row, a
`DELETEPENDING` row, a `DAMAGED` row, a `movie`, an unbalanced commercial-break list, and
`{"bool": true}` / `{"bool": "true"}` scalar variants. The fixtures directory's `README.md`
records, for every file, whether it was captured or hand-edited and from what.
