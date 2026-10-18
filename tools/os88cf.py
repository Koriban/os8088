#!/usr/bin/env python3
"""Lay four os8088 partitions across a whole CF card (SPEC.md 52.2).

    python3 tools/os88cf.py -o build/cf484.img --sectors 991872 \
        --part1 build/cfpart1.img --mbr build/mbr.bin

WHY FOUR, AND WHAT A PARTITION MAY NOW BE. Four is `--parts`' default, not a
cap this tool believes in: SPEC.md 52.2's offering is *"four primaries and an
extended chain is not implemented"*, so four is the most it can lay.

**THIS PARAGRAPH USED TO SAY 32MB WAS THE LARGEST SLICE os8088 COULD MOUNT.**
That was the word-wide volume-relative LBA, and **SPEC.md 18.7.5 raised the
ceiling to FAT16's own - just under 2GB - on `kern_big` and `kern_dos`**. The
body below was changed for it and this header was not, which left the file
stating a limit that the comment above `chs()` fifty lines down already said
had moved. `kern_small` still refuses a `TotSec16` of 0, so 32MB remains its
ceiling.

So the size of each slice is **not this tool's to decide**: it is read off
`--part1`'s own MBR and BPB (see `chs()`), which is an `os88disk.py --hdd`
image that already states its geometry. A plain `make cfimg` still lays the
63/16/65 = 65,520-sector shape that shipped before 18.7.5; `make cfimg
CFGEOM=261/255/63` lays ~2.0GB slices, and four of those reach ~8GB.

WHAT IT WRITES

  LBA 0          the MBR - boot/mbr.asm's code in bytes 0..445, then four
                 entries built here
  LBA 63         partition 1, from --part1: a complete bootable os8088
                 volume, taken out of an `os88disk.py --hdd` image
  LBA 65520      partition 2  )  entries only, type 06h, UNFORMATTED - the
  LBA 131040     partition 3  )  machine's own Format (the Hard Drive page,
  LBA 196560     partition 4  )  SPEC.md 52.3) is what should lay these down,
                 (those three LBAs are the DEFAULT 32MB shape's; with a
                 bigger --part1 they follow its geometry, not these numbers)
                                 because the formatter is the authority on
                                 what this kernel can mount and a filesystem
                                 hand-rolled here would only be a guess at it.
                                 They show as Unmountable with the reason,
                                 which SPEC.md 52.2.1 asks for.

EVERY PARTITION STARTS ON A CYLINDER BOUNDARY and each is 65,457 sectors - one
track short of the ceiling, which is what `--hdd` already produces and what
keeps all four identical. The era's two conventions are obeyed because DOS
reads what is written (SPEC.md 52.2): cylinder-aligned starts, and **the CHS
halves of an entry agree with its LBA halves** under the geometry the drive is
addressed with.

IT WRITES AN IMAGE AND NEVER A DEVICE. Burning is the operator's `dd`, so a
wrong device name cannot be this tool's mistake.
"""
import argparse
import struct
import sys

SECTOR = 512
NPART = 4

# NOTHING ABOUT THE PARTITION'S SHAPE IS DECLARED HERE ANY MORE. It used to
# carry SPT/HEADS/PART_SECS as copies of os88disk.py's HDD_* constants, with a
# comment saying so - two tools agreeing by restatement, which is the shape
# that goes stale the moment one of them learns something. SPEC.md 18.7.5
# raised the volume ceiling from 65,535 sectors to FAT16's own (just under
# 2GB) and that copy would have silently kept laying 32MB slices on an 8GB
# card. The geometry, the size and the type are READ OFF --part1's own MBR and
# BPB instead: it is an os88disk.py --hdd image, it already states all three,
# and a disagreement is now impossible rather than merely unlikely.
def chs(lba, spt, heads):
    """LBA as a partition entry's 3-byte CHS field, clamped the way every tool
    of the era clamped it: a cylinder past 1023 becomes the all-ones form,
    which is what tells a reader to use the LBA fields instead."""
    c, r = divmod(lba, spt * heads)
    h, s = divmod(r, spt)
    if c > 1023:
        return bytes([0xFE, 0xFF, 0xFF])
    return bytes([h, ((c >> 2) & 0xC0) | (s + 1), c & 0xFF])


def read_part1(path):
    """(payload, lba, secs, ptype, spt, heads) off an os88disk.py --hdd image.

    Its MBR entry 0 states where its partition is, how long it is and what
    type it was written as; its volume boot record states the geometry the
    two CHS columns were computed under (BPB_SecPerTrk / BPB_NumHeads). All
    six come from the file so that this tool cannot disagree with the tool
    that built it."""
    img = open(path, "rb").read()
    if len(img) < 2 * SECTOR or img[510:512] != b"\x55\xAA":
        sys.exit("os88cf: %s is not an MBR image" % path)
    ent = img[446:462]
    lba, secs = struct.unpack("<II", ent[8:16])
    ptype = ent[4]
    if not secs or (lba + secs) * SECTOR > len(img):
        sys.exit("os88cf: %s: entry 0 is %d sectors at LBA %d, which does not "
                 "lie inside a %d-sector file" % (path, secs, lba,
                                                  len(img) // SECTOR))
    vbr = img[lba * SECTOR:(lba + 1) * SECTOR]
    spt, heads = struct.unpack("<HH", vbr[24:28])
    if not spt or not heads:
        sys.exit("os88cf: %s: its volume boot record names no geometry "
                 "(BPB_SecPerTrk=%d, BPB_NumHeads=%d)" % (path, spt, heads))
    return (img[lba * SECTOR:(lba + secs) * SECTOR],
            lba, secs, ptype, spt, heads)


def part_end(vol: bytes) -> int:
    """How many sectors of a FAT volume are worth writing: everything up to
    and including the last ALLOCATED cluster. Reads the BPB and walks the FAT
    rather than looking at the bytes, for the reason at the call site."""
    spc = vol[13]
    rsvd, = struct.unpack("<H", vol[14:16])
    nfats = vol[16]
    rootent, = struct.unpack("<H", vol[17:19])
    fatsz, = struct.unpack("<H", vol[22:24])
    if not spc or not rsvd or not nfats or not fatsz:
        sys.exit("os88cf: --part1's volume has no usable BPB")
    rootsecs = (rootent * 32 + SECTOR - 1) // SECTOR
    data = rsvd + nfats * fatsz + rootsecs
    nclus = (len(vol) // SECTOR - data) // spc
    fat = vol[rsvd * SECTOR:(rsvd + fatsz) * SECTOR]
    fat12 = nclus < 4085
    top = 1
    for c in range(2, nclus + 2):
        if fat12:
            o = c + (c >> 1)
            v = struct.unpack("<H", fat[o:o + 2])[0]
            v = (v >> 4) if (c & 1) else (v & 0x0FFF)
        else:
            v = struct.unpack("<H", fat[c * 2:c * 2 + 2])[0]
        if v:
            top = c
    return data + (top - 1) * spc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", required=True, metavar="IMG")
    ap.add_argument("--sectors", type=int, required=True,
                    help="the WHOLE card, in 512-byte sectors")
    ap.add_argument("--part1", required=True,
                    help="an os88disk.py --hdd image; its partition becomes p1")
    ap.add_argument("--mbr", required=True, help="build/mbr.bin")
    ap.add_argument("--parts", type=int, default=NPART,
                    help="how many primaries to lay (default %d)" % NPART)
    ap.add_argument("--full", action="store_true",
                    help="write the WHOLE card, zeros and all, instead of "
                         "stopping after p1")
    a = ap.parse_args()

    payload, _, psecs, ptype, spt, heads = read_part1(a.part1)
    cyl = spt * heads

    starts = []
    lba = spt                                   # the era's floor: cyl 0 head 1
    for _ in range(a.parts):
        starts.append(lba)
        lba = ((lba + psecs + cyl - 1) // cyl) * cyl         # next cylinder
    end = starts[-1] + psecs
    if end > a.sectors:
        fit = 0
        l = spt
        while l + psecs <= a.sectors:
            fit += 1
            l = ((l + psecs + cyl - 1) // cyl) * cyl
        sys.exit("os88cf: %d partitions of %d sectors need %d and the card "
                 "has %d. %d fit - pass --parts %d."
                 % (a.parts, psecs, end, a.sectors, fit, fit))

    mbr = bytearray(open(a.mbr, "rb").read()[:446].ljust(446, b"\0"))
    for i, st in enumerate(starts):
        e = bytearray(16)
        e[0] = 0x80 if i == 0 else 0x00         # only p1 boots
        e[1:4] = chs(st, spt, heads)
        e[4] = ptype
        e[5:8] = chs(st + psecs - 1, spt, heads)
        struct.pack_into("<II", e, 8, st, psecs)
        mbr += e
    mbr += b"\x55\xAA"
    assert len(mbr) == SECTOR

    # THE FILE STOPS AFTER p1 UNLESS --full, and on a big card that is the
    # difference between 40MB and 8GB. Only p1 has content: 2, 3 and 4 are
    # ENTRIES, for the machine's own Format to lay down (SPEC.md 52.3), so
    # the sectors past p1 are ones `dd` has no reason to write. What is left
    # on the card there is whatever was there before, which is harmless
    # because no FAT marks it allocated - and `--full` is the arm for a card
    # that should be wiped.
    tail = a.sectors if a.full else starts[0] + psecs
    img = bytearray(tail * SECTOR)
    img[0:SECTOR] = mbr
    img[starts[0] * SECTOR:(starts[0] + psecs) * SECTOR] = payload

    # ...AND THEN THE FILE STOPS AT THE END OF p1's ALLOCATED DATA, unless
    # --full. A 1.5GB partition holding a few MB of files is almost all FREE
    # CLUSTERS, and a free cluster's contents are not data: the FAT - which is
    # near the front and IS written - is what says it is free. So `dd` has no
    # reason to write them, and leaves the card as it found it there.
    #
    # THE BOUND IS THE FAT AND NOT "THE LAST NON-ZERO SECTOR", which is the
    # version I wrote first and which is WRONG: a file whose last sector is
    # legitimately all zeros - a zero-padded binary, a cleared record - would
    # have had those sectors trimmed, `dd` would not write them, and the read
    # would return whatever the card held before. Allocated is allocated
    # whatever the bytes say, so the highest IN-USE cluster is what sets the
    # end.
    #
    # --full is the arm for a card that should be WIPED. What survives
    # otherwise is unreferenced, but it is still there.
    if not a.full:
        img = img[:starts[0] * SECTOR + part_end(payload) * SECTOR]

    open(a.o, "wb").write(img)

    def mb(n):
        return n * SECTOR // (1024 * 1024)
    print("os88cf: %s  %d sectors (%d MB) of card, %d partitions of %d "
          "sectors (%d MB), geometry %dx%d, type %02Xh"
          % (a.o, a.sectors, mb(a.sectors), a.parts, psecs, mb(psecs),
             heads, spt, ptype))
    for i, st in enumerate(starts):
        print("  p%d  LBA %-9d cyl %-5d %s" % (
            i + 1, st, st // cyl,
            "BOOTABLE, from %s" % a.part1 if i == 0 else
            "unformatted - Format it from the Hard Drive page"))
    left = a.sectors - end
    if left > 0:
        print("  %d sectors (%d MB) past p%d are unused: %d primaries is the "
              "whole offering and no extended chain is implemented "
              "(SPEC.md 52.2)." % (left, mb(left), a.parts, a.parts))
    if not a.full:
        print("  the FILE is %d MB, not %d: it stops at p1's last ALLOCATED "
              "cluster. p2-p4 are entries only, and a free cluster is not "
              "data - the FAT says so. --full writes the card whole."
              % (len(img) // (1024 * 1024), mb(a.sectors)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
