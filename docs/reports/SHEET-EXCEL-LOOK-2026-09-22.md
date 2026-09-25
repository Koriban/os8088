# SHEET against Excel 2.1d, on the glass — 2026-09-22

Stage 1.8's goal is SHEET looking and feeling like Excel 2.0, **less MDI**.
This is the first time that goal has been MEASURED. SHEET was photographed on
MartyPC's `os8088_xt_vga` (640×480) in the scenes the reference captures show,
and each scene was compared side by side with the capture.

- **The tree:** `forkmain` plus the then-uncommitted §81.98/§81.99 work (the
  menu save-under and Repeat's removal). SHEET 51,725 resident bytes.
- **The references:** `_LIBRARY/documentation/screenshots/excel/`: Excel
  2.1d under Windows 2 on a colour display, 62 captures. **21 were
  compared.** Three more were opened and do not show what their names say:
  `rundialog.png` is the MS-DOS Executive's Run, not Excel's Macro Run;
  `sort_dialog.png` shows only a selection, so `sort_dialog2.png` was used;
  and `sheet1_active_check3.png` is not a cell being edited. Chart,
  Window-menu and printing captures were left out: charts are a §82
  rendering here, not a document, and the other two are out of scope.
- **The photographs:** `build/macwork/probe18.py` boots SHEET on VGA with
  Excel's own sample (Month/Sales, Jan–Mar, a SUM total) and photographs the
  main window, every menu held open, and every dialog with an Excel
  counterpart. It writes them to `build/sheet18/`, with side-by-side pairs in
  `build/sheet18/cmp/` and a page of all of them at `build/sheet18/index.html`.
  None of these are tracked; re-run the probe to remake them.

Every line below was checked on the images. Where the source was read as
well, to separate a deliberate difference from a defect, the line says so.

## 1. What already matches

- **Menu contents and order**, after the decisions on record (printing, MDI,
  Short Menus and Repeat out):
  - File, Edit and Format carry exactly Excel's items, in Excel's order.
  - Formula carries Excel's seven in its order, though one of them means
    something else (4.1).
  - Data lacks only Table, and adds the §82 chart items at its end.
  - Options and Macro are in 4.1; Help has only About (4.3).
- **Format ▸ Number**: a scrolling list of the built-in formats beside
  OK/Cancel, the closest dialog of all. The eight rows visible in both
  photographs are identical, and §81.55 says the other thirteen follow
  Excel's order too.
- **Format ▸ Border**: the same titled group box, the same six check boxes in
  the same order, and OK/Cancel stacked on the right.
- **The formula bar** in principle: a boxed reference, then the cell's content.
- **The active cell's thick border**, right-aligned numbers, column letters
  and row numbers.
- **Dithered scroll tracks** with arrow boxes at both ends.
- **A status bar with a message and the NUM indicator.**
- **Disabled menu items drawn greyed** (Can't Undo).

## 2. OS-owned: not SHEET's to change

These are how the OS draws every package. Changing them is an OS decision,
for every package at once - the radio glyph alone is, in `os88ui.inc`'s own
words, "a published contract twenty-two packages rest on".

- **Window chrome.** The title bar, close and zoom boxes, and the menu bar at
  the top of the screen are System-1 Mac style. Excel's are Windows 2's.
- **Dialogs are windows with a title bar.** Excel's are borderless modal
  boxes with a double blue frame.
- **The radio glyph is a rounded SQUARE** with a dot when set. Excel's is a
  circle. SHEET asks for the radio glyph (`OS88UI_GRADIO`) and gets
  `os88ui_glyph`'s shape: checked in the source and on a 12×12 zoom.
- **The pointer shapes available**: the arrow, plus `OSAPI_CUR_CROSS`
  (see 4.1).

## 3. Decided out, with the record

- **MDI:** the document windows, the Window menu, Close, Links, Save
  Workspace (§81.39.2, §81.93).
- **Printing:** Page Setup, Print, Printer Setup and the print areas (the
  owner's decision).
- **Short Menus and Repeat** (the owner's decision, §81.99).
- **Italic** in the Font dialog (the kernel has no italic face) and
  **Alignment's Fill** (the format byte is full). Both declined earlier, with
  their reasons in SPEC.
- **The About box's content.** Excel's names Microsoft; SHEET's names itself.
  That is correct, and it stays.
- **Colour.** SHEET draws in black and white on every adapter, VGA included:
  a count of the photographs finds two colours, plus one grey for disabled
  items. **The capture's colours are not Excel's.** The blue title bars, the
  cyan menu bar and the red highlight are Windows 2's system colours, which
  every Windows application of the day drew in.
  - **The OS's equivalent is a theme, not a package's choice.** SPEC §76 has
    three: Bright, Dark and **Color** (§76.12, patterned on Windows 3.1, EGA
    and VGA only). The user picks one in Control Panel ▸ Theme, and it is
    stored in `SYSTEM.CFG`.
  - **A theme colours the CHROME only:** the desktop, the menu bar, the dock
    and window title bars. §76 draws that line deliberately: "a window's
    content is not themed", so no package is asked for a dark mode.
  - **SHEET's in-window menu bar is content, not chrome.** It is SHEET's
    own, replacing the kernel's (see the memory on the custom bar). So under
    Color, SHEET's window title goes blue but its menu bar stays black on
    white.
  - **No package API reads the theme:** there is no theme slot in
    `os88api.inc`. A SHEET that matched the theme would need the OS to
    publish it first. That is an OS decision, the same kind as section 2.

## 4. Gaps SHEET could close

Grouped by what they cost, with the most visible first in each group.

### 4.1 Small

| # | Excel | SHEET | Note |
|---|---|---|---|
| 1 | Window title names the DOCUMENT ("Sheet1", or the file) | **done 2026-09-24 (SPEC §81.103):** "Sheet - LEDGER.SLK", "Sheet - SHEET1.SLK" for a new sheet | |
| 2 | A plus-shaped pointer over the grid | the arrow everywhere | **deferred (SPEC §81.104):** `OSAPI_WM_CURSOR` dresses the WHOLE content, and SHEET's menu bar, formula bar and scroll bars are content, where Excel shows the arrow. Needs a kernel content sub-rectangle for the shape, which is the owner's decision |
| 3 | Status bar: a divider, and NUM drawn INVERTED | **done 2026-09-24 (SPEC §81.104)** | the indicator went opaque, so the text registry fell 17 → 16 |
| 4 | Cell text inset about 2 px from the gridline | text starts ON the left gridline, and "Sales" in B1 touches it | every cell draw, and the run-on (§81.54) logic |
| 5 | Scroll thumb always shown | no thumb when the used range fits the view | DELIBERATE (`sh_sbsync`'s comment: the range is the used extent plus one screen); listed so it is a choice |
| 6 | Options: Display..., **Freeze Panes second**, Protect Document, Calculation, Calculate Now, **Workspace...** | Gridlines and Formulas toggles, Protect Document, Calculation, Calculate Now, **Freeze Panes last**; no Workspace | the order is a table edit with §81.99's named-constant care; Workspace is in section 4 of the gaps plan |
| 7 | Formula ▸ **Reference** toggles the reference being EDITED between relative and absolute (greyed when not editing) | "Reference: A1" switches the whole sheet between A1 and R1C1 display | a DIFFERENT COMMAND under Excel's name. In Excel, A1/R1C1 is in Options ▸ Workspace, the Preferences question recorded before |
| 8 | Macro: Record, Run, **Start Recorder**, Set Recorder, Relative Record | no Start Recorder | the gaps plan's Start Recorder / Resume |

### 4.2 Medium

| # | Excel | SHEET | Note |
|---|---|---|---|
| 9 | **Gridlines DOTTED** | solid | the most visible difference in the grid. Pattern lines cost more per edge, so price it on the 8088 first |
| 10 | **Headers BOXED**: lines through the header row and column, and a corner box | letters and numbers float outside the grid, with no lines | |
| 11 | **A selected range INVERTED** | a thick outline around the block | behaviour-visible; the redraw cost of inversion needs pricing |
| 12 | **Menu separators** between item groups, in every menu | none | a separator is a row that is NOT an item, and Edit's rows dispatch by position (§81.99's named constants make it safe to do) |
| 13 | Status bar describes the HIGHLIGHTED menu item ("Create new document", "Undo last command"), and a dialog's help hint | "Ready", or the last message | one string per menu item - 58 of them - which belong in a module |
| 14 | Formula bar has a THIRD box, where ✗ and ✓ appear during entry | two boxes; no cancel or enter buttons | |
| 15 | Radio dialogs frame their choices in a titled group box, with OK/Cancel stacked top-right | no group box, and OK/Cancel along the bottom | ONE engine (`sh_fdlg`) draws Alignment, Font, Calculation, New and the rest, so one change fixes them all. Number and Border already follow Excel |

### 4.3 Dialog contents, command by command

- **Format ▸ Number:** Excel has a `Format:` field for custom codes and a
  Delete button. That is the known custom-code gap (§81.39.3), and it is
  storage, not drawing.
- **Options ▸ Calculation:** Excel has Automatic, **Automatic except Tables**
  and Manual, plus **Iteration** (with Maximum Iterations and Maximum
  Change), **Precision as Displayed** and **1904 Date System**. SHEET has
  Automatic, Manual and Calculate Now.
- **Options ▸ Display:** one dialog in Excel, with Formulas, Gridlines,
  **Row & Column Headings**, **Zero Values** and a gridline and heading
  colour. SHEET has two menu toggles, Gridlines and Formulas.
- **Format ▸ Font:** Excel has four font slots plus `Fonts >>` for face and
  size. SHEET has Normal, Bold, Underline and Bold Underline.
- **Data ▸ Sort:** Excel uses one dialog with Sort by Rows or Columns and
  **three keys**, each with its own direction. SHEET uses two steps: a
  `1st Key:` field, then Ascending or Descending (read in the source:
  `sh_fd_i_sort`). There is one key and no sort by columns.
- **File ▸ Save As:** Excel shows a filename field, the path and
  `Options >>`. SHEET asks for the FORMAT first, then opens the OS file
  dialog.
- **File ▸ New:** the same three choices; only the layout differs (item 15).
- **Help:** Excel's menu has Index, Keyboard, Lotus 1-2-3, Multiplan,
  Tutorial and Feature Guide. SHEET has only About. A help system is its own
  project (`HELP` is blocked in §81.93).

### 4.4 Large

| # | Excel | SHEET | Note |
|---|---|---|---|
| 16 | **Proportional cell text** (Helv 10) and bold proportional headers | the fixed 8×8 face everywhere | the biggest remaining difference in texture. It also sets the default row height (Excel 17 px, SHEET 14) and column width (64 px against 56). The OS composes proportional rows for Word, so the mechanism exists, but every cell draw, width measurement and spill decision would move |
| 17 | **Menus from the keyboard**: Alt or F10 and underlined mnemonic letters, in the bar and every menu | mouse only: no handler exists (checked in the source) and nothing is underlined | behaviour as much as look |
| 18 | Keyboard shortcuts shown in Edit (Shift+Del, Ctrl+Ins, Shift+Ins, Del) | **done 2026-09-23 (SPEC §81.101), with the MODERN set by the owner's choice:** Ctrl+X/C/V/Z and ten more, captioned in the pulldowns | Excel 2.1d's own chords were declined |

## 5. What this measurement did NOT cover

- **The period EGA probe.** Section 6 covers CGA, Hercules and EGA's 640×350
  geometry, but EGA ran on QEMU's VGA forced into mode 10h. MartyPC's EGA
  needs IBM's ROM, which is not bundled, so the real card's detection and
  mode set are `make xt-ega`'s, which is interactive.
- **Motion**: menu tracking speed, redraw flicker, and timing on the 8088.
  These are PERFORMANCE.md's questions, not the captures'.
- **Scenes with no capture**: Row Height, Column Width, Define Name, Paste
  Function, Paste Special, Goto, Find, Parse, Series, Form and Macro ▸ Run.
  The Reference Guide has pictures of some of them; they were not compared.
- **Excel's own behaviour beyond the look**, for instance how the arrow keys
  move a selection. The captures cannot show it.

## 6. The other three displays (added the same day)

Everything above was photographed on VGA. The same probe was then run on the
other three displays the OS drives:

- `probe18.py` takes a machine and an output directory;
- `probe18ega.py` is a QEMU harness for EGA.

| Display | Machine | Photographs | Menus restored (§81.98) |
|---|---|---|---|
| CGA 640×200 | MartyPC `os8088_5150_cga_gla` | `build/sheet18-cga/` | `sheetmtail` (8 checks) |
| Hercules 720×348 | MartyPC `os8088_5150_herc_gla` | `build/sheet18-herc/` | `sheetmtail --card herc` (6), new |
| EGA 640×350 | QEMU `VIDEO=ega` | `build/sheet18-ega/` | all 9 menus pixel-identical after closing |
| VGA 640×480 | MartyPC `os8088_xt_vga` | `build/sheet18/` | `sheetmtail --card vga` (6) |

**Two defects were found, and both are fixed (SPEC §81.100):**

1. **A close box shut two dialog engines for the session.** This happened on
   every display. The list dialog (Number, Paste Function, Paste Name) and
   the input dialog (Goto, Define Name, Row Height, Column Width, Sort, Run,
   INPUT) never learned that the kernel had only hidden them. Closing Number
   by its box left Paste Function silently dead: its first photograph on
   every display was an empty sheet. The gate is `tests/sheetdlgclose.py`.
2. **On CGA, two dialogs were cut and drew through their frames.** The radio
   dialog (171 rows) and Border (159) are taller than a CGA's 155-row desktop
   band. On the radio dialogs, OK and Cancel sat under the frame, took no
   clicks, and were left on the desktop after closing. Both now use the OS's
   `WF_KEEPH` (§11.93). The gate is `tests/sheetdlgcga.py`.

**What else the three displays show, and none of it is a defect:**

- **On CGA the default window shows four grid rows.** The desktop band is
  155 rows. After the title bar, SHEET's menu bar, the formula bar, the
  headings, the horizontal scroll bar and the status bar, that leaves four.
  It is the same arithmetic for every package on a CGA, not a SHEET layout
  bug. It does mean the Excel look costs most where the screen is smallest:
  the formula bar and status bar take two of what would otherwise be six
  rows.
- **Hercules and EGA show 15 rows, VGA 20.** Hercules' window is narrower
  than its 720-pixel screen: SHEET's window keeps its template width.
- **The photographs are black and white on EGA too.** That is section 3's
  colour point: the theme on the probe's boot was Bright.

