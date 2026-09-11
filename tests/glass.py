"""Reading SHEET's grid off the glass - where its lines are, and what text a
cell SHOWS - for gates whose subject is what is drawn rather than what is
stored (SPEC.md 81.54, 81.55).

The screen is m.vram()'s 1bpp picture, in which ink is 0. The glyphs are the
kernel's own (`font_glyphs`, 32..126, eight bytes a glyph, bit 7 the left
pixel, 1 ink): whatever the BIOS handed font_init is what the grid was drawn
with, so a match is exact and there is no font file to keep in step.
"""

FONT_FIRST, FONT_N = 32, 95


def glyphs(m):
    """{8-byte glyph: character} from the running kernel."""
    raw = m.read(m.sym("font_glyphs"), FONT_N * 8)
    out = {}
    for i in range(FONT_N):
        g = bytes(raw[i * 8:i * 8 + 8])
        out.setdefault(g, chr(FONT_FIRST + i))   # the first of any duplicates
    return out


def grid(w, h, rows):
    """(row boundaries, column boundaries) of the grid, or None. The rows are
    the longest evenly spaced run of horizontal lines; the columns are the
    vertical lines unbroken through all of those rows, which no glyph can be,
    starting at the first gap of the commonest width (column A)."""
    lines = [y for y in range(h)
             if sum(1 for x in range(120, 580) if not rows[y][x]) > 440]
    best = []
    for i in range(len(lines)):
        for j in range(i + 1, len(lines)):
            d = lines[j] - lines[i]
            if not 10 <= d <= 24:
                continue
            run = [lines[i]]
            while run[-1] + d in lines:
                run.append(run[-1] + d)
            if len(run) > len(best):
                best = run
    if len(best) < 3:
        return None
    y1, y2 = best[0], best[-1]
    cols = [x for x in range(w)
            if all(not rows[y][x] for y in range(y1, y2 + 1))]
    cols = [x for k, x in enumerate(cols) if k == 0 or x != cols[k - 1] + 1]
    gaps = [b - a for a, b in zip(cols, cols[1:])]
    width = max(set(gaps), key=gaps.count)
    first = next(k for k, g in enumerate(gaps) if g == width)
    return best, cols[first:]


def ink(rows, box, part=1.0):
    """Ink pixels inside a cell, two pixels in from its lines; `part` keeps
    only that fraction of it from the left."""
    x1, y1, x2, y2 = box
    x2 = x1 + int((x2 - x1) * part)
    return sum(1 for y in range(y1 + 2, y2 - 1)
               for x in range(x1 + 2, x2 - 1) if not rows[y][x])


def _slot(rows, x, y, skip, hskip):
    """The 8x8 at (x, y) as glyph bytes, with the gridline columns (`skip`)
    and rows (`hskip`) cleared rather than read - SHEET draws the lines after
    the text, and a glyph's top row lies on its cell's upper line."""
    out = bytearray(8)
    for r in range(8):
        if y + r in hskip:
            continue
        b = 0
        for c in range(8):
            if x + c not in skip and not rows[y + r][x + c]:
                b |= 0x80 >> c
        out[r] = b
    return bytes(out)


def _match(g, table, cols, lrows):
    """The character whose glyph agrees with `g` everywhere but the masked
    columns and rows, or None."""
    if not cols and not lrows and g in table:
        return table[g]
    cmask = 0xFF
    for c in cols:
        cmask &= ~(0x80 >> c) & 0xFF
    for k, ch in table.items():
        if all((a & cmask) == (b & cmask) for r, (a, b) in enumerate(zip(g, k))
               if r not in lrows):
            return ch
    return None


def cell_text(rows, box, table, lines=(), hlines=()):
    """The text a cell shows, spaces stripped, or None if nothing in it reads
    as glyphs. The run is found, not assumed: every placing within a glyph of
    the cell's corner is tried, and the one whose slots ALL match a glyph,
    with the most ink, wins. `lines` and `hlines` are the grid's columns and
    rows, masked out of any slot they cross. Read an UNSELECTED cell: the
    selection's heavier border is a line this does not know about."""
    x1, y1, x2, y2 = box
    skip, hskip = set(lines), set(hlines)
    best = None
    for y in range(y1 - 1, y2 - 6):
        lrows = [r for r in range(8) if y + r in hskip]
        for x in range(x1 - 2, x1 + 6):
            n = (x2 + 1 - x) // 8
            out, weight = [], 0
            for k in range(n):
                sx = x + 8 * k
                cols = [c for c in range(8) if sx + c in skip]
                g = _slot(rows, sx, y, skip, hskip)
                ch = _match(g, table, cols, lrows)
                if ch is None:
                    break
                out.append(ch)
                weight += sum(bin(v).count("1") for v in g)
            else:
                text = "".join(out).strip()
                if text and (best is None or weight > best[0]):
                    best = (weight, text)
    return best[1] if best else None
