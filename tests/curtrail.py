#!/usr/bin/env python3
"""SPEC.md 7.1: the pointer's save-under puts back EXACTLY what was under it.

    make && python3 tests/curtrail.py

Move the arrow across the desktop and park it where it started: the screen
must be the pixel it was. That is the whole assertion, and nothing in this
tree made it before.

WHY IT EXISTS. SPEC.md 39.29 gave the renderer a live stride, and converting
`ROW_BYTES` - an immediate, touching no memory - into `[vid_stride]` changed
WHICH SEGMENT the read goes through. `vga_save_vram` points DS at VGA_SEG for
its `movsb` and `vga_restore_vram` points it at the save-under claim, so a
plain read fetched PIXELS and used them as the row step. The cursor, every
menu drop and every window save-under go through that one pair.

It shipped. It was found on a Toshiba Satellite 4025CDT, by eye, after four
round trips - and the reason no gate here saw it is not that the bug needed
1024x768. **It is visible at stride 80, on this emulator, in one screenshot**:
the mutation that restores the DS-relative read puts a line of debris across
the desktop exactly where the pointer went. What was missing was anybody
moving the pointer and looking.

So this is cheap and it is the test that would have caught the whole class on
the first `make`. It asserts no geometry and no stride: it asserts that moving
the arrow and putting it back changes nothing, which is true of every adapter
this OS drives and must stay true of any it learns.

THE MENU BAR CLOCK IS MASKED and nothing else is. Two shots a few seconds
apart can straddle a minute, and a test that fails for that would be a test
somebody turns off (SPEC.md 47's rule about refusing a fact rather than a
guess, applied to ourselves). The mask is the clock's cell only; a trail
anywhere else in the bar still fails.
"""
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import heapmap                                              # noqa: E402
import os88qemu                                             # noqa: E402
import shot                                                 # noqa: E402

SOCK = os.path.join(ROOT, "build", "curtrail.sock")
PIDFILE = os.path.join(ROOT, "build", "curtrail.pid")
PPM = os.path.join(ROOT, "build", "curtrail.ppm")
IMG = os.path.join(ROOT, "build", "os8088.img")

STEP = 60                       # the msmouse protocol truncates a large delta
PACE = 0.06                     # ...and 1200 baud loses a packet still in
                                # flight, which is tools/mouse.py's rule and
                                # the reason this walks rather than jumps
HOME = (600, 440)               # where the arrow sits for BOTH shots: the same
                                # pixels under it either time, so any
                                # difference is something it left behind
PATH = [(120, 120), (240, 180), (360, 240), (480, 300), (520, 380),
        (360, 300), (200, 220)]
CLOCK_W = 180                   # the menu bar cell the date and time live in


def kill_stale():
    os88qemu.kill(PIDFILE, SOCK)


def launch():
    em = "qemu" + "-system-i386"        # never whole on a command line
    subprocess.run(
        em + " -machine pc,vmport=off"
        " -drive file=%s,format=raw,if=floppy -boot a"
        " -chardev msmouse,id=m0 -serial chardev:m0"
        " -display none -qmp unix:%s,server,nowait -daemonize -pidfile %s"
        % (IMG, SOCK, PIDFILE), cwd=ROOT, shell=True, check=True)
    os88qemu.own(PIDFILE, SOCK)


def screen(q):
    q.hmp('screendump "%s"' % PPM)
    w, h, pix = shot.read_ppm(PPM)
    os.unlink(PPM)
    return w, h, pix


def walk(q, dx, dy):
    """one move, split into packets the protocol can carry"""
    while dx or dy:
        cx = max(-STEP, min(STEP, dx))
        cy = max(-STEP, min(STEP, dy))
        q.hmp("mouse_move %d %d" % (cx, cy))
        time.sleep(PACE)
        dx -= cx
        dy -= cy


def goto(q, w, h, x, y):
    """absolute, by pinning against the kernel's own edge clamp first"""
    for _ in range((max(w, h) + STEP - 1) // STEP):
        q.hmp("mouse_move %d %d" % (STEP, STEP))
        time.sleep(PACE)
    walk(q, x - (w - 1), y - (h - 1))


def main():
    kill_stale()
    try:
        launch()
        q = heapmap.Qmp(SOCK)
        for _ in range(200):
            try:
                q.hmp("info status")
                break
            except OSError:
                time.sleep(0.1)

        os88qemu.pace(q, 18)            # GUEST seconds: a desktop, settled
        w, h, _ = screen(q)
        goto(q, w, h, *HOME)
        os88qemu.pace(q, 1)
        before = screen(q)

        for x, y in PATH:
            goto(q, w, h, x, y)
        goto(q, w, h, *HOME)
        os88qemu.pace(q, 1)
        after = screen(q)

        q.hmp("quit")
    finally:
        kill_stale()

    (w, h, a), (_, _, b) = before, after
    bad = []
    for y in range(h):
        for x in range(w):
            if y < 16 and x >= w - CLOCK_W:
                continue                # the clock, and only the clock
            i = (y * w + x) * 3
            if a[i:i + 3] != b[i:i + 3]:
                bad.append((x, y))

    if os.environ.get("CURTRAIL_DUMP"):
        d = os.environ["CURTRAIL_DUMP"]
        from PIL import Image
        Image.frombytes("RGB", (w, h), bytes(a)).save(d + "-before.png")
        Image.frombytes("RGB", (w, h), bytes(b)).save(d + "-after.png")
        dif = bytearray(len(a))
        for i in range(0, len(a), 3):
            dif[i:i+3] = b"\xff\x00\x00" if a[i:i+3] != b[i:i+3] else a[i:i+3]
        Image.frombytes("RGB", (w, h), bytes(dif)).save(d + "-diff.png")
        print("  dumped %s-{before,after,diff}.png" % d)

    print("  %dx%d, pointer walked %d legs and parked where it started"
          % (w, h, len(PATH)))
    if bad:
        ys = sorted({y for _, y in bad})
        print("  %d pixels differ, on %d rows: first six %s"
              % (len(bad), len(ys), bad[:6]))
        print("curtrail: FAIL - the arrow left debris behind it. The "
              "save-under did not put back what it took, which is "
              "SPEC.md 7.1's whole contract. A stride read through the "
              "wrong segment is what did this last time (SPEC.md 39.29).")
        return 1
    print("curtrail: the screen is the pixel it was")
    return 0


if __name__ == "__main__":
    sys.exit(main())
