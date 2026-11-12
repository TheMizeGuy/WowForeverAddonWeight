Store images: the window drawn 1 unit = 1 pixel from the Forever client's own art and fonts, filled by the real addon under the fake client. From the repository root (needs Python 3 with Pillow, LuaJIT, and `.cache/wow-ui-source-forever` from `python3 tests/audit_globals.py --fetch`):

    python3 -I -B tests/render/assets.py   # client art, fonts and atlas tables for build 1.60.1.70888 into .cache/addon-weight-render
    luajit tests/render/dump.lua           # three invented sessions -> .cache/addon-weight-render/dump.json
    python3 -I -B tests/render/render.py   # art/screens/1-session.png, 2-all-time.png, 3-tooltip.png; prints the art used and the guesses
