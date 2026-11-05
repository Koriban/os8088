#!/usr/bin/env python3
"""BASIC/8088 runs a program and the answers are right (SPEC.md 126).

    python3 tests/basiclang.py

THE FIRST ROW THAT EXECUTES THE LANGUAGE. Everything before it checked the
package's LAYOUT (tests/unit/t_fpscratch.py) or its size; nothing ran a
program and compared what came back, and the cost of that was five defects
that the build could not see and reading did not catch:

  * the value stack reserved four slots while bas_exec permitted sixteen, so
    a right-nested expression wrote over os88fp.inc's register-A scratch and
    `1+(2+(3+(4+(5+(6+(7+8))))))` answered -2.668453E+307 for 36;
  * the variable table outlived the program text its entries point into, so
    `PRINT n` answered a previous RUN's `y`;
  * `PRINT 10\\3` refused as "outside an INTEGER" from wave 1c until wave 2b -
    `\\` had never once been executed;
  * File > New cleared the console and not the program, and the repaint after
    it went through a clobbered SI;
  * the console blanked on its first scroll, because the carrier never spent
    os88con.inc's scroll debt.

Every one of them is a line below.

**IT READS THE CONSOLE BUFFER, NOT THE PIXELS.** The answers are (character,
attribute) cells in the package's own bss, so a row that matches glyphs would
be testing the renderer as well and could not say which half was wrong - and
the console is EIGHT rows of a 25-row buffer (SPEC.md 126.17), so most of a
long program's output is not on the glass at all. The buffer is found by its
CONTENT: BASIC's banner, as cells, locates it with no kernel symbol and no
package map. One pixel assertion stands beside the text, and only one - that
the pane is not blank - because that is the renderer defect above and it is
invisible to every buffer read.

**IT PRESSES F5.** Run is a menu pick and a menu pick is a drag whose offsets
drift (the pulldown's dy is not a constant across adapters); F5 is what every
BASIC of this line runs on, it is what the package ships, and it makes the
whole row keyboard-only once the window is open.

VERIFIED TO FAIL - and what is NOT verified, which matters more:

  * putting `BAS_STK_MAX*2` back - the wave 1c defect - reports `PRINT x`
    answering 0 where it owes 7. **It did NOT, until the program had a
    variable read AFTER the deep expression.** A short reservation does not
    corrupt the expression that overruns it; it corrupts whatever the chain
    puts above, and since wave 2a that is bas_nvar and the variable table,
    not register A. The mutation passed a row whose deep line stood alone,
    which is the fixture failing and not the assertion.
  * the ink assertion is **NOT** shown to catch its own defect. Deleting
    bas_paint's `con_takescroll` leaves this row green - with one run and
    with three - though it blanks the pane under a hand-driven session of
    six or more. So the line below guards a pane that is blank OUTRIGHT, and
    the scroll debt is held by inspection and by os88con.inc's header, not
    by this row. Said here rather than claimed, because a row that is
    believed to cover something it does not is worse than one that says so.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import os88sym                                              # noqa: E402
import os88qemu                                             # noqa: E402
import os88fixture                                          # noqa: E402
import dispcp                                               # noqa: E402

S = os88sym.linear
SOCK = os88qemu.SOCK

CON_COLS, CON_ROWS = 80, 25
ROW = CON_COLS * 2                      # a row of (character, attribute)
BANNER = "BASIC/8088"                   # bas_s_banner's first word

# The program, and what each line owes the console. A blank expectation is a
# line that prints nothing - an assignment, which is most of what a program
# is. SPEC.md 126.4's PRINT puts a space where the sign would be and another
# after the number, so the text is compared STRIPPED.
PROGRAM = [
    ("x = 7",                            None),
    ("y = x * 6",                        None),
    ("PRINT y",                          "42"),      # variables at all
    ("PRINT 1+2*3",                      "7"),       # precedence
    ("PRINT (1+2)*3",                    "9"),       # ...and parentheses
    ("PRINT 1+(2+(3+(4+(5+(6+(7+8))))))", "36"),     # eight slots at once
    # **AND A VARIABLE READ AFTER IT**, which is what makes the line above an
    # assertion rather than a decoration. A value stack that reserves too
    # little does not corrupt the expression - it corrupts whatever the chain
    # puts above it, and since wave 2a that is bas_nvar and the VARIABLE
    # TABLE (bas_vars, 192 bytes), not os88fp.inc's register A. Reserving
    # words instead of slots and running the deep line alone comes back 36,
    # correct, with x quietly gone. Measured: the mutation PASSED this row
    # until this line existed.
    ("PRINT x",                          "7"),
    ("PRINT 10-3",                       "7"),
    ("PRINT 10/4",                       "2.5"),     # `/` is REAL division
    ("PRINT 10\\3",                      "3"),       # `\` is integer division
    ("PRINT -10",                        "-10"),     # unary minus
    ("PRINT n",                          "0"),       # never assigned reads 0
    ("N = 3",                            None),
    ("PRINT n + N",                      "6"),       # ...and names fold case
]

QCHAR = {" ": "spc", "=": "equal", "+": "shift-equal", "-": "minus",
         "*": "shift-8", "/": "slash", "\\": "backslash",
         "(": "shift-9", ")": "shift-0", "\n": "ret"}

FAILED = []


def check(cond, what, why="", got=None, want=None):
    if cond:
        print("  ok   %s" % what)
        return True
    FAILED.append(what)
    print("  FAIL %s" % what)
    if want is not None:
        print("       want: %r" % (want,))
    if got is not None:
        print("       got:  %r" % (got,))
    if why:
        print("       why:  %s" % why)
    return False


class Qemu:
    """QMP, one connection per command - never a persistent one.

    `-qmp unix:...,server,nowait` serves a SINGLE client, so a held
    connection parks every other tool in the listen backlog for ever, which
    reads exactly like the guest having hung. tests/ethernet.py's class, with
    only what this row uses.
    """

    def __init__(self, path=None):
        self.path = path or os88qemu.SOCK
        self.tmp = tempfile.mkdtemp(prefix="basiclang")
        for _ in range(150):
            try:
                self.hmp("info status")
                return
            except OSError:
                time.sleep(0.2)
        raise RuntimeError("no QMP socket at %s" % self.path)

    def hmp(self, cmd):
        k = re.match(r"^sendkey (\S+)$", cmd)
        if k is not None:                       # CONFIRMED, per os88qemu
            os88qemu.sendkey(self.path, k.group(1))
            return ""
        # QMP ON THIS CONNECTION, never a tools/qmp.py subprocess from
        # inside one. `-qmp ...,server,nowait` serves a SINGLE client: hold
        # the socket and spawn the tool and the tool sits in the listen
        # backlog for ever, which is not an error and not a return - it reads
        # exactly like the guest having hung on the gesture. (It did: the
        # first version of this class did both and the row never printed a
        # line.)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.path)
        f = s.makefile("rw")

        def send(obj):
            f.write(json.dumps(obj) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("QMP closed")
                msg = json.loads(line)
                if "event" not in msg:
                    return msg
        try:
            json.loads(f.readline())            # the greeting
            send({"execute": "qmp_capabilities"})
            r = send({"execute": "human-monitor-command",
                      "arguments": {"command-line": cmd}})
            return r.get("return", "")
        finally:
            f.close()
            s.close()

    QKEYS = {"ArrowDown": "down", "ArrowUp": "up", "Home": "home",
             "End": "end", "PageDown": "pgdn", "PageUp": "pgup",
             "Tab": "tab", "Enter": "ret"}

    def key(self, name):
        self.hmp("sendkey " + self.QKEYS[name])
        os88qemu.pace(self, 0.05)

    def read(self, linear, n):
        p = os.path.join(self.tmp, "m.bin")
        # THE FILENAME IS QUOTED: HMP parses an unquoted path as an
        # EXPRESSION and answers "invalid char 't'", which reads as a bad
        # address rather than a bad argument.
        self.hmp('pmemsave 0x%X %d "%s"' % (linear, n, p))
        with open(p, "rb") as f:
            return f.read()

    def readseg(self, seg, off, n):
        return self.read(os88qemu.lin(seg, off), n)

    def lin(self, seg, off=0):
        return os88qemu.lin(seg, off)

    def quit(self):
        try:
            self.hmp("quit")
        except Exception:
            pass


class Mouse:
    """The three gestures tests/dispcp.py asks of a pointer, DEAD-RECKONED.

    dispcp names its fallback: tools/mouse.py, which walks the pointer and
    paces itself in GUEST time. ethernet.py's Mouse is closed-loop on the
    kernel's own `mouse_x`/`mouse_btn` and is the better one under a loaded
    soak; this row opens two windows and then never touches the mouse again,
    so the fallback is the whole of what it needs.

    THE SOCKET IS READ AT CALL TIME. os88qemu.make_test re-points SOCK at the
    machine it launched, and a Mouse that captured it at construction drives
    whatever instance happened to be there first.
    """

    def _mouse(self, *a):
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mouse.py"),
                        os88qemu.SOCK] + list(a), cwd=ROOT,
                       capture_output=True)

    def _hmp(self, *c):
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "qmp.py"),
                        os88qemu.SOCK] + list(c), cwd=ROOT,
                       capture_output=True)

    def click(self, x, y, settle=None, **kw):
        self._mouse("click", str(x), str(y))

    def dblclick(self, x, y, settle=None, **kw):
        # tools/mouse.py has no double click (it would be two processes and
        # the gap between them is the host's): the pointer is parked first
        # and BOTH button pairs go in ONE qmp.py call, so the only time
        # between them is the guest's own.
        self._mouse("to", str(x), str(y))
        self._hmp("mouse_button 1", "sleep 0.05", "mouse_button 0",
                  "sleep 0.06", "mouse_button 1", "sleep 0.05",
                  "mouse_button 0", "gsleep 0.5")

    def menu(self, px, py, ix, iy, settle=None, **kw):
        self._mouse("to", str(px), str(py))
        self._hmp("mouse_button 1", "gsleep 0.2")
        self._mouse("to", str(ix), str(iy))
        self._hmp("mouse_button 0", "gsleep 0.3")


def settle(m, card=None):
    """The UI task finished with what it was given - a CEILING, not a pause."""
    os88qemu.ui_done(m, S, cap=2.0)


def typ(m, text):
    """os88qemu.type_text: EVERY KEYSTROKE CONFIRMED.

    Firing `sendkey` per character and moving on types 160 keys in 0.9
    seconds and loses some of them - measured, and the editor showed it:
    `PRINT n` and `N = 3` arrived merged as `N =3RINT n`. type_text releases
    each key only once the ROM has STORED the press, which is the whole
    difference between a row that types a program and a row that types most
    of one.
    """
    os88qemu.type_text(m.path, text)


def console_lines(m):
    """Every non-blank line of the console BUFFER, in order.

    The buffer is located by its own content - the banner, as cells - so this
    needs no kernel symbol and no package map, and works on a package the
    loader put wherever it liked.
    """
    img = m.read(0, 0x100000)
    pat = BANNER.encode()
    nxt = b"Ready"
    at = -1
    # TWO ROWS, NOT ONE. The banner alone matched in the package IMAGE, where
    # the same letters sit as a plain string and the every-other-byte test can
    # still land on them by accident - and the row then read code as text and
    # reported a screenful of NULs. `Ready` one row below is the confirmation:
    # bas_conreset writes the pair together and nothing else in memory has
    # them a row apart AS CELLS.
    for i in range(len(img) - ROW - 2 * len(nxt)):
        if img[i] != pat[0]:
            continue
        if not all(img[i + 2 * k] == pat[k] for k in range(len(pat))):
            continue
        j = i + ROW
        if all(img[j + 2 * k] == nxt[k] for k in range(len(nxt))):
            at = i
            break
    if at < 0:
        return None
    print("      console buffer: banner at 0x%X" % at)
    # BOUND IT BY THE ATTRIBUTE BYTE. A cell is (character, attribute) and
    # the console writes ONE attribute for the whole pane, so every odd byte
    # of a real row is that value and no row of package image is. Without
    # this the window either side of the banner came back as "lines" of
    # decoded code - the answers were right and buried in it.
    attr = img[at + 1]
    rows = []
    base = at
    while base - ROW >= 0 and all(img[base - ROW + 2 * c + 1] == attr
                                  for c in range(CON_COLS)):
        base -= ROW                                   # up to the first row
    lo, n = base, 0
    while (lo + (n + 1) * ROW <= len(img) and n < CON_ROWS
           and all(img[lo + n * ROW + 2 * c + 1] == attr
                   for c in range(CON_COLS))):
        n += 1
    out = []
    for base in range(lo, lo + n * ROW, ROW):
        if base + ROW > len(img):
            break
        # PRINTABLE ONLY. `str.strip()` does not remove NUL - it is not
        # whitespace - so a row of zeroed cells came through as a "line" 80
        # characters long and the comparison printed the whole buffer.
        txt = "".join(chr(img[base + 2 * c])
                      if 32 <= img[base + 2 * c] < 127 else " "
                      for c in range(CON_COLS)).strip()
        if txt:
            out.append(txt)
    return out


def pane_has_ink(m):
    """The console pane is DRAWN - text lit INSIDE it, not pixels anywhere.

    The first version counted lit pixels in the lower half of the SCREEN and
    passed with the pane stone blank, because most of that half is desktop:
    a 50% dither is half lit and swamps anything the window does. It was a
    vacuous assertion and the mutation proved it - taking con_takescroll out
    of bas_paint left every check green.

    So the pane is found by what makes it unmistakable: it is the only SOLID
    BLACK on the screen. A dither alternates, so its longest run of dark
    pixels is one or two; the pane's is its full width. Rows carrying a long
    dark run are the pane, and the white pixels in them are its TEXT.
    """
    png = os.path.join(m.tmp, "pane.png")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"),
                    m.path, png], capture_output=True, cwd=ROOT)
    try:
        from PIL import Image
    except ImportError:
        return None
    im = Image.open(png).convert("L")
    w, h = im.size
    px = im.load()
    lit = rows = 0
    for y in range(h):
        run = best = 0
        for x in range(w):
            if px[x, y] < 128:
                run += 1
                best = max(best, run)
            else:
                run = 0
        if best < 300:                      # not the pane: dither or chrome
            continue
        rows += 1
        lit += sum(1 for x in range(w) if px[x, y] >= 128
                   and 0 < x < w - 1 and px[x - 1, y] < 128 or
                   (px[x, y] >= 128 and _in_dark_row(px, w, y, x)))
    return lit if rows else 0


def _in_dark_row(px, w, y, x):
    """`x` lies inside the pane's dark span on row `y`."""
    left = right = False
    for i in range(x - 1, max(-1, x - 400), -1):
        if px[i, y] < 128:
            left = True
            break
    for i in range(x + 1, min(w, x + 400)):
        if px[i, y] < 128:
            right = True
            break
    return left and right


def main():
    os88fixture.need("build/basic.img")
    os88qemu.make_test("TESTAPPS=build/basic.img")
    m = Qemu()
    os88qemu.own(sock=m.path)
    os88qemu.kernel_up(m, S, secs=180)

    # B:, then APPS, then the package - BY NAME at every step. dispcp.open_*
    # looks the row up in the staged listing and CHECKS it before it clicks,
    # which is the only way a gate should name a file: a coordinate drifts
    # with the window and a miss reads as the package having failed to start.
    mo = Mouse()
    dispcp.open_drive(m, mo, S, settle, "B")
    wins = dispcp.win_list(m, S)
    wx, wy = dispcp.win_rect(m, S, wins[-1])[:2]
    dispcp.open_named(m, mo, S, settle, wx, wy, "APPS")
    dispcp.open_named(m, mo, S, settle, wx, wy, "BASIC.O88")

    t0 = time.time()
    for line, _ in PROGRAM:
        typ(m, line + "\n")
    print("      typed %d lines in %.1fs" % (len(PROGRAM), time.time() - t0))
    os88qemu.sendkey(m.path, "f5")      # the Run key, confirmed
    os88qemu.pace(m, 6.0)

    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "shot.py"),
                    m.path, os.path.join(m.tmp, "end.png")],
                   capture_output=True, cwd=ROOT)
    print("      screen: %s" % os.path.join(m.tmp, "end.png"))
    got = console_lines(m)
    if not check(got is not None, "the console buffer is found by its banner",
                 why="no run can be read without it"):
        return 1
    want = [e for _, e in PROGRAM if e is not None]
    answers = [g for g in got if g not in (BANNER + " - SPEC.md 126", "Ready")]
    check(answers == want,
          "every line of the program answers what SPEC.md 126 says it does",
          why="the language is what this row is for; an answer that is merely "
              "PLAUSIBLE is the failure mode (-2.668453E+307 was not)",
          got=answers, want=want)

    # --- and now the RENDERER, which needs more than one run ---------------
    # The answers are read above, while the banner is still in the buffer and
    # can anchor it. The scroll defect needs REPEATED paint cycles - a single
    # run leaves the pane drawn with bas_paint's con_takescroll deleted, which
    # is a mutation that passed - so two more runs happen here, after the text
    # is in hand. They also scroll the banner off the top, which is why the
    # order is not the other way round.
    for _ in range(2):
        os88qemu.sendkey(m.path, "f5")
        os88qemu.pace(m, 6.0)

    lit = pane_has_ink(m)
    if lit is not None:
        check(lit > 50,
              "the console pane is DRAWN, not just right in the buffer",
              why="os88con.inc's scroll debt is the carrier's to settle, and "
                  "a carrier that does not leaves the pane blank with every "
                  "cell behind it correct (bas_paint owes con_takescroll)",
              got="%d lit pixels" % lit, want="> 50")

    print("basiclang: %s" % ("FAILED: " + ", ".join(FAILED) if FAILED
                             else "all checks passed"))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
