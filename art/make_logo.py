"""Project logo for Addon Weight: a gold balance beam tipped down by one big red block with an
alert mark, three small white blocks riding high on the other end, on a dark disc. 400x400,
drawn at 4x and downsampled for smooth edges.

Usage: python3 -I -B art/make_logo.py art/logo.png
"""
import sys

from PIL import Image, ImageDraw

S = 4
W = 400 * S
gold, dark_gold = (232, 183, 74, 255), (168, 120, 38, 255)
red, white = (230, 60, 60, 255), (240, 236, 224, 255)
disc = (27, 32, 43, 255)


def P(*v):
    return tuple(round(x * S) for x in v)


img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.ellipse((8 * S, 8 * S, W - 8 * S, W - 8 * S), fill=disc, outline=(64, 74, 92, 255), width=6 * S)

# Shifted left of centre so the red block's weight sits balanced in the disc.
cx, cy, ground = 190, 202, 310

# stand
d.polygon([P(cx, cy), P(cx + 54, ground), P(cx - 54, ground)], fill=dark_gold)
d.rounded_rectangle(P(cx - 92, ground - 6, cx + 92, ground + 16), radius=11 * S, fill=dark_gold)

# The beam and its loads, drawn level, then tipped about the pivot.
beam = Image.new("RGBA", (W, W), (0, 0, 0, 0))
b = ImageDraw.Draw(beam)
half, th = 138, 22
top = cy - th / 2
b.rounded_rectangle(P(cx - half, top, cx + half, cy + th / 2), radius=6 * S, fill=gold)
# the light ones
x, light = cx - half + 6, 30
for _ in range(3):
    b.rounded_rectangle(P(x, top - light, x + light, top + 2), radius=5 * S, fill=white)
    x += light + 8
# the heavy one, with an alert mark cut from the disc colour
heavy = 106
x1 = cx + half - 6
x0 = x1 - heavy
b.rounded_rectangle(P(x0, top - heavy, x1, top + 2), radius=12 * S, fill=red)
mx, mw = (x0 + x1) / 2, 20
b.rounded_rectangle(P(mx - mw / 2, top - 92, mx + mw / 2, top - 44), radius=mw / 2 * S, fill=disc)
b.ellipse(P(mx - 12, top - 36, mx + 12, top - 12), fill=disc)
# pivot
b.ellipse(P(cx - 16, cy - 16, cx + 16, cy + 16), fill=gold)
b.ellipse(P(cx - 6, cy - 6, cx + 6, cy + 6), fill=dark_gold)
img.alpha_composite(beam.rotate(-15, resample=Image.BICUBIC, center=(cx * S, cy * S)))

img.resize((400, 400), Image.LANCZOS).save(sys.argv[1])
