#!/bin/bash
# Builds a Release EditMax.app and packages it for a GitHub release into build/release/:
#   EditMax-<version>.dmg, EditMax-<version>.zip and SHA256SUMS.
#
# VERSION (default: the one in project.yml) and BUILD (default: 1) stamp the bundle for this build only.
# Signing always uses the hardened runtime, so an ad-hoc local run exercises the same entitlements a release does.
#   SIGN_IDENTITY   a "Developer ID Application: …" identity in the keychain; ad hoc ("-") when unset
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   (CI)   or   NOTARY_PROFILE   (a Mac: a notarytool keychain profile,
#                   made once with `xcrun notarytool store-credentials <name>`)
#                   with a real identity, the app and the DMG are notarized by Apple and the tickets stapled,
#                   so Gatekeeper opens them on any Mac, offline too
# Run by .github/workflows/release.yml on a tag, and by hand for a local check: scripts/package.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="${VERSION:-$(grep -m1 CFBundleShortVersionString project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
BUILD="${BUILD:-1}"
OUT="$ROOT/build/release"; rm -rf "$OUT"; mkdir -p "$OUT"
DD="$ROOT/build/DerivedData-release"
APP="$DD/Build/Products/Release/EditMax.app"
BUN_ENT="$ROOT/scripts/signing/bun-runtime.entitlements"
IDENTITY="${SIGN_IDENTITY:--}"
NOTARIZE=""; NOTARY=()
if [ -n "${NOTARY_PROFILE:-}" ]; then NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  NOTARY=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"); fi
if [ "$IDENTITY" != "-" ] && [ ${#NOTARY[@]} -gt 0 ]; then NOTARIZE=1; fi
echo "package: EditMax $VERSION ($BUILD), identity: $IDENTITY, notarize: ${NOTARIZE:-no}"

# The stamp is for this build only: project.yml and the generated Info.plist are put back when the script ends.
cp project.yml "$OUT/project.yml.bak"; cp EditMax/Resources/Info.plist "$OUT/Info.plist.bak"
trap 'mv "$OUT/project.yml.bak" project.yml; mv "$OUT/Info.plist.bak" EditMax/Resources/Info.plist' EXIT
sed -i '' -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\1\"$VERSION\"/; s/(CFBundleVersion: )\"[^\"]+\"/\1\"$BUILD\"/" project.yml
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate -q
scripts/vendor-codemax.sh
scripts/vendor-agent.sh

# Build unsigned; everything is signed below, inside out, with the identity and entitlements each part needs.
rm -rf "$APP"   # so a failed build can never package the previous one
xcodebuild -project EditMax.xcodeproj -scheme EditMax -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|\*\* BUILD" || true
[ -d "$APP" ] || { echo "package: no app at $APP" >&2; exit 1; }

# The license, the commercial terms and every bundled component's license travel with the app (the licenses require it).
LIC="$APP/Contents/Resources/Licenses"; mkdir -p "$LIC"
cp LICENSE COMMERCIAL.md THIRD-PARTY-NOTICES.md "$LIC/"
CODEMAX_LICENSE="${CODEMAX_SRC:-$ROOT/../codemax-cli}/LICENSE"
if [ -f "$CODEMAX_LICENSE" ]; then cp "$CODEMAX_LICENSE" "$LIC/codemax-LICENSE"
else echo "package: no codemax LICENSE at $CODEMAX_LICENSE; its AGPL text must ship with the binary" >&2; exit 1; fi

sign() {   # sign <path> [entitlements]
  local args=(--force --options runtime --sign "$IDENTITY")
  [ "$IDENTITY" != "-" ] && args+=(--timestamp)
  [ -n "${2:-}" ] && args+=(--entitlements "$2")
  codesign "${args[@]}" "$1"
}
for b in "$APP"/Contents/Resources/bin/*; do sign "$b" "$BUN_ENT"; done
find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" \) -prune -print 2>/dev/null | while read -r f; do sign "$f"; done
sign "$APP"
codesign --verify --deep --strict "$APP"
# The bundled runtimes must still start under the hardened runtime (without their entitlements they die at launch).
"$APP/Contents/Resources/bin/codemax" --version >/dev/null || { echo "package: bundled codemax does not start under the hardened runtime" >&2; exit 1; }

notarize() {   # notarize <file>: submit, wait, and on rejection print Apple's log and fail
  local res="$OUT/notary-$(basename "$1").json"
  xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 30m --output-format json > "$res"
  local status id; status=$(plutil -extract status raw "$res"); id=$(plutil -extract id raw "$res")
  echo "package: notarization of $(basename "$1"): $status ($id)"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true
    exit 1
  fi
}
if [ -n "$NOTARIZE" ]; then
  # The app is notarized and stapled first, so the copy in the zip and the one in the DMG both carry the ticket.
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"; notarize "$OUT/notarize.zip"; rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
fi

STAGE="$OUT/stage"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"; cp LICENSE "$STAGE/LICENSE.txt"
DMG="$OUT/EditMax-$VERSION.dmg"
hdiutil create -volname "EditMax" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
if [ "$IDENTITY" != "-" ]; then codesign --force --timestamp --sign "$IDENTITY" "$DMG"; fi
if [ -n "$NOTARIZE" ]; then
  notarize "$DMG"; xcrun stapler staple "$DMG"
  spctl --assess --type execute -vv "$APP"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  touch "$OUT/notarized"
fi
ditto -c -k --keepParent "$APP" "$OUT/EditMax-$VERSION.zip"
( cd "$OUT" && shasum -a 256 EditMax-*.dmg EditMax-*.zip > SHA256SUMS && cat SHA256SUMS )
echo "package: EditMax $VERSION ($BUILD) -> $OUT"
