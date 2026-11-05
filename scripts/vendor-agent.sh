#!/bin/bash
# Builds the API-key chat sidecar from agent/ (bun) and places it at Vendor/editmax-agent, which the Xcode
# project copies into EditMax.app/Contents/Resources/bin. Skips the build when nothing changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/agent"
OUT="$ROOT/Vendor/editmax-agent"
mkdir -p "$ROOT/Vendor"
BUN="$(command -v bun || true)"
[ -z "$BUN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN="$HOME/.bun/bin/bun"
[ -z "$BUN" ] && [ -x /opt/homebrew/bin/bun ] && BUN=/opt/homebrew/bin/bun
if [ -z "$BUN" ]; then
  if [ -x "$OUT" ]; then echo "vendor-agent: bun not found, keeping $OUT"; exit 0; fi
  echo "vendor-agent: bun is required to build the agent sidecar (curl -fsSL https://bun.sh/install | bash)" >&2; exit 1
fi
if [ -x "$OUT" ] && [ -z "$(find "$SRC/src" "$SRC/package.json" -newer "$OUT" -print -quit)" ]; then
  echo "vendor-agent: Vendor/editmax-agent is current ($("$OUT" --version))"; exit 0
fi
( cd "$SRC" && [ -d node_modules ] || "$BUN" install --frozen-lockfile )
( cd "$SRC" && "$BUN" run build )
cp "$SRC/dist/editmax-agent" "$OUT"; chmod 755 "$OUT"
echo "vendor-agent: editmax-agent $("$OUT" --version) -> $OUT"
