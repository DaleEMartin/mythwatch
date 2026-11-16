#!/bin/bash
# Checks the target dependency rule in docs/SPEC.md §2 by scanning import statements.
#
# Package.swift alone does not enforce the rule: in a debug build SwiftPM lets a target import
# any module that happens to be built already and only prints a warning. This script is the
# enforcement. Keep the table below identical to SPEC §2.
#
# Usage: Tools/check-deps.sh        (exit 0 = clean, 1 = violation)

set -u
cd "$(dirname "$0")/../MythwatchKit/Sources" || exit 2

allowed() {
  case "$1" in
    MythwatchDomain)      echo "" ;;
    MythwatchBackend)     echo "MythwatchDomain" ;;
    MythBackendV35)       echo "MythwatchBackend MythwatchDomain" ;;
    MythwatchPlayback)    echo "MythwatchDomain" ;;
    MythwatchFeatures)    echo "MythwatchDomain MythwatchBackend MythwatchPlayback" ;;
    MythwatchTestSupport) echo "MythwatchDomain MythwatchBackend MythwatchPlayback MythwatchFeatures" ;;
    *) return 1 ;;
  esac
}

modules="MythwatchDomain MythwatchBackend MythBackendV35 MythwatchPlayback MythwatchFeatures MythwatchTestSupport"
status=0

for target in *; do
  [ -d "$target" ] || continue
  if ! ok=$(allowed "$target"); then
    echo "error: target '$target' is not in the SPEC §2 table (update the spec and this script)"
    status=1
    continue
  fi
  # Every "import X" / "import struct X.Y" line, with any attributes or access modifiers in front.
  while IFS=: read -r file line text; do
    module=$(echo "$text" | sed -E 's/.*import[[:space:]]+((struct|class|enum|protocol|typealias|func|let|var)[[:space:]]+)?([A-Za-z0-9_]+).*/\3/')
    case " $modules " in *" $module "*) ;; *) continue ;; esac   # not one of ours
    [ "$module" = "$target" ] && continue
    case " $ok " in
      *" $module "*) ;;
      *) echo "error: $file:$line: '$target' must not import '$module' (SPEC §2)"; status=1 ;;
    esac
  done < <(grep -rnE '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+|public[[:space:]]+|package[[:space:]]+|internal[[:space:]]+|fileprivate[[:space:]]+|private[[:space:]]+)*import[[:space:]]' --include='*.swift' "$target")
done

# The app target (SPEC §2 "App target" row). It may import MythwatchFeatures and the layers under
# it. Only the composition root (App/Composition.swift) may import MythBackendV35, and
# MythwatchTestSupport only there and only inside `#if DEBUG` (Release builds neither link nor
# contain it; SPEC §7 "UI tests"). Only VLCPlayerEngine.swift may import VLCKit. The UI tests
# import none of our modules.
app_dir="../../Mythwatch/Mythwatch"
composition="App/Composition.swift"
while IFS= read -r file; do
  rel=${file#"$app_dir/"}
  in_debug=0
  while IFS= read -r text; do
    case "$text" in
      "#if DEBUG") in_debug=1; continue ;;
      "#endif"*|"#else"*) in_debug=0; continue ;;
    esac
    echo "$text" | grep -qE '^[[:space:]]*((@[A-Za-z_]+|public|internal|private|fileprivate|package)[[:space:]]+)*import[[:space:]]' || continue
    module=$(echo "$text" | sed -E 's/.*import[[:space:]]+((struct|class|enum|protocol|typealias|func|let|var)[[:space:]]+)?([A-Za-z0-9_]+).*/\3/')
    case "$module" in
      MythwatchFeatures|MythwatchDomain|MythwatchBackend|MythwatchPlayback) ;;
      MythBackendV35)
        [ "$rel" = "$composition" ] || { echo "error: $rel: only $composition may import MythBackendV35 (SPEC §2)"; status=1; } ;;
      MythwatchTestSupport)
        if [ "$rel" != "$composition" ] || [ $in_debug -ne 1 ]; then
          echo "error: $rel: MythwatchTestSupport may only be imported inside #if DEBUG in $composition (SPEC §2, §7)"; status=1
        fi ;;
      TVVLCKit|MobileVLCKit)
        case "$rel" in */VLCPlayerEngine.swift|VLCPlayerEngine.swift) ;; *) echo "error: $rel: only VLCPlayerEngine.swift may import VLCKit (SPEC §7)"; status=1 ;; esac ;;
    esac
  done < "$file"
done < <(find "$app_dir" -name '*.swift')

if grep -rqE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+Myth' ../../Mythwatch/MythwatchUITests; then
  echo "error: the UI tests must not import Mythwatch modules; they drive the app (SPEC §7)"; status=1
fi

[ $status -eq 0 ] && echo "Dependency rule OK"
exit $status
