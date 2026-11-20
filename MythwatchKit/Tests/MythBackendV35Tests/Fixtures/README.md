# v35 fixtures

Captured from a real MythTV v35.0 backend on 2026-11-14 with
`Tools/capture-fixtures.sh <base-url> <out_dir>` (GET requests only), then sanitised. The raw
capture is never committed. Wire contract: `docs/BACKEND-V35.md`.

## Sanitising applied to every captured file

Text-level edits only, so formatting, key order, `\/` escaping and number formats (`0.000000`)
stay exactly as the backend sent them.

- The backend's host name is replaced with `backend` everywhere (`HostName` fields,
  `/Myth/GetHostName`, and the host in `myth://Coverart@<host>/...` artwork file names).
- `backend-info.json`: the `Env` object (home directory, user name, web root, locale) and the
  `Log` object are removed; `Build` is verbatim.
- `Cast` is removed from every programme. As captured it was `"Cast": null` in the list pages
  (sent with `IncCast=false`) and `"Cast": {"CastMembers": []}` in both `GetRecorded` replies.
- Before the repository went public (2026-11-19), every identifying value was swapped for an
  invented one, in these files and in the git history: programme titles, subtitles and
  descriptions, channel names, call signs and numbers, `XMLTVID` values, channel icon names,
  `Inetref` values and `ProgramId`/`SeriesId`. Titles keep their alphabetical order, and
  escaping, JSON shapes, ids, times and numbers are unchanged.

## Files

| File | Kind | Source |
| --- | --- | --- |
| `backend-info.json` | captured | `GET /Myth/GetBackendInfo` |
| `hostname.json` | captured | `GET /Myth/GetHostName` |
| `recorded-list-page1.json` | captured | `GET /Dvr/GetRecordedList?StartIndex=0&Count=4&Descending=true&Sort=starttime&IgnoreLiveTV=true&IgnoreDeleted=true&IncCast=false&IncChannel=true&IncArtWork=true&IncRecording=true`. Because `Sort` overrides `Descending`, these are the **oldest** recordings (see BACKEND-V35). Rows 2 and 4 are movies (`CatType` `movie`, `SubTitle` `""`, `Season`/`Episode` 0, `Airdate` `yyyy-01-01`, `"Artwork": {"ArtworkInfos": []}`) |
| `recorded-list-page2.json` | captured | same, `StartIndex=4`. Row 3 has `LASTPLAYPOS`; row 4 has `"ArtworkInfos": []` |
| `recorded-one.json` | captured | `GET /Dvr/GetRecorded?RecordedId=<first id of page 1>` |
| `recorded-missing.json` | captured | `GET /Dvr/GetRecorded?RecordedId=99999999` (HTTP 200, blank programme, `"Recording": null`) |
| `commbreak.json` | captured | `GET /Dvr/GetRecordedCommBreak?RecordedId=<first id of page 1>&OffsetType=Duration`; first break starts at offset 0 |
| `commbreak-empty.json` | captured | `GET /Dvr/GetRecordedCommBreak?RecordedId=99999999&OffsetType=Duration`. Every listed recording was commercial-flagged, so this uses the unknown id; an unflagged recording returns the same shape [source] |
| `lastplaypos-zero.json` | captured | `GET /Dvr/GetLastPlayPos?RecordedId=<first id of page 1>&OffsetType=Duration` → `{"long": "0"}` |
| `lastplaypos-set.json` | captured | `GET /Dvr/GetLastPlayPos?RecordedId=<page 2 row 3, flagged LASTPLAYPOS>&OffsetType=Duration` → `{"long": "581614"}` |
| `not-found.html` | captured | `GET /Dvr/NoSuchMethod`, HTTP 404, `Content-Type: text/html` |
| `recorded-one-airdate-null.json` | hand-edited from `recorded-one.json` | `Airdate` → `null` |
| `recorded-one-artwork-null.json` | hand-edited from `recorded-one.json` | `Artwork` → `null` |
| `recorded-one-resume-watched-bookmark.json` | hand-edited from `recorded-one.json` | `ProgramFlags` 1 → 262673, `ProgramFlagNames` → `COMMFLAG\|BOOKMARK\|WATCHED\|LASTPLAYPOS` (names in bit order, as the backend writes them) |
| `recorded-one-deletepending.json` | hand-edited from `recorded-one.json` | `ProgramFlags` 1 → 129, `ProgramFlagNames` → `COMMFLAG\|DELETEPENDING`. `GetRecordedList` never returns such a row; `GetRecorded` can [source] |
| `recorded-one-damaged.json` | hand-edited from `recorded-one.json` | `VideoProps` 71 → 1095, `VideoPropNames` → `WIDESCREEN\|HDTV\|MPEG2\|1080\|DAMAGED` |
| `commbreak-unbalanced.json` | hand-edited from `commbreak.json` | Marks (offset ms): end 156990 (first mark, no start → break from 0), end 1000000 (no open start, not first → dropped), start 3183681, start 3300000 (second start → dropped), end 3526990, start 3600000 (trailing → dropped). Expected breaks under the BACKEND-V35 pairing rules: 0–156990 and 3183681–3526990 |
| `bool-true.json` | hand-written | `{"bool": true}`: the shape the v35 JSON serialiser writes for a `bool` result [source]. No read-only GET in v35 returns a bool, so it could not be captured |
| `bool-true-string.json` | hand-written | `{"bool": "true"}`: the lenient variant the decoder must also accept |

Cases from BACKEND-V35 "Fixtures" covered by the capture itself, so not hand-edited: empty
`SubTitle`, `Season` 0, a `movie` (page 1 rows 2 and 4).

`FixtureSetTests` checks that this directory holds exactly these files, that every `.json` file
parses, and that no file contains the real host name. Update its list and this table together.
