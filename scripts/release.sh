#!/bin/bash
# Cuts a release: scripts/release.sh 0.2.0
# Stamps the version into project.yml, commits it, tags v0.2.0 and pushes both. The push of the tag starts
# .github/workflows/release.yml, which builds, packages and publishes the GitHub release with the DMG and zip.
set -euo pipefail
V="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release: version must look like 0.2.0" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
[ -z "$(git status --porcelain)" ] || { echo "release: commit or stash your changes first" >&2; exit 1; }
[ "$(git branch --show-current)" = "main" ] || { echo "release: switch to main first" >&2; exit 1; }
git tag -l "v$V" | grep -q . && { echo "release: v$V already exists" >&2; exit 1; }
sed -i '' -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\1\"$V\"/" project.yml
git add project.yml && git commit -q -m "Release $V" && git tag -a "v$V" -m "EditMax $V"
git push -q origin main "v$V"
echo "release: pushed v$V; watch https://github.com/SkidGod4444/editmax/actions/workflows/release.yml"
