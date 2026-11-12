"""Fetch the WoW Forever client art and fonts the Addon Weight window draws, decode them, write manifest.json.

Run from the repository root:
    python3 -I -B tests/render/assets.py [cache dir] [ui source AddOns dir]
Defaults: .cache/addon-weight-render and .cache/wow-ui-source-forever/Interface/AddOns.

Every file comes from https://wago.tools/api/casc/<fdid>?version=<BUILD>; the atlas tables from
https://wago.tools/db2/<table>/csv?build=<BUILD>. Downloads are kept in <cache>/dl and <cache>/db2 and
reused; decoded PNGs go to <cache>/png. An atlas name resolves the way the Forever client resolves it:
the element of that name, its member in atlas set 1 (the "-c60" Camelot art) when it has one, else set 0;
the 1x member when there is one, else the 2x member at half its pixel size.
"""

import csv
import hashlib
import json
import os
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blp  # noqa: E402

from PIL import Image, ImageFont  # noqa: E402

BUILD = "1.60.1.70888"
UA = {"User-Agent": "Mozilla/5.0"}
TABLES = ["UiTextureAtlas", "UiTextureAtlasMember", "UiTextureAtlasElement", "UiTextureAtlasElementSliceData",
          "ManifestInterfaceData", "GlobalColor", "UiCanvas"]

# Every atlas the window, its templates and the tooltip draw (names as the XML and Lua give them).
ATLASES = [
    # DefaultPanelTemplate: NineSliceLayouts.ButtonFrameTemplateNoPortrait, and the title streaks
    "UI-Frame-Metal-CornerTopLeft", "UI-Frame-Metal-CornerTopRight", "UI-Frame-Metal-CornerBottomLeft",
    "UI-Frame-Metal-CornerBottomRight", "_UI-Frame-Metal-EdgeTop", "_UI-Frame-Metal-EdgeBottom",
    "!UI-Frame-Metal-EdgeLeft", "!UI-Frame-Metal-EdgeRight", "_UI-Frame-TopTileStreaks",
    # UIPanelCloseButton
    "RedButton-Exit",
    # InsetFrameTemplate
    "UI-Frame-InnerTopLeft", "UI-Frame-InnerTopRight", "UI-Frame-InnerBotLeftCorner", "UI-Frame-InnerBotRight",
    "_UI-Frame-InnerTopTile", "_UI-Frame-InnerBotTile", "!UI-Frame-InnerLeftTile", "!UI-Frame-InnerRightTile",
    # SearchBoxTemplate
    "common-search-border-left", "common-search-border-right", "common-search-border-middle",
    "common-search-magnifyingglass",
    # the window's own
    "Options_HorizontalDivider", "auctionhouse-rowstripe-1", "auctionhouse-rowstripe-2",
    "auctionhouse-ui-row-highlight", "auctionhouse-ui-sortarrow",
    # MinimalScrollBar
    "minimal-scrollbar-track-top", "minimal-scrollbar-track-bottom", "!minimal-scrollbar-track-middle",
    "minimal-scrollbar-small-thumb-top", "minimal-scrollbar-small-thumb-middle", "minimal-scrollbar-small-thumb-bottom",
    "minimal-scrollbar-arrow-top", "minimal-scrollbar-arrow-bottom",
    # SharedButtonSmallTemplate (128-RedButton)
    "128-RedButton-Left", "128-RedButton-Right", "_128-RedButton-Center",
    # PanelTabButtonTemplate
    "uiframe-tab-left", "uiframe-tab-right", "_uiframe-tab-center",
    "uiframe-activetab-left", "uiframe-activetab-right", "_uiframe-activetab-center",
    # GameTooltip: NineSliceLayouts.TooltipDefaultLayout
    "Tooltip-NineSlice-CornerTopLeft", "Tooltip-NineSlice-CornerTopRight", "Tooltip-NineSlice-CornerBottomLeft",
    "Tooltip-NineSlice-CornerBottomRight", "_Tooltip-NineSlice-EdgeTop", "_Tooltip-NineSlice-EdgeBottom",
    "!Tooltip-NineSlice-EdgeLeft", "!Tooltip-NineSlice-EdgeRight", "Tooltip-NineSlice-Center",
]

# Loose textures, by the path the XML or Lua names.
FILES = [
    "Interface\\FrameGeneral\\UI-Background-Rock",
    "Interface\\FrameGeneral\\UI-Background-Marble",
    "Interface\\FriendsFrame\\WhoFrame-ColumnTabs",
    "Interface\\DialogFrame\\DialogIcon-AlertNew-16",
]

FONT_FILES_TTF = {"FRIZQT__.TTF": 615960, "ARIALN.TTF": 615958}

# Font objects in game load order for the Mainline family (Blizzard_Fonts_Shared.toc, Glue-only files skipped).
FONT_XML = [
    "Blizzard_Fonts_Shared/Mainline/Fonts.xml",
    "Blizzard_Fonts_Shared/Shared/Fonts.xml",
    "Blizzard_Fonts_Shared/Shared/GameFonts.xml",
    "Blizzard_Fonts_Shared/Mainline/GameFonts.xml",
    "Blizzard_Fonts_Shared/Shared/FontStyles.xml",
    "Blizzard_Fonts_Shared/Mainline/FontStyles.xml",
    "Blizzard_Fonts_Shared/Mainline/GameFontStyles.xml",
    "Blizzard_Fonts_Shared/Shared/GameFontStyles.xml",
]
FONT_OBJECTS = [
    "GameFontNormal", "GameFontHighlight", "GameFontHighlightMedium", "GameFontHighlightSmall",
    "GameFontDisableSmall", "GameFontDisable", "GameFontNormalSmall", "Number14FontWhite",
    "GameTooltipHeaderText", "GameTooltipText",
]
COLORS = ["NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR", "WHITE_FONT_COLOR", "DISABLED_FONT_COLOR", "GREEN_FONT_COLOR",
          "RED_FONT_COLOR", "TOOLTIP_DEFAULT_COLOR", "TOOLTIP_DEFAULT_BACKGROUND_COLOR"]

log = []


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return open(dest, "rb").read()
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read()
        kind = resp.headers.get("Content-Type", "")
    # A bad file id answers 200 with a JSON error body.
    if "json" in kind or body[:1] == b"{":
        raise SystemExit(f"{url}: {body[:200]!r}")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as handle:
        handle.write(body)
    log.append({"url": url, "bytes": len(body)})
    return body


def table(cache, name):
    path = os.path.join(cache, "db2", f"{name}.csv")
    fetch(f"https://wago.tools/db2/{name}/csv?build={BUILD}", path)
    with open(path, encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def casc(cache, fdid, ext):
    dest = os.path.join(cache, "dl", f"{fdid}.{ext}")
    return fetch(f"https://wago.tools/api/casc/{fdid}?version={BUILD}", dest), dest


def decoded(cache, fdid):
    data, dest = casc(cache, fdid, "blp")
    png = os.path.join(cache, "png", f"{fdid}.png")
    img, header = blp.decode(data)
    if not os.path.exists(png):
        os.makedirs(os.path.dirname(png), exist_ok=True)
        img.save(png)
    return img, header, png, hashlib.sha256(data).hexdigest()


def is_2x(member, sheet):
    return member["UiCanvasID"] == "2" or sheet["UiCanvasID"] == "2" or member["CommittedName"].lower().endswith("-2x")


def resolve_atlases(cache):
    sheets = {r["ID"]: r for r in table(cache, "UiTextureAtlas")}
    members = table(cache, "UiTextureAtlasMember")
    elements = {r["Name"].lower(): r["ID"] for r in table(cache, "UiTextureAtlasElement")}
    slices = {r["UiTextureAtlasElementID"]: r for r in table(cache, "UiTextureAtlasElementSliceData")}
    by_element = {}
    for m in members:
        by_element.setdefault(m["UiTextureAtlasElementID"], []).append(m)
    out = {}
    for name in ATLASES:
        element = elements.get(name.lower())
        if element is None:
            raise SystemExit(f"atlas {name}: no element of that name in UiTextureAtlasElement")
        group = by_element[element]
        for m in group:
            m["_set"] = int(sheets[m["UiTextureAtlasID"]]["UiTextureAtlasSetID"])
            m["_2x"] = is_2x(m, sheets[m["UiTextureAtlasID"]])
        best_set = max(m["_set"] for m in group)
        pool = [m for m in group if m["_set"] == best_set]
        ones = [m for m in pool if not m["_2x"]] or pool
        # Two members in one set (a re-packed atlas): the one on a canvas-1 sheet, then the newest, wins.
        ones.sort(key=lambda m: (sheets[m["UiTextureAtlasID"]]["UiCanvasID"] == "1", int(m["ID"])), reverse=True)
        member = ones[0]
        scale = 1 if not member["_2x"] else 0.5
        sheet = sheets[member["UiTextureAtlasID"]]
        fdid = int(sheet["FileDataID"])
        img, header, png, sha = decoded(cache, fdid)
        if list(img.size) != [int(sheet["AtlasWidth"]), int(sheet["AtlasHeight"])]:
            raise SystemExit(f"sheet {fdid}: decoded {img.size}, table says {sheet['AtlasWidth']}x{sheet['AtlasHeight']}")
        flags = int(member["CommittedFlags"])
        entry = {
            "name": name, "member": member["CommittedName"], "element": int(element), "set": best_set,
            "twins": sorted(f"{m['CommittedName']} (set {m['_set']})" for m in group if m is not member),
            "tiedWith": [f"{m['CommittedName']} (member {m['ID']}, file {sheets[m['UiTextureAtlasID']]['FileDataID']})"
                         for m in ones[1:]],
            "file": fdid, "sheetPng": os.path.relpath(png, cache), "sheetSha256": sha,
            "rect": [int(member["CommittedLeft"]), int(member["CommittedTop"]), int(member["CommittedRight"]), int(member["CommittedBottom"])],
            "pixels": [int(member["Width"]), int(member["Height"])],
            "units": [int(member["Width"]) * scale, int(member["Height"]) * scale],
            "tileH": bool(flags & 4), "tileV": bool(flags & 2),
        }
        if element in slices:
            s = slices[element]
            entry["slice"] = [int(s["Left"]), int(s["Top"]), int(s["Right"]), int(s["Bottom"]), int(s["SliceMode"])]
        out[name.lower()] = entry
    return out


def resolve_files(cache):
    rows = table(cache, "ManifestInterfaceData")
    by_path = {}
    for r in rows:
        path = (r["FilePath"] + r["FileName"]).lower().replace("/", "\\")
        if path.endswith(".blp"):
            by_path[path[:-4]] = int(r["ID"])
    out = {}
    for path in FILES:
        fdid = by_path.get(path.lower())
        if fdid is None:
            raise SystemExit(f"texture {path}: not in ManifestInterfaceData")
        img, header, png, sha = decoded(cache, fdid)
        out[path.lower()] = {"path": path, "file": fdid, "png": os.path.relpath(png, cache), "sha256": sha,
                             "size": list(img.size), "encoding": header["encodingName"], "alphaType": header["alphaTypeName"]}
    return out


def strip(tag):
    return tag.split("}", 1)[-1]


def parse_font_node(node):
    d = {k: node.attrib[k] for k in ("font", "height", "outline", "inherits", "justifyH") if k in node.attrib}
    for child in node:
        t = strip(child.tag)
        if t == "Shadow":
            sh = {}
            if "x" in child.attrib or "y" in child.attrib:
                sh["offset"] = [child.attrib.get("x", "0"), child.attrib.get("y", "0")]
            for c in child:
                if strip(c.tag) == "Offset":
                    sh["offset"] = [c.attrib.get("x", "0"), c.attrib.get("y", "0")]
                    for a in c:
                        if strip(a.tag) == "AbsDimension":
                            sh["offset"] = [a.attrib.get("x", "0"), a.attrib.get("y", "0")]
                elif strip(c.tag) == "Color":
                    sh["color"] = dict(c.attrib)
            d["shadow"] = sh
        elif t == "Color":
            d["color"] = dict(child.attrib)
    return d


def font_objects(uisrc, colors):
    defs = {}
    for relpath in FONT_XML:
        root = ET.fromstring(open(os.path.join(uisrc, relpath), encoding="utf-8-sig").read())
        for node in root:
            name, t = node.attrib.get("name"), strip(node.tag)
            if not name or t not in ("Font", "FontFamily"):
                continue
            if t == "FontFamily":
                d = {}
                for member in node:
                    if member.attrib.get("alphabet") == "roman":
                        for f in member:
                            if strip(f.tag) == "Font":
                                d = parse_font_node(f)
            else:
                d = parse_font_node(node)
            d["_site"] = relpath
            defs[name] = d

    def resolve(name, depth=0):
        live = defs[name]
        base = resolve(live["inherits"], depth + 1)[0] if "inherits" in live and depth < 20 else {}
        out = dict(base)
        out.update({k: v for k, v in live.items() if not k.startswith("_") and k != "inherits"})
        chain = [name] + (resolve(live["inherits"], depth + 1)[1] if "inherits" in live else [])
        return out, chain

    result = {}
    for name in FONT_OBJECTS:
        r, chain = resolve(name)
        color = r.get("color") or {}
        rgb = colors[color["color"]] if "color" in color else [float(color.get(k, 1)) for k in "rgb"]
        shadow = None
        if r.get("shadow"):
            off = r["shadow"].get("offset") or ["0", "0"]
            c = r["shadow"].get("color") or {}
            shadow = {"x": float(off[0]), "y": float(off[1]),
                      "rgba": [float(c.get("r", 0)), float(c.get("g", 0)), float(c.get("b", 0)), float(c.get("a", 1))]}
        result[name] = {"font": r["font"].split("\\")[-1].upper(), "height": float(r["height"]), "rgb": rgb,
                        "shadow": shadow, "outline": r.get("outline"), "chain": chain}
    return result


def main():
    root = os.getcwd()
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, ".cache", "addon-weight-render")
    uisrc = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, ".cache", "wow-ui-source-forever", "Interface", "AddOns")
    version = open(os.path.join(uisrc, "..", "..", "version.txt")).read().strip()
    if version != BUILD:
        raise SystemExit(f"UI source is {version}, the art is pinned to {BUILD}")
    colors = {}
    for r in table(cache, "GlobalColor"):
        argb = int(r["Color"]) & 0xFFFFFFFF
        colors[r["LuaConstantName"]] = [((argb >> s) & 255) / 255 for s in (16, 8, 0)]
    fonts = {}
    for name, fdid in FONT_FILES_TTF.items():
        data, dest = casc(cache, fdid, "ttf")
        family = ImageFont.truetype(dest, 12).getname()
        fonts[name] = {"file": fdid, "local": os.path.relpath(dest, cache), "sha256": hashlib.sha256(data).hexdigest(),
                       "family": list(family)}
    manifest = {
        "build": BUILD,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "atlases": resolve_atlases(cache),
        "files": resolve_files(cache),
        "fonts": fonts,
        "fontObjects": font_objects(uisrc, colors),
        "colors": {k: colors[k] for k in COLORS},
        "downloads": log,
    }
    out = os.path.join(cache, "manifest.json")
    with open(out, "w") as handle:
        json.dump(manifest, handle, indent=1)
    print(f"wrote {out}: {len(manifest['atlases'])} atlases, {len(manifest['files'])} textures, {len(fonts)} fonts, "
          f"{len(log)} downloads")


if __name__ == "__main__":
    main()
