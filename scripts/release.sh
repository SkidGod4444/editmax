#!/bin/bash
# Cuts a release on this Mac: scripts/release.sh 0.2.0
# Nothing is built on GitHub. scripts/package.sh builds, signs and notarizes EditMax here; then the version is stamped
# into project.yml, committed, tagged v0.2.0 and pushed, and the GitHub release is published with the DMG, the zip and
# SHA256SUMS. A build that is not notarized is never published (the website's Download button hands out the latest
# release to everyone).
#
#   SIGN_IDENTITY   a "Developer ID Application: …" identity in your keychain
#   NOTARY_PROFILE  a notarytool keychain profile, made once with: xcrun notarytool store-credentials <name>
# Both come from the environment or from .release.env in the repo root (git-ignored, so they stay on this Mac).
set -euo pipefail
V="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release: version must look like 0.2.0" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
[ -f .release.env ] && . ./.release.env
: "${SIGN_IDENTITY:?release: set SIGN_IDENTITY (in .release.env or the environment) to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?release: set NOTARY_PROFILE (in .release.env or the environment) to your notarytool keychain profile}"
export SIGN_IDENTITY NOTARY_PROFILE
command -v gh >/dev/null || { echo "release: needs the GitHub CLI (brew install gh)" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || { echo "release: commit or stash your changes first" >&2; exit 1; }
[ "$(git branch --show-current)" = "main" ] || { echo "release: switch to main first" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release: main differs from origin/main; pull or push first" >&2; exit 1; }
if git tag -l "v$V" | grep -q . || git ls-remote --exit-code --tags origin "refs/tags/v$V" >/dev/null 2>&1; then
  echo "release: v$V already exists" >&2; exit 1
fi

BUILD="$(git rev-list --count HEAD)"
VERSION="$V" BUILD="$BUILD" scripts/package.sh
[ -f build/release/notarized ] || { echo "release: the build was not notarized, so nothing was published" >&2; exit 1; }

sed -i '' -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\1\"$V\"/; s/(CFBundleVersion: )\"[^\"]+\"/\1\"$BUILD\"/" project.yml
git diff --quiet project.yml || git commit -q -m "Release $V" project.yml
git tag -a "v$V" -m "EditMax $V"
git push -q origin main "v$V"
gh release create "v$V" "build/release/EditMax-$V.dmg" "build/release/EditMax-$V.zip" build/release/SHA256SUMS --verify-tag \
  --title "EditMax $V" --notes "Requires macOS 15 or later on Apple silicon (M1 or later). Signed and notarized by Apple." --generate-notes
echo "release: EditMax $V is live: https://github.com/SkidGod4444/editmax/releases/tag/v$V"
