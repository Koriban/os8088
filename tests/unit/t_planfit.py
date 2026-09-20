#!/usr/bin/env python3
"""PLAN still fits the 128KB machine, and still reaches the disks it exists for.

    python3 tests/unit/t_planfit.py

PLAN (SPEC.md 81.75) is SHEET cut down until a spreadsheet fits a floor
machine: `kern_small`'s free arena is 52.5KB (SPEC.md 11.102), and SPEC.md
24.5.2's rule is that a package's footprint is its REGION PLUS THE CLAIMS IT
MAKES TO FUNCTION.  SHEET's region alone is larger than the whole arena, which
is why it is in $(SMALLOMIT) and why this program exists.

THE NUMBER IS NOT A TARGET THAT WAS HIT ONCE.  It was reached with 1,062 bytes
to spare out of 51,712, which is two percent - a single feature added without
looking puts PLAN back over, and the symptom on the machine itself is not a
build error or a refusal.  It is a claim that fails, and then a spreadsheet
with no cells.  `make plan` prints the figure for a person; this is the same
arithmetic for the build, so the regression lands here and not on the 5150.

THE THREE VOLUMES ARE HALF OF IT.  A package that fits and ships nowhere has
not solved anything, and PLAN's whole premise is the disks SHEET cannot reach:
apps360.img, where SHEET has never fitted (SPEC.md 24.6.3), and the two
`make smallapps` floppies, which are the app disks for the machine SHEET is
omitted from.  tests/unit/t_livefull.py's EXEMPT_DIRS carried PLAN as a
deadline while that was still true; this file is what replaced the deadline.

What it does NOT check is that PLAN runs, which wants a machine.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import check, done                             # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# SPEC.md 11.102's arena less the ~2KB the Disk window is holding when a
# package is launched from it, which is how a user starts one.  The same
# figure the `plan` target in the Makefile measures against; spelt in both
# places because a gate that imports its bound from the thing it is gating
# checks nothing.
ARENA = 51712

# SPEC.md 50.6.2 - the largest SINGLE run kern_small can hand out.  A total
# that fits is not enough: SHEET's 32KB cells claim is under the arena and
# over this, which is the test that omitted SKIES.
RUN_MAX = 17 * 1024 + 512

BIN = os.path.join(ROOT, "build", "planapp", "plan.bin")
SRC = os.path.join(ROOT, "apps", "plan", "plan.asm")

IMGS = ["build/apps360.img", "build/smallapps360.img", "build/smallapps.img"]


def main():
    if not os.path.exists(BIN):
        check(False, "build/planapp/plan.bin is present to measure",
              "`make plan` builds it and `all` names $(PLANPKG), so a missing "
              "binary means the build did not run rather than that PLAN is "
              "small enough",
              got="missing", want="run `make plan`")
        done("t_planfit")
        return

    image = os.path.getsize(BIN)
    src = open(SRC, encoding="latin-1").read()
    m = re.search(r"OS88_BSS (\d+)", src)
    check(bool(m), "apps/plan/plan.asm declares its bss with a literal",
          "SPEC.md 20.1's OS88_BSS literal is self-checking - two TIMES lines "
          "turn the number into a build error when the chain moves - and it "
          "is also how anything outside the assembler learns the size",
          got="no OS88_BSS literal", want="OS88_BSS <n>")
    if not m:
        done("t_planfit")
        return
    bss = int(m.group(1))

    out = subprocess.run([sys.executable, "tools/planclaims.py", "--verbose"],
                         cwd=ROOT, capture_output=True, text=True)
    check(out.returncode == 0, "tools/planclaims.py reads the claims",
          "it refuses a total of zero on purpose, because the sh_ -> pl_ "
          "rename once left its pattern matching nothing and it reported a "
          "comfortable fit",
          got=(out.stderr or out.stdout).strip()[:200], want="exit 0")
    if out.returncode != 0:
        done("t_planfit")
        return

    claims = {}
    total = 0
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            claims[parts[0]] = int(parts[1])
        elif line.startswith("required "):
            total = int(parts[1].rstrip(","))

    region = image + bss
    check(region + total <= ARENA,
          "PLAN's region plus its claims fit the 128KB machine's arena",
          "SPEC.md 24.5.2 - region PLUS the claims it makes to function, "
          "against SPEC.md 11.102's 52.5KB less the Disk window. Over this "
          "line the failure is not a build error: a claim is refused on the "
          "machine and the spreadsheet opens with no cells",
          got="region %d (image %d + bss %d) + claims %d = %d"
              % (region, image, bss, total, region + total),
          want="<= %d" % ARENA)

    for name, size in sorted(claims.items()):
        check(size <= RUN_MAX,
              "PLAN's %s claim fits one run (%d bytes)" % (name, RUN_MAX),
              "SPEC.md 50.6.2 - the arena is not one block. A claim larger "
              "than the largest free RUN is refused however much is free in "
              "total, which is the rule that omitted SKIES",
              got="%d bytes" % size, want="<= %d" % RUN_MAX)

    try:
        from t_image import Vol
    except Exception as e:                                  # pragma: no cover
        check(False, "the FAT12 reader loads", got=str(e), want="t_image.Vol")
        done("t_planfit")
        return

    for rel in IMGS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            check(False, "%s is present to walk" % rel,
                  "declared in this row's wants=, so the runner builds it "
                  "before the row starts; a missing image is a row that "
                  "answered nothing, not a row that passed",
                  got="missing", want="run `make smallapps` and `make`")
            continue
        with open(path, "rb") as f:
            vol = Vol(f.read(), rel)
        found = [(folder, n11) for folder, n11, attr, _c, _s in vol.walk()
                 if not attr & 0x10
                 and n11[:8].decode("ascii", "replace").strip().upper() == "PLAN"
                 and n11[8:].decode("ascii", "replace").strip().upper() == "O88"]
        check(bool(found), "%s carries PLAN.O88" % rel,
              "PLAN exists for the volumes SHEET cannot reach - apps360.img "
              "(SPEC.md 24.6.3) and the two `make smallapps` floppies. A "
              "package that fits and ships nowhere has solved nothing, and "
              "the Makefile lists that carry it are three separate places "
              "for it to fall out of",
              got="absent", want="APPS/PLAN.O88")

    done("t_planfit")


if __name__ == "__main__":
    main()
