#!/bin/bash
# Direct distribution only. Never invoke build.sh/sign-local.sh or launch the app.
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: build.sh NEW_OUTPUT_DIRECTORY TAG}
tag=${2:?Missing tag}
python3 scripts/ci/version.py "$tag" >/dev/null
[[ $(uname -m) == arm64 ]] || { echo 'arm64 host required' >&2; exit 1; }
mkdir "$destination"
destination=$(cd "$destination" && pwd)
app="$destination/Duck Island.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp outputs/DuckIsland/Info.plist "$app/Contents/Info.plist"
cp outputs/DuckIsland/Assets/*.png "$app/Contents/Resources/"
python3 - "$app" "$tag" <<'PY'
import json, pathlib, plistlib, subprocess, sys
sys.path.insert(0, 'scripts/ci')
from version import parse_tag
app = pathlib.Path(sys.argv[1])
metadata = parse_tag(sys.argv[2])
metadata.update(commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                signing='ad-hoc', notarized=False,
                toolchain=subprocess.check_output(['xcodebuild', '-version'], text=True).strip())
path = app / 'Contents/Info.plist'
with path.open('rb') as stream:
    plist = plistlib.load(stream)
plist.update(CFBundleShortVersionString=metadata['version'], CFBundleVersion=metadata['version'],
             DuckIslandReleaseTag=metadata['tag'], DuckIslandCommit=metadata['commit'])
with path.open('wb') as stream:
    plistlib.dump(plist, stream)
(app / 'Contents/Resources/build-info.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
(
  cd outputs/DuckIsland
  xcrun swiftc -O main.swift RecentRecords.swift MeetingCapture.swift MeetingRecognition.swift \
    NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift \
    VoiceInput.swift MoLive.swift ReviewModel.swift ReviewPanels.swift ReviewOrbit.swift ReviewExport.swift SelfTests.swift \
    -o "$app/Contents/MacOS/DuckIsland" -framework Cocoa -framework SwiftUI -framework Speech \
    -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0
)
[[ $(lipo -archs "$app/Contents/MacOS/DuckIsland") == arm64 ]]
# The linker may add an ad-hoc signature to arm64 Mach-O; apply bundle signature only at packaging.
echo "Built without certificate signing: $app"
