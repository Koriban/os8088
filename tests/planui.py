#!/usr/bin/env python3
"""PLAN's menus, Copy/Paste and Undo on the 128KB machine (SPEC.md 81.75).

    make small plan && python3 tests/planui.py [--machine M]

tests/planrig.py drives the EVALUATOR - 71 formulas typed down a column. This
drives the parts a formula never reaches: the in-window menu bar, Edit >
Copy and Paste, and Undo. None of them has a keyboard shortcut in PLAN, so
none of them is reachable from the battery at all.

**The claim under test that matters is RELATIVE REFERENCE ADJUSTMENT.** When
the dead-code sweep took pl_formula_reidx out, the argument for its safety was
that Copy/Paste does not use it - paste has its own pl_copy_shift and
pl_copy_cellpart. That was checked by READING, and reading is how the same
sweep first convinced itself it had found 5,031 dead lines. So: B1 holds
`=A1*10`, it is copied to B2, and B2 must answer 20 rather than 10. A paste
that carried the formula across unchanged gives 10, which is a plausible
number in the right cell - exactly the failure that cannot be seen by looking.

**THE MENU BAR IS PLAN'S OWN** (81.54), not the kernel's OS88_MENUSET, so
os88ui's menu_pick cannot see it and this file drives it by clicking. The
coordinates are not guessed and not remembered between runs: pl_mboxof lays a
title out at [pl_ox] plus the running sum of pl_mw[i] + 2*PL_MPAD, and pl_mw
is an array in PLAN's own bss, so the rig READS the layout the guest actually
drew. Every step is then proved against the guest's own state - [pl_mopen]
says which menu opened and [pl_mhi] which item is hot - before the button is
released. CLAUDE.md's memory on this ("never reuse a remembered pulldown dy
offset") is what that is for: a click that lands one item off selects a
neighbouring command and the test reports the wrong feature broken.
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

# Defaulted rather than forced, so the same row can be pointed at a 640KB
# machine - which is the only way to exercise Undo's FUNCTIONAL path, since
# its claim is refused on the floor machine (SPEC.md 81.57):
#   OS88_BUILD=build OS88_DEFINES= python3 tests/planui.py \
#       --machine os8088_5150_cga_gla --image build/os8088-360.img
os.environ.setdefault("OS88_BUILD", "build/smallk")
os.environ.setdefault("OS88_DEFINES", "KERN_SMALL")

import os88ui                                               # noqa: E402
import os88mouse                                            # noqa: E402
import dispapps                                             # noqa: E402
from harness import check, done                             # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FX = 10000
C_SZ = 16
C_ROW, C_COL, C_FMT, C_TYPE, C_VAL = 0, 2, 5, 6, 8
ROW_MASK = 0x3FFF

# PLAN's OWN bar, and the names carry the PL_ prefix on purpose: the
# kernel has an PL_MBAR_H too and it is 20, because the kernel's menu bar
# is not this one. tests/unit/t_mirror.py refuses a host script that
# retypes a kernel constant's NAME with a different value, which is how
# this was caught.
PL_MBAR_H, PL_MI_H, PL_MPAD, PL_MENU_N = 14, 12, 8, 4
M_FILE, M_EDIT, M_FORMAT, M_OPTIONS = 0, 1, 2, 3
# pl_i_edit's order, which IS the item index
E_UNDO, E_REPEAT, E_CUT, E_COPY, E_PASTE, E_CLEAR = 0, 1, 2, 3, 4, 5
FRAMES = 8


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", default="os8088_5150_cga_128k")
    ap.add_argument("--image", default="build/small360.img")
    ap.add_argument("--apps", default="build/planrig.img")
    a = ap.parse_args(argv)
    os.chdir(ROOT)

    r = subprocess.run([sys.executable, "tools/os88disk.py", "--size", "360",
                        "-o", a.apps, "build/planapp/PLAN.O88"],
                       capture_output=True, text=True)
    if r.returncode:
        check(False, "the rig's floppy builds", "PLAN.O88 on a 360KB volume",
              got=(r.stderr or r.stdout).strip()[-200:], want="exit 0")
        return done("planui")

    def off(n):
        return dispapps.bss_off("plan", n)

    with os88ui.boot(a.image, apps=a.apps, machine=a.machine) as ui:
        m = ui.m
        mo = os88mouse.Mouse(marty=m)
        ui.open_drive("B")
        w = ui.open("PLAN.O88")
        ui.raise_window(w)
        m.advance(frames=180)
        m.run()

        got = dispapps.pkg_seg(m, 0)
        check(got is not None, "PLAN opens on a %s machine" % a.machine,
              "SPEC.md 81.75", got="no window", want="a package window")
        if got is None:
            return done("planui")
        _slot, seg = got
        base = int.from_bytes(m.readseg(seg, 8, 2), "little")

        def word(n):
            return int.from_bytes(m.readseg(seg, base + off(n), 2), "little")

        def byte(n):
            return m.readseg(seg, base + off(n), 1)[0]

        def settle(f=40):
            m.advance(frames=f)
            m.run()

        def enter(text):
            for ch in text:
                m.type_text(ch)
                m.advance(frames=FRAMES)
                m.run()
            m.type_text("\n")
            settle(30)

        def arrow(name, n=1):
            for _ in range(n):
                m.key(name)
                m.advance(frames=20)
                m.run()

        def at(col, row, why):
            """Prove where the selection is before acting on it."""
            check((word("pl_selcol"), word("pl_selrow")) == (col, row),
                  "selection is at (%d,%d) %s" % (col, row, why),
                  "0-based [pl_selcol]/[pl_selrow], read from the guest. An "
                  "arrow key that double-stepped would put every step after "
                  "this one on the wrong cell and blame the feature",
                  got=(word("pl_selcol"), word("pl_selrow")),
                  want=(col, row))

        def records():
            n = word("pl_ncells")
            raw = m.readseg(word("pl_cellseg"), 0, max(n, 1) * C_SZ)
            out = {}
            for i in range(n):
                rec = raw[i * C_SZ:(i + 1) * C_SZ]
                rr = struct.unpack("<H", rec[C_ROW:C_ROW + 2])[0] & ROW_MASK
                cc = struct.unpack("<H", rec[C_COL:C_COL + 2])[0]
                out[(cc, rr)] = (rec[C_TYPE], rec[C_FMT],
                                 struct.unpack("<i", rec[C_VAL:C_VAL + 4])[0])
            return out

        # --- the menu driver, reading the layout the guest drew -------------
        widths = [struct.unpack("<H", m.readseg(seg, base + off("pl_mw") + 2 * i, 2))[0]
                  for i in range(PL_MENU_N)]

        def title_x(mi):
            x = word("pl_ox")
            for i in range(mi):
                x += widths[i] + 2 * PL_MPAD
            return x + (widths[mi] + 2 * PL_MPAD) // 2

        def pick(mi, item, label):
            # THE EDGES ARE SENT EXPLICITLY, and that is the whole of why an
            # earlier version of this hung with the menu open: `to(x, y,
            # l=False)` at a position already reached moves nothing, so no
            # packet goes out and the button-up edge never happens. The menu
            # stayed down, ate every arrow key after it, and the failure
            # surfaced three steps later as "the selection did not move".
            # _edge() sends the packet and then waits for the guest's own
            # published mouse_btn to agree, re-sending if the UART dropped it.
            y = word("pl_oy") + PL_MBAR_H // 2
            mo.to(title_x(mi), y)
            mo._edge(True)
            settle()
            check(byte("pl_mopen") == mi, "%s: the menu opened" % label,
                  "[pl_mopen] is PLAN's own, so this proves the click landed "
                  "on the title rather than near it",
                  got=byte("pl_mopen"), want=mi)
            iy = word("pl_mry1") + item * PL_MI_H + PL_MI_H // 2
            mo.to(title_x(mi), iy, l=True)
            settle()
            hot = byte("pl_mhi")
            check(hot == item, "%s: the right item is hot" % label,
                  "[pl_mhi] before the button is released - one item off is a "
                  "neighbouring command and a test that blames the wrong "
                  "feature", got=hot, want=item)
            mo._edge(False)
            settle(80)
            check(byte("pl_mopen") == 0xFF, "%s: the menu closed" % label,
                  "PL_M_NONE again. A menu still open here eats every "
                  "keystroke that follows and the next failure names the "
                  "wrong feature",
                  got=byte("pl_mopen"), want=0xFF)
            return hot == item

        # --- operands, and a formula with a RELATIVE reference ---------------
        for v in ("1", "2", "3"):
            enter(v)
        at(0, 3, "after three entries down column A")
        arrow("ArrowUp", 3)
        arrow("ArrowRight", 1)
        at(1, 0, "at B1")
        enter("=A1*10")
        at(1, 1, "Enter advanced to B2")

        cells = records()
        check(cells.get((1, 0), (0, 0, 0))[2] == 10 * FX,
              "B1 =A1*10 is 10",
              "A1 holds 1, so the formula reads 10 before anything is copied",
              got=cells.get((1, 0)), want=10 * FX)

        # --- Copy B1, Paste into B2 ------------------------------------------
        arrow("ArrowUp", 1)
        at(1, 0, "back on B1 to copy it")
        if not pick(M_EDIT, E_COPY, "Edit > Copy"):
            return done("planui")
        arrow("ArrowDown", 1)
        at(1, 1, "on B2 to paste into")
        if not pick(M_EDIT, E_PASTE, "Edit > Paste"):
            return done("planui")

        cells = records()
        b2 = cells.get((1, 1))
        check(b2 is not None and b2[2] == 20 * FX,
              "the pasted formula ADJUSTED its reference: B2 is 20",
              "=A1*10 copied one row down must become =A2*10, and A2 holds 2. "
              "10 here is the formula carried across unchanged - a plausible "
              "number in the right cell, which is the failure that cannot be "
              "seen by looking. pl_copy_shift and pl_copy_cellpart are what "
              "do this; pl_formula_reidx, which the dead-code sweep removed, "
              "is NOT",
              got=("%d (%s)" % (b2[2], b2[2] / FX)) if b2 else "no record",
              want="%d (20.0)" % (20 * FX))

        # --- Cut it back out --------------------------------------------------
        # Cut is "Copy, then Clear" in PLAN, and its own orphaned `jc` made it
        # refuse or run depending on the carry the PREVIOUS command left - so
        # it is driven here right after a Paste, which is the ordering that
        # showed it.
        at(1, 1, "still on B2 to cut it")
        n_before_cut = word("pl_ncells")
        if pick(M_EDIT, E_CUT, "Edit > Cut"):
            cells = records()
            b2 = cells.get((1, 1))
            check(b2 is None or b2[0] == 0, "Cut emptied B2",
                  "Cut clears the whole selection after copying it. The "
                  "`jc .refused` left behind when document protection was cut "
                  "read the caller's carry, so this ran or did not by "
                  "accident of what came before it",
                  got=("cells %d -> %d, B2 %s"
                       % (n_before_cut, word("pl_ncells"),
                          b2 if b2 else "gone")),
                  want="B2 blank")

        # --- Undo, or an honest refusal to offer it ---------------------------
        # SPEC.md 81.57 makes Undo's claim the OPTIONAL one: pl_entry takes it
        # LAST with `jc .noundo` and carries on without it, which is what lets
        # "keep Undo" and "fit the floor machine" both be true. So on this
        # machine the right answer may be that there is no Undo - and then the
        # menu item must be GREYED rather than present and dead. SPEC.md 47's
        # rule is to grey a FACT, and [pl_undoseg] is the fact.
        undo_seg = word("pl_undoseg")
        y = word("pl_oy") + PL_MBAR_H // 2
        mo.to(title_x(M_EDIT), y)
        mo._edge(True)
        settle()
        iy = word("pl_mry1") + E_UNDO * PL_MI_H + PL_MI_H // 2
        mo.to(title_x(M_EDIT), iy, l=True)
        settle()
        hot = byte("pl_mhi")
        if undo_seg == 0:
            print("  Undo's claim was REFUSED on this machine "
                  "(SPEC.md 81.57's `jc .noundo`)")
            check(hot != E_UNDO,
                  "Undo is GREYED when its claim was refused",
                  "a machine that cannot fund the undo claim must not offer "
                  "the command - SPEC.md 47 rule 1, grey a fact. An item that "
                  "highlights and then does nothing is the failure this "
                  "checks for",
                  got="hot item %d" % hot, want="not selectable")
            mo._edge(False)
            settle(60)
        else:
            check(hot == E_UNDO, "Edit > Undo is offered", "",
                  got=hot, want=E_UNDO)
            before = word("pl_ncells")
            mo._edge(False)
            settle(80)
            cells = records()
            b2 = cells.get((1, 1))
            check(b2 is not None and b2[0] != 0,
                  "Undo put the cut cell back",
                  "one level, SPEC.md 81.57",
                  got=("cells %d -> %d, B2 %s"
                       % (before, word("pl_ncells"), b2 if b2 else "gone")),
                  want="B2 back")

        done("planui")


if __name__ == "__main__":
    main(sys.argv[1:])
