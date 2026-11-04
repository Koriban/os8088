#!/usr/bin/env python3
"""os88fp.inc's scratch is declared by its CARRIERS, and they must agree.

    python3 tests/unit/t_fpscratch.py

os88fp.inc DECLARES NO STORAGE (its own header, SPEC.md 84.3): the caller
declares every `fp_*` field, under those exact names, at those exact sizes,
and the include reaches them through the caller's DS. Four packages carry it
- SHEET, CHART, FPTEST and BASIC/8088 - and each writes the chain out BY HAND
as a run of `equ`s. Nothing has ever checked that the four hands agree.

**A carrier that sizes a field short is silent.** nasm assembles it, the
package runs, and os88fp.inc writes past the field into whatever the carrier
put next - which on BASIC/8088 was the route by which a too-small value stack
printed `-2.668453E+307` for an expression whose answer was 36. The names all
resolve; only the arithmetic is wrong, and the arithmetic lives in four files
that no build step compares.

THE INVARIANT IS AGREEMENT, NOT A TABLE HERE. A size table copied into this
file would be a fifth hand to go stale, and it would go stale the first time
os88fp.inc grows a field. So the gate is pairwise: for every field that two
carriers both declare, its size - the distance to the next field THAT carrier
declares - must be the same in both. A carrier may OMIT a field it does not
need (SPEC.md 84.8's opt-outs: CHART drops fp_dig/fp_d10/fp_nd, fp_sq/fp_g,
fp_tv and the fp_e* set), and an omitted field is simply not compared; what
it may not do is keep a field at the wrong size. If upstream grows a field
and updates three carriers of four, this fires on the fourth.

It also holds BASIC/8088's own bss chain, which is where the defect above
lived:

  * the value stack reserves BAS_STK_MAX whole slots of BAS_SLOT bytes. It
    reserved `BAS_STK_MAX*2` - a stack of WORDS - for four waves after a slot
    became the 8 bytes a double needs, while bas_exec's bound check already
    counted in slots, so slots 5..16 lay on bas_numbuf, bas_reg, bas_fp and
    os88fp.inc's register-A scratch;
  * BAS_BSS_OWN is DERIVED from the chain and still equals its top, so no
    future edit quietly puts the hand-written sum back;
  * bas_exec's own bound names the same two symbols rather than a number;
  * the chain is strictly increasing, so no two fields share an address.

VERIFIED TO FAIL: putting `BAS_B_bas_numbuf equ BAS_B_bas_stk + BAS_STK_MAX*2`
back reports the stack short by 96 bytes; sizing `BAS_B_fp_x1` at `fp_hw + 2`
(which is what BASIC/8088 carried until this row was written - fp_hw is a
`db`, and sheet, chart and fptest all give it one byte) reports fp_hw
disagreeing between basic and the other three; and replacing bas_exec's
`BAS_STK_MAX*BAS_SLOT` bound with the literal 128 reports the bound no longer
named in symbols.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import check, done                           # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

CARRIERS = {
    "sheet":  "apps/sheet/sheet.asm",
    "chart":  "apps/chart/chart.asm",
    "fptest": "apps/fptest/fptest.asm",
    "basic":  "apps/basic/basic.asm",
}


class _Zero(dict):
    """Unknown names are the carrier's own anchor LABEL, which we measure from.

    Only a label may be unknown. A missing CONSTANT silently becoming zero is
    how this row first passed while checking nothing: OS88TEXT_SZ, BAS_STK_MAX
    and BAS_SLOT live in other files, so `BAS_STK_MAX * BAS_SLOT` was 0 and the
    stack check read `0 == 0`. The sources below are gathered per carrier for
    that reason, and `_need` re-reads every constant a check depends on.
    """

    def __missing__(self, _k):
        return 0


def _read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def _sources(rel):
    """A carrier's own text plus every apps/ include it names.

    The chains hang off constants the includes define, so a carrier read on
    its own resolves them to zero - see _Zero.
    """
    text = _read(rel)
    out = [text]
    for inc in re.findall(r'%include\s+"([^"]+)"', text):
        for cand in ("apps/" + inc, os.path.join(os.path.dirname(rel), inc)):
            if os.path.isfile(os.path.join(ROOT, cand)):
                out.append(_read(cand))
                break
    return out


def _equs(texts):
    """{name: value} for every `NAME equ EXPR` across the carrier's sources."""
    env = _Zero()
    rows = []
    for t in texts:
        rows += re.findall(r"(?m)^(\w+)\s+equ\s+([^\n;]+)", t)
    for _ in range(6):
        for name, expr in rows:
            try:
                env[name] = eval(expr.strip(), {}, env)   # noqa: S307 - our own source
            except Exception:
                pass
    return env, {n for n, _ in rows}


def _links(texts):
    """{name: base} for each `NAME equ BASE [+ ...]` that chains off another."""
    link = {}
    for t in texts:
        for name, expr in re.findall(r"(?m)^(\w+)\s+equ\s+([^\n;]+)", t):
            m = re.match(r"^(\w+)\b", expr.strip())
            if m:
                link[name] = m.group(1)
    return link


def _roots(link):
    """{name: the label its equ chain ultimately hangs off}, memoised.

    Walking each name to its root independently is quadratic and SHEET's
    chain is thousands deep - it was 1.44s of this row's 1.65s. Each walk
    now stops at the first name already resolved.
    """
    root = {}

    def walk(name):
        path = []
        while name in link and name not in root:
            if name in path:                       # a cycle: it is its own root
                break
            path.append(name)
            name = link[name]
        end = root.get(name, name)
        for n in path:
            root[n] = end
        return end

    for n in link:
        walk(n)
    return root


def _chain_offsets(texts, anchor="fp_as"):
    """Offsets of every field in the SAME bss chain as `anchor`.

    Every field, not just the fp_* ones: FPTEST puts its own `fpt_quiet`
    between fp_hw and fp_x1, so measuring fp_hw as the gap to the next fp_*
    field would call it two bytes and report a disagreement that is not one.
    """
    env, declared = _equs(texts)
    link = _links(texts)
    if anchor not in env:
        return {}
    roots = _roots(link)
    root = roots.get(anchor, anchor)
    out = {}
    for n in declared:
        if isinstance(env.get(n), int) and roots.get(n, n) == root:
            out[n] = env[n]
    if not out:
        return {}
    base = min(out.values())
    return {n: v - base for n, v in out.items()}


def _sizes(off):
    """{field: its size} - the gap to the next field in the chain."""
    order = sorted(off, key=lambda n: (off[n], n))
    return {n: off[nxt] - off[n] for n, nxt in zip(order, order[1:])}


def main():
    tables = {}
    for who, rel in CARRIERS.items():
        off = _chain_offsets(_sources(rel))
        fp = [n for n in off if n.startswith("fp_")]
        check(len(fp) >= 20, "%s: its fp_* scratch chain resolves" % who,
              why="a carrier whose chain this cannot read is not being checked "
                  "at all, and would pass by saying nothing",
              got=len(fp), want=">= 20")
        tables[who] = _sizes(off)

    # --- the carriers agree, field by field ---------------------------------
    names = sorted({n for t in tables.values() for n in t if n.startswith("fp_")})
    for field in names:
        said = {who: t[field] for who, t in tables.items() if field in t}
        if len(said) < 2:
            continue
        check(len(set(said.values())) == 1,
              "fp scratch: every carrier that declares %s sizes it the same" % field,
              why="os88fp.inc declares no storage and reaches this field through "
                  "the caller's DS, so the smallest carrier is the one that "
                  "corrupts - silently, with every name still resolving",
              got=", ".join("%s=%d" % kv for kv in sorted(said.items())),
              want="one size")

    # --- BASIC/8088's own chain ---------------------------------------------
    env, _ = _equs(_sources(CARRIERS["basic"]))

    # EVERY constant the checks below multiply or compare must be non-zero, or
    # the check reads 0 == 0 and passes while testing nothing. This row did
    # exactly that on its first run.
    for name in ("BAS_STK_MAX", "BAS_SLOT", "OS88TEXT_SZ", "BAS_PROG_MAX",
                 "BAS_OPS_MAX", "R_N", "BAS_BSS_OWN"):
        check(env.get(name, 0) > 0,
              "BASIC: %s resolves to a real value" % name,
              why="a constant this row cannot see becomes zero, and the "
                  "comparison it feeds then passes by testing nothing",
              got=env.get(name), want="> 0")

    need = env["BAS_STK_MAX"] * env["BAS_SLOT"]
    have = env["BAS_B_bas_numbuf"] - env["BAS_B_bas_stk"]
    check(have == need,
          "BASIC: the value stack reserves BAS_STK_MAX whole slots",
          why="bas_exec's bound check counts in slots, so a reservation that "
              "counts in anything else lets a deep expression write past the "
              "stack into the fields above it",
          got="%d bytes" % have, want="%d bytes" % need)

    top = env["BAS_B_bas_fpbuf"] + 32
    check(env["BAS_BSS_OWN"] == top,
          "BASIC: BAS_BSS_OWN is the chain's top, not a number beside it",
          why="a hand-written sum drifts from the fields it pays for, and "
              "slack in one term hides a shortfall in another",
          got=env["BAS_BSS_OWN"], want=top)

    # bas_fpend is a MARKER for the end of os88fp.inc's scratch and shares its
    # address with bas_fpbuf, which starts there; every other pair is a bug.
    seen = {}
    clash = []
    for n, v in sorted(env.items()):
        if n.startswith("BAS_B_") and isinstance(v, int):
            if v in seen and "fpend" not in (n + seen[v]):
                clash.append("%s == %s" % (seen[v], n))
            seen.setdefault(v, n)
    check(not clash, "BASIC: no two bss fields share an address",
          why="two names for one address is the shape the stack defect took",
          got=clash, want=[])

    lang = _read("apps/basic/baslang.inc")
    check(re.search(r"cmp\s+di,\s*bas_stk\s*\+\s*BAS_STK_MAX\*BAS_SLOT", lang),
          "BASIC: bas_exec's push bound names the symbols, not a number",
          why="a literal there and a symbol in the reservation is two places "
              "to change and one to forget, which is how this broke",
          got="not found", want="cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT")

    return done("os88fp.inc's scratch, and BASIC/8088's bss chain")


if __name__ == "__main__":
    sys.exit(main())
