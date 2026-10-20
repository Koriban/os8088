# Sheet

Sheet is a spreadsheet in the style of Excel 2.1. A document is a grid of
cells, 256 columns (A to IV) by 16,384 rows, and each cell holds a number, a
label or a formula. Formulas work out sums, averages and much more from other
cells and update when those cells change. You can format numbers as currency
or percentages, sort a table, chart a column, and keep four sheets in one
workbook.

![Sheet with the sample sales figures open. Column C holds formulas that multiply each month's units by 25.](shot:sheet-window){full}

## Starting Sheet

Sheet is on the Office disk, at the top level of the disk. On the larger
applications disks it is in the `APPS` folder. Double-click **SHEET.O88** to
start with an empty sheet, or double-click a spreadsheet file (`.SLK`, `.DIF`,
`.BIF` or `.XLS`) to open Sheet on that file. The Office disk has a sample in its
`MEDIA` folder, [[SALES.SLK]].

Sheet needs about 100KB of free memory. If the machine cannot spare that,
Sheet does not open.

## The window

From the top down, the Sheet window has:

- its own **menu bar**: File, Edit, Formula, Format, Data, Options, Macro,
  Sheets and Help. These menus are inside the window, not in the bar at the
  top of the screen.
- the **reference box** on the left, naming the selected cell (`C2`), and the
  **formula bar** beside it, showing what the cell really holds. For a
  formula cell that is the formula, not its result.
- the **grid**, with column letters across the top and row numbers down the
  side, and scroll bars on the right and bottom.
- the **status line**, which says `Ready` or reports what the last command
  did. On the right it shows `NUM` and, when calculation is manual and the
  sheet needs recalculating, `CALCULATE`.

The menu bar at the top of the screen carries a **Sheet** menu with **About
Sheet** and **Close**.

## Moving around and selecting

Click a cell to select it. The arrow keys move one cell, **Page Up** and
**Page Down** move a screenful, and **Home** goes back to column A. Use the
scroll bars to look elsewhere without moving the selection, or **Formula >
Goto...** to jump straight to a cell by typing its reference, such as `B12`.

To select a block, drag across it with the mouse, hold **Shift** and click
the far corner, or hold **Shift** and press the arrow keys. Most commands
work on the whole block: formatting, Clear, Copy, Cut, Fill and Sort.

## Typing into cells

Select a cell and start typing. What you type appears in the formula bar.
Press **Enter** to store it and move down, or **Tab** to store it and move
right. After a run of Tabs, Enter goes to the start of the next row, in the
column where the run began, so you can type a table row by row. The up and
down arrows also store the entry and move.

While you type, Left, Right, Home, End, Delete and Backspace edit the text in
the formula bar. **Esc** throws the entry away. To change a cell that already
has something in it, select it and press **F2**. **Delete**, pressed when you
are not typing, empties the selected cell.

Sheet decides what a cell holds from what you type:

- text starting with `=` is a **formula**;
- a complete number, such as `42`, `-7` or `3.5`, is a **number**;
- anything else, such as `Sales` or `3kg`, is a **label**.

Numbers sit on the right of the cell and labels on the left. A label longer
than its column is cut off at the column's edge.

## Formulas

A formula starts with `=` and can use numbers, cell references, the operators
below, parentheses and functions. `=B2*25`, `=SUM(B2:B13)` and
`=IF(B2>100,1,0)` are all formulas.

![Typing a formula: the formula bar shows it as you type.](shot:sheet-formula){full}

| Operator | Meaning |
|---|---|
| `+` `-` `*` `/` | add, subtract, multiply, divide |
| `^` | power: `2^3` is 8 |
| `=` `<` `>` `<=` `>=` `<>` | comparisons, which give 1 for true and 0 for false |
| `-` in front | negative: `-B2` |
| `A1:B5` | a range of cells, for functions that take one |

Powers are worked out first, then multiplication and division, then addition
and subtraction. Use parentheses to change the order. `2^3^2` is 2 to the
power 9, and `-2^2` is -4.

**References.** `B2` names a cell on the same sheet and `Sheet2!B2` names a
cell on another sheet of the workbook. A `$` in front of the column or the
row, as in `$B$2`, keeps that part from changing when the formula is copied
or filled. Inserting or deleting rows and columns still updates every
reference, so a formula keeps pointing at the same data.

**Names.** **Formula > Define Name...** gives the selected cell a name, such
as `RATE`. A formula can then say `=B2*RATE`. Names can be up to 12 letters,
are the same in upper and lower case, and each one names a single cell. A
workbook holds up to 16.

**Paste Function...** and **Paste Name...** list the functions and the
defined names. Pick one and click OK, and it goes into the cell you are
typing in (a new formula starts if you were not typing). A function arrives
with its opening parenthesis.

![Formula > Paste Function... lists every function.](shot:sheet-functions){full}

When a formula has an opening parenthesis without its partner, Sheet keeps
what you typed as a label and says `Unbalanced ( ) - kept as text.`

## Functions

| Function | What it gives |
|---|---|
| `SUM(...)` | the total of its arguments and ranges |
| `AVERAGE(...)` | the average. Labels and empty cells are left out |
| `MIN(...)`, `MAX(...)` | the smallest, the largest |
| `COUNT(...)` | how many numbers there are |
| `COUNTA(...)` | how many values there are, labels included |
| `PRODUCT(...)` | everything multiplied together |
| `IF(test, yes, no)` | `yes` when `test` is not 0, otherwise `no` |
| `AND(...)`, `OR(...)` | 1 if all, or any, of the arguments are true |
| `NOT(x)` | 1 if `x` is 0, otherwise 0 |
| `TRUE()`, `FALSE()` | 1 and 0 |
| `CHOOSE(n, a, b, ...)` | the nth of the values that follow |
| `ABS(x)` | `x` without its sign |
| `SIGN(x)` | 1, 0 or -1 |
| `INT(x)` | rounds down: `INT(-3.7)` is -4 |
| `TRUNC(x)` | cuts off the fraction: `TRUNC(-3.7)` is -3 |
| `ROUND(x, places)` | `x` rounded to that many decimal places |
| `SQRT(x)` | the square root |
| `POWER(x, y)` | `x` to the power `y` |
| `MOD(a, b)` | the remainder of `a` divided by `b` |
| `FACT(n)` | n factorial |
| `ROW()`, `COLUMN()` | the row or column number of the cell the formula is in |

`MOD`, `FACT`, `CHOOSE`, `ROW` and `COLUMN` work in whole numbers.

## Error values

When a formula cannot give a number, its cell shows an error instead. A
formula that uses that cell shows the error too, so you can trace a wrong
total back to its cause.

| Shows | Means |
|---|---|
| `#DIV/0!` | division by zero, for example by an empty cell |
| `#VALUE!` | a label used as a number, or a formula that does not make sense, such as `=1+` |
| `#NAME?` | a function or name Sheet does not know |
| `#NUM!` | a number out of range, such as `SQRT(-1)` |
| `#N/A` | no value available. A DIF file can only say this |

`=IF(B1=0,0,A1/B1)` guards against `#DIV/0!`: the branch that is not chosen
does not count.

## Formatting

The Format menu changes how cells look. **Number...**, **Alignment...** and
**Font...** open a small dialog with a list of choices; pick one and click
OK. They apply to every cell in the selection.

![Format > Number... offers four number formats.](shot:sheet-number){full}

| Dialog | Choices |
|---|---|
| Number | **General** (as typed), **Currency** (a `$` in front), **Comma** (thousands separated by commas), **Percent** (the number times 100 with a `%` after it, so `0.5` shows `50%`) |
| Alignment | **General** (numbers right, labels left), **Left**, **Center**, **Right** |
| Font | **Normal**, **Bold**, **Underline**, **Bold, Underline** |
| Border | tick any of **Outline**, **Left**, **Right**, **Top**, **Bottom** and **Shade** |

Percent changes only how the number looks: a cell showing `50%` still
holds `0.5`, and a formula using it gets `0.5`.

Border works on the whole selection. **Left**, **Right**, **Top** and
**Bottom** draw that side of the selected block, so **Outline**, which ticks
all four, draws a frame round it. **Shade** shades every cell in the block.
Lines already drawn inside the block are kept.

**Row Height...** and **Column Width...** ask for a number. Column width is
in characters and row height is in points. Each applies to the rows or
columns the selection touches, so one column can be wide and its neighbour
narrow. Only the Normal (`.BIF` or `.XLS`) format keeps row heights; SYLK
keeps column widths, and DIF keeps neither.

**Cell Protection...** marks the selection **Locked**, **Unlocked**,
**Locked, Hidden** or **Unlocked, Hidden**. Nothing is refused until
**Protect Document** is turned on in the Options menu; then a locked cell
cannot be typed into and a hidden one shows its result with its formula kept
out of the formula bar.

**Justify** spreads a long label in the selected cell down the rows beneath
it, breaking it at spaces so each line fits the column.

## The Edit menu

| Item | What it does |
|---|---|
| Undo *action* | takes back the last change and names it — **Undo Entry**, **Undo Cut**, **Undo Paste**, **Undo Clear**, **Undo Paste Special**, **Undo Paste Link**, **Undo Delete** or **Undo Insert**. Choose it again and it reads **Redo**, which puts the change back. One step is kept; it is greyed until there is something to take back, and a change too large to hold drops what was kept |
| Cut | copies the selection to the clipboard, then empties it |
| Copy | copies the selection to the clipboard |
| Paste | pastes the clipboard with its top-left corner at the selected cell |
| Paste Special... | pastes part of what was copied: **All**, **Formulas**, **Values**, **Formats** or **Notes** |
| Paste Link | fills the selection with formulas pointing at the copied cells, so the two keep the same values |
| Clear... | asks **All**, **Formulas** or **Formats**. Formulas removes the contents and keeps the formatting; Formats does the opposite |
| Delete... | asks **Row** or **Column**, and deletes the selected cell's row or column |
| Insert... | asks **Row** or **Column**, and inserts one at the selected cell |
| Fill Right | copies the left column of the selection across the rest of it |
| Fill Down | copies the top row of the selection down the rest of it |

Copied cells go on the clipboard as text, with tabs between columns and a new
line after each row, so a table pastes into Word or Note Pad and lines up.
Formulas move with their references adjusted, so `=A1*B1` copied one row down
becomes `=A2*B2`. Fill adjusts references the same way.

## The Formula menu

![The Formula menu, inside Sheet's own menu bar.](shot:sheet-menu){full}

| Item | What it does |
|---|---|
| Paste Name... | lists the defined names and pastes one into the cell |
| Paste Function... | lists the functions and pastes one into the cell |
| Reference: A1 | switches the reference box between `C2` style and `R2C3` style. The item shows which one is in use |
| Define Name... | names the selected cell |
| Note... | opens a note for the selected cell, several lines long. Click OK to keep it |
| Goto... | moves the selection to the cell you type, such as `F4` |
| Find... | finds the next cell whose text contains what you type, upper or lower case alike. It looks at what cells show, so it finds the results of formulas. It goes round to the top again; it says `Not found.` when nothing matches |

## The Data menu: databases, sorting and charts

A **database** is a block of cells with a heading row: one record per row,
one field per column. **Set Database...** marks the selected block as the
one the other commands work on, and **Set Criteria...** marks a second block
holding a heading row and, under each heading, what to match.

**Form...** opens one record at a time in a dialog, a field to a line, and
walks the database with **Find Next** and **Find Prev**. Typing in a field
changes that record. **Find** selects the next record matching the criteria;
**Extract...** copies every matching record to the block below the criteria,
asking **All Matching Records** or **Unique Records Only** first; **Delete**
removes every matching record and closes the gap.

**Sort...** asks **Ascending** or **Descending** and sorts the rows of the
selection by the column where the selection started. The other columns of
each row move with it, so a table stays together. With one cell selected it
sorts that whole column. A row whose sort column holds a label, such as a
heading, stays where it is.

**Series...** fills the selection from its first cell: **Linear** adds a
step each time, **Growth** multiplies, and the three date choices step by
day, weekday or month.

**Table...** fills a table of results from one formula. Put the formula in
the corner of the block, the values to try down the left column or along the
top row, and Table asks which cell to substitute them into; each result
appears where its row and column meet, and the table recalculates with the
sheet.

**Parse...** splits a column of labels into several columns, cutting where
the text lines up.

**Chart Column...** opens a chart of the column the selection is in. Its
numbers become columns on the chart; labels are skipped. If the next column
to the right holds numbers too, it becomes a second series for the Scatter
and Combination types. The chart is live: change a number in that column and
the chart changes with it. A chart shows up to 40 values.

![Data > Chart Column... on the Revenue column.](shot:sheet-chart){full}

**Chart Gallery...** chooses the chart type: **Area**, **Bar**,
**Column**, **Line**, **Pie**, **Scatter** or **Combination**. The chart
redraws at once. **Export Chart as BMP...** saves the chart as a picture
(`CHART.BMP` unless you type another name) that Paint and PiXEL can open.

To work on the chart further, or chart a saved file without Sheet, use the
**Chart** program, [[CHART.O88]].

## The Options menu

| Item | What it does |
|---|---|
| Display... | tick **Formulas** to show each formula in its cell instead of its result, and **Gridlines** to draw the lines between cells |
| Freeze Panes | holds the rows above and the columns left of the selected cell in place while the rest scrolls; choose it again to let them go |
| Protect Document | refuses changes to cells marked Locked in Format > Cell Protection..., and keeps a Hidden cell's formula out of the formula bar |
| Calculation... | **Automatic** recalculates formulas as you go, **Automatic except Tables** does the same but leaves Data > Table... until you ask, and **Manual** stops both, which keeps a large sheet quick |
| Calculate Now | recalculates everything at once, for when Calculation is not Automatic |
| Workspace... | tick **R1C1** to name cells by row and column number instead of letters |

## Four sheets in one workbook

The **Sheets** menu lists **Sheet1** to **Sheet4**; the one you are looking
at is marked. Choose another to switch to it. A formula reaches another
sheet with a reference like `Sheet3!B2`.

Only the Normal (`.BIF` or `.XLS`) file format keeps all four sheets. SYLK and DIF
save the sheet you are looking at, and the status line says so.

## Macros

A macro is a column of formula cells that Sheet carries out one after the
other. Select the first cell and choose **Macro > Run**. These commands do
something when a cell holds one on its own:

| Command | What it does |
|---|---|
| `=SET.VALUE(B2, expression)` | puts the value of the expression in cell B2 |
| `=SELECT(B2)` | moves the selection to B2 |
| `=GOTO(D10)` | carries on from cell D10 |
| `=ALERT("text")` | shows a message and waits for you to close it |
| `=RETURN()` | ends the macro |

Any other formula is worked out and its result ignored. A macro ends at
`RETURN()`, at an empty cell, or after 5,000 steps, when it says `Err: macro
step limit`. The cell references in macro commands stay on the current
sheet.

## The File menu

| Item | What it does |
|---|---|
| New... | asks Worksheet, Chart or Macro Sheet. Each one empties the workbook, its names included, and starts a new one called `SHEET1.SLK` |
| Open... | opens a spreadsheet file |
| Save | saves under the current name |
| Save As... | asks for the file format, then for the name |
| Print... | Sheet cannot print; it says so |

If the workbook has changes that are not saved, New, Open and closing the
window first ask **Save changes to** the file. **Save** saves it under its
current name and carries on, **Discard** carries on without saving, and
**Cancel** leaves everything as it was. If the save could not keep
everything, for example because a SYLK file keeps only one sheet, Sheet stops
and says so on the status line instead of carrying on.

To quit, choose **Close** from the Sheet menu at the top of the screen.

## Files

Sheet reads and writes three formats and picks one by the file's extension.

| Format | Extension | Keeps |
|---|---|---|
| Normal | `.BIF` or `.XLS` | Excel's own format: values, labels, formulas, number formats, alignment, bold and underline, borders, notes and all four sheets |
| SYLK | `.SLK` | values, labels, formulas, number formats, alignment, borders and notes, one sheet |
| DIF | `.DIF` | values and labels only, one sheet |

Save As starts on the format the current name has, so OK alone keeps the file
in its format. The format you pick is the one that is saved: if the name you
type ends in an extension for another format, Sheet changes the extension to
match, so `REPORT.TXT` saved as Normal becomes `REPORT.BIF`. Saving recalculates every formula first, so the file holds
up-to-date results. These files also open in Excel and in other spreadsheets
that read these formats. Defined names, row height and column width are not
saved in any of them.

## Good to know

- A workbook holds about 1,600 filled cells across its four sheets. Formulas,
  labels and notes share about 8KB of text, and changing a formula or label
  uses more of it. When it runs out, Sheet refuses the edit; a sort stops
  with `Sort incomplete - text area full.` Save, close and reopen the file to
  get the room back.
- A file larger than Sheet can save is cut short, and the status line says
  `Saved - TRUNCATED`.
- An empty cell counts as 0 in a formula.
- Each dialog can be closed with its Cancel button. Goto, Find, Define Name,
  Row Height and Column Width also take **Enter** for OK and **Esc** for
  Cancel.
- **Help > About Sheet...** and **Sheet > About Sheet** show who made it.
