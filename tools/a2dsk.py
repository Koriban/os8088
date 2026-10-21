#!/usr/bin/env python3
"""Build the Disk II gate's fixture - a 143,360-byte Apple II disk image.

    python3 tools/a2dsk.py -o build/a2disk.dsk
    python3 tools/a2dsk.py --selfcheck
    python3 tools/a2dsk.py --dump build/a2disk.dsk 17 0

WHY THIS EXISTS.  **No `.DSK` ships** (docs/APPLE2-SPEC.md section 14): the
images people run are other people's, and the README and the Wire page say
where a reader gets them.  So the gate cannot open a disk that is in the tree
and must build one - and a fixture the TEST writes is the shape this project
already reaches for, because a reader defect and an image defect cannot then
cancel each other out.

WHAT IS IN IT, AND WHY NOT A REAL DOS 3.3 DISK.  Every one of the 560 sectors
carries its own (track, sector) and a checksum over the rest, so an assertion
is `the sector I asked for is the sector I got` rather than `something came
back`.  A real bootable image would test the controller and DOS at once and
say nothing about which of them was wrong; this says exactly one thing.

**THE BYTES ARE IN PHYSICAL ORDER AND THE FILE DOES NOT KNOW ITS OWN SECTOR
ORDER.**  A `.DSK`/`.DO` and a `.PO` of the same disk differ only in how a
reader MAPS logical sectors onto these 256-byte slots (section 14's two
tables), and the extension alone picks the mapping.  So this writes slot
`t * 16 + s` and labels it `s`, and a reader under test is right when logical
sector N of track T comes back labelled `order[N]`.  Writing a file that
already had an order baked in would test the generator against itself.

IT IS DETERMINISTIC, to the byte, so the gate can hold a checksum of the
whole image rather than re-deriving what it should contain.  `--selfcheck`
rebuilds it and compares against the figures below, which is the same
arrangement `tools/a2bas.py` uses for the tokeniser.
"""
import argparse
import hashlib
import sys

TRACKS = 35
SECTORS = 16
SECSIZE = 256
IMAGE = TRACKS * SECTORS * SECSIZE          # 143,360 - section 14's one size

MAGIC = b"A2DSK"                            # +0..4
# The two orders are section 14's, kept here because --dump reads a logical
# sector and would otherwise need the reader under test to interpret it.
DOS33 = (0x00, 0x07, 0x0E, 0x06, 0x0D, 0x05, 0x0C, 0x04,
         0x0B, 0x03, 0x0A, 0x02, 0x09, 0x01, 0x08, 0x0F)
PRODOS = (0x00, 0x08, 0x01, 0x09, 0x02, 0x0A, 0x03, 0x0B,
          0x04, 0x0C, 0x05, 0x0D, 0x06, 0x0E, 0x07, 0x0F)

# --selfcheck's PINNED ANSWER, and it is a measurement rather than a wish:
# the hash below was taken from this generator's own output and is checked
# against it. A change to the pattern changes the image, the image changes
# this, and a gate holding the old one says so instead of quietly comparing
# new bytes with new bytes. (The first draft of this file carried a hash
# nobody had taken, which is the defect this comment exists to not repeat.)
SHA256 = "0f2acae00c4a83af7dc74a3602bb4847f16511678bc003443a6667f00f0416cd"


def sector(track, sec):
    """One 256-byte slot: its own coordinates, then filler, then a checksum.

    The filler is a byte walk seeded from (track, sector) rather than a
    constant, so a reader that returns the RIGHT sector's header and the
    WRONG sector's body - an off-by-one in the nibble stream, which is the
    defect this format exists to catch - does not pass.
    """
    b = bytearray(SECSIZE)
    b[0:5] = MAGIC
    b[5] = track
    b[6] = sec
    b[7] = 0
    v = (track * 17 + sec * 31 + 7) & 0xFF
    for i in range(8, SECSIZE - 2):
        b[i] = v
        v = ((v << 1) | (v >> 7)) & 0xFF            # rotate, then mix
        v ^= (i & 0xFF)
    s = 0
    for i in range(0, SECSIZE - 2):
        s = (s + b[i]) & 0xFFFF
    b[SECSIZE - 2] = s & 0xFF
    b[SECSIZE - 1] = (s >> 8) & 0xFF
    return bytes(b)


def build():
    """The whole image, physical slot order."""
    out = bytearray()
    for t in range(TRACKS):
        for s in range(SECTORS):
            out += sector(t, s)
    assert len(out) == IMAGE, len(out)
    return bytes(out)


def check(blob, track, logical, order):
    """Read LOGICAL sector `logical` of `track` under `order`; answer its label.

    This is the arithmetic a reader under test has to get right, written once
    here so --dump and the gate agree about what the answer should be.
    """
    phys = order[logical]
    off = (track * SECTORS + phys) * SECSIZE
    sec = blob[off:off + SECSIZE]
    if sec[0:5] != MAGIC:
        return None
    s = 0
    for i in range(0, SECSIZE - 2):
        s = (s + sec[i]) & 0xFFFF
    if sec[SECSIZE - 2] != (s & 0xFF) or sec[SECSIZE - 1] != ((s >> 8) & 0xFF):
        return None
    return (sec[5], sec[6])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", metavar="OUT.DSK",
                    help="write the image here")
    ap.add_argument("--selfcheck", action="store_true",
                    help="rebuild and verify, writing nothing")
    ap.add_argument("--dump", nargs=3, metavar=("IMG", "TRACK", "LOGICAL"),
                    help="read one logical sector and print its label")
    ap.add_argument("--order", choices=("dos", "prodos"), default="dos",
                    help="the sector order --dump reads under")
    a = ap.parse_args()
    order = DOS33 if a.order == "dos" else PRODOS

    if a.dump:
        blob = open(a.dump[0], "rb").read()
        if len(blob) != IMAGE:
            sys.exit("a2dsk: %s is %d bytes, not %d - section 14 takes one "
                     "size and refuses every other" % (a.dump[0], len(blob), IMAGE))
        t, l = int(a.dump[1]), int(a.dump[2])
        got = check(blob, t, l, order)
        if got is None:
            sys.exit("a2dsk: track %d logical %d (%s) is not a fixture sector"
                     % (t, l, a.order))
        print("track %d logical %d (%s) -> physical %d, labelled track %d "
              "sector %d" % (t, l, a.order, order[l], got[0], got[1]))
        return 0

    blob = build()

    if a.selfcheck:
        # Every sector readable under BOTH orders, and labelled with the
        # PHYSICAL slot the order maps to - which is the one thing a reader
        # can get wrong without the bytes looking wrong.
        bad = 0
        for t in range(TRACKS):
            for l in range(SECTORS):
                for nm, o in (("dos", DOS33), ("prodos", PRODOS)):
                    got = check(blob, t, l, o)
                    if got != (t, o[l]):
                        bad += 1
                        if bad < 4:
                            print("a2dsk: %s track %d logical %d -> %r, "
                                  "wanted %r" % (nm, t, l, got, (t, o[l])),
                                  file=sys.stderr)
        if bad:
            sys.exit("a2dsk: %d sector reading(s) wrong" % bad)
        h = hashlib.sha256(blob).hexdigest()
        if h != SHA256:
            sys.exit("a2dsk: the image is %s and SHA256 says %s - the pattern "
                     "moved, so every gate holding the old bytes is stale.\n"
                     "        If that was deliberate, put this hash in SHA256."
                     % (h, SHA256))
        print("a2dsk: %d bytes, %d tracks x %d sectors, both orders read "
              "clean, sha256 pinned" % (len(blob), TRACKS, SECTORS))
        return 0

    if not a.output:
        sys.exit("a2dsk: -o OUT.DSK, or --selfcheck, or --dump")
    open(a.output, "wb").write(blob)
    print("a2dsk: %s - %d bytes (%d x %d x %d)"
          % (a.output, len(blob), TRACKS, SECTORS, SECSIZE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
