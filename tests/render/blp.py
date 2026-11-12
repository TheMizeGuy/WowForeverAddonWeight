"""BLP2 decoder covering every encoding the WoW client ships.

Pillow 12.3 decodes BLP2 DXT correctly but reads palettized BLP2 alpha from the palette
entries (the format keeps alpha in a separate plane after the indices) and rejects
encoding 3 (raw BGRA). This module decodes all three and reports the header.
"""

import struct

from PIL import Image
from PIL.BlpImagePlugin import decode_dxt1, decode_dxt3, decode_dxt5

ALPHA_TYPES = {0: "DXT1", 1: "DXT3", 7: "DXT5"}
ENCODINGS = {1: "palettized", 2: "DXT", 3: "raw BGRA"}


def header(data):
    if data[:4] != b"BLP2":
        raise ValueError(f"not BLP2: {data[:4]!r}")
    kind, encoding, alpha_depth, alpha_type, mips = struct.unpack_from("<I4B", data, 4)
    width, height = struct.unpack_from("<II", data, 12)
    offsets = struct.unpack_from("<16I", data, 20)
    lengths = struct.unpack_from("<16I", data, 84)
    return {
        "magic": "BLP2",
        "type": kind,
        "encoding": encoding,
        "encodingName": ENCODINGS.get(encoding, "unknown"),
        "alphaDepth": alpha_depth,
        "alphaType": alpha_type,
        "alphaTypeName": ALPHA_TYPES.get(alpha_type, "n/a") if encoding == 2 else "n/a",
        "mipsByte": mips,
        "width": width,
        "height": height,
        "mipCount": sum(1 for o, n in zip(offsets, lengths) if o and n),
        "offset0": offsets[0],
        "length0": lengths[0],
    }


def decode(data):
    h = header(data)
    w, ht = h["width"], h["height"]
    start, length = h["offset0"], h["length0"]
    body = data[start:start + length]
    enc = h["encoding"]
    if enc == 1:
        palette = [struct.unpack_from("<4B", data, 148 + 4 * i) for i in range(256)]
        count = w * ht
        indices = body[:count]
        plane = body[count:]
        depth = h["alphaDepth"]
        out = bytearray()
        for i, index in enumerate(indices):
            b, g, r, _ = palette[index]
            if depth == 0:
                a = 255
            elif depth == 1:
                a = 255 if (plane[i >> 3] >> (i & 7)) & 1 else 0
            elif depth == 4:
                nibble = (plane[i >> 1] >> (4 * (i & 1))) & 0xF
                a = nibble * 17
            elif depth == 8:
                a = plane[i]
            else:
                raise ValueError(f"alpha depth {depth}")
            out += bytes((r, g, b, a))
        return Image.frombytes("RGBA", (w, ht), bytes(out)), h
    if enc == 2:
        at = h["alphaType"]
        out = bytearray()
        pos = 0
        blocks_per_row = (w + 3) // 4
        if at == 0:
            linesize = blocks_per_row * 8
            mode = "RGBA"
            for _ in range((ht + 3) // 4):
                for row in decode_dxt1(body[pos:pos + linesize], alpha=h["alphaDepth"] > 0):
                    out += row if h["alphaDepth"] > 0 else _rgb_to_rgba(row)
                pos += linesize
        elif at in (1, 7):
            linesize = blocks_per_row * 16
            fn = decode_dxt3 if at == 1 else decode_dxt5
            for _ in range((ht + 3) // 4):
                for row in fn(body[pos:pos + linesize]):
                    out += row
                pos += linesize
        else:
            raise ValueError(f"alpha type {at}")
        padded_w = blocks_per_row * 4
        img = Image.frombytes("RGBA", (padded_w, ((ht + 3) // 4) * 4), bytes(out))
        return img.crop((0, 0, w, ht)), h
    if enc == 3:
        raw = body[: w * ht * 4]
        img = Image.frombytes("RGBA", (w, ht), raw, "raw", "BGRA")
        return img, h
    raise ValueError(f"encoding {enc}")


def _rgb_to_rgba(row):
    out = bytearray()
    for i in range(0, len(row), 3):
        out += row[i:i + 3] + b"\xff"
    return bytes(out)
