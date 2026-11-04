#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p '../Duck Island.app/Contents/Resources' '../Duck Island.app/Contents/MacOS'
cp Info.plist '../Duck Island.app/Contents/Info.plist'
cp Assets/*.png '../Duck Island.app/Contents/Resources/'
swiftc main.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift ReviewModel.swift ReviewPanels.swift ReviewExport.swift SelfTests.swift -o '../Duck Island.app/Contents/MacOS/DuckIsland' -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0
./sign-local.sh '../Duck Island.app'
'../Duck Island.app/Contents/MacOS/DuckIsland' --self-test
