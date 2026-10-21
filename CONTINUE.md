# CONTINUE — where this left off, 2026-10-20 (late)

Working note, not a design record. Untracked on purpose. Everything durable is
in commit messages and SPEC.md; this is the state and what is owed.

## TL;DR

**`Data ▸ Table` IS FINISHED — all five stages.** §81.39's inventory now
has no menu command Excel 2.1d has and this app does not, printing (no OS
backend) and MDI (struck on purpose) aside. The merge is landed and the two
things it left owed are done; Chart went from 1 gate row to 5 and that found
one real defect; the fptest port is finished at 126 cases.

Stage 1 (`c71c72dd`) fills the rectangle. **Stage 2** (`aa370f70`) makes it a
TABLE: the rectangle outlives the run in a list carved from the border claim,
a result cell cannot be edited, and `Edit ▸ Clear` is all-or-nothing the way
Excel's is. SPEC.md §81.114.7, `tests/sheettbl2.py`, 9 checks.

**Stage 3a** makes it RECALCULATE, and the plan was missing the thing that
makes that affordable: Excel 2.1's Calculation dialog is **Automatic /
Automatic except Tables / Manual** — three modes, the middle one there for
exactly this cost (a table is a full formula evaluation PER RESULT CELL,
where an ordinary formula is a memoized lazy one). The capture
`dialog_calculation.png` is the authority. `sh_calcmanual` is `sh_calcmode`
now, three-valued; two of its three readers had been testing it as a flag.
**No dependency tracking, by decision** — every table re-runs entirely, and
the mode switch is the answer Excel itself shipped. SPEC.md §81.114.8,
`tests/sheettblcalc.py`, 8 checks.

**Six defects came out of stage 2, and only ONE was in stage 2's own code.**
Putting the result-cell mark in the border byte meant reading every write
path that touches that byte, and four of these had been there for cycles:

- `sh_table_unbank` restored an input cell by reading its row back out of the
  BANKED RECORD, where the row is packed with the sheet — so it restored
  nothing at all on sheets 2–4, and nothing anywhere if the input cell had
  not existed before the run (the substitution stayed in the user's sheet).
  SPEC §81.114.4 had ASSERTED the opposite for a cycle.
- **the Del key never asked `sh_prot_blocked` at all** — a §81.46 defect, so
  Del cleared a locked cell on a protected document.
- **`Clear ▸ Formats` removed the whole border record**, resetting any cell's
  Locked/Hidden to the default — also §81.46, also older than this feature —
  and, once the table mark joined that byte, un-protecting a table's result
  cells while the table stayed recorded. The right pattern was already in the
  tree: `sh_bdlg_apbord`'s `.clearit`, three hundred lines away.
- **`Clear ▸ Formulas` orphaned the marks**: §81.63 keeps a cell that still
  has a border record, so clearing a whole table that way dropped the table
  and left every result cell refusing edits for ever.
- `sh_tbl_dropsel` used `AX` as a length across a call that answers in `AL`.
  The machine said `STACK OVERFLOW TASK 00`, three structures from the
  mistake. **Stage 2's own, and the only one.**

**And `CH_OVKB` went 48 → 51.** `CHART.OVL` ran out mid-fix at 49,204 against
48 KB's 49,152. Three ahead on purpose — the same step `os88chartovl.inc`'s
own history took at 50, for the same stated reason. Heap, not image; 63 is
the wall.

**Stage 3b** makes the stored rectangle FOLLOW the grid. Insert/Delete
Row/Column move the cells and move a result cell's mark for free (it is a bit
in the border byte, which `sh_rc_sides` already shifts); the 16-byte record
did not, so a table whose sheet gained a row above it was guarded against a
rectangle one row too high. `sh_rc_table` is the generic shifter for *(packed
row/sheet, column)* records and could not be reused — a row inserted INSIDE a
table grows it, one above moves it, the top row deleted takes the formulas,
and a deleted input cell leaves nothing to substitute. Sort drops any table
it touches and says so. **It also found a gap stage 2 left**: Undo's snapshot
never carried the table list, so an undone Insert Row put the cells and the
marks back and left every rectangle shifted — a half-restoring Undo, which is
worse than none. `SH_UD_HDR` is 10 now. SPEC.md §81.114.9,
`tests/sheettblshift.py`, 9 checks, 10 mutations.

**Stage 4** makes it survive SAVE AND LOAD. A `FORMULA` record per result
cell whose whole token array is one `tTbl`, plus one `DATATABLE` (`0236H`)
after the first formula of the range — Excel's own shape, so a reader that
knows neither still sees the right figures from the cached results.

**The plan was wrong that the sixteen bytes are a straight copy.** The range
and the flags are; the INPUT CELLS are not. The format names a one-input
table's single cell in the FIRST pair whichever kind it is, with option bit 2
giving the orientation — this app keeps the row input first and the column
input second always. Verbatim, every column-input table (the common shape)
writes `0FFFFh` as its input cell and reads back substituting along the wrong
axis. **Found by working out what the authored fixture should contain**, not
by reading the code, which is the argument for the host learning the record
first. SPEC.md §81.114.10, `tests/sheettblbiff.py`, 6 checks, 8 mutations.

Nine resident bytes — the reader, writer, translation and marking pass are
all `CHART.OVL`'s.

**Stage 5** is `TABLE([row_input][, column_input])`, the macro equivalent,
and it cost **not one resident byte**. The Cetab number was looked up rather
than guessed (`0029H`, `[MS-XLS]` 2.5.198.4, cross-checked against
`DATA.SERIES` at `0028H` which this tree already carries) — and the host's
`--selfcheck` refused the first attempt with *"TABLE is Ftab index 41, which
is DSUM"*, because the third byte of the row is what says Cetab rather than
Ftab. SPEC.md §81.114.11, `tests/sheetmcmd.py` 24 checks.

**Going to read §81.93 found it stale twice.** The plan claimed this feature
unblocks "13 declined macro names" — it unblocks ONE; thirteen is the size of
the whole "blocked on a SHEET feature" list. And `WORKSPACE` had stopped
being blocked when §81.106 built `Options ▸ Workspace...`, with nobody
re-reading the list. A list of "blocked on something that does not exist yet"
goes stale the moment the thing arrives.

Nothing is blocking. Stages 3–5 are next, and **`CHART.OVL` is the constraint
now, not the region**: 90 bytes free of 49,152.

## State

| | |
|---|---|
| `forkmain` @ the 2026-10-18 upstream merge | **`Data ▸ Table` is FINISHED (5 stages)** and **origin/main `ad1be5d6` is merged**. `make` 48/0, `soak -k 'sheet*' -k 'chart*'` **67/0 nothing skipped**, `test-full` **57/0 nothing skipped** |
| merge worktree | `../os8088-merge-20261014` on `merge-upstream-20261014`, same commit — **disposable** |
| kernel | `.text` +624 over the merge; **the image rung crossed 96 → 97**, 1,536 spare of `KERN_BUDGET` |
| SHEET | image 51,761 + bss 9,279 = **61,040 of 61,440, 400 spare**; `CHART.OVL` **49,204 of 52,224, 3,020 free** (`CH_OVKB` 48 -> 51); both modules ship PACKED |
| CHART | bss 2,185 → 792 (upstream moved its arrays into the staging claim) |
| text registry | RE-COUNTED at that merge, neither side's number (66 in 22 by the end of the day) |
| FPTEST | 126 cases, 105 pooled doubles, image 8,492 + 245 bss; window 460 wide now |

## What the merge actually cost, and where it hid

Six defects, and **six of the seven were in files git merged cleanly**. A
conflict marker is where two branches edited the same line, not where they
disagree about meaning. They are written up in `94e184e6`; the two worth
carrying:

- **`dec_s16` landed in `.modc`** while `sh_itoa` calls it near from twelve
  resident callers, because `os88chart.inc` includes upstream's new
  `os88dec.inc` and this fork compiles that file into CHART.OVL.
- **The Standard File dialog is a Disk window now** (§38.3), and the fixture
  clicked its old geometry: **38 of 56 sheet rows failed with no error message
  anywhere**. The rows drive it by NAME now.

**And one in our own code:** §82.15's named-range filter **never ran** —
`ct_reset_series` zeroed `ct_wantrng` and every reader called it first. SPEC
asserted the behaviour for two cycles. It survived because nothing tests
Chart.

## The 2026-10-18 upstream merge

`origin/main` `b47de145..ad1be5d6` — 11 commits, 174 files, +52,805: Sticky
Apps (Desk Calendar, Sticky Note, Desk Clock), `DESK.DRV`, `STIKMENU.DRV`,
Timer and Bounce as packages, EGA colour themes, browser work for retro
sites. **ABI unchanged** — PKG_FMT 10, DRV_VER 11; the new cells are appended
at free slots, so our packages load untouched.

**It touched ZERO lines of `apps/sheet/`** — no commits, no diff, no §81/§82
section. `apps/sheet/` and `tests/sheet*.py` are byte-identical across the
merge. What changed under SHEET is `apps/os88api.inc` (+224: the Sticky App
mark and three theme cells) and 5,013 lines of kernel. **That is the case
where a diff tells you nothing**, which is why the 67-row soak was run rather
than reasoned about. It is green.

Three conflicts:

1. `tools/os88ovlchk.py`'s module-suffix list — **the second time this exact
   conflict has come up**, and the HEAD side carries its own resolution:
   *"THE UNION: a name missing here is a module this tool silently does not
   check."* Ours `.modm` + upstream's new `.modj`/`.modn`.
2. `Makefile` ×2, the small disks — ours adds `APPS:$(PLANPKG)`, upstream
   `$(SMALLSTIKARGS)`. Union.
3. `Makefile`, `office360` — ours puts SHEET's two modules on that disk and
   drops PiXEL to fit; upstream adds `SYSTEM/FONTS` for the Desk Clock. Both
   answer the same 354-cluster pressure, so PiXEL coming off pays for both.

**And the merge exposed a defect older than itself.** `CHART.OVL` and
`MACRO.OVL` rode `$(APPS_TOOLS)` onto every `kern_small` floppy while SHEET
was omitted by `$(SMALLOMIT)` and CHART by `$(SMALLOMIT_ORPHAN)` — 66 of 354
clusters for packages not on the disk. The filters name PACKAGES and a module
is not its package. It had always been wasteful and always FITTED; upstream's
new packages took it to 400 and `make` refused. **It surfaced as a SKIP** —
`test-full` read "56 passed, 0 failed, 1 skipped" — which is the third
instance of that trap in this tree. Fixed in `b644367a`; the disk is 349/354
with everything on it, so no curation decision was owed at all.

### Upstream PR #268 is open and this is the plan for it

"Elendilon -> Main", 791 commits / 875 files / 112k insertions, and it
**does** carry SHEET work (`2c8ba025`: Percent, Border over a block,
notes/formats/borders in files, ask before New/Open/Close, two redraw bugs)
plus eleven chart size-pass commits.

**WAIT FOR IT TO LAND ON `main`, THEN MERGE `main` WHOLE.** `main` is
squash-only (docs/UPSTREAM.md): merging the PR branch now means merging that
content TWICE, the second time with no shared ancestry, so every touched line
conflicts. Cherry-picking the sheet subset is out — those commits sit on
`OS88LINE_NOEDIT` and the sidecar/parts work.

**Budget for it being expensive, and SHEET pays.** Today's merge touched no
sheet line; that one edits the file where five stages of `Data ▸ Table` now
live.

A report of `sheetminfo`/`sheetmcmd` failing on `GET.CELL → None` **does not
reproduce here** — both green in the 2026-10-18 soak. Do not pull #268 early
to fix rows that are not broken in this tree.

## Open, in the order I would do them

0. ~~**`Data ▸ Table`**~~ — **FINISHED**, all five stages, SPEC.md §81.114.1
   to §81.114.11. 5 gate rows, 45 checks, 34 mutations. Nothing is owed on
   it. What it left behind, for whoever picks SHEET up next:

   - **The region has 122 bytes.** That is the binding constraint on SHEET
     now, not the overlay: `CHART.OVL` has 1,300 and `CH_OVKB` can still go
     to 63. Anything resident needs a plan first, and §81.71.5.1's precedent
     (move two dialogs out to pay for a sixth) is the one to copy.
   - **A list of "blocked on X" goes stale the moment X arrives.** Reading
     §81.93 for stage 5 found `WORKSPACE` blocked on a dialog §81.106 had
     already built, and a "13 declined macro names" miscount repeated in two
     files. Grepping the feature's own name afterwards found six more stale
     claims in four files, including §81.39's "the only menu command still
     genuinely missing" and three in SHEET-GAPS-PLAN.md — the file CLAUDE.md
     sends a reader to as "the current list". **When a feature lands, grep
     its name through every declined/blocked/deferred list.**
   - **§81.39's function count is now the stale thing to watch.** It was
     re-measured 2026-09-11 at 111 of ~131 and has not been re-measured
     since; several stages have added functions. Re-measure, never quote.

1. **CHART IS COVERED — 5 rows** (`chartname`, `chartread`, `chartgal`,
   `chart2ser`, `chartexp`), up from 1. The readers (`0b1d5c11`), the menus — where
   `Data > Column` **found and fixed a real defect** (`a636a4ff`) — the
   drawing half in pixels (`c10b88be`), the two-series data model
   (`87cfd191`) and the decimal exponent (`3677ee5f`). **Chart is covered.**
   Two real findings came out of it: `Data > Column` charted a named range
   nothing had defined (fixed), and `ct_finalize`'s "series two first"
   ordering turns out to be load-bearing for EVERY chart, not just the
   two-series ones - scaling an empty second series writes `ch_e10` too, so
   reversing it labels every file's axis in the wrong units (82.13.2).
   **READ `stable()` IN tests/chartgal.py BEFORE WRITING ANOTHER PIXEL ROW.**
   The canvas is composed OFFSCREEN, so the screen does not change DURING a
   render and `ui.settle()` returns mid-draw. The wait is: canvas changed ->
   next SCREEN change (the blit) -> settle -> one PAUSED read. Four
   conditions, none sufficient alone, and the version that tolerated a bad
   read with a pixel threshold MISSED ITS OWN MUTATION.
2. **The FPTEST redraw defect.** Chased, not solved; SPEC.md §84.4.1 has the
   whole measurement and `911919d7` corrected two claims I had got wrong.
   Where it stands: it needs the 460 width **and** the multi-second paint
   (wide+fast is clean, narrow+slow is clean), the first paint is always
   right, and a later redraw can end with `fpt_bad` = **236** when there are
   only 126 cases — so a redraw's verdict is garbage and this is not merely
   cosmetic. Ruled out: the screen saver, `m.fbuf()`, a width cap.
   **The thing that blocked every attempt to measure a redraw**: a 126-case
   paint is ~8 GUEST seconds and the pointer cannot move through it, so
   `ui.close()` (8s) and `os88mouse.to` (6s) both expire inside one repaint.
   Raise those budgets past a paint before trying again. Re-entrancy is the
   obvious candidate and is NOT proven — the nesting counter says maxnest=1,
   but no redraw happened in any instrumented run. **Do not "fix" it by
   caching the results**: the app's header says running the cases in W_PAINT
   is the design, so the screen is never stale.
3. **FOUR things to send upstream**, all the same shape — two branches each
   adding their own version of something:
   - `tools/martypc/build.sh` **cannot rebuild the instrument at their tip**:
     `12-hercules-lone-page1` (#257) and `13-hercules-page1-lone-card` (#252)
     are mutually exclusive and both patch `bus/mod.rs` + `mda/mmio.rs`. This
     fork deleted 12. Nobody with an existing `build/martypc/` sees it.
   - ~~the `t_wire` sidecar case-folding fix~~ — **DOES NOT REPRODUCE at
     `ad1be5d6`** (checked 2026-10-18). Their `t_wire` passes 332 checks with
     `tools/os88wire.py` byte-identical to theirs, because the test names its
     fixtures `SIDE%02d.DAT` — UPPERCASE — with a comment saying why:
     *"--pack upper-cases a sidecar (8.3), and --verify opens that name,
     which a case-sensitive host does not find as side00.dat"*. They fixed
     the FIXTURE, not the tool. It may well have failed at `277313a`.
     Our 17-line `--verify` fix is still a real robustness fix — `--pack`
     accepts a catalog that `--verify` then refuses, for a sidecar written
     lowercase on a case-sensitive host — but it is an IMPROVEMENT to offer,
     not a defect report, and sending it as the latter would be wrong.
   - the duplicated `### 105.9` heading
   - `vid_disp_init`'s missing `vid_ctx_capture` — OUR ghost, still theirs,
     and re-confirmed in this merge: their `je .jout` short-circuit IS it.
4. ~~**`tools/os88cf.py`'s four-partition layout is obsolete**~~ — **it was
   not, and this item was itself the stale thing** (`9f45acd9`). Four is
   §52.2's offering and the only cap left; each slice's SIZE has been read
   off `--part1`'s own geometry since §18.7.5, so `make cfimg` lays 32MB and
   `make cfimg CFGEOM=261/255/63` lays ~2.0GB, four of which reach ~8GB.
   What was obsolete was three PARAGRAPHS — in SPEC §52.2, in the Makefile's
   cfimg block and in the tool's docstring — **two of which contradicted
   themselves inside the same file**, each stating the new ceiling and the
   old one within fifty lines.
5. **The menu-bar overprint** — Control Panel text at rows 0–11, photographed
   once on the Satellite, never reproduced. `VBEDIAG=1` at it if it recurs.
6. ~~**`build/mfm20.img` and `build/wiredata360.img` do not exist**~~ —
   **nothing was owed here either.** Both are prerequisites of their own VM
   targets with rules attached (`$(MFMIMG)` for `xt-mfm`/`pc5150`,
   `wiredata360.img` for `xt-wire`), so running the target creates them;
   this item read like a task and was a description of an empty `build/`.
   Both exist now (21MB blank platter, 360KB empty volume). **Both are KEPT
   disks** — `mfm20.img` accumulates an install and hibernate, and
   `wiredata360.img` is The Wire's scratch because Add to Disk writes — so
   they belong on the never-sweep list beside `build/hdd.img`.

## Things that will bite the next person

- **A PASSING MUTATION INDICTS THE FIXTURE, NOT THE CHECK** — five for five
  in this one feature. Every time the assertion was right and the fixture
  never reached the mutated code, because it sat on a degenerate value: ONE
  table (the guard's `[sh_ntbl]==0` early-out skipped the mark test), SHEET 1
  (`cursheet` 0 makes packed row == row), a ONE-INPUT table (half the
  input-shifting code never entered), an input cell ON the table's top row
  (dropped through the other rule — right outcome, wrong reason), and an undo
  of an operation that does not CHANGE the count. Ask "does the fixture reach
  the mutated instruction" and "is there an earlier early-out" **before**
  rewriting the assertion. My instinct was to rewrite the check every time,
  and every time that was the wrong repair.
- **ASK, DO NOT COUNT — and the full soak is what says you counted.** Adding
  one row to the Calculation dialog broke two gates and one shipped macro
  command, all three counting a position that moved, and **the targeted runs
  missed both gates**. `sheetfmt` now derives a menu item's row, a menu's bar
  position, a dialog's radio row and a dialog's OK button from the guest and
  the assembler's map; nothing in it is a measured pixel or a counted index.
  Three for three in this feature: an inserted menu item (§81.114.7), an
  inserted dialog row, and a mode number a comment had reasoned away.
- **A COMMENT THAT REASONS FROM A FEATURE'S ABSENCE GOES BAD SILENTLY.**
  `shm_mcalcn` folded `CALCULATION(2)` into Automatic because *"SHEET has no
  tables, so automatic"*. True when written; false from §81.114 stage 1, and
  nothing re-reads a comment when the feature it reasons about arrives.
- **SHEET 1 IS THIS APP'S DEGENERATE PARAMETER.** `[sh_cursheet]` is 0 there,
  which makes the packed row word equal the plain row — so every bug that
  confuses the two is invisible on Sheet 1. It has hidden **two** defects in
  `Data ▸ Table` alone: stage 1's `sh_table_unbank` (restored input cells on
  Sheet 1 and nowhere else, for a cycle) and stage 3a's `[sh_cursheet]`
  assignment (deleting it passed all seven checks of a brand-new gate). Any
  change touching a row word, `[sh_cursheet]` or a side table keyed by a
  packed row owes a **Sheet 2** fixture — and the sharp assertion is not
  "Sheet 2 is still right", which it can be by never being touched, but
  **"Sheet 1 has no ghost at those coordinates"**.
- **A CHEAP EARLY-OUT MAKES EVERY CHECK BEHIND IT VACUOUS.** `sh_prot_blocked`
  returns at once when `[sh_ntbl] == 0` — correct, and it costs a sheet with
  no table nothing. `tests/sheettbl2.py`'s last check cleared the ONLY table
  and then asked whether the cell was editable again: with no table left the
  guard returned before reading the per-cell mark, so **the mutation that
  deliberately leaves the mark behind passed all six checks**, against a
  paragraph of SPEC.md §81.114.7 that said it would fail. Two tables in the
  fixture now. Ask what the cheap path skips, and keep the fixture off it.
- **PREDICTING A MUTATION'S RESULT IS NOT RUNNING IT**, twice in two days.
  Both times the prediction was written into SPEC or the suite row first.
- **A LONG-LIVED `build/` IS NOT A FRESH ONE.** The merge bumped the package
  format (10 app / 11 driver / 5 module) and this checkout held **27
  on-demand packages built at 8 and 9**, plus a pre-merge `os8088-usb.img`
  and `.iso`. `t_pkg` and `t_livefull` both caught it; the merge worktree was
  green because it started empty. They were deleted and regenerate on demand.
  `build/hdd.img` is KEPT — do not sweep it up with them, and nor are
  `build/mfm20.img` (an install and a hibernate accumulate on it) or
  `build/wiredata360.img` (The Wire writes to it).
- **A SKIP IS NOT A PASS**, twice in one day. Three `test-full` rows skipped
  silently because a fresh worktree has no MartyPC stage; and `sheetmove`
  skipped through two whole sweeps because `build/sheetmove360.img` would not
  build — `$(CC_OVLZ)` was used 190 lines before the include that defines it,
  so the prerequisite was a file called `/CHART.OVL`. The sweep says
  `1 artefact(s) would not build` on the line above the summary. Read it.
- **MARTYPC IS FIVE PATCHES NEWER, AND THIS CHECKOUT'S STAGE WAS STALE UNTIL
  TODAY.** Upstream added covox, keyboard hold-scancode, two Hercules page-1
  fixes and VGA write mode 3. The stage here was from **Sep 7** and had no
  `os8088_xt_vga_128k`, so `kernresident` died at launch with
  `No machine configuration for specified config name` — a red row that had
  nothing to do with what was being changed. Only two files actually differ:
  `run/martypc_headless` and `run/configs/machines/ibm5150.toml` (54,067 →
  91,852; `build.sh` APPENDS `tools/martypc/configs/os8088_machines.toml` to
  it). Both were copied across from `../os8088-merge-20261014`, which has the
  Oct 16 build. `sh tools/martypc/build.sh` rebuilds from scratch; `src/` is
  609MB and `run/` is 12MB.
- **A VALUES-ONLY GATE IS BLIND TO THE CHROME, again.** `tests/fptest.py`
  reads the summary line out of bss and would pass with the third column
  drawn off the screen entirely. It was a screenshot that showed the 38 rows
  actually land, and the same screenshot that found the band corruption.
- **THE GATE'S BUFFER WAS THE APP'S SCRATCH.** FPTEST's summary line shared
  `fpt_out` with the four doubles a case under test lives in. That was free
  while a paint took half a second; at 126 cases it takes over two, a redraw
  arrives, and the gate read `  8087 -` back as `` a\xe7R\xee!0``. If a test
  reads a buffer out of an app's bss, check what else writes there.
- **Seven emulators on a loaded desktop starve each other.** Seven sheet rows
  "failed" at a 1630s timeout and all pass in 25–74s at `--marty-jobs 2`.
  `sheetmtailherc`'s standing "flaky" note is this, and nothing else.
- **A dialog that renders correctly and a click that silently misses** produce
  38 red rows and zero error messages. What identified it was noticing the 18
  PASSING rows were exactly those that never open a chooser — then
  photographing the dialog.

## 2026-10-18 — the gfxbench reader, and the VBE `jnc` measured

- **`tools/gfxbenchread.py` exists now.** It boots the bench disk under
  MartyPC, picks Bench ▸ Run, waits for the end-of-report LINE (not a clock,
  not a row count), and reads all 74 measurement rows out of the package's own
  bss by symbol — benchlib's `bl_arena`/`bl_idx`/`bl_nrow`, where `bl_idx`
  entries are **arena-relative** (`bl_lcommit` stores `[bl_used]`; `bl_fetch`
  adds the base itself). It then saves the report and reads the file back
  through `os88flush` as a second walk of the same rows. `--knob K=V` builds
  the other A/B arm with `os88build.tree` and boots that; `--file`, `--grep`,
  `--json`, `--out`, `--full`, `--no-save`.
- **The column offsets and the end-of-report sentence are DERIVED** from
  `tests/benchlib.inc`'s `BL_C_*` and `tests/gfxbench/gfxbench.asm`'s
  `gb_s_end1`, so a format change stays one edit. Mutating `BL_C_US` or
  `BL_C_UNIT` by one gives **0 rows** and the tool FAILs; the cross-check
  catches a dropped row, a changed digit and a save that did not happen.
- **`open` returns before the menu bar is relaid.** The first run died with
  "no single menu called 'Bench' … the bar is ['Apple','File','Edit','Nav',
  'Disk','Sticky Apps','Gfx Bench']" — the Disk window's cells with the app's
  NAME cell already appended. A UI pass later it is `['Apple','Bench','Gfx
  Bench']`. The tool now waits for the cell. **Any driver that picks an app
  menu straight after `open` has this bug.**
- **The VBE row advance costs 22 cycles a row and 11–25% on every rect.**
  PERFORMANCE.md **Set 161**, SPEC.md §39.29.3 updated. `jnc %%same` is
  **TAKEN** 511 times out of 512 — the spec said "not-taken", which is the
  whole gap between the 9-clock estimate and the 22 measured. `vga_solid_rect`
  has FOUR `VBROW` arms and a 64px rect walks three of them per row, so
  4,135/64 = 64.6 = 3 × 21.5 and the arithmetic closes.
- **The control is the better half**: every row with no `VBROW` on it agrees
  between the arms to 0.02% — all the RAM/VRAM bandwidth rows, `GFX_BLIT1`,
  `GFX_SCROLL`, `FONT_RUN` (no `VBROW`) while `FONT_CHAR` (one) moved 3.3%.
  The sandbox geometry was identical on both arms; the reports' provenance
  blocks differ only in kernel span, free heap and boot ticks.
- **So the VBE PR cannot ship arm A.** Either arm B (banked twins selected
  once per operation — bytes instead of time) or finish §39.29.10's revision,
  which deletes the per-row test: `gfx_rowbase_calc`'s `mul word
  [cs:vid_stride]` already yields the bank in DX, and a straddling primitive
  is cut at row 512 the way `gfx_disp_run` cuts at a display seam.
- Still owed on VBE: the 86Box row for the POSITIVE case, and the renderer /
  additive split before offering it upstream.
- NOT committed yet: `tools/gfxbenchread.py` (new), PERFORMANCE.md, SPEC.md,
  docs/TESTING.md, tests/benchlib.inc.

## 2026-10-18 (later) — §39.29.10.5: the per-row bank test is GONE

Option 1 of the three, done: `gfx_rowbase_calc` already homes the bank, so the
only thing the row loops needed was a guarantee they never cross one — and
cutting the rect at the boundary is that guarantee.

- **`vbe_cut_run` + `VBCUT`/`VBCUT_ARM` + `VBSTEP`/`VBSTEPR`** (kernel/vbe.inc,
  kernel/viddet.inc). Three hooks: `vga_solid_rect`, `gfx_fill_gray_raw`,
  `gfx_fill_pat_raw`. 9 `VBROW` → `VBSTEP` (bare add), **6 `VBHOME` calls
  deleted**. `[vbe_cutrow]` is published by `vid_apply` and is 0xFFFF on every
  mode but 0104h — **verified by reading it on a booted VGA and CGA** — so one
  unsigned compare answers "not banked" and "does not straddle" at once.
- **The hook is on `vga_solid_rect` and NOT on the four `_raw` entries**, and
  that is load-bearing: `menu.inc` enters `vga_xor_fill_vram` *directly*, so
  hooking the entries would have left that route uncut while the body's row
  advances had already given up their test.
- **Measured: every rect primitive 10–19% faster than the kernel that
  shipped** (PERFORMANCE.md Set 162). FOUR rows beat even the `NOVBEROW=1`
  no-test floor, because **`VBHOME` never had a knob** — both of Set 161's arms
  paid three `call vbe_home` per solid rect, so Set 161 *under-reported* the
  old design. Small rects are +1.6–2.7% over that floor (six bytes at the
  8088's fetch floor) and break-even against what shipped.
- **Cost `.text` +96, bss +0, cold +0, no rung crossed.** (kernsize's
  "CROSSED" line is against a stale blessed baseline — the image rung was
  already 97 steps before this change. Pre-change text was 44,269; it is
  44,365.)
- **`tests/vbeident.py` is new and is the gate the plan asked for**: mode 12h
  byte-identical over three settled frames (desktop / Disk window /
  Calculator, 307,200 px each) against `build/vbeident-before.cap`, which was
  taken BEFORE the change and is worth keeping. `--mutate` (one bit of
  `gfx_lmtab[0]`) moves 97 and 117 pixels, so the captures demonstrably reach
  `gfx_rect_setup`; `--twice` answered 0 on two runs of one build.
- **`--cutrow 200` is the trick worth remembering**: no emulator here can
  enter 0104h, but poking the word that says where the window ends makes the
  cut fire on mode 12h, where a correct cut must be pixel-neutral. Proven
  non-vacuous — skipping one row inside `vbe_cut_run` gives a bbox of exactly
  `(105, 200, 424, 200)`.
- **NASM trap that cost an hour**: a macro emitting a non-local label
  (`<name>_vbody:`) in the middle of a routine RESETS the previous-non-local
  label, so every `.arm`/`.lcol`/`.done` below it silently re-homed. The build
  failed with `symbol vga_solid_rect.arm not defined` plus thirty
  `label changed during code generation` errors naming `kernel_text_end` — not
  one of which points at the macro. The re-entry label must begin with a
  period.
- Still owed: `gfx_blitp` is +10.3% over the floor and keeps the per-row test
  (§39.29.10.6 lists it with `gfx_save`/`gfx_restore`/`font_char`/`ico_pass`/
  `cur_draw`); the 512-row boundary itself is only checked on hardware, since
  `--cutrow` proves the cut for an arbitrary row but the Satellite is where
  0104h can be entered.
- Gates run ONCE after the last edit: `make` (48/0/0 fast), `NOVBEROW=1` and
  `KERN_SMALL=1` both build, soak `vbeident vgadirty dispcorner paintundo-vga
  dispseam dispblitp paintpal paintblank blitplane blitcut` 10/0/0,
  `test-full` 57/0/0.
- NOT committed: kernel/vbe.inc, kernel/viddet.inc, kernel/vga12.inc,
  Makefile, SPEC.md, PERFORMANCE.md, docs/TESTING.md, tests/suite.py,
  tests/vbeident.py (new), tools/gfxbenchread.py (new), tests/benchlib.inc.

## 2026-10-18 (later still) — gfx_blitp off the per-row test too

- **It took a DIFFERENT answer from the three rect primitives**, and the
  routine's own comment is what pointed at it: the per-row test was only ever
  in the plane-major fast path, which "holds the block's first framebuffer
  byte and steps by [vid_stride], every planar surface being ONE bank". So a
  crossing block is sent to the general `.row` path — which calls
  `gfx_rowbase` per row and therefore homes per row — instead of teaching the
  fast path to bank. Two compares and an add, once a blit. §39.29.10 always
  said this (it already does it for `gfx_scroll`).
- **GFX_BLITP 64x64 13,770 → 12,379 µs, −10.11%, and 0.9% BELOW the
  `NOVBEROW=1` floor** — four more `VBHOME` calls, one per plane. 256x16
  −4.28%. `.text` +8 (total for both passes **+104**, 44,269 → 44,373).
- **THE PAINT FRAME I ADDED TO GATE IT DOES NOT GATE IT**, and the mutation
  is what said so: breaking `gfx_blitp.row` by a byte changed nothing. Paint
  opens with a PACKED canvas, asks §5.4.3.2's probe during a repaint,
  converts with `pt_toplanar` only if told yes, and blits planar from the
  repaint AFTER that — one open and one settle never reach the routine. The
  frame is kept for what it actually is (a fourth window of chrome on the
  identity surface) and the false claim is corrected in the file, in SPEC and
  in PERFORMANCE.md rather than left in a comment.
- **What IS proved is the mode 12h direction, by measurement**: 12,379 µs is
  the fast path where `.row` would be ~35,000, so the compares demonstrably
  fall through. The other direction (a crossing block really reaching `.row`)
  is ungated and only matters in a mode no emulator here can enter; forcing it
  needs the conversion and a second repaint driven — `tests/paintpack.py`'s
  territory.
- Gates: `make` 48/0/0, NOVBEROW=1 and KERN_SMALL=1 build, soak `vbeident
  blitp dispblitp paintpack paintblank paintundo-vga` 6/0/0, `test-full`
  57/0/0, `vbeident --ref build/vbeident-before.cap --cutrow 200` still 0
  differing pixels on all four frames.

## 2026-10-18 — the cut RUN in the banked mode (86Box), SPEC §39.29.9.1

`make vbebox`, then `make VBEDIAG=1 build/vbeos.img` + `tools/os88box.py` with
a burst of `--do shot:` frames. 86Box's Trident is the only card here that
enters 0104h.

- **A correct 1024x768 desktop**: chrome at the TOP, dither unbroken through
  row 512. The desktop fill spans 0..767, so that picture IS the cut's output
  in the banked mode — and the negative of §39.29.10's own failure picture
  ("the whole chrome 512 rows down").
- **A window drawn whole across the boundary**: VBEDIAG puts it at 470..670
  by construction; title bar, frame, content, shadow and both corner boxes in
  one piece, no tear at 512.
- **Before and after the round trip are BYTE-IDENTICAL** (same SHA-256 of the
  whole framebuffer PNG): dragged down across the boundary and back, no ghost
  at the vacated rect, no residue anywhere.
- Kept: `build/vbebox.png`, `build/vbebox-vbediag-{before,across,after}.png`.
- **Reading the frames by HASH first was the right move** — 8 of my first 11
  shots were the same picture, and the drag is a ~6-second window. Fingerprint
  the burst, then look only at the frames that changed.
- **A VBEDIAG build leaves a KNOB kernel in build/** — rebuilt plain
  immediately (every marty row dies on "the map describes a DIFFERENT kernel"
  otherwise).
- Still open: §39.29.9's bank-select mutation (no window to move on mode 12h,
  so it needs 86Box or the Satellite); the Satellite itself (Trident vs
  NeoMagic, §39.29.8.2); the PR split.

## 2026-10-18 — §39.29.9's bank-select mutation, done (SPEC §39.29.9.2)

The acceptance bullet that was still open. **The point is not the picture —
it is that §39.29.9.1's picture would be worth NOTHING if the window never
had to move**: a card (or an emulator) mapping all 98,304 bytes at A000 would
render that desktop correctly with the bank select doing nothing, and every
VBE figure taken here would be vacuous. §39.28.2.2's defect class.

- The mutation is two lines in `vbe_bank`: `xor al, 1` right after
  `mov [cs:vbe_cbank], al`, so the CACHE keeps the bank the kernel believes
  (every early-out still behaves, nothing refuses) and only the HARDWARE
  window is wrong.
- The mutant desktop comes up with **the menu bar, clock and floppy icon 512
  rows down the panel**, a black band where the real window was never
  written, dither above and below — the failure §39.29.10 records from the
  Satellite, in its own words.
- Reverted and re-ran: §39.29.9.1's picture back with **0 differing pixels**
  outside the clock's field. So it is an A/B/A, not two photographs that
  happen to differ.
- Kept `build/vbebox-mutant-wrongbank.png` beside the good ones.
- ONE-OFF, not a knob: the arm it would keep assembling is a kernel that
  cannot draw, and only 86Box and the Satellite can run it. The two lines are
  in SPEC so the experiment is repeated rather than re-derived.
- §39.29.9 now reads MET on both bullets. What is left on the VBE track: the
  Satellite (Trident here, NeoMagic there — §39.29.8.2), and the PR split.

## 2026-10-18 — PR #272 opened; the VBE split DEFERRED with reasons

- **#272 `upstream-gfxbenchread`** (off origin/main, 1 commit, +436/-0 in
  three files): the reader, the benchlib pointer and the docs/TESTING.md
  paragraph, with the fork's own Set 161/162 citations scrubbed. checkdocs
  clean on main. Every dependency exists upstream and benchlib's report
  format is BYTE-IDENTICAL there, so the parser is portable as written.
- **The VBE split is deferred, and the reasons are measured, not guessed:**
  - replaying the 20 VBE commits onto origin/main: the first conflicts on
    SPEC.md, and after resolving it **18 of the remaining 19 still conflict**,
    because each later commit edits SPEC text whose numbering just moved;
  - upstream's §39.28 is **Force Color**; the fork renumbered it to §39.30 to
    put VBE at §39.28/§39.29, so a PR to main must shift the VBE sections —
    **230 citations of 39.28/39.29**, where a wrong one resolves to a real
    but WRONG heading and checkdocs passes it;
  - the feature touches ten kernel files diverged by 310 commits, so "just
    the VBE hunks" is a reconstruction;
  - and **#268 landing will reconcile §39.28/§39.30 anyway**, so a renumber
    done now is thrown away then.
- **The split BOUNDARY is settled and costs nothing to keep**: stage 1
  (VBE.DRV, probe, fifth vid_kind, 1024x512 — no hot-path change) = commits
  b200d93e..b6410805; stage 2 (banking + the cut) = 864f6e95..e068635a.
  Stage 2 depends on 4b000b85, already offered standalone as #271.
- Worktree at <scratch>/wt-vbe on branch upstream-gfxbenchread; the throwaway
  `upstream-vbe-try` branch can be deleted.

## 2026-10-18 — SHEET 1.8 #15: the radio dialogs take Excel's shape (§81.115)

- **One engine, FIFTEEN dialogs** (not the report's six): Format Number,
  Alignment, Font, Insert, Delete, Clear, New, Calculation, Sort, Gallery,
  File Format, Paste Special, Cell Protection, Extract, Series.
- Titled group box with the label breaking its top edge, OK/Cancel **stacked
  top right**, and the height **per kind** (`WT_H` patched at open the way
  `WT_X`/`WT_Y` already were). Photographed against
  `_LIBRARY/.../excel/dialog_alignment.png`: same structure.
- **CHART.OVL +113 (50,924 -> 51,037, 1,187 spare); resident UNCHANGED** at
  52,029. The engine is `section SH_MODSEC`, which is the only reason this
  was affordable at 122 resident bytes.
- **The label uses ONE opaque `font_run`**, not `sh_bdlg`'s
  FONT_WIDTH+GFX_FILL+transparent-string: the run's own ground is the erase
  that breaks the frame line. Three calls become one and no new site joins
  `tests/textsites.txt`'s ratchet.
- Per-kind height also **retires** the CGA `OSAPI_WM_KEEPH` workaround's
  reason - the tallest kind is now shorter than the fixed 171 it was.
- **THE BILL WAS THE GATES: 40 files, 99 call sites.** They clicked at screen
  absolutes (`FMT_RADIO_X = 246`, rows `55 + 16*row`, OK `(267,170)`), right
  only while every kind was one size - which `tests/sheetcalc.py` had written
  down as the reason it was safe. Deleted, not re-measured: `SF.fdlg_xy(m,
  row)` / `SF.fdlg_okxy(m)` read the FRONT WINDOW's rect out of `wm_wins`.
  Kernel-side on purpose - 35 of those files have no package symbols at all.
- **Two slips the conversion made, both caught by running rows:** a file with
  a local `FMT_OK` alias got an unqualified `fdlg_okxy` (NameError,
  sheetdbcmd), and `sheetfmt.py:616` was clicking Cell Protection's row 1
  through `FMT_ROW['slk']` - correct by accident, misleading by name.
- Gates: `make` 48/0/0, soak 16/0/0 across every dialog kind touched
  (sheetfmt sheetcalc sheetcolw sheetsort sheetundo sheetrowh sheetside
  sheetseries sheetrecord sheettable sheetdbcmd sheetnumfmt sheetxl2
  sheetjust sheetcell), `test-full` 57/0/0.
- Evidence kept: `build/dlg-align.png`.
- NEXT in 1.8: #9 dotted gridlines + #10 boxed headers (price the pattern
  lines on the 8088 first), then #11 inverted selection, #13/#14/#4.

## 2026-10-18 — 1.8 #10 shipped, #9 measured and DEFERRED (§81.116, §81.116.1)

- **#10 boxed headers SHIPPED** as the corner box: two SHORT one-pixel rules
  (the row-header column's width, the column-header band's height). Row 1's
  own top gridline and column A's left gridline already rule the headers off;
  only the L was missing. 83 bytes, **46 resident spare**.
  - They started as two LONG rules and the GATES cut them down: a full-width
    rule sits 1px above row 1's gridline and a full-height one 1px beside
    column A's, and `glass.py` reads the grid out of the GAPS - `sheetrowh`
    saw `[1, 11, 14, 33]`, `sheetcolw` a first gap of 161 where it wanted
    36..46. Shortening removed the collision AND the redundancy.
- **#9 dotted gridlines: MEASURED FREE, NOT SHIPPED.** `GFX_FILL_GRAY 256x1`
  is **599.49 us against GFX_FILL 256x1's 608.61** - 9 us FASTER, spread
  0.05 us (PERFORMANCE.md Set 163, and a new `GFX_FILL_GRAY 256x1` row in
  gfxbench that stays). The look report expected pattern lines to cost MORE.
  - **What stopped it is the instrument, not the renderer.** A 50% dither and
    a dotted line are locally the same thing, and `glass.py` finds the grid by
    looking for lines - 12 sheet rows read cell text through it. Three
    detectors tried, each failed on the next capture (one phase -> finds the
    desktop; opposite phase blank -> finds a dithered BLOCK below the grid,
    12 consecutive "lines" that stretch the run past it; isolate by
    neighbours -> drops the real line beside the header rule). **3 of 5 glass
    rows failed.** The attempt is kept at
    `<scratch>/glass.dotted-attempt.py`.
  - **The anchor that fixes it is #10's own**: the header rules are SOLID and
    unique, so the grid's origin is their intersection and the search can be
    BOUNDED to the grid rect where no desktop dither reaches. That is a
    redesign of a detector 12 rows depend on - its own piece of work, and the
    two lines that turn the gridlines dotted are named in §81.116.
- Gates: `make` 48/0/0, soak **19/0/0** (sheetcolw sheetrowh sheetdb
  sheetform sheethide sheetdel sheetmsep sheetcell sheetcalc sheetfmt
  sheetsort sheetnumfmt sheetxl2 sheetseries sheetmacro + earlier),
  `test-full` 57/0/0. Evidence: `build/grid-corner.png`.

## 2026-10-18 — why the next 1.8 item is the GLASS rework, measured

Tried #4 (the 2px cell-text inset) and stopped at the design, then measured
where SHEET's resident bytes actually are. Both answers point the same way.

- **#4 is not the small change the report groups it as.** SHEET aligns by
  PADDING THE STRING to the cell width (`sh_justify`, `_c`, `_t` build
  `sh_numbuf`) and draws it from the cell's left edge, so a 2px inset makes
  the usable width `cellw - 4` and changes how many characters fit - the
  three justifiers, the clip and the run-on (§81.54) all move. Not a
  candidate at 46 resident bytes.
- **A size pass has no big win.** Ranked by symbol gap, the largest resident
  routine is `sh_ovshims` at **300 bytes** (and those are the overlay thunks,
  which must be resident). By subsystem: **70% is a long tail of small
  routines**, `fp_` (softfloat) 4,437 / 8.5% - needed by every formula -
  `os88ui` 2,540, `sh_draw` 2,394 - the renderer, hot. §81.62 already moved
  48 functions to CHART.OVL and §81.102 the Note dialog; the obvious moves
  are gone.
- **So the next item is #9's blocker, because #9 is the only 1.8 item left
  that costs NEGATIVE resident bytes** (-7: the `OSAPI_SET_COLOR` dies with
  the solid fill). Everything else - #4, #11 inverted selection, #13's 58
  strings, #14's third formula-bar box - spends from 46.
- The glass rework: bound the line search to the grid rectangle instead of
  the whole screen, anchored on §81.116.1's corner box, so a 50% desktop
  dither can never be mistaken for a dotted gridline. 12 rows depend on the
  detector, so it wants its own pass with each row run.

## 2026-10-20 — #272 settled: the maintainer was right

- **His review rejected the premise and his fix is better.** Every bench
  already saves via `bl_save`; it is in CLAUDE.md, docs/TESTING.md, the
  header I READ, and each bench's file comment - and reports still get
  photographed. His answer: put it in the FIRST LINE THAT PRINTS, not a
  fifth copy of the documentation.
- **#272 is now one file, +70/-0**: `bl_lcommit` emits two lines at the top
  of every report. That is the funnel every report line passes through, so
  no bench can forget it and a NEW bench gets it free. `gfxbenchread` is
  dropped from the PR; offered separately, not pushed.
- **It composes with #268's own change to the same routine**: upstream added
  an arena reset at `.have` keyed on `[bl_nrow] = 0`; the banner sits ABOVE
  it, so the banner is the line that empties the arena on a re-run.
- **The trap, worth remembering: a package's bss is NOT ZEROED at load.** A
  "have I done this" flag in bss started as garbage and the banner silently
  never printed. It is a RE-ENTRY guard in the IMAGE now (0 whenever control
  is not inside `bl_intro`), and the condition is `[bl_nrow] = 0` so a re-run
  prints it again.
- Fork carries the same change at `c2752529`; the upstream branch is rebuilt
  on the NEW main (#268 + #273) at `199deee2`.

**NEXT: #268 HAS LANDED, so merge `main` whole into the fork.** It is the
gate in front of everything - the VBE PR split needs it (one renumber
instead of two), and the fork is 310 commits out. #268 touches the kernel's
memory map (ROM/HMA), package sidecars->parts, ASSOC.DAT writes and the
Sticky App library, so expect SHEET and the kernel to need real work.


## 2026-10-20 — the merge landed, and the three things it left owed

`3f41ce08` is the upstream merge (`ad1be5d6..1e3608d8`, #268 + #273): 882
files, +112,957/−37,945, 14 conflicts, safety ref **`premerge-20261020`** at
`c2752529`. Its own account is in the commit message and in docs/UPSTREAM.md;
SPEC.md §81.117 records the one real gap it left (upstream's ask-before-discard
and the WRITER half of borders/notes in files - we kept OURS whole and the code
is recoverable at `git show origin/main:apps/sheet/sheet.asm`). **SHEET gave
back §81.116.1's corner box to pay for the merge's bytes** and has 34 spare;
the routine is saved and re-landing it is one `call` plus the body.

Then `e780591d` and `d6bcd38e` are the fallout, and the second one is the
interesting half.

**`make` was shipping a dead SCRIBE.OVL on every scribe disk.** #268 made
Scribe's sidecar a PART of the package and dropped the file from `all`; the
Makefile conflict looked like two lists and I took ours as the superset
without asking why theirs was shorter. docs/UPSTREAM.md's rule is ours for
what THIS branch deliberately changed - not for what upstream deliberately
removed.

**#268's guide lock is what caught it**, and the lock is worth understanding
before the next merge, because it reads as 31 units of debt and was four
things:

  - SHEET_O88.md and CHART_O88.md arrived with #268 describing UPSTREAM's
    programs. This tree kept its own whole, so the pages were wrong about the
    program in front of the user - "Sheet has no undo" (it has eight named
    actions), Row Height/Column Width "change every row at once" (they are
    per row and per column), Gridlines and Formulas as menu toggles (they are
    tick boxes in Display...), and no Data menu database half at all;
  - PLAN had no manual. It has one now, and writing it found three defects no
    rig could (SPEC.md §81.75.10): two status lines naming menus PLAN has not
    got, the About card's body outliving its menu with `Sheet for os8088`
    still in it, and §81.55 never having come to PLAN;
  - VBE.DRV, CHART.OVL and MACRO.OVL had no line in entries.toml at all -
    ours, on shipped disks, undescribed since they landed;
  - **and 27 were STALE ARTEFACTS.** build/ held on-demand disks from 10-11
    carrying files that no longer ship. Nine `make <x>disk` targets took it
    from 27 to 0. If a future merge makes that number jump, REBUILD THE
    ON-DEMAND DISKS BEFORE READING IT.

## 2026-10-20 — the merge soak, 127 rows, three real failures

`sheet* chart* disp* vbe* lz*`, **124 passed, 3 failed**, 28.6 minutes wall
against 8.7 hours declared - the budgets in `tests/suite.py` are about 7x
generous, which is worth knowing before anybody sizes a run off them. All
three failures were real and none was what it looked like; `aa5c51bf` has the
account and SPEC.md §20.13.5 and §81.115.2 keep it.

The short version: **SHEET and CHART had gone back to LZ4** because the merge
took upstream's `LZBPKGS` list and left this fork's own two recipes saying
`$(OS88PKG)` (five 360KB clusters for SHEET, one for CHART), and **the other
two were §81.115's**, not the merge's - `sheettitle` clicked a literal the
sweep could not see, and `sheetdlgcga`'s tall-dialog case stopped being tall.
That second one would have gone on PASSING if the number had been edited
instead of the case replaced, which is why Gallery is in that row now and why
the KEEPH mutation is recorded beside it.

**The whole soak is 1,056 rows and 31.6 hours declared** - call it four or
five hours wall at the factor above. It has still not been run end to end on
this tree.

## What is owed next, in order

1. **The rest of the soak**, if it is wanted: everything outside
   `sheet*/chart*/disp*/vbe*/lz*` is unrun on the merged tree.
2. **The VBE PR split** - now tractable, because the merge reconciled
   §39.28/§39.30's numbering once instead of twice. #272 is settled
   (the maintainer's fix, not mine); #269, #270, #271 are open and
   REVIEW_REQUIRED.
3. **SHEET 1.8**: #9 dotted gridlines is measured FREE and gives 7 bytes
   back, blocked on the glass rework (§81.116.2 says what the right test is:
   dotted AND isolated on both axes, bounded by the window rect from
   `wm_wins` rather than more heuristics). Then #4, #11, #13, #14.
4. **§81.75.10's sweep** - PLAN's dead About card and the dialog kinds no
   menu can open. Not urgent; `pl_abdismiss` has two callers, so it is not
   a blind delete.


## 2026-10-20 (late) — three merges, the Sheet PR, and what the PRs said back

**THREE upstream merges in one day**, not one: `3f41ce08` (#268, #273),
`43554af4` (#274, #275, #277 — WireChat, the mouse wheel) and `7cf7ba99`
(#278–#283, and this fork's own two PRs coming home). `premerge-20261020`,
`-20261020b` and `-20261020c` are the safety refs.

**The four PRs all resolved, and three came back with corrections:**

* **#272 benchlib — MERGED, and it corrected me twice.** My banner said
  "press S" in a file 20 packages include, and on NETBENCH **S zeroes the
  profiler**. And my DIAGNOSIS was wrong: I wrote that a package's bss is not
  zeroed at load; `kernel/loader.inc`'s own banner says it IS. The real cause
  was gfxbench committing its facts page at launch. That false claim is in
  `c2752529`'s message and nowhere else.
* **#271 vidsel — MERGED with a fix on top.** #268 turned `vid_disp_init`
  into the `VSW_DISP` macro, so my plain `call` was a near call into the
  wrong segment and `%2` would not fit the boot blob. Their `.cap:` label
  costs **zero bytes**. Theirs taken; one paragraph of mine kept.
* **#270, #269 — CLOSED as superseded**, both findings confirmed. #269 is the
  one that paid: it prompted **#279**, which taught `checkdocs` to see
  sections 100 and up. Both its patterns stopped at two digits, so 283
  headings in this tree had never been checked.

**PR #289 IS OPEN**: Sheet 2.1 and Chart, `Koriban:upstream-sheet` →
`jggonz:main`, 92 files, +85,933/−18,189. Expect the maintainer to fetch,
build and push fixes onto the branch, as #271 and #272 went.

**What the Sheet PR needed first**, and this is the part worth remembering:
SHEET **could not save a cell note** (§81.119), while main's Sheet has kept
them for ages — so opening it as-is would have taken a working feature away.
Two of my three §81.117.1 "gaps" were wrong besides: borders ARE written (on
a (format, border, number-format) TRIPLE, §81.47.6/§81.55) and a border on an
empty cell is NOT lost (§81.77 already met it). **A symbol main has and we do
not is evidence about NAMES, not about BEHAVIOUR.**

SHEET is **version 2.1** now (`SH_VER`, About card), and that is the
PACKAGE's number — `os8088 1.0` is the system's, and `tools/os88sym.py`
searches the kernel image for that exact string.

**`APP_MAX_SIZE` went 0xF000 → 0xFE00** with #277, which is why all of this
was affordable: SHEET had 34 bytes spare this morning and has **3,158**.
§81.116.1's corner box came back with it.

## What is owed, in order

1. **THE REST OF THE SOAK. 951 of 1,080 rows are unrun** since three merges
   landed — 23.5 hours declared, so about 3–3.5 wall at the measured 7×. Only
   `sheet*`/`chart*`/`plan*`/`disp*`/`vbe*`/`lz*` have been run. This is the
   merged tree's one real hole.
2. **The VBE PR split** — still never done; the merges reconciled
   §39.28/§39.30's numbering, which was the thing making it awkward.
3. **SHEET 1.8's remainder**, now affordable at 3,158 bytes: #9 dotted
   gridlines (measured FREE and gives 7 bytes back, blocked on the glass
   rework — §81.116.2 says what the right test is), #4 cell inset, #11
   inverted selection, #13, #14.
4. **§81.119's owed round-trip gates** for the formats other than notes.
5. **§81.75.10's sweep** — PLAN's dead About card and the unreachable dialog
   kinds. `pl_abdismiss` has two callers, so not a blind delete.


## 2026-10-21 — the first whole-tier soak, and what 100 failures actually were

`os88soak.py start --user-asked --anyway -x editmove`, 1,230 rows, **4h 22m**:
**1,119 ok, 100 FAIL, 11 SKIP**. The headline is that almost none of it was a
defect in what the rows test, and almost none of it was the merges.

**69 of the 100 CANNOT RUN under `os88soak.py` at all.** It builds a private
tree (`build/trees/plain-<hash>/`) and those rows pack their own fixture
floppy at a hardcoded `build/...` path, then ask the launcher for it:
`FileNotFoundError: build/trees/plain-0744cacc/sheetask.img`. The whole
`sheet*`/`chart*` family is in there - the same rows that run **69/69 green**
under `os88test.py`, which uses the real tree. The documented shape is
`os88fixture.need()` plus a `wants=`; these rows have neither. **This is the
single biggest thing owed.**

**13 were starvation** under the 8-wide lane and pass serially - the whole
video family among them. `videnc` alone forks ffmpeg across every core.

**3 were the owner's own `node backend/server.js` processes** holding ports
8094/8095/8099 (the suite hard-codes 8090/8092/8094/8095/8099). Freed, all
three pass. The durable fix is to bind port 0 and read back what the OS gave
us: the port already flows into the guest through `HOSTLINE`.

**2 were a FOUR-DAY-OLD EMULATOR.** `wheel` and `kbdburst` drive MartyPC
patches 15 (serial wheel) and 14 (keyboard pacing) that arrived with the
merges; `martypc_headless` was built 2026-10-16. `make marty` fixed both in
50 seconds. **A stale emulator is a class**: it fails rows that test the
GUEST and names the guest in the message. `os88soak.py check` reads the
kernel map for exactly this shape of staleness and could read this too.

**12 were real and are fixed:**

| row | what it actually was |
|---|---|
| `vidbigclus`, `vidkeyclus`, `vidhdmake` | asserted CURATION - they boot apps360.img for VIDEO.O88, which this fork removed on 2026-10-05. Red for a fortnight. Each builds its own handler floppy now |
| `smallreq` | allowlist literal vs `$(KMODS)`; SERIAL.DRV joined with #278. **Red on upstream's main too** |
| `rdiffself` | the fixture's `jmp near` was not `strict`, so NASM 3.01 shortened it and the one case about branch relaxation tested nothing |
| `kernmods` | `vbediag.inc` - our first CONDITIONAL `%include` - killed the whole kernsize pass; and `vbe.inc` was in no theme |
| `shedrelist` | opened GORILLAS.O88, which OUR commit removed from kern_small on 2026-10-07 |
| `buildmatrix` | NOVBEROW and VBEDIAG in no row: nothing assembled either arm |
| `regrowshed` | WireFleet (#278) filled small360.img; the fixture needed 24 clusters and had 20 |
| `wheel`, `kbdburst` | the stale emulator above |
| `regmove` | Sheet cannot be its subject here (139090 pins the region). 3 problems -> 1 |

**Only TWO of the twelve came from the merges** (`smallreq`, `regrowshed`).
The rest had been quietly red for days or weeks. **That is what the whole
tier is for**, and why it had not been run is why they lasted.

## Still open from the soak

1. **`lzship --fmt lz4` cannot build apps360.img**: 356 clusters needed, 354
   held. WireFleet joined that disk with #278; packing it LZB won 4 clusters
   back (21 free now) but the lz4 arm forces LZ4 everywhere, so it does not
   help there. **The 360KB apps disk now DEPENDS on LZB.** That is a real
   constraint and 24.6.1's kind of decision - what comes off, or does the arm
   carry less - and it is the owner's, not a gate's.
2. **`gfxlk`**: `scrolled PAST entry 2 - the list moved under us`.
   `ui.scroll_to` walks to the top then down until `scroll >= entry` and can
   OVERSHOOT; the row's own comment already records this class ("it only
   started mattering when GAMES grew past the window"). GAMES has grown
   again - isoTron and WireFleet.
3. **`regpin`**: `regmove`'s sibling, not yet diagnosed; likely the same
   pinned-region cause.
4. **`regmove` check 5**: 220 px on ONE row (y=186), Calculator's History
   separator between a paint and a repaint. Left named rather than tuned.
