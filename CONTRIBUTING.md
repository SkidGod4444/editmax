# Contributing

Issues and pull requests are welcome. Before you change code:

- Read [docs/INTERNALS.md](docs/INTERNALS.md): the architecture, the engine's rules, the file format and the gotchas.
  Each area's detail is in `docs/internals-*.md` (editing, audio, assets, fonts and more).
- Keep its [UI conventions](docs/INTERNALS.md#ui-conventions).
- Add a test for behaviour you change. The model and tool tests run in about a second.
- Never call the macOS 26-only glass APIs directly; go through the compatibility layer.

## Build

You need Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and
[Bun](https://bun.sh) (for the chat sidecar).

```sh
scripts/vendor-codemax.sh && scripts/vendor-agent.sh   # bundle the agent runtime and the API-key sidecar
xcodegen generate
xcodebuild -project EditMax.xcodeproj -scheme EditMax -configuration Debug \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
open build/DerivedData/Build/Products/Debug/EditMax.app
```

- The agent runtime is built from a sibling checkout of [codemax-cli](https://github.com/SkidGod4444/codemax-cli).
  Without one, set `EDITMAX_STUB_VENDOR=1`: everything works except the in-app agent chat.
- Run `xcodegen generate` again after adding files.
- The deployment target is macOS 15. Liquid Glass is used on 26, and a material before it.

## Test

```sh
xcodebuild -project EditMax.xcodeproj -scheme EditMax -destination 'platform=macOS' test   # or ⌘U in Xcode
cd agent && bun test                                                                      # the chat sidecar
```

The Swift suite covers the timeline model, history, the tool API and the engine on a bundled clip (import, frame
render, nest, export, ProRes and HEVC masters, FCPXML and EDL). GitHub Actions runs both suites on every push and pull
request, but the seven tests that render video skip there because GitHub's video path is unreliable. Run the suite on
a Mac before a release.

## Website

The site is a static Next.js export in `web/`:

```sh
cd web && bun install
bun run dev     # http://localhost:3000
bun run build   # the static site, in web/out
```

- Vercel hosts it, with the root directory set to `web`, and builds every push to `main`.
- Host it at the root of a domain: asset paths start at `/`.
- The Download button finds the newest release's DMG through the GitHub API, so publishing a release updates it.
- Page views go to [Vercel Web Analytics](https://vercel.com/docs/analytics) (only from the Vercel deployment, and
  only with Analytics on in the Vercel project) and to PostHog, which keeps nothing on the visitor's device.
- SEO tags, `robots.txt`, `sitemap.xml`, share images and icons come from `web/src/app`. Their absolute URLs use the
  Vercel project's production domain at build time (`web/src/app/site.ts`).

## Release

Releases are built, signed and notarized on a Mac; nothing is built on GitHub.

```sh
scripts/release.sh 0.2.0
```

This runs `scripts/package.sh` (a Release build with the hardened runtime, signed with your Developer ID, notarized
and stapled, packaged as a DMG and a zip with `SHA256SUMS`), signs the zip for updates, writes `appcast.xml`, stamps
the version into `project.yml`, commits, tags `v0.2.0`, pushes and publishes the GitHub release. It refuses to
publish a build that is not notarized, because the website's Download button hands out the latest release.

It reads two settings from the environment or from a git-ignored `.release.env` in the repo root:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE=editmax   # made once with: xcrun notarytool store-credentials editmax
```

- Installed copies read `releases/latest/download/appcast.xml`, so every release carries one.
- The update key ([Sparkle](https://sparkle-project.org)'s EdDSA key) is in the login keychain under the account
  `editmax`; macOS may ask once to let `sign_update` use it. Keep a backup: without it, installed copies can't update.
- `scripts/package.sh` on its own builds into `build/release/` without publishing, and signs ad hoc without an
  identity.
- The installer window (the app and Applications as two clips on a timeline) is laid out by
  [dmgbuild](https://github.com/dmgbuild/dmgbuild) from `scripts/dmg/settings.py`; its art is
  `scripts/dmg/src/index.html`. The `installer-designer` agent in `.claude/agents/` makes and previews new looks.
