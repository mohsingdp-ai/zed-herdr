# Builds czr-status.ttf: the status icons zed-autoresume.sh puts at the start
# of Zed thread titles, in Herdr's status colors.
#   uv run --with fonttools python shell/czr-status-font.py
#
# Zed (Linux) draws glyphs in color only for a font whose PostScript name is
# "NotoColorEmoji"; every other font gets its faint text color. So this font
# carries that PostScript name, under its own family name, and only covers
# plane-16 private code points (U+100000...), which no real emoji, letter or
# Nerd Font icon uses.
# ponytail: leans on Zed's emoji-font check by name; if Zed changes it, the
# icons turn gray, nothing breaks.

import math
import sys
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables import otTables  # noqa: F401  (registers COLR/CPAL)
from fontTools.colorLib.builder import buildCOLR, buildCPAL

UPM = 1000
ADV = 760
CX, CY = ADV / 2, 330  # icon center: about where a text ● sits

# Herdr's palette (src/client/shell.rs status_color): green idle, yellow
# working, red blocked, teal done, gray unknown.
COLORS = {
    "green": "#8bc56a", "yellow": "#e5c07b", "red": "#e06c75",
    "teal": "#56b6c2", "gray": "#7c828d",
}

# Code points the script writes; keep in sync with zed-autoresume.sh.
IDLE, BLOCKED, DONE, UNKNOWN = 0x100000, 0x100001, 0x100002, 0x100003
WORKING = [0x100010 + i for i in range(8)]


def circle(r, steps=48, cw=True, cx=CX, cy=CY):
    pts = [(cx + r * math.cos(2 * math.pi * i / steps), cy + r * math.sin(2 * math.pi * i / steps)) for i in range(steps)]
    return pts[::-1] if cw else pts  # TrueType: outer contours clockwise


def stroke(points, w):
    """Outline of a polyline stroke of width w with mitred joins; returned counterclockwise (a hole)."""
    def off(p, q, d):
        dx, dy = q[0] - p[0], q[1] - p[1]
        n = math.hypot(dx, dy)
        return (-dy / n * d, dx / n * d)
    left, right = [], []
    for i, p in enumerate(points):
        segs = []
        if i > 0:
            segs.append(off(points[i - 1], p, w / 2))
        if i < len(points) - 1:
            segs.append(off(p, points[i + 1], w / 2))
        nx = sum(s[0] for s in segs) / len(segs)
        ny = sum(s[1] for s in segs) / len(segs)
        if len(segs) == 2:  # mitre: scale the averaged normal back to width
            k = (w / 2) ** 2 / max(nx * nx + ny * ny, 1e-9)
            nx, ny = nx * k, ny * k
        left.append((p[0] + nx, p[1] + ny))
        right.append((p[0] - nx, p[1] - ny))
    poly = left + right[::-1]
    # make it counterclockwise (signed area > 0) so it cuts a hole
    area = sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly)))
    return poly if area > 0 else poly[::-1]


def glyph(contours):
    pen = TTGlyphPen(None)
    for c in contours:
        pen.moveTo(tuple(map(round, c[0])))
        for p in c[1:]:
            pen.lineTo(tuple(map(round, p)))
        pen.closePath()
    return pen.glyph()


R = 350          # outer radius: a bit bigger than a text ●
RING_W = 130     # ring thickness
S = R * 0.42     # check / cross reach

shapes = {
    "idle": [circle(R), circle(R - RING_W, cw=False)],
    "blocked": [circle(R), stroke([(CX - S, CY + S), (CX + S, CY - S)], 85),
                stroke([(CX - S, CY - S), (CX - 22, CY - 22)], 85),
                stroke([(CX + 22, CY + 22), (CX + S, CY + S)], 85)],
    "done": [circle(R), stroke([(CX - S * 1.05, CY + S * 0.05), (CX - S * 0.25, CY - S * 0.75), (CX + S * 1.05, CY + S * 0.7)], 85)],
    "unknown": [circle(R * 0.38)],
}
# Working: the heavy braille spinner ⣾⣽⣻⢿⡿⣟⣯⣷, eight dots in a 2x4 braille
# cell with one gap walking around it (left column down, right column up).
BX, BY, BR = 165, (300, 100, -100, -300), 95  # column offset, row offsets (top first), dot radius
dots = {1: (-BX, BY[0]), 2: (-BX, BY[1]), 3: (-BX, BY[2]), 7: (-BX, BY[3]),
        4: (BX, BY[0]), 5: (BX, BY[1]), 6: (BX, BY[2]), 8: (BX, BY[3])}
for i, gap in enumerate([1, 2, 3, 7, 8, 6, 5, 4]):
    shapes[f"spin{i}"] = [circle(BR, 24, cx=CX + x, cy=CY + y) for d, (x, y) in dots.items() if d != gap]

# One size knob for all icons: scales every shape around the icon center.
SIZE = 1.2
EXTRA = {"blocked": 1.12, "done": 1.12}  # filled dots read smaller than the ring
shapes = {n: [[(CX * SIZE + (x - CX) * SIZE * EXTRA.get(n, 1), CY + (y - CY) * SIZE * EXTRA.get(n, 1)) for x, y in c] for c in cs]
          for n, cs in shapes.items()}
ADV = round(ADV * SIZE)

glyph_order = [".notdef", "space"] + list(shapes)
glyphs = {".notdef": glyph([]), "space": glyph([])}
glyphs.update({name: glyph(c) for name, c in shapes.items()})

cmap = {0x20: "space", IDLE: "idle_c", BLOCKED: "blocked_c", DONE: "done_c", UNKNOWN: "unknown_c"}
cmap.update({cp: f"working{i}_c" for i, cp in enumerate(WORKING)})

# Colored base glyphs: an empty outline whose COLR layers are the shapes above.
for name in ["idle_c", "blocked_c", "done_c", "unknown_c"] + [f"working{i}_c" for i in range(8)]:
    glyph_order.append(name)
    glyphs[name] = glyph([])

def rgba(hexcolor):
    h = hexcolor.lstrip("#")
    return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, 1.0)

palette = [rgba(COLORS["green"]), rgba(COLORS["yellow"]), rgba(COLORS["red"]),
           rgba(COLORS["teal"]), rgba(COLORS["gray"])]
GREEN, YELLOW, RED, TEAL, GRAY = range(5)
layers = {
    "idle_c": [("idle", GREEN)],
    "blocked_c": [("blocked", RED)],
    "done_c": [("done", TEAL)],
    "unknown_c": [("unknown", GRAY)],
}
for i in range(8):
    layers[f"working{i}_c"] = [(f"spin{i}", YELLOW)]

fb = FontBuilder(UPM, isTTF=True)
fb.setupGlyphOrder(glyph_order)
fb.setupCharacterMap(cmap)
fb.setupGlyf(glyphs)
fb.setupHorizontalMetrics({g: (ADV if g != ".notdef" else 500, 0) for g in glyph_order})
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({
    "familyName": "CZR Status Icons",
    "styleName": "Regular",
    "uniqueFontIdentifier": "CZR Status Icons Regular",
    "fullName": "CZR Status Icons",
    "psName": "NotoColorEmoji",  # see the top of this file
})
fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
fb.setupPost()
fb.font["COLR"] = buildCOLR(layers, version=0)
fb.font["CPAL"] = buildCPAL([palette])

out = sys.argv[1] if len(sys.argv) > 1 else "czr-status.ttf"
fb.save(out)
print(out)
