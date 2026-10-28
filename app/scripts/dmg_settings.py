# dmgbuild settings for the eyeOS disk image (used by scripts/package_app.sh).
# Defines passed with -D: app (path to eyeOS.app), background (path to the 1x PNG; a @2x PNG beside it is picked up),
# icon (the volume icon).
import os.path

app = defines["app"]  # noqa: F821 - provided by dmgbuild
appname = os.path.basename(app)

format = "ULFO"            # lzfse: smaller than zlib, opens on macOS 10.11+
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821
hide_extensions = [appname]

background = defines["background"]  # noqa: F821
# window content 660 x 420 (scripts/make_dmg_background.swift); the title bar sits on top of it
window_rect = ((200, 140), (660, 442))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {appname: (170, 215), "Applications": (490, 215)}
