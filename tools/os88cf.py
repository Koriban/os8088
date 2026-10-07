#!/usr/bin/env python3
"""Lay four os8088 partitions across a whole CF card (SPEC.md 52.2).

    python3 tools/os88cf.py -o build/cf484.img --sectors 991872 \
        --part1 build/cfpart1.img --mbr build/mbr.bin

WHY FOUR AND NOT ONE. **A partition is capped at 65,535 sectors by the
kernel's volume ceiling (SPEC.md 18.7/52.2)** - the volume layer counts
sectors in a WORD - so 32MB is the largest slice os8088 can mount, and
`os88disk.py --hdd` is hard-wired to 63/16/65 = 65,520 sectors for exactly
that reason. FAT16 media with `TotSec16 == 0` (anything >= 32MB) is REFUSED
by the mount rules rather than truncated, so a single big partition would not
degrade - it would simply not appear.

SPEC.md 52.2 settles the rest: *"four primaries is the whole offering and an
extended chain is not implemented"*. So the most of a card os8088 can reach is
**4 x 32MB = 128MB**, whatever its size, and a 484MB card carries 356MB it
cannot address. That is a property of the OS, not of this tool, and the tool
says so rather than quietly laying one partition and leaving the card looking
broken.

WHAT IT WRITES

  LBA 0          the MBR - boot/mbr.asm's code in bytes 0..445, then four
                 entries built here
  LBA 63         partition 1, from --part1: a complete bootable os8088
                 volume, taken out of an `os88disk.py --hdd` image
  LBA 65520      partition 2  )  entries only, type 06h, UNFORMATTED - the
  LBA 131040     partition 3  )  machine's own Format (the Hard Drive page,
  LBA 196560     partition 4  )  SPEC.md 52.3) is what should lay these down,
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
SPT, HEADS = 63, 16             # os88disk.py's HDD_SPT / HDD_HEADS
CYL = SPT * HEADS               # 1,008 sectors to a cylinder
PART_SECS = 65457               # os88disk.py's HDD_PSECS - one track under the
                                # 65,535 ceiling, and what --hdd lays down
NPART = 4
TYPE_FAT16 = 0x04               # HPT_FAT16S: "FAT16 under 32MB - what DOS 3.3
                                # wrote, and every partition this driver makes
                                # is one" (drivers/hdd/hddabi.inc). 65,457
                                # sectors IS under 32MB, so it is the honest
                                # type as well as the matching one. 0x06 and
                                # 0x0E mount too (hdcom.inc) - another
                                # machine's FDISK wrote those - but the
                                # formatter and the installer both write 0x04
                                # and an image that disagrees with them is one
                                # more thing to explain later


def chs(lba):
    """LBA as a partition entry's 3-byte CHS field, clamped the way every tool
    of the era clamped it: a cylinder past 1023 becomes the all-ones form,
    which is what tells a reader to use the LBA fields instead."""
    c, r = divmod(lba, CYL)
    h, s = divmod(r, SPT)
    if c > 1023:
        return bytes([0xFE, 0xFF, 0xFF])
    return bytes([h, ((c >> 2) & 0xC0) | (s + 1), c & 0xFF])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", required=True, metavar="IMG")
    ap.add_argument("--sectors", type=int, required=True,
                    help="the WHOLE card, in 512-byte sectors")
    ap.add_argument("--part1", required=True,
                    help="an os88disk.py --hdd image; its partition becomes p1")
    ap.add_argument("--mbr", required=True, help="build/mbr.bin")
    a = ap.parse_args()

    p1 = open(a.part1, "rb").read()
    if len(p1) < (SPT + PART_SECS) * SECTOR:
        sys.exit("os88cf: %s is %d sectors, too short to hold a partition at "
                 "LBA %d for %d" % (a.part1, len(p1) // SECTOR, SPT, PART_SECS))
    payload = p1[SPT * SECTOR:(SPT + PART_SECS) * SECTOR]

    starts = []
    lba = SPT                                   # the era's floor: cyl 0 head 1
    for _ in range(NPART):
        starts.append(lba)
        lba = ((lba + PART_SECS + CYL - 1) // CYL) * CYL     # next cylinder
    end = starts[-1] + PART_SECS
    if end > a.sectors:
        sys.exit("os88cf: %d partitions need %d sectors and the card has %d. "
                 "A smaller card takes fewer - this tool lays %d."
                 % (NPART, end, a.sectors, NPART))

    mbr = bytearray(open(a.mbr, "rb").read()[:446].ljust(446, b"\0"))
    for i, st in enumerate(starts):
        e = bytearray(16)
        e[0] = 0x80 if i == 0 else 0x00         # only p1 boots
        e[1:4] = chs(st)
        e[4] = TYPE_FAT16
        e[5:8] = chs(st + PART_SECS - 1)
        struct.pack_into("<II", e, 8, st, PART_SECS)
        mbr += e
    mbr += b"\x55\xAA"
    assert len(mbr) == SECTOR

    img = bytearray(a.sectors * SECTOR)
    img[0:SECTOR] = mbr
    img[starts[0] * SECTOR:(starts[0] + PART_SECS) * SECTOR] = payload

    open(a.o, "wb").write(img)
    mb = a.sectors * SECTOR // (1024 * 1024)
    print("os88cf: %s  %d sectors (%d MB), %d partitions of %d sectors (32MB)"
          % (a.o, a.sectors, mb, NPART, PART_SECS))
    for i, st in enumerate(starts):
        what = "BOOTABLE, from %s" % a.part1 if i == 0 else \
               "unformatted - Format it from the Hard Drive page"
        print("  p%d  LBA %-7d cyl %-4d  %s" % (i + 1, st, st // CYL, what))
    unused = a.sectors - end
    print("  %d sectors (%d MB) past p4 are UNREACHABLE: SPEC.md 52.2 caps a "
          "partition at 65,535 sectors and implements no extended chain."
          % (unused, unused * SECTOR // (1024 * 1024)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
