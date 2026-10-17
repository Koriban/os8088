# PLAN — `Data ▸ Table`, the last missing menu command

## Why this file exists

`Data ▸ Table` is the **only menu command still genuinely missing** from
SPEC.md §81.39's inventory — printing (no OS backend) and MDI (struck on
purpose) aside. It also blocks 13 declined macro names, `TABLE` among them
(§81.93).

The owner chose the **fully Excel-faithful** shape over a one-shot fill: the
result cells carry a real table formula, cannot be edited, recalculate, and
**survive save and load**. That last clause is what makes this a week rather
than a day, and it is the reason the research below exists.

## What Excel 2.1d actually does

Read from *Microsoft Excel Reference Guide*, pp. 150–156, not recalled.

**One-input table.** Formulas in a row → the values go in the column to the
left of the first formula, starting one row below it, and the input cell is a
**column input cell**. Formulas in a column → the values go in the row above
the first formula, starting one column to the right, and the input cell is a
**row input cell**. As many formulas and as many values as you like.

**Two-input table.** One formula in the top-left corner; the values that
substitute into one input cell go down the column below it, the values for
the other go across the row to its right. Both input cells are given.

**The selection** is the whole rectangle *including* the formula row/column
and the value column/row — "select the range of cells containing the row and
column of values and the formula".

**Result cells** each hold `{=TABLE($D$9,$E$8)}`, shown in braces, and
**cannot be edited**: "Other than copying, you cannot edit cells inside the
table. If you try to edit a portion of the table, Microsoft Excel displays a
message." A one-input table with a row input cell writes `{=TABLE($D$9,)}`;
with a column input cell, `{=TABLE(,$E$8)}` — the comma's side says which.

**Clearing** is all-or-nothing: "You must clear all the resulting values."

**Editing the inputs** recalculates the table immediately if Calculation is
Automatic.

## How it persists — the format, settled

The library's `excelfileformat.pdf` (the 2002 revision `docs/` points at) has
*Multiple Operations* (its section 4.5) as **`2do`** and documents no record. The fuller
revision beside it, `excelfileformat(1).pdf`, documents all of it, and
`[MS-XLS]` (`docs/ms-xls.pdf`, sections 2.4.319 and 2.5.198.92) agrees field for field.
Both were read; the BIFF2/BIFF3 column below is the one that matters, because
SHEET writes BIFF3 (§81.10).

### `DATATABLE` — BIFF2 `0036H`, **BIFF3 `0236H`**

It **immediately follows the FIRST `FORMULA` record** of the table's range.

| off | size | contents |
|---|---|---|
| 0 | 6 | cell range address of the table range (that document's 2.5.14 Ref form) |
| 6 | 2 | option flags |
| 8 | 2 | row of the first input cell (in 2-D mode, the **row** input cell) |
| 10 | 2 | column of the first input cell |
| 12 | 2 | row of the second input cell (2-D only: the **column** input cell) |
| 14 | 2 | column of the second input cell |

Option flags:

| bit | mask | meaning |
|---|---|---|
| 0 | 0001H | always recalculate |
| 1 | 0002H | recalculate on open |
| 2 | 0004H | 0 = input data in the column left, formulas in the row above; 1 = input data in the row above, formulas in the column left |
| 3 | 0008H | **two-dimensional** (row *and* column input data) |
| 4,5 | 0010H/0020H | input cell deleted — BIFF8 only, so not ours |

BIFF2 splits the two-input case into a second record, `DATATABLE2` (`0037H`);
**from BIFF3 on one record carries both**, which is another reason to stay on
BIFF3 and not drop to 2.

### `tTbl` — the token every result cell carries

That document's section 3.10.2. **It is always the only token in the array**, and it is only
legal in a `FORMULA` record.

| off | size | BIFF2 | BIFF3–8 |
|---|---|---|---|
| 0 | 1 | `02H` | `02H` |
| 1 | 2 | first row of the table range | first row of the table range |
| 3 | 1 / 2 | first column (1 byte) | first column (**2 bytes**) |

So a result cell's whole token array is **five bytes** in BIFF3, naming the
table's top-left corner — which is how a cell is associated with its table
without the table being described more than once.

**A string-valued table formula** puts its `STRING` record after the
`DATATABLE`, not after the `FORMULA` — worth knowing before it bites.

### The other formats

SYLK, DIF and CSV have **no table record of any kind**. A table saved to one
of them keeps its *values* and loses its table-ness, which is the same shape
of limit those formats already impose (SYLK carries four number formats of
twenty-one, and widths but not heights). It is a format limit, not an app
one, and §81.39.3's wording for the others is the model.

## What it costs, measured

| | |
|---|---|
| SHEET region | image 51,486 + bss 9,182 = **60,668 of 61,440 — 772 bytes spare** |
| `CHART.OVL` | 47,902 of 49,152 — 1,250 free |
| `MACRO.OVL` | 18,747 of 28,672 — **9,925 free** |
| cell flags byte | bit0 HASFORMULA, bit1 EVALUATING — **bits 2–7 free** |
| PLAN | a SEPARATE SOURCE (`apps/plan/plan.asm`), so its 761-byte margin is untouched by any of this |

**So almost nothing may be resident.** The menu item, its door and the cell
flag are; the dialog, the engine and the readers/writers are not. That is the
same bind §81.71.5.1 was in when it moved two dialogs out to pay for a sixth,
and `MACRO.OVL`'s ~9.9KB is where the room is.

`SH_C_FMT` is **not** available for the flag — that byte's numeric value *is*
the BIFF XF index the writer emits, and §81's own comment says borrowing bits
6–7 would silently change every XF in every file this app has written.

## The design

**A table is a 16-byte record in a sparse side claim**, laid out as the
BIFF3 `DATATABLE` body is, so writing one is a copy rather than a
construction. The same pattern §81's border table uses, and for the same
reason: the cell record is full and this is sparse.

**A result cell is marked by a free flag bit** (`SH_C_TABLE`, bit 2) and
finds its table by the rect that contains it. — **WRONG, and stage 2 says
why**: `SH_C_FLAGS` bit 2 *is* free, but that byte is written as a word with
the format at several sites and cleared outright when a formula becomes a
value, so a mark there survives some edits and not others. That is §81.46's
own recorded reason for putting cell protection in the border byte, and the
mark went to **bit 7 of the border byte** beside it — which also makes the
guard free, since `sh_prot_blocked` fetches that byte already. Excel puts the top-left corner
in every cell's `tTbl` token to make that O(1); a scan of a short list is
cheaper here than two more bytes in 1,638 cell records, and the token is
still written on the way out because the format demands it.

**Evaluation** walks the rect: for each result cell, write the governing
input value(s) into the input cell(s), evaluate the governing formula, store,
restore. One full evaluation per cell — Excel's own cost, and the reason
`fAlwaysCalc` exists.

## Staging — each stage is useful alone and gated

1. **The side table, the dialog and one evaluation.** `Data ▸ Table…` with
   Row Input Cell / Column Input Cell, the three shapes detected from the
   selection, the rect filled. No protection, no persistence yet.
2. **Protection and clearing.** *(DONE — SPEC.md §81.114.7.)* Typing into a
   result cell is refused with a message; `Edit ▸ Clear` over the whole rect
   drops the table; a partial clear is refused the way Excel refuses it.
   **The side table landed here, not in stage 1**, which left stage 1 with no
   record of a table at all — the two rules above cannot be asked without
   one, and stages 3 and 4 need the same record, so it is built once.
   **And the mark is in the BORDER byte, not `SH_C_FLAGS`**: §81.46's own
   comment is the argument, and the border byte is what `sh_prot_blocked`
   already holds. `tests/sheettbl2.py`, 6 checks.
3. **Recalculation.** Editing an input value or a formula re-runs the table
   under Automatic; `Calculate Now` re-runs it under Manual.
   - **3a DONE — SPEC.md §81.114.8.** And the plan missed the mode that
     makes it affordable: Excel 2.1's Calculation dialog is **Automatic /
     Automatic except Tables / Manual**, three modes, and the middle one
     exists for exactly the cost this stage introduces. The capture
     (`dialog_calculation.png`) is the authority; this app had two modes plus
     a folded-in Calculate Now. `sh_commit` is the one hook for typing,
     Paste, Fill and a sort's write-back; Del and `Edit ▸ Clear` bypass it.
     **No dependency tracking, by decision** — every table re-runs entirely,
     and the mode switch is the user-facing answer Excel itself shipped.
     `tests/sheettblcalc.py`, 7 checks.
   - **3b DONE — SPEC.md §81.114.9: the stored rectangle follows the grid.**
     Insert/Delete Row/Column move the cells and move the result cells'
     MARKS (they live in the border table, which `sh_rc_sides` already
     shifts), and the 16-byte record now moves with them. A table record is
     not a point record — a row inserted INSIDE it grows it, one inserted
     above moves it, and a delete that takes an input cell or the top row
     drops it — so `sh_rc_table` could not be reused and it has its own.
     A SORT drops any table whose range it touches, and says so.
     **It also found a gap stage 2 left**: Undo's snapshot never carried the
     table list, so an undone Insert Row put the cells and the marks back
     and left every rectangle shifted — a half-restoring Undo, which is
     worse than none. `SH_UD_HDR` is 10 now and the list is its fourth
     array. `tests/sheettblshift.py`, 8 checks.
4. **BIFF.** Write `FORMULA`+`tTbl` per cell and one `DATATABLE` after the
   first; read both back. This is the stage that makes the feature real, and
   the host side (`tools/os88sheetfmt.py`) learns the record first so the
   gate can author a file SHEET never wrote.
5. **The `TABLE` macro command**, which unblocks §81.93's 13.

## Verification

- A **format gate** on the §81 model: the host authors the BIFF, SHEET opens
  it, and SHEET's own save is read back by the host — so a writer defect and
  a reader defect cannot cancel (the trap §81's format gate already records).
- The Reference Guide's own worked example is the fixture: `=ABS(PMT(D5/12,
  D6, D7))` over interest rates and terms, which is a two-input table with
  both input cells outside the rect.
- **Mutation, per this tree's standing rule, and per check**: the lesson of
  2026-10-16 is that the hole is always in the check that was reasoned about
  and never broken. Every check owes a mutation that fails IT and nothing
  else, run twice.
