#!/usr/bin/env python3
"""os88vbelog: print the transcript tests/vbeset wrote to a floppy image.

    python3 tools/os88vbelog.py build/vbesetauto.img

THE DISK IS THE OUTPUT CHANNEL, and it is the only one that works everywhere
this test has to run.  86Box has no QMP and no headless screen; a photograph of
a real machine's LCD is what SPEC.md 39.28.2.4 records the limits of; and the
same sector read here comes off a floppy carried back from the Satellite.  So
vbeset tees every character it prints into a buffer and writes it to a fixed
LBA, and this is the four lines that read it.

Raw sectors and not a file: the image has a boot sector and a payload laid down
by os88disk and no filesystem worth the name, and a FAT writer in 8086 assembly
would have been a hundred bytes to make the answer openable by something that
is never going to open it.
"""
import sys

LBA = 100           # tests/vbeset's VS_LOGSEC
SECS = 8            # ...and VS_LOG / 512


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    with open(sys.argv[1], "rb") as fh:
        fh.seek(LBA * 512)
        blk = fh.read(SECS * 512)
    txt = blk.decode("latin1").replace("\r", "").rstrip("\x00 \t\n")
    if not txt.strip():
        print("os88vbelog: sector %d is empty - the run never reached vs_save."
              % LBA)
        print("  a fresh CMOS stops an AT-class BIOS in setup; seed vm/*/nvr")
        return 1
    print(txt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
