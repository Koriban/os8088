#!/usr/bin/env python3
"""A card that ADVERTISES 1024x768 and cannot map it is refused (SPEC.md 39.29.6)

    make && python3 tests/vberefuse.py

VBE.DRV's probe runs at BOOT - drv_boot_x, above the settings read and right
after the mount (39.29.5's third placement) - so this needs no clicking: the
machine has already decided by the time the desktop is up.

QEMU IS THE MACHINE THIS ROW WANTS, and that is not a limitation here but the
whole point. Its Bochs BIOS ANSWERS `int 10h AX=4F01h` for mode 0104h and
lists it as present, and the window it reports at A000 is not CPU-addressable:
tests/vbeset's raw probe reads 00 00 00 00 there against A5 A5 A5 A5 in mode
12h, exactly as the mode's own attribute word (003B, bit 5 set) advertises.

So QEMU is a BIOS THAT LIES, which is the case 39.29.6 exists for:

    "A BIOS can set the mode and still not put the framebuffer where a
     real-mode CPU can reach it."

VBV_PROVE sets the mode, writes one byte through the window, reads it back and
puts mode 12h again. If the read-back disagrees the bit stays CLEAR and the
Display page never grows a row - instead of growing one that has to be
RECOVERED from at the moment somebody picks it, with the desktop already in a
mode the renderer cannot reach.

  1 REFUSED   VID_A_VBE is clear in [vid_avail] after boot, on a machine
              whose BIOS said yes
  2 MODE 12h  ...and the desktop is still VID_VGA at 640x480, which is what
              "puts mode 12h again" has to leave behind
  3 ALIVE     ...and the machine is actually running, so 1 and 2 are not two
              readings of a kernel that died during the probe

WHAT THIS ROW DOES NOT CLAIM: that the mode WORKS anywhere. No emulator in
this tree can run it (39.29.8) and the Satellite 4025CDT is where every
positive case is verified and photographed. This is the negative case, and it
is the one that runs on every machine that is not that laptop.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "unit"))
import os88sym                                               # noqa: E402
import os88qemu                                              # noqa: E402
import os88geom as geom                                      # noqa: E402
from harness import check, done                              # noqa: E402

S = os88sym.linear
SOCK = "build/qmp.sock"


class Qemu(object):
    """The three QMP calls this row needs, and no more.

    tests/ethernet.py carries a fuller version of this and the two are NOT
    shared yet: promoting it belongs in a change that can re-run that row,
    and that one needs `make ethertest` and a NIC build. One connection per
    command for its stated reason - the socket serves a SINGLE client, so a
    held-open monitor makes every later tools/qmp.py sit in the backlog for
    ever, which reads exactly like the guest hanging.
    """

    def __init__(self, path=SOCK):
        self.path, self.tmp = path, tempfile.mkdtemp()
        for _ in range(150):
            try:
                self.hmp("info status")
                return
            except OSError:
                time.sleep(0.2)
        raise RuntimeError("no QMP socket at %s" % path)

    def hmp(self, cmd):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.path)
        f = s.makefile("rw")
        try:
            json.loads(f.readline())
            for obj in ({"execute": "qmp_capabilities"},
                        {"execute": "human-monitor-command",
                         "arguments": {"command-line": cmd}}):
                f.write(json.dumps(obj) + "\n")
                f.flush()
                while True:
                    line = f.readline()
                    if not line:
                        raise RuntimeError("QMP closed")
                    msg = json.loads(line)
                    if "event" not in msg:
                        break
            return msg.get("return", "")
        finally:
            s.close()

    def read(self, addr, n):
        out = os.path.join(self.tmp, "m.bin")
        # THE FILENAME IS QUOTED, and it has to be: HMP parses an unquoted
        # /tmp/... as an EXPRESSION and answers "invalid char 't'", which
        # reads as a bad ADDRESS rather than a bad argument.
        # tests/ethernet.py carries this same comment, which is where it was
        # found the second time.
        self.hmp('pmemsave 0x%X %d "%s"' % (addr, n, out))
        with open(out, "rb") as fh:
            return fh.read()


VID_VGA, VID_VBE = 0, 4
VID_A_VBE = 1 << VID_VBE


def main():
    os.chdir(os.path.join(HERE, ".."))
    os88qemu.own()                       # `make test` daemonises it; we own it
    r = subprocess.run(["make", "test"], capture_output=True, text=True)
    if r.returncode:
        sys.exit("vberefuse: make test failed:\n" + r.stdout + r.stderr)
    m = Qemu()
    b = lambda n: m.read(S(n), 1)[0]
    w = lambda n: (lambda v: v[0] | (v[1] << 8))(m.read(S(n), 2))

    # THE PROBE IS DONE BY THE TIME THE DESKTOP IS UP (39.29.5: drv_boot_x,
    # above the settings read), so this waits on the desktop and then reads a
    # decision already taken - there is nothing to drive and nothing to click.
    os88qemu.acted(m, lambda _m=None: w("vid_w") != 0, secs=90,
                   what="the kernel's geometry words", poll=0.5)
    os88qemu.pace(m, 2.0)
    avail, kind = b("vid_avail"), b("vid_kind")
    vw, vh = w("vid_w"), w("vid_h")
    # LIVENESS IS THE TICK COUNTER, not a window count. The first version
    # here counted visible windows and asserted at least one - and a bare
    # os8088 desktop HAS none: the Disk window opens on a double-click. It
    # reported 0 on a perfectly healthy machine, which is a check measuring
    # the wrong thing rather than a kernel that died.
    t0 = os88qemu.ticks(m)
    os88qemu.pace(m, 2.0)
    t1 = os88qemu.ticks(m)

    check(not (avail & VID_A_VBE), "1 REFUSED",
          "QEMU's BIOS lists mode 0104h and cannot map its window, so "
          "VBV_PROVE's write-and-read-back disagrees and the bit must stay "
          "CLEAR. A kernel that trusted the BIOS would light a Display row "
          "here, and picking it would put the desktop in a mode the "
          "renderer cannot reach - with no way back that does not go "
          "through the failure",
          got="[vid_avail]=0x%02X (VBE bit %s)"
              % (avail, "SET" if avail & VID_A_VBE else "clear"),
          want="bit 4 clear")
    check(kind == VID_VGA and (vw, vh) == (640, 480), "2 MODE 12h",
          "...and the probe put mode 12h back. VBV_PROVE leaves the card in "
          "the mode it found it in, so a refusal costs the desktop nothing - "
          "the geometry words here are the ones every primitive reads",
          got="vid_kind=%d, %dx%d" % (kind, vw, vh),
          want="vid_kind=0 (VID_VGA), 640x480")
    check(t1 != t0, "3 ALIVE",
          "...and the guest is still EXECUTING: the BIOS tick counter moved "
          "between two reads. Checks 1 and 2 both read zero-ish values and a "
          "kernel that died inside the probe - which sets a mode, writes "
          "through a window and sets another - would give the same two "
          "answers, so without this the row would pass on a corpse",
          got="BIOS ticks %d -> %d" % (t0, t1), want="advanced")
    done("vberefuse")


if __name__ == "__main__":
    sys.exit(main())
