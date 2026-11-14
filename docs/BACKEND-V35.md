# MythTV v35 services API: wire contract for `MythBackendV35`

Source of truth: the MythTV source at `../mythtv` on branch `fixes/35`, directory
`mythtv/programs/mythbackend/servicesv2/` (`v2dvr.h/.cpp`, `v2content.h/.cpp`, `v2myth.h/.cpp`)
and `mythtv/libs/libmythbase/http/`. Read those files when this document is silent.

Each statement below is marked:

- **[live]** observed on a real v35.0 backend with a read-only call on 2026-11-14.
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
  A `long` arrives as a **string**. [live for String and long; bool is [verify]] Decode bool and
  numeric scalars leniently: accept a JSON bool/number or a string holding one.
- Timestamps are ISO 8601 UTC with `Z`, no fractional seconds: `2026-11-14T20:30:00Z`. [live]
- Errors:
  - Unknown method: HTTP 404 with an **HTML** body. [live]
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

`GET /Myth/GetHostName` returns `{"String": "<host>"}`. [live]

## Recordings

### `GET /Dvr/GetRecordedList` [live]

Parameters used: `Descending=true`, `StartIndex`, `Count`, `Sort=starttime`,
`IgnoreLiveTV=true`, `IgnoreDeleted=true`, `IncCast=false`, `IncChannel=true`,
`IncArtWork=true`, `IncRecording=true`. Other parameters exist (`TitleRegEx`, `RecGroup`,
`StorageGroup`, `Category`, `Details`); see `v2dvr.h`.

`IncCast=false` and `IncChannel=false` were sent on one live call and the response still
contained `Cast` and `Channel`. Treat both as hints the backend may ignore. [live]

Paging: request pages of 200 until `StartIndex + Count >= TotalAvailable`. The reference backend
has 307 recordings across 37 titles.

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
| `Airdate` | string or **null** | `originalAirDate` | `yyyy-MM-dd`; null and `""` become nil |
| `Inetref` | string | `seriesKey` | e.g. `ttvdb4.py_78193`; `""` becomes nil (4 of 307) |
| `StartTime`, `EndTime` | timestamp | `scheduledStart/End` | the programme's listing times |
| `LastModified` | timestamp | `lastModified` | |
| `FileSize` | int | `fileSize` | bytes; exceeds 32 bits |
| `ProgramFlagNames` | string | `flags` | `|`-separated names, or `NONE`. See below |
| `VideoPropNames` | string | `video`, `flags.damaged` | `|`-separated: `WIDESCREEN`, `HDTV`, `MPEG2`, `1080`, `720`, `DAMAGED`, `UNKNOWN` |
| `Channel` | object | `channel` | `ChanNum`, `CallSign`, `ChannelName`; may be absent |
| `Recording` | object | see below | |
| `Artwork` | object or **null** | `artwork` | `{"ArtworkInfos": [{"URL","FileName","StorageGroup","Type"}]}` |
| `Cast` | object | ignored in v1 | |

Parse flags from the **names**, never from the numeric `ProgramFlags`: bit values can change
between versions. Names seen or defined in `libs/libmythbase/programtypeflags.h`:

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

### `GET /Dvr/GetRecorded?RecordedId=<id>` [live]

Returns `{"Program": {...}}` with the same shape. **An unknown id returns HTTP 200 with a blank
programme** (`"Title": null`, `"FileName": null`, zeroed numbers). The adapter must map that to
`BackendError.notFound`: treat `Title == null` or a missing/zero `Recording.RecordedId` as not found.

### `POST /Dvr/UpdateRecordedWatchedStatus` [source]

Form fields `RecordedId`, `Watched=true|false`. Returns `{"bool": true}`; `false` when the
recording does not exist → `BackendError.rejected`.

### `POST /Dvr/DeleteRecording` [source]

Form fields `RecordedId`, `ForceDelete=false`, `AllowRerecord=<bool>`. Returns `{"bool": true}`
when the delete was **queued**; deletion is asynchronous. `false` → `.rejected`. Until it
completes the recording can still appear in lists with the `DELETEPENDING` flag, and afterwards
may sit in the `Deleted` recording group, which `IgnoreDeleted=true` filters out.
`POST /Dvr/UnDeleteRecording` exists; not used in v1.

## Playback state

Use `OffsetType=Duration` everywhere: offsets are **milliseconds** from the start of the file.

| Call | Parameters | Result |
| --- | --- | --- |
| `GET /Dvr/GetLastPlayPos` [live] | `RecordedId`, `OffsetType=Duration` | `{"long": "<ms>"}`; `"0"` means none → nil |
| `GET /Dvr/GetSavedBookmark` [live] | same | same |
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

- `Mark` 4 = commercial start, 5 = commercial end; `Offset` in ms (a JSON number here).
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
- `GET /Dvr/GetRecordedCutList` has the same shape (marks 1 = cut start, 0 = cut end). Not used in v1.
- 304 of 307 recordings on the reference backend carry the `COMMFLAG` flag.

## Media URLs (built by `MediaLocator`, never fetched by the adapter)

| Purpose | URL | Notes |
| --- | --- | --- |
| Stream | `/Content/GetRecording?RecordedId=<id>` | Honours `Range` (HTTP 206, `Accept-Ranges: bytes`), `Content-Type: video/mp2t`. [live] |
| Artwork | `<ArtworkReference.locator>&Width=<w>` | `/Content/GetImageFile` accepts `Width`/`Height`. [verify] If it does not scale, omit the parameter. |
| Preview frame | `/Content/GetPreviewImage?RecordedId=<id>&Width=<w>` | 200 with an image. [live] Used when a recording has no poster. |

All are resolved against `BackendConnection.baseURL`. Percent-encoding already present in a
locator must be preserved, not double-encoded.

## Discovery

The backend advertises Bonjour service type `_mythbackend._tcp` (`mediaserver.cpp`). [source]
The advertised port and TXT record contents are [verify] in task M5-2.

## Capabilities reported by the v35 adapter

`.recordings`, `.resumePosition`, `.bookmarks`, `.commercialBreaks`, `.deleteRecording`.
`supports(version)` is true for `major == 35` only.

## Known differences in later versions (for whoever writes the next adapter)

Comparing `fixes/35` with `master` (v37-Pre): `Myth/LoginUser` and `Myth/GetUsers` are added;
the HLS `Content/*LiveStream` calls are removed; `Dvr/GetRecordedList` and `Dvr/GetRecGroupList`
gain parameters; `Video/*` signatures change. Run
`git diff origin/fixes/35 master -- mythtv/programs/mythbackend/servicesv2` in the MythTV checkout.

## Fixtures

`Tools/capture-fixtures.sh <base-url> <out-dir>` performs only GETs and writes:

| File | Source |
| --- | --- |
| `backend-info.json` | `/Myth/GetBackendInfo` |
| `recorded-list-page1.json`, `-page2.json` | `/Dvr/GetRecordedList` with `Count=4`, two pages |
| `recorded-one.json` | `/Dvr/GetRecorded` for a real id |
| `recorded-missing.json` | `/Dvr/GetRecorded?RecordedId=99999999` |
| `commbreak.json`, `commbreak-empty.json` | `/Dvr/GetRecordedCommBreak` |
| `lastplaypos-zero.json` | `/Dvr/GetLastPlayPos` |
| `not-found.html` | `/Dvr/NoSuchMethod` (status 404) |

Before committing: replace the backend's host name everywhere with `backend`, drop the `Env`
and `Log` objects from `backend-info.json`, and remove `Cast`. Then hand-edit copies to cover
cases the capture may miss: null `Airdate`, null `Artwork`, empty `SubTitle`, `Season` 0, a
`LASTPLAYPOS|WATCHED|BOOKMARK` row, a `DELETEPENDING` row, a `DAMAGED` row, a `movie`, an
unbalanced commercial-break list, and `{"bool": true}` / `{"bool": "true"}` scalar variants.
