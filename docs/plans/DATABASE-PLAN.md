> **SUPERSEDED on the FILE FORMAT, 2026-10-21, same session.** The
> owner asked to target dBASE III specifically - real `.DBF`/`.NDX`
> compatibility and the actual command language, not an invented
> format. `DBASE3-PLAN.md` is the live plan.
>
> **What still stands, unchanged, and is cited from there rather than
> repeated:** section 1 (cluster-aligned `READ_AT`/`WRITE_AT`, no
> byte-offset random access, page size read once at mount) and
> section 2 (no file lock anywhere in the kernel - checked, not
> assumed). Those are facts about THIS KERNEL and do not change with
> the file format sitting on top of them.

# A true database engine — dBASE's shape, not a worksheet's

**The decision this plans:** a standalone record-database ENGINE and its own
package — indexed, not scanned — not a continuation of the works-suite idea
(dropped) and not an extension of SHEET's §81.65 functions.

Nothing is built. Three facts from the kernel decide the shape of this before
a single data structure is drawn, and each is checked against the code rather
than assumed.

---

## 0. Why SHEET does not already give you this

§81.65's `DAVERAGE`/`DCOUNT`/`DSUM`/… and `Data ▸ Find/Extract` are real, and
they are a **linear scan** — a criteria compare walked over a worksheet range,
every time, with no sorted access path and no index. That is Lotus Symphony's
database (a FORM environment over the worksheet), and it is genuinely
different from what is being asked for here: a table with a KEY, an index
that answers "find record X" without reading every record before it, and a
storage format that is the table — not a spreadsheet that happens to hold
rows.

---

## 1. The constraint that shapes the file format

`OSAPI_FILE_READ_AT` / `WRITE_AT` move **whole clusters only** — offset and
length must each be a multiple of the volume's cluster size, or `FERR_NAME`.
There is no byte-offset random access anywhere in the SDK; the file manager's
own chunked copy (§18.4.4) is built on the identical rule.

**And cluster size is not a constant.** `OSAPI_FILE_DFREE` answers it in
SECTORS, per volume — 1 sector (512 bytes) on a 1.44MB floppy, up to 64
sectors (32KB) on a large CF partition (measured this session on
`build/cffull-part1.img`: 48,689 clusters of 32,768 bytes). **And it is
O(clusters) to ask** — "about 105ms... on a 20MB hard disk", so it is a
mount-time question, cached, never a per-record one. `apps/ftpd` is the
tree's own cautionary tale: it asked per chunk of a copy loop and spent 44%
of an upload there (SPEC.md 77.40).

**So the engine's unit of disk I/O is a PAGE, sized to the volume it is
sitting on at mount time, not a fixed constant chosen at compile time.** A
table file on a floppy and the same table on a CF card are laid out in
different page sizes, and the engine reads that size once, at open, the way
`os88disk.py` picks cluster size from capacity on the host side already.

---

## 2. The constraint nothing else needs: there is no lock

Checked rather than assumed: no `OSAPI_FILE_LOCK`, no `FERR_LOCK`/`FERR_INUSE`,
and nothing in `sheet.asm` or elsewhere handles "this file is already open
somewhere else" at the ENGINE level — every existing app simply never has two
instances editing the same workbook. A record database is exactly the
program this stops being true for: a form and a report can legitimately be
open on the same table in two windows of the SAME instance, and the kernel's
own multitasking does nothing to stop a second instance doing the same thing
to the same file.

**So the engine owns an advisory lock, in-file**, the dBASE/Paradox-era
answer: one reserved byte in the header, claimed with a read-verify-write on
open and cleared on close. It is advisory and it is enough — nothing else on
this machine opens a `.DBT`-shaped file — and it is the first thing the
engine does with any file it did not just create, before a page is read.

---

## 3. The format

One file is one table. Fixed-length records — variable-length fields are a
second table's worth of complexity for a return this machine cannot afford
to chase first.

- **Header page** (one page, whatever size §1 decided): record count, record
  length, field count, a field descriptor table (name, type, width — dBASE's
  own shape, which is public domain by age and well understood), and the
  advisory-lock byte of §2.
- **Data pages**: records packed back-to-back, no record split across a page
  boundary — a record that would straddle is padded, the same reasoning
  `OSAPI_FILE_READ_AT`'s own cluster rule already forces one level up.
- **Index pages**: a B-tree, one per indexed field, each page a node sized to
  the volume's page — not a fixed 512 or 4096 as a desktop engine would pick,
  because this machine's "page" is whatever `OSAPI_FILE_DFREE` said it was at
  mount.

**Deletion is a tombstone bit, not a compaction.** A `PACK` operation that
rewrites the file is a separate, explicit, user-invoked step — exactly
dBASE's own DELETE/PACK split — because compacting on every delete is an
`int 13h` storm on a machine where one costs ~400ms.

---

## 4. The budget, and why this is its own package

`APP_MAX_SIZE` is `0xFE00` = 65,024, the same ceiling SHEET is at 61,866 of.
**This is a new package, not a mode of SHEET or anything else**, for the
arithmetic reason that killed the works-suite idea: SHEET has 3,158 bytes
spare and a B-tree engine plus a form/report UI does not fit in that, and
would not even if it did — §0's whole point is that this is a DIFFERENT
program from a worksheet with functions bolted on.

A claim-heap table, open in full, is bounded by `OSAPI_MEM_CLAIM`'s
available heap (SPEC.md §50) rather than by the package's own 65KB — large
tables stay on disk, a page at a time, which §1 already forces.

---

## 5. What gets built, each story useful alone

### Story 1 — the file format and the page I/O, host-side first
`tools/` gets a Python reference writer/reader for the header and data-page
layout, the `hosttest/` shape every C64/Apple2 core component already uses —
a format defect and an engine defect must not be able to cancel each other.
No index yet: appends and sequential scan only.

### Story 2 — the package, CREATE/APPEND/scan
A window, a file dialog, `CREATE TABLE`-equivalent (field list, name, width,
type), append a record, scan and display. **No index, no query** — this
story proves the storage format on the real machine before anything is built
on top of it, and it is already strictly ahead of nothing: a flat
fixed-record file with a form is usable.

### Story 3 — one index, one key
A B-tree on exactly one field. `FIND key` by the tree instead of a scan is
the whole point of this plan and the thing that makes it a database rather
than a spreadsheet with ambitions; everything after this story is reach, not
foundation.

### Story 4 — the query
A single-table filter — field, operator, value, AND across clauses — using
the index when the filter's first clause is on the indexed field and falling
back to a scan otherwise. **No joins.** A join is a second table's worth of
design (which side builds the hash, memory for it, nested-loop as the
fallback) and is explicitly out of this plan.

### Story 5 — form and report
A record-at-a-time form (SHEET's `Data ▸ Form` is the precedent to read, not
to reuse — it is CHART.OVL's sixth dialog engine over a worksheet range, and
this is a page-backed table, a different shape underneath). A report is a
sort-by-index-or-field, a page break rule, and totals — the dBASE/Paradox
report-writer shape, not a free-form layout tool.

---

## 6. What this will NOT do, pinned so it is not re-litigated

- **No joins.** §5, story 4's boundary.
- **No variable-length fields** in the first format. §3.
- **No multi-user over a network share** — the advisory lock in §2 is for
  two windows on one machine, not two machines on one file; this OS's own
  network story (§72) is sockets, not a shared filesystem, so the question
  does not currently arise.
- **Not a mode of SHEET, not part of the works-suite idea** — both considered
  and both refused in §0 and §4.
- **No compaction on delete.** §3 — `PACK` is explicit.

---

## 7. First measurement, before story 1

The same discipline that took APPLE2-SPEC §14.0 and WORKS-PLAN.md's own §7 used: **measure
before designing around a guess.** Two numbers, both on MartyPC at 4.77MHz:

- **A page write's cost** at each shipped cluster size (512B floppy, the
  large-CF 32KB case) — this is what every `INSERT` and every B-tree split
  pays, and it is the number that decides whether the page size should ever
  be SMALLER than the volume's cluster (batching several logical pages per
  physical one) rather than equal to it.
- **`OSAPI_FILE_DFREE`'s own cost** on the geometries this will actually run
  on, confirming the "once at mount, cached" rule is enough rather than
  assumed enough.
