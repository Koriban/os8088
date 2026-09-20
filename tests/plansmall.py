#!/usr/bin/env python3
"""PLAN opens, claims and CALCULATES on the 128KB machine (SPEC.md 81.75).

    make small smallapps && python3 tests/plansmall.py [--machine M]

This is the row the whole program exists for, and the only one that can
answer the question. `tests/unit/t_planfit.py` does the arithmetic - region
plus claims against SPEC.md 11.102's arena, each claim against SPEC.md
50.6.2's run limit - and arithmetic is not the same question: a package whose
ladder FITS in 128KB can still fail to open there, which is the distinction
tests/small128.py was written to make about the kernel itself.

**The failure this catches is SILENT.** `pl_entry` takes four claims. The
first three are `jc .fail` - the package stops - and the fourth is Undo's,
`jc .noundo`, which carries on deliberately (SPEC.md 81.57). A heap that
cannot fund the cells claim gives a window that opens and a spreadsheet with
nowhere to put a cell; nothing is printed, nothing is logged, and the size
meter on the host still says FITS. So the segments are read out of the
guest's own bss rather than inferred from a screenshot.

**And then it types.** Claims landing is not calculating: PLAN swapped SHEET's
software IEEE-754 double for fixed-point decimal (SPEC.md 81.75.3), which
rewrote every value path in the evaluator, and `=2+3` is the shortest
sentence that exercises the parser, the arithmetic and the cell store
together. The value is read back from the cells segment as the record
actually holds it - `PL_C_VAL`, 4 bytes at `FX_SCALE` - and not off the
glass, because the glass is what a format bug and a value bug look the same
on (SPEC.md 81.66's stored-versus-published rule).

SHEET cannot run here at all: it is in $(SMALLOMIT), its region alone is
larger than this machine's whole arena, and its cells claim is nearly twice
the largest run. That is the comparison this row is making.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "unit"))

# BEFORE the imports: os88sym resolves kernel symbols against $OS88_BUILD and
# $OS88_DEFINES at IMPORT time, so setting them later leaves the row reading
# kern_big's map against a kern_small guest - which does not raise, it reads
# plausible rubbish (tests/tanksmall.py carries the same note and the scar).
os.environ["OS88_BUILD"] = "build/smallk"
os.environ["OS88_DEFINES"] = "KERN_SMALL"

import os88ui                                               # noqa: E402
import dispapps                                             # noqa: E402
from harness import check, done                             # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FX_SCALE = 10000                    # apps/os88fix.inc, four decimal places
PL_C_VAL = 8                        # the record's value field, 4 bytes
PL_C_SZ = 16

# The three that stop the package, and the one that does not.
REQUIRED = ("pl_cellseg", "pl_txtseg", "pl_stgseg")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", default="os8088_5150_cga_128k")
    ap.add_argument("--image", default="build/small360.img")
    ap.add_argument("--apps", default="build/smallapps360.img")
    a = ap.parse_args(argv)
    os.chdir(ROOT)

    def off(n):
        return dispapps.bss_off("plan", n)

    with os88ui.boot(a.image, apps=a.apps, machine=a.machine) as ui:
        m = ui.m
        ui.open_drive("B")
        ui.open("APPS")
        w = ui.open("PLAN.O88")
        ui.raise_window(w)
        m.advance(frames=180)
        m.run()

        got = dispapps.pkg_seg(m, 0)
        check(got is not None, "PLAN.O88 is on the small apps disk and opens",
              "the Makefile puts $(PLANPKG) on both `make smallapps` volumes "
              "and on both small SYSTEM disks (SPEC.md 24.5.6 - a 128KB "
              "machine with one drive never swaps floppies). A disk built "
              "without it has nothing here",
              got="no package window", want="a window with a segment")
        if got is None:
            return done("plansmall")
        _slot, seg = got
        base = int.from_bytes(m.readseg(seg, 8, 2), "little")

        def word(n):
            return int.from_bytes(m.readseg(seg, base + off(n), 2), "little")

        for name in REQUIRED:
            check(word(name) != 0,
                  "%s was GRANTED on a %s machine" % (name, a.machine),
                  "pl_entry takes this one with `jc .fail`, so a refusal is "
                  "the package stopping - but the three before the window is "
                  "even created, which on the glass is a double-click that "
                  "does nothing at all",
                  got=word(name), want="a segment")

        undo = word("pl_undoseg")
        print("  undo claim: %s"
              % ("granted, segment %04X" % undo if undo else
                 "REFUSED - Undo is off, which is deliberate (SPEC.md 81.57)"))

        # ONE CHARACTER AT A TIME, with frames in between. `type_text` sends
        # the whole string as fast as the debug server will take it, and PLAN
        # polls - so `=2+3` arrived as `=` and the rest went on the floor, the
        # cell store stayed empty, and the row read that as a refused claim.
        # A harness artefact that looks exactly like the defect the row is
        # for is worth the six lines to make impossible.
        for ch in "=2+3":
            m.type_text(ch)
            m.advance(frames=45)
            m.run()
        check(m.readseg(seg, base + off("pl_editing"), 1)[0] == 1,
              "the keystrokes reached PLAN's editor",
              "read before Enter commits, so that a row which fails below "
              "says WHICH half failed: a cell store that refused the record, "
              "or a keyboard that never got there",
              got="pl_editing = 0", want=1)
        m.type_text("\n")
        m.advance(frames=180)
        m.run()

        n = word("pl_ncells")
        check(n == 1, "the entry reached the cell store",
              "one cell, because the sheet opened empty and one thing was "
              "typed into it. Zero here is a store that refused the record - "
              "PL_CELL_CAP is 320 at 5KB and 16 bytes a record, and a cells "
              "claim that landed as something smaller would show up exactly "
              "like this",
              got=n, want=1)
        if n != 1:
            return done("plansmall")

        cells = word("pl_cellseg")
        raw = m.readseg(cells, PL_C_VAL, 4)
        val = int.from_bytes(raw, "little", signed=True)
        check(val == 5 * FX_SCALE,
              "=2+3 evaluates to 5 in the cell record itself",
              "read from the cells segment as PL_C_VAL holds it, at "
              "apps/os88fix.inc's FX_SCALE - not off the glass, where a "
              "number-format defect and an arithmetic defect look the same "
              "(SPEC.md 81.66). This is the parser, the fixed-point add and "
              "the cell store in one sentence",
              got="%d (%.4f)" % (val, val / FX_SCALE), want=5 * FX_SCALE)

        done("plansmall")


if __name__ == "__main__":
    main(sys.argv[1:])
