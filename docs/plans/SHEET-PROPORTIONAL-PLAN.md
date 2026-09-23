# SHEET in proportional type: what it would take

**Status:** a study, not a start. Nothing here is built. Written 2026-09-23 for the owner's
request to "look into supporting proportional" fonts, after the 1.8 look measurement listed
proportional cell text as its largest remaining gap
(`docs/reports/SHEET-EXCEL-LOOK-2026-09-22.md`, gap #16).

Every number below was **measured on the tree at `cbe8691`** unless a line says *estimate*.
Re-measure before quoting any of them; the resident headroom in particular moves with every
SHEET commit.

## 1. The answer

**Yes, SHEET can set its cell text in Helvetica.** It would use the OS's own mechanism,
`apps/os88type.inc` (SPEC §6.3, §6.5), on every adapter. Nothing the OS lacks is required. Four
things stand in the way:

- **No claim slot is free.** SHEET holds 8 of `MEM_OWNER_MAX`'s 8, and the library wants one or
  two more.
- **No resident room.** The library's bss alone is 1,933 bytes against 97 free.
- **Character-based layout.** Everything that lays out a cell counts in 8-pixel characters.
- **Screen-reading tests.** 19 test files read cell text off the screen by matching 8×8 glyphs.

None of these is a wall. Each has a known way through, costed below. **Speed is not a
blocker** (section 5).

The recommended path is staged:

1. Make room.
2. Set cell text in Helv behind a **display setting that defaults off**, so every existing gate
   keeps its meaning.
3. Headers.
4. Only then, consider making it the default.

The formula bar, the dialogs, the menus and the status bar stay in the 8×8 face.

## 2. What the OS already provides

| Piece | Where | What it gives SHEET |
|---|---|---|
| The method | SPEC §6.3 | compose a row of glyphs into a 1bpp band in your own RAM, emit it with one `OSAPI_GFX_BLIT1` |
| The library | `apps/os88type.inc` (1,644 lines), SPEC §6.5 | `ty_openfam`/`ty_use`/`ty_width`/`ty_fit`/`ty_hit`/`ty_band`/`ty_putn`/`ty_flush`; face 0 is the kernel's 8×8 face, so a missing `.F88` degrades to the system face on the same code path (§6.5) |
| The emit | `OSAPI_GFX_BLIT1`, SPEC §5.4.2 | works on CGA, Hercules, EGA and VGA; refused on `kern_small`, where `ty_flush` returns CF and the caller letters with `OSAPI_FONT_RUN` instead (§6.5) |
| Greying | `ty_flush` via `OSAPI_GFX_PEN_CF` (§6.5) | a disabled band is dithered for the caller |
| The faces | `faces/*.t88`, built into `SYSTEM/FONTS` (Makefile:3039) | ten families; **Helvetica** is `faces/helv.t88` (Arimo, OFL) |
| A working consumer | `apps/word/word.asm` (`WD_PROPDRAW` = 1 at :325; `ty_cache` at :2760) | Word sets its document in a chosen face today |

### 2.1 Helvetica measured against SHEET's grid

Read from `faces/helv.t88`, the face's own source:

| | Helv | SHEET today (8×8) |
|---|---|---|
| glyph rows / ascent / leading | 12 / 9 / 2 → **a 14-px line** | 8 rows in a 14-px row (`SH_RH_NORMAL` 14, `sheet.asm:173`) |
| lowercase advance, mean | **6.4 px** | 8 |
| uppercase advance, mean | 7.7 px | 8 |
| digits | `0`,`2`-`6`,`8`,`9` = 8 px; **`1` and `7` = 6 px** | 8 |
| space | **4 px** | 8 |
| styles in the file | **regular only** | regular; bold is a 1-px overprint (`sheet.asm:6853`) |

Sample widths, in pixels (Helv / 8×8): `Month` 32/40, `Sales` 34/40, `SUM(B2:B4)` 68/80,
`1234567890` 76/80, `16384` 38/40.

Three consequences follow.

- **Row height needs no change.** Helv's 14-px line is exactly SHEET's current standard row.
- **The column-width unit survives.** Excel measures a column in widths of the default font's
  `0`, and Helv's `0` is 8 px. SHEET's `SH_CW_*` character arithmetic (`sheet.asm:172-182`) and
  the SYLK `F;W` and BIFF `COLWIDTH` units keep their meaning, so **no file-format change is
  needed**.
- **Helv's digits are not tabular.** `1` and `7` are 6 px, so right-aligned numbers do not line up
  by digit, as they do in Excel's Helv. Section 6.4 gives two fixes.

## 3. What blocks it, measured

### 3.1 Claims: 8 of 8

Counted on a live machine, not from the source. SHEET was launched on MartyPC
`os8088_xt_vga` with a sheet open, and `tools/heapmap.py` was read via `heapmap.Map` over the
MartyPC connection. The result: **eight claims owned by SHEET's segment**, which are cells,
text, staging, border+note (carved, §81.94.1), chart, undo, CHART.OVL and MACRO.OVL. The
package's 60 KB region is a ninth block, owned by `inst 1`, so it **does not** count against the
cap.

> The comment at `sheet.asm:644` says the region "already counts as one of them". The
> live count says it does not. That comment is stale and should be corrected when this work
> starts.

`MEM_OWNER_MAX` is 8 (`kernel/memory.inc:57`), enforced per owner at claim time
(`kernel/memory.inc:714-727`).

What the library claims:

| Claim | Size | Taken by | Required? |
|---|---|---|---|
| face image | `TY_FACE_KB` = 8 KB, `OSAPI_MEM_CLAIM_DMA`, 512-aligned by hand (§6.4) | `ty_open` (`os88type.inc:610`) | **yes**, one per open face |
| pre-shifted glyph table | `TY_PSKB` = 12 KB (`os88type.inc:78-79`) | `ty_cache` (`os88type.inc:1001-1003`) | **no**: without it the compose runs the general loop, with identical pixels at about 2× the compose cost (§6.5.2) |
| the band | 1,472 B (`TY_BANDSZ`, `os88type.inc:64`) | **package bss**, `ty_bandbuf` | not a claim |

> SPEC §6.5.1 is titled "The band is one claim and the face is another". The library
> as built keeps the band in the including package's bss (`os88type.inc:1600`, `TY_BSS_SIZE`
> at :1643). The code is what SHEET would get. The heading is worth a follow-up in §6.5.1.

**The heap is not the constraint:** 169 KB contiguous was free with SHEET open (same
`heapmap` run). **Slots are.**

### 3.2 Resident bytes: 97 free

`build/sheet.o88`'s header: image 52,220, bss 9,123, total 61,343 of `APP_MAX_SIZE` 0xF000 =
61,440 (`apps/os88api.inc:93`). **97 bytes free.** The study measured 517 (image 51,800);
§81.101's keyboard shortcuts, built the same day, took 420 of them: the table, the dispatcher
and the pulldown captions must be resident, since the key callback and the panel drawing are.
The gaps plan's figure of 756 predates §81.99 to §81.101.

What the library costs, measured by assembling it:

| | Bytes |
|---|---|
| library code, `ty_scan` … `ty_gray.out` (mapped in `tests/facetest`) | **about 2,820** |
| library bss, `TY_BSS_SIZE` | **1,933** (band 1,472, advance table 95, 4 face slots × 16, family names, scalars) |

Neither fits. **The bss must be resident**: every `[ty_*]` cell is DS-relative, and DS is the
package. The code could move to an overlay only with changes (section 4.2).

### 3.3 The layout counts characters

SHEET lays a cell out in characters and pads with spaces:

- `sh_justify` (`sheet.asm:48871`) and `sh_justify_c` (`:48901`) right-align and centre by
  **padding `sh_tbuf` with spaces to `[sh_cellch]` characters**. With a 4-px space, that padding no
  longer places the text. There are 22 references to `sh_cellch` and 13 to `sh_justify`.
- Formula text is truncated at `[sh_cellch]` characters (`sheet.asm:6735-6740`).
- **Run-on (§81.54, §81.76):** `sh_spill` (`sheet.asm:49079`) draws each empty cell's slice of a
  long label by character offset. Proportional slicing needs pixel offsets, which `ty_fit` and
  `ty_hit` provide.
- **`####` for a number too wide** is decided in characters, in the number formatter
  (`sh_numfmt`, 5 references).
- The cell pen is `OSAPI_FONT_RUN` once per cell (`sheet.asm:6844`). Bold is a transparent 1-px
  overprint (`:6853`), and a shaded cell letters transparently over its dither (`:6838`).
- Column widths are held to multiples of 8 for `FONT_RUN`'s sake (`sheet.asm:169`).
  `OSAPI_GFX_BLIT1` also takes its x on a multiple of 8 (§5.4.2), so that rule stays.

### 3.4 The tests read 8×8 glyphs

**19 test files** read cell text off the screen through `tests/glass.py`, which matches the
kernel's 8×8 glyphs:

sheetcell, sheetfreeze, sheethide, sheetnumfmt, sheetspill, sheetrecord, sheetdb, sheetside,
sheetform, sheetsort, sheetcalc, sheetcolw, sheetdbcmd, sheetmacro, sheetjust, sheetparse,
sheetundo, sheetrowh and sheetseries.

Making Helv the **default** breaks all of them at once. A setting that defaults off breaks none,
and a Helv-aware glass reader can be built beside them. The `.F88` is data, so the host can
render the expected text from it.

## 4. Options

### 4.1 A claim slot

| Option | Frees | Cost | Verdict |
|---|---|---|---|
| **Carve chart (19 KB) and undo (16 KB) into one 35 KB claim**, §81.94.1's move | 1 slot | undo is OPTIONAL today (`sheet.asm:2027-2030`: a refused claim costs Undo, not the app). Carving it into chart's makes both succeed or fail together; `sh_reloc` must re-derive the second base; `tests/sheetmove.py` gains a case | good, and has precedent |
| **Face and table in an overlay claim's tail**, as §81.91.1 put the macro file channels in MACRO.OVL's | 0 slots needed | a library change: `ty_open` and `ty_cache` would take a caller-supplied segment instead of claiming. The face must also be DMA-safe and 512-aligned (§6.4), so that overlay claim would have to be taken with `OSAPI_MEM_CLAIM_DMA` | **best on slots**, but it touches a shared include used by five packages (word, scribe, fontview, cword and tests/facetest) |
| Drop the pre-shifted table | 1 of the 2 | compose about 2× (section 5) | acceptable as a first stage |

### 4.2 Resident room

| Option | Frees | Cost |
|---|---|---|
| **Move resident code into an overlay first.** CHART.OVL's claim is `CH_OVKB` = 46 KB (`apps/os88chartovl.inc:35`) and MACRO.OVL's `SH_M2KB` = 28 (`sheet.asm:865`); either can grow to 63 for heap bytes alone | as much as is moved | the two overlay traps (memory: module data through DS, and a near call to a resident name); `tools/os88ovlchk.py` checks both |
| **Let a package set the band's size.** `TY_STRIDE` is fixed at 92 for Hercules' 720 px (`os88type.inc:55`), but a SHEET cell is at most `SH_CW_MAXCH` × 8 = 320 px = 41 bytes, so a stride of 42 would do | about 970 of the 1,933 bss bytes | `%ifndef` guards in the include; the unrolled compose uses the stride as a displacement, so any even value works |
| **Put the library's code in an overlay.** | about 2,820 resident | three DS-relative reads of `.text` data (`os88type.inc:952` `ty_rftab`, `:461`/`:464` the folder names) need `cs:` overrides or a data move. `ty_rowfn` is a near pointer called inside the library, which is fine if the whole library is in the module. Every call from the resident draw path becomes a door |

**Arithmetic for a minimal build:**

- **Needed resident:** bss about 960 B (stride 42) + draw-path changes, *estimate* 400–700 B →
  about 1.4–1.7 KB.
- **Free:** 97 B (after §81.101).
- **Gap:** move roughly **1.3–1.9 KB** of resident code to an overlay first, or 4.2 KB if the
  library itself stays resident.

### 4.3 Where proportional applies

| Surface | Proportional? | Why |
|---|---|---|
| cell text | **yes**, the point of the work | Excel's Helv 10 |
| column letters, row numbers | **yes, stage 3** | Excel draws them in bold Helv. Drawn transparently today (`sheet.asm:6594`, `:6641`) |
| formula bar and editing | **no** | Excel 2.x edits only in the formula bar. `os88line`'s caret and hit math is fixed-pitch, and SHEET has no in-cell editing, so there is nothing to convert |
| Options ▸ Formulas on show | yes, like any cell | it is cell text |
| menus, dialogs, status bar | **no** | chrome, and the kernel's 8×8 face everywhere else in the OS |
| `kern_small` | falls back to 8×8, per row | `ty_flush` CF → `OSAPI_FONT_RUN` (§6.5); face 0 keeps the measuring on one path |

### 4.4 How the choice is made

- **A display setting**, beside Gridlines and Formulas (`docs/plans/SHEET-GAPS-PLAN.md` already
  wants those in one Options ▸ Display dialog). It is **not** per sheet and not stored in the
  file: SYLK and BIFF carry fonts of their own, and reading those is a separate project.
- **Default off** until the glass reader exists. Then the owner decides the default.

## 5. Speed

These are *estimates*, derived from PERFORMANCE.md's measured per-glyph figures, not measured
inside SHEET. One 7-character cell, on a 4.77 MHz 8088:

| Path | Per cell | Source |
|---|---|---|
| `OSAPI_FONT_RUN`, byte-aligned, CGA/Hercules | about 2.2 ms (7 × 0.312) | Set 64: 24.37 ms / 78 cells |
| `OSAPI_FONT_RUN`, VGA | about 5.3 ms (7 × 0.757) | Set 64: 59.06 ms / 78 |
| band, **pre-shifted** table | about 1.8 ms (0.395 emit + 7 × 0.204) | Set 64: 21.18 ms / 104 glyphs; blit intercept 395 µs |
| band, general compose (no table) | about 3.3 ms (0.395 + 7 × 0.41) | Set 64: 42.68 ms / 104 |

The per-call setup of `FONT_RUN` is not separated out in Set 64, so the first two rows
flatter it. Set 68 prices a comparable composed band at 860 µs a call plus 173 µs a cell, and
it beats `FONT_RUN` at every width.

**A full grid:**

| Display | Visible cells | `FONT_RUN` | Band, pre-shifted | Band, no table |
|---|---|---|---|---|
| VGA | 20 × 9 = 180 | about 950 ms | about 320 ms | about 590 ms |
| CGA | 4 × 9 = 36 | about 80 ms | about 65 ms | about 120 ms |

So proportional is **faster on VGA**, and on the mono cards it is **parity with the table and
about 1.5× without it**. Bold doubles the compose for bold cells only (section 6.3). None of this
is a reason not to do it. It is a reason to **measure it in stage 2**, with the grid-paint
harness, before anyone quotes these numbers.

## 6. Drawing a cell as a band

### 6.1 The gridline

`OSAPI_GFX_BLIT1` is opaque and its x is a multiple of 8. A cell's left edge is its gridline
column, so a band covering the cell would erase the gridline unless the band carries it. The
fix: **compose the vertical gridline into the band** by clearing bit 7 of byte 0 in each row.
Start the pen at x + 2.

This also closes the report's gap #4 (Excel insets cell text about 2 px; SHEET letters on the
gridline) at no extra cost.

### 6.2 A shaded cell

Today a shaded cell is a dither plus a transparent pass (`sheet.asm:6826-6840`). In a band, it
becomes: fill the band rows with the dither bytes, then compose the ink over them. **One
opaque emit, and one fewer transparent-text site** in `tests/textsites.txt` (§6.6.3).

### 6.3 Bold and underline

No face has a bold style. Compose the run twice, with the pen 1 px apart, inside the band. That
is the §6.6.2 case-6 overstrike, done in RAM where it needs no transparent call. Underline is
one cleared row in the band.

### 6.4 Tabular digits

Two ways to line up digits:

- **Fix the face.** Give `1` and `7` an 8-px advance in `faces/helv.t88`. It also changes Word's
  Helvetica, so it is the owner's call.
- **Fix it in SHEET.** Pad each digit to 8 px as the number is composed. That needs a small
  `ty_putn` variant, or composing a number one digit per call at a forced pen.

The second is cleaner for SHEET and touches no other package.

## 7. Recommended path

Each stage is its own SPEC §81 section and its own gate, and each one ships.

| Stage | Work | Buys | Rough cost |
|---|---|---|---|
| **0. Make room** | move ≥1.5 KB of resident code to an overlay (candidates to be measured, not guessed); add `%ifndef TY_STRIDE`/`TY_BROWS` to `os88type.inc`; carve chart+undo into one claim, freeing 1 slot; fix the stale comment at `sheet.asm:644` | a slot, resident headroom, and nothing visible | `tests/sheetmove.py` extended; `ovlchk` clean; all 48 `sheet*` suite rows unchanged |
| **1. Pixel layout, still 8×8** | re-express `sh_justify`, the formula-text truncation, `sh_spill` and `####` in **pixels**, measured through `ty_widthn` / `ty_fit` with **face 0**, the kernel's 8×8, which the library exposes on the same calls | the whole layout converted with **zero pixels changed**, which every existing glass gate proves | the risky stage, done where the tests can still see |
| **2. Helv cells, behind a setting** | `ty_openfam` Helvetica at entry (one face claim, no pre-shift table); cells drawn as bands with the gridline, shading and bold composed in; a new **Helv glass reader** that renders from `faces/helv.t88` on the host; a grid-paint timing on CGA and VGA | Excel's texture, measured | new gate(s); the table is added later if the measurement asks for it |
| **3. Headers and digits** | bold Helv row/column headers; tabular digits (section 6.4) | Excel's headers | small |
| **4. The default** | the owner's decision, with the stage-2 timing in hand | | flipping the default re-baselines the 19 glass gates to the Helv reader |

**What stays fixed-width, permanently:** the formula bar and its editor (`os88line`), every
dialog, SHEET's menu bar and pulldowns, the status bar, and anything drawn on `kern_small`.

## 8. Open questions for the owner

1. **Tabular digits:** change `faces/helv.t88` for everyone, or pad inside SHEET only?
2. **Carving undo into chart's claim** turns an optional claim into a required one. On a machine
   that cannot spare 35 KB in one piece, SHEET would then lose the chart window as well as Undo.
   Is that acceptable, or should the face go in an overlay tail instead (the library change in
   section 4.1)?
3. **Default:** proportional on for new sheets once stage 2 is measured, or an opt-in for good?
