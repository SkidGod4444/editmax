# dmgbuild settings for the EditMax installer window (the "timeline" look; art in scripts/dmg/src/index.html).
# Option names are from the dmgbuild 1.6.7 source (dmgbuild/core.py). scripts/package.sh runs it from the repo root:
#   uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg/settings.py -D app="$APP" "EditMax" "$DMG"
# Inputs come from -D defines. dmgbuild resolves paths against the working directory, so every default here is
# relative to the repo root: run it from there (package.sh does `cd "$ROOT"` first).

app = defines.get("app")  # noqa: F821  (dmgbuild injects `defines`)
if not app:
    raise SystemExit("settings.py: pass -D app=path/to/EditMax.app")
background = defines.get("background", "scripts/dmg/background.tiff")  # noqa: F821  1x+2x TIFF
icon = defines.get("icon", "EditMax/Resources/AppIcon.icns")  # noqa: F821  volume icon

format = "UDZO"  # same as the hdiutil line it replaces in scripts/package.sh (dmgbuild's default is UDBZ)
filesystem = "HFS+"

# The licenses travel inside the app (Contents/Resources/Licenses, copied by scripts/package.sh), not in the window.
files = [(app, "EditMax.app")]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: Finder already hides ".app" on app bundles (the name reads "EditMax"), and dmgbuild's
# SetFile -a E would add a FinderInfo xattr to the signed bundle that `codesign --verify --strict` rejects.

# Finder stores the window frame including its title bar (28-32 pt). 660x340 is the picture; 368 = 340 + 28.
# On a 32 pt title bar the bottom 4 pt of the picture is cut off, and the art keeps nothing there.
window_rect = ((200, 120), (660, 368))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
show_item_info = False
arrange_by = None
label_pos = "bottom"
icon_size = 128
text_size = 13

# Icon centres, in points from the top-left of the content area. The art puts a flat #757575 clip under each name.
icon_locations = {
    "EditMax.app": (170, 150),
    "Applications": (490, 150),
}
