# Fonts

Titles and captions can use any font on your Mac, any of the roughly 1,900 Google Fonts families, or a font file you
add. Pick one in the Title card; manage them in Home ▸ Assets ▸ Fonts.

## Pick a font for a title

1. Select the title or caption, then click **Font** in its Title or Caption card.
2. Click a family (a Google font downloads first). The arrow keys browse without downloading; Return applies.

**Weight** picks Light, Bold and so on. The back arrow returns to the style's own font. Each change is one undo step.
A lower third's role line uses a lighter weight of the same family, when there is one.

## Find a font

- **Search** matches family names.
- **Show**: All fonts, Recently used, In this project, My fonts, Google Fonts or On this Mac.
- **Any style**: Sans serif, Serif, Display, Handwriting or Monospace.
- **Sort**: **Trending** (Google's rank of fast-growing families, often new ones), **Popular** (how many sites use it),
  **Newest** or **A–Z**. Fonts without a Google rank follow, A to Z.
- A cloud icon means the font downloads from Google Fonts when you use it.

## Add your own fonts

Click **+** (**Add Fonts…** in Home) or drop files onto the browser: .ttf, .otf, .ttc, .otc, .woff or .woff2. EditMax
copies them, so you can move or delete the originals. They appear under **My fonts** and in Assets.

## Manage your fonts

In Home ▸ Assets ▸ **Fonts**, click a family to preview it; type your own words and set the size at the bottom.
**Download** gets every style of a Google family. **Remove…** removes a font you added or downloaded: its files go to
the Archive, where Home ▸ Archive can restore them for 30 days (or the time set in Settings ▸ Files). Titles that use
it show their style's font meanwhile.

## Open a project on another Mac

A project saves the font's name, not the file.

- **A Google font** downloads by itself when the project opens. Offline, the Title card offers **Download**.
- **A font you added** shows "*Font* is not on this Mac. Add the font file to use it." in the Title card, with an
  **Add font…** button.

Until then the title draws in its style's font. File ▸ Export Timeline… names the font and weight; Final Cut Pro or
Resolve needs it installed too.

## Where fonts are kept

In `~/Library/Application Support/EditMax/Fonts/`: Google downloads in `google/`, your own in `custom/`. EditMax
refreshes the Google list at most once a day and uses its last copy offline. Google Fonts are free under the SIL Open
Font License, the Apache License or the Ubuntu Font Licence, and download only when you or an agent picks one.

## For agents

- `list_fonts`: search, category, sort, source, limit.
- `install_font`: a Google family, optionally some weights (`["400", "700", "700i"]`). `add_font_files`: font files.
- `add_text` takes `font`; `set_text_style` sets font, font_size and color in one undo step. A `font` is a family name
  (any case) or a PostScript name (`Inter-Bold`), downloaded first if it is a Google family; `"default"` returns to
  the style's font.

## Limits

These fonts are for EditMax only; other apps on your Mac do not see them.
