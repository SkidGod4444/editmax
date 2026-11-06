#!/bin/bash
# Builds codemax from ../codemax-cli (or $CODEMAX_SRC) and places the binary at Vendor/codemax,
# which the Xcode project copies into EditMax.app/Contents/Resources/bin. Skips the build when nothing changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${CODEMAX_SRC:-$ROOT/../codemax-cli}"
OUT="$ROOT/Vendor/codemax"
mkdir -p "$ROOT/Vendor"
if [ ! -d "$SRC" ]; then
  if [ -x "$OUT" ]; then echo "vendor-codemax: no source at $SRC, keeping $OUT"; exit 0; fi
  if [ -n "${EDITMAX_STUB_VENDOR:-}" ]; then   # CI: the runtime is not part of this repo; a stub keeps the bundle complete
    printf '#!/bin/sh\necho "codemax stub (EDITMAX_STUB_VENDOR)"; exit 1\n' > "$OUT"; chmod 755 "$OUT"; echo "vendor-codemax: wrote stub"; exit 0
  fi
  echo "vendor-codemax: no codemax source at $SRC and no Vendor/codemax; set CODEMAX_SRC" >&2; exit 1
fi
BUN="$(command -v bun || true)"
[ -z "$BUN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN="$HOME/.bun/bin/bun"
[ -z "$BUN" ] && [ -x /opt/homebrew/bin/bun ] && BUN=/opt/homebrew/bin/bun
[ -z "$BUN" ] && { echo "vendor-codemax: bun is required to build codemax" >&2; exit 1; }
if [ -x "$OUT" ] && [ -z "$(find "$SRC/src" "$SRC/package.json" -newer "$OUT" -print -quit)" ]; then
  echo "vendor-codemax: Vendor/codemax is current ($("$OUT" --version))"; exit 0
fi
( cd "$SRC" && { [ -d node_modules ] || "$BUN" install --frozen-lockfile; } && "$BUN" run build )
cp "$SRC/dist/codemax" "$OUT"; chmod 755 "$OUT"
echo "vendor-codemax: codemax $("$OUT" --version) -> $OUT"
