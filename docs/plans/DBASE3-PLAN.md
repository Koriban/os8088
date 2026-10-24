# dBASE III — an independent runtime and compiler for the real format

**The decision this plans:** real file compatibility with dBASE III's
`.DBF` tables and (where it can be verified) `.NDX` indexes, and an
independent implementation of the dBASE III command language — the
interactive dot prompt and `.PRG` programs — compiled to this machine's
own bytecode. Supersedes `DATABASE-PLAN.md`'s file-format decision;
`WORKS-PLAN.md` stays dropped. Nothing is built.

**§1.1/§6's blocker is cleared (2026-10-23): `docs/DBASE3-SPEC.md` pins the
`.DBF` header, field descriptor and record format against three real,
authentic dBASE III files, hex-dumped by hand, cross-checked against five
published sources** — and one of those sources (fileformat.info's own byte
order for the last-update date) turned out to be wrong, caught only because
the real bytes disagreed with it. Still open there: a real sample with a
Logical (`L`) field, and a *confirmed-genuine* dBASE III `.DBF`+`.DBT` pair
for the memo format (the one memo sample found was Visual FoxPro, not
dBASE III — see `DBASE3-SPEC.md` §0). Neither blocks wave 1, which needs no
memo and no Logical field to prove `.DBF` read/write. The language reference
(§1.3) is separately covered: 20 period dBASE III/III PLUS/IV books are at
`~/Documents/_LIBRARY/books/programming_-_reference/dbase/`, confirmed by
direct text search to carry real `.PRG` program listings and command syntax
— sufficient to start wave 3/4 when the time comes, though no individual
command's edge-case behaviour has been pinned from them yet.

---

## 0. What "target dBASE III" means here, stated the way FROTZ-PLAN states it

**This is not a port of Ashton-Tate's dBASE III**, the way `apps/frotz` is
not a port of David Griffith's Frotz — this tree has no C toolchain that a
1984 DOS program's source would even compile under, and the original is not
open source. It is an **independent implementation of the dBASE III
*format and language*, in 8086 assembly**, aimed at reading and writing real
`.DBF` files and running real `.PRG` programs — "dBASE III" in the sense
Frotz is "Frotz" and not in the sense of vendored code. The About box says
so, for the reason FROTZ-PLAN gives: a program that claims a name it only
partly earns is a misattribution if it does not say which part.

**What this buys, concretely:** a `.DBF` a real dBASE III (or FoxBase, or
Clipper, or any of the family that read the format) produced opens here, and
a table this writes opens there. **What it does not buy:** running
Ashton-Tate's own compiled `.DBO` bytecode, which is proprietary and
undocumented — §5 is explicit about why that is refused rather than
attempted.

---

## 1. Two layers, and they are verified to very different degrees

### 1.1 The storage format — `.DBF`

The header (version byte, record count, header length, record length, a
field-descriptor array terminated by `0x0D`, then fixed-width records each
prefixed by a one-byte delete flag) is one of the most-published binary
formats from the whole DOS era — it outlived dBASE itself by decades as the
`xBase`/`FoxPro`/Clipper common format.

**It is still not pinned here, on this tree's own rule.** `WEAVE-SPEC`'s
"if an implementer has to guess a byte" and the 1541 plan's "the ROM
addresses are not written in this document and must not be" are the same
rule: wide publication is not the same as verified, and a byte written down
with confidence stops being questioned (`os8088_false_premise_in_comment`).
**Before any code: a real `.DBF` file, inspected byte for byte, or a
primary specification pinned by URL/checksum** — docs/MISSING.md's shape if
one cannot be had. `DBASE3-SPEC.md` gets the table only once it is taken
that way, the `C64-SPEC`/`WEAVE-SPEC` precedent.

### 1.2 The index format — `.NDX`

**Flagged separately and more cautiously, because it is genuinely riskier.**
`.NDX` is a B-tree on 512-byte pages, but the exact node layout varies
across dBASE III, III PLUS and the FoxPro-compatible readers that followed
it, and getting a bit of it wrong produces a tree that looks plausible and
answers wrong — the `ondisk_records_are_bigendian` class of defect, invisible
until something cross-checks it.

**Staged behind the storage format, not alongside it** (§4, story 3): the
engine's first index is this tree's own, proven on the same `hosttest/`
harness `DATABASE-PLAN.md §5` already specified. `.NDX` binary compatibility
is a later wave, taken only once a verified reference exists, and the
database is useful — indexed, even — before that wave starts.

### 1.3 The language — the dot prompt and `.PRG`

**A real grammar**, not a formula language: `USE`/`APPEND`/`EDIT`,
`GO`/`SKIP`/`LOCATE`/`SEEK`, `INDEX ON`/`SORT`, `REPLACE`, `SUM`/`COUNT`/
`AVERAGE`, `DELETE`/`RECALL`/`PACK`, `@ SAY/GET` screen I/O, `DO WHILE`/
`ENDDO`, `IF`/`ELSE`/`ENDIF`, `DO <prog>`, procedures, memory variables
(`STORE`, `PUBLIC`, `PRIVATE`), and the dBASE expression language over
string/numeric/date/logical types with its function library
(`SUBSTR`/`TRIM`/`STR`/`VAL`/`DTOC`/…).

Verified the same way: dBASE III command syntax and semantics are
documented in period manuals and in the many compatible implementations
(Clipper, FoxBase) that followed it, but **a command's exact edge-case
behaviour is pinned from a real reference before its handler is written**,
not from recollection of "how dBASE worked."

---

## 2. What this inherits unchanged from `DATABASE-PLAN.md`

Two kernel facts, checked against the code there, that do not change with
the file format sitting on top of them:

- **`OSAPI_FILE_READ_AT`/`WRITE_AT` move whole clusters only**, and cluster
  size is read once at mount from `OSAPI_FILE_DFREE` (itself O(clusters),
  so never per-record) and cached. A `.DBF`'s own record boundaries do not
  line up with a cluster boundary in general, so the engine's I/O unit is a
  PAGE — a whole number of clusters, holding a whole number of records —
  not the `.DBF` record itself.
- **There is no file lock anywhere in this kernel.** The engine owns an
  advisory lock in its own reserved header bytes, claimed on open.

---

## 3. The budget reality check, measured rather than guessed

**SHEET's own macro LANGUAGE — not its formula engine, not its charting,
just the recorder/player — is `MACRO.OVL`: 18,831 bytes uncompressed,
13,721 compressed** (`build/MACRO.OVL`, `build/ovlz/MACRO.OVL`, measured this
session). And SHEET, the whole package, sits at 61,866 of `APP_MAX_SIZE`
65,024 with its formula engine and that macro language already split
across two overlays.

**A general-purpose language — loops, procedures, screen I/O, a real
grammar — is not smaller than a macro recorder.** So before a line of
`dbase.asm` exists, assume this needs the overlay treatment SHEET needed,
probably worse: a resident core (file I/O, the B-tree, the dot-prompt line
reader), the LANGUAGE compiler and bytecode interpreter in one overlay, and
`@ SAY/GET` screen-form handling and the report writer in a second — the
same shape `CHART.OVL`/`MACRO.OVL` already proves works on this kernel.
**Re-measure this once any of it exists; this paragraph is an expectation,
not a number.**

---

## 4. Staging

This is new-program scale — closer to Weave than to a feature — so it
follows CLAUDE.md's **"Building an app or game in waves"** process once
work starts: a feature branch in its own worktree, `docs/INDEX.md` read
before any design, the contract pinned in `DBASE3-SPEC.md` ahead of the
code that depends on it, one review thread kept open across waves, and a
build diary kept the way `HOW-WIREFLEET-WAS-BUILT.md` was.

The stories, in the order each becomes useful on its own:

1. **`.DBF` read/write**, host-side first (`tools/`, a `hosttest/`-shaped
   gate) — §1.1's pinned header, fixed-length records, the delete-flag byte.
   No index, no language: a table a real dBASE III wrote opens here and a
   table this writes opens there.
2. **The engine's own index**, on the resident package — §1.2's deferral,
   `DATABASE-PLAN.md §5` story 3's shape. Indexed lookup, still no language.
3. **The dot prompt** — an interactive line interpreter for the data
   commands (`USE`/`LIST`/`GO`/`SEEK`/`REPLACE`/…) with no `.PRG`, no
   procedures, no screen forms yet. This alone is a usable database tool.
4. **The compiler and `.PRG` runtime** — the real language: `DO WHILE`,
   `IF`, procedures, memory variables, expressions. Compiled to this
   project's OWN bytecode (§5), run by the resident interpreter.
5. **`@ SAY/GET` and screen forms**, then the report writer — both
   overlay-weight, per §3.
6. **`.NDX` binary compatibility**, once §1.2's reference is in hand.

---

## 5. What this will NOT do, pinned so it is not re-litigated

- **Ashton-Tate's `.DBO` bytecode is not reproduced.** It is proprietary
  and undocumented; `.PRG` SOURCE is compiled to this project's own
  bytecode instead, which is source-level compatibility and not binary
  compatibility with dBASE III PLUS's compiler output. Stated once here so
  nobody re-derives disappointment at wave 4.
- **No joins, no SQL.** dBASE III has neither; a later `RELATION`-style
  feature (dBASE III PLUS added `SET RELATION`) is a question for a wave
  that has not been planned.
- **No network/multi-user file sharing.** §2's advisory lock is for two
  windows on one machine; this kernel's network story is sockets, not a
  shared filesystem (SPEC.md §72), so true multi-user `.DBF` locking does
  not currently arise.
- **`.NDX` is deferred, not refused** — §1.2 — but it does not ship until a
  verified reference exists, and the engine does not wait for it.

---

## 6. Before anything else

**Get a real `.DBF` specification or sample file, and a real dBASE III
language reference, pinned and checked rather than recalled.** Every byte
offset and every command's exact behaviour in `DBASE3-SPEC.md` traces to
one of those, the same discipline `C64-SPEC`/`WEAVE-SPEC`/`APPLE2-SPEC`
already hold their authors to. Until then this plan is the design record
and nothing more.
