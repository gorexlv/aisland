#!/bin/bash
# Isolated fixtures only: never runs the app, Notes, AI, recording, or signing.
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
for mode in local store; do
  flags=(-D LOCAL_BUILD)
  if [[ "$mode" == store ]]; then flags=(-D APP_STORE); fi
  swiftc "${flags[@]}" -parse-as-library NotesExport.swift MeetingAnalysis.swift Tests/SaveReliabilityTests.swift -framework Cocoa -o "$build_dir/tests-$mode"
  "$build_dir/tests-$mode"
  swiftc "${flags[@]}" main.swift RecentRecords.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift ReviewModel.swift ReviewPanels.swift ReviewExport.swift SelfTests.swift -o "$build_dir/DuckIsland-$mode" -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0
  echo "PASS: unsigned $mode build"
done
swiftc -D APP_STORE AppStore/Helper/main.swift NotesExport.swift MeetingAnalysis.swift -framework Cocoa -o "$build_dir/NotesHelper"
echo 'PASS: unsigned NotesHelper build'
