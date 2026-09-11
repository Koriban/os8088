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


def _slot(rows, x, y, skip):
    """The 8x8 at (x, y) as glyph bytes, with the columns in `skip` (the
    gridlines) cleared rather than read."""
    out = bytearray(8)
    for r in range(8):
        b = 0
        for c in range(8):
            if x + c not in skip and not rows[y + r][x + c]:
                b |= 0x80 >> c
        out[r] = b
    return bytes(out)


def _match(g, table, skip_cols):
    if g in table:
        return table[g]
    if not skip_cols:
        return None
    mask = 0xFF
    for c in skip_cols:
        mask &= ~(0x80 >> c) & 0xFF
    for k, ch in table.items():
        if all((a & mask) == (b & mask) for a, b in zip(g, k)):
            return ch
    return None


def cell_text(rows, box, table, lines=()):
    """The text a cell shows, spaces stripped, or None if nothing in it reads
    as glyphs. The run is found, not assumed: every x within a glyph's width
    of the cell's left line and every y inside it is tried, and the placing
    whose slots ALL match a glyph, with the most ink, wins. `lines` are the
    column lines, masked out of any slot they cross - SHEET draws them after
    the text."""
    x1, y1, x2, y2 = box
    skip = set(lines)
    best = None
    for y in range(y1 + 1, y2 - 7):
        for x in range(x1 - 2, x1 + 6):
            n = (x2 + 1 - x) // 8
            out, weight = [], 0
            for k in range(n):
                sx = x + 8 * k
                cols = [c for c in range(8) if sx + c in skip]
                g = _slot(rows, sx, y, skip)
                ch = _match(g, table, cols)
                if ch is None:
                    break
                out.append(ch)
                weight += sum(bin(v).count("1") for v in g)
            else:
                text = "".join(out).strip()
                if text and (best is None or weight > best[0]):
                    best = (weight, text)
    return best[1] if best else None
