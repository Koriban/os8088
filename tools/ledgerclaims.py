#!/usr/bin/env python3
"""Total the heap LEDGER takes on open, in bytes.

SPEC.md 24.5.2's rule is that a package's footprint is its REGION PLUS THE
CLAIMS IT MAKES TO FUNCTION, and the number that matters for the 128KB
machine is the sum of the two.  So this reads the claims OUT OF THE ENTRY
PROC rather than out of the constant block: a `LG_CLAIM_*_KB` that nothing
calls OSAPI_MEM_CLAIM with is a constant, not a claim, and counting it would
make the meter pessimistic in exactly the way that hides progress.  It has been wrong in both directions: it first missed the border and note
claims entirely, and then a sh_ -> pl_ -> lg_ rename left its pattern matching
nothing at all, so it reported a total of ZERO and a comfortable fit. A meter
that can read zero as good news needs a floor, so it refuses one now.

Undo's claim (81.57) is reported SEPARATELY because sh_entry takes it last
and carries on without it (`jc .noundo`) - it is the one claim whose absence
costs a feature rather than the program.
"""
import re, sys

SRC = 'apps/ledger/ledger.asm'
s = open(SRC, encoding='latin-1').read()

consts = {m.group(1): int(m.group(2))
          for m in re.finditer(r'^LG_CLAIM_(\w+?)_KB\s+equ\s+(\d+)', s, re.M)}

# every `mov ax, LG_CLAIM_x_KB` that is followed by a MEM_CLAIM
taken = re.findall(r'mov\s+ax,\s*LG_CLAIM_(\w+?)_KB\s*[^\n]*\n\s*call\s+OSAPI_MEM_CLAIM', s)
missing = [t for t in taken if t not in consts]
if missing:
    sys.exit('ledgerclaims: claimed but not declared: %s' % ', '.join(missing))

need = sum(consts[t] for t in taken if t != 'UNDO') * 1024
undo = sum(consts[t] for t in taken if t == 'UNDO') * 1024
if '--verbose' in sys.argv:
    for t in taken:
        print('%-8s %6d%s' % (t, consts[t] * 1024, '  (optional)' if t == 'UNDO' else ''))
if not taken:
    sys.exit('ledgerclaims: found no MEM_CLAIM at all in %s - the pattern has '
             'gone stale, and a silent 0 would read as a comfortable fit' % SRC)
print(need if '--verbose' not in sys.argv else 'required %d, undo %d' % (need, undo))
