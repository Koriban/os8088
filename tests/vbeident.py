#!/usr/bin/env python3
"""MODE 12h MUST BE BYTE-IDENTICAL: the VGA renderer's before/after gate.

    make
    python3 tests/vbeident.py --save build/vbeident-before.cap   # BEFORE
    ... change kernel/vga12.inc ...
    make
    python3 tests/vbeident.py --ref  build/vbeident-before.cap    # AFTER
    python3 tests/vbeident.py --ref ... --mutate                   # prove it bites
    python3 tests/vbeident.py --ref ... --cutrow 200               # fire the CUT

SPEC.md 39.29's verification asks for exactly this and names why: stage 2 puts
ONE body in front of both mode 12h and the banked VBE mode, so mode 12h's
output has to be proved unchanged across the change - and the classic failure
is a row advance or a straddle cut written one site wrong, which moves pixels
on the adapter nobody was looking at.

**IT IS A BEFORE-PHOTO, AND THAT IS LEGITIMATE HERE FOR ONE REASON**: what is
being compared is the SAME render, not a fast path against a stale picture of
a different one (the trap docs/plans and PERFORMANCE.md Part 3 both record).
Every frame below is a settled screen with the pointer parked and the saver
off, so the capture is a pure function of the kernel - which `--twice` is the
fixture check for: two runs of the SAME build must answer 0 differing pixels,
or this gate cannot say anything about two different ones.

**AND IT HAS TO BE ABLE TO FAIL.** `--mutate` pokes one bit of `gfx_lmtab`
entry 0 - the left-edge mask every byte-aligned rect in the system looks up in
`gfx_rect_setup` - before a pixel is drawn, and asserts the capture DOES
differ. It is a runtime poke and not a build, so it needs no knob and cannot
go stale; and it sits on exactly the path this change touches. A gate of this
shape that has never been seen red is the defect class os8088 has paid for
repeatedly: a fixture that never reaches the code passes every assertion in
it.

**`--cutrow N` IS THE POSITIVE TEST FOR THE STRADDLE CUT**, and it is the
reason this gate is worth more than a before-photo. A correct cut is
PIXEL-NEUTRAL: running a rect primitive twice over two halves of its own rect
must put the same pixels on the glass as running it once. So poking
`[vbe_cutrow]` to a row in the middle of a mode 12h screen makes the cut fire
on an adapter every emulator here has, where the answer must still be 0
differing pixels - and an off-by-one at the boundary, a half drawn with the
wrong y, or a row drawn twice shows up immediately. The banked mode itself
cannot be entered under QEMU or MartyPC at all (SPEC.md 39.29.8), so without
this the cut would only ever be exercised on hardware.

THE FRAMES, chosen so the rect primitives are all on the glass at once:

  desk   the bare desktop - the pattern fill (gfx_fill_pat_raw / _gray_raw),
         the dock, the icon blits (gfx_blitp)
  disk   ...plus a Disk window on B: - gfx_frame, the title bar, the content
         fill, every icon and every label
  calc   ...plus the Calculator, which is the one package in the tree chosen
         for having nothing that moves (dispcorner.py's SUBJECT: no worker, no
         clock, it draws once and stops)
  paint  ...plus Paint - a fourth window of chrome, captured always and
         compared only between two runs of one build. It does NOT reach
         gfx_blitp's planar path; the note beside EXTRA says why, and that
         note is the correction of what this frame was added for
And a fourth check that needs NO reference, because it compares this kernel
against itself: the System menu is dropped and dismissed with no command, and
the screen afterwards must be byte-identical to the screen before. That is the
save-under pair (vga_save_vram / vga_restore_vram) round-tripping, and it is
non-vacuous in the only direction that matters - a restore that loses pixels
leaves the pull-down's own on the glass.

THE MENU BAR'S TOP MBAR_H ROWS ARE MASKED, for assocglyph.py's reason: the bar
carries a clock (SPEC.md 12.9) and two captures minutes apart would otherwise
be comparing the time of day. Everything the bar draws is drawn again by the
windows below it.
"""
import argparse
import gzip
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import os88marty, os88ui, os88build, os88mouse           # noqa: E402
import os88geom as geom                                  # noqa: E402

MBAR_H = geom.MBAR_H
PARK = (4, MBAR_H + 4)
FRAMES = ("desk", "disk", "calc")       # the ones a --save/--ref carries
# ...and one more, captured always and compared only between two runs of the
# SAME build, so it needs no stored reference.
#
# **IT DOES NOT REACH `gfx_blitp`, AND IT WAS ADDED BELIEVING IT WOULD.** The
# intent was to gate 39.29.10.5's straddle test on gfx_blitp's plane-major
# path, Paint being the kernel's only caller of it - and the mutation says
# otherwise: breaking gfx_blitp's general `.row` path by a byte changes
# nothing in this frame. Paint opens with a PACKED canvas, ASKS whether
# gfx_blitp works during a repaint (SPEC.md 5.4.3.2's probe), converts with
# pt_toplanar only if told yes, and blits planar from the repaint AFTER that -
# so one open and one settle never gets there. What the frame is worth is
# what it turned out to be: a fourth window's worth of chrome, fills and
# frames on the mode 12h identity surface. Reaching the planar path would
# need the conversion forced and a second repaint driven, which is
# tests/paintpack.py's territory.
EXTRA = ("paint",)


def u16(b, i=0):
    return b[i] | (b[i + 1] << 8)


def mask_bar(data, w):
    """Blank the menu bar's rows - the clock lives there (SPEC.md 12.9)."""
    out = bytearray(data)
    for i in range(0, min(len(out), MBAR_H * w * 3)):
        out[i] = 0
    return bytes(out)


def diff(a, b, w):
    """[(x, y)] where two captures differ - dispcorner.py's helper."""
    return [((i // 3) % w, (i // 3) // w)
            for i in range(0, min(len(a), len(b)), 3) if a[i:i + 3] != b[i:i + 3]]


def bbox(d):
    if not d:
        return None
    xs, ys = [p[0] for p in d], [p[1] for p in d]
    return (min(xs), min(ys), max(xs), max(ys))


def capture(m):
    """One settled frame, bar masked."""
    m.pause()
    w, h, data = m.fbuf()
    m.run()
    return dict(w=w, h=h, data=mask_bar(data, w))


def exercise(image="build/os8088.img", apps="build/apps.img",
             machine="os8088_xt_vga_144", knobs=(), verbose=True,
             mutate=False, cutrow=None):
    """Boot, drive the frames, hand back {name: capture}.

    `mutate` and `cutrow` are POKED before the first pixel is drawn, so every
    frame below is rendered by the machine under the changed condition - no
    forced repaint, and so none of tools/notepad/pixcheck.py's "a repaint can
    be a byte copy of the save-under cache" problem (dispcorner.py's note).
    """
    os.chdir(ROOT)
    appsimg = os88build.at(apps)
    if knobs:
        t = os88build.tree(*knobs, targets=("os8088.img",)).apply()
        sysimg = t.img("os8088.img")
    else:
        os88build.plain().apply()
        sysimg = os88build.at(image)

    caps = {}
    with os88ui.boot(sysimg, apps=appsimg, machine=machine,
                     verbose=verbose) as ui:
        m = ui.m
        if mutate:
            a = ui._S("gfx_lmtab")
            was = m.read(a, 1)[0]
            m.write(a, bytes([was ^ 1]))
            print("      MUTANT: gfx_lmtab[0] %02X -> %02X" % (was, was ^ 1))
        if cutrow is not None:
            try:
                a = ui._S("vbe_cutrow")
            except Exception:
                sys.exit("vbeident: this kernel has no [vbe_cutrow] - the "
                         "straddle cut is not built yet, so --cutrow has "
                         "nothing to fire")
            m.write(a, struct.pack("<H", cutrow))
            print("      [vbe_cutrow] = %d: the straddle cut fires on mode 12h"
                  % cutrow)
        mo = os88mouse.Mouse(marty=m)
        mo.to(*PARK)                    # PARKED FOR EVERY CAPTURE, so the
        ui.settle()                     # arrow cancels out of every compare
        caps["desk"] = capture(m)

        ui.open_drive("B")
        mo.to(*PARK)
        ui.settle()
        caps["disk"] = capture(m)

        ui.path("APPS/CALC.O88")
        mo.to(*PARK)
        ui.settle()
        caps["calc"] = capture(m)

        ui.open_drive("B")              # back to the Disk window: `path`
        ui.path("APPS/PAINT.O88")       # walked it into APPS/ already
        mo.to(*PARK)
        ui.settle()
        caps["paint"] = capture(m)

        # ...and the save-under round trip: drop the System menu and dismiss
        # it with no command (press and release on the title itself), then
        # the screen must be what it was. No reference needed - this one
        # compares the kernel against itself one capture ago.
        cells = ui.menus()
        x0, x1 = cells[0][1], cells[0][2]
        cx, cy = (x0 + x1) // 2, MBAR_H // 2
        mo.menu(cx, cy, cx, cy)
        mo.to(*PARK)
        ui.settle()
        caps["_saveu"] = capture(m)
    return caps


def save(caps, path):
    blob = {}
    for k, c in caps.items():
        blob[k] = dict(w=c["w"], h=c["h"], n=len(c["data"]))
    with gzip.open(path, "wb") as f:
        f.write((json.dumps(dict(frames=FRAMES, meta=blob)) + "\n").encode())
        for k in FRAMES:
            f.write(struct.pack("<I", len(caps[k]["data"])))
            f.write(caps[k]["data"])


def load(path):
    with gzip.open(path, "rb") as f:
        hdr = json.loads(f.readline().decode())
        out = {}
        for k in hdr["frames"]:
            (n,) = struct.unpack("<I", f.read(4))
            m = hdr["meta"][k]
            out[k] = dict(w=m["w"], h=m["h"], data=f.read(n))
    return out


def compare(new, ref, frames=FRAMES):
    bad = []
    for k in frames:
        if k not in ref:
            bad.append("the reference has no %r frame" % k)
            continue
        a, b = new[k], ref[k]
        if (a["w"], a["h"]) != (b["w"], b["h"]):
            bad.append("%s: the capture is %dx%d and the reference %dx%d - a "
                       "diff of two different rasters is a number with no "
                       "meaning" % (k, a["w"], a["h"], b["w"], b["h"]))
            continue
        d = diff(a["data"], b["data"], a["w"])
        print("   %-5s %d differing pixel(s) of %d%s"
              % (k, len(d), a["w"] * a["h"],
                 "" if not d else "   bbox %r" % (bbox(d),)))
        if d:
            bad.append("%s: %d pixels differ from the reference" % (k, len(d)))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--save", metavar="PATH")
    ap.add_argument("--ref", metavar="PATH")
    ap.add_argument("--twice", action="store_true",
                    help="the FIXTURE check: two runs of this same build must "
                         "answer 0 differing pixels")
    ap.add_argument("--mutate", action="store_true",
                    help="prove the gate can fail: one bit of gfx_lmtab[0] "
                         "must move pixels")
    ap.add_argument("--cutrow", type=int, metavar="N",
                    help="poke [vbe_cutrow]=N so the straddle cut fires on "
                         "mode 12h, where it must be pixel-neutral")
    ap.add_argument("--image", default="build/os8088.img")
    ap.add_argument("--apps", default="build/apps.img")
    ap.add_argument("--machine", default="os8088_xt_vga_144")
    ap.add_argument("--knob", action="append", default=[], metavar="K=V")
    a = ap.parse_args()

    caps = exercise(a.image, a.apps, a.machine, knobs=tuple(a.knob))
    print()
    bad = []
    # the self-consistency check first: it needs no reference and it is the
    # one assertion here that holds on a FIRST run, before any --save exists
    d = diff(caps["_saveu"]["data"], caps["paint"]["data"],
             caps["paint"]["w"])
    print("   save-under round trip: %d differing pixel(s)%s"
          % (len(d), "" if not d else "   bbox %r" % (bbox(d),)))
    if d:
        bad.append("the System menu's save-under did not restore the screen: "
                   "%d pixels differ" % len(d))
    if a.save:
        save(caps, a.save)
        print("   reference -> %s" % a.save)
    if a.ref:
        bad = compare(caps, load(a.ref))
    if a.cutrow is not None:
        # SELF-CONTAINED, and that is the point: the cut run is compared
        # against a PLAIN run of the same build in the same invocation, so
        # this needs no stored capture and can stand as a suite row. A
        # correct cut is pixel-neutral, so the answer must be 0.
        print("   the SAME build with the straddle cut forced at row %d:"
              % a.cutrow)
        d = compare(exercise(a.image, a.apps, a.machine, knobs=tuple(a.knob),
                             cutrow=a.cutrow), caps, FRAMES + EXTRA)
        if d:
            bad += ["the straddle cut is NOT pixel-neutral: " + x for x in d]
        else:
            print("   ...identical, so running a rect primitive twice over "
                  "two halves of its own rect draws what running it once does")
    if a.twice:
        print("   second run of the SAME build:")
        bad += compare(exercise(a.image, a.apps, a.machine,
                                knobs=tuple(a.knob)), caps, FRAMES + EXTRA)
    if a.mutate:
        print("   the MUTANT (gfx_lmtab[0] ^ 1):")
        d = compare(exercise(a.image, a.apps, a.machine, knobs=tuple(a.knob),
                             mutate=True), caps, FRAMES + EXTRA)
        if not d:
            bad.append("the MUTANT produced an identical screen: these "
                       "captures do not reach gfx_rect_setup and this gate "
                       "cannot fail")
        else:
            print("   ...and it differs, so the gate bites")
    if bad:
        print()
        for b in bad:
            print("   FAIL: %s" % b)
        return 1
    print("\n   ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
