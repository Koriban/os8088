# SHEET — what is left, and the order to do it in

Printing is **out of scope here** by decision, and that is worth stating
first because it changes what the remaining list looks like: six of the
thirteen missing menu commands are downstream of it, so removing it removes
almost half the arithmetic and none of the work.

**Status 2026-09-22: the macro language is finished** (section 2.4 below,
and `docs/plans/SHEET-MACRO-PLAN.md`), both defects in section 1 are closed,
and section 0.1's menu tail was the one known defect still open - closed
the same day by §81.98. Section 4 at the end is what is left, re-measured
that day; the sections above it are kept as the record.

Everything below was **measured on 2026-09-20**, off SHEET's own tables and
source rather than off §81.39 — which had itself gone stale in one row
(`Data ▸ Series` was listed missing and had closed in §81.72). §81.39's own
header states the rule this plan inherits: *every inventory in this tree has
gone stale within days of being written — quote a count only after re-making
it.* Re-measure before acting on any line here.

## 0. The constraint that shapes the whole plan

**Re-measured 2026-09-22** - the figures under this line are 2026-09-20's and
kept as the record; the macro language took most of what was left:

```
sheet.o88   image 51,564 + bss 9,120 = 60,684 of 61,440 (APP_MAX_SIZE)
            -> 756 bytes free
CHART.OVL   45,618 of the 47,104 CH_OVKB (46) reserves -> 1,486 free
MACRO.OVL   18,635 of the 28,672 SH_M2KB (28) reserves -> 10,037 free, but
            that tail IS the two macro text-file buffers (5,008 each,
            §81.91.1): what the module grows by, a macro's files lose
```

2026-09-20's figures:

```
sheet.o88   image 49,975 + bss 8,119 = 58,094 of 61,440 (APP_MAX_SIZE)
            -> 3,346 bytes free
CHART.OVL   44,083 of the 45,056 CH_OVKB reserves -> 973 bytes free
```

**That second line was wrong when this plan was written** — it said "an
overlay with room in it" off the module's *size*, which is not the budget.
The budget is `CH_OVKB`, and §81.77 found the module at **44,031 of 44,032**:
one byte. `CH_OVKB` went to 44 for that reason. Raising it is routine and
documented (8 → 22 → 23 → 26 → 28 → 29 → 30 → 31 → 33 → 43 → 44 as tenants
arrived) but it is a **heap claim**, so it is not free either.

**Both numbers are the design rule for everything below**, not a footnote: §81.71.6
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

## 0.1 A defect found while building §81.82 — the menu's tail — **fixed, §81.98**

**Fixed 2026-09-22 (§81.98)**, by neither option below: the panel's pixels
are BANKED in the staging claim and written back on close - the kernel
menu's own answer, with the gfx lock held while the panel is up so nothing
can draw under it. What follows is the record.

**Still open 2026-09-22 (before §81.98)**: `sh_mclose` still repaints `[sh_ownwin]` and
nothing else. §81.95 made a dropdown that would run past the window's RIGHT
edge move left (`sh_mdrop_geo`); the BOTTOM overhang this section is about
is untouched by it.

**SHEET's pulldown leaves its bottom rows painted on the desktop.** `sh_mclose`
repaints `[sh_ownwin]`, but a pulldown taller than the window has drawn *past*
the window's bottom edge, and nothing repaints what is beyond it. Open Data,
dismiss it, and the last item or two stay on the desktop until something else
covers them.

**It is PRE-EXISTING**, and that was established rather than assumed: the same
gesture on the pre-§81.82 build leaves `Export Chart as BMP...` behind, so the
defect predates Parse. What §81.82 did was make it one row worse, because a
twelfth Data item is twelve more pixels of overhang.

**It is not a quick fix, which is why it is recorded rather than patched into
that commit.** There is no save-under for a transient in the API
(`OSAPI_WM_SAVEU` is a window's content cache for a raise, not this), so the
honest options are (a) SHEET's pulldown becomes a real window, which is what
§81.54 moved *away* from because `OS88_MENUSET` capped at five menus, or (b)
`sh_mclose` repaints the screen region below the window, which means a package
reaching outside its own clip and asking the desktop to redraw. (a) is the
right shape and is a change to the menu bar, not to a command.

Worth noting WORD does not have this: its menu is `os88ui`'s, with an
`OS88UI_MN_RPNTH` repaint hook. So the mechanism to copy already exists, which
makes this smaller than it first looks.

## 1. Two defects — ~~still open~~ **both closed**

These are not gaps. They are wrong behaviour, and they came first. Both are
built now (§81.77 and §81.80); the sections are kept because what each one
turned out to be is the part worth having written down.

### 1.1 ~~Sort leaves empty cells where they are~~ — **done, §81.80**

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

**Built. 227 bytes of `CHART.OVL`, 7 of bss, and the resident image is
byte-for-byte the same size — 50,172** — so the item this plan flagged as the
one that could break something that works did not spend a resident byte.
`tests/sheetsort.py` is at **10 checks** and the seven that were there are
unchanged.

**Step 1 above was wrong, and cheaper than it looked.** "Collect by ROW, not
by record — that is a `sh_findcell` per row" was the plan's estimate; it is
not what was needed. The single pass over the cell array was **kept** and
made to *group*: the block's column span is computed once, a cell outside it
is skipped, and a cell whose row differs from the one being grouped flushes
that row first — staging it blank if no key cell was seen on it. A row over
2,048 rows of grid costs one `sh_findcell` each in the plan's version and
nothing at all in this one. §81.80.2 is the record.

Steps 2 and 3 were both right, and §81.80.3 is the trap step 2 named: the
blank tests sit ahead of the direction test, so descending does not reverse
them.

### 1.2 ~~A formatted empty cell loses its format through BIFF~~ — **done, §81.77**

Measured: when a format is applied to a cell with **no record**, it goes into
the side table — `sh_bt_addcell`, the **border table's sixth byte** (§81.55) —
and not into a cell record. `sh_biff_cells` walks the **cell array**, so it
never sees that cell, and there is no `BLANK` record writer in the file at all.

**It was in two passes at once, and each looked complete alone**: `sh_xfp_scan`
registers no XF for the cell and `sh_biff_cells` writes no record for it, and
fixing either without the other buys nothing. The READER had the same hole —
SHEET wrote a `BLANK` it could not read back — so the loop needed three
changes, not one. §81.77 has the account, including the stale overlay that
made the A/B say the defect did not exist.

**The gate it wanted now exists**: `tests/sheetnumfmt.py` holds both
directions — a cell formatted while empty is written as a `BLANK` record
naming an XF that carries the format, and a `BLANK` record in the file arrives
as a format that is waiting when a value is typed. That still leaves the
narrower thing PLAN's `tests/planfmt.py` does and SHEET has no equivalent of:
nothing pins the 2-bit `SH_FMT_NUM_*` encoding itself, which is the field
PLAN's Currency/Text bug lived in. SHEET is self-consistent today — checked —
but nothing holds it that way while §2.3 is built on top of it.

## 2. The gaps, by what they cost

### 2.1 Cheap, resident-safe, self-contained

| | what it is | note |
|---|---|---|
| **`Options ▸ Calculate Now`** | force a full recalc | the recalc path and the pass counter already exist; `Calculation...` (auto/manual) is already there and this is its missing other half. The smallest real item on the list |
| ~~**`File ▸ Delete`**~~ | — | **done, §81.79.** 152 bytes. It was cheap as predicted, and the two things worth knowing were not in the prediction: the picker is an `FDLG_OPEN` and says so, and the chosen name had to be kept out of `sh_name` — which is the OPEN DOCUMENT's name |
| ~~**`File ▸ Close`**~~ | — | **measured, and it is NOT a gap.** Excel's Close ends a DOCUMENT because Excel is MDI; this app has one document per instance and the window's close box already ends both, so the item would be a second name for the close box and express no distinction this app has. Recorded as a deliberate absence beside `Exit` |

### 2.1.1 ~~`Options ▸ Short Menus`~~ — measured, and NOT cheap — **DROPPED by the owner, 2026-09-22**

It was listed above as *"pure menu-table work"*. That is the easy half.

**What it hides is now known rather than guessed.** The reference captures
carry SHORT and FULL pairs for five menus (`menu_file`, `menu_edit`,
`menu_format`, `menu_data2`, `menu_options` against their `_full` twins), and
against SHEET's own tables they come to **nine items**:

| menu | hidden in short | SHEET has |
|---|---|---|
| File | Links, Delete, Save Workspace | **none of them** — SHEET's File already IS Excel's short File |
| Edit | Repeat, Paste Special, Paste Link | all three |
| Format | Cell Protection | it |
| Data | Extract, Delete, Series, Table, Parse | Extract, Delete, Series |
| Options | Set Print Titles, Set Page Break, Freeze Panes, Protect Document, Workspace | Freeze Panes, Protect Document |

So the feature is real here — it hides the advanced flavour wholesale — and
`Short Menus` ↔ `Full Menus` is the same relabel-by-repointing this app
already does four times over.

**The hard half is that item indices are POSITIONS.** The hidden items are
*interleaved*, not trailing — `Repeat` is Edit's index 1 and `Paste Special`
its 6 — so a short menu is not a smaller count, it is a different table, and
every command dispatch reads `AL` as an index into the FULL one. That needs a
per-menu remap, and its failure mode is **the wrong command runs**: exactly
what §81.78 had to be careful about for one inserted item, multiplied by five
menus. Reordering the items so the hidden ones trail would avoid it and would
also stop the full menus matching Excel's order, which is the point of having
them.

Budget it at **~300 bytes and a remap layer with a self-checking length
assertion**, not at a table and a toggle.

### 2.2 Medium, and each self-contained

| | what it is | the real cost |
|---|---|---|
| ~~**`Format ▸ Justify`**~~ | **done, §81.81** | 131 resident + 671 module + 84 bss. The estimate here was right about the cost and wrong about the SHAPE: it is not "splitting on spaces" over a block, it is a paragraph operation on the LEFT column at the width of the whole selection, with blank cells as separators. The Reference Guide had four clauses a sensible guess misses |
| ~~**`Data ▸ Parse`**~~ | **done, §81.82** | 120 resident + 920 module + 296 bss. This estimate was right, unlike Justify's: it IS a dialog with a guessed split and a write across, and it IS module work. What it understates is that the split is at FIXED CHARACTER POSITIONS rather than at a delimiter, which is the whole reason the feature exists beside CSV |
| **`Macro ▸ Resume`** (Start Recorder done, §81.107) | the recorder's last command | §81.74 names it as a documented shortfall |
| ~~**`Edit ▸ Repeat`**~~ | **DROPPED by the owner, 2026-09-22** | ~~repeat the last command~~. Its greyed `Can't Repeat` row was removed too (§81.99), behind named constants for every Edit position. **scope this before starting.** Repeating an arbitrary command means recording its arguments; Excel 2.1's Repeat is mostly the last *formatting* action. Do that, or it grows without limit |
| ~~**`File ▸ Links`**~~ | — | **struck as MDI, 2026-09-22**: it exists to reach a second open document, and SHEET has one per instance. §81.93 declines its macro functions (CHANGE.LINK, LINKS, OPEN.LINKS) on the same ground |

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

**The macro language — ~~20 functions of ~90~~ DONE, 2026-09-21.** Every
name in the vocabulary is built or declined with its reason: subroutines
(§81.84), `OFFSET` and the reference family (§81.85), custom dialogs (§81.96),
and the Normal-save fix (§81.83) all shipped, plus everything
`docs/plans/SHEET-MACRO-PLAN.md` added beyond this list. §81.93 is the
declined list. What follows is the 2026-09-20 text, kept as the record: the
only remaining *family*, and the roadmap puts it ahead of the 1.8 UI work. Three things are missing and
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

1. ~~**§1.2 BIFF `BLANK`**~~ — done in §81.77, both directions and the reader.
2. ~~**§2.1's cheap four**~~ — **the group is closed.** `Calculate Now`
   (§81.78) and `File ▸ Delete` (§81.79) are done, `File ▸ Close` was
   measured away as a non-gap, and `Short Menus` was measured OUT of the
   cheap group into §2.1.1. Of four items, two were built, one was refused
   with a reason and one was re-sized — which is roughly what "cheap" is
   worth as an estimate before the measuring.
3. ~~**§1.1 Sort and blanks.**~~ — **done, §81.80.** It was ahead of the big
   features because it is *wrong* rather than *missing*, and behind the cheap
   ones because it is the one item here that could break something that works
   today. Nothing broke: the full `sheet*` soak is unchanged.
4. ~~**`Format ▸ Justify`**~~ and ~~**`Data ▸ Parse`**~~ — **both done**
   (§81.81, §81.82). Format is complete against Excel 2.1d and Data is
   complete apart from `Table`. Reading the Reference Guide first was worth
   it both times: Justify's one-line estimate here described a different
   command from the one Excel documents, and Parse's understated what the
   split is (character positions, not delimiters).
5. ~~**The macro language**~~ — **done** (§81.83-§81.97), in this order:
   the Normal-save fix, subroutines, `OFFSET`, and custom dialogs last.
6. **`Data ▸ Table`** last of the features: it is the most self-contained large
   item, so it loses least by waiting, and it wants module room that the macro
   work may move around.

**~~`Edit ▸ Repeat` is deliberately unplaced.~~** Dropped by the owner, 2026-09-22 - the scope decision below was taken by not building it. It is cheap or unbounded
depending entirely on a scope decision nobody has taken yet, and it should not
be started until that decision is.

## 4. What is left — re-measured 2026-09-22

Off the source, not off the sections above: every menu's item table was
counted (`sh_i_*`: File 5, Edit 12, Formula 7, Format 8, Data 12, Options 6,
Macro 4), which agrees with §81.39.2.

**Commands:**

| | cost | note |
|---|---|---|
| **`Data ▸ Table`** | large, module | Section 2.4. The last multi-cell feature; the one Data command left |
| **`Macro ▸ Resume`** (Start Recorder done, §81.107) | medium | Section 2.2; the recorder's own documented shortfall (§81.74) |
| `Options ▸ Workspace` | unscoped | in §81.39.2's missing list, never sized here |
| printing (6 commands) | out of scope | by decision; no print backend in the OS |

**Dropped by the owner** (2026-09-22): `Options ▸ Short Menus` and
`Edit ▸ Repeat` - and Repeat's greyed row is gone from the menu too (§81.99),
every Edit position now named rather than numbered.

**Struck as MDI** (2026-09-22) — neither SHEET nor the OS has a
multiple-document interface, so these are not gaps: `File ▸ Links`, `File ▸
Save Workspace`, `File ▸ Close`, the whole of Excel's `Window` menu (New
Window, Show Info, Arrange All, Hide, Unhide, the window list), and the
Control menu's document Maximize/Restore/Close. §81.39.2 has the menu side
and §81.93 the 22 macro functions.

**Behaviour:** custom number-format codes in the dialog (per-cell STORAGE,
section 2.3) and SYLK carrying 4 of the 21 built-ins (a compatibility decision).

**Defects and limits:**

- ~~Section 0.1's menu tail~~ - **fixed, §81.98**. What remains of it: a
  window dragged low pushes a tall menu's last items past the screen, where
  they cannot be reached (the panel is deliberately not slid up - §81.98
  says why).
- Two `DIALOG.BOX` calls (or two `INPUT`s) in ONE cell loop: one pending
  answer, INPUT's design since §81.63; the step limit bounds it and the close
  box ends it (§81.96.3).
- Not reached by any gate: WAIT's and ON.TIME's clock paths (the 5150 has no
  BIOS clock, §81.86/§81.92), and the ON.TIME-inside-an-open-dropdown race
  §81.95.3 guards against.

**Next, by the roadmap:** stage 1.8, the Excel 2.0 look without MDI -
**measured 2026-09-22** in `docs/reports/SHEET-EXCEL-LOOK-2026-09-22.md`,
SHEET on VGA beside 21 of the Excel 2.1d captures. Eighteen gaps, grouped
small / medium / large, plus what is OS-owned and what is decided out; the
largest single difference is colour, which was never the owner's decision
and is flagged for one.

With 756 resident bytes, everything above except a small fix is module work.
