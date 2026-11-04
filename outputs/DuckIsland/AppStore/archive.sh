#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
team_id="${DEVELOPMENT_TEAM:-86NX4VWHDU}"
xcodebuild -project DuckIsland.xcodeproj -scheme DuckIsland -configuration Release \
  -archivePath ../AppStore/DuckIsland.xcarchive -derivedDataPath ../AppStore/SignedDerivedData \
  DEVELOPMENT_TEAM="$team_id" -allowProvisioningUpdates archive
