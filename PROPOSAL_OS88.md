# Proposals — shared facilities the tree keeps rewriting

**Scope, deliberately narrow.** One entry per thing that is *missing* and is
*reinvented repeatedly*, each with the count that justifies it. A facility
that already exists is not a proposal, however hard it was to find — that is
a `docs/INDEX.md` problem, and the "Already there" section at the bottom is
where those go so nobody proposes them again.

**Every count here is measured, not estimated**, and the command that
produced it is given so it can be re-run. The counts will drift; re-measure
before arguing from one.

| # | proposal | packages affected | sites |
|---|---|---|---|
| 1 | `os88list.inc` — a scrolling selectable list | 15 | — |
| 2 | `os88mem.inc` — the DS→DS byte move | 27 | 165 |
| 3 | `dec_*` adopted where it is already included | 9 | 36 |

---

## 1. `os88list.inc` — a scrolling selectable list

**Fifteen packages carry one and there is no shared one.** `artful`,
`browser`, `cdrack`, `dos`, `frotz`, `ledger`, `midirack`, `notepad`,
`plan`, `scribe`, `sheet`, `thewire`, `win16`, `wirechat`, `word` each hold
both a selection index and a first-visible-row index — which is what a list
*is* — and **ten of the fifteen already drive `os88ui.inc`'s scroll bar**,
so the thing they are each writing is the part between the bar and the rows.

That is the strongest shape of evidence in this file: the hard half is
already shared and the easy half is copied fifteen times.

**What it would give.** A row count, a row height, a painter callback per
row, and the five behaviours every one of those fifteen implements by hand:
click to select, drag to extend, arrow keys with the view following the
selection, PageUp/PageDown, and wheel. Over the existing `os88ui_sb*` so the
bar stays one implementation.

**Why it is not trivial**, and the reason to scope it carefully: a list's
*painter* is the part that differs — SHEET's rows are cells, `cdrack`'s are
tracks with a lamp, `word`'s are styles with a sample. The callback is the
whole design, and a version that tries to own the drawing will be refused by
every caller. Take `os88ui_drop`'s shape: it owns the box, the banking, the
hit testing and the keyboard, and `os88ui_dritem` is the caller's.

**Cost.** Resident bytes in every package that includes it, so it wants
`%define` arms like `os88dec.inc` — the keyboard and the wheel are separable
from the minimum.

**Measured by**
```sh
# a selection index AND a first-visible index in the same file
grep -rlE '\b\w+_(sel|cursel)\b' apps/*/ | xargs grep -lE '\b\w+_(top|first|vtop|scroll)\b'
```

## 2. `os88mem.inc` — the DS→DS byte move

**Twenty-seven packages, 165 hand-written copy loops.** `sheet` alone has
51; `dos` 15, `pixel` 12, `ledger` 11, `plan` 11, `ftpd` 9.

**And there is a reason it is not `rep movsb`**, which is exactly why it
keeps being written out longhand: `movsb` writes to `ES:DI`, and **ES is the
kernel's segment on entry to every callback** (CLAUDE.md's hard rules). So
every package writes the four-instruction loop by hand, and the two ways to
get it wrong — a count of zero walking 65,536 bytes, and an overlapping move
in the wrong direction — are each one line away in all 165 of them.

**What it would give.** `mem_fwd`, `mem_rev`, and `mem_move` that picks by
the overlap; a zero count that returns immediately; and a `rep movsb` arm
behind a `%define` for the one case where the caller genuinely owns ES. One
test file instead of none.

**Cost.** Perhaps thirty bytes resident, against 165 copies of the same four
instructions — so for most packages it is a *saving*, and for a hot loop the
existing inline copy stays legitimate (PERFORMANCE.md's rules: a call is
11 µs on the target and some of these are per-pixel).

**Measured by**
```sh
grep -rzPo 'mov\s+al\s*,\s*\[si\].{0,40}?mov\s+\[di\]\s*,\s*al' apps/*/ | wc -l
```

## 3. `dec_*` adopted where `os88dec.inc` is already included

**Not a new facility — nine packages that include it and hand-roll digits
anyway**, 36 sites between them: `wirefleet` 10, `waverack` 8, `scribe` 4,
`sheet` 3, `taskmgr` 3, `xtmp3` 3, `install` 1, `telnet` 1,
`os88chart.inc` 1.

Fifty-six packages have at least one digit→character loop. Most of those are
*legitimate* — a single digit is `add al, '0'` and wants no call — so the
honest target is the nine that pay for the include and then do not use it.

**Why it is in this file at all.** It is the cheapest entry here and it is
the one with evidence of harm: BASIC/8088 wrote its own, and the loop went
uncovered while `tests/decfmt.py` ran every arm of the shared one under
Unicorn against Python's own formatting.

**Measured by**
```sh
grep -rlE "^\s*(add|or)\s+[a-d][lh]\s*,\s*'0'" apps/*/ | cut -d/ -f2 | sort -u
grep -rl 'os88dec.inc' apps/*/ | cut -d/ -f2 | sort -u
```

---

## Already there — do not propose these

Each of these was reinvented or nearly reinvented *because the index named
7% of the shared entry points*. The index now names 787 of 789, which is the
fix; this list is the memory of it.

| wanted | it already exists as | in |
|---|---|---|
| a combo box / dropdown | `os88ui_drop` + `drbox` `drfit` `drrect` `drbank` `drback` `drfree` `drlist` `dritem` `dritemat` `drpress` `drdrag` `drup` `drclose` | `apps/os88ui.inc` §20.5 |
| a scroll bar | the `os88ui_sb*` family, 24 entry points, with wheel, rate and drag | `apps/os88ui.inc` |
| a software FPU | `fp_*`, 78 entry points: parse, format, the four operations, compare, sqrt, trunc, floor, round, ln/exp/pow, and an 8087 path chosen at run time | `apps/os88fp.inc` §84 |
| ...the same without a double's cost | `fx_*`, signed 32-bit hundredths, **entry point for entry point the same names** so a caller swaps one for the other by renaming | `apps/os88fix.inc` §81.75 |
| number → decimal text | `dec_u16` `dec_s16` `dec_u32` `dec_fld`, every arm a `%define` | `apps/os88dec.inc` §20.5.2 |
| check boxes, radio buttons, buttons, menus, an alert, an About card | `os88ui_chk*` `os88ui_rad*` `os88ui_btn*` `os88ui_mn*` `os88ui_ask` `os88ui_about` | `apps/os88ui.inc` |
| a flat colour face on 4bpp | `flat_card` `flat_lamp` `flat_check` `flat_btn` `flat_big` | `apps/os88flat.inc` §20.5.3 |
| bytes moved above 1 MB | `OSAPI_XMEM_COPY` — and **not** `os88la.inc`/`os88ub.inc`, whose own index entries say so | the API |
| a multi-line text editor | `os88text.inc` §83 | — |
| a character console | `os88con.inc` | — |

## What is NOT proposed, and why

**A string library.** BASIC/8088 needed a counted compare and a counted
console write (`con_say` stops at a NUL and a BASIC string may hold one),
and no other package wants either: a counted string is BASIC's own
representation, not the system's. One caller is not a facility.

**A sort.** Looked for and not found as a repeated hand-rolled mechanism —
SHEET's Sort Column is the only general one, and it sorts cells through its
own comparison. Nothing to share yet.

**A generated symbol index for packages as well as includes.** The includes
are what a package *reuses*; a package's own internals are what it owns, and
listing several thousand private labels would bury the 789 that matter. The
packages table's own line is the better instrument: *"when a convention is
unclear, the shortest package that uses it is usually the fastest answer."*
