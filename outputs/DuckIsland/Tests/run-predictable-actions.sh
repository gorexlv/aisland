#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
# Compile the actual production types, replacing only the application's launch entry.
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('main.swift').read_text()
Path(sys.argv[1]).write_text(source.split('#if APP_STORE && !DEBUG\nlet app =')[0] + Path('Tests/PredictableActions.swift').read_text())
PY
swiftc "$test_dir/main.swift" RecentRecords.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift MoLive.swift ReviewModel.swift ReviewPanels.swift ReviewOrbit.swift Launcher.swift WindowOCR.swift LarkProxy.swift GameCompanion.swift Settings.swift ReviewExport.swift SelfTests.swift -o "$test_dir/checks" -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0
"$test_dir/checks"
