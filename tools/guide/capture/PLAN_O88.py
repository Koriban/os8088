"""Plan's screenshots, for tools/guide/manuals/PLAN_O88.md.

    python3 tools/guide/capture/run.py PLAN_O88

Plan draws its own menu bar inside its window, which ui.menu_pick cannot
reach, so `pick`/`press` below drive it the way tests/planui.py does: every
coordinate is read off Plan's own state through a map of a re-assembly.
Its bar is four menus, not Sheet's nine (SPEC.md 81.75).
"""
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import os88marty  # noqa: E402
import os88geom  # noqa: E402

PL_MPAD, PL_MI_H = 8, 12                 # apps/plan/plan.asm
FILE, EDIT, FORMAT, OPTIONS = 0, 1, 2, 3


def u16(b):
    return b[0] | (b[1] << 8)


def plan_syms():
    src = os.path.join(ROOT, "apps/plan/plan.asm")
    with tempfile.TemporaryDirectory() as d:
        cp, mp = os.path.join(d, "t.asm"), os.path.join(d, "t.map")
        open(cp, "w").write(open(src).read() + "\n[map symbols %s]\n" % mp)
        subprocess.run(["nasm", "-f", "bin", "-w+error", "-I", ROOT + "/apps/",
                        "-I", ROOT + "/apps/plan/",
                        "-o", os.path.join(d, "t.bin"), cp], check=True)
        out = {}
        for line in open(mp):
            f = line.split()
            if len(f) == 3 and all(c in "0123456789ABCDEF" for c in f[0]):
                out[f[2]] = int(f[0], 16)
        return out


def capture(ui, shot):
    m, mo = ui.m, ui.mo
    S = plan_syms()
    ui.path("B:/APPS/PLAN.O88")
    w = ui.window("Plan")
    seg = u16(m.read(os88geom.winptr(m, w.i, ui.sym) + os88geom.W_SEG, 2))
    ui.settle()

    def rd(sym):
        return u16(m.readseg(seg, S[sym], 2))

    def press(menu):
        x = rd("pl_ox")
        for i in range(menu):
            x += u16(m.readseg(seg, S["pl_mw"] + i * 2, 2)) + PL_MPAD * 2
        mo.to(x + PL_MPAD + 2, rd("pl_oy") + 6)
        os88marty.settle(m)
        mo._edge(True)
        m.advance(frames=12)
        m.run()

    def over(item):
        mo.to(rd("pl_mrx1") + 12, rd("pl_mry1") + 2 + item * PL_MI_H + 6, l=True)
        m.advance(frames=12)
        m.run()

    def release():
        mo._edge(False)
        os88marty.settle(m)
        ui.settle()

    def pick(menu, item):
        press(menu)
        over(item)
        release()

    def button(rec, k):
        """Click button k (0 = OK, 1 = Cancel) of a dialog's record."""
        rects = u16(m.readseg(seg, S[rec], 2))
        x0, y0, x1, y1 = (u16(m.readseg(seg, rects + k * 8 + i * 2, 2))
                          for i in range(4))
        mo.click((x0 + x1) // 2, (y0 + y1) // 2)
        os88marty.settle(m)
        ui.settle()

    def park():
        """Move the pointer out of the picture."""
        mo.to(632, 440)
        os88marty.settle(m)

    def keys(*names):
        for k in names:
            m.key(k)
        ui.settle()

    def cell(ref):
        """Select a cell the way a user does, with Home and the arrows."""
        col, row = ord(ref[0]) - 65, int(ref[1:]) - 1
        keys("Home")
        for _ in range(20):
            keys("ArrowUp")
        for _ in range(col):
            keys("ArrowRight")
        for _ in range(row):
            keys("ArrowDown")

    # a small budget, typed: labels down A, figures down B, a total below
    cell("A1")
    for text in ("Rent", "Food", "Fuel", "Books"):
        m.type_text(text)
        keys("Enter")
    cell("B1")
    for n in ("425", "260.50", "88.25", "31.99"):
        m.type_text(n)
        keys("Enter")
    cell("A6")
    m.type_text("Total")
    keys("Tab")
    m.type_text("=SUM(B1:B4)")
    keys("Enter")

    # column A wide enough for the labels: Format > Column Width... = 10
    cell("A1")
    pick(FORMAT, 3)
    keys(*["Backspace"] * 4)
    m.type_text("10")
    keys("Enter")
    cell("B6")
    park()
    shot("plan-window", window="Plan", pad=8)

    # the File menu, held open
    press(FILE)
    over(0)
    shot("plan-menu", window="Plan", pad=8)
    release()                              # ...which opens New
    shot("plan-new", window="Plan", pad=8)
    button("pl_fdlg_btrec", 1)             # Cancel: keep the sheet

    # a formula being typed, shown in the formula bar as it is entered
    cell("B7")
    m.type_text("=AVERAGE(B1:B4)")
    park()
    shot("plan-formula", window="Plan", pad=8)
    keys("Enter")

    # Format > Number... on the total
    cell("B6")
    pick(FORMAT, 0)
    park()
    shot("plan-number", window="Plan", pad=8)
    button("pl_fdlg_btrec", 1)

    # Options > Calculation...
    pick(OPTIONS, 2)
    park()
    shot("plan-calc", window="Plan", pad=8)
    button("pl_fdlg_btrec", 1)
