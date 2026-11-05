#!/bin/bash
# Rebuilds EditMax/Resources/AppIcon.icns from EditMax/Resources/AppIcon.svg (1024 px render through headless Chrome,
# transparent background, then the macOS iconset). Run after editing the SVG.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
printf '<html><head><style>html,body{margin:0;background:transparent;overflow:hidden}</style></head><body>%s</body></html>' "$(cat EditMax/Resources/AppIcon.svg)" > "$TMP/icon.html"
"$CH" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 --window-size=1024,1024 --screenshot="$TMP/icon.png" "file://$TMP/icon.html" >/dev/null 2>&1
mkdir -p "$TMP/AppIcon.iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o EditMax/Resources/AppIcon.icns
cp "$TMP/icon.png" "${1:-$TMP/icon.png}"
echo "AppIcon.icns rebuilt; 1024 px PNG at ${1:-$TMP/icon.png}"
