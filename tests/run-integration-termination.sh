#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
# Compile the production app types without running the top-level app/service CLI.
python3 - "$OUT/AppTypes.swift" <<'PY'
import sys
s = open('outputs/DuckIsland/main.swift').read()
marker = '\n#if APP_STORE && !DEBUG\nlet app ='
assert s.count(marker) == 1
open(sys.argv[1], 'w').write(s.split(marker)[0])
PY
cd outputs/DuckIsland
swiftc -D APP_STORE -parse-as-library "$OUT/AppTypes.swift" ../../tests/integration-termination.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift ReviewModel.swift ReviewPanels.swift ReviewExport.swift SelfTests.swift -o "$OUT/tests" -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0
"$OUT/tests"
