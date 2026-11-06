# Fonts

Every title and caption can use any font: one already on your Mac, any of the roughly 1,900 families on
Google Fonts, or a font file you add yourself. Developers: see [internals-fonts.md](internals-fonts.md).

## Pick a font for a title

1. Select the title on the timeline.
2. In the Title card, click **Font**. The font browser opens.
3. Click a family. A Google font downloads first (a small spinner shows on its row), then it is applied.

The change is one step in Edit ▸ Undo. **Weight** (under Font) picks Light, Regular, Bold and so on when the family
has more than one. The back arrow next to the font puts the title back to its style's own font.

A lower third uses the font for the name and a lighter weight of the same family for the role line, when the family has
one.

## The font browser

- **Search** matches family names.
- **Show** picks what to list: all fonts, Recently used, In this project, My fonts, Google Fonts, or On this Mac.
- **Any style** narrows to Sans serif, Serif, Display, Handwriting or Monospace.
- **Sort**:
  - **Trending** is Google's own trending rank. It favours families whose use is growing fast, so recently added
    families are often near the top.
  - **Popular** is Google's rank by how many sites use the family.
  - **Newest** is by the date Google added it.
  - **A–Z** is by name.

  Fonts that are only on your Mac or that you added have no Google rank; they follow the Google ones, A to Z.

Each row shows the family's name drawn in that font. Google fonts you have not downloaded show a small preview that
EditMax fetches as you scroll; if it can't, the name shows in the normal font with a download icon.

## Add your own fonts

Click **+** (or **Add fonts…**) in the browser and pick files, or drop font files onto the browser. EditMax accepts
.ttf, .otf, .ttc, .otc, .woff and .woff2. The files are copied into EditMax's own folder, so moving or deleting the
originals later is fine. They show under **My fonts** and in the Assets library.

To remove one, open the Fonts pane (in the Home window's Assets section) and click the trash icon on its row. Its
files go to the Trash.

## Where fonts are kept

`~/Library/Application Support/EditMax/Fonts/`:

- `google/<Family>/` holds downloaded Google fonts.
- `custom/` holds the fonts you added.
- `google-catalog.json` is the list of Google families, refreshed at most once a day. Offline, EditMax uses the last
  copy it saved. With no saved copy and no network, the browser lists your Mac's fonts and your own, and says the Google
  list could not be loaded.

These fonts are for EditMax only; other apps on your Mac do not see them.

## Opening a project on another Mac

A project saves the font's name, not the font file.

- **A Google font** the other Mac does not have downloads by itself when the project opens. The title draws in its
  style's font for the moment it takes, then redraws.
- **A font you added** shows a warning in the Title card: "*Font* is not on this Mac. Add the font file to use it." The
  title draws in its style's font until you add the file (the **Add font…** button next to the warning).

Final Cut Pro and Resolve exports (File ▸ Export Timeline) name the font and its weight; the other app needs the font
installed too.

## For agents (MCP)

- `list_fonts`: search, category, sort (trending, popular, newest, name), source (installed, google, custom, system), limit.
- `install_font`: a Google family, optionally only some weights (`["400", "700", "700i"]`).
- `add_font_files`: font file paths to add.
- `add_text` takes `font`; `set_text_style` changes a text's font, font_size and color as one undo step.

A `font` argument is a family name (any case) or a PostScript name (`Inter-Bold`). A Google family that is not on this
Mac yet is downloaded first. `"default"` puts a text back on its style's font.

Google Fonts are free to use under the SIL Open Font License, the Apache License or the Ubuntu Font Licence. EditMax
downloads them only when you or an agent picks one.
