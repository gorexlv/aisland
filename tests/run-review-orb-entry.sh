#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../outputs/DuckIsland"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
DEST=${1:-/tmp/aisland-review-controls}
mkdir -p "$DEST"
python3 - "$OUT/main.swift" <<'PY'
import pathlib,sys
s=pathlib.Path('main.swift').read_text().split('#if APP_STORE && !DEBUG\nlet app =')[0]
pathlib.Path(sys.argv[1]).write_text(s+pathlib.Path('../../tests/review-orb-entry.swift').read_text())
PY
cp Assets/*.png "$OUT/"
swiftc "$OUT/main.swift" RecentRecords.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift MoLive.swift ReviewModel.swift ReviewPanels.swift ReviewOrbit.swift Launcher.swift WindowOCR.swift ReviewExport.swift SelfTests.swift -o "$OUT/render" -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0
"$OUT/render" "$DEST"
