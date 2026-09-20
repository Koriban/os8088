# SHEET — what is left, and the order to do it in

Printing is **out of scope here** by decision, and that is worth stating
first because it changes what the remaining list looks like: six of the
thirteen missing menu commands are downstream of it, so removing it removes
almost half the arithmetic and none of the work.

Everything below was **measured on 2026-09-20**, off SHEET's own tables and
source rather than off §81.39 — which had itself gone stale in one row
(`Data ▸ Series` was listed missing and had closed in §81.72). §81.39's own
header states the rule this plan inherits: *every inventory in this tree has
gone stale within days of being written — quote a count only after re-making
it.* Re-measure before acting on any line here.

## 0. The constraint that shapes the whole plan

```
sheet.o88   image 49,975 + bss 8,119 = 58,094 of 61,440 (APP_MAX_SIZE)
            -> 3,346 bytes free
CHART.OVL   43,818 bytes
```

**SHEET has 3,346 bytes of resident headroom and an overlay with room in it.**
That is not a footnote, it is the design rule for everything below: §81.71.6
and §81.74.2 both had to *move something into `CHART.OVL` to pay for what they
added*. Any item here that is more than a few hundred bytes lands in the
module, and the question to ask of each is not "how big" but **"how often does
it run?"** — a keystroke's path stays resident, a menu command's does not.

Two consequences:

- The cheap items below are cheap *because they are resident-safe*. The large
  ones are large partly because they need a door, a verb and a dialog engine
  in the module.
- **`Data ▸ Table` and the macro language cannot both be resident.** Neither
  should be.

## 1. Two defects still open

These are not gaps. They are wrong behaviour, and they come first.

### 1.1 Sort leaves empty cells where they are — *structural*

Excel puts blank cells **last, in both directions**. SHEET leaves them where
they were, and the reason is not the comparator: `sh_sort_cmp` orders by class
(number, text, logical, error) and **blank is not one of them**, because a row
whose key cell is empty *never enters `rows[]` at all*. The collection walks
the **cell array** and selects records in the key column — a row with no record
there is simply never visited.

So this needs three changes, and the third is the one that makes it real work:

1. **Collect by ROW, not by record** — walk `r1..r2` and look the key cell up,
   instead of walking the cell array. That is a `sh_findcell` per row where
   today it is one pass over the records.
2. **A blank class**, and *blanks last in both directions*. The direction is
   applied at the insertion decision, not by negating the comparator, so the
   blank test has to sit **before** that test and bypass it — a blank value
   always shifts past a real key, a blank key never shifts anything.
3. **The write-back must be able to clear a destination key cell.** Every
   collected row today has a staged value to write back; a blank row has none.

`tests/sheetsort.py` (7 checks) has to grow with it. **Do not start this one
casually**: §81.61 hardened this routine two cycles ago and it is the single
most delicate thing in the package.

### 1.2 A formatted empty cell loses its format through BIFF — *bounded*

Measured: when a format is applied to a cell with **no record**, it goes into
the side table — `sh_bt_addcell`, the **border table's sixth byte** (§81.55) —
and not into a cell record. `sh_biff_cells` walks the **cell array**, so it
never sees that cell, and there is no `BLANK` record writer in the file at all.

The fix is bounded and needs no new storage: after the cell records, walk the
border table, and for each entry that `sh_findcell` says has no cell record,
emit a **`BLANK`** record (BIFF3 `0x0201`, row/col/xf) with the XF that entry
names. The reader already has to tolerate it.

Worth pairing with **a format round-trip gate**, which SHEET does not have and
PLAN now does (`tests/planfmt.py`). That matters specifically because the 2-bit
`SH_FMT_NUM_*` field is the same one PLAN's Currency/Text bug lived in: SHEET
is self-consistent today — checked — but nothing holds it that way, and SHEET
has 21 formats riding a side table on top of those 4.

## 2. The gaps, by what they cost

### 2.1 Cheap, resident-safe, self-contained

| | what it is | note |
|---|---|---|
| **`Options ▸ Calculate Now`** | force a full recalc | the recalc path and the pass counter already exist; `Calculation...` (auto/manual) is already there and this is its missing other half. The smallest real item on the list |
| **`Options ▸ Short Menus`** | hide the advanced items | pure menu-table work, and a *visible* Excel 2.x trait — the menus are already SHEET's own tables, so this is a second table and a toggle |
| **`File ▸ Delete`** | delete a file from disk | the file dialog and a kernel delete already exist; this is a dialog kind and a confirm |
| **`File ▸ Close`** | close the document | **measure before planning**: the OS owns window close (§12.2), so this may be near-meaningless here, exactly as `Exit` is |

### 2.2 Medium, and each self-contained

| | what it is | the real cost |
|---|---|---|
| **`Format ▸ Justify`** | wrap a long label down a selected block, splitting on spaces | a text operation over a range; no new storage. The one Format command missing |
| **`Data ▸ Parse`** | split a column of text into columns | a dialog with a guessed split, then a write across. Module work |
| **`Macro ▸ Start Recorder` / `Resume`** | the recorder's other two commands | §81.74 names these as its own documented shortfalls, so the design already exists |
| **`Edit ▸ Repeat`** | repeat the last command | **scope this before starting.** Repeating an arbitrary command means recording its arguments; Excel 2.1's Repeat is mostly the last *formatting* action. Do that, or it grows without limit |
| **`File ▸ Links`** | external references | only meaningful once a second document can be open. Probably out of scope with `Close` |

### 2.3 Number formats — the residual, and it is storage

All **21 built-ins** are in since §81.55. What is missing is two things that
look like one and are not:

- **Custom codes in the dialog.** The engine (`sh_fmtcode`) already takes *any*
  code — `TEXT()` hands it one — so the missing half is a text field and
  **somewhere to keep a per-cell custom code**. The format byte is full (2
  bits) and the 21 built-ins already ride the border table's sixth byte, so a
  custom code needs an arena of its own. That is the cost: storage, not
  parsing.
- **SYLK carries 4 of the 21.** The `F` record's `c1` has no vocabulary for
  the rest. Carrying them means SHEET's own extension record, which is a
  compatibility decision rather than a coding one — *what does another reader
  do with it?*

### 2.4 The two large ones

**`Data ▸ Table`** — the one genuinely multi-cell feature left, and §81.39.4
names it as the single thing array formulas would have gated (*"it is
genuinely a multi-cell feature, not just an array-returning function"*). A one-
or two-input table substitutes each row/column heading into an input cell and
recomputes a formula across the block. It needs: the table range, the input
cell(s), a substitute-and-evaluate loop, and a decision about whether the
results are live or frozen. **Module work, with a verb and a door.**

**The macro language — 20 functions of ~90.** The only remaining *family*, and
the roadmap puts it ahead of the 1.8 UI work. Three things are missing and
they are not equal:

1. **Subroutines** — calling one macro from another, with a return. This is
   the one that makes the rest worth having.
2. **References as values (`OFFSET`)** — the macro language cannot compute a
   reference, so anything that walks a range has to be written out.
3. **Custom dialogs** — the largest and the least load-bearing.

…and one smaller wrongness that belongs with them: **a Normal save keeps a
macro cell's value, not its formula** (SYLK carries it). That is a file-format
fix, not a language one, and it can be done first and alone.

## 3. The order, and why

1. **§1.2 BIFF `BLANK`, with a format round-trip gate.** Bounded, and the gate
   is worth more than the fix — it is the only thing that will hold the format
   encoding still while §2.3 is built on top of it.
2. **§2.1's cheap four**, measuring `File ▸ Close` before planning it. They are
   a day between them and they close two menu rows.
3. **§1.1 Sort and blanks.** Ahead of the big features because it is *wrong*
   rather than *missing*, and behind the cheap ones because it is the one item
   here that can break something that works today.
4. **`Format ▸ Justify`**, then **`Data ▸ Parse`** — self-contained, and they
   finish the Format and Data rows apart from `Table`.
5. **The macro language**, starting with the Normal-save fix, then
   subroutines, then `OFFSET`. Custom dialogs last, and only if asked for.
6. **`Data ▸ Table`** last of the features: it is the most self-contained large
   item, so it loses least by waiting, and it wants module room that the macro
   work may move around.

**`Edit ▸ Repeat` is deliberately unplaced.** It is cheap or unbounded
depending entirely on a scope decision nobody has taken yet, and it should not
be started until that decision is.
