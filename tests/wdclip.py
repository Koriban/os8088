#!/usr/bin/env python3
"""Word's repaint stays inside Word (SPEC.md 68.16, upstream issue #152).

    make && python3 tests/wordclip.py

`wd_redraw` is Word's whole-content repaint and no `W_PAINT` reaches it, so
its 31 callers arrive with no clip region armed (SPEC.md 11.3).  `wd_worker`
is the one that can run with another window on top: it draws DELIBERATELY
when Word is not frontmost (its `.idle` test).  It used to ask
`OSAPI_WM_OBSCURED` first, which vetoed the whole frame for one covered
pixel; 68.16 traded that veto for `OSAPI_WM_CLIP_SET` inside `wd_redraw`, so
a partly covered Word draws the part that shows instead of dropping the
repaint entirely.

THE TRIGGER IS POKED, not arranged (docs/TESTING.md: "what does that mode
change, and can I set it by hand").  The worker reaches `wd_redraw` only with
`[wd_sowed]` raised - a scroll whose repaint was dropped because another click
was right behind it (SPEC.md 27.7.8) - and it only wakes at all when there is
work, so `[wd_hdirty]` goes up with it.  Both are one byte in Word's own bss.

TWO GUARDS, and the row was VACUOUS without either of them:

  RAN    `wd_worker` clears `[wd_sowed]` on its way into the repaint, past all
         four of its `.unlock` tests, so a zero afterwards is the proof the
         path RAN.  A worker that never woke leaves every pixel check below
         testing nothing.
  INK    and the covering window must have INK under Word, not just white.
         The first shape of this row put Word over the Disk window's empty
         lower BODY and the mutant passed: Word's page is white and so is
         that, so an unclipped fill changed 21 pixels on the whole screen and
         every one of them was the menu bar's CLOCK.  So the Disk window is
         dragged bodily INSIDE Word's rect - frame, title bar, icons, names
         and scroll bar, all of it dark on white - and what the mutant erases
         is the chrome.  SPEC.md 81.105's gate learned the same thing about
         the Chart's frame; a content-only check passes the unfixed build.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "unit"))
import os88marty as M                                        # noqa: E402
import os88build                                             # noqa: E402
from os88mouse import Mouse                                  # noqa: E402
import dispcp                                                # noqa: E402
import os88sym                                               # noqa: E402
from harness import check, done                              # noqa: E402
import sheetfmt as SF                                        # noqa: E402
from paintmove import pkg_syms, pkg_seg                      # noqa: E402

WORK = os88build.at("build/wdclip")
DISK = os88build.at("build/wdclip.img")


def zord(m, S):
    """The z-order back to front - wm_zord, [-1] frontmost.

    NOT `dispcp.win_list`, which answers SLOT order (`range(MAX_WIN)`) and
    whose [-1] is merely the newest window. The two agree until something is
    raised, which is exactly what this row does.
    """
    n = m.read(S("wm_zn"), 1)[0]
    return list(m.read(S("wm_zord"), max(n, 1)))[:n]


def ink(fb, x, y):
    """Is that pixel BLACK in every channel?

    All three, because SPEC.md 81.105's gate counted the Chart's dark BLUE
    bars as SHEET's ink off the red channel alone.
    """
    w, data = fb[0], fb[2]
    o = (y * w + x) * 3
    return max(data[o:o + 3]) < 64


def main():
    os.chdir(os.path.join(HERE, ".."))
    os.makedirs(WORK, exist_ok=True)
    subprocess.run([sys.executable, "tools/os88disk.py", "-o", DISK,
                    "--size", "360", "build/word.o88"], check=True,
                   stdout=subprocess.DEVNULL)
    S = os88sym.linear
    P = pkg_syms("apps/word/word.asm", incs=("apps/", "apps/word/"))
    got = {}

    with M.launch(SF.SYS, apps=DISK, machine="os8088_xt_vga") as m:
        M.settle(m)
        M.no_saver(m)
        mo = Mouse(marty=m)

        dispcp.open_drive(m, mo, S, M.settle, letter="B")
        M.settle(m)
        disk = dispcp.win_list(m, S)[-1]
        dx, dy, dw, dh = dispcp.win_rect(m, S, disk)

        dispcp.open_named(m, mo, S, M.settle, dx, dy, name="WORD.O88")
        M.settle(m, limit=240)
        wslot = dispcp.win_list(m, S, check=False)[-1]
        wx, wy, ww, wh = dispcp.win_rect(m, S, wslot)

        # MOVE WORD CLEAR OF THE DISK WINDOW'S TITLE BAR FIRST. Word opens
        # nearly full screen, so the Disk window is wholly buried and there
        # is no exposed title to click (deskbench.raise_win's refusal) - and
        # the x of this drag is CLAMPED by wm_fit, which is why the step
        # below reads the rect back instead of computing where it put it.
        mo.drag(wx + ww // 2, wy + 9, wx + ww // 2 + 120, wy + 9 + 150)
        M.settle(m)
        wx, wy, ww, wh = dispcp.win_rect(m, S, wslot)

        mo.click(dx + 40, dy + 9)               # raise the Disk window...
        M.until(m, lambda mm: zord(mm, S)[-1:] == [disk],
                "the Disk window to come to the front", limit=90)
        M.settle(m)

        # ...AND NOW DRAG IT BODILY INSIDE WORD, which is the whole of the
        # INK guard: what must survive is the Disk window's chrome, so all
        # four of its edges have to be over Word's content.
        tx, ty = wx + 90, wy + 50
        mo.drag(dx + 40, dy + 9, dx + 40 + (tx - dx), dy + 9 + (ty - dy))
        M.settle(m)
        dx, dy, dw, dh = dispcp.win_rect(m, S, disk)
        mo.to(8, 470)                           # park off both windows
        M.settle(m)

        rect = (dx, dy, dx + dw - 1, dy + dh - 1)
        got["rect"] = rect
        got["word"] = (wx, wy, ww, wh)
        got["inside"] = (dx >= wx and dy >= wy and
                         dx + dw <= wx + ww and dy + dh <= wy + wh)
        got["front"] = (zord(m, S)[-1:] == [disk], disk)

        wseg, _ = pkg_seg(m, S, "Microsoft Word")
        got["seg"] = wseg
        if not wseg:
            check(False, "Word's package segment is readable",
                  "without it the poke below would land in another program",
                  got=repr(wseg), want="a segment")
            done("wdclip")

        got["before"] = m.fbuf()
        M.write_png_rgb(os.path.join(WORK, "1-before.png"), *got["before"])

        m.write(wseg * 16 + P["wd_hdirty"], b"\x01")   # there IS work...
        m.write(wseg * 16 + P["wd_sowed"], b"\x01")    # ...and it is a repaint
        m.write(wseg * 16 + P["wd_sigok"], b"\x00")    # ...of the WHOLE content
        # THE THIRD BYTE IS WHAT MAKES THE REPAINT DRAW ANYTHING. `wd_redraw`
        # is incremental: `.normal` asks `wd_sigsame`, and with the content
        # rect unchanged it walks the rows that moved and an untouched
        # document has none - so the first shape of this row poked two bytes,
        # watched the worker run a repaint that wrote not one pixel, and
        # passed the unarmed mutant with 10,239 ink pixels sitting under
        # Word. [wd_sigok] = 0 is the state after a RESIZE (wd_bounds has not
        # saved this geometry yet), it sends wd_sigsame to `.full`, and a
        # full content repaint is the case SPEC.md 68.16 is about.
        M.pace(m, 20)                                  # the worker wakes every
                                                       # WD_WTICKS = 3 ticks
        got["sowed"] = m.read(wseg * 16 + P["wd_sowed"], 1)[0]
        got["after"] = m.fbuf()
        M.write_png_rgb(os.path.join(WORK, "2-after.png"), *got["after"])

    before, after = got["before"], got["after"]
    x0, y0, x1, y1 = got["rect"]
    was = diff = 0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if ink(before, x, y):
                was += 1
            o = (y * before[0] + x) * 3
            if before[2][o:o + 3] != after[2][o:o + 3]:
                diff += 1
    print("      word %r, disk dragged inside it at %r" % (got["word"],
                                                           got["rect"]))
    print("      %d ink pixels under Word, %d changed by the repaint"
          % (was, diff))

    check(got["inside"], "the Disk window sits WHOLLY inside Word",
          "every edge of it has to be over Word's content, or the frame this "
          "row watches is over bare desktop and nothing Word draws could "
          "reach it",
          got="disk %r in word %r" % (got["rect"], got["word"]),
          want="contained")
    check(got["front"][0], "...and it is IN FRONT of Word",
          "the whole point is a repaint by a window that is NOT frontmost; "
          "with Word in front the kernel would be right to let it draw",
          got="frontmost %r, disk %r" % (got["front"][1:], got["front"][1]),
          want="the Disk window")
    check(was > 800, "the Disk window has INK under Word",
          "white on white is not a test. The first shape of this row put "
          "Word over the Disk window's empty BODY, and the unarmed mutant "
          "changed 21 pixels on the whole screen - all of them the menu "
          "bar's clock",
          got="%d black pixels in the Disk window" % was, want="> 800")
    check(got["sowed"] == 0, "the worker RAN its wd_redraw",
          "wd_worker clears [wd_sowed] on the way into the repaint, past all "
          "four of its .unlock tests, so a 1 here means the path never ran "
          "and the pixel check below is vacuous",
          got="wd_sowed = %d" % got["sowed"], want="0")
    check(diff == 0, "Word's repaint left the Disk window alone",
          "wd_redraw arms OSAPI_WM_CLIP_SET on its own window (SPEC.md "
          "68.16), so the part of Word under the Disk window is clipped "
          "away. Without the arm its fill erases the frame, the title bar, "
          "the icons and the scroll bar, and SPEC.md 11.96's raise cache "
          "banks the damage",
          got="%d of %d pixels changed" % (diff, dw * dh), want="0")
    done("wdclip")


if __name__ == "__main__":
    main()
