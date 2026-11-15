#!/usr/bin/env python3
"""A refusal helper that RETURNS must never be reached by `jmp`.

    python3 tests/unit/t_basrefuse.py

`bas_err` (SPEC.md 150.7) prints the reason and **returns**. That makes
`jmp bas_err` the right ending for a statement body, which is reached with
nothing of its own on the stack - the `ret` then goes to bas_c_stmt's own
caller, which is exactly where a refused statement should end up.

It makes it WRONG for a helper that another routine calls. If routine R
ends in `jmp bas_err` and is reached by `jmp R` from a routine holding
pushed registers, bas_err's `ret` returns into those saved registers. The
refusal still PRINTS, correctly and with the right line, so every visible
symptom says the feature works - and the package is wedged from that moment
on. That is what `jmp bas_kinderr` did in SPEC.md 150.25's kind check: the
sentence appeared, and the NEXT program typed into the editor never ran, so
the row read the previous program's console and reported the previous
program's refusal. The bug looked like a wrong message.

THE RULE IS SOUND AND NEEDS NO FLOW ANALYSIS: a helper that is ever
`call`ed must never be `jmp`ed to, because the two disagree about who the
`ret` belongs to. A tempting stronger check - track the push depth at every
`jmp bas_err` site - is NOT sound here: a linear walk crosses the pop runs
of blocks it never flows through, which is why that version missed this
very defect in bas_calfix while catching it in bas_callemit.

IT IS A RATCHET ON NAMES AND NOT A PROOF. Three refusers are legitimately
both called and jumped to - `bas_emit`, `bas_emitw` and `bas_c_stmt`, each
a tail call from a body that has already popped everything - so they are
listed below with that reason. What the row holds is that a NEW name cannot
join them silently: a helper written to be called, and then jumped to from
somewhere holding registers, appears here as a name nobody has judged. It
does NOT catch a new bad `jmp` to one of the three listed names; that needs
the flow analysis the paragraph above explains is not sound cheaply.

VERIFIED TO FAIL: putting either `jmp bas_kinderr` back reports it as a
name not in the list.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import check, done                           # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# bascomp.inc JOINED THIS LIST when SPEC.md 150.39 extracted the
# compile-time half: the judged names moved with it, and this file's
# own two guards fired - "a pattern this cannot see is a pattern it
# cannot hold" found 1 refuser where it wants 2, and the judged list
# named three routines that had left the files being scanned. A gate
# is only ever pointed at files, so a move is a thing it must be told.
FILES = ("apps/basic/baslang.inc", "apps/basic/bascomp.inc",
         "apps/basic/basic.asm")

# SPEC.md 150.39's two call macros ARE the call and the jmp, so the rule has
# to read both spellings. In the resident build `SHOUT x` expands to `call x`
# and `SHOUTR x` to `jmp x`; in the overlay build both go through the vector
# table. The RESIDENT spelling is the one the rule is about - that is the
# build with a real `jmp` into a helper that returns - and the hazard is the
# same whichever way the site is written. A pattern that knows only the old
# spelling holds nothing once the sites are converted, which is what the
# first guard below reported when 133 of them were.
JMP = r"(?:jmp|SHOUTR)"
CALL = r"(?:call|SHOUT)"


def main():
    text = ""
    for rel in FILES:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            text += fh.read() + "\n"

    # every routine whose body ends a path in `jmp bas_err`
    refusers = set()
    cur = None
    for ln in text.split("\n"):
        m = re.match(r"^(\w+):", ln)
        if m:
            cur = m.group(1)
            continue
        if cur and re.match(r"^\s+" + JMP + r"\s+bas_err\b", ln):
            refusers.add(cur)
    check(len(refusers) >= 2,
          "the refusers that end in `jmp bas_err` are found at all",
          why="a pattern this cannot see is a pattern it cannot hold",
          got=len(refusers), want=">= 2")

    # Judged, with the reason each one is safe: a tail call whose caller has
    # already popped everything it held.
    TAIL_OK = {
        "bas_emit":   "a tail call from statement bodies that hold nothing",
        "bas_emitw":  "likewise, the word form",
        "bas_c_stmt": "the label probe re-enters it as a TAIL call so a line "
                      "of eight labels is not eight frames",
    }
    called = set(re.findall(r"^\s+" + CALL + r"\s+(\w+)", text, re.M))
    jumped = set(re.findall(r"^\s+" + JMP + r"\s+(\w+)", text, re.M))
    both = sorted(((refusers & called) & jumped) - set(TAIL_OK))
    check(not both,
          "no UNJUDGED refusal helper is both called and jumped to",
          why="bas_err RETURNS, so the two disagree about whose ret it is - "
              "and the jmp path prints the right sentence and then returns "
              "into the caller's saved registers, which wedges the package "
              "while every visible symptom says it worked",
          got=both, want=[])
    stale = sorted(set(TAIL_OK) - ((refusers & called) & jumped))
    check(not stale,
          "every name on the judged list is still one of these",
          why="a list that outlives what it describes stops being a "
              "judgement and starts being a hole",
          got=stale, want=[])

    return done("BASIC/8088's refusal paths")


if __name__ == "__main__":
    sys.exit(main())
