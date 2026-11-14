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

[ $status -eq 0 ] && echo "Dependency rule OK"
exit $status
