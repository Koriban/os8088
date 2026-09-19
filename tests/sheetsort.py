#!/usr/bin/env python3
"""Sort orders every kind of constant, and an error constant stays one
(SPEC.md 81.61).

    make && python3 tests/sheetsort.py

Data > Sort ordered NUMBERS only: a label, a logical and an error value in the
key column sat the sort out, their rows never moving - so sorting a column of
names did nothing at all. Excel's ascending order is numbers, then text in any
case, then logicals, then errors. And an error CONSTANT - #DIV/0! held as a
value, not computed - was lost three ways: Fill Right stored 0, Copy/Paste
carried the zero underneath it, and a typed #N/A became a label.

The HOST writes a SYLK file; everything is driven through the real menus and
read back from SHEET's own SYLK save:

  1. Fill Right from C1, which holds #DIV/0!, into D1: D1 is #DIV/0!.
  2. Copy C1, Paste into E1: E1 is #DIV/0!.
  3. #n/a typed into F1: F1 is the error #N/A, not a label.
  4. Sort on A1 alone - the whole column - ascending: 3, "pear", TRUE, #N/A,
     1, "Banana", FALSE, "apple", 2, ="cherry" and =1.5 come out 1, =1.5, 2,
     3, apple, Banana, ="cherry", pear, FALSE, TRUE, #N/A - the two formulas
     by their results, and the labels in any case (ASCII puts B before a).
  5. Sort G1:H4 on G, ascending, then descending: the key's classes order,
     and H comes with them row for row.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "unit"))
import os88marty as M                                       # noqa: E402
import os88flush                                            # noqa: E402
import os88sheetfmt as F                                     # noqa: E402
from os88mouse import Mouse                                  # noqa: E402
import dispcp                                                # noqa: E402
import os88sym                                              # noqa: E402
from harness import check, done                              # noqa: E402
import sheetfmt as SF                                        # noqa: E402
import glass                                                 # noqa: E402

WORK = "build/sheetsort"                # this row's own paths (WRITING-TESTS 5.5)
DISK = "build/sheetsort.img"
NAME = "SHIN.SLK"
EDIT = (123, 45)
DATA = (311, 45)
ITEM = lambda x, i: (x + 17, 57 + 12 * i + 2)
COPY, PASTE, FILLR = 3, 4, 10
SORT = 5                                # 81.71 put the Data menu in Excel's
                                         # own order, which moved Sort down
RADIO = lambda row: (SF.FMT_RADIO_X, 55 + 16 * row)
OK = (267, 172)
T, FA = ('bool', True), ('bool', False)
NA, DIV = ('err', '#N/A'), ('err', '#DIV/0!')
# 'Banana' and 'apple': in ASCII 'B' is below 'a', so a sort that does not
# fold case puts them the other way round
COL_A = [3.0, 'pear', T, NA, 1.0, 'Banana', FA, 'apple', 2.0,
         ('formula', '"cherry"', 'cherry'), ('formula', '1.5', 1.5)]
WANT_A = [1.0, 1.5, 2.0, 3.0, 'apple', 'Banana', 'cherry', 'pear', FA, T, NA]
COL_G = ['b', 2.0, T, 'A']
WANT_GH_UP = [(2.0, 2.0), ('A', 4.0), ('b', 1.0), (T, 3.0)]
WANT_GH_DOWN = list(reversed(WANT_GH_UP))


def build_disk():
    os.makedirs(WORK, exist_ok=True)
    cells = {(r, 0): v for r, v in enumerate(COL_A)}
    cells[(0, 2)] = DIV                                     # C1
    for r, v in enumerate(COL_G):
        cells[(r, 6)] = v                                   # G1:G4
        cells[(r, 7)] = float(r + 1)                        # H1:H4
    src = os.path.join(WORK, NAME)
    open(src, "wb").write(F.write_sylk(cells))
    subprocess.run([sys.executable, "tools/os88disk.py", "-o", DISK, "--size",
                    "360", "build/sheet.o88", "build/CHART.OVL", src],
                   check=True, stdout=subprocess.DEVNULL)


def plain(v):
    """a formula as the value it shows"""
    return v[2] if isinstance(v, tuple) and v and v[0] == 'formula' else v


def main():
    os.chdir(os.path.join(HERE, ".."))
    build_disk()
    S = os88sym.linear
    saved = {}
    with M.launch(SF.SYS, apps=DISK, machine=SF.MACHINE) as m:
        M.settle(m)
        M.no_saver(m)
        mo = Mouse(marty=m)
        dispcp.open_drive(m, mo, S, M.settle, letter="B")
        M.settle(m)
        ds = dispcp.win_list(m, S)[-1]
        wx, wy, _, _ = dispcp.win_rect(m, S, ds)
        dispcp.open_named(m, mo, S, M.settle, wx, wy, name=NAME)
        M.settle(m, limit=240)
        mo.to(634, 180)
        M.settle(m)
        w, h, rows = m.vram("cga")
        g = glass.grid(w, h, rows)
        if not g:
            check(False, "the grid is on the glass", "no grid")
            done("sheetsort")
            return
        ys, xs = g
        at = lambda r, c: ((xs[c] + xs[c + 1]) // 2, (ys[r] + ys[r + 1]) // 2)

        def menu(title, i):
            mo.menu(title[0], title[1], *ITEM(title[0], i))
            M.settle(m)

        def select(r1, c1, r2, c2):
            mo.click(*at(r1, c1))
            M.settle(m)
            if (r1, c1) != (r2, c2):
                m.key("ShiftLeft", down=True, up=False)
                mo.click(*at(r2, c2))
                m.key("ShiftLeft", down=False, up=True)
                M.settle(m)

        def sort(descending=False):
            menu(DATA, SORT)                # the key dialog, on the anchor
            m.type_text("\n")
            M.settle(m)
            if descending:
                mo.click(*RADIO(1))
                M.settle(m)
            mo.click(*OK)
            M.settle(m, limit=120)

        def save(tag):
            before = saved.get("last") or open(os.path.join(WORK, NAME),
                                               "rb").read()
            mo.menu(SF.FILE_MENU[0], SF.FILE_MENU[1],
                    SF.SAVE_AS[0], SF.SAVE_AS[1])
            M.settle(m)
            mo.click(SF.FMT_RADIO_X, SF.FMT_Y['slk'])
            M.settle(m)
            mo.click(*SF.FMT_OK)
            M.settle(m, limit=120)
            mo.click(*SF.SAVE_BUTTON)
            for _ in range(60):
                v = os88flush.Flush(marty=m).volume(1)
                if NAME in v.names() and v.read(NAME) != before:
                    saved[tag] = saved["last"] = v.read(NAME)
                    return
                M.settle(m, quiet=2.0, stable=2, limit=60)

        select(0, 2, 0, 3)                  # 1: C1:D1, Fill Right
        menu(EDIT, FILLR)
        select(0, 2, 0, 2)                  # 2: Copy C1, Paste at E1
        menu(EDIT, COPY)
        select(0, 4, 0, 4)
        menu(EDIT, PASTE)
        select(0, 5, 0, 5)                  # 3: typed
        m.type_text("#n/a\n")
        M.settle(m)
        select(0, 0, 0, 0)                  # 4: the whole of column A
        sort()
        select(0, 6, 3, 7)                  # 5: G1:H4, up and then down
        sort()
        save("up")
        select(0, 6, 3, 7)
        sort(descending=True)
        save("down")

    up = F.read_sylk(saved["up"]) if "up" in saved else {}
    down = F.read_sylk(saved["down"]) if "down" in saved else {}
    check(up.get((0, 3)) == DIV, "Fill Right carries the error constant #DIV/0!",
          "D1 holds %r" % (up.get((0, 3)),))
    check(up.get((0, 4)) == DIV, "Copy and Paste carry it too",
          "E1 holds %r" % (up.get((0, 4)),))
    check(up.get((0, 5)) == NA, "a typed #n/a is the error constant #N/A",
          "F1 holds %r" % (up.get((0, 5)),))
    got = [plain(up.get((r, 0))) for r in range(len(WANT_A))]
    check(got == WANT_A, "Sort orders numbers, then labels in any case, then "
          "logicals, then errors - formulas by their results",
          "column A came out %r" % (got,))
    kept = [up.get((r, 0)) for r in range(len(WANT_A))]
    check(('formula', '"cherry"', 'cherry') in kept
          and any(isinstance(v, tuple) and v[0] == 'formula' and v[2] == 1.5
                  for v in kept),
          "the two formulas are still formulas after the sort",
          "column A holds %r" % (kept,))
    gh = [(plain(up.get((r, 6))), plain(up.get((r, 7)))) for r in range(4)]
    check(gh == WANT_GH_UP, "Sort G1:H4 ascending: G's classes order and H "
          "comes with them", "G:H came out %r" % (gh,))
    gh = [(plain(down.get((r, 6))), plain(down.get((r, 7)))) for r in range(4)]
    check(gh == WANT_GH_DOWN, "...and descending reverses the whole order",
          "G:H came out %r" % (gh,))
    done("sheetsort")


if __name__ == "__main__":
    main()
