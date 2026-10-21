#!/usr/bin/env python3
"""t_a2dsk: the Disk II fixture builds, and its two sector orders are right.

    python3 tests/unit/t_a2dsk.py

APPLE2-SPEC section 14 says **no `.DSK` ships** - the images people run are
other people's - so the Disk II gate has to BUILD its fixture, and
`tools/a2dsk.py` is what builds it. A generator with no caller rots quietly;
this is the caller, and it costs milliseconds.

WHAT IT ACTUALLY PROTECTS is the pair of sector-order tables. Section 14 pins
DOS 3.3's `{00,07,0E,...}` and ProDOS's `{00,08,01,...}`, the extension alone
picks between them, and the two agree on logical 0 and on nothing else until
15 - so a reader that used the wrong one reads plausible bytes from the wrong
place and the only thing that ever says so is an assertion like this one.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import check, done                             # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import a2dsk                                                # noqa: E402

r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "a2dsk.py"),
                    "--selfcheck"], capture_output=True, text=True)
check(r.returncode == 0, "tools/a2dsk.py --selfcheck passes",
      why="it reads every sector under BOTH orders and checks the image "
          "against its own pinned sha256; a failure here is the pattern "
          "having moved under a gate that still holds the old bytes",
      got=(r.stdout + r.stderr).strip()[-300:], want="exit 0")

blob = a2dsk.build()
check(len(blob) == 143360, "the image is section 14's one size",
      why="35 x 16 x 256, headerless; a 40-track image is 163,840 and is "
          "refused with the number",
      got=len(blob), want=143360)

# THE TABLES THEMSELVES, AGAINST SECTION 14'S LITERALS - and this check is
# here because the row DID NOT HAVE IT and a mutation walked straight
# through. Swapping DOS33's entries 1 and 2 left every assertion below green:
# they compare `check(... order)` against `order[l]`, which is the same table
# on both sides of the equals, so they prove the OFFSET ARITHMETIC and the
# checksum and nothing whatever about the values. A reader using the wrong
# order reads plausible bytes from the wrong place; only a literal says so.
check(tuple(a2dsk.DOS33) == (0x00, 0x07, 0x0E, 0x06, 0x0D, 0x05, 0x0C, 0x04,
                             0x0B, 0x03, 0x0A, 0x02, 0x09, 0x01, 0x08, 0x0F),
      "DOS 3.3's sector order is section 14's",
      why="`.DSK` and `.DO` take this one and the extension alone picks it",
      got=tuple(a2dsk.DOS33))
check(tuple(a2dsk.PRODOS) == (0x00, 0x08, 0x01, 0x09, 0x02, 0x0A, 0x03, 0x0B,
                              0x04, 0x0C, 0x05, 0x0D, 0x06, 0x0E, 0x07, 0x0F),
      "ProDOS's sector order is section 14's",
      why="`.PO` takes this one", got=tuple(a2dsk.PRODOS))

# ...and they are PERMUTATIONS, which the literals above would also catch but
# which is worth failing separately: a duplicated entry makes one physical
# slot unreachable and another read twice.
for t, nm in ((a2dsk.DOS33, "dos"), (a2dsk.PRODOS, "prodos")):
    check(sorted(t) == list(range(16)), "%s order is a permutation of 0..15" % nm,
          why="a duplicate hides one slot and reads another twice", got=sorted(t))

# The two differ everywhere but 0 and 15 - which is why using the wrong one
# is invisible without the literals above.
same = [i for i in range(16) if a2dsk.DOS33[i] == a2dsk.PRODOS[i]]
check(same == [0, 15], "the two sector orders agree on 0 and 15 alone",
      why="a reminder of how little distinguishes them in use",
      got=same, want=[0, 15])

for order, name in ((a2dsk.DOS33, "dos"), (a2dsk.PRODOS, "prodos")):
    bad = [(t, l) for t in range(35) for l in range(16)
           if a2dsk.check(blob, t, l, order) != (t, order[l])]
    check(not bad, "%s: every logical sector reads its own physical slot" % name,
          why="the label in the sector is the PHYSICAL slot, so this is the "
              "order table applied and checked rather than assumed",
          got=bad[:4], want="none wrong")

done("t_a2dsk")
