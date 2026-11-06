#!/bin/bash
# Offline fixtures; strip only application entry point, retaining actual Recorder code.
set -euo pipefail
cd "$(dirname "$0")/../.."
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PY'
import pathlib,sys
source=pathlib.Path('main.swift').read_text().split('#if APP_STORE && !DEBUG')[0]
pathlib.Path(sys.argv[1]).write_text(source+'\n'+pathlib.Path('Tests/workflow/checks.swift').read_text())
PY
swiftc "$build_dir/main.swift" RecentRecords.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift MoLive.swift ReviewModel.swift ReviewPanels.swift ReviewOrbit.swift Launcher.swift WindowOCR.swift LarkProxy.swift GameCompanion.swift Settings.swift ReviewExport.swift SelfTests.swift -o "$build_dir/checks" -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0
"$build_dir/checks"
