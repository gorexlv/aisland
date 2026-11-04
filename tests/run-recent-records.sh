#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
for mode in LOCAL_BUILD APP_STORE; do
 swiftc -D "$mode" -parse-as-library tests/recent-records.swift outputs/DuckIsland/RecentRecords.swift outputs/DuckIsland/NotesExport.swift outputs/DuckIsland/MeetingAnalysis.swift -framework Cocoa -framework SwiftUI -o "$OUT/tests"
 "$OUT/tests"
done
