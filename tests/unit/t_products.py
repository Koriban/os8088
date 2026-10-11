#!/usr/bin/env python3
"""The SHIPPING configurations `make all` does not build (SPEC.md 19, 9.11.7).

    python3 tests/unit/t_products.py

WHY THIS EXISTS AND WHY IT IS NOT t_buildmatrix. That file already builds
`make emu` and `make small`, correctly and in a private tree - and it is in
the SOAK tier, because 99 knob configurations is not "did you break the
build" and it costs 143s. That is the right call for a KNOB, which is the A/B
half of some gate and rots in silence until somebody runs the gate.

It is the wrong call for a PRODUCT. The 2026-10-05 upstream merge broke FOUR
configurations - `kern_small`, `kern_emu`, `make combo` and `make combo720` -
and `make` plus `test-full` between them reported exactly one. The other
three were found by hand, days apart, one at a time, by a human typing the
target. A disk that SHIPS belongs in the pre-merge gate; a knob can wait for
soak.

So this row is the product subset and nothing else:

  * `make emu`        kern_emu, SPEC.md 9.11.7 - kern_big plus the VMware
                      absolute pointer, the only build that compiles that
                      feature at all. It broke at ASSEMBLY: the boot overlay
                      stopped fitting the blob when the merge's growth spent
                      kern_big's two-byte margin.
  * `make combo`      the system and apps on ONE floppy, 360KB/1.44MB/720KB.
    `combo144`        These broke at DISK PACKING rather than assembly - 78
    `combo720`        and 34 clusters over - which no amount of `nasm` would
                      ever have caught, and which is the commonest way a
                      merge that adds packages breaks a geometry.

kern_small is NOT here: `small128` already builds that kernel and BOOTS it on
a 128KB machine, which is strictly more than this file would ask.

IT RUNS IN THE SHARED TREE, deliberately, and that is safe for exactly these
targets: `emu` writes build/emuk/ and build/emu.img, `combo*` only pack
build/combo*.img, and NEITHER overwrites build/kernel.bin - which is the one
file a knob build in build/ must never touch, because tools/os88sym.py
refuses a map that does not match it. A private tree would be correct too and
costs minutes rather than ~31s, and at that price this would have gone in
soak beside the knobs and caught nothing.
"""
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# (make target, the image it must produce)
PRODUCTS = [
    ("emu",      "emu.img"),
    ("combo",    "combo.img"),
    ("combo144", "combo144.img"),
    ("combo720", "combo720.img"),
]

fails = []
checks = 0


def check(ok, what, why, got="", want=""):
    global checks
    checks += 1
    if ok:
        return
    msg = "  FAIL: %s\n        %s" % (what, why)
    if want:
        msg += "\n        want: %s\n        got:  %s" % (want, got)
    fails.append(msg)


def main():
    for target, img in PRODUCTS:
        t0 = time.time()
        r = subprocess.run(["make", target], cwd=ROOT,
                           capture_output=True, text=True)
        dt = time.time() - t0
        tail = (r.stderr or r.stdout or "").strip().splitlines()
        tail = "\n              ".join(tail[-4:]) if tail else "(no output)"
        check(r.returncode == 0,
              "`make %s` builds" % target,
              "a configuration that SHIPS and that `all` does not build. The "
              "2026-10-05 merge broke four of these and the gates reported "
              "one; this row is why the next one reports all of them",
              got=tail, want="exit 0")
        if r.returncode != 0:
            continue
        p = os.path.join(ROOT, "build", img)
        check(os.path.exists(p),
              "...and build/%s exists" % img,
              "a target that exits 0 without leaving its image has not built "
              "it - the recipe ran and the disk step was skipped or renamed",
              got="absent", want=p)
        print("  ok  %-10s %5.1fs  %s" % (target, dt, img))

    print("t_products: %d checks passed, %d FAILED"
          % (checks - len(fails), len(fails)))
    for f in fails:
        print(f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
