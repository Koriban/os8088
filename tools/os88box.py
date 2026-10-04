#!/usr/bin/env python3
"""Drive 86Box with a display, and take the picture (SPEC.md 39.29.8.2).

    python3 tools/os88box.py vm/vbeos --shot build/vbebox.png

WHY THIS EXISTS. 86Box is the only emulator in this tree that can enter VBE
mode 0104h: QEMU's Bochs BIOS advertises the mode and then cannot map the
window at A000, so a refusal is the only thing testable there (SPEC.md
39.28.2.1). But 86Box has no QMP, no monitor and no headless mode of its own,
so every VBE defect so far was found by photographing a laptop - FIVE field
round trips for one feature.

`QT_QPA_PLATFORM=offscreen` runs it with no display, which is enough to let a
guest write a disk sector (that is `make vbesetbox`) and no use at all for
looking at a SCREEN. An x11grab of this host's root is black, because the
session is Wayland and XWayland does not composite into it.

So this gives 86Box a display of its own: a real X server, Xvfb, on a private
display number. Then the screen is reachable two ways and both are used -

  - 86Box's OWN screenshot (Ctrl+F11), which writes a PNG of the EMULATED
    framebuffer into <vm>/screenshots/. That is the one to want: it is the
    guest's own pixels at the guest's own resolution, with no window chrome,
    no scaling and no host colour management in the way.
  - an xwd of the 86Box window, as the fallback for when the hotkey does not
    land - which tells you something is wrong rather than nothing.

AND IT MAKES INPUT POSSIBLE AT ALL. xdotool can type and click into a real X
window, so a machine that could previously only be started and watched can now
be driven. That is what `--key` and `--click` are for.

WHAT DOES NOT WORK, MEASURED, SO NOBODY REDOES IT: pointer MOTION.
86Box captures the pointer and WARPS IT BACK to the centre of its render area
after every motion event, and it forwards the warp's own delta to the guest as
well - so an XTEST `mousemove_relative dx dy` and the warp that follows it
cancel exactly. `--do probe` prints the host pointer and it reads the SAME
coordinate after every move (534,452 here, pinned). The guest arrow jitters in
a ~70px box around wherever it started and goes nowhere: driving it to
(950,700) left the changed pixels at guest (439..520, 317..396), which is where
it already was. Using `--window` is worse, not better - that sends SYNTHETIC
XSendEvent, which the grabbing render widget ignores outright, and then not
even the jitter happens.

KEYS DO work (Ctrl+F11 is how the screenshot is taken), so this is specific to
the pointer and the warp.

THE ROUTE THAT SHOULD WORK is not X at all: 86Box has serial passthrough with
a "Create pseudoterminal" and a "TCP/IP listening port" mode, and os8088 wants
a Microsoft serial mouse on COM1 - so the harness can BE the mouse and write
the protocol itself, the way tools/mouse.py drives QEMU's msmouse. The obstacle
to size first is SPEC.md 9.4.1's identify handshake: the driver toggles RTS/DTR
and expects an `M` back, and neither a pty nor a socket carries a modem control
line. Streaming `M` until the window opens is the likely answer.

KILLING 86Box: MATCH THE COMMAND LINE, NOT `comm`. The AppImage renames its
main thread to `qt_thread`, so a comm-based sweep misses it completely and
leaves instances running at ~70% CPU each. The VM path is in the cmdline and
cannot collide with anything else on this host.
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def box_binary():
    """the same search the Makefile does, so one of them is not a second list"""
    import glob
    for c in sorted(glob.glob(os.path.expanduser(
            "~/.local/opt/86box/86Box*.AppImage"))):
        if os.access(c, os.X_OK):
            return c
    for n in ("86Box", "86box"):
        p = shutil.which(n)
        if p:
            return p
    return None


def free_display(lo=90, hi=120):
    """a display number nothing else on this host has taken"""
    for n in range(lo, hi):
        if not os.path.exists("/tmp/.X%d-lock" % n) and \
           not os.path.exists("/tmp/.X11-unix/X%d" % n):
            return n
    raise RuntimeError("no free X display between :%d and :%d" % (lo, hi))


def procs_matching(needle):
    """PIDs whose CMDLINE contains `needle`, never this process or its parent.

    ps+awk rather than pgrep -f: `-f` matches the killing shell's own command
    line, which is this repo's own recorded trap.
    """
    out = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True,
                         text=True).stdout
    mine = {os.getpid(), os.getppid()}
    hits = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, args = line.partition(" ")
        try:
            pid = int(pid)
        except ValueError:
            continue
        if pid in mine or needle not in args:
            continue
        hits.append(pid)
    return hits


def reap(needle, what):
    pids = procs_matching(needle)
    for p in pids:
        try:
            os.kill(p, signal.SIGTERM)
        except OSError:
            pass
    if pids:
        time.sleep(1.0)
        for p in procs_matching(needle):
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass
        print("  reaped %d stale %s" % (len(pids), what))


class Xvfb:
    def __init__(self, w, h):
        self.n = free_display()
        self.disp = ":%d" % self.n
        self.p = subprocess.Popen(
            ["Xvfb", self.disp, "-screen", "0", "%dx%dx24" % (w, h),
             "-nolisten", "tcp"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if os.path.exists("/tmp/.X11-unix/X%d" % self.n):
                time.sleep(0.3)
                return
            if self.p.poll() is not None:
                raise RuntimeError("Xvfb died on startup")
            time.sleep(0.1)
        raise RuntimeError("Xvfb never came up on %s" % self.disp)

    def env(self):
        e = dict(os.environ)
        e["DISPLAY"] = self.disp
        e["QT_QPA_PLATFORM"] = "xcb"      # a REAL X server, so not offscreen
        e.pop("WAYLAND_DISPLAY", None)
        e.pop("XDG_SESSION_TYPE", None)
        return e

    def stop(self):
        if self.p and self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.kill()


def xdo(env, *args):
    """ALWAYS XTEST, never `--window`.

    `xdotool click --window <id>` sends a SYNTHETIC XSendEvent, and Qt's render
    widget - which has the pointer GRABBED while 86Box has the mouse captured -
    ignores synthetic events outright. The first version of this harness used
    --window and the guest pointer never moved: the only pixels that changed
    between a click run and a no-click run were the menu bar CLOCK. Without
    --window xdotool goes through the XTEST extension, which the server
    delivers exactly as it delivers real hardware, grabs included.
    """
    return subprocess.run(["xdotool", *args], env=env,
                          capture_output=True, text=True)


def win_geom(env, win):
    r = xdo(env, "getwindowgeometry", "--shell", win).stdout
    g = dict(l.split("=", 1) for l in r.strip().splitlines() if "=" in l)
    return (int(g["X"]), int(g["Y"]), int(g["WIDTH"]), int(g["HEIGHT"]))


# The serial mouse's own limits, which are the guest's and not the host's:
# the Microsoft protocol truncates a large delta, and 1200 baud drops a packet
# that is still in flight. tests/curtrail.py settled these against QEMU and
# they are the same protocol here.
STEP = 60
PACE = 0.06


class Pointer:
    """the guest's arrow, in GUEST pixels, over a captured relative mouse.

    86Box hands the guest RELATIVE motion once it has captured the pointer, so
    there is no host->guest coordinate map to get wrong - and no need for one.
    Absolute position is reached the way tests/curtrail.py reaches it: shove
    the arrow into a corner until the KERNEL'S OWN EDGE CLAMP has it pinned,
    which is a known position, then walk back from there.
    """

    def __init__(self, env, win, w, h):
        self.env, self.win, self.w, self.h = env, win, w, h
        self.captured = False

    def capture(self):
        """click once in the middle of the window, which is certainly inside
        the render area whatever chrome 86Box has put around it"""
        x, y, ww, wh = win_geom(self.env, self.win)
        xdo(self.env, "mousemove", str(x + ww // 2), str(y + wh // 2))
        time.sleep(0.3)
        xdo(self.env, "click", "1")
        time.sleep(1.2)
        self.captured = True

    def rel(self, dx, dy):
        while dx or dy:
            cx = max(-STEP, min(STEP, dx))
            cy = max(-STEP, min(STEP, dy))
            xdo(self.env, "mousemove_relative", "--", str(cx), str(cy))
            time.sleep(PACE)
            dx -= cx
            dy -= cy

    def goto(self, gx, gy):
        if not self.captured:
            self.capture()
        for _ in range((max(self.w, self.h) + STEP - 1) // STEP):
            xdo(self.env, "mousemove_relative", "--", str(STEP), str(STEP))
            time.sleep(PACE)
        self.rel(gx - (self.w - 1), gy - (self.h - 1))

    def click(self, gx, gy):
        self.goto(gx, gy)
        time.sleep(0.3)
        xdo(self.env, "click", "1")
        time.sleep(0.8)

    def dclick(self, gx, gy):
        self.goto(gx, gy)
        time.sleep(0.3)
        xdo(self.env, "click", "--repeat", "2", "--delay", "80", "1")
        time.sleep(1.2)

    def drag(self, x1, y1, x2, y2):
        self.goto(x1, y1)
        time.sleep(0.3)
        xdo(self.env, "mousedown", "1")
        time.sleep(0.3)
        self.rel(x2 - x1, y2 - y1)
        time.sleep(0.3)
        xdo(self.env, "mouseup", "1")
        time.sleep(1.0)

    def release(self):
        """give the pointer back to the host - 86Box's own hotkey"""
        xdo(self.env, "key", "ctrl+End")
        time.sleep(0.4)
        self.captured = False


def find_window(env, tries=60):
    for _ in range(tries):
        r = xdo(env, "search", "--onlyvisible", "--class", ".")
        ids = [w for w in r.stdout.split() if w.strip()]
        for w in ids:
            nm = xdo(env, "getwindowname", w).stdout.strip()
            if nm and "86Box" in nm:
                return w, nm
        if ids:                           # a window, but not named yet
            return ids[-1], xdo(env, "getwindowname", ids[-1]).stdout.strip()
        time.sleep(0.5)
    return None, None


def newest_png(d, after):
    if not os.path.isdir(d):
        return None
    best, bt = None, after
    for f in os.listdir(d):
        if not f.lower().endswith(".png"):
            continue
        p = os.path.join(d, f)
        t = os.path.getmtime(p)
        if t > bt:
            best, bt = p, t
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vmpath", help="the vm/<name> directory to run")
    ap.add_argument("--shot", help="where to put the PNG")
    ap.add_argument("--boot", type=float, default=90.0,
                    help="GUEST seconds to let it boot before looking")
    ap.add_argument("--screen", default="1280x1024",
                    help="the Xvfb screen, which must exceed the guest's")
    ap.add_argument("--guest", default="1024x768",
                    help="the GUEST's own geometry, which --do coordinates are "
                         "in and which the edge-clamp pin walks back from")
    ap.add_argument("--do", action="append", default=[], metavar="ACTION",
                    help="a step, repeatable and run in order. "
                         "click:X,Y  dclick:X,Y  drag:X1,Y1,X2,Y2  "
                         "key:ctrl+F11  shot:path.png  wait:SECONDS  release")
    ap.add_argument("--keep", action="store_true",
                    help="leave 86Box running (for a human to look)")
    a = ap.parse_args()

    box = box_binary()
    if not box:
        print("os88box: 86Box not found under ~/.local/opt/86box", file=sys.stderr)
        return 2
    if not shutil.which("Xvfb"):
        print("os88box: Xvfb is not installed - sudo apt install -y xvfb",
              file=sys.stderr)
        return 2
    if not shutil.which("xdotool"):
        print("os88box: xdotool is not installed", file=sys.stderr)
        return 2

    vm = os.path.abspath(os.path.join(ROOT, a.vmpath)) \
        if not os.path.isabs(a.vmpath) else a.vmpath
    if not os.path.isfile(os.path.join(vm, "86box.cfg")):
        print("os88box: no 86box.cfg in %s" % vm, file=sys.stderr)
        return 2
    if not os.path.isdir(os.path.join(vm, "nvr")) or \
       not os.listdir(os.path.join(vm, "nvr")):
        print("os88box: %s/nvr is empty. A cleared CMOS stops an AT BIOS in\n"
              "         SETUP, waiting for a key, and the run then does\n"
              "         nothing at all and says nothing about why:\n"
              "           cp vm/486/nvr/ami471.nvr %s/nvr/" % (vm, a.vmpath),
              file=sys.stderr)
        return 2

    w, h = (int(x) for x in a.screen.lower().split("x"))
    shots = os.path.join(vm, "screenshots")
    t0 = time.time()

    reap(vm, "86Box")
    x = None
    proc = None
    try:
        x = Xvfb(w, h)
        env = x.env()
        print("  Xvfb on %s, %dx%d" % (x.disp, w, h))
        proc = subprocess.Popen([box, "-P", vm, "-N"], env=env,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        win, name = find_window(env)
        if not win:
            print("os88box: 86Box never mapped a window", file=sys.stderr)
            return 1
        print("  86Box window %s %r" % (win, name))

        print("  booting, %.0fs..." % a.boot)
        time.sleep(a.boot)

        xdo(env, "windowactivate", "--sync", win)
        xdo(env, "windowfocus", win)

        gw, gh = (int(v) for v in a.guest.lower().split("x"))
        ptr = Pointer(env, win, gw, gh)

        def shoot(dest):
            """86Box's OWN screenshot, with an xwd of the window as the
            fallback so a run where the hotkey does not land says so"""
            dest = dest if os.path.isabs(dest) else os.path.join(ROOT, dest)
            os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
            mark = time.time() - 0.5
            xdo(env, "key", "ctrl+F11")
            for _ in range(20):
                time.sleep(0.5)
                g = newest_png(shots, mark)
                if g:
                    shutil.copyfile(g, dest)
                    from PIL import Image
                    print("  %s  %dx%d" % (dest, *Image.open(dest).size))
                    return
            xwd = dest + ".xwd"
            with open(xwd, "wb") as f:
                subprocess.run(["xwd", "-id", win], env=env, stdout=f,
                               check=True)
            from PIL import Image
            Image.open(xwd).save(dest)
            os.unlink(xwd)
            print("  %s <- xwd fallback (Ctrl+F11 did not land)" % dest)

        for step in a.do:
            op, _, arg = step.partition(":")
            n = [int(v) for v in arg.split(",")] if arg and op in (
                "click", "dclick", "drag") else None
            print("  do %s" % step)
            if op == "click":
                ptr.click(*n)
            elif op == "dclick":
                ptr.dclick(*n)
            elif op == "drag":
                ptr.drag(*n)
            elif op == "key":
                xdo(env, "key", arg)
                time.sleep(1.0)
            elif op == "wait":
                time.sleep(float(arg))
            elif op == "release":
                ptr.release()
            elif op == "goto":
                ptr.goto(*[int(v) for v in arg.split(",")])
            elif op == "rel":
                ptr.rel(*[int(v) for v in arg.split(",")])
            elif op == "probe":
                r = xdo(env, "getmouselocation", "--shell").stdout
                print("     host pointer: %s" % " ".join(r.split()))
            elif op == "shot":
                shoot(arg)
            else:
                print("os88box: unknown action %r" % step, file=sys.stderr)
                return 2

        if a.shot:
            shoot(a.shot)

        if a.keep:
            print("  --keep: 86Box left running on %s" % x.disp)
            return 0
    finally:
        if not a.keep:
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    proc.kill()
            reap(vm, "86Box")
            if x:
                x.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
