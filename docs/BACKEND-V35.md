# MythTV v35 services API: wire contract for `MythBackendV35`

Source of truth: the MythTV source at `../mythtv` on branch `fixes/35`, directory
`mythtv/programs/mythbackend/servicesv2/` (`v2dvr.h/.cpp`, `v2content.h/.cpp`, `v2myth.h/.cpp`)
and `mythtv/libs/libmythbase/http/`. Read those files when this document is silent.

Each statement below is marked:

- **[live]** observed on a real v35.0 backend with a read-only call on 2026-11-14 (the
  committed fixtures in `MythwatchKit/Tests/MythBackendV35Tests/Fixtures/` are from these calls).
- **[source]** read from the v35 source, not exercised live.
- **[verify]** an assumption; the task that depends on it must check it first.

No write call (POST) has been exercised live yet. Every write is [source] at best.

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
  other scalar type (including `long`) as a quoted string. [source] `{"bool": ...}` is
  **[verify]**: no read-only GET in v35 returns a bool (every bool-returning method is POST-only,
  or named `Set...`, which defaults to POST), so it cannot be observed without a write; settle it
  in the first task that performs a nominated write. Decode bool and numeric scalars leniently:
  accept a JSON bool/number or a string holding one.
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

### `POST /Dvr/UpdateRecordedWatchedStatus` [source]

**Not implemented until M3-5 / M5-1.** `V35RecordingsService.setWatched` sends no request and throws `BackendError.rejected("not implemented until M3-5 / M5-1")`. The same holds for every write below (`delete`, `setResumePosition`, `setBookmark`).

Form fields `RecordedId`, `Watched=true|false`. Returns `{"bool": true}`; `false` when the
recording does not exist → `BackendError.rejected`.

### `POST /Dvr/DeleteRecording` [source]

Form fields `RecordedId`, `ForceDelete=false`, `AllowRerecord=<bool>`. Returns `{"bool": true}`
when the delete was **queued**; deletion is asynchronous. `false` → `.rejected`. Until it
completes, `GetRecorded` can still return the recording with the `DELETEPENDING` flag;
`GetRecordedList` skips delete-pending rows. [source] Afterwards it may sit in the `Deleted`
recording group, which `IgnoreDeleted=true` filters out.
`POST /Dvr/UnDeleteRecording` exists; not used in v1.

## Playback state

Use `OffsetType=Duration` everywhere: offsets are **milliseconds** from the start of the file.

| Call | Parameters | Result |
| --- | --- | --- |
| `GET /Dvr/GetLastPlayPos` [live] | `RecordedId`, `OffsetType=Duration` | `{"long": "<ms>"}` (seen `"0"` and `"581614"`); `"0"` means none → nil. `"-1"` when the stored position cannot be converted to a duration (no seek table) [source] → nil |
| `GET /Dvr/GetSavedBookmark` [live] | same | same (including `"-1"`) [source] |
| `POST /Dvr/SetLastPlayPos` [source] | `RecordedId`, `OffsetType=Duration`, `Offset=<ms>` | `{"bool": ...}` |
| `POST /Dvr/SetSavedBookmark` [source] | same | same |

- The backend converts the duration to a keyframe using the recording's seek table and returns
  `false` if that lookup fails (for example no seek table). [source] Map `false` to `.rejected`;
  `PlaybackSession` treats a failed save as non-fatal.
- A negative `Offset` raises a service exception (HTTP 400). [source]
- Clearing: send `Offset=0`. [verify] that this removes the mark and clears the
  `LASTPLAYPOS` / `BOOKMARK` flag; if it does not, find the clearing call in `v2dvr.cpp`
  (`UpdateRecordedMetadata` is the newer combined call) and update this document.
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
The advertised port and TXT record contents are [verify] in task M5-2.

## Errors in the adapter

Every read goes through one helper (`V35Client`): `Accept: application/json`; HTTP 400 → `.rejected(<text of the HTML body, or "HTTP 400">)`; any other non-2xx → `.http(status, <text of the body or nil>)` (the 404 page gives `"404 Not Found"`); an undecodable or wrong-shaped 2xx body → `.malformedResponse`; transport errors pass through unchanged.

## Capabilities reported by the v35 adapter

`.recordings`, `.resumePosition`, `.bookmarks`, `.commercialBreaks`, `.deleteRecording`.
The adapter advertises `.deleteRecording` although `delete` is a stub until M3-5 (listed as the document says; see the status note on the write endpoints). `liveTV` and `videoLibrary` are nil.
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
