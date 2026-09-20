#!/usr/bin/env python3
"""PLAN's SYLK reader and its three number formats (SPEC.md 81.75).

    make plan && python3 tests/planfmt.py [--machine M]

THE INPUT IS AUTHORED HERE, on the host, and that is the rule SPEC.md 81.63
states for exactly this gate: a fixture the package itself wrote would let a
writer defect and a reader defect CANCEL, and the pair has been found doing
it. So the bytes below are written by this file, PLAN opens them, and what is
read back is the CELL RECORD.

**The defect this exists for**, found by reading rather than running, and the
reason the gate was owed: PLAN's format byte has a 2-bit number-format field,
and for a while there were TWO sets of names for it. The twenty-one-format
interpreter's PL_FMT_NUM_GENERAL/CURRENCY/COMMA/PERCENT = 0/1/2/3, and the
three formats that replaced it (81.75), PL_NF_NUMBER/TEXT/CURRENCY = 0/1/2.
Currency was 1 in one set and 2 in the other. The SYLK writer and reader were
still on the old names while everything that DISPLAYS a cell had moved to the
new ones, so a Currency cell was written as comma-with-no-dollar, a Text cell
was written as currency, and Excel's own '$' came back as Text. Two names for
one thing, both assembling, nothing said.

The machine is os8088_5150_cga_gla and not os8088_5150_cga because the
latter's ROM cannot be committed to this tree: on a box without a private copy
that name silently falls back to the GLaBIOS machine and says nothing, which
tests/unit/t_machines.py refuses by name.

This runs on a 640KB machine and not the floor one on purpose: it opens its
fixture by DOUBLE-CLICKING it, which wants a file association, and SPEC.md
54.0 takes associations out of kern_small entirely. The reader under test is
the same code either way; what the 128KB machine answers is
tests/planrig.py's question, not this one.
"""
import argparse
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "unit"))

import os88ui                                               # noqa: E402
import dispapps                                             # noqa: E402
from harness import check, done                             # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FX = 10000
C_SZ = 16
C_ROW, C_COL, C_FMT, C_TYPE, C_VAL = 0, 2, 5, 6, 8
ROW_MASK = 0x3FFF

NUM_MASK, NUM_SHIFT = 0x30, 4           # PL_FMT_NUM_MASK / _SHIFT
ALIGN_MASK, ALIGN_SHIFT = 0x0C, 2       # PL_FMT_ALIGN_MASK / _SHIFT
NF_NUMBER, NF_TEXT, NF_CURRENCY = 0, 1, 2
AL_GENERAL, AL_LEFT, AL_CENTER, AL_RIGHT = 0, 1, 2, 3
NFNAME = {0: "Number", 1: "Text", 2: "Currency", 3: "(3 - unassigned)"}

# (row, K value, F field or None, expected value, expected number format,
#  expected alignment)
ROWS = [
    (1, "1234.5",  "$2G", 12345000, NF_CURRENCY, AL_GENERAL),
    (2, "-1234.5", "$2G", -12345000, NF_CURRENCY, AL_GENERAL),
    (3, "99",      "G0G", 990000,   NF_NUMBER,   AL_GENERAL),
    (4, "42",      None,  420000,   NF_NUMBER,   AL_GENERAL),
    # ';K' is real SYLK's thousands-separator flag. PLAN has no Comma format
    # among its three, so it must be CONSUMED AND DROPPED - not turned into a
    # currency, which would put a '$' on a cell whose author never asked for
    # one. That is what this row is for.
    (5, "5000",    "G0G;K", 50000000, NF_NUMBER, AL_GENERAL),
    (6, "7",       "G0L", 70000,    NF_NUMBER,   AL_LEFT),
]


def write_slk(path):
    L = ["ID;POS88PLANFMT", "B;Y%d;X1" % len(ROWS)]
    for r, k, f, _v, _nf, _al in ROWS:
        L.append("C;Y%d;X1;K%s" % (r, k))
        if f:
            L.append("F;Y%d;X1;F%s" % (r, f))
    L.append("E")
    open(path, "w", newline="\r\n").write("\n".join(L) + "\n")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", default="os8088_5150_cga_gla")
    ap.add_argument("--image", default="build/os8088-360.img")
    a = ap.parse_args(argv)
    os.chdir(ROOT)

    slk = os.path.join("build", "PLANFMT.SLK")
    img = os.path.join("build", "planfmt.img")
    write_slk(slk)
    r = subprocess.run([sys.executable, "tools/os88disk.py", "--size", "360",
                        "-o", img, "build/planapp/PLAN.O88", slk],
                       capture_output=True, text=True)
    check(r.returncode == 0, "the fixture floppy builds",
          "PLAN.O88 and the host-authored SYLK on one volume; os88disk writes "
          "the ASSOC.DAT that makes the .SLK open PLAN",
          got=(r.stderr or r.stdout).strip()[-200:], want="exit 0")
    if r.returncode:
        return done("planfmt")

    def off(n):
        return dispapps.bss_off("plan", n)

    with os88ui.boot(a.image, apps=img, machine=a.machine) as ui:
        m = ui.m
        ui.open_drive("B")
        w = ui.open("PLANFMT.SLK")
        ui.raise_window(w)
        m.advance(frames=300)
        m.run()

        got = dispapps.pkg_seg(m, 0)
        check(got is not None, "the .SLK opens PLAN through its association",
              "SPEC.md 54 - the handler resolves on the disk it was launched "
              "from, and PLAN.O88 is on this one",
              got="no package window", want="a window with a segment")
        if got is None:
            return done("planfmt")
        _slot, seg = got
        base = int.from_bytes(m.readseg(seg, 8, 2), "little")

        def word(n):
            return int.from_bytes(m.readseg(seg, base + off(n), 2), "little")

        n = word("pl_ncells")
        check(n == len(ROWS), "every C record became a cell",
              "one cell a row; short here is a reader that dropped a record",
              got=n, want=len(ROWS))

        cells = word("pl_cellseg")
        raw = m.readseg(cells, 0, max(n, 1) * C_SZ)
        by_row = {}
        for i in range(n):
            rec = raw[i * C_SZ:(i + 1) * C_SZ]
            row = struct.unpack("<H", rec[C_ROW:C_ROW + 2])[0] & ROW_MASK
            by_row[row] = (rec[C_FMT],
                           struct.unpack("<i", rec[C_VAL:C_VAL + 4])[0])

        for r, k, f, want_v, want_nf, want_al in ROWS:
            rec = by_row.get(r - 1)
            if rec is None:
                check(False, "row %d (%s) has a record" % (r, k),
                      "the C record names this row", got="absent", want=k)
                continue
            fmt, val = rec
            nf = (fmt & NUM_MASK) >> NUM_SHIFT
            al = (fmt & ALIGN_MASK) >> ALIGN_SHIFT
            check(val == want_v, "row %d: %s reads back as %s" % (r, k, k),
                  "the VALUE is independent of the format it is shown in",
                  got="%d (%s)" % (val, val / FX),
                  want="%d (%s)" % (want_v, want_v / FX))
            check(nf == want_nf,
                  "row %d: ;F%s -> %s" % (r, f or "(none)", NFNAME[want_nf]),
                  "the 2-bit number-format field of PL_C_FMT, read as "
                  "PL_NF_* - the encoding the DISPLAY uses. Two names for "
                  "this field disagreed about which value meant Currency",
                  got="%d (%s), format byte %02X" % (nf, NFNAME[nf], fmt),
                  want="%d (%s)" % (want_nf, NFNAME[want_nf]))
            check(al == want_al, "row %d: alignment" % r,
                  "c2 of the F record, independent of the number format",
                  got=al, want=want_al)

        done("planfmt")


if __name__ == "__main__":
    main(sys.argv[1:])
