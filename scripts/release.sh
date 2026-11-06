#!/bin/bash
# Cuts a release on this Mac: scripts/release.sh 0.2.0
# Nothing is built on GitHub. scripts/package.sh builds, signs and notarizes EditMax here; then the version is stamped
# into project.yml, committed, tagged v0.2.0 and pushed, and the GitHub release is published with the DMG, the zip,
# SHA256SUMS and appcast.xml. A build that is not notarized is never published (the website's Download button hands out
# the latest release to everyone).
#
# appcast.xml is what installed copies read to update themselves (SUFeedURL points at releases/latest/download/, so
# every release must carry one). Its one item is the zip, signed with the EdDSA key in the login keychain (account
# "editmax", made with Sparkle's generate_keys; backed up in ~/.editmax-sparkle). macOS may ask once to let
# sign_update use that key: allow it.
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

# The update feed: one item, the notarized zip, with its EdDSA signature and length from sign_update.
SPARKLE_BIN="build/DerivedData-release/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/sign_update" ] || { echo "release: Sparkle's sign_update is missing at $SPARKLE_BIN" >&2; exit 1; }
ZIP="build/release/EditMax-$V.zip"
SIG="$("$SPARKLE_BIN/sign_update" --account editmax "$ZIP")"
[[ "$SIG" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]] || { echo "release: sign_update did not sign $ZIP" >&2; exit 1; }
PAGE="https://github.com/SkidGod4444/editmax/releases/tag/v$V"
cat > build/release/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EditMax</title>
    <link>https://github.com/SkidGod4444/editmax/releases</link>
    <item>
      <title>EditMax $V</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$PAGE</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>EditMax $V is ready. <a href="$PAGE">See what's new</a>.</p>]]></description>
      <enclosure url="https://github.com/SkidGod4444/editmax/releases/download/v$V/EditMax-$V.zip" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
APPCAST
xmllint --noout build/release/appcast.xml

sed -i '' -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\1\"$V\"/; s/(CFBundleVersion: )\"[^\"]+\"/\1\"$BUILD\"/" project.yml
git diff --quiet project.yml || git commit -q -m "Release $V" project.yml
git tag -a "v$V" -m "EditMax $V"
git push -q origin main "v$V"
gh release create "v$V" "build/release/EditMax-$V.dmg" "build/release/EditMax-$V.zip" build/release/SHA256SUMS build/release/appcast.xml --verify-tag \
  --title "EditMax $V" --notes "Requires macOS 15 or later on Apple silicon (M1 or later). Signed and notarized by Apple." --generate-notes
echo "release: EditMax $V is live: https://github.com/SkidGod4444/editmax/releases/tag/v$V"
