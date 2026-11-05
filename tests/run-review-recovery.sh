#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc tests/review-recovery.swift outputs/DuckIsland/ReviewModel.swift outputs/DuckIsland/ReviewExport.swift outputs/DuckIsland/ReviewPanels.swift outputs/DuckIsland/RecentRecords.swift outputs/DuckIsland/VoiceInput.swift outputs/DuckIsland/ScreenWindows.swift -o "$OUT/review-tests" -target arm64-apple-macosx15.0
"$OUT/review-tests"
