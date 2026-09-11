#!/usr/bin/env python3
"""What SHEET's evaluator ANSWERS, checked by the host (SPEC.md 81.49).

    make && python3 tests/sheeteval.py

tests/sheetfin.py holds the financial family and tests/sheetdec.py the
Normal-format round trip; this row is for the evaluator itself - the parse
and the value, whatever function or operator is involved - and it is where a
parity gap goes when it is closed. sheetfin.py's shape exactly: the host
authors SYLK formulas with a WRONG cached value (-999), SHEET opens the file,
recomputes, and saves SYLK, and the host reads the values back. SYLK and not
Normal, because SHEET's BIFF writer cannot carry a string literal and half
of these have one.

WHAT IT HOLDS TODAY:

  CHOOSE (81.49) was an INTEGER function, parsed beside MOD and FACT: every
  value through sh_parg as a word, the answer through sh_acc_int. So
  =CHOOSE(2,1.5,2.5) answered 2 and a text value answered 0. It returns the
  value it picked now - fractions, text, an error - and steps over the
  arguments after it rather than evaluating them.

  sh_skipargs COUNTED THE PARENTHESES INSIDE A QUOTED STRING, so the ')' in
  =1+ISERROR(FOO("a)"))*10 closed FOO early and the formula lost its tail.
  It is the routine CHOOSE now steps over its tail with, and every refusal
  path used it already. Only a case that CONTINUES after the skip could see
  it: with the quote handling taken out, that one failed and
  =CHOOSE(1,"a","b)") still answered "a", because the parser stopped
  quietly at the stray characters the bad skip left.

  THAT QUIET STOP (81.50): =1+2 3 answered 3 and =A1 * ( A2 - 1 ) answered
  2. What is left over after the parse is #VALUE! now, and spaces are
  dropped where a formula is stored, as Excel 2.1 drops them - except one
  between two operands, which is a mistake and is left for the parse to
  refuse.

  IF with TEXT branches (81.10.10 found it) answered the else-branch's text
  for every condition. Kept here because this is the row it belongs to.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "unit"))
import os88marty as M                                       # noqa: E402
import os88sheetfmt as F                                     # noqa: E402
from os88mouse import Mouse                                  # noqa: E402
import dispcp                                                # noqa: E402
from harness import check, done                              # noqa: E402
import sheetfmt as SF                                        # noqa: E402
import sheetfin as FN                                        # noqa: E402

WORK = "build/sheeteval"                # this row's own paths (WRITING-TESTS 5.5)
DISK = "build/sheeteval.img"
WRONG = -999.0
VALUES = {(0, 0): 2.0, (1, 0): 7.0, (2, 0): 3.25}
DIV0, VAL, NAME = ('err', '#DIV/0!'), ('err', '#VALUE!'), ('err', '#NAME?')

CASES = [
    # CHOOSE returns the VALUE it picked (81.49)
    ('CHOOSE(2,1.5,2.5)',                 2.5),
    ('CHOOSE(A1,A2,A3)',                  3.25),    # a fractional cell, picked
    ('CHOOSE(1,"a","b")',                 'a'),
    ('CHOOSE(2,"a","b")',                 'b'),
    ('CHOOSE(1,CHOOSE(2,"p","q"),"r")',   'q'),     # nested: nothing is banked
    ('CHOOSE(2,1,1/0)',                   DIV0),    # the CHOSEN error stands
    ('CHOOSE(1,1,1/0)',                   1.0),     # an unchosen one is skipped
    ('CHOOSE(4,1,2,3)',                   VAL),     # past the list: #VALUE!
    ('CHOOSE(0,1,2)',                     VAL),
    ('CHOOSE(2,1,2)*10',                  20.0),    # the tail after its ')'
    ('IF(A1>1,CHOOSE(1,"yes","no"),"x")', 'yes'),
    # a quoted ')' is not a parenthesis, before OR after the chosen value
    ('CHOOSE(1,"a","b)")',                'a'),
    ('CHOOSE(2,"x)","y")',                'y'),
    # ...and through an unknown function's refusal, where only a formula
    # that CONTINUES after the skip can tell a right one from a wrong one:
    # ISERROR alone answers 1 however the skip went, which is how the first
    # version of this case passed against the unfixed binary
    ('1+ISERROR(FOO("a)"))*10',           11.0),
    # the WHOLE formula is parsed, or it is #VALUE! (81.50) - these three
    # used to answer 3, 3 and 50, plausible numbers nobody would doubt
    ('1+2 3',                             VAL),     # NOT closed up into 1+23
    ('(1+2)3',                            VAL),
    ('50%',                               VAL),     # no % operator: an error,
                                                    # not half the answer
    # ...and spacing is not a mistake: dropped where it is stored, as Excel
    # 2.1 drops it. The first three answered 1, 2 and 0 before
    (' 1 + 2 ',                           3.0),
    ('A1 * ( A2 - 1 )',                   12.0),
    ('SUM (A1 : A3)',                     12.25),
    (' ( 1 + 2 ) * 3 ',                   9.0),
    ('" a  + "&"b "',                     ' a  + b '),  # a string keeps its
    # own - and only a double space, or one beside an operator, shows it:
    # every space in " a "&"b " sits between two operands and is kept anyway,
    # which is how that first version of this case passed with the quote
    # handling taken out
    # IF keeps a text branch (81.10.10)
    ('IF(A1>1,"big","small")',            'big'),
    ('IF(A1>5,"big","small")',            'small'),
]
COL = 2


def build_disk():
    os.makedirs(WORK, exist_ok=True)
    cells = dict(VALUES)
    for i, (expr, _) in enumerate(CASES):
        cells[(i, COL)] = ('formula', expr, WRONG)
    src = os.path.join(WORK, "SHIN.SLK")
    open(src, "wb").write(F.write_sylk(cells))
    subprocess.run([sys.executable, "tools/os88disk.py", "-o", DISK,
                    "--size", "360", "APPS:build/sheet.o88",
                    "APPS:build/CHART.OVL", "APPS:" + src],
                   check=True, stdout=subprocess.DEVNULL)


def agrees(want, got):
    if isinstance(got, tuple) and got and got[0] == 'formula':
        got = got[2]
    if isinstance(want, float):
        return (isinstance(got, float)
                and abs(got - want) <= 1e-9 * max(1.0, abs(want)))
    return got == want


def main():
    os.chdir(os.path.join(HERE, ".."))
    build_disk()
    with M.launch(SF.SYS, apps=DISK, machine=SF.MACHINE) as m:
        M.settle(m)
        mo = Mouse(marty=m)
        dispcp.open_drive(m, mo, lambda n: m.sym(n), M.settle, letter="B")
        M.settle(m)
        mo.dblclick(*SF.APPS_FOLDER)
        M.settle(m)
        mo.dblclick(*SF.SHIN_ROW)
        M.settle(m, limit=180)
        mo.menu(SF.FILE_MENU[0], SF.FILE_MENU[1], SF.SAVE_AS[0], SF.SAVE_AS[1])
        M.settle(m)
        mo.click(SF.FMT_RADIO_X, SF.FMT_Y['slk'])
        M.settle(m)
        mo.click(*SF.FMT_OK)
        M.settle(m, limit=120)
        mo.click(*SF.SAVE_BUTTON)
        vol = FN.wait_for(m, 'SHIN.SLK')
        raw = vol.read('SHIN.SLK') if 'SHIN.SLK' in vol.names() else b''
    check(bool(raw), "SHIN.SLK written back", "no SHIN.SLK after Save As SYLK")
    got = F.read_sylk(raw) if raw else {}
    for i, (expr, want) in enumerate(CASES):
        g = got.get((i, COL))
        check(agrees(want, g), "=%s" % expr,
              "SHEET answers %r, the host expects %r"
              % (g[2] if isinstance(g, tuple) else g, want))
    # what was STORED, read back from the saved text: the spacing gone, the
    # quoted spaces and the one mistaken space kept
    for expr, text in (('1+2 3', '1+2 3'), (' 1 + 2 ', '1+2'),
                       (' ( 1 + 2 ) * 3 ', '(1+2)*3'),   # SYLK saves a
                       # reference as R1C1, so this one has none
                       ('" a  + "&"b "', '" a  + "&"b "')):
        g = got.get(([e for e, _ in CASES].index(expr), COL))
        t = g[1] if isinstance(g, tuple) else None
        check(t == text, "=%s is stored =%s" % (expr, text),
              "saved as %r" % (t,))
    done("sheeteval")


if __name__ == "__main__":
    main()
