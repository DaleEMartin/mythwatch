#!/bin/bash
# Captures raw v35 fixtures from a live MythTV backend. See docs/BACKEND-V35.md, "Fixtures".
#
# Usage: Tools/capture-fixtures.sh <base-url> <out_dir>
#        e.g. Tools/capture-fixtures.sh http://mybackend:6544 /tmp/mythwatch-raw
#
# Safety: the backend is someone's working DVR. This script sends only plain GET requests to
# read-only methods (curl's default method, no request body). It never writes, schedules or
# deletes anything. Keep it that way: do not add request bodies, method overrides or calls to
# methods that are not read-only GETs in the v35 services source.
#
# Output is RAW: it contains the backend's host name, environment and what the owner records.
# Write it outside the repository and sanitise before committing (see the fixtures README).
#
# Safe to re-run: every file is rewritten; nothing else in <out_dir> is touched.
# Requires: curl, jq.

set -euo pipefail

if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: $0 <base-url> <out_dir>" >&2
  echo "  e.g. $0 http://mybackend:6544 /tmp/mythwatch-raw" >&2
  exit 64
fi

base="${1%/}"
out="$2"

case "$base" in
  http://*|https://*) ;;
  *) echo "error: base URL must start with http:// or https:// (got '$base')" >&2; exit 64 ;;
esac
command -v curl >/dev/null || { echo "error: curl is required" >&2; exit 69; }
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 69; }

mkdir -p "$out"
log="$out/capture-log.txt"
: > "$log"

# get <file> <path-and-query> [expected-status]
# One plain GET. Body to <out>/<file>; status and content type to the log.
get() {
  local file="$1" path="$2" expected="${3:-200}" result status
  result=$(curl --silent --show-error --max-time 20 \
    --header 'Accept: application/json' \
    --output "$out/$file" \
    --write-out '%{http_code} %{content_type}' \
    "$base$path") || { echo "error: GET $path failed" >&2; exit 1; }
  status="${result%% *}"
  echo "GET $path -> $result ($file)" | tee -a "$log"
  if [ "$status" != "$expected" ]; then
    echo "error: GET $path returned $status, expected $expected" >&2
    exit 1
  fi
}

# Sort overrides Descending on v35, so this lists the OLDEST recordings first. Kept on purpose:
# old recordings change less often, so re-captures stay comparable. The adapter does not send Sort.
list_query='Descending=true&Sort=starttime&IgnoreLiveTV=true&IgnoreDeleted=true&IncCast=false&IncChannel=true&IncArtWork=true&IncRecording=true'

get backend-info.json      "/Myth/GetBackendInfo"
get hostname.json          "/Myth/GetHostName"
get recorded-list-page1.json "/Dvr/GetRecordedList?StartIndex=0&Count=4&$list_query"
get recorded-list-page2.json "/Dvr/GetRecordedList?StartIndex=4&Count=4&$list_query"

# Candidate rows from both pages: "<RecordedId> <ProgramFlagNames>" per line.
rows=$(jq -r '.ProgramList.Programs[] | "\(.Recording.RecordedId) \(.ProgramFlagNames)"' \
  "$out/recorded-list-page1.json" "$out/recorded-list-page2.json")
[ -n "$rows" ] || { echo "error: the recording list is empty; nothing to capture" >&2; exit 1; }

has_flag() { case "|$2|" in *"|$1|"*) return 0 ;; *) return 1 ;; esac; }

first_line=$(echo "$rows" | head -1); first_id="${first_line%% *}"
get recorded-one.json      "/Dvr/GetRecorded?RecordedId=$first_id"
get recorded-missing.json  "/Dvr/GetRecorded?RecordedId=99999999"

# Commercial breaks: the first COMMFLAG recording whose list is not empty.
comm_id=""
while read -r id flags; do
  has_flag COMMFLAG "$flags" || continue
  get commbreak.json "/Dvr/GetRecordedCommBreak?RecordedId=$id&OffsetType=Duration"
  if [ "$(jq '.CutList.Cuttings | length' "$out/commbreak.json")" -gt 0 ]; then comm_id="$id"; break; fi
done <<< "$rows"
[ -n "$comm_id" ] || echo "warning: no listed recording has commercial breaks; commbreak.json is empty" | tee -a "$log"

# No commercial breaks: a listed recording without COMMFLAG, else the unknown id.
empty_id=$(echo "$rows" | while read -r id flags; do
  has_flag COMMFLAG "$flags" || { echo "$id"; break; }; done)
if [ -z "$empty_id" ]; then
  empty_id=99999999
  echo "note: every listed recording is commercial-flagged; commbreak-empty.json uses unknown id $empty_id" | tee -a "$log"
fi
get commbreak-empty.json   "/Dvr/GetRecordedCommBreak?RecordedId=$empty_id&OffsetType=Duration"

# Last-play position: a listed recording without LASTPLAYPOS (expected "0").
zero_id=$(echo "$rows" | while read -r id flags; do
  has_flag LASTPLAYPOS "$flags" || { echo "$id"; break; }; done)
if [ -n "$zero_id" ]; then
  get lastplaypos-zero.json "/Dvr/GetLastPlayPos?RecordedId=$zero_id&OffsetType=Duration"
else
  echo "warning: every listed recording has LASTPLAYPOS; lastplaypos-zero.json not written" | tee -a "$log"
fi

# Optional: a listed recording with LASTPLAYPOS (a non-zero position), when there is one.
set_id=$(echo "$rows" | while read -r id flags; do
  has_flag LASTPLAYPOS "$flags" && { echo "$id"; break; }; done || true)
if [ -n "$set_id" ]; then
  get lastplaypos-set.json "/Dvr/GetLastPlayPos?RecordedId=$set_id&OffsetType=Duration"
else
  echo "note: no listed recording has LASTPLAYPOS; lastplaypos-set.json not written" | tee -a "$log"
fi

get not-found.html         "/Dvr/NoSuchMethod" 404

echo "ids: one=$first_id commbreak=${comm_id:-none} empty=$empty_id lastplaypos-zero=${zero_id:-none} lastplaypos-set=${set_id:-none}" | tee -a "$log"
echo "Raw capture written to $out. Sanitise before committing." | tee -a "$log"
