# SHEET's macro language — finishing it

**Status: planned 2026-09-21. Waves 0-4 done: text files and events (§81.91, §81.92), MACRO.OVL past the 64 KB wall (§81.94), custom menus (§81.95) and DIALOG.BOX (§81.96); SEND.KEYS declined (§81.93). Wave 5, the reader half and the macro-sheet kind, done (§81.97).** Every count here was
measured from Microsoft Excel **Version 2.0**'s *Functions and Macros* manual
(`_LIBRARY/documentation/excel_man/`), OCR-repaired by hand where the scan
split a name, and cross-checked against SHEET's own `sh_functab` through
`tools/os88sheetfmt.py`. Re-measure it; never quote it — §81.39 went stale in
three rows in two days.

## 1. What "finished" means

Excel 2.0 has **about 209 macro-side functions**. SHEET has **20**
(§81.63). Of the rest:

| | count | |
|---|---:|---|
| **build** | **117** | the language itself, a command equivalent for every command SHEET has, and the customizing functions |
| **decline** | **59** | each for a reason that is a property of this OS or of SHEET — §3 |
| **blocked** | **13** | the SHEET feature they drive does not exist yet — §4 |

**Finished = the 117 built, the 60 declined in SPEC with their reasons, and
the 13 recorded against the feature each waits on.** Not "209 of 209":
`APP.MAXIMIZE` on a machine where the OS owns every window is a function that
could only lie.

## 2. The constraint that decides the architecture

```
sheet.o88   image 50,440 + bss 8,525 = 58,965 of 61,440 (APP_MAX_SIZE)
            -> 2,475 bytes free, RESIDENT
CHART.OVL   45,990 of the 47,104 CH_OVKB reserves; the module is ONE
            SEGMENT, so 65,536 is a wall and not a setting
```

**The names cannot go where the twenty are.** `sh_functab` is resident: a
word per entry, the name string, and a row in each of four parallel byte
tables (`sh_rpn_fid/fvar/fargc/fce`). 117 more of those is ~2 KB of a 2,475
byte budget — and the language would be finished with nothing left for
anything else SHEET ever does.

**So wave 0 moves the macro NAMES into the module.** `sh_funcid` answers the
worksheet functions resident, exactly as now, and on a miss asks `CHART.OVL`.
That is correct and cheap for three reasons:

- **Every worksheet formula still resolves resident** — the evaluator's path
  on a keystroke does not change.
- **A macro function only acts under the step engine**, which is already in
  the module (§81.63), and **`CHART.OVL` is loaded once and kept**
  (`ch_ovneed` tests `[ch_ovseg]`), so a lookup after the first is a far call.
- **A new function costs no resident byte.** Its name, its kind, its BIFF row
  and its handler are all module-side.

**The existing twenty stay resident — revised while building.** Moving them
would renumber the twenty database, `CELL` and matrix ids after them
(131–150 down to 111–130) through a descending dispatch chain and four
positional tables, to win back about 300 bytes. Not worth that risk.

**Extension functions get WORD ids from `SH_FID_MX` = `0x100`.** The
evaluator's ids were always words (`sh_pfid`); only `sh_funcid`'s `AL` return
is a byte. So an extension name is found by a **second** lookup
(`sh_mfind_r` → verb `SHM_MFIND` → `shm_mfind`) at the two call sites that
want one — the evaluator's call path and the BIFF writer — and never by
`sh_funcid` itself, whose byte callers (the bare `TRUE`/`FALSE` tests) can
therefore neither see one nor misread its low byte. `shm_pmacro` maps both
ranges onto one index space, resident twenty first.

**Module budget.** At ~70 bytes a command equivalent, the build costs ~8 KB
of `CHART.OVL`: 46 → ~54 KB of a hard 64 KB. That is the number to watch, and
the one that would force a second module if the estimate is wrong.

## 3. Declined, with the reason

**Printing (6)** — out of scope by
the user's decision (SHEET-GAPS-PLAN): `PAGE.SETUP`, `PRINTER.SETUP`, `REMOVE.PAGE.BREAK`, `SET.PAGE.BREAK`, `SET.PRINT.AREA`, `SET.PRINT.TITLES`.

**The application window (6)** —
the OS owns every window's size, position and state; SHEET cannot maximise
itself any more than it can maximise the Finder: `APP.ACTIVATE`, `APP.MAXIMIZE`, `APP.MINIMIZE`, `APP.MOVE`, `APP.RESTORE`, `APP.SIZE`.

**More than one document (15)** — one
document per instance, the reason `File ▸ Close` was measured away (§81.39.2):
`ACTIVATE`, `ACTIVATE.NEXT`, `ACTIVATE.PREV`, `ARRANGE.ALL`, `CLOSE.ALL`, `DOCUMENTS`, `FILE.CLOSE`, `HIDE`, `MOVE`, `NEW.WINDOW`, `ON.WINDOW`, `SAVE.WORKSPACE`, `SIZE`, `SPLIT`, `WINDOWS`.

**Another program (8)** — there is no
DDE, no DLL and no `CALL`able code outside a package on this OS: `CALL`, `EXEC`, `EXECUTE`, `ON.DATA`, `POKE`, `REGISTER`, `REQUEST`, `TERMINATE`.

**A chart DOCUMENT (23)** — these
act on Excel's chart window, which has its own menu bar and selection model.
SHEET's chart is a rendering of a range (§82), not a document with arrows,
overlays and a plot area to select: `ADD.ARROW`, `ADD.OVERLAY`, `ATTACH.TEXT`, `AXES`, `COMBINATION`, `COPY.CHART`, `DELETE.ARROW`, `DELETE.OVERLAY`, `FORMAT.LEGEND`, `FORMAT.MOVE`, `FORMAT.SIZE`, `FORMAT.TEXT`, `GET.CHART.ITEM`, `MAIN.CHART`, `MAIN.CHART.TYPE`, `OVERLAY`, `OVERLAY.CHART.TYPE`, `PATTERNS`, `PREFERRED`, `SCALE`, `SELECT.CHART`, `SELECT.PLOT.AREA`, `SET.PREFERRED`.

**Links (1)** — `CHANGE.LINK`, for the MDI reason.

## 4. Blocked on a SHEET feature

`APPLY.NAMES`, `CREATE.NAMES`, `DELETE.FORMAT`, `FORMULA.REPLACE`, `HELP`, `OPEN.LINKS`, `SELECT.SPECIAL`, `SHORT.MENUS`, `SHOW.CLIPBOARD`, `SHOW.INFO`, `STYLE`, `TABLE`, `WORKSPACE`. Each drives a command SHEET does not have
(`Data ▸ Table`, `Options ▸ Short Menus`, Replace, Select Special, custom
number formats, …). **Build the feature and the macro function comes with it**
— the function is a few dozen bytes once the command exists.

## 5. The waves

Each wave is gated by the existing `sheetmacro`, `sheetrecord` and
`sheetmbiff` rows **plus** a row of its own, and every new function gets its
Ftab or Cetab number (`docs/ms-xls.pdf`, §81.68) so a Normal save keeps it.

**Wave 0 — the extension mechanism. DONE.** No new function. The lookup, the
id range, one index space in `shm_pmacro`, a per-function *kind* replacing the
single `SH_MF_ACTCELL` exception, and `sh_rpn_meta` so the BIFF writer reads
either table. Resident **+30**, module **+153**. `sheetmacro`, `sheetrecord`,
`sheetmbiff`, `sheetfunc` and `sheeteval` pass unchanged. **The hit path has
no function to find yet** — wave 1's first one is what proves it.

**Wave 1 — subroutines and references (10). DONE.**
`ARGUMENT`, `CALLER`, `RESULT` — a macro called as `=NAME(args)` from another, with a return;
the plan's "the one that makes the rest worth having" (§81.84, `sheetmsub`). Then `ABSREF`, `DEREF`, `OFFSET`, `REFTEXT`, `RELREF`, `SELECTION`, `TEXTREF`
(§81.85, `sheetmref`): a reference function answers its top-left value and
leaves the reference for a macro argument that is exactly one call to it.
Resident +0, module +1,055; `CHART.OVL` 49,641 of `CH_OVKB`'s 51,200.

**Wave 2 — control and information (17). DONE** (§81.86 `sheetmctl`,
§81.87 `sheetminfo`). Resident +199, bss +15 (2,066 of APP_MAX_SIZE left);
`CHART.OVL` 53,216, `CH_OVKB` 54 - **12,320 bytes to the 64 KB wall**, which
is what waves 3 and 4 have. WAIT's timer path is unverified: the gate's 5150
has no BIOS clock.
`CANCEL.KEY`, `DISABLE.INPUT`, `ECHO`, `ERROR`, `RESTART`, `STEP`, `WAIT`; `DIRECTORY`, `GET.CELL`, `GET.DEF`, `GET.DOCUMENT`, `GET.FORMULA`, `GET.NAME`, `GET.NOTE`, `GET.WINDOW`, `GET.WORKSPACE`, `NAMES`.

**Wave 3 — command equivalents (68), by menu. DONE, 65 of 68** (§81.88,
§81.89, §81.90; FORMULA.ARRAY, FILL.LEFT and FILL.UP are features SHEET
lacks). `CHART.OVL` 57,263: **8,273 bytes to the 64 KB wall** for wave 4. Each one runs SHEET's existing command with the macro's arguments
where the menu would have asked in a dialog.

- File: `FILE.DELETE`, `NEW`, `OPEN`, `SAVE`, `SAVE.AS`
- Edit: `CANCEL.COPY`, `EDIT.DELETE`, `FILL.DOWN`, `FILL.LEFT`, `FILL.RIGHT`, `FILL.UP`, `FORMULA.ARRAY`, `FORMULA.FILL`, `INSERT`, `PASTE.LINK`, `PASTE.SPECIAL`, `UNDO`
- Formula: `DEFINE.NAME`, `DELETE.NAME`, `FORMULA.FIND`, `FORMULA.FIND.NEXT`, `FORMULA.FIND.PREV`, `FORMULA.GOTO`, `NOTE`, `SET.NAME`
- Format: `ALIGNMENT`, `BORDER`, `CELL.PROTECTION`, `COLUMN.WIDTH`, `FORMAT.FONT`, `FORMAT.NUMBER`, `JUSTIFY`, `ROW.HEIGHT`
- Data: `DATA.DELETE`, `DATA.FIND`, `DATA.FIND.NEXT`, `DATA.FIND.PREV`, `DATA.FORM`, `DATA.SERIES`, `EXTRACT`, `PARSE`, `SET.CRITERIA`, `SET.DATABASE`, `SORT`
- Options: `CALCULATE.DOCUMENT`, `CALCULATION`, `DISPLAY`, `FREEZE.PANES`, `PRECISION`, `PROTECT.DOCUMENT`
- Macro: `RUN`
- Movement: `HLINE`, `HPAGE`, `HSCROLL`, `SELECT.END`, `SELECT.LAST.CELL`, `SHOW.ACTIVE.CELL`, `UNLOCKED.NEXT`, `UNLOCKED.PREV`, `VLINE`, `VPAGE`, `VSCROLL`
- Chart gallery: `GALLERY.AREA`, `GALLERY.BAR`, `GALLERY.COLUMN`, `GALLERY.LINE`, `GALLERY.PIE`, `GALLERY.SCATTER`

**Wave 4 — customizing (22). DONE, 21 of 22** (§81.91 `sheetmfile`, §81.92 `sheetmevt`, §81.95 `sheetmmenu`, §81.96 `sheetmdbox`; SEND.KEYS declined in §81.93).
Text files: `FCLOSE`, `FOPEN`, `FPOS`, `FREAD`, `FREADLN`, `FSIZE`, `FWRITE`, `FWRITELN`. Events: `ON.KEY`, `ON.TIME`, `SEND.KEYS` (`OSAPI_WM_TIMER` is
`ON.TIME`'s clock). Custom menus on SHEET's own bar (§81.54): `ADD.BAR`, `ADD.COMMAND`, `ADD.MENU`, `CHECK.COMMAND`, `DELETE.BAR`, `DELETE.COMMAND`, `DELETE.MENU`, `ENABLE.COMMAND`, `RENAME.COMMAND`, `SHOW.BAR`.
And `DIALOG.BOX` last, as the gap plan already said: the largest item and
the least load-bearing.

**Wave 5 — the reader half. DONE** (§81.97 `sheetmkind`; KWWHAT's 71 formulas in `sheetxl2`). Decode ptg `0x58` (§81.83.2) so a macro sheet
reopens as a script — which needs the ptg to pick the table, because every
Cetab number collides with a worksheet function's. And the macro-sheet KIND
(`dt = 0x0040`), which needs SHEET to have one (§81.83.6).
