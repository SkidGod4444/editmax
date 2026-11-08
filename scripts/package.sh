#!/bin/bash
# Builds a Release EditMax.app and packages it for a GitHub release into build/release/:
#   EditMax-<version>.dmg, EditMax-<version>.zip (also the app update Sparkle installs) and SHA256SUMS.
#
# VERSION (default: the one in project.yml) and BUILD (default: 1) stamp the bundle for this build only.
# Signing always uses the hardened runtime, so an ad-hoc local run exercises the same entitlements a release does.
#   SIGN_IDENTITY   a "Developer ID Application: …" identity in the keychain; ad hoc ("-") when unset
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   (CI)   or   NOTARY_PROFILE   (a Mac: a notarytool keychain profile,
#                   made once with `xcrun notarytool store-credentials <name>`)
#                   with a real identity, the app and the DMG are notarized by Apple and the tickets stapled,
#                   so Gatekeeper opens them on any Mac, offline too
# Run by scripts/release.sh on this Mac (releases are never built on GitHub), and by hand for a local check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="${VERSION:-$(grep -m1 CFBundleShortVersionString project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
BUILD="${BUILD:-1}"
OUT="$ROOT/build/release"; rm -rf "$OUT"; mkdir -p "$OUT"
DD="$ROOT/build/DerivedData-release"
APP="$DD/Build/Products/Release/EditMax.app"
BUN_ENT="$ROOT/scripts/signing/bun-runtime.entitlements"
APP_ENT="$ROOT/scripts/signing/editmax.entitlements"   # the chat's microphone under the hardened runtime
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
command -v uvx >/dev/null || brew install uv
# xcodegen refuses to generate unless both Vendor/ directories exist, so the bundled binaries come first.
scripts/vendor-codemax.sh
scripts/vendor-agent.sh
xcodegen generate -q

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
SPARKLE_LICENSE="$DD/SourcePackages/checkouts/Sparkle/LICENSE"
if [ -f "$SPARKLE_LICENSE" ]; then cp "$SPARKLE_LICENSE" "$LIC/Sparkle-LICENSE"
else echo "package: no Sparkle LICENSE at $SPARKLE_LICENSE; its MIT notice must ship with the framework" >&2; exit 1; fi
# PostHog's SDK, and the crash reporter and WebP library it vendors, are compiled into the executable.
PH="$DD/SourcePackages/checkouts/posthog-ios"
for pair in "LICENSE:PostHog-LICENSE" "vendor/PHPLCrashReporter/LICENSE:PLCrashReporter-LICENSE" "vendor/libwebp/COPYING:libwebp-COPYING" "vendor/libwebp/PATENTS:libwebp-PATENTS"; do
  if [ -f "$PH/${pair%%:*}" ]; then cp "$PH/${pair%%:*}" "$LIC/${pair##*:}"
  else echo "package: no ${pair%%:*} in the PostHog SDK at $PH; its notice must ship with the app" >&2; exit 1; fi
done

sign() {   # sign <path> [entitlements]
  local args=(--force --options runtime --sign "$IDENTITY")
  [ "$IDENTITY" != "-" ] && args+=(--timestamp)
  [ -n "${2:-}" ] && args+=(--entitlements "$2")
  codesign "${args[@]}" "$1"
}
for b in "$APP"/Contents/Resources/bin/*; do sign "$b" "$BUN_ENT"; done
# Sparkle (app updates) carries its own helpers. Each one is signed with our identity first, inside out; the framework loop
# below signs the framework as one bundle and would leave them with Sparkle's signature, which notarization rejects.
# The Downloader service keeps its own (network client) entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
[ -d "$SPARKLE" ] || { echo "package: Sparkle.framework is missing from the app" >&2; exit 1; }
sign "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --options runtime --sign "$IDENTITY" $([ "$IDENTITY" != "-" ] && echo --timestamp) --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" \) -prune -print 2>/dev/null | while read -r f; do sign "$f"; done
sign "$APP" "$APP_ENT"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "device.audio-input" || { echo "package: the app lost its microphone entitlement" >&2; exit 1; }
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

DMG="$OUT/EditMax-$VERSION.dmg"
# The DMG window (background, icon layout, volume icon; the app and an Applications link) is laid out by dmgbuild
# from scripts/dmg/settings.py. The licenses are inside the app, in Contents/Resources/Licenses.
uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg/settings.py -D app="$APP" "EditMax" "$DMG"
if [ "$IDENTITY" != "-" ]; then codesign --force --timestamp --sign "$IDENTITY" "$DMG"; fi
if [ -n "$NOTARIZE" ]; then
  notarize "$DMG"; xcrun stapler staple "$DMG"
  spctl --assess --type execute -vv "$APP"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  touch "$OUT/notarized"
fi
ditto -c -k --keepParent "$APP" "$OUT/EditMax-$VERSION.zip"

# Crash reports (EditMax/Support/Telemetry.swift) name the functions in a crash only with this build's debug symbols.
# The dSYM is always kept in build/dsyms (a later upload needs exactly this build's), and is uploaded to PostHog with
# the SDK's own script when POSTHOG_CLI_API_KEY is set: a personal API key with "error tracking write" and
# "organization read", a secret like the notary password, so it lives in .release.env and is never printed. The
# upload needs posthog-cli (`brew install posthog/tap/posthog-cli`) and POSTHOG_CLI_PROJECT_ID.
DSYM_DIR="$DD/Build/Products/Release"
if [ -d "$DSYM_DIR/EditMax.app.dSYM" ]; then
  mkdir -p "$ROOT/build/dsyms"
  ditto -c -k --keepParent "$DSYM_DIR/EditMax.app.dSYM" "$ROOT/build/dsyms/EditMax-$VERSION-$BUILD.dSYM.zip"
  if [ -n "${POSTHOG_CLI_API_KEY:-}" ]; then
    # The built app's Info.plist names the release (bundle id, version, build) the crash reports carry.
    CONFIGURATION=Release DEBUG_INFORMATION_FORMAT=dwarf-with-dsym DWARF_DSYM_FOLDER_PATH="$DSYM_DIR" DWARF_DSYM_FILE_NAME=EditMax.app.dSYM \
      TARGET_BUILD_DIR="$DSYM_DIR" EXECUTABLE_PATH=EditMax.app/Contents/MacOS/EditMax EXECUTABLE_NAME=EditMax \
      INFOPLIST_FILE="$APP/Contents/Info.plist" PRODUCT_BUNDLE_IDENTIFIER=io.openhorizon.editmax \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
      POSTHOG_CLI_HOST="${POSTHOG_CLI_HOST:-https://us.posthog.com}" \
      "$DD/SourcePackages/checkouts/posthog-ios/build-tools/upload-symbols.sh" \
      || echo "package: the dSYM upload to PostHog failed; upload build/dsyms/EditMax-$VERSION-$BUILD.dSYM.zip by hand" >&2
  else
    echo "package: POSTHOG_CLI_API_KEY is not set, so crashes in $VERSION ($BUILD) show without function names until build/dsyms/EditMax-$VERSION-$BUILD.dSYM.zip is uploaded"
  fi
else
  echo "package: no dSYM at $DSYM_DIR; crash reports from this build cannot be symbolicated" >&2
fi
( cd "$OUT" && shasum -a 256 EditMax-*.dmg EditMax-*.zip > SHA256SUMS && cat SHA256SUMS )
echo "package: EditMax $VERSION ($BUILD) -> $OUT"
