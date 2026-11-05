#!/bin/bash
# Called only by the gated tag job. Never create tags or overwrite a release.
set -euo pipefail
cd "$(dirname "$0")/../.."
tag=${RELEASE_TAG:?Missing RELEASE_TAG}
commit=${GITHUB_SHA:?Missing GITHUB_SHA}
python3 scripts/ci/version.py "$tag" >/dev/null
git fetch --no-tags origin "refs/tags/$tag"
[[ $(git rev-parse 'FETCH_HEAD^{commit}') == "$commit" ]] || { echo 'Tag moved since this run' >&2; exit 1; }
git fetch --no-tags origin main
git merge-base --is-ancestor "$commit" FETCH_HEAD
existing=$(mktemp)
trap 'rm -f "$existing"' EXIT
# A failed API request aborts; an existing draft also prevents accidental replacement.
gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq '.[].tag_name' > "$existing"
if grep -Fxq -- "$tag" "$existing"; then
  echo 'Release already exists (possibly a partial draft); refusing to overwrite' >&2
  exit 1
fi
(
  cd release
  shasum -a 256 -c SHA256SUMS
)
cat > release/NOTES.md <<EOF
macOS 15+ · Apple Silicon (arm64) · direct distribution build

Version: $tag · Commit: $commit

Download Duck-Island-$tag-macos-arm64.zip, extract Duck Island.app and move it to Applications.
Verify the ZIP with SHA256SUMS (shasum -a 256 -c SHA256SUMS).

Signing: ad-hoc only. This app has NO Developer ID signature and has NOT been notarized by Apple.
macOS Gatekeeper may block opening it; this download does not establish a trusted developer identity.
See https://support.apple.com/en-us/102445 for Apple's guidance. No system security settings are changed.
Updates may require renewed macOS privacy permissions because ad-hoc signatures do not preserve a developer identity.
EOF
flags=(--draft)
if [[ "$tag" == *-* ]]; then flags+=(--prerelease); fi
# Stage all assets before publishing, including when immutable releases are enabled.
gh release create "$tag" "release/Duck-Island-$tag-macos-arm64.zip" release/SHA256SUMS \
  --verify-tag --target "$commit" --title "Duck Island $tag" \
  --generate-notes --notes-file release/NOTES.md "${flags[@]}"
gh release edit "$tag" --draft=false
