#!/usr/bin/env python
"""Generate app/app.ico programmatically (no image tooling required).

Draws a simple fan glyph into 32-bit BGRA bitmaps at several sizes and packs
them into a valid .ico (BMP/BI_RGB entries + 1-bit AND mask).
"""
import math
import struct
import sys
from pathlib import Path

SIZES = [16, 24, 32, 48, 64, 128]
DARK = (18, 24, 33)
CYAN = (34, 211, 238)
CYAN_DIM = (14, 116, 144)
WHITE = (235, 245, 250)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * max(0.0, min(1.0, t)))) for i in range(3))


def sample(size, x, y):
    """Return (r,g,b,a) for pixel (x,y) of an icon of edge `size`."""
    cx = cy = (size - 1) / 2.0
    r = (x - cx) ** 2 + (y - cy) ** 2
    dist = math.sqrt(r)
    radius = size * 0.46
    px = x - cx
    py = y - cy
    ang = math.atan2(py, px)

    # rounded-square backdrop, transparent outside
    corner = size * 0.22
    dx = max(abs(px) - (size / 2.0 - corner), 0.0)
    dy = max(abs(py) - (size / 2.0 - corner), 0.0)
    box_d = math.hypot(dx, dy)
    edge = size / 2.0 - corner + corner
    if box_d > corner + 0.5:
        return (0, 0, 0, 0)

    col = lerp((26, 34, 47), DARK, min(1.0, box_d / max(1e-6, corner)))

    hub = size * 0.115
    outer = size * 0.44
    if dist < hub:
        col = lerp(CYAN_DIM, WHITE, 1.0 - dist / hub)
    elif dist < outer:
        # four curved blades: brightness follows angle + blade thickness by radius
        blades = 4
        a = (ang * blades) % (2 * math.pi)
        curve = a / (2 * math.pi)
        span = 0.42
        in_blade = curve < span
        # swirl: blade boundary rotates with radius
        swirl = (0.16 * (dist / outer))
        in_blade = ((curve - swirl) % 1.0) < span
        taper = 0.18 + 0.82 * ((dist - hub) / max(1e-6, (outer - hub)))
        if in_blade and taper > 0.0:
            shade = 0.55 + 0.45 * math.sin(min(1.0, taper) * math.pi)
            col = lerp(CYAN_DIM, CYAN, shade)
        else:
            col = lerp((22, 30, 42), (12, 17, 24), dist / outer)
        ring = abs(dist - outer)
        if ring < max(1.0, size * 0.028):
            col = lerp(col, CYAN, 0.85)
    return (col[0], col[1], col[2], 255)


def render(size):
    """Bottom-up BGRA pixel rows + 1-bit AND mask."""
    pixels = bytearray()
    for y in range(size - 1, -1, -1):          # BMP stores bottom-up
        for x in range(size):
            r, g, b, a = sample(size, x, y)
            pixels += bytes((b, g, r, a))
    row_bytes = ((size + 31) // 32) * 4
    mask = bytearray()
    for _ in range(size):                       # AND mask: 0 = opaque (we use full alpha)
        mask += b"\x00" * row_bytes
    return bytes(pixels), bytes(mask)


def ico_entry(size, dib, mask, offset):
    bmp = struct.pack(
        "<IiiHHIIiiII",
        40,            # biSize
        size,          # biWidth
        size * 2,      # biHeight  (XOR image + AND mask)
        1,             # biPlanes
        32,            # biBitCount
        0,             # BI_RGB
        len(dib) + len(mask),
        0, 0, 0, 0,
    )
    data = bmp + dib + mask
    w = 0 if size >= 256 else size
    h = 0 if size >= 256 else size
    header = struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset)
    return header, data


def build(dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    images = []
    for s in SIZES:
        dib, mask = render(s)
        images.append((s, dib, mask))
    count = len(images)
    out = bytearray(struct.pack("<HHH", 0, 1, count))
    offset = 6 + 16 * count
    headers = []
    bodies = []
    for s, dib, mask in images:
        hdr, data = ico_entry(s, dib, mask, offset)
        headers.append(hdr)
        bodies.append(data)
        offset += len(data)
    for h in headers:
        out += h
    for b in bodies:
        out += b
    dst.write_bytes(bytes(out))
    return len(out)


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "app" / "app.ico"
    n = build(target)
    print(f"wrote {target} ({n} bytes, sizes={SIZES})")
