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
# Document icon for .editmax files (CFBundleTypeIconFile): the page in scripts/icon/doc.html with the app icon as badge.
cp scripts/icon/doc.html "$TMP/doc.html"
"$CH" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 --window-size=1024,1024 --screenshot="$TMP/doc.png" "file://$TMP/doc.html" >/dev/null 2>&1
mkdir -p "$TMP/ProjectDoc.iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$TMP/doc.png" --out "$TMP/ProjectDoc.iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$TMP/doc.png" --out "$TMP/ProjectDoc.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/ProjectDoc.iconset" -o EditMax/Resources/ProjectDoc.icns
# README / docs copies
mkdir -p docs; sips -z 256 256 "$TMP/icon.png" --out docs/icon-256.png >/dev/null; sips -z 256 256 "$TMP/doc.png" --out docs/project-file-256.png >/dev/null
cp "$TMP/icon.png" "${1:-$TMP/icon.png}"; cp "$TMP/doc.png" "$(dirname "${1:-$TMP/icon.png}")/editmax-project-file-icon.png"
echo "AppIcon.icns + ProjectDoc.icns rebuilt; 1024 px PNGs at ${1:-$TMP/icon.png} and editmax-project-file-icon.png beside it"
