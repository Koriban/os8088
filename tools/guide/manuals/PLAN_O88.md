# Plan

Plan is a spreadsheet for the smallest machine os8088 runs on. You type
labels and numbers into a grid of cells, write formulas that work out
answers from other cells, and save the result as a SYLK, CSV or text file
that [[SHEET.O88]] and other spreadsheets can open. It fits where Sheet does
not: a 128KB machine, and a 360KB floppy.

![Plan with a small budget in it, the total worked out by a formula.](shot:plan-window){full}

## Starting Plan

Open the disk that holds it, then the `APPS` folder, and double-click
**PLAN.O88**. On a machine with room you can open more than one, each with
its own sheet.

Plan is the spreadsheet on the small system disk and on the 360KB software
disk. On a larger machine with Sheet on the disk, open Sheet instead: it has
charts, a macro language, a database and more file formats. Everything Plan
does, Sheet does the same way.

## The grid

The sheet is **256 columns (A to IV) by 1,024 rows**. Click a cell to select
it, or move with the arrow keys; `Page Up` and `Page Down` move a screen at
a time and `Home` goes back to column A. The box at the left of the formula
bar shows which cell is selected, and the box beside it shows what that cell
holds.

Drag across the grid to select a block of cells, or hold `Shift` and click
the far corner, or hold `Shift` and press the arrow keys. Cut, Copy, Clear
and the three Format commands all work on the whole block.

Each column has its own width, set in **Format > Column Width...**. Rows are
all one height: there is no Row Height command.

## Typing into a cell

![A formula being typed: the formula bar shows it as it is entered.](shot:plan-formula){full}

Start typing and the cell goes into edit mode, with what you type appearing
in the formula bar's content box. `Enter` stores it and moves down, `Tab`
stores it and moves right, and `Esc` throws the entry away. `F2` opens the
cell you are on for editing instead of replacing it. While you are editing,
`Left`, `Right`, `Home`, `End`, `Backspace` and `Delete` move and edit
inside the entry; `Up` and `Down` store it and move on.

An entry is a **number** if the whole of it reads as one, so `3.5`, `-0.25`
and `1e3` are numbers and `3.5kg` is a label. An entry starting with `=` is
a **formula**. Anything else is a label, which runs on over the cells to its
right while they are empty.

A figure wider than its column is cut off at the column's edge, so a total
that looks too small for its parts wants a wider column.

`Delete` on a selected cell clears it without opening anything.

An entry holds up to 63 characters.

## Formulas

A formula starts with `=` and may use the cells around it:

| | |
|---|---|
| `=B2+B3` | add two cells |
| `=SUM(B2:B13)` | a range, from corner to corner |
| `=$B$2*C4` | a `$` fixes a column or a row, so copying the formula does not move that reference |
| `=IF(C4>100,C4,0)` | a condition |

The operators are `+ - * / ^`, the comparisons `= <> < > <= >=`, and
brackets. A formula with a bracket missing is kept as a label rather than
guessed at, and the status bar says **Unbalanced ( ) - kept as text.**

Plan has these functions:

| Group | Functions |
|---|---|
| Totals | `SUM` `AVERAGE` `MIN` `MAX` `COUNT` `COUNTA` `PRODUCT` |
| Statistics | `VAR` `VARP` `STDEV` `STDEVP` |
| Arithmetic | `ABS` `INT` `TRUNC` `MOD` `ROUND` `SIGN` `SQRT` `POWER` `FACT` `RAND` |
| Logic | `IF` `AND` `OR` `NOT` `TRUE` `FALSE` |
| Looking things up | `LOOKUP` `VLOOKUP` `HLOOKUP` `INDEX` `MATCH` `CHOOSE` `INDIRECT` `ROW` `COLUMN` `ROWS` `COLUMNS` `AREAS` |
| About a cell | `ISBLANK` `ISNUMBER` `ISTEXT` `ISNONTEXT` `ISLOGICAL` `ISREF` `ISERROR` `ISERR` `ISNA` `TYPE` `N` `NA` `ERROR.TYPE` |
| Dates and times | `DATE` `DAY` `MONTH` `YEAR` `WEEKDAY` `TIME` `HOUR` `MINUTE` `SECOND` `DATEVALUE` `TIMEVALUE` `NOW` |

A name Plan does not know answers `#NAME?`, so a sheet written elsewhere
shows you exactly which of its formulas it cannot work out. The other
answers a formula can give are `#DIV/0!`, `#VALUE!` for the wrong kind of
argument, `#REF!` for a reference that is not there, `#NUM!` for an answer
too big to hold, `#N/A` and `#NULL!`.

`NOW()` answers `#N/A` on a machine with no clock chip, which is most of
the machines Plan is for.

## Numbers

Plan works in **four decimal places**, from -214,748.3647 to
214,748.3647. That is money to the penny with three places to spare, and a
rate written `0.0625` is exact. Past the top of the range an answer is
`#NUM!` rather than a wrong number.

Two things follow from four places. `=1/3` is 0.3333, not a third, so a
total of thirds is not quite one. And `POWER` and `^` round at every step,
so a long compound-interest sum drifts: `=POWER(1.005,12)` gives 1.0612
where the true answer is 1.0617. For that kind of sum use Sheet, which
works to fifteen digits.

## The File menu

![The File menu.](shot:plan-menu){left}

| Item | What it does |
|---|---|
| New... | Empties the sheet. The dialog asks for a Worksheet, a Chart or a Macro Sheet; Plan has only worksheets, makes one whichever you pick, and says so in the status bar |
| Open... | Opens a SYLK, CSV or text file, replacing what is in the window |
| Save | Writes the file back under the name it was opened as. A sheet you started from new is saved as `SHEET1.SLK` |
| Save As... | Asks which format - **SYLK**, **CSV** or **Text** - then asks for the name, and changes the name's ending to match |

![New asks which kind of document. Plan makes a worksheet whichever you pick.](shot:plan-new){right}

## The Edit menu

| Item | What it does |
|---|---|
| Undo *action* | Takes back the last entry, Cut, Paste or Clear, naming which. Choosing it again redoes it |
| Can't Repeat | Always grey. Plan has no repeat |
| Cut | Copies the selected cells and clears them |
| Copy | Copies the selected cells |
| Paste | Puts them in at the selection, moving every reference in a copied formula by the distance it travelled |
| Clear... | Asks for **All**, **Formulas** (the contents) or **Formats**, and clears that much of the selection |

Copy and Cut put the cells on the system clipboard as text, one row a line
and a tab between columns, so a block of figures pastes into
[[NOTEPAD.O88]] or [[WORD.O88]] as a table. Paste reads the clipboard the
same way, so numbers typed anywhere else can come into a sheet.

Undo holds one step, and it needs memory of its own. On a machine with none
to spare Plan starts with **Can't Undo** greyed out and everything else
working. Number, Alignment, Font and New cannot be taken back, and
choosing one of them empties Undo.

## The Format menu

![Format > Number..., opened on the cell's current format.](shot:plan-number){right}

| Item | What it does |
|---|---|
| Number... | **Number**, **Text** or **Currency** for the selected cells |
| Alignment... | **General**, **Left**, **Center** or **Right**. General puts numbers right and labels left |
| Font... | **Normal**, **Bold**, **Underline** or **Bold, Underline** |
| Column Width... | The width of the selected cell's column, typed in characters, from 1 to 40 |

## The Options menu

| Item | What it does |
|---|---|
| Gridlines: On / Off | Draws the grid's own lines, or hides them |
| Formulas: On / Off | Shows each formula cell's formula instead of its answer |
| Calculation... | **Automatic**, **Manual** or **Calculate Now** |
| Reference: A1 / R1C1 | Labels rows and columns `A1` style or `R1C1` style, in the headings and in the reference box |

![Options > Calculation...](shot:plan-calc){left}

Plan works a sheet out again every time it redraws, which on a 4.77MHz
machine is about a second for a full window. **Manual** stops that: the
sheet keeps the answers it had, the word **CALCULATE** appears at the right
of the status bar to say they are stale, and **Calculate Now** brings them
up to date.

## The status bar

The strip along the bottom says **Ready**, or what just happened: **Saved**,
**Loaded**, the reason an entry was kept as text, which calculation mode you
chose. At its right is **NUM**, or **CALCULATE** when the sheet is stale.

## Files

Plan reads and writes three formats, chosen by the file's ending:

| | |
|---|---|
| `.SLK` | SYLK, Plan's own format. Cells, formulas, number formats and column widths |
| `.CSV` | Comma-separated values: the cells as they are shown, one row a line |
| `.TXT` | The same with tabs instead of commas |

CSV and text carry the values and not the formulas, which is what makes
them worth having: they are what another program on another machine can
read. A field with a comma or a quote in it is quoted, so it survives the
trip.

Double-clicking a `.SLK` or a `.CSV` file opens it in Plan. The 128KB
machine's system has no file associations at all, so there open the file
from **File > Open...** instead.

## Good to know

- A sheet holds about **320 cells** with something in them, and the labels
  in them share 1KB of room. A sheet that is full refuses the next entry and
  keeps what the cell had. For a bigger sheet, use Sheet on a bigger machine.
- Plan has no charts, no macros, no database commands, no inserting or
  deleting rows and columns, no fill, no cell notes and no borders. Sheet has
  all of them.
- There are no text functions and no trigonometry.
- Saving a sheet that is larger than the format can hold says **Saved -
  TRUNCATED; sheet too large for this format.** rather than writing a file
  that looks complete.
- Plan carries no About card. The window's close box closes it.
