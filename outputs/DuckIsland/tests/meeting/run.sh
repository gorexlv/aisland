#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc MeetingRecognition.swift MeetingCapture.swift tests/meeting/main.swift -o "$test_dir/meeting-tests" \
  -framework Cocoa -framework Speech -framework AVFoundation -framework ScreenCaptureKit -target arm64-apple-macosx15.0
"$test_dir/meeting-tests"
