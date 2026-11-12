#!/usr/bin/env python3
"""Draws the Addon Weight window from tests/render/dump.lua's JSON with the Forever client's own art and fonts.

Run from the repository root (after assets.py and dump.lua):
    python3 -I -B tests/render/render.py [cache dir] [out dir]
Defaults: .cache/addon-weight-render (manifest.json, dump.json) and art/screens.

One UI unit is one pixel. Every position comes from !!AddonWeight/Window.lua and the Blizzard templates it
uses (file and line in the comments below); every text, colour, sort and row from the dump. What the
engine does that no Lua or XML states is listed in GUESSES and printed with each run.
"""

import json
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFont

GUESSES = [
    "text: the client's TTF at the font object's height in pixels, unhinted (drawn at 4x and box-filtered, so "
    "advances are fractional), grey anti-aliasing; a line box is the font's height and the ascent/descent span is "
    "centred in it; the string's start and baseline are rounded to whole pixels",
    "shadow: the glyphs once more in the shadow colour, offset by the font object's shadow offset (1, -1 -> one "
    "pixel right and down)",
    "a string wider than its region is cut and ends in '...', as a non-wrapping FontString does",
    "textures snap their edges to whole pixels; minified art is box-filtered (area average), magnified art "
    "bilinear; the atlas sheets carry no mipmaps, so the client's own minification may alias more",
    "tiled textures repeat at the atlas member's size in units (file textures at one texel a unit), starting at "
    "the region's top left",
    "GameTooltip: 10 units of padding on every side, 2 between lines, at least 20 between the two halves of a "
    "double line, wrapped lines wrap at the width the other lines set",
    "regions of one frame on one layer draw in creation order; later sibling frames draw over earlier ones",
]

WHITE = (1, 1, 1)
# Glyphs are drawn at this many times their size and box-filtered down: even spacing, no hinting jumps.
SUPER = 4

# Window.lua
WIDTH, HEIGHT = 780, 630
LEFT = 15
ROW_HEIGHT = 20
ALERT = "Interface\\DialogFrame\\DialogIcon-AlertNew-16"


def snap(v):
    return int(math.floor(v + 0.5))


class Art:
    def __init__(self, cache):
        self.cache = cache
        with open(os.path.join(cache, "manifest.json")) as handle:
            self.m = json.load(handle)
        self.images = {}
        self.fonts = {}
        self.used = {}
        self.notes = []

    def _img(self, rel):
        if rel not in self.images:
            img = Image.open(os.path.join(self.cache, rel))
            img.load()
            self.images[rel] = img.convert("RGBA")
        return self.images[rel]

    def atlas(self, name):
        a = self.m["atlases"][name.lower()]
        l, t, r, b = a["rect"]
        self.used[name] = f"atlas {a['member']} (set {a['set']}), sheet file {a['file']}"
        return self._img(a["sheetPng"]).crop((l, t, r, b)), a

    def file(self, path):
        f = self.m["files"][path.lower()]
        self.used[path] = f"file {f['file']}"
        return self._img(f["png"]), f

    def font(self, obj):
        spec = self.m["fontObjects"][obj]
        key = (spec["font"], spec["height"])
        if key not in self.fonts:
            fid = self.m["fonts"][spec["font"]]["local"]
            self.fonts[key] = ImageFont.truetype(os.path.join(self.cache, fid), int(spec["height"] * SUPER))
        return self.fonts[key], spec


# Texture drawing ----------------------------------------------------------------------------------------


def premul(img):
    return img.convert("RGBa")


def resample(img, size, box=None):
    """img (or box of it, texel floats) to size: box filter where it shrinks, bilinear where it grows, per axis."""
    w, h = size
    box = box or (0, 0, img.width, img.height)
    sw, sh = box[2] - box[0], box[3] - box[1]
    src = premul(img)
    fx = Image.BOX if sw > w * 1.001 else Image.BILINEAR
    fy = Image.BOX if sh > h * 1.001 else Image.BILINEAR
    if fx == fy:
        out = src.resize((w, h), fx, box=box)
    else:
        tmp = src.resize((w, src.height), fx, box=(box[0], 0, box[2], src.height))
        out = tmp.resize((w, h), fy, box=(0, box[1], w, box[3]))
    return out.convert("RGBA")


def tint(layer, rgba):
    if tuple(rgba) == (1, 1, 1, 1):
        return layer
    bands = layer.split()
    out = [band.point(lambda v, f=f: int(round(v * f))) if f != 1 else band for band, f in zip(bands, rgba)]
    return Image.merge("RGBA", out)


def desaturate(layer):
    r, g, b, a = layer.split()
    luma = Image.merge("RGB", (r, g, b)).convert("L")
    return Image.merge("RGBA", (luma, luma, luma, a))


def paste(canvas, layer, x, y, blend=None):
    """Composites layer with its top left at canvas (x, y), clipped to the canvas."""
    l, t = max(x, 0), max(y, 0)
    r, b = min(x + layer.width, canvas.width), min(y + layer.height, canvas.height)
    if r <= l or b <= t:
        return
    part = layer.crop((l - x, t - y, r - x, b - y))
    if blend == "ADD":
        target = canvas.crop((l, t, r, b))
        lr, lg, lb, la = part.split()
        add = Image.merge("RGB", (ImageChops.multiply(lr, la), ImageChops.multiply(lg, la), ImageChops.multiply(lb, la)))
        summed = ImageChops.add(target.convert("RGB"), add)
        summed.putalpha(target.getchannel("A"))
        canvas.paste(summed, (l, t))
    else:
        canvas.alpha_composite(part, dest=(l, t))


def texture(canvas, src, rect, tile=(None, None), color=(1, 1, 1, 1), blend=None, desat=False, texbox=None):
    """src stretched (or tiled with the given period in pixels per axis) over rect (canvas floats l t r b)."""
    l, t, r, b = (snap(v) for v in rect)
    w, h = r - l, b - t
    if w <= 0 or h <= 0:
        return None
    px, py = tile
    if px is None and py is None:
        layer = resample(src, (w, h), texbox)
    else:
        tw, th = px or w, py or h
        unit = resample(src, (tw, th), texbox)
        layer = Image.new("RGBA", (w, h))
        for y0 in range(0, h, th):
            for x0 in range(0, w, tw):
                layer.paste(unit, (x0, y0))
    if desat:
        layer = desaturate(layer)
    layer = tint(layer, color)
    paste(canvas, layer, l, t, blend)
    return (l, t, r, b)


def atlas_tex(art, canvas, name, rect, color=(1, 1, 1, 1), blend=None, desat=False, texbox=None):
    src, a = art.atlas(name)
    tile_x = snap(a["units"][0]) if a["tileH"] else None
    tile_y = snap(a["units"][1]) if a["tileV"] else None
    if texbox is not None:
        tile_x = tile_y = None
    return texture(canvas, src, rect, (tile_x, tile_y), color, blend, desat, texbox)


# Text ----------------------------------------------------------------------------------------------------


class Text:
    def __init__(self, art):
        self.art = art
        self.cut = []

    def width(self, obj, text):
        font, _ = self.art.font(obj)
        return font.getlength(text) / SUPER

    def fit(self, obj, text, width):
        if width is None or self.width(obj, text) <= width + 0.01:
            return text
        while text and self.width(obj, text + "...") > width:
            text = text[:-1]
        self.cut.append((obj, text + "..."))
        return text.rstrip() + "..."

    def draw(self, canvas, obj, text, box, justify="LEFT", color=None, nowrap=True, alpha=1.0):
        """Draws one line in box (canvas floats l t r b), centred vertically; returns (x0, x1) of the advance."""
        font, spec = self.art.font(obj)
        l, t, r, b = box
        if nowrap:
            text = self.fit(obj, text, r - l)
        width = self.width(obj, text)
        if justify == "LEFT":
            x = l
        elif justify == "RIGHT":
            x = r - width
        else:
            x = (l + r) / 2 - width / 2
        ascent, descent = font.getmetrics()
        baseline = (t + b) / 2 + (ascent - descent) / SUPER / 2
        x, baseline = snap(x), snap(baseline)
        mask, mx, my = self.mask(font, text, x, baseline)
        if mask is None:
            return x, x + width
        shadow = spec.get("shadow")
        if shadow:
            sr, sg, sb, sa = shadow["rgba"]
            self._ink(canvas, mask, mx + snap(shadow["x"]), my + snap(-shadow["y"]), (sr, sg, sb), sa * alpha)
        self._ink(canvas, mask, mx, my, color or spec["rgb"], alpha)
        return x, x + width

    def mask(self, font, text, x, baseline):
        """Coverage of the glyphs, drawn at SUPER times the size and box-filtered down, placed at whole pixels."""
        left, top, right, bottom = font.getbbox(text, anchor="ls")
        if right <= left or bottom <= top:
            return None, 0, 0
        x0, y0 = math.floor(left / SUPER) - 1, math.floor(top / SUPER) - 1
        x1, y1 = math.ceil(right / SUPER) + 1, math.ceil(bottom / SUPER) + 1
        big = Image.new("L", ((x1 - x0) * SUPER, (y1 - y0) * SUPER), 0)
        ImageDraw.Draw(big).text((-x0 * SUPER, -y0 * SUPER), text, font=font, anchor="ls", fill=255)
        return big.reduce(SUPER), x + x0, baseline + y0

    def _ink(self, canvas, mask, x, y, rgb, alpha):
        if alpha < 1:
            mask = mask.point(lambda v: int(round(v * alpha)))
        solid = Image.new("RGBA", mask.size, tuple(int(round(255 * c)) for c in rgb) + (255,))
        solid.putalpha(mask)
        paste(canvas, solid, x, y)


# The window ----------------------------------------------------------------------------------------------


class Window:
    def __init__(self, art, text, canvas, origin):
        self.art, self.text, self.canvas = art, text, canvas
        self.ox, self.oy = origin

    def P(self, x, y):
        """Window offsets (x right, y up from the top left, as SetPoint takes them) to canvas pixels."""
        return self.ox + x, self.oy - y

    def R(self, x0, y0, x1, y1):
        a = self.P(x0, y0)
        b = self.P(x1, y1)
        return (a[0], a[1], b[0], b[1])

    def tex(self, name, rect, **kw):
        return atlas_tex(self.art, self.canvas, name, rect, **kw)

    def file(self, path, rect, tile=False, **kw):
        src, f = self.art.file(path)
        period = (src.width, src.height) if tile else (None, None)
        return texture(self.canvas, src, rect, period, **kw)

    def units(self, name):
        return self.art.m["atlases"][name.lower()]["units"]

    # DefaultPanelTemplate (SharedUIPanelTemplates.xml:528-547): the rock, then the streaks.
    def background(self):
        self.file("Interface\\FrameGeneral\\UI-Background-Rock", self.R(6, -21, WIDTH - 2, -(HEIGHT - 2)), tile=True)
        self.tex("_UI-Frame-TopTileStreaks", self.R(6, -21, WIDTH - 2, -21 - 43))

    # InsetFrameTemplate (SharedUIPanelTemplates.xml:389-401, NineSliceLayouts.lua InsetFrameTemplate).
    def inset(self, l, t, r, b):
        self.file("Interface\\FrameGeneral\\UI-Background-Marble", (l, t, r, b), tile=True)
        self.nine_slice((l, t, r, b), {
            "TopLeftCorner": ("UI-Frame-InnerTopLeft", 0, 0), "TopRightCorner": ("UI-Frame-InnerTopRight", 0, 0),
            "BottomLeftCorner": ("UI-Frame-InnerBotLeftCorner", 0, -1), "BottomRightCorner": ("UI-Frame-InnerBotRight", 0, -1),
            "TopEdge": "_UI-Frame-InnerTopTile", "BottomEdge": "_UI-Frame-InnerBotTile",
            "LeftEdge": "!UI-Frame-InnerLeftTile", "RightEdge": "!UI-Frame-InnerRightTile",
        })

    def nine_slice(self, frame, layout, center=None):
        """NineSlice.lua ApplyLayout: corners at their points with offsets and atlas size, edges between them."""
        l, t, r, b = frame
        pieces = {}
        for key, point in (("TopLeftCorner", "TL"), ("TopRightCorner", "TR"), ("BottomLeftCorner", "BL"), ("BottomRightCorner", "BR")):
            name, dx, dy = layout[key]
            w, h = self.units(name)
            x = (l + dx) if point[1] == "L" else (r + dx - w)
            y = (t - dy) if point[0] == "T" else (b - dy - h)
            pieces[key] = (x, y, x + w, y + h)
        tl, tr, bl, br = pieces["TopLeftCorner"], pieces["TopRightCorner"], pieces["BottomLeftCorner"], pieces["BottomRightCorner"]
        th = self.units(layout["TopEdge"])[1]
        bh = self.units(layout["BottomEdge"])[1]
        lw = self.units(layout["LeftEdge"])[0]
        rw = self.units(layout["RightEdge"])[0]
        edges = {
            "TopEdge": (tl[2], tl[1], tr[0], tl[1] + th),
            "BottomEdge": (bl[2], bl[3] - bh, br[0], bl[3]),
            "LeftEdge": (tl[0], tl[3], tl[0] + lw, bl[1]),
            "RightEdge": (tr[2] - rw, tr[3], tr[2], br[1]),
        }
        if center:
            name, color = center
            self.tex(name, (tl[2] - 4, tl[3] - 4, br[0] + 4, br[1] + 4), color=color)
        for key in ("TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner"):
            self.tex(layout[key][0], pieces[key])
        for key in ("TopEdge", "BottomEdge", "LeftEdge", "RightEdge"):
            self.tex(layout[key], edges[key])

    # NineSliceLayouts.ButtonFrameTemplateNoPortrait with Camelot/NineSliceLayoutOverrides.lua applied.
    def border(self):
        self.nine_slice(self.R(0, 0, WIDTH, -HEIGHT), {
            "TopLeftCorner": ("UI-Frame-Metal-CornerTopLeft", -8, 16),
            "TopRightCorner": ("UI-Frame-Metal-CornerTopRight", 4 - 2, 16),
            "BottomLeftCorner": ("UI-Frame-Metal-CornerBottomLeft", -8, -8),
            "BottomRightCorner": ("UI-Frame-Metal-CornerBottomRight", 4 - 2, -8),
            "TopEdge": "_UI-Frame-Metal-EdgeTop", "BottomEdge": "_UI-Frame-Metal-EdgeBottom",
            "LeftEdge": "!UI-Frame-Metal-EdgeLeft", "RightEdge": "!UI-Frame-Metal-EdgeRight",
        })

    # TitleContainer TOPLEFT 30,-1 / TOPRIGHT -24,-1; TitleText TOP 0,-5, LEFT, RIGHT, GameFontNormal.
    def title(self, text):
        self.text.draw(self.canvas, "GameFontNormal", text, self.R(30, -6, WIDTH - 24, -18), "CENTER")

    # UIPanelCloseButtonDefaultAnchors, Camelot/SharedUIPanelTemplates.lua: 28 x 28 at TOPRIGHT 0, 3.
    def close(self):
        self.tex("RedButton-Exit", self.R(WIDTH - 28, 3, WIDTH, -25))

    # Window.lua BuildTiles: four columns 185 apart, lines at -60/-75/-95/-110, each 180 x 15.
    def tiles(self, tiles):
        for i, tile in enumerate(tiles):
            x = LEFT + i * 185
            self.text.draw(self.canvas, "GameFontNormal", tile["label"]["text"], self.R(x, -60, x + 180, -75))
            name = tile["name"]["text"]
            box = self.R(x, -75, x + 180, -90)
            prefix = "|T" + ALERT + ":16:16|t"
            if name.startswith(prefix):
                # The inline texture: 16 x 16 at the start of the line, centred on it.
                cy = (box[1] + box[3]) / 2
                self.file(ALERT, (box[0], cy - 8, box[0] + 16, cy + 8))
                box = (box[0] + 16, box[1], box[2], box[3])
                name = name[len(prefix):]
            self.text.draw(self.canvas, "GameFontHighlightMedium", name, box, color=tile["name"].get("color"))
            self.text.draw(self.canvas, "GameFontHighlight", tile["value"]["text"], self.R(x, -95, x + 180, -110),
                           color=tile["value"].get("color"))
            self.text.draw(self.canvas, "GameFontDisableSmall", tile["detail"]["text"], self.R(x, -110, x + 180, -125),
                           color=tile["detail"].get("color"))
        # Options_HorizontalDivider, atlas height, TOPLEFT 15,-128 to TOPRIGHT -15,-128.
        h = self.units("Options_HorizontalDivider")[1]
        self.tex("Options_HorizontalDivider", self.R(LEFT, -128, WIDTH - LEFT, -128 - h))

    # SearchBoxTemplate (InputBoxTemplates.xml:44-68, 175-235) at TOPRIGHT -15,-30, 160 x 20; the context line
    # LEFT at 15,-40, RIGHT 20 left of the box.
    def search_and_context(self, context):
        l, t, r, b = WIDTH - LEFT - 160, -30, WIDTH - LEFT, -50
        cy = (t + b) / 2
        self.tex("common-search-border-left", self.R(l - 5, cy + 10, l - 5 + 8, cy - 10))
        self.tex("common-search-border-right", self.R(r - 8, cy + 10, r, cy - 10))
        self.tex("common-search-border-middle", self.R(l - 5 + 8, cy + 10, r - 8, cy - 10))
        # Instructions: GameFontDisableSmall coloured 0.35, TOPLEFT 16,0 / BOTTOMRIGHT -20,0; the global SEARCH.
        self.text.draw(self.canvas, "GameFontDisableSmall", "Search", self.R(l + 16, t, r - 20, b), color=(0.35, 0.35, 0.35))
        # The magnifying glass: 10 x 10 at LEFT 1,-1, vertex colour 0.6 (SearchBoxTemplate_OnLoad).
        self.tex("common-search-magnifyingglass", self.R(l + 1, cy - 1 + 5, l + 11, cy - 1 - 5), color=(0.6, 0.6, 0.6, 1))
        self.text.draw(self.canvas, "GameFontHighlightSmall", context, self.R(LEFT, -35, l - 20, -45))

    # Window.lua BuildHeaders: ColumnDisplayButtonShortTemplate (SharedUIPanelTemplates.xml:1180-1219).
    def headers(self, headers):
        src, _ = self.art.file("Interface\\FriendsFrame\\WhoFrame-ColumnTabs")
        x = LEFT
        for header in headers:
            w = header["width"] + 2
            l, t, r, b = self.R(x, -135, x + w, -135 - 19)
            # TexCoords: Left 0-0.078125, Middle 0.078125-0.90625, Right 0.90625-0.96875; all 0-0.59375 high.
            texture(self.canvas, src, (l, t, l + 5, b), texbox=(0, 0, 5, 19))
            texture(self.canvas, src, (r - 4, t, r, b), texbox=(58, 0, 62, 19))
            texture(self.canvas, src, (l + 5, t, r - 4, b), texbox=(5, 0, 58, 19))
            cy = (t + b) / 2
            label = header["text"]
            width = self.text.width("GameFontHighlightSmall", label)
            if header["left"]:
                tl = l + 8
            else:
                tl = r - 10 - width
            self.text.draw(self.canvas, "GameFontHighlightSmall", label, (tl, cy - 5, tl + width, cy + 5))
            if header["arrow"]:
                aw, ah = self.units("auctionhouse-ui-sortarrow")
                ax = tl + width + 3 if header["left"] else tl - 3 - aw
                self.tex("auctionhouse-ui-sortarrow", (ax, cy - ah / 2, ax + aw, cy + ah / 2))
            x += header["width"]

    # Window.lua BuildRow/InitRow with Templates.xml AddonWeightRowTemplate.
    def rows(self, view, columns, hover=None):
        visible = (HEIGHT - 160 - 30) // ROW_HEIGHT
        for i, row in enumerate(view["rows"][:visible]):
            top = -160 - i * ROW_HEIGHT
            rl, rt, rr, rb = self.R(LEFT, top, WIDTH - 35, top - ROW_HEIGHT)
            self.tex(row["stripe"], (rl, rt, rr, rb))
            cy = (rt + rb) / 2
            x = rl
            cells = {}
            for column in columns:
                cells[column["key"]] = (x + 8, x + 8 + column["width"] - 16)
                x += column["width"]
            if row["bar"]:
                right = cells[view["sort"]][1] + 3
                texture(self.canvas, Image.new("RGBA", (1, 1), (255, 255, 255, 255)),
                        (right - row["bar"]["width"], cy - 7.5, right, cy + 7.5), color=(1, 1, 1, 0.1))
            for column in columns:
                key = column["key"]
                cell = row["cells"][key]
                l, r = cells[key]
                if key == "name":
                    r = l + cell["width"]
                if column["left"]:
                    self.text.draw(self.canvas, "GameFontHighlight", cell["text"], (l, rt, r, rb), "LEFT", cell["color"])
                else:
                    self.text.draw(self.canvas, "Number14FontWhite", cell["text"], (l, rt, r, rb), "RIGHT", cell["color"])
            if row["alert"]:
                ar = rl + columns[0]["width"] - 6
                self.file(ALERT, (ar - 16, cy - 8, ar, cy + 8))
            if hover is not None and i == hover:
                self.tex("auctionhouse-ui-row-highlight", (rl, rt, rr, rb), blend="ADD")
        return visible

    # MinimalScrollBar (MinimalScrollBar.xml) TOPLEFT/BOTTOMLEFT 10 right of the list; ScrollBar.lua Update.
    def scrollbar(self, count, visible):
        l, t, r, b = self.R(WIDTH - 35 + 10, -160, WIDTH - 35 + 18, -(HEIGHT - 30))
        cx = (l + r) / 2
        # Steppers 17 x 11 at TOP and BOTTOM; Back disabled (and desaturated) at the top of the list.
        self.tex("minimal-scrollbar-arrow-top", (cx - 8.5, t, cx + 8.5, t + 11), desat=True)
        self.tex("minimal-scrollbar-arrow-bottom", (cx - 8.5, b - 11, cx + 8.5, b))
        tt, tb = t + 19, b - 19
        cap = self.units("minimal-scrollbar-track-top")[1]
        self.tex("minimal-scrollbar-track-top", (l, tt, r, tt + cap))
        self.tex("minimal-scrollbar-track-bottom", (l, tb - cap, r, tb))
        self.tex("!minimal-scrollbar-track-middle", (l, tt + cap, r, tb - cap))
        extent = visible * ROW_HEIGHT / (count * ROW_HEIGHT)
        if extent < 1:
            thumb = max(23, (tb - tt) * extent)
            hb = tt + thumb
            cap = self.units("minimal-scrollbar-small-thumb-top")[1]
            self.tex("minimal-scrollbar-small-thumb-top", (l, tt, r, tt + cap))
            self.tex("minimal-scrollbar-small-thumb-bottom", (l, snap(hb) - cap, r, snap(hb)))
            src, a = self.art.atlas("minimal-scrollbar-small-thumb-middle")
            v = min(thumb / a["units"][1], 1)
            texture(self.canvas, src, (l, tt + cap, r, snap(hb) - cap), texbox=(0, 0, src.width, src.height * v))

    # SharedButtonSmallTemplate (ThreeSliceButtonTemplate.xml/.lua), 80 x 22, GameFontNormal.
    def button(self, label, x0, y0):
        l, t, r, b = self.R(x0, y0, x0 + 80, y0 - 22)
        h = b - t
        lw, lh = self.units("128-RedButton-Left")
        rw, _ = self.units("128-RedButton-Right")
        scale = h / lh
        left, right = lw * scale, rw * scale
        assert left + right <= r - l
        self.tex("128-RedButton-Left", (l, t, l + left, b))
        self.tex("128-RedButton-Right", (r - right, t, r, b))
        src, a = self.art.atlas("_128-RedButton-Center")
        # The centre is not scaled: it tiles at the atlas width and is squeezed to the button's height.
        texture(self.canvas, src, (l + left, t, r - right, b), (snap(a["units"][0]), None))
        self.text.draw(self.canvas, "GameFontNormal", label, (l, t, r, b), "CENTER")

    def buttons(self):
        # Reset BOTTOMLEFT 4,4; Copy Text at its BOTTOMRIGHT; Settings BOTTOMRIGHT -4,4.
        bottom = -(HEIGHT - 4 - 22)
        self.button("Reset", 4, bottom)
        self.button("Copy Text", 84, bottom)
        self.button("Settings", WIDTH - 4 - 80, bottom)

    # PanelTabButtonTemplate (SharedUIPanelTemplates.xml:932-1004) and PanelTemplates_TabResize/SelectTab.
    def tabs(self, labels, selected):
        x = 11
        top = -(HEIGHT - 2)
        lw = self.units("uiframe-tab-left")[0]
        rw = self.units("uiframe-tab-right")[0]
        for i, label in enumerate(labels, 1):
            width = max(self.text.width("GameFontNormalSmall", label) + 20, lw + rw)
            l, t, r, b = self.R(x, top, x + width, top - 32)
            if i == selected:
                left, right, mid, dl, dr = "uiframe-activetab-left", "uiframe-activetab-right", "_uiframe-activetab-center", -1, 8
            else:
                left, right, mid, dl, dr = "uiframe-tab-left", "uiframe-tab-right", "_uiframe-tab-center", -3, 7
            aw, ah = self.units(left)
            bw, _ = self.units(right)
            self.tex(left, (l + dl, t, l + dl + aw, t + ah))
            self.tex(right, (r + dr - bw, t, r + dr, t + ah))
            self.tex(mid, (l + dl + aw, t, r + dr - bw, t + ah))
            cy = (t + b) / 2 + (3 if i == selected else -2)
            tw = self.text.width("GameFontNormalSmall", label)
            cx = (l + r) / 2
            font = "GameFontHighlightSmall" if i == selected else "GameFontNormalSmall"
            self.text.draw(self.canvas, font, label, (cx - tw / 2, cy - 5, cx + tw / 2, cy + 5), "CENTER")
            x += width + 3

    def draw(self, view, columns, hover=None):
        self.background()
        self.inset(*self.R(9, -153, WIDTH - 6, -(HEIGHT - 26)))
        self.tiles(view["tiles"])
        self.search_and_context(view["context"])
        self.headers(view["headers"])
        visible = self.rows(view, columns, hover)
        self.scrollbar(len(view["rows"]), visible)
        self.buttons()
        self.tabs(view["tabs"], view["selectedTab"])
        self.border()
        self.title(view["title"])
        self.close()


# The tooltip ---------------------------------------------------------------------------------------------


PAD, GAP, DOUBLE_GAP = 10, 2, 20


def wrap(text_obj, obj, text, width):
    words, lines, line = text.split(" "), [], ""
    for word in words:
        trial = word if not line else line + " " + word
        if text_obj.width(obj, trial) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    lines.append(line)
    return lines


def tooltip_layout(text, lines):
    """(width, height, [(kind, obj, y offset, payload)]) for GameTooltip's lines."""
    width = 0
    for line in lines:
        if line["kind"] == "header":
            width = max(width, text.width("GameTooltipHeaderText", line["text"]))
        elif line["kind"] == "double":
            width = max(width, text.width("GameTooltipText", line["left"]) + DOUBLE_GAP + text.width("GameTooltipText", line["right"]))
        elif not line.get("wrap"):
            width = max(width, text.width("GameTooltipText", line["text"]))
    placed, y = [], PAD
    for line in lines:
        obj = "GameTooltipHeaderText" if line["kind"] == "header" else "GameTooltipText"
        h = text.art.font(obj)[1]["height"]
        if line["kind"] == "line" and line.get("wrap") and text.width(obj, line["text"]) > width:
            parts = wrap(text, obj, line["text"], width)
        else:
            parts = [line.get("text")]
        for part in parts:
            placed.append((line, obj, y, part))
            y += h + GAP
    height = int(round(y - GAP + PAD))
    return math.ceil(width) + 2 * PAD, height, placed


def draw_tooltip(art, text, canvas, rect, layout):
    l, t, r, b = rect
    _, _, placed = layout
    bg = art.m["colors"]["TOOLTIP_DEFAULT_BACKGROUND_COLOR"]
    win = Window(art, text, canvas, (0, 0))
    win.nine_slice((l, t, r, b), {
        "TopLeftCorner": ("Tooltip-NineSlice-CornerTopLeft", 0, 0), "TopRightCorner": ("Tooltip-NineSlice-CornerTopRight", 0, 0),
        "BottomLeftCorner": ("Tooltip-NineSlice-CornerBottomLeft", 0, 0), "BottomRightCorner": ("Tooltip-NineSlice-CornerBottomRight", 0, 0),
        "TopEdge": "_Tooltip-NineSlice-EdgeTop", "BottomEdge": "_Tooltip-NineSlice-EdgeBottom",
        "LeftEdge": "!Tooltip-NineSlice-EdgeLeft", "RightEdge": "!Tooltip-NineSlice-EdgeRight",
    }, center=("Tooltip-NineSlice-Center", (bg[0], bg[1], bg[2], 1)))
    for line, obj, y, part in placed:
        h = art.font(obj)[1]["height"]
        box_t = t + y
        if line["kind"] == "double":
            text.draw(canvas, obj, line["left"], (l + PAD, box_t, r - PAD, box_t + h), "LEFT", line["leftColor"], nowrap=False)
            text.draw(canvas, obj, line["right"], (l + PAD, box_t, r - PAD, box_t + h), "RIGHT", line["rightColor"], nowrap=False)
        elif part and part.strip():
            text.draw(canvas, obj, part, (l + PAD, box_t, r - PAD, box_t + h), "LEFT", line.get("color") or WHITE, nowrap=False)


# Composition ---------------------------------------------------------------------------------------------

CANVAS_WIDTH = 840
BACKDROP = (17, 17, 19, 255)
CAPTION_GAP = 16


def window_bounds(art, text, view, columns):
    """The drawn window's pixel bounds relative to its top left, from a trial render."""
    pad = 200
    scene = Image.new("RGBA", (WIDTH + 2 * pad, HEIGHT + 2 * pad), (0, 0, 0, 0))
    Window(art, text, scene, (pad, pad)).draw(view, columns)
    box = scene.getchannel("A").point(lambda v: 255 if v >= 16 else 0).getbbox()
    return box[0] - pad, box[1] - pad, box[2] - pad, box[3] - pad


def caption_draw(art, text, canvas, caption, top):
    w = text.width("GameFontHighlightMedium", caption)
    x = (canvas.width - w) / 2
    text.draw(canvas, "GameFontHighlightMedium", caption, (x, top, x + w, top + 14), "LEFT", color=(0.85, 0.85, 0.85))


def compose(art, text, view, columns, bounds, caption, hover=None, tooltip=None):
    bl, bt, br, bb = bounds
    margin = (CANVAS_WIDTH - (br - bl)) // 2
    ox, oy = margin - bl, margin - bt
    tip_rect = None
    content_bottom = oy + bb
    if tooltip is not None:
        layout = tooltip_layout(text, tooltip["lines"])
        tw, th = layout[0], layout[1]
        # ANCHOR_RIGHT: the tooltip's BOTTOMLEFT at the row's TOPRIGHT; clamped inside the image's margin.
        row_top = -160 - (tooltip["row"] - 1) * ROW_HEIGHT
        left = ox + WIDTH - 35
        if left + tw > CANVAS_WIDTH - margin:
            left = CANVAS_WIDTH - margin - tw
        bottom_rel = -row_top
        if oy + bottom_rel - th < margin:
            oy = margin + th - bottom_rel
        tip_rect = (left, oy + bottom_rel - th, left + tw, oy + bottom_rel)
        content_bottom = oy + bb
    height = content_bottom + (CAPTION_GAP + 14 if caption else 0) + margin
    canvas = Image.new("RGBA", (CANVAS_WIDTH, height), BACKDROP)
    Window(art, text, canvas, (ox, oy)).draw(view, columns, hover)
    if tip_rect:
        draw_tooltip(art, text, canvas, tip_rect, layout)
    if caption:
        caption_draw(art, text, canvas, caption, content_bottom + CAPTION_GAP)
    return canvas.convert("RGB"), (ox, oy), tip_rect


def main():
    root = os.getcwd()
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, ".cache", "addon-weight-render")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "art", "screens")
    with open(os.path.join(cache, "dump.json")) as handle:
        dump = json.load(handle)
    art = Art(cache)
    text = Text(art)
    views = dump["views"]
    columns = [{"key": h["key"], "width": h["width"], "left": h["left"]} for h in views["session"]["headers"]]
    bounds = window_bounds(art, text, views["session"], columns)
    os.makedirs(out, exist_ok=True)
    shots = [
        ("1-session.png", views["session"], "Every addon's frame time, hitches, memory and load time, heaviest first.", None, None),
        ("2-all-time.png", views["all"], "Figures are kept across sessions; removed addons can be kept or forgotten.", None, None),
        ("3-tooltip.png", views["sorted"], "Hover a row for everything measured about that addon.",
         dump["tooltip"]["row"] - 1, dump["tooltip"]),
    ]
    for name, view, caption, hover, tip in shots:
        text.cut = []
        img, origin, tip_rect = compose(art, text, view, columns, bounds, caption, hover, tip)
        path = os.path.join(out, name)
        img.save(path, optimize=True)
        print(f"{path}: {img.width} x {img.height}, window at {origin}" + (f", tooltip {tip_rect}" if tip_rect else ""))
        for obj, cut in text.cut:
            print(f"  cut to fit: {cut!r} ({obj})")
    print("art:")
    for name in sorted(art.used):
        print(f"  {name}: {art.used[name]}")
    print("guesses:")
    for g in GUESSES:
        print(f"  - {g}")


if __name__ == "__main__":
    main()
