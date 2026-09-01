#!/usr/bin/env python3
"""os88imgcase: build apps/os88img.inc's test corpus and its expectations.

    python3 tools/os88imgcase.py            write build/imgcases/ and the .inc
    python3 tools/os88imgcase.py --check    exit 1 if the .inc would change

WHY THIS EXISTS AND WHY IT IS PYTHON. apps/os88img.inc decodes three file
formats, and a decoder is the classic thing that passes its own test: write
the encoder and the decoder from the same understanding and they agree with
each other about a format neither of them has got right. So the expectations
here are computed from the FORMAT DOCUMENTS - ZSoft's Technical Reference
Manual revision 5 for PCX, the BITMAPINFOHEADER layout for BMP, and
apps/frotz/zpic.inc's own header comment for PIX - and never by running the
assembly and recording what it said.

The same argument apps/fptest/fpcases.inc makes for the soft-float core: the
reference is not my own arithmetic restated, it is what an independent
implementation produced.

One case is not generated at all. MAIN.PCX comes off the Dr. Dobb's File
Formats disc, is 1152x90 in four planes, and was written by PC Paintbrush in
1995 by somebody who had never heard of this project. Everything else here
could share a misreading with the decoder; that one cannot.
"""

import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, "build", "imgcases")
INC = os.path.join(ROOT, "apps", "imgtest", "imgcases.inc")

# os8088's sixteen, CBLACK..CWHITE, as (R,G,B) - apps/os88api.inc's palette.
PAL = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0xAA), (0x00, 0xAA, 0x00), (0x00, 0xAA, 0xAA),
    (0xAA, 0x00, 0x00), (0xAA, 0x00, 0xAA), (0xAA, 0x55, 0x00), (0xAA, 0xAA, 0xAA),
    (0x55, 0x55, 0x55), (0x55, 0x55, 0xFF), (0x55, 0xFF, 0x55), (0x55, 0xFF, 0xFF),
    (0xFF, 0x55, 0x55), (0xFF, 0x55, 0xFF), (0xFF, 0xFF, 0x55), (0xFF, 0xFF, 0xFF),
]

# IMG_E_* - apps/os88img.inc defines these and this file must agree.
E_OK, E_WHAT, E_SHORT, E_DIM, E_BIG, E_TRUNC, E_DEPTH, E_COMP, E_NOPIC, E_VER = range(10)


def nearest(rgb):
    """The os8088 colour closest to rgb, by |dR|+|dG|+|dB| - img_pal16's rule."""
    best, bestd = 0, 1 << 30
    for i, p in enumerate(PAL):
        d = abs(p[0] - rgb[0]) + abs(p[1] - rgb[1]) + abs(p[2] - rgb[2])
        if d < bestd:
            best, bestd = i, d
    return best


def pack4(rows):
    """rows = a list of lists of colour indices -> packed 4bpp, stride (w+1)//2."""
    w = len(rows[0])
    stride = (w + 1) // 2
    out = bytearray()
    for r in rows:
        line = bytearray(stride)
        for x, v in enumerate(r):
            if x & 1:
                line[x >> 1] |= v & 0x0F
            else:
                line[x >> 1] |= (v & 0x0F) << 4
        out += line
    return bytes(out), stride


def cksum(b):
    """A 16-bit rotate-xor. Order matters, which a plain sum would not catch."""
    s = 0
    for x in b:
        s = ((s << 1) | (s >> 15)) & 0xFFFF
        s ^= x
    return s


# --- the pattern every generated case carries --------------------------------

def pattern(w, h, ncol):
    """A deterministic pattern that uses every colour and is not symmetric.

    Not a flat fill and not a gradient: a wrong stride, a swapped nibble, an
    off-by-one row and a transposed image all survive those and none of them
    survives this.

    THE MIX MATTERS AND THE FIRST ONE WAS WRONG. `x*7 + y*5 + (x^y)` looks
    random and is not: x+y and x^y have the same parity, so the whole thing is
    even everywhere and the two-colour case came out ALL ZEROS - a test whose
    expected answer is a blank image, which a decoder that wrote nothing would
    have passed. It also reached only 8 of the 16 colours. This one is checked:
    16 distinct values at ncol=16, both at ncol=2, near-even counts for each.
    """
    return [[((x * 29 + y * 53 + (x * y) % 7) % ncol) for x in range(w)]
            for y in range(h)]


# --- encoders (each written from the format document) ------------------------

def enc_pcx_planar(rows, palette, nplanes):
    """PCX, 1 bit per pixel, `nplanes` planes. ZSoft revision 5.

    BytesPerLine MUST be even and is NOT derived from the width by a reader,
    so this deliberately pads it two bytes beyond the minimum - a decoder that
    computes its own stride reads the padding as pixels and fails here.
    """
    h, w = len(rows), len(rows[0])
    bpl = (w + 7) // 8
    if bpl % 2:
        bpl += 1
    bpl += 2                              # the padding a reader must respect
    hdr = bytearray(128)
    hdr[0] = 10                           # Manufacturer
    hdr[1] = 5                            # Version
    hdr[2] = 1                            # Encoding: RLE
    hdr[3] = 1                            # BitsPerPixel, per plane
    struct.pack_into("<HHHH", hdr, 4, 0, 0, w - 1, h - 1)
    struct.pack_into("<HH", hdr, 12, 72, 72)
    for i, c in enumerate(palette[:16]):
        hdr[16 + i * 3: 19 + i * 3] = bytes(c)
    hdr[65] = nplanes
    struct.pack_into("<H", hdr, 66, bpl)
    struct.pack_into("<H", hdr, 68, 1)
    body = bytearray()
    for r in rows:
        raw = bytearray(bpl * nplanes)
        for x, v in enumerate(r):
            for p in range(nplanes):
                if v & (1 << p):
                    raw[p * bpl + (x >> 3)] |= 0x80 >> (x & 7)
        body += rle(raw)                  # a break at the end of each scan line
    return bytes(hdr) + bytes(body)


def rle(raw):
    """PCX run-length encoding. A literal >= 0xC0 MUST go out as a run of one."""
    out = bytearray()
    i = 0
    while i < len(raw):
        v = raw[i]
        n = 1
        while i + n < len(raw) and raw[i + n] == v and n < 63:
            n += 1
        if n > 1 or v >= 0xC0:
            out.append(0xC0 | n)
            out.append(v)
        else:
            out.append(v)
        i += n
    return bytes(out)


def enc_bmp4(rows, palette, topdown=False):
    """A 4bpp BI_RGB BMP. Rows pad to a multiple of four bytes."""
    h, w = len(rows), len(rows[0])
    stride = ((w + 1) // 2 + 3) & ~3
    px = bytearray()
    order = range(h) if topdown else range(h - 1, -1, -1)
    for y in order:
        line = bytearray(stride)
        for x, v in enumerate(rows[y]):
            if x & 1:
                line[x >> 1] |= v & 0x0F
            else:
                line[x >> 1] |= (v & 0x0F) << 4
        px += line
    off = 14 + 40 + 64
    hdr = bytearray()
    hdr += b"BM"
    hdr += struct.pack("<IHHI", off + len(px), 0, 0, off)
    hdr += struct.pack("<IiiHHIIiiII", 40, w, -h if topdown else h,
                       1, 4, 0, len(px), 0, 0, 16, 0)
    for c in palette[:16]:
        hdr += bytes((c[2], c[1], c[0], 0))     # B,G,R,reserved
    return bytes(hdr) + bytes(px)


def enc_pix(pics):
    """A .PIX archive - apps/frotz/zpic.inc's own layout. pics = [(no, rows)]."""
    n = len(pics)
    dirsz = n * 16
    off = 16 + dirsz
    off = (off + 15) & ~15
    blocks, entries = [], []
    for no, rows in pics:
        h, w = len(rows), len(rows[0])
        stride = (w + 1) // 2
        if stride % 2:
            stride += 1                   # a padded stride, which a reader
        blk = bytearray()                 # must take from the entry
        for r in rows:
            line = bytearray(stride)
            for x, v in enumerate(r):
                if x & 1:
                    line[x >> 1] |= v & 0x0F
                else:
                    line[x >> 1] |= (v & 0x0F) << 4
            blk += line
        entries.append((no, w, h, stride, off))
        blocks.append(bytes(blk))
        off += len(blk)
        off = (off + 15) & ~15
    out = bytearray(b"O8PIX" + bytes([1]))
    out += struct.pack("<HHH", n, 1, 16)
    out += b"\0" * 4
    for no, w, h, stride, o in entries:
        out += struct.pack("<HHHHI", no, w, h, stride, o) + b"\0" * 4
    for (no, w, h, stride, o), blk in zip(entries, blocks):
        out += b"\0" * (o - len(out))
        out += blk
    return bytes(out)


# --- the reference DECODE, from the documents and not from the assembly ------

def ref_pcx(data):
    """Decode a PCX the way ZSoft's manual describes. -> (w, h, rows) or None."""
    if data[0] != 10 or data[2] != 1 or data[3] != 1:
        return None
    x0, y0, x1, y1 = struct.unpack("<HHHH", data[4:12])
    w, h = x1 - x0 + 1, y1 - y0 + 1
    npl = data[65]
    bpl = struct.unpack("<H", data[66:68])[0]
    total = npl * bpl
    pal = [nearest(tuple(data[16 + i * 3: 19 + i * 3])) for i in range(16)]
    p, rows = 128, []
    for _ in range(h):
        raw, run = bytearray(), []
        while len(raw) < total:
            b = data[p]; p += 1
            if (b & 0xC0) == 0xC0:
                n = b & 0x3F
                v = data[p]; p += 1
                raw += bytes([v]) * n
            else:
                raw.append(b)
        raw = raw[:total]                 # a run may overshoot the scan line
        row = []
        for x in range(w):
            idx = 0
            for pl in range(npl):
                if raw[pl * bpl + (x >> 3)] & (0x80 >> (x & 7)):
                    idx |= 1 << pl
            row.append(pal[idx])
        rows.append(row)
    return w, h, rows


def ref_bmp(data):
    off = struct.unpack("<I", data[10:14])[0]
    hsz = struct.unpack("<I", data[14:18])[0]
    w = struct.unpack("<i", data[18:22])[0]
    h = struct.unpack("<i", data[22:26])[0]
    bpp = struct.unpack("<H", data[28:30])[0]
    assert bpp == 4
    topdown = h < 0
    h = abs(h)
    pstart = 14 + hsz
    pal = [nearest((data[pstart + i * 4 + 2], data[pstart + i * 4 + 1],
                    data[pstart + i * 4])) for i in range(16)]
    stride = ((w + 1) // 2 + 3) & ~3
    rows = []
    for i in range(h):
        line = data[off + i * stride: off + (i + 1) * stride]
        row = []
        for x in range(w):
            b = line[x >> 1]
            row.append(pal[(b >> 4) if not (x & 1) else (b & 15)])
        rows.append(row)
    if not topdown:
        rows.reverse()
    return w, h, rows


def ref_pix(data, picno):
    n = struct.unpack("<H", data[6:8])[0]
    for i in range(n):
        e = 16 + i * 16
        no, w, h, stride = struct.unpack("<HHHH", data[e:e + 8])
        off = struct.unpack("<I", data[e + 8:e + 12])[0]
        if picno == 0 or no == picno:
            dst = (w + 1) // 2
            rows = []
            for y in range(h):
                line = data[off + y * stride: off + y * stride + dst]
                row = []
                for x in range(w):
                    b = line[x >> 1]
                    row.append((b >> 4) if not (x & 1) else (b & 15))
                rows.append(row)
            return w, h, rows
    return None


# --- the corpus --------------------------------------------------------------

def build():
    os.makedirs(OUTDIR, exist_ok=True)
    cases = []                            # (file, picno, err, w, h, stride, ck)

    def emit(name, blob, picno, err, decoded):
        with open(os.path.join(OUTDIR, name), "wb") as f:
            f.write(blob)
        if decoded is None:
            cases.append((name, picno, err, 0, 0, 0, 0))
            return
        w, h, rows = decoded
        packed, stride = pack4(rows)
        cases.append((name, picno, err, w, h, stride, cksum(packed)))

    # 1-2. PCX in four planes and in one, both with OUR palette, so the
    #      palette map is the identity and a failure here is the decoder's.
    rows = pattern(37, 11, 16)            # 37 is ODD: the last pixel of a row
    blob = enc_pcx_planar(rows, PAL, 4)   # has no partner nibble
    emit("P4.PCX", blob, 0, E_OK, ref_pcx(blob))

    rows1 = pattern(23, 7, 2)
    blob = enc_pcx_planar(rows1, PAL, 1)
    emit("P1.PCX", blob, 0, E_OK, ref_pcx(blob))

    # 3-4. BMP both ways up. Bottom-up is what this tree writes.
    rows = pattern(30, 9, 16)
    blob = enc_bmp4(rows, PAL, topdown=False)
    emit("BUP.BMP", blob, 0, E_OK, ref_bmp(blob))
    blob = enc_bmp4(rows, PAL, topdown=True)
    emit("BDOWN.BMP", blob, 0, E_OK, ref_bmp(blob))

    # 5. A FOREIGN palette: the sixteen colours in reverse. Every index must
    #    come back mapped, and an identity map fails every pixel. This is the
    #    case that proves img_pal16 does something.
    rows = pattern(16, 5, 16)
    blob = enc_bmp4(rows, list(reversed(PAL)), topdown=False)
    emit("FOREIGN.BMP", blob, 0, E_OK, ref_bmp(blob))

    # 6. A .PIX archive of two, asking for the SECOND by number - the archive
    #    is not a picture and picture numbers are not contiguous.
    a = pattern(12, 4, 16)
    b = pattern(19, 6, 16)
    blob = enc_pix([(1, a), (7, b)])
    emit("TWO.PIX", blob, 7, E_OK, ref_pix(blob, 7))

    # 7. ...and asking for one that is not in it.
    emit("TWO2.PIX", blob, 4, E_NOPIC, None)

    # 8. A FOREIGN palette on the PLANAR path too - the four-plane sibling of
    #    FOREIGN.BMP, and the case that covers what the real PC Paintbrush
    #    file below covers, for anyone who does not have the disc.
    rows = pattern(41, 8, 16)
    blob = enc_pcx_planar(rows, list(reversed(PAL)), 4)
    emit("FOREIGN.PCX", blob, 0, E_OK, ref_pcx(blob))

    # 9. An 8-bit PCX: REFUSED by name, not approximated. Synthesised rather
    #    than taken off the disc so the refusal is covered without it.
    hdr = bytearray(128)
    hdr[0], hdr[1], hdr[2], hdr[3] = 10, 5, 1, 8
    struct.pack_into("<HHHH", hdr, 4, 0, 0, 15, 3)
    hdr[65] = 1
    struct.pack_into("<H", hdr, 66, 16)
    emit("EIGHT.PCX", bytes(hdr) + b"\x10" * 64, 0, E_DEPTH, None)

    # 10-11. Two real third-party files, when the Dr. Dobb's File Formats disc
    #    has been copied into build/imgcases/. They are NOT in this repository
    #    (the same rule the format PDFs follow), so the corpus is eleven cases
    #    without them and thirteen with. Everything above could share a
    #    misreading with the decoder; MAIN.PCX - PC Paintbrush, 1152x90, four
    #    planes, written by somebody who had never heard of this project -
    #    cannot.
    real = os.path.join(OUTDIR, "MAIN.PCX")
    if os.path.exists(real):
        blob = open(real, "rb").read()
        emit("MAIN.PCX", blob, 0, E_OK, ref_pcx(blob))
    real = os.path.join(OUTDIR, "HELP8.PCX")
    if os.path.exists(real):
        emit("HELP8.PCX", open(real, "rb").read(), 0, E_DEPTH, None)

    # 10. A PCX whose pixel data stops early. Every byte off a disk is hostile
    #     (19) and this is what that means in practice.
    rows = pattern(37, 11, 16)
    blob = enc_pcx_planar(rows, PAL, 4)
    emit("CUT.PCX", blob[:len(blob) // 2], 0, E_TRUNC, None)

    # 11. Not a picture at all.
    emit("NOPE.TXT", b"This is not a picture, it is a sentence." * 8,
         0, E_WHAT, None)

    return cases


def render(cases):
    out = []
    out.append("; GENERATED by tools/os88imgcase.py - do not edit.")
    out.append(";")
    out.append("; One record per case: the file to load, which picture to ask")
    out.append("; for, and what apps/os88img.inc must answer. The expected")
    out.append("; values are computed on the HOST from the format documents,")
    out.append("; never by running the decoder and recording what it said.")
    out.append(";")
    out.append("; IMGC_REC = name(2) picno(2) err(2) w(2) h(2) stride(2) ck(2)")
    out.append("IMGC_REC equ 14")
    out.append("IMGC_N   equ %d" % len(cases))
    out.append("")
    out.append("imgc_tab:")
    for i, (name, picno, err, w, h, stride, ck) in enumerate(cases):
        out.append("    dw imgc_n%d, %d, %d, %d, %d, %d, 0x%04X"
                   % (i, picno, err, w, h, stride, ck))
    out.append("")
    for i, (name, *_rest) in enumerate(cases):
        out.append("imgc_n%d: db '%s', 0" % (i, name))
    out.append("")
    return "\n".join(out) + "\n"


def main():
    cases = build()
    text = render(cases)
    if "--check" in sys.argv:
        have = open(INC).read() if os.path.exists(INC) else ""
        if have != text:
            print("os88imgcase: apps/imgtest/imgcases.inc is stale - "
                  "run tools/os88imgcase.py")
            return 1
        print("os88imgcase: %d cases, imgcases.inc is current" % len(cases))
        return 0
    with open(INC, "w") as f:
        f.write(text)
    print("os88imgcase: wrote %d cases to %s" % (len(cases), INC))
    for c in cases:
        print("   %-12s pic=%d err=%d  %dx%d stride=%d ck=%04X" % c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
