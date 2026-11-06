# Fonts: internals

How the font library is built, for whoever changes it. Users: see [fonts.md](fonts.md). The engine's general rules
are in [INTERNALS](INTERNALS.md).

## Files

| File | What it holds |
| --- | --- |
| `Model/Project.swift` | `TextOverlay.fontName` (PostScript name) and `fontFamily`. Both optional, so older files decode with nil and no format version bump was needed. |
| `Engine/TextFont.swift` | `TextOverlay.font(style:size:)` and `lowerThirdFonts(nameSize:roleSize:)`: the one place that turns a text into an `NSFont`. Thread-safe; renderers call it off the main thread. |
| `Engine/FontLibrary.swift` | `@MainActor FontLibrary.shared`: system families, the Google catalogue, downloads, added files, registration, previews, resolving font arguments, missing-font status. |
| `Engine/FontTools.swift` | `ToolExecutor.setTextStyle` (the one edit for font, size and colour) and `ToolExecutor.fontList` (`list_fonts`). |
| `UI/FontBrowser.swift` | `FontBrowser` (pick and manage modes), `FontsPane()`, and the Title card rows `TextFontRow`, `TextFaceRow`, `TextFontStatusRow`. |
| `EditMaxTests/FontLibraryTests.swift` | Network-free tests (a fake `FontLibrary.fetch`), plus an opt-in real-network test. |

## One resolver for every renderer

`TextOverlay.font(style:size:)` returns, in order:

1. The chosen face by PostScript name, when Core Text has it.
2. Otherwise, a face of `fontFamily`: the same style as the PostScript name's suffix ("Inter-SemiBold" → "SemiBold"),
   else the face nearest the preset font's weight. This covers a project moved to a Mac that has the family from
   another source, with different PostScript names.
3. Otherwise, the preset's font (`CaptionStyle.fontName`), exactly as before fonts existed.

Callers: `OverlayLayerBuilder.renderText` (plain titles and captions, used by preview, export and `capture_frame`),
`TitleRasterizer.title` and `lowerThirdLayout` (animated titles and lower thirds), `TextLayout.box` (overlap checks), and
the FCPXML writer in `Interchange.swift`. A lower third's role line uses `TextFont.lighter(than:)`: the heaviest face of
the same family at least 0.12 lighter in Core Text weight (Bold → Medium), else the name's face. Without a chosen font it
stays Helvetica Neue Bold / Medium.

FCPXML writes `font="<family>" fontFace="<style>"` for a chosen font that resolves, the family alone when it is missing,
and `font="<preset PostScript name>"` otherwise (unchanged). The export report lists the font names as transferred,
with a note that the other Mac needs them.

## Registration

Fonts are registered for this process only: `CTFontManagerRegisterFontsForURL(url, .process, …)`.
`FontLibrary.registerInstalledFonts()` runs first thing in `EditMaxApp.init` (skipped under tests), before any document
window restores or the MCP server starts, so the first render already sees them. `alreadyRegistered` counts as success.
Removing a font unregisters it, then moves its files to the Trash (tests delete them).

Core Text on macOS 15+ accepts .ttf, .otf, .ttc, .otc, .woff and .woff2 through this call (checked with a variable
WOFF2: all its named instances register). The accepted extensions are `AssetLibrary.fontExtensions`.

Preview subsets (below) are never registered: a css2 `&text=` subset carries the full font's PostScript name and would
shadow the real face. They are loaded with `CTFontManagerCreateFontDescriptorFromData` and used as an unregistered
`CTFont` in the row only.

## Folders

`FontLibrary.directory` (default `~/Library/Application Support/EditMax/Fonts`, overridable in tests):

- `google/<Family>/<Family>-<style>.ttf`, one file per style ("400", "700i").
- `custom/<original name>.ttf`, copies of added files (deduplicated by identical faces and size).
- `previews/<Family>.ttf`, the few-kB name subsets; safe to delete.
- `google-catalog.json`, the raw metadata as last fetched.

Every downloaded and added file is also registered in the Assets library with
`AssetLibrary.shared.add(urls:source:.download or .upload, copy: false)`; removal calls `AssetLibrary.shared.remove`.

## The Google catalogue

`https://fonts.google.com/metadata/fonts` (no key). It is JSON, sometimes behind a `)]}'` guard line, which is stripped.
Fields used from each entry of `familyMetadataList`:

| Field | Use |
| --- | --- |
| `family` | Name, and the css2 `family=` value. |
| `category` | Sans Serif, Serif, Display, Handwriting, Monospace. About 585 families have null; `stroke` is used then (Slab Serif counts as Serif). |
| `popularity` | Google's usage rank, 1 = most used. Sort "Popular". |
| `trending` | Google's trending rank, 1 = top, unique per family. Sort "Trending". It favours families whose use is growing fast, so recent additions lead. The UI and `list_fonts` say so. |
| `dateAdded` | Sort "Newest". |
| `fonts` | Variant keys ("400", "700i"): the styles offered. |
| `subsets` | Scripts (the "menu" subset is dropped). |

`refreshCatalog(force:)` fetches at most once per 24 hours (by the cache file's date), parses off the main actor, and
deduplicates concurrent calls. Offline with a cache: state `.stale`, the cache is used. Offline with no cache:
`.unavailable`, and the browser lists system and custom fonts with a message.

## Downloading a Google family

`installGoogle(_:styles:)`:

1. Looks the family up in the catalogue (refreshing it once if unknown); resolves styles ("700", "700i", "bold",
   "italic", "regular"…), default all.
2. Skips styles already on disk; deduplicates concurrent installs of the same family.
3. Requests `https://fonts.googleapis.com/css2?<cssQuery>` with `User-Agent: EditMax/<version>`. A non-browser agent gets
   one complete TTF per style (a browser agent gets WOFF2 split by unicode-range, which would need every slice).
   `cssQuery`: `family=X` for 400 only, `family=X:wght@400;700` for uprights, `family=X:ital,wght@0,400;1,400` with italics.
   Note css2 silently drops weights a family lacks, so missing styles are reported in `InstallResult.missing`.
4. Fetches the files four at a time, writes each to a temp file, checks Core Text can read faces from it, moves it into
   place, registers it, updates `progress[family]`.
5. Adds the files to the Assets library and bumps `version`.

The GitHub tree (`raw.githubusercontent.com/google/fonts/main/ofl/<dir>/…`) also works but needs a family→directory map,
is rate limited and serves large variable fonts; css2 was chosen.

Previews: `requestPreview(family)` fetches `css2?family=X&text=<name>` (a 2–5 kB subset), six at a time, once per
family per session (failures are not retried until relaunch).

## Opening projects and missing fonts

`EditorRootView.onAppear` calls `FontLibrary.shared.ensureFonts(for:)`: every chosen family that is in the Google
catalogue and not installed is downloaded in the background. Fonts arriving bump `FontLibrary.version`;
`PlayerController` subscribes and rebuilds when any text has a chosen font. That is a redraw, not an edit: no history
entry, no undo step.

`status(of:)` drives `TextFontStatusRow` in the Title card:

- `.downloading(family, progress)`.
- `.missingGoogle(family, error)`: offline or failed; Download retries.
- `.missingCustom(family)`: "<Font> is not on this Mac. Add the font file to use it." with an Add font… button.

Meanwhile the text renders with its preset's font (rule 3 above).

## Edits and MCP

All font edits go through `ToolExecutor.setTextStyle` (one `document.apply`, label "Text font" or "Text style", one undo
step) or `addText(…, font:)`. The Title card's Font row, Weight picker and reset button call `setTextStyle` with
`origin: .user`; the MCP tools with `.agent`.

`FontLibrary.resolve(_:)` turns a `font` argument into a `FontChoice`:

1. "default", "none", "preset" → back to the preset's font.
2. An installed family, any case (custom first, then Google, then system).
3. An exact PostScript name.
4. A Google family → installed first.
5. Otherwise an error with close names.

Tools: `list_fonts`, `install_font`, `add_font_files` (in `FollowPlans.none`: nothing on the timeline to show), the
`font` argument of `add_text`, and `set_text_style` (`P(text: "text", anchor: .title)`, so following lands on the
Title card).

## UI

`FontBrowser(mode: .pick)` is the Title card's popover (340×480): a click applies, downloading a Google family first.
`FontBrowser(mode: .manage)` / `FontsPane()` is the full-size library with Download and remove buttons; it takes no
arguments so the Home window's Assets section can embed it. Both accept dropped font files and have an Add fonts…
open panel.

Rows draw the family's name in the family: `displayFont` for installed families (rejects symbol fonts and fonts without
glyphs for their own name), the preview subset for Google families not downloaded, else the system font with a
download icon. `.uiFrame` ids: `fonts.popover` / `fonts.pane` (the whole browser, also the drop target), `fonts.search`, `fonts.source`, `fonts.category`, `fonts.sort`, `fonts.add`,
`fonts.list`, `fonts.<section>.<family>` (rows), `fonts.download.<family>`, `fonts.remove.<family>`,
`fonts.catalog.retry`, `inspector.text.font`, `inspector.text.fontReset`, `inspector.text.fontWeight`,
`inspector.text.fontDownload`, `inspector.text.fontAdd`.

## Tests

`FontLibraryTests` points `FontLibrary.directory` and `AssetLibrary.indexURL` at a temp folder and replaces
`FontLibrary.fetch` with `FakeFontNetwork`: a four-family catalogue fixture and the Plaster font (SIL OFL, unmodified,
licence in `EditMaxTests/Fixtures/Plaster-OFL.txt`) behind css2 and gstatic URLs. Nothing touches the network.

`GoogleFontsNetworkTests` runs only with `TEST_RUNNER_EDITMAX_NETWORK_TESTS=1`: it fetches the real catalogue, installs
Playfair Display into a temp folder, renders a frame through the real compositor and an exported movie, and compares
them. With `TEST_RUNNER_EDITMAX_PREVIEW_DIR` set, the font tests save PNGs (`fonts-*.png`).
