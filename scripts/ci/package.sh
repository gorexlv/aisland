#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: package.sh BUILD_DIRECTORY TAG}
tag=${2:?Missing tag}
python3 scripts/ci/version.py "$tag" >/dev/null
destination=$(cd "$destination" && pwd)
app="$destination/Duck Island.app"
archive="Duck-Island-$tag-macos-arm64.zip"
[[ ! -e "$destination/$archive" ]] || { echo 'Refusing to overwrite archive' >&2; exit 1; }
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$destination/$archive"
(
  cd "$destination"
  shasum -a 256 "$archive" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
ditto -x -k "$destination/$archive" "$check_dir"
codesign --verify --deep --strict "$check_dir/Duck Island.app"
cmp "$app/Contents/MacOS/DuckIsland" "$check_dir/Duck Island.app/Contents/MacOS/DuckIsland"
python3 - "$check_dir/Duck Island.app" "$tag" <<'PY'
import json, pathlib, plistlib, sys
sys.path.insert(0, 'scripts/ci')
from version import parse_tag
app = pathlib.Path(sys.argv[1])
expected = parse_tag(sys.argv[2])
with (app / 'Contents/Info.plist').open('rb') as stream:
    plist = plistlib.load(stream)
info = json.loads((app / 'Contents/Resources/build-info.json').read_text())
assert plist['CFBundleShortVersionString'] == expected['version']
assert plist['DuckIslandReleaseTag'] == expected['tag'] == info['tag']
assert plist['DuckIslandCommit'] == info['commit']
assert info['signing'] == 'ad-hoc' and info['notarized'] is False
PY
