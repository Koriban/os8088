#!/usr/bin/env python3
"""PLAN's feature battery, on the 128KB machine (SPEC.md 81.75).

    make small plan && python3 tests/planrig.py [--machine M] [--cases N]

tests/plansmall.py asks whether PLAN opens, claims and evaluates AT ALL - one
cell, one formula, the smoke test. This asks what it actually computes, across
every family it still has, in one boot.

**THE BATTERY IS TYPED, NOT LOADED**, and that is a decision about what the
128KB machine can do rather than a preference. SPEC.md 54.0 takes file
ASSOCIATIONS out of kern_small whole - 2,560 bytes and a 3,072-byte heap claim
that stood on a bare desktop, on a machine whose whole heap is ~31KB - so on
the floor machine a .SLK cannot be double-clicked at all, and a rig that
loaded its battery would be testing a path this machine has not got. Typing
also exercises the editor and the parser from the keyboard, which is the path
a user actually takes here.

What is compared is the CELL RECORD - PL_C_TYPE, PL_C_AUX and PL_C_VAL at
apps/os88fix.inc's FX_SCALE - and never the glass. SPEC.md 81.66 is why: the
grid shows what the evaluator PUBLISHED through the number format, so a format
defect and an arithmetic defect are the same picture, and a column one
character too narrow looks like a wrong answer (it did, for an hour, in the
session that built this).

**ONE CHARACTER AT A TIME, WITH FRAMES BETWEEN.** `m.type_text` on a whole
string sends as fast as the debug server takes it and PLAN polls, so the
string arrives as its first character. Measured on this machine: 8 frames a
character is reliable and a whole formula lands in about a second, so the
pacing is not what costs the run - it is the boot.

The battery is typed straight DOWN column A, because Enter advances the
selection a row and that needs no coordinates at all. A1..A5 hold 1..5, typed
first, and are the operands every reference and range case reads; the cases
follow from A6. A cell keeps PL_C_VAL once it has been evaluated, so scrolling
past row 20 during entry costs nothing.

A case's expectation is one of:

    an int      the exact value in FX_SCALE units - and every asserted case is
                one whose answer is EXACT in four places, so that this file
                does not have to model PLAN's rounding to test its arithmetic
    ERR(n)      PL_T_ERR with that PL_ERR_* code
    TEXT        PL_T_TEXT, whatever the characters
    NOTE        not asserted: the value is printed and judged by a person.
                Rounding, NOW() and RAND() live here. A case nobody has looked
                at is not evidence, so these are counted and reported apart
                from the pass total rather than folded into it
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

# BEFORE the imports - tests/plansmall.py carries the note and the scar.
os.environ["OS88_BUILD"] = "build/smallk"
os.environ["OS88_DEFINES"] = "KERN_SMALL"

import os88ui                                               # noqa: E402
import dispapps                                             # noqa: E402
from harness import check, done                             # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FX = 10000                      # apps/os88fix.inc FX_SCALE, four places
C_SZ = 16                       # PL_C_SZ
C_ROW, C_COL, C_FLAGS, C_FMT, C_TYPE, C_AUX, C_VAL = 0, 2, 4, 5, 6, 7, 8
ROW_MASK = 0x3FFF               # PL_ROW_MASK - the sheet index is bits 14-15

T_BLANK, T_NUM, T_TEXT, T_BOOL, T_ERR = 0, 1, 2, 3, 4
ERRNAME = {1: "#NULL!", 2: "#DIV/0!", 3: "#VALUE!", 4: "#REF!",
           5: "#NAME?", 6: "#NUM!", 7: "#N/A"}


class ERR:
    def __init__(self, code): self.code = code
    def __repr__(self): return ERRNAME.get(self.code, "err%d" % self.code)


TEXT = object()
NOTE = object()


def fx(x):
    """An exact 4-place value in FX_SCALE units. Refuses one that is not."""
    v = round(x * FX)
    assert abs(v / FX - x) < 1e-9, "%r is not exact in four places" % (x,)
    return v


# (formula, expected). The formula is written WITHOUT a leading '=' because a
# SYLK ;E field carries the expression itself - a leading '=' there is a
# #VALUE! and cost an hour once.
CASES = [
    # --- arithmetic, and the shape of the value -----------------------------
    ("2+3",                 fx(5)),
    ("10-4",                fx(6)),
    ("6*7",                 fx(42)),
    ("10/4",                fx(2.5)),
    ("2^10",                fx(1024)),
    ("1+2*3",               fx(7)),        # precedence
    ("(1+2)*3",             fx(9)),
    ("-5",                  fx(-5)),       # unary minus: the IEEE sign-bit
    ("3*-2",                fx(-6)),       # idiom broke both of these once
    ("0.0625*16",           fx(1)),        # exact in four places
    ("0.5+0.25",            fx(0.75)),
    ("-7/2",                fx(-3.5)),
    ("100*1.05",            fx(105)),
    ("2^-2",                fx(0.25)),     # negative whole exponent
    # --- references and ranges ----------------------------------------------
    ("A1",                  fx(1)),
    ("A1+A5",               fx(6)),
    ("$A$1+1",              fx(2)),        # absolute
    ("SUM(A1:A5)",          fx(15)),
    ("AVERAGE(A1:A5)",      fx(3)),
    ("MIN(A1:A5)",          fx(1)),
    ("MAX(A1:A5)",          fx(5)),
    ("COUNT(A1:A5)",        fx(5)),
    ("COUNTA(A1:A5)",       fx(5)),
    ("PRODUCT(A1:A3)",      fx(6)),
    ("SUM(A1:A5)/COUNT(A1:A5)", fx(3)),
    # --- logic ---------------------------------------------------------------
    ("IF(1,10,20)",         fx(10)),
    ("IF(0,10,20)",         fx(20)),
    ("IF(A1>A2,1,0)",       fx(0)),
    ("IF(A5>A1,1,0)",       fx(1)),
    ("NOT(0)",              fx(1)),
    ("AND(1,1)",            fx(1)),
    ("AND(1,0)",            fx(0)),
    ("OR(0,1)",             fx(1)),
    ("TRUE()",              fx(1)),
    ("FALSE()",             fx(0)),
    ("A1=1",                fx(1)),        # comparison operators
    ("A1<>1",               fx(0)),
    ("A5>=5",               fx(1)),
    # --- the maths that survived --------------------------------------------
    ("ABS(-7)",             fx(7)),
    ("MOD(7,3)",            fx(1)),
    ("MOD(-7,3)",           fx(2)),        # Excel: the DIVISOR's sign
    ("INT(3.7)",            fx(3)),
    ("INT(-3.7)",           fx(-4)),       # INT floors...
    ("TRUNC(-3.7)",         fx(-3)),       # ...TRUNC cuts toward zero
    ("SIGN(-9)",            fx(-1)),
    ("FACT(5)",             fx(120)),
    ("SQRT(16)",            fx(4)),        # the seed-overestimate bug
    ("SQRT(2)",             NOTE),
    ("SQRT(-1)",            ERR(6)),       # #NUM!
    ("POWER(2,8)",          fx(256)),
    ("ROUND(1234.5678,2)",  fx(1234.57)),
    ("ROUND(1250,-2)",      fx(1300)),     # half away from zero
    ("ROUND(2.5,0)",        fx(3)),
    ("ROUND(-2.5,0)",       fx(-3)),
    ("ROUND(1000,2)",       fx(1000)),     # the fx_qmulcx BX clobber
    ("CHOOSE(2,10,20,30)",  fx(20)),
    ("COLUMN()",            NOTE),
    ("ROW()",               NOTE),
    # --- errors --------------------------------------------------------------
    ("1/0",                 ERR(2)),       # #DIV/0!
    ("FOO(1)",              ERR(5)),       # #NAME? - an outright typo
    # ...and the families that are NAMED in pl_functab but cut (81.75). Each
    # must answer #NAME?, which is what a user typing it actually sees, and
    # NOT a wrong number or a wild jump.
    ("DATE(2026,1,1)",      ERR(5)),
    ("NOW2()",              ERR(5)),
    ("VLOOKUP(1,A1:A5,1)",  ERR(5)),
    ("INDEX(A1:A5,1)",      ERR(5)),
    ("VAR(A1:A5)",          ERR(5)),
    ("STDEV(A1:A5)",        ERR(5)),
    ("ISBLANK(A1)",         ERR(5)),
    ("ISERROR(A1)",         ERR(5)),
    ("LEFT(A1,1)",          ERR(5)),
    ("PMT(1,2,3)",          ERR(5)),
    ("SIN(1)",              ERR(5)),
    ("LN(1)",               ERR(5)),
    ("MDETERM(A1:A2)",      ERR(5)),
    # --- text ----------------------------------------------------------------
    ('"ab"&"cd"',           TEXT),
    # --- not asserted, reported ----------------------------------------------
    ("1/3",                 NOTE),
    ("10/3*3",              NOTE),
    ("NOW()",               NOTE),
    ("RAND()",              NOTE),
    ("100000*100000",       NOTE),         # past the +-214,748.3647 range
]

COL_A = 0                       # 0-based column index of A: PLAN
                                # opens with the selection on A1,
                                # and Enter walks down from there
OPERANDS = (1, 2, 3, 4, 5)      # A1..A5, what the reference cases read
FIRST_ROW = len(OPERANDS)       # 0-based row of the first case, i.e. A6
FRAMES = 8                      # per character; calibrated on this machine


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", default="os8088_5150_cga_128k")
    ap.add_argument("--image", default="build/small360.img")
    ap.add_argument("--apps", default="build/planrig.img")
    ap.add_argument("--cases", type=int, default=0, help="first N only")
    a = ap.parse_args(argv)
    os.chdir(ROOT)

    cases = CASES[:a.cases] if a.cases else CASES

    # A floppy with nothing on it but PLAN, so the row does not depend on what
    # else a shipped disk happens to carry.
    r = subprocess.run([sys.executable, "tools/os88disk.py", "--size", "360",
                        "-o", a.apps, "build/planapp/PLAN.O88"],
                       capture_output=True, text=True)
    check(r.returncode == 0, "the rig's floppy builds",
          "PLAN.O88 alone on a 360KB volume",
          got=(r.stderr or r.stdout).strip()[-200:], want="exit 0")
    if r.returncode:
        return done("planrig")

    def off(n):
        return dispapps.bss_off("plan", n)

    with os88ui.boot(a.image, apps=a.apps, machine=a.machine) as ui:
        m = ui.m
        ui.open_drive("B")
        w = ui.open("PLAN.O88")
        ui.raise_window(w)
        m.advance(frames=180)
        m.run()

        got = dispapps.pkg_seg(m, 0)
        check(got is not None, "PLAN.O88 opens on a %s machine" % a.machine,
              "SPEC.md 81.75 - the machine SHEET is omitted from entirely",
              got="no package window", want="a window with a segment")
        if got is None:
            return done("planrig")
        _slot, seg = got
        base = int.from_bytes(m.readseg(seg, 8, 2), "little")

        def word(n):
            return int.from_bytes(m.readseg(seg, base + off(n), 2), "little")

        for nm in ("pl_cellseg", "pl_txtseg", "pl_stgseg"):
            check(word(nm) != 0, "%s was granted" % nm,
                  "pl_entry takes these three with `jc .fail`, before the "
                  "window exists - so a refusal is a double-click that does "
                  "nothing at all", got=word(nm), want="a segment")

        def enter(text):
            for ch in text:
                m.type_text(ch)
                m.advance(frames=FRAMES)
                m.run()
            m.type_text("\n")
            m.advance(frames=30)
            m.run()

        typed = 0
        for v in OPERANDS:
            enter(str(v))
            typed += 1
        check(word("pl_ncells") == typed, "the five operands landed",
              "typed as plain numbers into A1..A5 before any formula reads "
              "them", got=word("pl_ncells"), want=typed)

        for f, _e in cases:
            enter("=" + f)
            typed += 1
        n = word("pl_ncells")
        check(n == typed, "every case reached the cell store",
              "one cell a case, typed down column A. Short here is a "
              "keystroke that went on the floor or a store that refused a "
              "record - PL_CELL_CAP is %d" % (5 * 1024 // C_SZ),
              got=n, want=typed)

        cells = word("pl_cellseg")
        raw = m.readseg(cells, 0, n * C_SZ)
        by_rc = {}
        for i in range(n):
            rec = raw[i * C_SZ:(i + 1) * C_SZ]
            row = struct.unpack("<H", rec[C_ROW:C_ROW + 2])[0] & ROW_MASK
            col = struct.unpack("<H", rec[C_COL:C_COL + 2])[0]
            val = struct.unpack("<i", rec[C_VAL:C_VAL + 4])[0]
            by_rc[(col, row)] = (rec[C_TYPE], rec[C_AUX], val, rec[C_FMT])

        notes, asserted = [], 0
        for i, (f, want) in enumerate(cases):
            rec = by_rc.get((COL_A, FIRST_ROW + i))
            if rec is None:
                check(False, "%-22s has a record" % f,
                      "the cell was typed and committed with Enter",
                      got="absent", want=f)
                continue
            ty, aux, val, _fmt = rec
            if want is NOTE:
                notes.append((f, ty, aux, val))
                continue
            asserted += 1
            if isinstance(want, ERR):
                check(ty == T_ERR and aux == want.code,
                      "%-22s -> %s" % (f, want),
                      "an error VALUE, not a number - the whole point is "
                      "that it cannot be mistaken for one",
                      got=("type %d aux %d (%s) val %d"
                           % (ty, aux, ERRNAME.get(aux, "?"), val)),
                      want="type %d aux %d" % (T_ERR, want.code))
            elif want is TEXT:
                check(ty == T_TEXT, "%-22s -> text" % f,
                      "'&' concatenation survives in PLAN even though the "
                      "text FUNCTIONS were cut",
                      got="type %d" % ty, want="type %d" % T_TEXT)
            else:
                # PL_T_BOOL is accepted beside PL_T_NUM: a logical answers
                # 1 or 0 at the same FX_SCALE and the tag is what says it
                # came from a comparison rather than from arithmetic.
                check(ty in (T_NUM, T_BOOL) and val == want,
                      "%-22s -> %s" % (f, want / FX),
                      "read from the cell record at FX_SCALE, never off the "
                      "glass (SPEC.md 81.66)",
                      got=("type %d val %d (%s)%s"
                           % (ty, val, val / FX,
                              "  " + ERRNAME.get(aux, "?") if ty == T_ERR
                              else "")),
                      want="%d (%s)" % (want, want / FX))

        print("  --- not asserted, for a person to read ---")
        for f, ty, aux, val in notes:
            print("  %-22s type %d  %s"
                  % (f, ty,
                     ERRNAME.get(aux, "?") if ty == T_ERR
                     else "%d (%s)" % (val, val / FX)))
        print("  %d asserted, %d reported" % (asserted, len(notes)))
        done("planrig")


if __name__ == "__main__":
    main(sys.argv[1:])
