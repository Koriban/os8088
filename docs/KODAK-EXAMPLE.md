# Kodak Q3 1982 — a worked example built inside os8088

*Staged into the tree from the original run of 26 August 2026. The files it
describes are `apps/sheet/KODAK.BIF`, `apps/scribe/KODAK.DOC`,
`apps/sheet/KODAKEX1.BMP` / `KODAKEX2.BMP` and the four `screenshots/kodak-*`
images; the 1.44MB floppy it was produced on is not tracked, because every
file on it is here.*

*`make` puts them on the **examples disk** — `build/examples.img`, and
`examples720.img`, `examples120.img` and `examples360.img` for the other
drives (`make examplesdisk` builds just those). All six files are in `MEDIA/`,
the folder the Open dialog starts in: this set, and the Xerox Q3 1982 set
beside it (`XEROXQ3.SLK` for Sheet, `XEROXQ3.RTF` for Scribe). They are on no
apps disk, so opening one is a disk swap, and the two applications take it
differently:*

- ***Sheet** (`KODAK.BIF`, `XEROXQ3.SLK`): launch it from the apps disk, swap
  the examples disk into B:, File ▸ Open. Its file formats live in
  `CHART.OVL`, which Sheet reads at start-up, so the swap costs nothing.*
- ***Scribe** (`KODAK.DOC`, `XEROXQ3.RTF`): open any document from Scribe's own
  disk FIRST, then swap. Scribe reads `SCRIBE.OVL` - where its file formats
  live - at the first file operation, from the disk it was launched from
  (SPEC.md 94.8); a cold Scribe asked to open a file off the examples disk
  looks for the module there and says it is missing. Once loaded it stays for
  the session. A hard-disk install has neither problem.*

Every byte here was produced **in the emulator, by hand**, driving SHEET.O88,
CHART.O88 and WORD.O88 through the mouse and keyboard. Nothing was written on
the host and copied in. It exists as an end-to-end exercise of the three
packages and the paths between them.

The premise: an internal management report for Eastman Kodak, dated
**23 October 1982** — a plausible date for a third-quarter review, and the year
the disc camera shipped.

This is the **second** build of it. The first was made on 26 August 2026 against
an earlier tree; this one was rebuilt from scratch after error values, the
chart's decimal exponent and BIFF function tokens landed, and it says below what
changed as a result — including the bug the rebuild found.

## What is here

| file | what it is |
|---|---|
| `kodak-disk.img` | the 1.44MB floppy it was produced on. Not tracked here - every file on it is, and `make` builds the examples disk from them |
| `KODAK.DOC` | the report, written in Word. A real Word-format `.DOC` |
| `KODAK.BIF` | the figures, saved from Sheet as a **BIFF4 workbook** — three sheets in one file |
| `KODAKEX1.BMP` / `KODAKEX2.BMP` | the two exhibits, exported from Sheet's chart window. 240x160, 4bpp, as written by the app |
| 
| `word-report.png` | the finished report on screen in Word |
| `sheet-segment-table.png` | the segment table in Sheet, formulas computing |
| `chart-exhibit1.png` / `chart-exhibit2.png` | the charts in Sheet's chart window, before export |

## The documents

**Sheet 1** — Q3 segment sales, $ millions, 1982 against 1981. `Change` is
`=C2-B2`, `Pct` is `=ROUND(D2/B2*100,1)`, and the total row is `=SUM(...)`
down each column. 2,645 -> 2,765, +120, +4.5%. Column A was widened to 12
characters through Format > Column Width so the segment names fit — which
turned out to matter, see below.

**Sheet 2** — the same three segments without the total row, so the exhibit
charts the segments rather than a total bar that dwarfs them. This is worth
knowing when building your own: **a summary row inside the charted column is
charted with the data.**

**Sheet 3** — disc camera shipments, **millions of units**, July to September:
1.42, 1.86, 2.15. Deliberately fractional, because that is what the charts
could not previously carry.

**KODAK.DOC** — the narrative, referring to both exhibits, with the letterhead
and the two section headings bolded from the toolbar. os8088 cannot print yet,
so the exhibits are exported as BMPs on the assumption they would be printed
and attached; Word does not embed them.

## What this run demonstrates that the first one could not

**Every formula travels as a formula.** The first build of this example had to
say that `=SUM(...)` and `=ROUND(...)` were written out as cached *values*,
because the BIFF writer would not emit a token for a function call. They are
real `FORMULA` records now — `SUM` as `42 01 0400` (tFuncVar, 1 argument,
function 4) and `ROUND` as `41 1b00` (tFunc, function 27) — so the workbook is
a spreadsheet in the file and not only on the screen. `=C2-B2` was already one:
`44 01c002  44 01c001  04`.

**The chart carries the decimals.** Exhibit 2's scale reads **2.15**. On the
earlier build the same column charted as bars of 1, 1 and 2 under a scale that
said `2`, because everything the chart touched was a signed 16-bit integer. The
series now carries a decimal exponent (SPEC.md §82.13) and only the labels need
to know about it.

**Both RK and NUMBER appear in one file.** Sheets 1 and 2 are exact small
integers and go out as `RK`, byte-identical to what this app has always
written; sheet 3's 1.42 cannot be, so it goes out as `NUMBER` — an IEEE-754
double, verbatim.

## The bug this rebuild found

Widening column A to 12 characters is the obvious thing to do when
`Photographic` does not fit. Doing it, and then charting, **stopped the whole
machine** — not the app, the machine — and left the chart window showing
uninitialised memory.

`sh_blank` is the row of spaces a blank cell paints as. It was **11 bytes**:
the widest of the three column-width *presets* it was written for, plus a NUL.
The numeric Column Width dialog that replaced those presets accepts 1..40, and
nothing resized the buffer. A width of 12 writes 13 bytes, and the two that
fall off the end land on the next word in the bss chain — `sh_chartseg`, the
segment of the chart canvas. The next chart then cleared 19,200 bytes through a
poisoned segment.

It was **pre-existing** and nothing to do with the chart work that had just
landed, which is exactly what made it hard: the symptom pointed at the code
that had most recently changed. Charting from a bare column, from a labelled
column, from a second sheet, and after a BIFF save all came back clean; the
column width typed several minutes earlier was what was left. Fixed in
`sheet: a column 11 characters wide killed the machine`, SPEC.md §81.21.

## Reproducing it

```sh
make run RUNAPPS=build/apps.img
```

Then open `KODAK.DOC` (double-click it — Word claims `.DOC`), or `KODAK.BIF`
(Sheet claims `.SLK`, `.DIF` and `.BIF`), or either `.BMP` (Paint claims those).
