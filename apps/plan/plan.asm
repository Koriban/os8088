; =============================================================================
; os8088 - apps/plan/plan.asm
;
; PLAN - a spreadsheet for the machines SHEET cannot reach. Prefix pl_.
;
; WHAT IT IS FOR. SPEC.md 24.5.2 leaves SHEET off the 128KB machine's disk on
; a ground that is a REQUIREMENT and not a size: its region is 48,352 bytes
; and what it claims on open is close to 100KB, which is more RAM than that
; machine has in total. The test 24.5.2 sets is "is there a state of this
; machine in which this package runs", and for SHEET the answer is no at
; every setting. PLAN is the answer that is yes.
;
; THE BUDGET, and every cut below is priced against it. kern_small's free
; arena on a 128KB machine is 52.5 KB = 53,760 bytes (11.102). A package's
; footprint is its REGION PLUS THE CLAIMS IT MAKES TO FUNCTION - 24.5.2's own
; closing line, and the thing the old 70KB target got wrong by measuring only
; the first. So:
;
;     region (image + bss)  +  cells + text + staging   <=  ~51,700
;
; leaving 2KB for the Disk window you launched it from. The claims grow with
; OSAPI_MEM_REGROW rather than being sized for the worst document, which is
; 93's own shape (dd_fit_claim) and is what lets PLAN START on a machine that
; could not hold the sheet it might eventually be asked to hold.
;
; PROVENANCE. This file began as apps/sheet/sheet.asm with -DPLAN resolved -
; 81.75's feature flags taken to their PLAN arm and the SHEET arm deleted -
; and the split was proved rather than reviewed: both resolved files assembled
; BYTE-IDENTICAL to what the one gated source produced for each arm. It
; carried sheet.asm's `sh_` prefix for exactly one commit, so that the rename
; to `pl_` could be proved the same way: 8,038 identifiers, not one byte of
; the image moved.
;
; WHAT DEFENDS AGAINST DRIFT, now that a diff cannot. The two packages share a
; CONTRACT without sharing the code that implements it - the SYLK and CSV
; formats, and what a formula means - which is the exact shape that goes
; wrong quietly (fs.c and file.c agreed for months, and agreeing was not
; enough). A name-level diff was the cheap defence and the rename spends it.
; What has to replace it is a FORMAT GATE: tools/os88sheetfmt.py is an
; independent reader and writer of both formats, so a fixture IT authors,
; opened and re-saved by each package, catches a divergence that a
; writer-then-reader round trip inside one package cannot - because there the
; two defects cancel. 81.75's own test list owes that row.
;
; WHAT WAS ALREADY CUT to get here, all of it in 81.75's Tier 1: charts and
; the whole overlay mechanism with them, BIFF/DIF/dBASE and the RPN encoder,
; the database family and the Data menu, the macro language and its recorder,
; Sort, the array/matrix family, CELL, the financial family, the
; transcendentals and the text functions. What SHEET keeps and this must not:
; see the cut list in SPEC.md 81.75.
;
; STORAGE. The cell array is sparse - an array of records sorted by (row,col)
; and binary-searched - living in a heap claim rather than in bss, for the
; reason sheet.asm's own header gives at length: a dense 256x2048 bitmap
; would not fit the package's whole budget before a single value was stored.
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'PLAN', pl_entry, 3    ; 81.75. A package NAME is a literal
                                        ; bit 0 = icon, bit 1 = the
                                        ; association block below

; --- embedded 16x16 icon: a blank page with a 3x3 grid on it -------------------
    OS88_ICON16
    dw 0x0000                       ; 16 mask rows (white underlay)
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x7FFE
    dw 0x0000
    dw 0x0000
    dw 0x0000                       ; 16 data rows (black pixels)
    dw 0x0000
    dw 0x3FFC                       ; top border
    dw 0x2224                       ; sides + two internal verticals
    dw 0x2224
    dw 0x2224
    dw 0x3FFC                       ; internal horizontal divider
    dw 0x2224
    dw 0x2224
    dw 0x2224
    dw 0x3FFC                       ; internal horizontal divider
    dw 0x2224
    dw 0x2224
    dw 0x3FFC                       ; bottom border
    dw 0x0000
    dw 0x0000
    OS88_ICON16_END

; The three sheet formats this app reads and writes, claimed so a document
; opens on a DOUBLE-CLICK rather than only through File > Open (SPEC.md 54.6).
; Declaring costs nothing at runtime - the mount's icon harvest already reads
; this sector - and it works before Sheet has ever been run, which a runtime
; OSAPI_ASSOC_SET claim does not.
;
; CHART.O88 reads the same three formats and deliberately does NOT claim them:
; there is no ownership model (54.5), so a second declaration would simply
; take the extension, and a spreadsheet file belongs to the spreadsheet. Chart
; opens one through its own File > Open.
;
; PLAN claims the two it can actually open (81.75): SYLK, and the CSV that
; every other program on this machine can also write. Declaring .DIF or .BIF
; there would be a package offering to open a file it has no reader for.
    OS88_ASSOC16
    db 2
    OS88_ASSOC_EXT 'SLK'
    OS88_ASSOC_EXT 'CSV'
    OS88_ASSOC16_END

; =============================================================================
; Geometry / grid / storage constants
; =============================================================================
PL_COLS      equ 256                ; the roadmap's stage 1.2 ceiling
; 81.75: 256 x 1024, AND THE TWO NUMBERS THIS FILE KEEPS APART.
;
; PL_COLS x PL_ROWS is THE ADDRESSABLE RANGE - which cell references exist and
; how far the view can scroll. It costs NOTHING, because storage is sparse:
; the cell array is records of (row, col, value), so what a grid costs is the
; cells that are OCCUPIED, never the ones that could be. 2048 rows and 1024
; rows assemble to BYTE-IDENTICAL images; that was measured, not assumed.
;
; HOW MANY CELLS MAY BE OCCUPIED AT ONCE is a different number entirely, and
; it is the one that is tight: PL_CELL_CAP, which is the cells CLAIM divided
; by PL_C_SZ. Do not read one as the other.
;
; PL_ROW_BITS stays 14. The packed key has room for 16384 either way and
; narrowing it would be a second change with no second benefit.
PL_ROWS      equ 1024
; stage 2.x: Format > Column Width.../Row Height... make these RUNTIME
; values (pl_cellw/pl_cellh/pl_cellch bss words) rather than compile-time
; constants. Stage 3.0c made both dialogs real numeric entry (pl_idlg_*, over
; os88line.inc); 81.56 gave each column its own width and 81.60 each row its
; own height, so the two words now mean THE CELL BEING DRAWN, and these are
; the standard width and height. Widths
; must stay multiples of 8 - pl_blank and every OSAPI_FONT_RUN cell text
; is built one glyph (8px) at a time, so a non-multiple would leave a
; fractional glyph column with nothing sensible to draw there.
PL_CW_NORMAL equ 56                 ; 7 chars - the original fixed default
PL_RH_NORMAL equ 14                 ; the original fixed default
; stage 3.0c: the bounds real numeric entry has to enforce, now that Row
; Height.../Column Width... take a typed number instead of a 3-way radio.
; Width is in CHARACTERS (Excel's own unit); height is in pixels.
PL_CW_MINCH  equ 1
PL_NUMBUF_MAX equ 40                ; stage 4.5: pl_numbuf's usable length,
                                    ; which is PL_CW_MAXCH because a label is
                                    ; clipped to its column and nothing wider
                                    ; can ever reach a justifier
PL_CW_MAXCH  equ 40                 ; 320px - wider than the window, but the
                                    ; renderer clips and the user asked
PL_RH_MIN    equ 8                  ; one glyph cell: below this no text fits
PL_RH_MAX    equ 48
; 81.60: EACH ROW ITS OWN HEIGHT, kept - as Excel keeps it and BIFF writes it -
; in TWIPS, a twentieth of a point, and drawn at PL_RH_NORMAL pixels for the
; standard 12.75 points: px = (tw * 14 + 127) / 255. The dialog takes points.
; The bounds are the twips that round to PL_RH_MIN and PL_RH_MAX pixels
PL_RH_STDTW  equ 255                ; the standard height, 12.75 points
PL_RH_TWMIN  equ 146                ; 7.3 points -> 8 px
PL_RH_TWMAX  equ 874                ; 43.7 points -> 48 px
PL_MAXVR     equ 64                 ; visible rows at most: 480px / PL_RH_MIN
PL_RH_W      equ 32                 ; row-header column: 81.75's 1024 rows are
                                    ; four digits, not five, so the grid gets
                                    ; the eighth column of it back
PL_CH_H      equ 14
PL_FB_H      equ 16
PL_REF_W     equ 64                 ; stage 2.x: the formula bar's own
                                     ; reference box width - wide enough
                                     ; for the longest possible reference
                                     ; text (a 2-letter column + a 5-digit
                                     ; row, PL_COLS=256/PL_ROWS=16384's own
                                     ; worst case) plus a little padding
; Mirrors of os88ui.inc's own scroll-bar constants. Duplicated here for the
; same reason the CH_* chart constants are (see their comment below): that file
; is %included at the END of this one, so its equs are FORWARD references, and
; a forward-referenced value used as an IMMEDIATE makes NASM size the
; instruction differently on each pass - `cmp cx, imm8` vs `cmp cx, imm16` -
; which fails the assembly outright with "label changed during code
; generation". Values must track os88ui.inc's; they are part of the block
; contract pl_hsb_* is written to be promoted into.
PL_SB_NONE   equ 0
PL_SB_UP     equ 1                  ; the LEFT arrow on a horizontal bar
PL_SB_DOWN   equ 2                  ; ...and the RIGHT one
PL_SB_PGUP   equ 3
PL_SB_PGDN   equ 4
PL_SB_THUMB  equ 5
PL_SB_MINH   equ 8                  ; the shortest thumb that is still a thumb
PL_SB_CELL   equ 10                 ; the arrow cell's depth

PL_VSB_W     equ 14                 ; stage 3.0a+: the vertical scroll bar's
                                     ; width. 14 is what both kernel callers
                                     ; use and what os88ui.inc's arrow glyph
                                     ; is drawn for (5 rows, widths 1..9)
PL_HSB_H     equ 14                 ; ...and the horizontal bar's height, the
                                     ; same cell so the two agree at the
                                     ; corner where they meet
PL_SB_H      equ 16                 ; stage 2.x: the status bar strip at
                                     ; the very bottom of the window,
                                     ; same height as the formula bar for
                                     ; visual symmetry
PL_EDITMAX   equ 63                 ; room for a formula, not just a number
PL_NAME_MAX  equ 12                  ; characters an IDENTIFIER may run to in a
                                     ; formula - a function name, and once a
                                     ; defined name. The names went; the
                                     ; parser's cap on what it will collect
                                     ; stayed, since it sizes pl_ident
PL_NAMEMAX   equ 12                  ; characters in an 8.3 FILE name - the
                                     ; same number, a different thing
PL_RW_CAP    equ 80                  ; stage 2.x: pl_formula_reidx's own
                                     ; output cap - a shifted reference can
                                     ; grow by a digit or two (row 9->10,
                                     ; col Z->AA), so a little more than
                                     ; PL_EDITMAX+1

; 81.75's CLAIM LADDER. §24.5.2 is why SHEET is not on the 128KB machine:
; 32KB of cells alone is nearly twice the largest single run that machine can
; hand out (§50.6.2), and a package that merely wants heap can refuse itself
; in its own words - which is a refusal, not a spreadsheet. Every figure below
; is sized from what a BUDGET holds rather than from what a sheet could.
PL_CLAIM_CELLS_KB equ 5             ; 320 records of 16 bytes (81.75)
PL_CLAIM_TXT_KB   equ 1             ; formula text only: no notes here
PL_CLAIM_STG_KB   equ 8             ; file I/O staging. NOT the 2KB the plan
                                    ; first wrote: the readers take a whole
                                    ; file into this buffer in one
                                    ; OSAPI_FILE_READ, so it is the DOCUMENT
                                    ; size and not a streaming window, and a
                                    ; 409-cell SYLK is about 15KB. What Sort's
                                    ; going buys is the 32KB its own layout
                                    ; forced (offsets to 30,720), not the
                                    ; buffer itself
; pl_docmd_sortcol's own layout within pl_stgseg (stage 2.x: formula cells
; now participate in the sort too, so alongside the original rows[]/
; values[] arrays it also needs a source-index permutation, an
; is-this-a-formula flag, and staged formula text for each one - see the
; section comment above pl_docmd_sortcol for the full design)
; STAGE 4.5 RELAID THIS OUT because values[] had to grow. It was a WORD per
; entry - the truncated integer - which was right while every cell held one and
; became silently wrong the moment cells held doubles: 1.2, 1.5 and 1.9 all
; truncate to 1, so a column of decimals sorted into whatever order the
; insertion sort's stability happened to leave them in. Nothing reported it,
; because a sorted-looking column IS what you get.
;
; Entries are capped at PL_SORT_CAP now as well. There was no cap before, and
; nothing stopped a long column walking off the end of one array into the next.
PL_MENU_CHK       equ 2              ; a leading byte meaning "checked", the
                                     ; companion to the kernel's MENU_DIS
PL_SORT_CAP       equ 512            ; entries one sort can carry
PL_SORT_ROWS_OFF  equ 0              ; word/entry
PL_SORT_VALS_OFF  equ 1024           ; EIGHT bytes/entry: a whole double
PL_SORT_ORIG_OFF  equ 5120           ; word/entry: origidx[] (which
                                     ; pre-sort entry ended up here)
PL_SORT_ISF_OFF   equ 6144           ; byte/entry: 1 if that entry is a
                                     ; formula cell
PL_SORT_FIDX_OFF  equ 6656           ; word/entry: which PL_SORT_FTXT_OFF
                                     ; slot holds that formula's own text
                                     ; (only meaningful when ISF is set)
PL_SORT_FTXT_OFF  equ 7680           ; PL_SORT_FCAP slots of 64 bytes each,
                                     ; ending at 7680+180*64=19200, safely
                                     ; inside the 32KB claim
PL_SORT_FCAP      equ 180           ; max formula cells one sort can carry
PL_SORT_SNAP_OFF  equ 19200          ; PL_SORT_SNAPCAP slots of 64 bytes: ONE
                                     ; other column's cells as text, while the
                                     ; permutation is applied to it. It starts
                                     ; where the formula slots end (7680 +
                                     ; 180*64) and fits inside PL_STAGE_MAX
PL_SORT_CLS_OFF   equ 30720          ; byte/entry, by ORIGINAL index (81.61):
                                     ; 0 number, 1 text, 2 logical, 3 error -
                                     ; Excel's ascending order of the four.
                                     ; A text entry's eight value bytes hold
                                     ; the offset of its text, staged in a
                                     ; SNAP slot, which nothing else uses
                                     ; until the carry, after the write-back
PL_SORT_SNAPCAP   equ 180            ; rows a multi-column sort can carry
                                     ; through - far more than any real
                                     ; column needs; a cell beyond this cap
                                     ; is simply excluded from the sort
                                     ; entirely (same "clip, don't crash"
                                     ; policy used throughout this file)
PL_CHART_S2  equ 512                ; where a chart's SECOND series lands in
                                    ; pl_stgseg - the first sits at 0 and needs
                                    ; CH_MAXBARS words, so 512 is clear of it
                                    ; with room to spare
PL_CHART_D1  equ 1024               ; stage 4.6: and where the DOUBLES the scan
PL_CHART_D2  equ 1536               ; collects sit, before ch_scale turns them
                                    ; into the two word arrays above. Same 512
                                    ; spacing; CH_MAXBARS doubles is 320
PL_CLAIM_UNDO_KB  equ 6             ; 81.75: 256 records plus the widths, and
PL_CLAIM_CHART_KB equ 19            ; stage 2.x: the live Chart Column window's
                                     ; offscreen 4bpp canvas - 240x160px, 120
                                     ; bytes/row (already a multiple of 4, so
                                     ; the BMP export below needs no row
                                     ; padding logic) = 19200 bytes -> 19KB.
                                     ; This is Sheet's 5th claim (own region +
                                     ; cellseg/txtseg/stgseg/bordseg), so 6/8
                                     ; of MEM_OWNER_MAX WHEN THIS WAS WRITTEN.
                                     ; The note table and CHART.OVL took the
                                     ; last two: it is 8/8 now (81.2).
                                     ; No pixel-readback API exists anywhere in
                                     ; this OS (checked every OSAPI_GFX_*), so
                                     ; this buffer - not the screen - is the
                                     ; one thing both the on-screen chart (one
                                     ; OSAPI_GFX_BLIT4 of it) and the exported
                                     ; .BMP (one OSAPI_FILE_WRITE of it, same
                                     ; bytes) are drawn from.
; =============================================================================
; THE CELL RECORD (stage 4.0). Every offset below is named, and every stride
; goes through PL_C_SZ, because this layout has now moved once and the plan's
; own risk list puts "a missed stride site" first: it reads a MISALIGNED
; record and hands back a plausible wrong number, with no crash to notice.
; Naming them makes the next move a four-line edit instead of an 87-site
; audit.
;
; +0 and +2 and +4 and +5 are shared in shape with the border and note tables
; (pl_bt_* / pl_nt_*), which is why those four are deliberately NOT renamed
; here - a rename would have had to reach into two other tables to stay
; honest, and they have their own strides.
; =============================================================================
PL_C_ROW     equ 0                  ; word: packed row | sheet
PL_C_COL     equ 2                  ; word
PL_C_FLAGS   equ 4                  ; byte: bit0 HASFORMULA, bit1 EVALUATING
PL_C_FMT     equ 5                  ; byte: PL_FMT_*, and the BIFF XF index
PL_C_TYPE    equ 6                  ; byte: PL_T_* - reserved by stage 4.0's
PL_C_AUX     equ 7                  ; byte: ...error code, likewise reserved.
                                    ; THE TAG IS ITS OWN BYTE AND NOT SPARE
                                    ; BITS OF PL_C_FMT: that byte's numeric
                                    ; value IS the XF index the BIFF writer
                                    ; emits, so borrowing bits 6-7 would
                                    ; silently change every XF in every file
                                    ; this app has ever written.
PL_C_VAL     equ 8                  ; 4 bytes: a signed count of HUNDREDTHS
                                    ; (81.75, apps/os88fix.inc). It was an
                                    ; IEEE-754 double and those four bytes are
                                    ; the expensive half of the switch: the
                                    ; record times the cells claim is how many
                                    ; cells the sheet can hold at all, so 20
                                    ; bytes becoming 16 is a quarter more
                                    ; cells for the same kilobyte.
PL_C_FOFF    equ 12                 ; word: formula text offset in pl_txtseg
PL_C_PASS    equ 14                 ; word: the repaint pass that cached VAL
; The value tags stage 4.0 reserves. Numbered so that BLANK is 0 and a
; zeroed record is therefore a blank one.
PL_SSTK_N    equ 6                   ; string-stack levels. The text
                                     ; functions bank one argument each, so six
                                     ; is several frames deep; past that a
                                     ; formula gets #VALUE! rather than a
                                     ; quietly overwritten argument
PL_STR_MAX   equ 64                 ; stage 4.5: the string accumulator's
                                    ; usable length, and the size of a text
                                    ; formula's result slot (81.22). A cell
                                    ; shows PL_CW_MAXCH=40 at most, so this is
                                    ; headroom for an intermediate concat
PL_T_BLANK   equ 0
PL_T_NUM     equ 1
PL_T_TEXT    equ 2
PL_T_BOOL    equ 3
PL_T_ERR     equ 4

; Error codes, in PL_C_AUX. These are EXCEL'S OWN ERROR.TYPE numbers, so
; ERROR.TYPE and ISERR become a table lookup if they are ever added.
;
; THE BIFF BOOLERR RECORD DOES NOT USE THIS NUMBERING. That claim stood here
; for a long time and cost a wrong byte in every error cell SHEET ever
; exported - the format has its own codes and pl_biff_e2b/pl_biff_b2e convert
; between them.
PL_ERR_NULL  equ 1                  ; #NULL!
PL_ERR_DIV0  equ 2                  ; #DIV/0!   - the only one produced today
PL_ERR_VALUE equ 3                  ; #VALUE!
PL_PS_ALL    equ 0                  ; Edit Paste Special's five, in the order
PL_PS_FORM   equ 1                  ; the dialog lists them
PL_PS_VAL    equ 2
PL_PS_FMT    equ 3
PL_PS_NOTE   equ 4
PL_PS_LINK   equ 5                  ; ...and Paste Link, which has no dialog
PL_ERR_REF   equ 4                  ; #REF!
PL_ERR_NAME  equ 5                  ; #NAME?
PL_ERR_NUM   equ 6                  ; #NUM!
PL_ERR_NA    equ 7                  ; #N/A

PL_C_SZ      equ 16                 ; ...and an EVEN stride, so the array
                                    ; shuffle can move words rather than bytes

; pl_rowcol_op stages every record through pl_stgseg while it shifts a row or
; column. It is a transient copy, not storage - but it CARRIES the whole
; cell across the shift, so it had to grow with the cell record: the value
; at stage 4.0, the type tag and error code at stage 4.5. Named for exactly
; the reason above: the two layouts look alike and one was silently edited
; into the other.
PL_S_SHEET   equ 0
PL_S_ROW     equ 2
PL_S_COL     equ 4
PL_S_FLAGS   equ 6
PL_S_FMT     equ 7
PL_S_VAL     equ 8                  ; 8 bytes since stage 4.0: this record
                                    ; CARRIES a cell's value across a row or
                                    ; column shift, so it had to grow with the
                                    ; cell record or every decimal in the
                                    ; sheet would have been truncated to the
                                    ; low half of its own double - silently,
                                    ; on an Insert Row
PL_S_FML     equ 16
PL_S_TYPE    equ 18                 ; byte: PL_C_TYPE, carried for the same
PL_S_AUX     equ 19                 ; byte: ...reason - pl_addcell retags a
                                    ; fresh record PL_T_NUM, so a label whose
                                    ; tag was not carried came back a number.
                                    ; Free bytes: PL_S_SZ was already 20, so
                                    ; 18..19 existed before anything used them
PL_S_SZ      equ 20                 ; ...and the code says PL_S_SZ where it
                                    ; means this, so changing it is a change
                                    ; to ONE layout and not silently to both

PL_CELL_CAP  equ 320                ; floor(PL_CLAIM_CELLS_KB*1024 / PL_C_SZ)
PL_TXT_CAP   equ 1024               ; PL_CLAIM_TXT_KB in bytes
PL_STAGE_MAX equ 8192
PL_BT_SZ     equ 6                  ; the border table's record (81.55): row,
                                    ; col, the border+protection byte, and
                                    ; the number format beyond the four the
                                    ; format byte can name. It was 5
PL_BORD_CAP  equ 682                ; floor(4096 / PL_BT_SZ) - 819 at 5
PL_NOTE_REC  equ 6                  ; stage 3.0b: the note table's record -
                                    ; packed row/sheet, col, and the note
                                    ; text's offset in the SHARED formula
                                    ; arena (see pl_nt_findcell's header)
PL_NOTE_CAP  equ 512                ; 682 - floor(4096 / PL_NOTE_REC) - until
                                    ; 81.56 took the claim's top kilobyte:
PL_COLW_OFF  equ PL_NOTE_CAP * PL_NOTE_REC ; 3072: the COLUMN WIDTHS, 256
                                    ; bytes a sheet (pl_colwidth). A new claim
                                    ; would have been SHEET's eighth and last,
                                    ; and bss the headroom's third; notes are
                                    ; the least-used table there is
PL_ROWH_OFF  equ PL_COLW_OFF + 1024 ; 4096: the ROW HEIGHTS (81.60), a sorted
                                    ; sparse table - packed row/sheet word,
                                    ; twips word - of the rows that are not
                                    ; the standard height. Paragraph-aligned,
                                    ; so pl_rc_table can walk it at offset 0
PL_ROWH_CAP  equ 255                ; records; the count is the KB's last word
PL_ROWH_N    equ PL_ROWH_OFF + 1022
PL_ROWH_REC  equ 4
PL_MAXVC     equ 80                 ; visible columns at most: 640px / 8
PL_NOTEMAX   equ 240                ; the longest note the dialog will take,
                                    ; INCLUDING its NUL - 6 lines of 39 in the
                                    ; box below, which is what fits
; CH_* is the offscreen-chart-canvas geometry apps/os88chart.inc's own
; routines (ch_bars_draw/ch_bmp_write, %included near the end of this
; file) are written against. These equ lines are duplicated verbatim in
; apps/chart/chart.asm rather than shared - NASM's equ can't be forward-
; referenced, and os88chart.inc's CODE has to live at the end of the file
; (same fixed-offset reason os88ui.inc's own header states), so anything
; used by code earlier than that has to already exist. Same idea as
; os88api.inc itself being "code-free on purpose" so it can sit at the top
; - these are the constant half of that split, just declared per-package
; instead of in a %include, since equ lines are too early-needed to live
; where the shared CODE has to live.
; -----------------------------------------------------------------------------
; CHMOD - call one of the module's entry points.
;
; The whole point of the %define: `CHMOD draw` is a near call to ch_draw when
; the module is resident and a verb through the dispatcher when it is not, so
; SHEET can be built BOTH WAYS from one source. That is not a nicety - it is
; the only way to tell an overlay-wiring bug apart from a drawing bug, and it
; was written after an afternoon spent unable to.
;
; CF=1 means the module could not be loaded, which the resident build cannot
; produce - so `clc` there, and every caller's error path is dead code rather
; than wrong code.
; -----------------------------------------------------------------------------

; The verb numbers again, keyed by the ROUTINE's own name, so one macro
; argument serves both builds: `ch_%1` is the near call, `CHM_%1` the verb.
%define CHM_draw      0
%define CHM_scale     1
%define CHM_bmp_write 2


%macro CHMOD 1
    call ch_%1
    clc
%endmacro

CH_W       equ 240
CH_H       equ 160
CH_STRIDE  equ 120                  ; CH_W / 2 (4bpp, 2px/byte)
CH_HDRSZ   equ 118                  ; 54-byte BMP header + 64-byte palette
CH_PXOFF   equ CH_HDRSZ             ; pixel data starts right after
CH_MAXBARS equ 40                   ; how many values the caller's arrays
                                     ; hold - NOT a drawing limit: ch_band
                                     ; divides the axis among however many
                                     ; there are, so any count up to this one
                                     ; fits the canvas
CH_T_COLUMN equ 0                   ; stage 3.0f: the gallery. Excel calls the
CH_T_BAR    equ 1                   ; vertical one Column and the horizontal
CH_T_LINE   equ 2                   ; one Bar, and this follows that naming
CH_T_AREA   equ 3                   ; rather than the intuitive-but-wrong one
CH_T_PIE    equ 4                   ; stage 3.0f, and the last of the four
CH_T_SCATTER equ 5                  ; ...and stage 3.0f's own last two, which
CH_T_COMBO   equ 6                  ; needed a SECOND series (SPEC.md 82.8)
                                    ; Excel types this app can draw: Scatter
                                    ; and Combination need TWO series, which
                                    ; is a data-model problem rather than a
                                    ; drawing one
PL_CHARTWIN_W equ 260                ; a little margin around the CH_W x
PL_CHARTWIN_H equ 200                ; CH_H canvas - real size comes back
                                      ; from OSAPI_WM_CONTENT either way
PL_EVAL_MAXDEPTH equ 6               ; a formula referencing a formula
                                      ; referencing a formula...; each level
                                      ; gets its own text buffer (below) so a
                                      ; nested evaluation cannot overwrite
                                      ; the text an outer one is still
                                      ; parsing. Beyond this many levels a
                                      ; reference just reads as 0 - the same
                                      ; honest simplification as every other
                                      ; unbounded case here.
PL_PNEST_MAX equ 12                  ; the parser's own nesting budget (81.3):
                                      ; live recursion points plus cell depth,
                                      ; charged by pl_pnest_enter. 12 is what
                                      ; the deepest PL_EVAL_MAXDEPTH chain of
                                      ; folds needs (one call + one depth per
                                      ; level); each level holds tens of bytes
                                      ; of task 0's 512-byte stack, so the
                                      ; cap is sized to that stack, not to the
                                      ; grammar

; --- stage 1.6: per-cell text formatting -----------------------------------
; Packed into the cell record's byte at +5 (previously unused padding, see
; the record layout comment above pl_findcell): bit0 bold, bit1 underline,
; bits3-2 alignment, bits5-4 number format. Bits6-7 are unused. This exact
; 6-bit space is also, not coincidentally, this app's BIFF XF index on disk
; (pl_dowrite_biff) - see the comment there for why that pairing is safe.
PL_FMT_BOLD          equ 0x01
PL_FMT_UNDER         equ 0x02
PL_FMT_BU_CLR        equ 0xFC        ; ~(PL_FMT_BOLD|PL_FMT_UNDER) & 0xFF -
                                      ; stage 1.8's Font dialog clears bits
                                      ; 0-1 in one mask, not two XORs
PL_FMT_ALIGN_MASK    equ 0x0C
PL_FMT_ALIGN_CLR     equ 0xF3        ; ~PL_FMT_ALIGN_MASK & 0xFF
PL_FMT_ALIGN_SHIFT   equ 2
PL_FMT_ALIGN_GENERAL equ 0           ; General: right, same as this app's
                                      ; only-ever-numeric default
PL_FMT_ALIGN_LEFT    equ 1
PL_FMT_ALIGN_CENTER  equ 2
PL_FMT_ALIGN_RIGHT   equ 3
PL_FMT_NUM_MASK      equ 0x30
PL_FMT_NUM_CLR       equ 0xCF        ; ~PL_FMT_NUM_MASK & 0xFF
PL_FMT_NUM_SHIFT     equ 4
PL_FMT_NUM_GENERAL   equ 0
PL_FMT_NUM_CURRENCY  equ 1
PL_FMT_NUM_COMMA     equ 2
PL_FMT_NUM_PERCENT   equ 3

; --- stage 2.x: cell borders (Format > Border..., its own pl_bordseg claim
; and pl_bt_* table - see the PL_CLAIM_BORD_KB comment above for why this
; isn't just more bits in the format byte) ----------------------------------
PL_BORD_LEFT   equ 0x01
PL_BORD_RIGHT  equ 0x02
PL_BORD_TOP    equ 0x04
PL_BORD_BOTTOM equ 0x08
PL_BORD_SHADE  equ 0x10
PL_BORD_EDGES  equ 0x0F             ; Left|Right|Top|Bottom together
; --- cell protection (81.46) lives in the SPARE BITS OF THE SAME BYTE ------
; The border byte uses bits 0-4 and every reader of it tests single bits or
; masks with 0x1F, so bits 5-7 were free. Protection goes there rather than
; into PL_C_FLAGS - which also has spare bits - because several sites write
; that byte as a WORD together with the format and one clears it outright
; when a formula becomes a value, so a bit there would survive some edits and
; not others.
;
; THE SENSE IS INVERTED ON PURPOSE. Excel's default is Locked and not Hidden,
; and this table's whole convention is "no record = the default" - a cell gets
; a record when it acquires a border and loses it again when the last bit
; clears. Storing "Locked" would make the absence of a record mean UNlocked,
; which is the opposite of Excel and the opposite of safe. Storing UNLOCKED
; means an untouched sheet is entirely locked, exactly as a new Excel sheet is.
PL_PROT_UNLOCK equ 0x20             ; bit 5: this cell is NOT locked
PL_PROT_HIDDEN equ 0x40             ; bit 6: hide its formula when protected
PL_PROT_MASK   equ 0x60             ; the two together, for preserving them

; pl_doread_biff's FONT/XF tracking tables (a real file might reference more
; than this app itself ever writes - beyond the cap, a cell just reads back
; as unformatted rather than growing these tables without bound)
PL_BIFF_FONT_CAP equ 32
PL_BIFF_XF_CAP   equ 128
PL_B2_XF         equ PL_BIFF_XF_CAP - 1 ; the slot a BIFF2 cell's own
                                        ; attributes are decoded into (81.52)            ; 64 was exactly the format-byte space,
                                    ; and 81.47 writes XFs past it for the
                                    ; cells that also carry a border
PL_XFP_CAP       equ 64             ; distinct (format, border) pairs one file
                                    ; may carry. Past this a bordered cell
                                    ; keeps its format and loses its border -
                                    ; never someone else's XF

; --- stage 2.0: multiple sheets in one instance ----------------------------
; No OS8088 mechanism lets one running instance find or address another's
; memory (there is no window-enumeration or IPC primitive at all - see the
; claim/task model in SPEC.md 29/50.2), and every app including this one is
; strictly one-instance-one-document. Real Excel's separate-file-per-sheet
; model is therefore not implementable without inventing new OS capability,
; so "sheets" here are multiple grids living inside this ONE instance's
; existing three claims, distinguished by a sheet index folded into the
; cell record's own row field rather than by claiming more segments (the
; kernel caps any one owner at MEM_OWNER_MAX=8 claims, and this package's
; region already counts as one of them - three fresh claims per extra sheet
; would run out fast). PL_ROWS needs exactly 14 bits (0..16383), leaving
; exactly 2 spare bits in that word for a sheet index - hence exactly
; PL_SHEETS=4, not a rounder number chosen for its own sake.
PL_SHEETS    equ 1                   ; 81.75: one grid, so the packed key's
                                     ; two sheet bits are always zero
PL_ROW_BITS  equ 14                  ; row occupies bits 0-13
PL_ROW_MASK  equ 0x3FFF

; --- stage 2.x: Sheet's own in-window menu bar -----------------------------
; MENU_APPMAX is five (apps/os88api.inc) and real Excel 2.1's bar is eight
; real menus (File/Edit/Format/Data/Options/Macro/Help, plus this app's own
; Sheets switcher, which has no real-Excel equivalent since Excel used
; separate windows per sheet rather than one packed instance - see the
; stage 2.0 comment above). Word.O88 hit the exact same ceiling and answered
; it the same way (see apps/word/word.asm's "Word chrome" section, SPEC.md
; 68.2): draw the bar and its dropdowns IN THE WINDOW instead of asking the
; kernel for one, and register only the kernel's minimum single-item
; placeholder (pl_mf_ret below) so the bar still gets an app-name pulldown.
; Word's own version adds a ribbon, a ruler, combos and a sliding-panel edge
; case none of which Sheet needs - this is a deliberately smaller subset of
; the same mechanism: plain titles, plain dropdowns, one interaction style
; (press-drag-release, matching what every OS88_MENUSET app - including
; Sheet's own menus before this stage - already trained users on).
;
; The gesture itself is Word's wd_mtrack pattern, not W_ONDRAG: a tight
; OSAPI_MOUSE poll with a gfx-unlock/yield/relock between reads (SPEC.md
; 13.7 forbids mixing W_ONDRAG with a polling loop in the same app, and
; W_ONDRAG/W_ONTIMER are missing entirely on one of the two kernel variants
; anyway - see the earlier note on why range selection was scoped out).
; This works on both kernel variants because it never touches the optional
; drag/timer slots at all.
PL_MBAR_H    equ 14                  ; the in-window menu bar strip
PL_MI_H      equ 12                  ; a dropdown item's row height
PL_MPAD      equ 8                   ; left/right pixel pad per title/item
PL_MCHKX     equ 2                   ; SPEC.md 81.30: the check mark, a solid
PL_MCHKY     equ 4                   ; square centred in the 8px check column
PL_MCHKS     equ 5                   ; and on the row's 8px glyph line
PL_MCHKW     equ 8                   ; stage 3.0c: the DROPDOWN's extra left
                                     ; gutter, where a checked item's mark
                                     ; goes. Not folded into PL_MPAD because
                                     ; that one also sets the spacing of the
                                     ; BAR's own titles, which have no marks
                                     ; and would just drift apart
; File,Edit,Formula,Format,Data,Options,Macro,Sheets,Help - Excel 2.1d's own
; bar order (see pl_mtab). NOTE PL_MENU_N also sizes pl_mw in the bss chain,
; so changing it moves OS88_BSS too.
;
; 81.75: A MENU'S INDEX IS NAMED rather than written as a number, because
; PLAN's bar is shorter - no Macro, no Sheets - and every index above a
; missing menu moves down one. pl_mfire's dispatch chain is the only thing
; that reads these, and it used bare 0..8; the names assemble to the identical
; bytes in SHEET's arm, which is what makes this restructure free. THE ORDER
; HERE IS THE BAR'S ORDER and pl_mtab below must agree line for line.
;
; THE DATA MENU IS DERIVED, not declared, because it is the only one whose
; CONTENTS decide whether it exists: Excel's six database items, Sort and
; Series, and this app's own three chart items. Take all of them and there
; is no menu left to open, so SHF_DATAMENU is the OR of what is left and
; PL_DATA_N is how many - one number, used by pl_mtab, by pl_i_data's own
; list and by nothing else.

PL_MI_FILE    equ 0
PL_MI_EDIT    equ 1
PL_MI_FORMAT  equ 2
PL_MI_OPTIONS equ 3
PL_MENU_N     equ PL_MI_OPTIONS + 1
; The five that are not on this bar, each a value AH can never hold so that
; its own arm in pl_mfire is unreachable rather than absent (81.75).
PL_MI_FORMULA equ 0xFB                ; Goto went; Reference moved to Options
PL_MI_SHEET   equ 0xFC
PL_MI_DATA    equ 0xFD
PL_MI_MACRO   equ 0xFE
PL_MI_HELP    equ 0xFA                ; the About card went with it
PL_M_NONE    equ 0xFF

; =============================================================================
; pl_reloc - THE HEAP COMPACTOR MOVED ONE OF OUR CLAIMS (SPEC.md 66.2)
; in:  BX = the base segment it WAS at, DX = the base it is at NOW.
;      DS = CS = ours, ES = KERNEL_SEG. The bytes have already moved.
; out: nothing; every register preserved
;
; SHEET WAS THE LARGEST UNDECLARED HOLDER IN THE TREE - six unconditional
; claims taken at the entry proc, ~99KB, pinned for the whole session
; (docs/plans/HEAP-UNPIN-PLAN.md 2.1.1 item 2). SPEC.md 66.5.10.2's closing
; line - "the arena below the top now has no barrier in it at all" - was true
; of the configuration it was measured on and false the moment a sheet opened.
;
; WHY IT IS A TABLE AND NOT A LADDER OF COMPARES. It is smaller at five
; entries and it does the one thing a ladder gets wrong: it patches EVERY word
; that names the old base rather than the first, because ch_srcseg and its
; siblings below are second copies of a segment this package also holds
; directly - and SPEC.md 66.1 is the record of a design that failed on exactly
; that, "the pair that killed the word-poke design".
;
; PL_STGSEG IS NOT IN THE TABLE AND IS NOT DECLARED. It is the ES:BX of every
; one of this package's seven OSAPI_FILE_READ/WRITE calls (SPEC.md 66.9 reason
; 4), and a file call claims, so a compaction inside one would move the buffer
; out from under a transfer the kernel has already been given the address of.
; SPEC.md 66.5.7.1's pin/unpin pair is what it would take; 67KB of the 99 move
; without it.
;
; Everything else in this package is an OFFSET into one of these segments -
; a cell record, a formula's text, a note - so nothing else needs fixing.
; =============================================================================
pl_reloc:
    push cx
    push si
    push di
    mov si, pl_segw
    mov cx, PL_NSEGW
.l:
    mov di, [si]                      ; DI = the address of a word that might
    cmp bx, [di]                      ; name the block that moved
    jne .next
    mov [di], dx
.next:
    add si, 2
    loop .l
    pop di
    pop si
    pop cx
    ret

; The words that name a movable claim. The first five are the claims
; themselves; the last three are os88chart.inc's borrowed copies, taken inside
; ch_bars_draw/ch_bmp_write and dead between calls - they cost two bytes each
; and they close the one window where a chart export could be holding a stale
; segment across the OSAPI_FILE_WRITE in the middle of it.
pl_segw:
    dw pl_cellseg, pl_txtseg
    dw pl_undoseg
PL_NSEGW equ 3                       ; 81.75: cells, text and undo. No chart

; =============================================================================
; pl_entry - package entry point (SPEC.md 20.2). Claims run here, and only
; here (SPEC.md 50.3): this is the one place a package has no window yet
; and is sizing itself. A claim failure aborts the launch (CF=1) rather
; than opening a sheet that cannot hold anything - the kernel tears down
; whatever we did claim either way (no teardown hook owed).
; =============================================================================

; =============================================================================
; THE MODULE'S OFFSET 0 (82.16.8). `ch_ovcall` far-calls (0, the claim), so
; whatever NASM lays down first in `.modc` is the dispatcher whether it meant
; to be or not - and fragments are laid down in SOURCE ORDER. SHEET's own
; module code sits 9,000 lines above the os88chart.inc include, so without
; this it would land at offset 0 and the chart verbs would jump into the
; middle of a BIFF writer.
;
; Three bytes fix it without moving a line of code: claim offset 0 here,
; before anything else can, and jump to the real dispatcher wherever it ends
; up. Both are inside the module, so it is an ordinary near jump.
; =============================================================================

; -----------------------------------------------------------------------------
; SHOUT - the module's calls back into the package (82.16.9).
;
; Resident, that is a near call like any other. In the module it cannot be:
; 68.10 keeps DS on the package but moves CS, so every route back is a FAR call
; through a vector the package fills in at start-up. One macro so the two
; builds cannot drift - the same argument CHFP makes for the chart module.
; -----------------------------------------------------------------------------
%macro SHOUT 1
    call %1
%endmacro

  %define PL_MODSEC .text            ; every `section PL_MODSEC` below is this
; =============================================================================
; 81.75: NO MODULE, SO NO DISPATCH. sheet.asm reaches its overlay through
; forty `mov bp, <verb>` doors, a verb table and a far-call dispatcher; PLAN
; has nothing on the other side of any of it, so the doors are plain jumps
; and the table, the verb numbers, ch_ovcall and the pl_m_* wrappers that
; turned each near body into a far return are all gone. The CALL SITES are
; untouched - every one of them still says `call pl_fdlg_open_r`.
; =============================================================================
section .text

; -----------------------------------------------------------------------------
; The three resident stubs. Every existing caller still says `call pl_doread`
; and never learns the reader moved - which is the point of doing it this way
; round rather than editing the call sites (82.16.9).
; -----------------------------------------------------------------------------
pl_doread:
    call plm_doread
    jmp pl_undo_drop                   ; another document now (81.57)
pl_dowrite:
    call pl_recalc_all                  ; every formula CURRENT before any
    jmp plm_dowrite                     ; writer reads one

; -----------------------------------------------------------------------------
; pl_recalc_all - evaluate every formula cell on every sheet, as its own sheet
; (SPEC.md 81.48).
; Preserves all registers.
;
; EVALUATION IS LAZY: pl_eval_cell runs when a cell is READ, and a repaint only
; reads what is on the glass. The SYLK and BIFF writers read a cell's value
; with pl_cellval_to_acc_si, the STORED double, and never ask for a fresh one -
; so a formula scrolled out of sight since it was loaded, or since a cell it
; names changed, was written with whatever it last held. After a load that is
; the zero pl_setformula leaves, and BIFF's reader keeps the result and not the
; tokens, so a Save in Normal format turned an off-screen formula into a
; permanent 0. DIF and the text formats read through pl_getcell2, which
; evaluates, which is why it looked like a SYLK/BIFF quirk rather than a hole.
; Found by tests/sheetfin.py: the first four formulas - the ones on screen -
; came back right and all twenty-two below them came back 0.
;
; NOTHING HERE DECIDES WHAT IS STALE. pl_eval_cell's pass stamp already does,
; and does the right thing in both modes: automatic advances pl_pass on every
; repaint, so anything not recomputed since is stale and recomputes; manual
; does not, so only a cell never computed at all (stamped 0xFFFF) runs - which
; keeps manual mode meaning what it says.
;
; THE SHEET IS IMPERSONATED per record, pl_rowcol_op's idiom: pl_findcell packs
; [pl_cursheet] into every reference, so a Sheet 2 formula evaluated as Sheet 1
; would read Sheet 1's cells.
; -----------------------------------------------------------------------------
pl_recalc_all:
    push ax
    push cx
    push dx
    push di
    push es
    push word [pl_cursheet]
    xor di, di
    mov cx, [pl_ncells]
    jcxz .done
.l:
    mov es, [pl_cellseg]                ; re-read each time: the claim is
    test byte [es:di+PL_C_FLAGS], 1     ; movable (66.2) and a word is what
    jz .next                            ; pl_reloc keeps right, not ES
    mov ax, [es:di+PL_C_ROW]
    rol ax, 1                           ; the sheet is the row word's top two
    rol ax, 1                           ; bits
    and ax, 3
    mov [pl_cursheet], ax
    push cx                             ; the parser under pl_eval_cell is
    call pl_eval_cell                   ; free with CX and DX; DI and ES it
    pop cx                              ; keeps
.next:
    add di, PL_C_SZ
    loop .l
.done:
    pop word [pl_cursheet]
    pop es
    pop di
    pop dx
    pop cx
    pop ax
    ret
pl_difbbox:
    jmp plm_difbbox

; pl_pfin - the financial family's door (82.16.10). The body is plm_pfin in
; CHART.OVL; its contract is unchanged - AX the id, SI just past '(', the answer
; in pl_acc, SI past ')', AX 0, BX CX DX DI kept.
;
; THE ONE STUB HERE THAT HAS TO ANSWER A REFUSAL ITSELF. The other three hand
; ch_ovcall's CF to callers that already test it; this one's caller is the
; formula parser, which expects the arguments consumed and a value in pl_acc,
; and would otherwise carry on parsing from inside the argument list. So no
; module answers exactly what the family's own refusals do: zero, #VALUE!
; (47), and the arguments stepped over.
; 81.62: THE TEXT, TRANSCENDENTAL AND INFORMATION FAMILIES came through the
; same door, each with its own verb: the functions a sheet uses least, 2.8 KB
; the package needed more than the module did. SUM and its folds, IF, the
; special forms, the lookups, the dates and NOW stay resident.

pl_entry:
    push ax
    push dx
    push si
    push di
    call fx_init                      ; before the first claim, because every
                                      ; other thing here can fail and be
                                      ; recovered from and this one decides
                                      ; which arithmetic the session gets
    mov ax, PL_CLAIM_CELLS_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [pl_cellseg], dx
    mov ax, pl_reloc                     ; ...and MOVABLE (SPEC.md 66.2). SHEET
                                      ; has NO WORKER, so mem_can_move
                                      ; passes these on I_TASK = 0xFF
                                      ; alone and no park is involved
    call OSAPI_MEM_MOVABLE
    mov ax, PL_CLAIM_TXT_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [pl_txtseg], dx
    mov ax, pl_reloc
    call OSAPI_MEM_MOVABLE
    mov ax, PL_CLAIM_STG_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [pl_stgseg], dx
    mov ax, PL_CLAIM_UNDO_KB           ; Undo's, last and optional (81.57): a
    call OSAPI_MEM_CLAIM               ; heap that cannot spare it costs Undo,
    jc .noundo                         ; not the app
    mov [pl_undoseg], dx
    mov ax, pl_reloc
    call OSAPI_MEM_MOVABLE
.noundo:
    ; THE REGION ITSELF IS NOT DECLARED MOVABLE IN THIS TREE, and that is the
    ; one place this proc departs from upstream's (SPEC.md 66.6.1). Upstream's
    ; case for it is that SHEET "stores its own segment nowhere", which is
    ; true of a package with no overlay and false of this one twice over:
    ;
    ;  - ch_ovbind stamps CS into CHART.OVL's vector table, and every SHOUT
    ;    reaches back through a far pointer holding it. A moved image leaves
    ;    all of them naming the old one.
    ;  - the module makes ELEVEN file calls (every format's reader and
    ;    writer, 82.16.9), each while this package's far return address is on
    ;    the stack - and a file call claims, so it can compact. The module's
    ;    retf would pop a segment the kernel has no record of.
    ;
    ; The data claims above DO move: every file transfer stages through
    ; pl_stgseg, which is pinned, and every copy of a movable segment is
    ; either in pl_segw or dead across no compaction point. The image and
    ; CHART.OVL are what stay put.
    mov word [pl_ncells], 0
    mov word [pl_txtlen], 0
    mov si, pl_tpl
    call OSAPI_WM_CREATE
    jc .fail
    mov [pl_ownwin], bx               ; stage 2.0: os88ui_ask needs our own
                                       ; window ptr, and it's asked for from
                                       ; the macro engine, which has no window
                                       ; ptr of its own to hand it - Sheet
                                       ; only ever has the one window, so
                                       ; capturing it once here is safe
    mov byte [pl_mopen], PL_M_NONE    ; stage 2.x: Sheet's own menu bar -
    mov byte [pl_mhi], PL_M_NONE      ; see the PL_MBAR_H section comment
    mov byte [pl_gridlines], 1
    mov byte [pl_showformulas], 0
    mov word [pl_i_options], pl_it_grid_on   ; match pl_i_options's own
                                              ; label to the actual default
                                              ; (pl_it_form_off already does,
                                              ; since Formulas defaults off)
    mov word [pl_cellw], PL_CW_NORMAL        ; stage 2.x: runtime cell size
    mov word [pl_cellh], PL_RH_NORMAL        ; defaults - see the PL_CW_*/
    mov word [pl_cellch], PL_CW_NORMAL / 8   ; PL_RH_* section comment
    mov word [pl_defch], PL_CW_NORMAL / 8    ; 81.56: the STANDARD width - a
                                             ; column's own is in the table,
                                             ; and pl_cellch/pl_cellw are the
                                             ; column being drawn
    call pl_mkblank
    call pl_mtab_calc

    ; 81.75: NO DRAG AT ALL. W_ONDRAG and W_ONMOUSEUP are exactly what
    ; kern_small refuses (kernel.asm's own OSAPI_WM_ONDRAG arm answers CF=1
    ; and carries the slot without the body), so on the machine this package
    ; exists for every byte of drag-to-select, thumb dragging and
    ; heading-resize was code that could never execute. Shift+click and
    ; shift+arrows build a range and need no kernel support at all; a scroll
    ; bar's arrows and its page areas still work, and only the thumb has
    ; stopped being draggable.

    ; stage 3.0b: the formula bar's content box. Only the buffer binding is
    ; set once - the rect is refreshed per draw by pl_flrect, since the window
    ; moves and resizes and a stale rect would draw and hit-test in the wrong
    ; place.
    mov word [pl_fline + LN_BUF], pl_editbuf
    mov word [pl_fline + LN_MAX], PL_EDITMAX + 1

    ; Arm the key-state map now rather than on the user's first shift+click.
    ; kbd_down arms itself on the first ASK and its first answer is always
    ; "up" (kernel/mouse.inc's own note), so without this the very first
    ; shift+click of a session would read as an unshifted one.
    mov al, 0x2A
    call OSAPI_KEY_DOWN

    mov si, pl_menus
    call OSAPI_MENU_SET
    ; 81.75: NO ABOUT CARD. OSAPI_ABOUT_SET takes 0 for "none" and is simply
    ; not called, which is the slot's own sanctioned state rather than the
    ; 12.2 defect of putting the same text in a Help menu of one's own - that
    ; menu is gone too. What it costs is that PLAN carries no attribution
    ; anywhere a user can reach.
    mov si, pl_defname
    mov di, pl_name
    call pl_strcpy
    call pl_note_arg                  ; a document double-clicked in the Disk
                                       ; window. NOTED here, READ at the first
                                       ; paint - see pl_note_arg's header
    clc
    jmp .out
.fail:
    stc
.out:
    pop di
    pop si
    pop dx
    pop ax
    ret

; =============================================================================
; Geometry
; =============================================================================

; -----------------------------------------------------------------------------
; pl_geom - in: BX = window ptr
; out: [pl_ox]/[pl_oy] content origin, [pl_cw]/[pl_ch] content size,
;      [pl_vcols]/[pl_vrows] grid cells that fit given the current scroll;
;      all registers preserved
; -----------------------------------------------------------------------------
pl_geom:
    push ax
    push cx
    push dx
    call OSAPI_WM_CONTENT
    mov [pl_ox], ax
    mov [pl_oy], dx
    add dx, PL_MBAR_H                  ; pl_goy: where the formula bar and
    mov [pl_goy], dx                   ; everything below it actually starts,
                                        ; now that the menu bar (PL_MBAR_H
                                        ; section comment) sits above them -
                                        ; pl_oy itself stays the RAW content
                                        ; origin, since pl_mbar_draw needs
                                        ; that one, not the shifted one
    call OSAPI_WM_GEOM
    mov [pl_cw], cx
    mov [pl_ch], dx

    mov ax, cx
    sub ax, PL_RH_W + PL_VSB_W         ; the vertical bar owns a strip at the
    jns .cw_ok                          ; right, so the grid is that much
    xor ax, ax                          ; narrower
.cw_ok:
    mov [pl_gridw], ax                  ; what pl_scrollto_t fits a column in
    ; EACH COLUMN ITS OWN WIDTH (81.56): walked from the scroll position until
    ; the next would not fit whole, and kept in pl_vcw for everything that
    ; places a column - pl_vcx is the only arithmetic that turns a visible
    ; column into pixels. It was one division by the one width.
    ;
    ; 81.75: no frozen panes, so there is one phase and not two - but the
    ; slot cursor is still not the real-column cursor, because a HIDDEN
    ; column is walked and takes no slot.
    push bx
    push di
    mov dx, ax                          ; DX = the pixels left
    xor di, di                          ; DI = the SLOTS filled so far
    mov ax, [pl_scrollcol]
    mov [pl_geom_rc], ax
.fcwalk:
    mov ax, [pl_geom_rc]
.cwalk:
    cmp di, PL_MAXVC
    jae .cset
    mov ax, [pl_geom_rc]
    cmp ax, PL_COLS
    jae .cset
    call pl_geom_col
    jc .cwalk
.cset:
    mov [pl_vcols], di
    pop di
    pop bx

    mov ax, [pl_ch]
    sub ax, PL_MBAR_H + PL_FB_H + PL_CH_H + PL_SB_H + PL_HSB_H
    jns .chh_ok                         ; ...and the horizontal bar a strip
    xor ax, ax                          ; above the status bar
.chh_ok:
    mov [pl_gridh], ax
    ; 81.75: every row is PL_RH_NORMAL and none can be hidden, so what 81.60
    ; and 81.73 needed a streaming walk over a sparse table for is arithmetic
    ; again. pl_vrr is still FILLED rather than dropped: pl_vclip_row and
    ; pl_vreal_row read it, and the COLUMNS still need their own table beside
    ; it, so one shape for both is cheaper than two.
    push bx
    push di
    mov dx, ax                          ; DX = the pixels left
    xor di, di                          ; DI = the rows so far
    mov ax, [pl_scrollrow]
    mov [pl_geom_rr], ax
.rwalk:
    cmp di, PL_MAXVR
    jae .rset
    mov ax, [pl_geom_rr]
    cmp ax, PL_ROWS
    jae .rset
    call pl_geom_row
    jc .rwalk
.rset:
    mov [pl_vrows], di
    pop di
    pop bx

    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_geom_col / pl_geom_row - ONE column (or row) of pl_geom's walk (81.73).
;
; in:  [pl_geom_rc]/[pl_geom_rr] = the real index to consider, DI = the next
;      free slot, DX = the pixels left; for rows, ES:SI/CX/BX are the row
;      height table's streaming cursor exactly as the walk left them.
; out: the cursor advanced, and CF=1 to carry on / CF=0 when this one did not
;      fit and the walk is finished. DI and DX updated in place.
;
; A HIDDEN index takes no slot and no pixels and does not end the walk, which
; is the whole of what hiding is here - every other reader sees a viewport
; that simply does not contain it.
; -----------------------------------------------------------------------------
pl_geom_col:
    push bx
    mov ax, [pl_geom_rc]
    inc word [pl_geom_rc]
    call pl_colwidth                   ; 0 = hidden
    or ax, ax
    jz .skip
    mov [pl_vcw + di], al
    mov cl, 3
    shl ax, cl
    cmp ax, dx
    ja .full
    sub dx, ax
    mov bx, di
    shl bx, 1
    mov ax, [pl_geom_rc]
    dec ax
    mov [pl_vrc + bx], ax              ; slot DI shows THIS real column
    inc di
.skip:
    pop bx
    stc
    ret
.full:
    pop bx
    clc
    ret

pl_geom_row:
    mov ax, PL_RH_NORMAL
    cmp ax, dx
    ja .full
    sub dx, ax
    mov [pl_vrh + di], al
    push bx
    mov bx, di
    shl bx, 1
    mov ax, [pl_geom_rr]
    mov [pl_vrr + bx], ax              ; slot DI shows THIS real row
    pop bx
    inc word [pl_geom_rr]
    inc di
    stc
    ret
.full:
    clc
    ret

; -----------------------------------------------------------------------------
; COLUMN WIDTHS (81.56, and 81.75 moved them). 256 bytes, each a column's
; width in CHARACTERS - Excel's own unit - with 0 meaning the standard width
; pl_defch and 255 meaning HIDDEN. They used to live in the top kilobyte of
; the note claim, four sheets' worth; with notes gone and one sheet left it is
; 256 bytes of this package's OWN bss, which costs the region a quarter of a
; kilobyte and gives the heap five back.
; -----------------------------------------------------------------------------
PL_CW_HIDDEN equ 255

; pl_colwidth - in: AX = a column; out: AX = its width in characters, and ZERO
; when it is hidden - which is what makes pl_geom skip it without a second
; question (81.73)
pl_colwidth:
    push bx
    mov bx, ax
    mov al, [pl_colwtab + bx]
    xor ah, ah
    cmp al, PL_CW_HIDDEN               ; 81.73: hidden is no width at all
    je .hidden
    or al, al
    jnz .out
    mov ax, [pl_defch]
    jmp short .out
.hidden:
    xor ax, ax
.out:
    pop bx
    ret

; pl_colw_set - in: AX = a column, CL = its width in characters (0 standard)
pl_colw_set:
    push bx
    mov bx, ax
    mov [pl_colwtab + bx], cl
    pop bx
    ret

; pl_colw_clear - every column the standard width
pl_colw_clear:
    push ax
    push cx
    push di
    push es
    push ds
    pop es
    mov di, pl_colwtab
    mov cx, 256
    xor al, al
    cld
    rep stosb
    pop es
    pop di
    pop cx
    pop ax
    ret

; pl_colw_shift - AL = 2 inserts a column at BX, 3 deletes the one at BX: the
; widths after it move with their columns, as the cells do. An inserted
; column is the standard width.
pl_colw_shift:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    push ds
    pop es
    mov cx, 255
    sub cx, bx
    jbe .out
    mov di, pl_colwtab
    add di, bx
    cmp al, 3
    je .del
    cmp al, 2
    jne .out
    push di                           ; insert: [c..254] -> [c+1..255]
    add di, cx
    mov si, di
    dec si
    std
    rep movsb
    cld
    pop di
    mov byte [di], 0
    jmp short .out
.del:
    mov si, di                        ; delete: [c+1..255] -> [c..254]
    inc si
    cld
    rep movsb
    mov byte [es:di], 0               ; the last column comes back standard
.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ROW GEOMETRY (81.75). Every row is PL_RH_NORMAL pixels.
;
; 81.60 made a row's height a per-row TWIPS figure kept in a sorted sparse
; table, and 81.73 let a row be hidden; between them the visible-row mapping
; stopped being arithmetic and became a walk over pl_vrh. Neither survives
; here - a budget's rows are all the same height - so the three routines below
; are arithmetic again, and the table, its dialog, the twips conversions and
; the whole of pl_rc_sides/pl_rc_table (which existed to move the border, note
; and height records with their cells) go with them.
; -----------------------------------------------------------------------------

; pl_vry - in: AX = a visible row (0..pl_vrows); out: AX = its top edge, in
; pixels from the grid's
pl_vry:
    push dx
    mov dx, PL_RH_NORMAL
    mul dx
    pop dx
    ret

; pl_vheight - in: AX = a visible row; out: AX = its height in pixels
pl_vheight:
    mov ax, PL_RH_NORMAL
    ret

; pl_vtoff - in: AX = a visible row; out: how far below its top the text
; starts, which with one height for every row is nothing
pl_vtoff:
    xor ax, ax
    ret

pl_vcx:
    push bx
    push cx
    mov cx, ax
    xor ax, ax
    xor bx, bx
.l:
    jcxz .d
    add al, [pl_vcw + bx]
    adc ah, 0
    inc bx
    dec cx
    jmp short .l
.d:
    mov cl, 3
    shl ax, cl
    pop cx
    pop bx
    ret

; pl_vwidth - in: AX = a visible column; out: AX = its width in pixels
pl_vwidth:
    push bx
    mov bx, ax
    mov al, [pl_vcw + bx]
    xor ah, ah
    push cx
    mov cl, 3
    shl ax, cl
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; FREEZE PANES (81.70). A visible column/row index (0..pl_vcols/vrows-1) no
; longer means [pl_scrollcol/row + index] once pl_freezecol/row is nonzero:
; pl_geom lays pl_vcw/pl_vrh out as the frozen prefix (real columns/rows
; 0..freeze-1, always shown) followed by the scrolling suffix (real
; pl_scrollcol/row and up). pl_vreal_col/row is that mapping; pl_vclip_col/
; row is its inverse for clamping a REAL range (a selection, a damage rect)
; into visible-index space the way pl_updsel/pl_drawsel already needed to
; before freeze existed, just freeze-aware now.
; -----------------------------------------------------------------------------

; pl_vreal_col - in: AX = a visible column (0..pl_vcols-1); out: AX = the
; real column it shows.
;
; 81.73 made this a TABLE READ. It was arithmetic - the frozen prefix's index
; is its own real column, and past it the scrolling suffix picks up at
; pl_scrollcol - and a HIDDEN column ends that: the slots no longer march in
; step with the columns, so pl_geom records which real one each slot got and
; everything reads it back from here. It is the smaller routine of the two.
pl_vreal_col:
    push bx
    mov bx, ax
    shl bx, 1
    mov ax, [pl_vrc + bx]
    pop bx
    ret

; pl_vreal_row - the same, for rows
pl_vreal_row:
    push bx
    mov bx, ax
    shl bx, 1
    mov ax, [pl_vrr + bx]
    pop bx
    ret

; pl_vclip_col - in: AX = real c1, BX = real c2 (c1 <= c2). out: CF=1, AX =
; visible c1 (rounded UP into view), BX = visible c2 (rounded DOWN into
; view); CF=0 if the whole [c1,c2] is off-screen. A column short of
; pl_freezecol is always visible, at its own index; pl_updsel/pl_drawsel
; used to do this inline with a bare [pl_scrollcol] subtraction - this is
; that clamp, freeze-aware, factored out because now two axes' worth of
; caller need the identical shape
; -----------------------------------------------------------------------------
; pl_vclip - in: AX = lo, BX = hi (REAL indices, lo <= hi), SI = the slot
; table, CX = how many slots it holds. out: AX = the first slot whose real
; index lies in [lo,hi], BX = the last; CF=0 when no slot does.
;
; 81.73 made this a SCAN. Before hidden rows and columns it was arithmetic
; with each edge clamped, and it cannot be any more - the visible slots no
; longer march in step with the real indices. The scan is over at most
; PL_MAXVC = 80 entries and runs on a selection move, not per cell.
;
; A range that is ENTIRELY hidden answers CF=0, which is the right answer and
; the same one an off-screen range gives: there is nothing to draw either way.
; -----------------------------------------------------------------------------
pl_vclip:
    push dx
    push di
    mov [pl_vcl_lo], ax
    mov [pl_vcl_hi], bx
    mov word [pl_vcl_a], 0xFFFF
    xor di, di
.l:
    cmp di, cx
    jae .done
    mov bx, di
    shl bx, 1
    mov dx, [si + bx]
    cmp dx, [pl_vcl_lo]
    jb .next
    cmp dx, [pl_vcl_hi]
    ja .next
    cmp word [pl_vcl_a], 0xFFFF
    jne .setb
    mov [pl_vcl_a], di
.setb:
    mov [pl_vcl_b], di
.next:
    inc di
    jmp short .l
.done:
    cmp word [pl_vcl_a], 0xFFFF
    je .no
    mov ax, [pl_vcl_a]
    mov bx, [pl_vcl_b]
    pop di
    pop dx
    stc
    ret
.no:
    pop di
    pop dx
    clc
    ret

; pl_vclip_col / pl_vclip_row - in: AX = real c1/r1, BX = real c2/r2. out: the
; visible range, CF=0 when none of it shows
pl_vclip_col:
    push cx
    push si
    mov si, pl_vrc
    mov cx, [pl_vcols]
    call pl_vclip
    pop si
    pop cx
    ret

pl_vclip_row:
    push cx
    push si
    mov si, pl_vrr
    mov cx, [pl_vrows]
    call pl_vclip
    pop si
    pop cx
    ret

; pl_vreal_col - pl_vclip_col clamps a RANGE into view, this answers whether
; one already-real column (the border table's own stored key, in
; pl_drawborders' sparse walk) is showing at all
pl_vidx_col:
    push bx
    push cx
    xor bx, bx
    mov cx, [pl_vcols]
.l:
    jcxz .no
    cmp [pl_vrc + bx], ax
    je .yes
    add bx, 2
    dec cx
    jmp short .l
.yes:
    shr bx, 1
    mov ax, bx
    pop cx
    pop bx
    stc
    ret
.no:
    pop cx
    pop bx
    clc
    ret

; pl_vidx_row - the same, for rows
pl_vidx_row:
    push bx
    push cx
    xor bx, bx
    mov cx, [pl_vrows]
.l:
    jcxz .no
    cmp [pl_vrr + bx], ax
    je .yes
    add bx, 2
    dec cx
    jmp short .l
.yes:
    shr bx, 1
    mov ax, bx
    pop cx
    pop bx
    stc
    ret
.no:
    pop cx
    pop bx
    clc
    ret

; =============================================================================
; EDIT > UNDO (81.57). Excel 2.1's: ONE level, the last cell entry or the last
; command of the Edit menu or Data Sort, and Undo then offers Redo. What it
; cannot reverse - formats, names, notes, macros, a new document - ends it.
;
; A SNAPSHOT, not a log of changes: the cell array, the border table, the note
; table, the column widths and row heights, and the text arena's LENGTH - it is
; append-only, so cutting it back is all it takes to undo what was added to
; it. Taken into Undo's own claim (PL_CLAIM_UNDO_KB) before the command runs;
; a document too big for it cannot be undone ("Can't Undo"), the honest
; answer. Undo SWAPS the two, through the staging claim, so Redo is the same
; operation again.
;
; Layout in pl_undoseg, and in staging during a swap: PL_UD_HDR bytes of
; header - ncells, nbord, nnote, txtlen - then the three arrays and the 2048
; bytes of widths and row heights (the height table carries its own count).
; =============================================================================
PL_UD_HDR    equ 8
PL_UL_ENTRY  equ 0                     ; the labels, pl_ud_names' order
PL_UL_CUT    equ 1
PL_UL_PASTE  equ 2
PL_UL_CLEAR  equ 3
PL_UL_PSPEC  equ 4
PL_UL_PLINK  equ 5
PL_UL_DEL    equ 6
PL_UL_INS    equ 7
PL_UL_FILLR  equ 8
PL_UL_FILLD  equ 9
PL_UL_SORT   equ 10
PL_UL_KEEP   equ 0xFE                  ; pl_ud_kind: changes nothing Undo holds
PL_UL_DROP   equ 0xFF                  ; ...or changes what it cannot reverse
pl_ud_names:  dw pl_ud_n0, pl_ud_n1, pl_ud_n2, pl_ud_n3, pl_ud_n4, pl_ud_n5
              dw pl_ud_n6, pl_ud_n7, pl_ud_n8, pl_ud_n9, pl_ud_n10
pl_ud_n0:     db 'Entry', 0
pl_ud_n1:     db 'Cut', 0
pl_ud_n2:     db 'Paste', 0
pl_ud_n3:     db 'Clear', 0
pl_ud_n4:     db 'Paste Special', 0
pl_ud_n5:     db 'Paste Link', 0
pl_ud_n6:     db 'Delete', 0
pl_ud_n7:     db 'Insert', 0
pl_ud_n8:     db 'Fill Right', 0
pl_ud_n9:     db 'Fill Down', 0
pl_ud_n10:    db 'Sort', 0
pl_ud_sundo:  db 'Undo ', 0
pl_ud_sredo:  db 'Redo ', 0
pl_ud_cant:   db MENU_DIS, "Can't Undo", 0
; pl_fdlg_apply's kinds: Number Align Font Insert Delete ColW RowH Clear New
; Calc Sort Gallery SaveFmt PasteSpecial Protection
pl_ud_kind:   db PL_UL_DROP, PL_UL_DROP, PL_UL_DROP, PL_UL_INS, PL_UL_DEL
              db PL_UL_DROP, PL_UL_DROP, PL_UL_CLEAR, PL_UL_DROP, PL_UL_KEEP
              db PL_UL_SORT, PL_UL_KEEP, PL_UL_KEEP, PL_UL_PSPEC, PL_UL_DROP
              db PL_UL_DROP, PL_UL_DROP    ; 81.71: Extract WRITES cells, and
                                             ; 81.72's Series does too
                                             ; the Reference Guide says Undo
                                             ; cannot reverse it - so DROP,
                                             ; which is Undo saying so
pl_ud_kind_end:                        ; one entry per pl_fdlg kind: asserted
                                       ; beside PL_FDK_N, which is defined later

; pl_undo_begin - AL = the label. Snapshot the document into Undo's claim and
; mark the command in progress, so pl_commit does not take one of its own
pl_undo_begin:
    push ax
    push dx
    mov byte [pl_ud_busy], 1
    mov [pl_ud_lab], al
    mov dx, [pl_undoseg]
    or dx, dx
    jz .no
    call pl_undo_save                  ; CF=1: too big for it
    jc .no
    mov byte [pl_ud_redo], 0
    call pl_undo_label
    jmp short .out
.no:
    call pl_undo_drop
.out:
    pop dx
    pop ax
    ret

pl_undo_end:
    mov byte [pl_ud_busy], 0
    ret

; pl_undo_drop - nothing to undo: "Can't Undo", greyed
pl_undo_drop:
    push si
    push di
    mov si, pl_ud_cant
    mov di, pl_it_undo
    call pl_strcpy
    pop di
    pop si
    ret

; pl_undo_label - "Undo <action>" or "Redo <action>", enabled
pl_undo_label:
    push ax
    push bx
    push si
    push di
    mov si, pl_ud_sundo
    cmp byte [pl_ud_redo], 0
    je .u
    mov si, pl_ud_sredo
.u:
    mov di, pl_it_undo
    call pl_strcpy
    mov di, pl_it_undo
.end:
    cmp byte [di], 0
    je .cat
    inc di
    jmp short .end
.cat:
    mov bl, [pl_ud_lab]
    xor bh, bh
    shl bx, 1
    mov si, [pl_ud_names + bx]
    call pl_strcpy
    pop di
    pop si
    pop bx
    pop ax
    ret

; pl_undo_size - out: AX = the bytes a snapshot of the document takes, CF=1
; when that is more than Undo's claim holds
pl_undo_size:
    push dx
    mov ax, [pl_ncells]
    mov dx, PL_C_SZ
    mul dx
    jc .big
    add ax, PL_UD_HDR + 256            ; 81.75: the cells, and the 256 column
    jc .big                            ; widths. The border and note tables
    cmp ax, PL_CLAIM_UNDO_KB * 1024    ; have gone and the row heights with
    ja .big                            ; them
    clc
    pop dx
    ret
.big:
    stc
    pop dx
    ret

; pl_fcopy - CX bytes from AX:SI to DX:DI, forward. SI and DI advance.
pl_fcopy:
    push ds
    push es
    mov es, dx
    mov ds, ax
    cld
    rep movsb
    pop es
    pop ds
    ret

; pl_undo_save - the live document into segment DX at offset 0.
; CF=1 when it does not fit Undo's claim, and nothing is written
pl_undo_save:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    call pl_undo_size
    jc .out
    mov es, dx
    mov ax, [pl_ncells]
    mov [es:0], ax
    mov ax, [pl_txtlen]
    mov [es:6], ax
    mov di, PL_UD_HDR
    mov ax, [pl_ncells]                ; every length from OUR bss before any
    mov bx, PL_C_SZ                    ; segment register moves (the lesson of
    push dx                            ; the DS-switch hang)
    mul bx
    pop dx
    mov cx, ax
    mov ax, [pl_cellseg]
    xor si, si
    call pl_fcopy
    mov cx, 256                        ; ...and the column widths, which are
    mov ax, ds                         ; this package's OWN bss now (81.75)
    mov si, pl_colwtab
    call pl_fcopy
    clc
.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; pl_undo_load - segment AX at offset 0 back into the live document
pl_undo_load:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, ax
    mov bx, [es:0]
    mov [pl_ncells], bx
    mov bx, [es:6]
    mov [pl_txtlen], bx
    mov si, PL_UD_HDR
    push ax
    mov ax, [pl_ncells]
    mov bx, PL_C_SZ
    mul bx
    mov cx, ax
    pop ax
    mov dx, [pl_cellseg]
    xor di, di
    call pl_fcopy
    mov cx, 256
    mov dx, ds
    mov di, pl_colwtab
    call pl_fcopy
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; pl_undo_do - Edit > Undo (or Redo): the live document and the snapshot
; change places, through the staging claim, so doing it again redoes it
pl_undo_do:
    push ax
    push cx
    push dx
    push si
    push di
    mov dx, [pl_undoseg]
    or dx, dx
    jz .out
    mov byte [pl_editing], 0           ; an edit in progress is abandoned, as
                                       ; Excel's Undo abandons one - committing
                                       ; it would snapshot over the snapshot
    mov dx, [pl_stgseg]                ; now -> staging
    call pl_undo_save
    jc .out                            ; it has outgrown Undo: leave both
    call pl_undo_size                  ; ...measured NOW, before the load
    push ax                            ; changes the counts it is made of
    mov ax, [pl_undoseg]               ; the snapshot -> live
    call pl_undo_load
    pop cx                             ; staging -> the snapshot: what live was
    push ds
    push es
    mov es, [pl_undoseg]
    mov ds, [pl_stgseg]
    xor si, si
    xor di, di
    cld
    rep movsb
    pop es
    pop ds
    xor byte [pl_ud_redo], 1
    call pl_undo_label
    inc word [pl_pass]                 ; every formula recomputes against what
    mov byte [pl_commitdirty], 1       ; is there now
    mov byte [pl_chartdirty], 1
    call pl_geom
    mov si, [pl_ownwin]
    call pl_repaint
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

; =============================================================================
; Callbacks
; =============================================================================

; -----------------------------------------------------------------------------
; pl_note_arg - take the document this instance was launched with, if any.
; OSAPI_ARG_FILE is READ-AND-CLEAR (SPEC.md 54.5), so asking once here spends
; it and a later instance can never inherit it.
;
; THIS COPIES A NAME AND TOUCHES NO DISK, and that is the whole point of
; splitting it from pl_deferred_ld. A floppy read inside the entry proc runs
; under the LOADER LOCK and freezes the desktop (SPEC.md 69.6) - texpad's own
; ARG_FILE note carries the same warning, having paid for it.
; -----------------------------------------------------------------------------
pl_note_arg:
    push ax
    push bx                           ; ARG_FILE answers in BL, and the entry
    push cx                           ; proc that calls this has not banked BX
    push dx
    push si
    push di
    push es
    call OSAPI_ARG_FILE
    jc .none                          ; CF=1 = launched empty, the usual case
    mov [pl_argdir], dx
    mov [pl_argdrv], bl
    mov ax, KERNEL_SEG                ; the name lives in the KERNEL's segment,
    mov es, ax                        ; not ours
    mov di, pl_name
    mov cx, PL_NAMEMAX
.cp:
    mov al, [es:si]
    mov [di], al
    or al, al
    jz .named
    inc si
    inc di
    loop .cp
    mov byte [di], 0
.named:
    mov byte [pl_needld], 1
.none:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_deferred_ld - and NOW the disk read, from the first paint, which happens
; after the window is up and the loader lock is long gone. Clears the flag
; first, so a read that fails is not retried on every repaint for the rest of
; the session.
; -----------------------------------------------------------------------------
pl_deferred_ld:
    push ax
    push bx
    push cx
    push dx
    push si                           ; pl_paint takes SI as its window ptr
    push di                           ; the instruction after this returns -
    push es                           ; OSAPI_FILE_GOTO documents no output
    mov byte [pl_needld], 0           ; but promises nothing about SI either

    mov dx, [pl_argdir]
    mov bl, [pl_argdrv]
    call OSAPI_FILE_GOTO
    jc .out                           ; could not list it: the volume is back
    call pl_doread                    ; at the root and pl_name still names a
.out:                                 ; file that is not here - leave the
    pop es                            ; sheet empty rather than half-read
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

pl_paint:
    push bx
    cmp byte [pl_needld], 0           ; the associated document lands HERE, so
    je .nold                          ; it is on screen at the first paint
    call pl_deferred_ld               ; instead of waiting for a key or click
.nold:
    mov bx, si
    call pl_geom
    call pl_drawall
    cmp byte [pl_abon], 0             ; ...and the About card LAST, over the
    je .noab                          ; grid it is opaque about (SPEC.md 20.5.1)
    push si
    mov bx, si
    mov si, pl_ablines
    call os88ui_about_d               ; _d: this paint's region is already armed
    pop si
.noab:
    pop bx
    ret

pl_repaint:
    push ax
    push bx
    push cx
    push dx
    mov bx, si
    call pl_geom
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [pl_ox]
    mov bx, [pl_oy]
    mov cx, [pl_ox]
    add cx, [pl_cw]
    dec cx
    mov dx, [pl_oy]
    add dx, [pl_ch]
    dec dx
    call OSAPI_GFX_FILL
    call pl_drawall
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_onclick - W_ONCLICK: CX=x, DX=y (screen), SI=window; gfx lock held
; -----------------------------------------------------------------------------
pl_onclick:
    push ax
    push bx
    push cx
    push dx
    call pl_abdismiss                  ; the credits are up: this click is
    jc .out                            ; spent taking them down
    cmp word [pl_fdlg_win], 0
    je .nofdlg
    call pl_fdlg_close_r                 ; stage 1.8: a Format dialog isn't
                                        ; kernel-modal (no fdlg_grab/fdlg_top
                                        ; machinery outside the kernel - see
                                        ; the section comment above
                                        ; pl_fdlg_open), so a click that
                                        ; reaches the main grid at all means
                                        ; the dialog visually lost focus;
                                        ; treat it as Cancel rather than
                                        ; leave pl_fdlg_win stuck non-zero,
                                        ; which would gate every future
                                        ; Format menu command shut for good
.nofdlg:
    mov word [pl_msg], 0
    mov bx, si
    call pl_geom
    call pl_mbar_hit                   ; stage 2.x: Sheet's own in-window
    cmp al, PL_M_NONE                  ; menu bar (see the PL_MBAR_H section
    je .notmenu                        ; comment) claims a click on its strip
    call pl_mtrack                     ; before anything below ever sees it -
    jmp .out                           ; AL=menu index (from pl_mbar_hit),
                                        ; SI=window (still this callback's own
                                        ; untouched SI)
.notmenu:
    call pl_sbclick                    ; stage 3.0a+: the two scroll bars get
    jc .out                            ; the click before the grid does
    call pl_gridhit                    ; CX=x, DX=y -> CF=1 + AX=col, BX=row
    jnc .out
    call pl_shiftdown                  ; stage 3.0a: shift+click extends the
    jc .extend                         ; range from the existing anchor
    call pl_select                     ; plain click: collapse and move
    mov byte [pl_dragging], 1          ; ...and arm the drag from here
    push ax
    mov ax, [pl_selcol]
    mov [pl_drag_col], ax
    mov ax, [pl_selrow]
    mov [pl_drag_row], ax
    pop ax
    jmp .out
.extend:
    call pl_select_to
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_select - commit any pending edit, move the selection, scroll to show
; it, and repaint. AX = new column, BX = new row. SI must be the window
; ptr; not touched here so it stays that way for pl_repaint.
; -----------------------------------------------------------------------------
pl_select:
    push ax
    push bx
    mov word [pl_tabanchor], 0       ; ANY other move ends a Tab run - only the
    call pl_selbank                  ; Tab arm puts the anchor back afterwards
    call pl_commit
    mov [pl_selcol], ax
    mov [pl_selrow], bx
    mov [pl_selcol2], ax               ; stage 3.0a: a plain select COLLAPSES
    mov [pl_selrow2], bx               ; the range - anchor and extent become
                                        ; the same cell, which is exactly the
                                        ; old single-cell behaviour every
                                        ; existing caller still expects
    call pl_scrollto
    call pl_selpaint                   ; only what the move dirtied - the full
                                        ; repaint costs ~1s on a 4.77MHz 8088
                                        ; and this path runs per arrow key
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_select_to - stage 3.0a: move only the EXTENT of the range, leaving the
; anchor where it is. AX = column, BX = row. Used by shift+click, shift+arrows
; and the drag handler. SI must be the window ptr (pl_repaint's contract).
;
; Deliberately does NOT call pl_commit: extending a selection is not a
; different-cell move, and committing here would end an in-progress edit
; halfway through a drag.
; -----------------------------------------------------------------------------
pl_select_to:
    push ax
    push bx
    call pl_selbank
    cmp ax, PL_COLS
    jb .colok
    mov ax, PL_COLS - 1
.colok:
    cmp bx, PL_ROWS
    jb .rowok
    mov bx, PL_ROWS - 1
.rowok:
    mov [pl_selcol2], ax
    mov [pl_selrow2], bx
    call pl_scrollto2
    call pl_selpaint
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_selbank - bank the rect and the scroll origin a selection move starts
; from, so pl_selpaint can price the damage afterwards. Preserves everything.
; -----------------------------------------------------------------------------
pl_selbank:
    push ax
    call pl_selrect
    mov ax, [pl_selc1]
    mov [pl_oldc1], ax
    mov ax, [pl_selc2]
    mov [pl_oldc2], ax
    mov ax, [pl_selr1]
    mov [pl_oldr1], ax
    mov ax, [pl_selr2]
    mov [pl_oldr2], ax
    mov ax, [pl_scrollcol]
    mov [pl_oldscol], ax
    mov ax, [pl_scrollrow]
    mov [pl_oldsrow], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_selpaint - repaint after a selection move: as little of the window as
; the move actually dirtied. SI = the window (pl_repaint's own contract).
;
; The full repaint is ~1s on the target (PERFORMANCE.md's own table: one
; OSAPI_FONT_RUN per visible cell, plus all the chrome, plus a recalc pass),
; and this path runs once per keystroke-repeat and per drag packet - so it
; pays that price only when it must:
;   * pl_commit stored something -> full, because a dependent formula
;     anywhere on screen may now show a new value and only pl_drawall's
;     pass advance re-evaluates them;
;   * the view scrolled by rows only -> blit the surviving rows
;     (pl_scrollrow_blit) and letter just the vacated ones;
;   * by columns only -> the grid and its column half, nothing else
;     (pl_scrollcol_part - OSAPI_GFX_SCROLL is vertical-only, SPEC.md 5.5);
;   * no scroll at all -> the old cells and the new ones (pl_updsel).
; -----------------------------------------------------------------------------
pl_selpaint:
    push ax
    push cx
    cmp byte [pl_commitdirty], 0
    jne .full
    mov ax, [pl_oldscol]
    cmp ax, [pl_scrollcol]
    jne .cols
    mov cx, [pl_oldsrow]
    cmp cx, [pl_scrollrow]
    jne .rows
    call pl_updsel
    jmp .out
.rows:
    call pl_scrollrow_blit             ; CX = the row the view is leaving
    jc .full                           ; refused: pay the full price
    call pl_updsel                     ; old cells + new cells + the bars
    jmp .out
.cols:
    mov cx, [pl_oldsrow]
    cmp cx, [pl_scrollrow]
    jne .full                          ; both axes moved: a Goto, not a walk
    call pl_scrollcol_part
    call pl_drawbar                    ; the reference box changed too
    call pl_drawstatus
    jmp .out
.full:
    mov byte [pl_commitdirty], 0
    call pl_repaint
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_updsel - the no-scroll damage path: redraw the union of the old and the
; new selection rects (which covers both frames), then the two bars whose
; text names the selection. SI = the window.
; -----------------------------------------------------------------------------
pl_updsel:
    push ax
    push bx
    push cx
    push dx
    mov bx, si
    call pl_geom
    cmp word [pl_vcols], 0
    je .chrome
    cmp word [pl_vrows], 0
    je .chrome
    call pl_selrect                    ; the NEW rect, ordered
    mov ax, [pl_selc1]                 ; the union's columns...
    cmp ax, [pl_oldc1]
    jbe .c1
    mov ax, [pl_oldc1]
.c1:
    mov bx, [pl_selc2]
    cmp bx, [pl_oldc2]
    jae .c2
    mov bx, [pl_oldc2]
.c2:
    call pl_vclip_col                  ; 81.70: real range -> visible-index
    jnc .chrome                        ; range, frozen-aware; CF=0 = wholly
    mov [pl_dmgc1], ax                 ; off-screen (what the old inline
    mov [pl_dmgc2], bx                 ; [pl_scrollcol] clamp used to do)
    mov ax, [pl_selr1]                 ; the union's rows, the same
    cmp ax, [pl_oldr1]
    jbe .r1
    mov ax, [pl_oldr1]
.r1:
    mov bx, [pl_selr2]
    cmp bx, [pl_oldr2]
    jae .r2
    mov bx, [pl_oldr2]
.r2:
    call pl_vclip_row
    jnc .chrome
    mov [pl_dmgr1], ax
    mov [pl_dmgr2], bx
    call pl_dmgdraw
    call pl_drawsel
.chrome:
    call pl_drawbar
    call pl_drawstatus
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_gridhit - stage 3.0a: which cell is this screen point on?
; in:  CX = x, DX = y (screen coords, W_ONCLICK/W_ONDRAG's own)
; out: CF=1 and AX = column, BX = row (both absolute, scroll-adjusted);
;      CF=0 if the point is not over a grid cell. CX/DX restored.
;
; Lifted verbatim out of pl_onclick so the drag handler hit-tests exactly the
; same way a click does - two copies of this arithmetic would drift the first
; time the header or menu-bar height changed.
; -----------------------------------------------------------------------------
pl_gridhit:
    push cx
    push dx
    mov ax, cx
    sub ax, [pl_ox]
    sub ax, PL_RH_W
    js .no
    mov bx, dx
    sub bx, [pl_goy]                   ; grid origin, NOT raw content origin -
    sub bx, PL_FB_H + PL_CH_H          ; the menu bar strip sits above it
    js .no
    mov dx, ax                         ; DX = pixels into the grid: walked
    xor cx, cx                         ; across the columns' own widths (81.56)
.hwalk:
    cmp cx, [pl_vcols]
    jae .no
    mov ax, cx
    call pl_vwidth
    cmp dx, ax
    jb .hcol
    sub dx, ax
    inc cx
    jmp short .hwalk
.hcol:
    mov ax, cx
    call pl_vreal_col                  ; 81.70: frozen or scrolling, the
    mov [pl_wcol], ax                  ; visible->real mapping is the same
    xor cx, cx                         ; ...and down the rows' own heights
.vwalk:                                ; (81.60), BX = pixels into the grid
    cmp cx, [pl_vrows]
    jae .no
    mov ax, cx
    call pl_vheight
    cmp bx, ax
    jb .vrow
    sub bx, ax
    inc cx
    jmp short .vwalk
.vrow:
    mov ax, cx
    call pl_vreal_row
    mov bx, ax
    mov ax, [pl_wcol]
    pop dx
    pop cx
    stc
    ret
.no:
    pop dx
    pop cx
    clc
    ret

; -----------------------------------------------------------------------------
; pl_flkey - stage 3.0b: hand one keystroke to the formula bar's field, then
; resync this app's own pl_editlen from the field's LN_LEN so pl_commit and
; every other existing reader keeps working unchanged.
; in: AL = ascii, AH = scan.
;
; REDRAWS ONLY THE FIELD. An editing keystroke changes no cell, so the full
; pl_repaint this used to end with - every visible cell re-lettered plus a
; recalc pass, ~1s per keystroke on a 4.77MHz 8088 - repainted identical
; pixels and dropped keys on the target. os88line_draw is one opaque run
; plus the strip past the text; pl_flmarg covers the one span it does not.
; -----------------------------------------------------------------------------
pl_flkey:
    push ax
    push si
    call pl_flrect                     ; the box may have moved since the last
                                        ; draw - os88line hit-tests and draws
                                        ; from the same four words
    mov si, pl_fline
    call os88line_key
    mov ax, [si + LN_LEN]
    mov [pl_editlen], al               ; LN_LEN is a word and PL_EDITMAX is
                                        ; 63, so the low byte is the whole of
                                        ; it - but keep them in step, because
                                        ; pl_commit still reads pl_editlen
    call pl_flmarg
    call os88line_draw
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_flmarg - white the strip between the content box's frame and os88line's
; 8-aligned pen. The field's own draw covers its run and the strip PAST the
; text (os88line_draw's header), so this margin is the one span neither
; touches - and on the first keystroke of an edit it still holds the leftmost
; pixels of the static text pl_drawbar drew there. SI = pl_fline, whose rect
; pl_flrect has already refreshed. Preserves everything.
; -----------------------------------------------------------------------------
pl_flmarg:
    push ax
    push bx
    push cx
    push dx
    call os88line_pen
    mov cx, ax
    dec cx                             ; the margin's right edge...
    mov ax, [si + LN_X1]
    inc ax                             ; ...and its left, inside the frame
    cmp ax, cx
    jg .none
    mov bx, [si + LN_Y1]
    inc bx
    mov dx, [si + LN_Y2]
    dec dx
    cmp bx, dx
    jg .none
    push ax
    mov al, CWHITE
    call OSAPI_SET_COLOR
    pop ax
    call OSAPI_GFX_FILL
.none:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_flsync - stage 3.0b: the buffer was filled by someone other than the
; field (F2's seed-from-cell, or a Paste). Recompute the field's own length
; from the NUL and park the caret at the end, which is where a just-loaded
; value should leave it. Preserves everything.
; -----------------------------------------------------------------------------
pl_flsync:
    push ax
    push cx
    push si
    xor cx, cx
    mov si, pl_editbuf
.cnt:
    cmp byte [si], 0
    je .done
    cmp cx, PL_EDITMAX                 ; never trust an unterminated buffer
    jae .done
    inc si
    inc cx
    jmp .cnt
.done:
    mov [pl_editlen], cl
    mov si, pl_fline
    mov [si + LN_LEN], cx
    mov [si + LN_CAR], cx              ; caret at the end
    mov word [si + LN_VIEW], 0
    mov byte [si + LN_FOCUS], 1
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_editstart - stage 3.0b: begin a fresh, EMPTY edit (the first character
; typed into a cell). Resets both this app's own edit state and the field's.
; -----------------------------------------------------------------------------
pl_editstart:
    push si
    mov byte [pl_editing], 1
    mov byte [pl_editlen], 0
    mov byte [pl_editbuf], 0
    mov si, pl_fline
    mov word [si + LN_LEN], 0
    mov word [si + LN_CAR], 0
    mov word [si + LN_VIEW], 0
    mov byte [si + LN_FOCUS], 1
    pop si
    ret

; -----------------------------------------------------------------------------
; pl_arrowsrc - stage 3.0a: where does an arrow key start counting from?
; out: AX = column, BX = row - the ANCHOR normally, the EXTENT while shift is
; held, which is what makes shift+arrow grow the block from the end the user
; last moved rather than snapping it back to the anchor.
; -----------------------------------------------------------------------------
pl_arrowsrc:
    call pl_shiftdown
    jc .ext
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    ret
.ext:
    mov ax, [pl_selcol2]
    mov bx, [pl_selrow2]
    ret

; -----------------------------------------------------------------------------
; pl_shiftdown - out: CF=1 if either shift key is held. Preserves everything.
; 0x2A/0x36 are the set-1 make codes; kbd_down's map is 128 bits wide, one per
; make code, so it answers for any key and not just the named KSC_* few.
; -----------------------------------------------------------------------------
pl_shiftdown:
    push ax
    mov al, 0x2A                       ; left shift
    call OSAPI_KEY_DOWN
    jc .yes
    mov al, 0x36                       ; right shift
    call OSAPI_KEY_DOWN
    jc .yes
    pop ax                             ; pop leaves the flags alone
    clc
    ret
.yes:
    pop ax
    stc
    ret

; -----------------------------------------------------------------------------
; pl_selrect - stage 3.0a: normalize the anchor/extent pair into an ordered
; rect. Out: [pl_selc1] <= [pl_selc2], [pl_selr1] <= [pl_selr2]. Every range
; consumer reads these rather than comparing the raw pair itself, so "which
; corner did the user start from" is answered in exactly one place.
; -----------------------------------------------------------------------------
pl_selrect:
    push ax
    push bx
    mov ax, [pl_selcol]
    mov bx, [pl_selcol2]
    cmp ax, bx
    jbe .cols_ok
    xchg ax, bx
.cols_ok:
    mov [pl_selc1], ax
    mov [pl_selc2], bx
    mov ax, [pl_selrow]
    mov bx, [pl_selrow2]
    cmp ax, bx
    jbe .rows_ok
    xchg ax, bx
.rows_ok:
    mov [pl_selr1], ax
    mov [pl_selr2], bx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_selsingle - out: CF=1 if the selection is a single cell (anchor==extent).
; The gate every command that has no range semantics yet uses.
; -----------------------------------------------------------------------------
pl_selsingle:
    push ax
    mov ax, [pl_selcol]
    cmp ax, [pl_selcol2]
    jne .no
    mov ax, [pl_selrow]
    cmp ax, [pl_selrow2]
    jne .no
    stc
    jmp .out
.no:
    clc
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_scrollto - move the scroll origin the least amount that brings the
; current selection into the viewport described by [pl_vcols]/[pl_vrows]
; -----------------------------------------------------------------------------
pl_scrollto:
    push ax
    mov ax, [pl_selcol]
    mov [pl_sc_tcol], ax
    mov ax, [pl_selrow]
    mov [pl_sc_trow], ax
    pop ax
    jmp pl_scrollto_t

; stage 3.0a: the same scroll, aimed at the range's moving END instead of its
; anchor - what a drag or a shift+arrow needs, since it is the extent that
; walks off-screen, not the anchor.
pl_scrollto2:
    push ax
    mov ax, [pl_selcol2]
    mov [pl_sc_tcol], ax
    mov ax, [pl_selrow2]
    mov [pl_sc_trow], ax
    pop ax
    jmp pl_scrollto_t
; =============================================================================
; the core: bring [pl_sc_tcol]/[pl_sc_trow] into the viewport, moving the
; scroll origin the least amount that does it
pl_scrollto_t:
    push ax
    push bx
    ; 81.73 made the "is it already on screen?" test ASK THE VIEWPORT rather
    ; than compute it. It used to be pl_scrollcol + the scrolling window's
    ; width, which is only the last visible column while the slots march in
    ; step with the columns - a hidden one anywhere between them breaks that,
    ; and pl_vidx_col is the routine that already knows.
    mov ax, [pl_sc_tcol]
    cmp ax, [pl_freezecol]             ; 81.70: the frozen prefix is always
    jb .rows                           ; visible - nothing to scroll for it,
                                        ; and pl_scrollcol may never go there
    call pl_vidx_col
    jc .rows                           ; already showing: leave the view alone
    mov ax, [pl_sc_tcol]
    cmp ax, [pl_scrollcol]
    jae .cfwd
    mov [pl_scrollcol], ax             ; it is to the LEFT: scroll onto it
    jmp short .rows
.cfwd:
    call pl_backcols                   ; to the RIGHT: walk back from it until
    mov [pl_scrollcol], ax             ; the window is full (81.56 - the
                                        ; columns are not one width, so this
                                        ; is walked and not subtracted)
.rows:
    mov ax, [pl_sc_trow]
    cmp ax, [pl_freezerow]
    jb .out
    call pl_vidx_row
    jc .out
    mov ax, [pl_sc_trow]
    cmp ax, [pl_scrollrow]
    jae .rfwd
    mov [pl_scrollrow], ax
    jmp short .out
.rfwd:
    call pl_backrows                   ; nor the rows one height (81.60)
    mov [pl_scrollrow], ax
.out:
    pop bx
    pop ax
    ret

; pl_backcols - AX = a column past the view's right edge -> AX = the scroll
; column that shows it WHOLE at the right: the columns before it, each its own
; width, as many as still fit [pl_gridw]. It subtracted the column count the
; OLD view held, which put a column wider than the ones it scrolled past
; partly or wholly off the glass
pl_backcols:
    push bx
    push cx
    push dx
    mov bx, ax                         ; BX = the first column shown
    call pl_colwidth
    mov cl, 3
    shl ax, cl
    mov dx, ax                         ; DX = the pixels they take
.l:
    or bx, bx
    jz .out
    mov ax, bx
    dec ax
    call pl_colwidth
    mov cl, 3
    shl ax, cl
    add ax, dx
    cmp ax, [pl_gridw]
    ja .out
    mov dx, ax
    dec bx
    jmp short .l
.out:
    mov ax, bx
    pop dx
    pop cx
    pop bx
    ret

; pl_backrows - AX = a row below the view -> AX = the scroll row that shows it
; whole at the bottom. 81.75: one height for every row, so it is a count.
pl_backrows:
    push bx
    push dx
    mov bx, ax                         ; BX = the first row shown
    mov dx, PL_RH_NORMAL               ; DX = the pixels they take
.l:
    or bx, bx
    jz .out
    mov ax, dx
    add ax, PL_RH_NORMAL
    cmp ax, [pl_gridh]
    ja .out
    mov dx, ax
    dec bx
    jmp short .l
.out:
    mov ax, bx
    pop dx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_onkey - W_ONKEY: AL=ascii (0 for a navigation key), AH=scan, SI=window
; -----------------------------------------------------------------------------
pl_onkey:
    push ax
    push bx
    push cx
    push dx
    call pl_abdismiss                  ; any key takes the credits down, and
    jc .out                            ; is spent doing it
    cmp word [pl_fdlg_win], 0
    je .nofdlg
    call pl_fdlg_close_r                 ; see pl_onclick's own copy of this
                                        ; guard for why
.nofdlg:
    mov word [pl_msg], 0
    mov bx, si
    call pl_geom
    or al, al
    jz .navkey
    ; stage 3.0a: a shift+arrow arrives WITH an ASCII byte. The arrow and the
    ; keypad digit share one scancode - 0x4D is both Right and KP-6, the E0
    ; prefix naming no key of its own (kernel/mouse.inc's own note) - so the
    ; kernel's shifted translation hands us '6'. Without this test, holding
    ; shift and pressing an arrow would TYPE A DIGIT into the cell instead of
    ; extending the selection, which is exactly what it did before this check.
    call pl_shiftdown
    jnc .typing
    cmp ah, 0x4B
    je .navkey
    cmp ah, 0x4D
    je .navkey
    cmp ah, 0x48
    je .navkey
    cmp ah, 0x50
    je .navkey
    jmp .typing
.navkey:
    ; stage 3.0b: while an edit is in progress, the keys that move a CARET
    ; belong to the field, not to the grid - Left/Right/Home/End and Delete.
    ; Up/Down deliberately still commit and move the selection, which is what
    ; Excel does during cell entry.
    cmp byte [pl_editing], 0
    je .navgrid
    cmp ah, 0x4B                     ; Left
    je .navfield
    cmp ah, 0x4D                     ; Right
    je .navfield
    cmp ah, 0x47                     ; Home
    je .navfield
    cmp ah, 0x4F                     ; End
    je .navfield
    cmp ah, 0x53                     ; Delete
    je .navfield
    jmp .navgrid
.navfield:
    call pl_flkey
    jmp .out
.navgrid:
    cmp ah, 0x4B                     ; Left
    je .left
    cmp ah, 0x4D                     ; Right
    je .right
    cmp ah, 0x48                     ; Up
    je .up
    cmp ah, 0x50                     ; Down
    je .down
    cmp ah, 0x49                     ; Page Up
    je .pgup
    cmp ah, 0x51                     ; Page Down
    je .pgdn
    cmp ah, 0x47                     ; Home: back to column A
    je .home
    cmp ah, 0x53                     ; Delete: clear the selected cell
    je .delcell
    cmp ah, 0x3C                     ; F2: edit the cell in place
    je .f2
    jmp .out
.typing:
    cmp al, 27                       ; Escape: cancel the edit
    jne .notesc
    cmp byte [pl_editing], 0
    je .out
    mov byte [pl_editing], 0
    call pl_repaint
    jmp .out
.notesc:
    cmp al, 13                       ; Enter: commit, move down - and back to
    jne .nottab                      ; the column this ROW's entry started in,
    call pl_commit                   ; which is what Excel does after a run of
    mov ax, [pl_tabanchor]           ; Tabs. pl_select clears the anchor, so
    or ax, ax                        ; Enter consuming it needs no extra step
    jz .noanchor
    dec ax                           ; stored as col+1, see the Tab arm below
    jmp .enterrow
.noanchor:
    mov ax, [pl_selcol]
.enterrow:
    mov bx, [pl_selrow]
    inc bx
    cmp bx, PL_ROWS
    jb .entergo
    mov bx, PL_ROWS - 1
.entergo:
    call pl_select
    jmp .out
.nottab:
    cmp al, 9                        ; Tab: commit, move right
    jne .notbs
    call pl_commit
    mov ax, [pl_tabanchor]           ; the first Tab of a run records where it
    or ax, ax                        ; started; later ones keep that. Stored as
    jnz .haveanchor                  ; col+1, so a ZEROED bss reads as "none"
    mov ax, [pl_selcol]              ; and no init pass is needed
    inc ax
.haveanchor:
    push ax                          ; pl_select clears it, so it is put back
    mov ax, [pl_selcol]              ; afterwards rather than before
    mov bx, [pl_selrow]
    inc ax
    cmp ax, PL_COLS
    jb .tabgo
    mov ax, PL_COLS - 1
.tabgo:
    call pl_select
    pop ax
    mov [pl_tabanchor], ax
    jmp .out
.notbs:
    cmp al, 8                        ; Backspace: the field owns it now, so it
    jne .notdigit                    ; deletes AT THE CARET rather than only
    cmp byte [pl_editing], 0         ; ever chopping the last character
    je .out
    call pl_flkey
    jmp .out
.notdigit:
    ; STAGE 4.5 REPLACED AN ALLOW-LIST WITH A RANGE, and the reason is that
    ; the list had stopped describing anything. It grew one character at a
    ; time as the formula language did - '=' then the operators, then <> for
    ; comparisons, then ! and " for cross-sheet refs and ALERT's string
    ; literal, then '.' for SET.VALUE, then '$' for absolute references, then
    ; '^' for the power operator - and each addition was found the same way:
    ; the parser handled the character perfectly and the character never
    ; reached it, because THIS gate dropped it first.
    ;
    ; A cell that can hold a LABEL ends the argument. A label is arbitrary
    ; text; there is no subset of printable ASCII a column heading is not
    ; allowed to contain, and an apostrophe or a percent sign being rejected
    ; is a bug with no upside. So the gate now asks the only question it can
    ; actually answer - is this a printable character - and leaves deciding
    ; what the characters MEAN to pl_commit, which is where that decision
    ; belongs and where it already lives.
    cmp al, ' '
    jb .out                            ; control characters are handled above
    cmp al, 0x7E                       ; (Enter, Escape, Backspace, arrows)
    ja .out                            ; and are not text
.accept:
    cmp byte [pl_editing], 0
    jnz .append
    call pl_editstart                ; first character into an empty cell
.append:
    call pl_flkey                    ; the field inserts AT THE CARET and
    jmp .out                         ; bounds itself against LN_MAX
; stage 3.0a: an arrow moves the ANCHOR (collapsing the range) normally, or
; walks the EXTENT when shift is held. Both halves share one source-load and
; one dispatch rather than four near-copies of each.
.left:
    call pl_arrowsrc
    or ax, ax
    jz .out
    dec ax
    jmp .arrowgo
.right:
    call pl_arrowsrc
    cmp ax, PL_COLS - 1
    jae .out
    inc ax
    jmp .arrowgo
.up:
    call pl_arrowsrc
    or bx, bx
    jz .out
    dec bx
    jmp .arrowgo
.down:
    call pl_arrowsrc
    cmp bx, PL_ROWS - 1
    jae .out
    inc bx
.arrowgo:
    call pl_shiftdown
    jc .arrowext
    call pl_select
    jmp .out
.arrowext:
    call pl_select_to
    jmp .out
.pgup:
    mov bx, [pl_selrow]
    mov ax, [pl_vrows]
    cmp bx, ax
    jae .pgup_sub
    xor bx, bx
    jmp .pgup_go
.pgup_sub:
    sub bx, ax
.pgup_go:
    mov ax, [pl_selcol]
    call pl_select
    jmp .out
.pgdn:
    mov bx, [pl_selrow]
    add bx, [pl_vrows]
    cmp bx, PL_ROWS - 1
    jbe .pgdn_go
    mov bx, PL_ROWS - 1
.pgdn_go:
    mov ax, [pl_selcol]
    call pl_select
    jmp .out
.home:
    xor ax, ax
    mov bx, [pl_selrow]
    call pl_select
    jmp .out
.f2:
    call pl_beginedit
    jmp .out
.delcell:
    mov byte [pl_editing], 0
    mov al, PL_UL_CLEAR                ; Del is Edit Clear's key, and undoable
    call pl_undo_begin                 ; as it is (81.57)
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    call pl_clearcell
    call pl_undo_end
    call pl_repaint
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_beginedit - F2: seed the edit buffer from the selected cell's current
; value (blank if the cell is empty) and enter edit mode. SI must be the
; window ptr for pl_repaint.
; -----------------------------------------------------------------------------
pl_beginedit:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov dx, si                        ; DX = window ptr, stashed (SI is used
                                       ; as scratch throughout this function)
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    call pl_findcell
    jnc .blank
    push es
    mov es, [pl_cellseg]
    test byte [es:di+4], 1
    jz .plainval
    mov ax, [es:di+PL_C_FOFF]                 ; formula_off
    pop es
    mov byte [pl_editbuf], '='
    mov di, pl_editbuf + 1
    mov si, ax
    push es
    mov es, [pl_txtseg]
.copyf:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyf
    pop es
    jmp .havelen
.plainval:
    call pl_cellnum                   ; the value as decimal text
    pop es
    mov si, pl_numbuf
    mov di, pl_editbuf
    call pl_strcpy
.havelen:
    xor cx, cx
    mov si, pl_editbuf
.cnt:
    cmp byte [si], 0
    je .setlen
    inc si
    inc cx
    jmp .cnt
.setlen:
    mov [pl_editlen], cl
    jmp .go
.blank:
    mov byte [pl_editbuf], 0
    mov byte [pl_editlen], 0
.go:
    mov byte [pl_editing], 1
    call pl_flsync                    ; stage 3.0b: the field's own length,
                                       ; caret and scroll must match the
                                       ; buffer we just seeded, or the caret
                                       ; draws somewhere the text is not
    mov si, dx                        ; SI = window ptr, restored
    call pl_repaint
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_paren_ok - do the parentheses in [pl_editbuf] balance? out: CF=1 = no.
;
; Lexical only, and deliberately so: it runs at COMMIT, where re-running the
; evaluator would mean recursion, cycle marks and memoisation stamps as a side
; effect of typing. It catches the bracket a person actually drops; it does not
; claim to be a syntax check, and something like `=1+` still commits and reads
; as 0. A real answer needs an error VALUE - PL_T_ERR is reserved and nothing
; produces one yet - and that is a feature, not this.
;
; A quoted string is skipped whole, so a bracket inside a label literal does
; not count toward the balance.
; -----------------------------------------------------------------------------
pl_paren_ok:
    push ax
    push cx
    push si
    mov si, pl_editbuf
    xor cx, cx                        ; cx = how many are still open
.scan:
    mov al, [si]
    or al, al
    jz .done
    inc si
    cmp al, '"'
    je .instr
    cmp al, '('
    je .open
    cmp al, ')'
    jne .scan
    or cx, cx
    jz .bad                           ; a ')' with nothing open
    dec cx
    jmp .scan
.open:
    inc cx
    jmp .scan
.instr:
    mov al, [si]
    or al, al
    jz .done
    inc si
    cmp al, '"'
    jne .instr
    jmp .scan
.done:
    or cx, cx
    jnz .bad
    clc
    jmp .out
.bad:
    stc
.out:
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_commit - if a cell is being edited, parse the buffer and store it (an
; empty buffer, or one that doesn't parse as a single signed integer,
; clears the cell instead); either way stop editing. SI is not touched.
; Out: CF=1 when the store was REFUSED (text arena or cell table full) and
; the cell keeps what it had - pl_sort_permcol stops on it; every older
; caller ignores it, which is what the silence always was.
; -----------------------------------------------------------------------------
pl_commit:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    cmp byte [pl_editing], 0
    je .out
    cmp byte [pl_ud_busy], 0          ; a TYPED entry is undoable on its own
    jne .inside                       ; (81.57); one made by Paste, Fill or
    mov al, PL_UL_ENTRY               ; Sort is part of theirs, which took
    call pl_undo_begin                ; the snapshot already
    call pl_undo_end
.inside:
    mov byte [pl_editing], 0
    mov byte [pl_commitdirty], 1      ; cell data changes below (even an empty
                                      ; buffer clears the cell) - pl_selpaint
                                      ; reads this and pays the full repaint,
                                      ; whose pass advance is what re-shows
                                      ; every dependent formula
    cmp byte [pl_editlen], 0
    jne .have
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    call pl_clearcell
    clc                               ; clearing is never refused
    jmp .out
.have:
    cmp byte [pl_editbuf], '='
    jne .numeric
    call pl_paren_ok                  ; ...and a formula must be well formed,
    jc .badformula                    ; for the same reason "3.5kg" is not 3.5
    mov si, pl_editbuf
    inc si                            ; past the '='
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    call pl_setformula
    jmp .out
.badformula:
    ; `=SUM(E2:E5` - one missing bracket - used to be STORED AS A FORMULA and
    ; quietly evaluated to 0, which is the worst answer available: a plausible
    ; number, in the right place, that nobody has reason to doubt. It is kept
    ; as a LABEL instead, so the cell shows the text that was typed, and the
    ; status bar says why. That is this app's existing rule for input that
    ; cannot be what it looks like, applied to the one type that was exempt.
    mov word [pl_msg], pl_s_badparen
    jmp .astext
.numeric:
    mov si, pl_editbuf                ; stage 4.0: a full decimal, not a signed
    call fx_atof                      ; integer. "3.5", "-0.25" and "1e3" are
    jc .astext                        ; all values now; anything fx_atof does
    mov al, [si]                      ; not consume ENTIRELY is not a number,
    or al, al                         ; which is what keeps "3.5kg" from
    jnz .astext                       ; silently becoming 3.5
    call pl_acc_store
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    call pl_setvald
    jmp .out
.astext:
    ; stage 4.5: what used to happen here was pl_clearcell - anything that
    ; would not parse as a number was DISCARDED, and typing a column heading
    ; left the cell empty. Content decides the type, exactly as Excel does it:
    ; '=' is a formula, a complete number is a number, and everything else is
    ; a label. There is no forcing prefix because Excel 2.1 has none either
    ; (the leading ' " ^ \ are Lotus's, not Excel's) - a cell that must hold
    ; "1990" as text is a Format problem, not an entry one.
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    mov si, pl_editbuf
    push ax                           ; ...except an ERROR VALUE's name, which
    call pl_errword                   ; is the error constant, as a typed #N/A
    mov dx, ax                        ; is in Excel - and so what Paste and
    pop ax                            ; Sort's carry commit for one, both of
    jnc .label                        ; which go through here as text (81.61)
    call pl_seterr
    jmp short .out
.label:
    call pl_setlabel                  ; ...and TRUE and FALSE, which are
.out:                                 ; the logical constant (81.51)
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; Drawing
; =============================================================================

pl_drawall:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    cmp byte [pl_calcmanual], 0       ; stage 3.0c Options > Calculation. NOT
    jne .nocalc                       ; advancing the pass stamp is the whole
    inc word [pl_pass]                ; mechanism: pl_eval_cell's memoization
.nocalc:                              ; keys off it, so every formula reads as
                                       ; a cache hit and nothing re-evaluates.
                                       ; One recalculation pass per full
                                       ; repaint, when it is automatic.
    call pl_mbar_draw
    call pl_drawbar
    call pl_drawstatus
    call pl_sbsync                    ; stage 3.0a+: both scroll bars, from
    mov bx, pl_vsb                    ; the live geometry and scroll position
    call os88ui_sbar
    mov bx, pl_hsb
    call pl_hsb_draw
    call pl_drawcolhdrs
    call pl_drawrowhdrs
    call pl_dmgfull                   ; the three grid painters below are
    call pl_drawgrid                  ; RANGED now (pl_dmgc1..pl_dmgr2); a
    call pl_drawlines                 ; full draw is the whole viewport
    call pl_drawsel
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_dmgfull - point the damage range at the whole viewport. The ranged grid
; painters guard [pl_vcols]/[pl_vrows] == 0 themselves, so the wrapped-around
; bounds an empty viewport produces here are never read. Preserves everything.
; -----------------------------------------------------------------------------
pl_dmgfull:
    push ax
    xor ax, ax
    mov [pl_dmgc1], ax
    mov [pl_dmgr1], ax
    mov ax, [pl_vcols]
    dec ax
    mov [pl_dmgc2], ax
    mov ax, [pl_vrows]
    dec ax
    mov [pl_dmgr2], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_dmgdraw - redraw ONLY the cells in [pl_dmgc1..c2] x [pl_dmgr1..r2]
; (window-relative, inclusive, already clamped to the viewport), plus the
; gridline segments and border edges over them. This is the partial-repaint
; core: OSAPI_FONT_RUN owns each cell's 8 glyph rows, so when a cell is
; taller the band below them is filled here - the full repaint's window-wide
; white fill does not run on this path, and the mover owns its stale pixels
; (the old selection frame's edges land in exactly that band).
; -----------------------------------------------------------------------------
pl_dmgdraw:
    push ax
    push bx
    push cx
    push dx
    cmp word [pl_vcols], 0
    je .out
    cmp word [pl_vrows], 0
    je .out
    mov ax, [pl_dmgc1]                 ; the damaged columns' pixel span
    call pl_vcx                        ; each column its own width (81.56)
    add ax, [pl_ox]
    add ax, PL_RH_W
    mov [pl_blitx1], ax
    mov ax, [pl_dmgc2]
    inc ax
    call pl_vcx                        ; each column its own width (81.56)
    add ax, [pl_ox]
    add ax, PL_RH_W
    dec ax
    mov [pl_blitx2], ax
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov cx, [pl_dmgr1]
.band:
    ; EACH ROW ITS OWN HEIGHT (81.60): the band ABOVE the glyphs, where a
    ; tall row's text sits low (pl_vtoff), and the band below them
    cmp cx, [pl_dmgr2]
    ja .nobands
    mov ax, cx
    call pl_vry
    add ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    mov bx, ax                         ; BX = the row's top
    mov ax, cx
    call pl_vtoff
    or ax, ax
    jz .below
    mov dx, bx
    add dx, ax
    dec dx                             ; down to the line above the glyphs
    mov ax, [pl_blitx1]
    push cx
    mov cx, [pl_blitx2]
    call OSAPI_GFX_FILL
    pop cx
.below:
    mov ax, cx
    call pl_vheight
    mov dx, bx
    add dx, ax
    dec dx                             ; DX = the row's last pixel line
    mov ax, cx
    call pl_vtoff
    add bx, ax
    add bx, 8                          ; below the glyphs
    cmp bx, dx
    ja .bandn                          ; an 8px row: the run covers it all
    mov ax, [pl_blitx1]
    push cx
    mov cx, [pl_blitx2]
    call OSAPI_GFX_FILL
    pop cx
.bandn:
    inc cx
    jmp .band
.nobands:
    call pl_drawgrid
    call pl_drawlines
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_drawbar - the formula bar (stage 2.x: real Excel's own two-box look -
; a fixed-width reference box on the left, a boxed content area on the
; right showing the selected cell's current value/formula, or the live
; edit buffer while typing). Status messages have their own bar now
; (pl_drawstatus) - this one only ever shows the reference and the
; content, matching real Excel's own division of labor between the two.
; -----------------------------------------------------------------------------
; =============================================================================
; The two scroll bars (stage 3.0a+)
;
; The VERTICAL one is os88ui.inc's shared element, used exactly as files.inc
; and fdlg.inc use it. The HORIZONTAL one is pl_hsb_* below - private to this
; app for now, but written to os88ui.inc's own conventions (same seven-word
; block, same OS88UI_SB* part codes, same "geometry not policy" split) so that
; promoting it into the shared file after Sheet 2.0 is a rename rather than a
; redesign. os88ui.inc has no horizontal bar today: its arrow cells are
; derived as y1+10/y2-10 and os88ui_sbtrack deliberately takes DX and not CX
; (SPEC.md 13.10.5.2, "x is never read"), so the axis is structural.
;
; SCROLL EXTENT. `total` is not PL_ROWS/PL_COLS - a bar over 16384 rows would
; have a one-pixel thumb that says nothing. It is the USED extent plus one
; screen, so the thumb is proportional to the sheet a person actually has, and
; it collapses to "no thumb" when everything already fits (os88ui_sbthumb
; answers CF=1 for that case on its own).
; =============================================================================

; -----------------------------------------------------------------------------
; pl_sbsync - refill both blocks from the live geometry and scroll position.
; Called before every draw and every hit-test, for pl_flrect's reason: the
; window moves and resizes, and a painter and a hit-tester reading different
; rects is the one bug this element is designed to make impossible.
; -----------------------------------------------------------------------------
pl_sbsync:
    push ax
    push bx
    push cx
    push dx
    call pl_difbbox                    ; -> [pl_bbcol]/[pl_bbrow], the used
                                        ; bounding box (walks only OCCUPIED
                                        ; cells, not the whole grid)

    ; --- vertical: the strip at the right of the grid area
    mov ax, [pl_ox]
    add ax, [pl_cw]
    sub ax, PL_VSB_W
    mov [pl_vsb + 0], ax               ; x1
    mov ax, [pl_ox]
    add ax, [pl_cw]
    dec ax
    mov [pl_vsb + 4], ax               ; x2
    mov ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    mov [pl_vsb + 2], ax               ; y1 - the top of the grid proper
    mov ax, [pl_oy]
    add ax, [pl_ch]
    sub ax, PL_SB_H + PL_HSB_H
    dec ax
    mov [pl_vsb + 6], ax               ; y2 - just above the horizontal bar
    mov ax, [pl_bbrow]
    inc ax                             ; the USED extent, not PL_ROWS - a bar
    cmp ax, [pl_vrows]                 ; over 16384 rows has a one-pixel thumb
    jae .vtot                          ; that says nothing. Floored at `fit`,
    mov ax, [pl_vrows]                 ; so an empty sheet has total == fit and
.vtot:                                 ; correctly shows no thumb at all.
    sub ax, [pl_freezerow]             ; 81.70: total/fit/pos all shift into
    mov [pl_vsb + 8], ax               ; the SCROLLING region's own space -
    mov ax, [pl_vrows]                 ; the frozen prefix is never part of
    sub ax, [pl_freezerow]             ; what the thumb represents at all
    mov [pl_vsb + 10], ax              ; fit
    mov ax, [pl_scrollrow]
    sub ax, [pl_freezerow]
    mov dx, [pl_vsb + 8]               ; pos, CLAMPED to total - fit: keyboard
    sub dx, [pl_vsb + 10]              ; navigation and Goto move the origin
    cmp ax, dx                         ; without consulting the bars, and both
    jbe .vpos                          ; thumb routines divide pos * track by
    mov ax, dx                         ; total - unclamped, the quotient can
.vpos:                                 ; overflow 16 bits and the DIV raises
    mov [pl_vsb + 12], ax              ; INT 0 (a crash on real hardware)

    ; --- horizontal: the strip below the grid, left of the vertical bar
    mov ax, [pl_ox]
    add ax, PL_RH_W
    mov [pl_hsb + 0], ax               ; x1
    mov ax, [pl_ox]
    add ax, [pl_cw]
    sub ax, PL_VSB_W
    dec ax
    mov [pl_hsb + 4], ax               ; x2 - stops at the vertical bar
    mov ax, [pl_oy]
    add ax, [pl_ch]
    sub ax, PL_SB_H + PL_HSB_H
    mov [pl_hsb + 2], ax               ; y1
    mov ax, [pl_oy]
    add ax, [pl_ch]
    sub ax, PL_SB_H
    dec ax
    mov [pl_hsb + 6], ax               ; y2
    mov ax, [pl_bbcol]
    inc ax
    cmp ax, [pl_vcols]
    jae .htot
    mov ax, [pl_vcols]
.htot:
    sub ax, [pl_freezecol]             ; 81.70: see the vertical bar's own
    mov [pl_hsb + 8], ax               ; comment above
    mov ax, [pl_vcols]
    sub ax, [pl_freezecol]
    mov [pl_hsb + 10], ax              ; fit
    mov ax, [pl_scrollcol]
    sub ax, [pl_freezecol]
    mov dx, [pl_hsb + 8]               ; pos, clamped to total - fit, for the
    sub dx, [pl_hsb + 10]              ; vertical bar's reason above
    cmp ax, dx
    jbe .hpos
    mov ax, dx
.hpos:
    mov [pl_hsb + 12], ax

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; pl_hsb_* - A HORIZONTAL SCROLL BAR, staged for os88ui.inc
;
; os88ui.inc's bar is structurally vertical and says so: its arrow cells are
; y1+10 and y2-10, and os88ui_sbtrack takes DX and refuses CX on purpose
; (SPEC.md 13.10.5.2). This is that element transposed, and NOTHING about it
; is Sheet-specific:
;
;   * the same seven-word block (x1,y1,x2,y2,total,fit,pos), so a promoted
;     version needs no caller to change its .bss;
;   * the same part codes - PL_SB_UP/SBDOWN mean LEFT/RIGHT here, which is
;     what the vertical file would also do rather than inventing two more;
;   * the same split: this answers where the parts are and draws them, and
;     what an arrow DOES to a view stays the caller's (13.10.1);
;   * the same refusal: no thumb when everything fits or the track is too
;     short to hold one.
;
; When it moves into os88ui.inc after Sheet 2.0, the intended shape is one
; axis flag in the block (or a paired entry point) rather than two copies -
; the arithmetic below is deliberately written so that swapping x for y and
; width for height is the whole of the difference.
; =============================================================================

; =============================================================================
; pl_hsb_* - A HORIZONTAL SCROLL BAR, staged for os88ui.inc
;
; os88ui.inc's bar is structurally vertical and says so: its arrow cells are
; y1+10 and y2-10, and os88ui_sbtrack takes DX and refuses CX on purpose
; (SPEC.md 13.10.5.2, "x is never read"). This is that element transposed, and
; nothing about it is Sheet-specific:
;
;   * the same seven-word block (x1,y1,x2,y2,total,fit,pos), so a promoted
;     version needs no caller to change its .bss;
;   * the same part codes - PL_SB_UP/SBDOWN read as LEFT/RIGHT here, which
;     is what a shared two-axis file would do rather than invent two more;
;   * the same split - this answers where the parts are and draws them; what
;     an arrow DOES to a view stays the caller's (13.10.1);
;   * the same refusal - no thumb when everything fits, or when the track is
;     too short to hold one.
;
; When it moves into os88ui.inc after Sheet 2.0, the intended shape is one
; axis flag in the block rather than two copies: the arithmetic below is
; written so that swapping x for y, and width for height, is the whole of the
; difference.
; =============================================================================

; -----------------------------------------------------------------------------
; pl_hsb_load - copy the block's rect into scratch. in: BX = the block.
; Preserves everything. Every drawing routine calls this FIRST and then never
; dereferences BX again, which is what keeps the block pointer and the gfx
; rect from fighting over the same register.
; -----------------------------------------------------------------------------
pl_hsb_load:
    push ax
    mov ax, [bx + 0]
    mov [pl_hsb_x1], ax
    mov ax, [bx + 2]
    mov [pl_hsb_y1], ax
    mov ax, [bx + 4]
    mov [pl_hsb_x2], ax
    mov ax, [bx + 6]
    mov [pl_hsb_y2], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_hsb_thumb - the thumb's geometry (os88ui_sbthumb, transposed)
; in:  BX = the block
; out: CF=1 = there is no thumb; else CF=0 and [pl_hsb_tl]/[pl_hsb_tw] hold
;      its left and width, absolute. Every register preserved.
; -----------------------------------------------------------------------------
pl_hsb_thumb:
    push ax
    push cx
    push dx
    push si
    mov cx, [bx + 4]
    sub cx, [bx + 0]
    sub cx, (PL_SB_CELL + 1) * 2    ; cx = the track's width
    cmp cx, PL_SB_MINH
    jb .none
    mov ax, [bx + 10]                  ; fit
    or ax, ax
    jz .none
    cmp ax, [bx + 8]                   ; fit >= total: everything fits
    jae .none
    xor dx, dx
    mul cx                             ; dx:ax = fit * track
    div word [bx + 8]                  ; / total
    cmp ax, PL_SB_MINH
    jae .wok
    mov ax, PL_SB_MINH
.wok:
    mov si, ax                         ; si = the thumb's width
    mov ax, [bx + 12]                  ; pos
    xor dx, dx
    mul cx                             ; dx:ax = pos * track
    div word [bx + 8]                  ; / total
    add ax, [bx + 0]
    add ax, PL_SB_CELL + 1          ; ax = the thumb's left
    ; Clamp the tail inside the track: pos == total-fit can overshoot by a
    ; pixel once both divisions have truncated.
    mov dx, [bx + 4]
    sub dx, PL_SB_CELL + 1          ; dx = the track's last column
    push ax
    add ax, si
    dec ax                             ; ax = the thumb's right
    cmp ax, dx
    pop ax
    jbe .fits
    mov ax, dx
    sub ax, si
    inc ax
.fits:
    mov [pl_hsb_tl], ax
    mov [pl_hsb_tw], si
    pop si
    pop dx
    pop cx
    pop ax
    clc
    ret
.none:
    pop si
    pop dx
    pop cx
    pop ax
    stc
    ret

; -----------------------------------------------------------------------------
; pl_hsb_draw - the whole bar. in: BX = the block; gfx lock held.
; Preserves everything; leaves the pen BLACK, as os88ui_sbar does.
; -----------------------------------------------------------------------------
pl_hsb_draw:
    push ax
    push bx
    push cx
    push dx
    call pl_hsb_load

    mov al, CWHITE                     ; the arrow cells are plain white...
    call OSAPI_SET_COLOR
    mov ax, [pl_hsb_x1]
    mov bx, [pl_hsb_y1]
    mov cx, [pl_hsb_x2]
    mov dx, [pl_hsb_y2]
    call OSAPI_GFX_FILL
    mov ax, [pl_hsb_x1]                ; ...and the TRACK between them is the
    add ax, PL_SB_CELL + 1             ; grey dither, which is what the thumb
    mov cx, [pl_hsb_x2]                ; reads as a knob against
    sub cx, PL_SB_CELL + 1
    mov bx, [pl_hsb_y1]
    inc bx
    mov dx, [pl_hsb_y2]
    dec dx
    cmp ax, cx
    jg .notrack
    call OSAPI_GFX_FILL_GRAY
.notrack:

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [pl_hsb_x1]                ; the outline
    mov bx, [pl_hsb_y1]
    mov cx, [pl_hsb_x2]
    mov dx, [pl_hsb_y2]
    call OSAPI_GFX_FRAME

    mov ax, [pl_hsb_x1]                ; the two arrow-cell rules
    add ax, PL_SB_CELL
    mov bx, [pl_hsb_y1]
    mov dx, [pl_hsb_y2]
    call OSAPI_GFX_VLINE
    mov ax, [pl_hsb_x2]
    sub ax, PL_SB_CELL
    mov bx, [pl_hsb_y1]
    mov dx, [pl_hsb_y2]
    call OSAPI_GFX_VLINE

    pop dx
    pop cx
    pop bx
    pop ax
    call pl_hsb_arrows
    call pl_hsb_thdraw
    ret

; -----------------------------------------------------------------------------
; pl_hsb_arrows - the two triangles. os88ui.inc's vertical arrow is 5 rows of
; widths 1..9; this is that rotated, so 5 columns of growing height.
; in: BX = the block (already loaded into scratch by the caller).
; -----------------------------------------------------------------------------
pl_hsb_arrows:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, [pl_hsb_y1]
    add si, [pl_hsb_y2]
    shr si, 1                          ; si = the cells' vertical centre

    ; The tips point OUTWARD - `<` on the left cell and `>` on the right, not
    ; `>` and `<`. Each arrow starts one pixel in from its OUTER edge, where
    ; the tip belongs, and widens INWARD.
    mov di, [pl_hsb_x1]                ; LEFT arrow: tip at the outer edge...
    add di, 3
    mov cx, 5
    xor bx, bx
.la:
    mov ax, di
    push bx
    push cx
    mov cx, si
    sub cx, bx
    mov dx, si
    add dx, bx
    mov bx, cx
    call OSAPI_GFX_VLINE
    pop cx
    pop bx
    inc di                             ; ...widening inward
    inc bx
    loop .la

    mov di, [pl_hsb_x2]                ; RIGHT arrow: tip at ITS outer edge,
    sub di, 3                          ; widening inward the other way
    mov cx, 5
    xor bx, bx
.ra:
    mov ax, di
    push bx
    push cx
    mov cx, si
    sub cx, bx
    mov dx, si
    add dx, bx
    mov bx, cx
    call OSAPI_GFX_VLINE
    pop cx
    pop bx
    dec di
    inc bx
    loop .ra

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_hsb_thdraw - just the thumb. in: BX = the block; gfx lock held.
; -----------------------------------------------------------------------------
pl_hsb_thdraw:
    push ax
    push bx
    push cx
    push dx
    call pl_hsb_thumb
    jc .out
    ; The same two-part thumb os88ui_sbthdraw draws, transposed: a BLACK
    ; frame with a WHITE interior inside it - not a solid block, which is what
    ; makes it read as a knob against the dithered track rather than as a bar.
    mov ax, [pl_hsb_tl]
    mov cx, ax
    add cx, [pl_hsb_tw]
    dec cx
    mov bx, [pl_hsb_y1]
    add bx, 2
    mov dx, [pl_hsb_y2]
    sub dx, 2
    push ax
    mov al, CBLACK
    call OSAPI_SET_COLOR
    pop ax
    call OSAPI_GFX_FRAME
    inc ax                             ; the interior, INSIDE the border
    dec cx
    inc bx
    dec dx
    cmp ax, cx
    jg .black
    cmp bx, dx
    jg .black
    push ax
    mov al, CWHITE
    call OSAPI_SET_COLOR
    pop ax
    call OSAPI_GFX_FILL
.black:
    mov al, CBLACK                     ; the header's promise: pen left BLACK
    call OSAPI_SET_COLOR
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_hsb_hit - which part is this point on? (os88ui_sbhit, transposed)
; in:  BX = the block, CX = x, DX = y (both ABSOLUTE)
; out: AL = OS88UI_SB*; AH clobbered, everything else preserved.
; -----------------------------------------------------------------------------
pl_hsb_hit:
    push cx
    push dx
    cmp dx, [bx + 2]
    jb .none
    cmp dx, [bx + 6]
    ja .none
    cmp cx, [bx + 0]
    jb .none
    cmp cx, [bx + 4]
    ja .none
    mov ax, [bx + 0]
    add ax, PL_SB_CELL
    cmp cx, ax
    jbe .up                            ; the LEFT arrow cell
    mov ax, [bx + 4]
    sub ax, PL_SB_CELL
    cmp cx, ax
    jae .down                          ; the RIGHT arrow cell
    call pl_hsb_thumb
    jc .pgdn                           ; no thumb: the track is all page-fwd
    mov ax, [pl_hsb_tl]
    cmp cx, ax
    jb .pgup
    add ax, [pl_hsb_tw]
    cmp cx, ax
    jae .pgdn
    mov al, PL_SB_THUMB
    jmp .out
.up:
    mov al, PL_SB_UP
    jmp .out
.down:
    mov al, PL_SB_DOWN
    jmp .out
.pgup:
    mov al, PL_SB_PGUP
    jmp .out
.pgdn:
    mov al, PL_SB_PGDN
    jmp .out
.none:
    mov al, PL_SB_NONE
.out:
    pop dx
    pop cx
    ret

; -----------------------------------------------------------------------------
; pl_hsb_grab / pl_hsb_track / pl_hsb_drop - the thumb drag, the same three
; edges os88ui.inc's own uses (13.10.5), with the anchor banked as
; press_x - thumb_left so the thumb does not jump under the hand.
; -----------------------------------------------------------------------------
pl_hsb_grab:
    push ax
    call pl_hsb_thumb
    jc .no
    mov ax, cx
    sub ax, [pl_hsb_tl]
    mov [pl_hsb_dragoff], ax
    mov byte [pl_hsb_dragon], 1
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret



; -----------------------------------------------------------------------------
; pl_onmouseup - W_ONMOUSEUP: the press was released. Ends a thumb drag and,
; for the vertical bar's rate-0 grab, commits the pos the hand ended on -
; which is what "the view follows only on release" means (13.10.5.4).
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; pl_sbclick - stage 3.0a+: a press landed somewhere. If it was on either
; scroll bar, act on it and answer CF=1 ("mine"); otherwise CF=0 and the grid
; gets it. in: CX = x, DX = y (absolute), SI = the window.
;
; This is the POLICY half that os88ui.inc deliberately leaves to the caller
; (13.10.1): the element says which part was hit, and what a part MEANS to a
; sheet - one row, one screen, or take the thumb - is decided here.
; -----------------------------------------------------------------------------
pl_sbclick:
    push ax
    push bx
    push di
    call pl_sbsync

    mov bx, pl_vsb                     ; --- the vertical bar
    call os88ui_sbhit
    cmp al, PL_SB_NONE
    je .tryh
    xor ah, ah                         ; stash the part in DI: the very next
    mov di, ax                         ; instruction writes the whole of AX,
    mov ax, [pl_scrollrow]             ; so stashing it in AH (as this did)
    mov [pl_sb_oldpos], ax             ; destroyed it and every compare below
    cmp di, PL_SB_UP                   ; fell through to the thumb branch
                                        ; - which is why an arrow click did
                                        ; nothing at all
    je .vup
    cmp di, PL_SB_DOWN
    je .vdn
    cmp di, PL_SB_PGUP
    je .vpgup
    cmp di, PL_SB_PGDN
    je .vpgdn
    mov al, 2                          ; SB_THUMB. A rate of 2 ticks (~110ms)
    call os88ui_sbgrab                 ; rather than 0: the view FOLLOWS the
                                        ; thumb as it moves, throttled, which
                                        ; is 13.10.5.4's purpose - rate 0 means
                                        ; nothing moves until release, and then
                                        ; the final pos has to be recovered
                                        ; from os88ui_sbpos, an INTERNAL that
                                        ; answers in DI and wants the pointer's
                                        ; y that a release has but a drop does
                                        ; not naturally carry
    jmp .mine
.vup:
    mov ax, [pl_scrollrow]
    or ax, ax
    jz .mine
    dec ax
    jmp .vset
.vdn:
    mov ax, [pl_scrollrow]
    inc ax
    jmp .vset
.vpgup:
    mov ax, [pl_scrollrow]
    sub ax, [pl_vrows]
    jns .vset
    xor ax, ax
    jmp .vset
.vpgdn:
    mov ax, [pl_scrollrow]
    add ax, [pl_vrows]
.vset:
    call pl_setscrollrow
    jmp .mine

.tryh:
    mov bx, pl_hsb                     ; --- the horizontal bar
    call pl_hsb_hit
    cmp al, PL_SB_NONE
    je .notmine
    xor ah, ah                         ; same AX-clobber trap as the vertical
    mov di, ax                         ; branch above
    mov ax, [pl_scrollcol]
    mov [pl_sb_oldpos], ax
    cmp di, PL_SB_UP
    je .hlf
    cmp di, PL_SB_DOWN
    je .hrt
    cmp di, PL_SB_PGUP
    je .hpgup
    cmp di, PL_SB_PGDN
    je .hpgdn
    call pl_hsb_grab                   ; SB_THUMB
    jmp .mine
.hlf:
    mov ax, [pl_scrollcol]
    or ax, ax
    jz .mine
    dec ax
    jmp .hset
.hrt:
    mov ax, [pl_scrollcol]
    inc ax
    jmp .hset
.hpgup:
    mov ax, [pl_scrollcol]
    sub ax, [pl_vcols]
    jns .hset
    xor ax, ax
    jmp .hset
.hpgdn:
    mov ax, [pl_scrollcol]
    add ax, [pl_vcols]
.hset:
    call pl_setscrollcol
.mine:
    pop di
    pop bx
    pop ax
    stc
    ret
.notmine:
    pop di
    pop bx
    pop ax
    clc
    ret

; -----------------------------------------------------------------------------
; pl_setscrollrow / pl_setscrollcol - move the view to AX, clamped to the
; scrollable extent, and paint the move if it actually happened - the
; surviving rows blitted and only the vacated ones lettered (vertical), or
; the grid's own strip repainted (horizontal; OSAPI_GFX_SCROLL is
; vertical-only, SPEC.md 5.5). SI = the window.
; -----------------------------------------------------------------------------
pl_setscrollrow:
    push ax
    push bx
    push cx
    mov cx, [pl_vsb + 8]               ; total
    sub cx, [pl_vsb + 10]              ; ...minus fit = the last legal pos,
    jns .rok                           ; relative to the scrolling region
    xor cx, cx
.rok:
    add cx, [pl_freezerow]             ; 81.70: back to an ABSOLUTE row -
    cmp ax, cx                         ; every caller passes AX absolute
    jbe .rset
    mov ax, cx
.rset:
    cmp ax, [pl_freezerow]             ; 81.70: the frozen prefix is the
    jae .rset2                         ; floor - scrolling can never uncover
    mov ax, [pl_freezerow]             ; less of it than that
.rset2:
    cmp ax, [pl_scrollrow]
    je .rout                           ; no movement: draw nothing
    mov cx, [pl_scrollrow]             ; the row the view is leaving
    mov [pl_scrollrow], ax
    call pl_scrollrow_blit
    jnc .rout
    call pl_repaint                    ; the blit refused: pay the full price
.rout:
    pop cx
    pop bx
    pop ax
    ret

pl_setscrollcol:
    push ax
    push bx
    push cx
    mov cx, [pl_hsb + 8]
    sub cx, [pl_hsb + 10]
    jns .cok
    xor cx, cx
.cok:
    add cx, [pl_freezecol]             ; 81.70: the vertical bar's own
    cmp ax, cx                         ; comment applies here too
    jbe .cset
    mov ax, cx
.cset:
    cmp ax, [pl_freezecol]
    jae .cset2
    mov ax, [pl_freezecol]
.cset2:
    cmp ax, [pl_scrollcol]
    je .cout
    mov [pl_scrollcol], ax
    call pl_scrollcol_part
.cout:
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_scrollrow_blit - move the grid by whole rows with OSAPI_GFX_SCROLL
; instead of repainting every visible cell: the surviving rows are one blit,
; and only the |delta| vacated ones are lettered (~7 runs for an arrow click
; instead of ~119).
; in:  CX = the scroll row the view is leaving, SI = the window;
;      [pl_scrollrow] already holds the new one.
; out: CF=0 the view is painted; CF=1 nothing was drawn and the caller owes
;      the full repaint - the blit refused (the clip does not wholly contain
;      the rect, SPEC.md 5.5), the byte-alignment round-up would reach the
;      vertical bar, or the delta leaves no surviving band worth keeping.
; -----------------------------------------------------------------------------
pl_scrollrow_blit:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call pl_geom                       ; fresh geometry: the drag path arrives
                                        ; without pl_onclick's own pl_geom
    cmp word [pl_vcols], 0
    je .no
    cmp word [pl_vrows], 0
    je .no
    ; FROZEN ROWS REFUSE THE BLIT (81.70). OSAPI_GFX_SCROLL shifts a whole
    ; rect's pixels, and the frozen strip's must not move with the rest -
    ; cutting the rect below it is real work in the one routine whose
    ; rectangle arithmetic is hardest to get right, for a saving only a
    ; frozen sheet being scrolled would ever see. The caller already owns a
    ; refusal path (it repaints), so this takes it
    cmp word [pl_freezerow], 0
    jne .no
    mov ax, [pl_scrollrow]
    sub ax, cx                         ; ax = the delta, in rows (signed)
    mov [pl_blitdel], ax
    mov di, ax
    or di, di
    jns .abs
    neg di                             ; di = |delta|
.abs:
    cmp di, [pl_vrows]
    jae .no                            ; nothing survives: repaint instead
    ; 81.60 asked here whether every row in the band was the standard height,
    ; because a band of mixed heights does not move by delta*one-height.
    ; 81.75 gave every row one height, so the question has one answer.

    ; The rect. x1 and x2+1 must be multiples of 8 (the blit is byte-column
    ; granular, SPEC.md 5.5): x1 rounds DOWN into the row-header strip,
    ; which is redrawn whole below anyway; x2+1 rounds UP into the dead
    ; space right of the last gridline - refused if that would reach the
    ; vertical bar, whose pixels must not move.
    mov ax, [pl_ox]
    add ax, PL_RH_W
    and ax, 0xFFF8
    mov [pl_blitx1], ax
    mov ax, [pl_vcols]
    call pl_vcx                        ; each column its own width (81.56)
    add ax, [pl_ox]
    add ax, PL_RH_W                    ; ax = one past the grid's right edge
    add ax, 7
    and ax, 0xFFF8                     ; ...rounded up to the byte column
    mov dx, [pl_ox]
    add dx, [pl_cw]
    sub dx, PL_VSB_W                   ; dx = the vertical bar's x1
    cmp ax, dx
    ja .no
    dec ax
    mov [pl_blitx2], ax
    mov ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    mov [pl_blity1], ax
    mov bx, ax
    mov ax, [pl_vrows]
    mov dx, PL_RH_NORMAL               ; every row the standard, checked above
    mul dx
    add ax, bx
    dec ax
    mov [pl_blity2], ax

    mov ax, [pl_blitdel]
    mov dx, PL_RH_NORMAL
    imul dx                            ; the delta is under vrows, so AX is
    mov si, ax                         ; the whole of it: SI = signed dy
    mov ax, [pl_blitx1]
    mov bx, [pl_blity1]
    mov cx, [pl_blitx2]
    mov dx, [pl_blity2]
    call OSAPI_GFX_SCROLL              ; positive dy = content UP = view DOWN
    jc .no                             ; refused: nothing moved, fall back

    xor ax, ax                         ; the vacated rows, and only them:
    cmp word [pl_blitdel], 0           ; scrolled up = new rows on top,
    jl .vac                            ; scrolled down = at the bottom
    mov ax, [pl_vrows]
    sub ax, di
.vac:
    mov [pl_dmgr1], ax
    add ax, di
    dec ax
    mov [pl_dmgr2], ax
    xor ax, ax
    mov [pl_dmgc1], ax
    mov ax, [pl_vcols]
    dec ax
    mov [pl_dmgc2], ax
    call pl_dmgdraw
    call pl_drawsel                    ; the frame's share of the vacated
                                        ; band - its surviving part moved
                                        ; WITH the blit, to exactly where the
                                        ; frame now belongs

    mov al, CWHITE                     ; the row headers: every number
    call OSAPI_SET_COLOR               ; changed places, and their text is
    mov ax, [pl_ox]                    ; transparent, so the strip is erased
    mov bx, [pl_blity1]                ; first
    mov cx, [pl_ox]
    add cx, PL_RH_W - 1
    mov dx, [pl_blity2]
    call OSAPI_GFX_FILL
    call pl_drawrowhdrs

    call pl_sbsync                     ; ...and the thumb moved
    mov bx, pl_vsb
    call os88ui_sbar
    clc
    jmp .out
.no:
    stc
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_scrollcol_part - a horizontal scroll has no blit primitive to lean on,
; but it still owes nothing to the menu bar, the formula bar, the status bar
; or the vertical scroll bar: the grid, the column letters and the
; horizontal thumb are the whole of what moved - and no recalc pass, because
; no cell changed. SI = the window.
; -----------------------------------------------------------------------------
pl_scrollcol_part:
    push ax
    push bx
    push cx
    push dx
    mov bx, si
    call pl_geom                       ; pl_scrollrow_blit's reason
    ; THE STRIP PAST THE LAST WHOLE COLUMN (81.56): with one width it was
    ; always narrower than a column and the same each time; with each column
    ; its own, scrolling changes it, and the cells alone never cover it
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [pl_vcols]
    call pl_vcx
    add ax, [pl_ox]
    add ax, PL_RH_W
    mov cx, [pl_ox]
    add cx, [pl_cw]
    sub cx, PL_VSB_W + 1
    cmp ax, cx
    ja .nostrip
    mov bx, [pl_goy]
    add bx, PL_FB_H
    mov dx, [pl_oy]
    add dx, [pl_ch]
    sub dx, PL_SB_H + PL_HSB_H + 1
    call OSAPI_GFX_FILL
.nostrip:
    call pl_dmgfull
    call pl_dmgdraw
    call pl_drawsel
    cmp word [pl_vcols], 0
    je .nohdr
    mov al, CWHITE                     ; the column letters all changed
    call OSAPI_SET_COLOR               ; places; their text is transparent,
    mov ax, [pl_ox]                    ; so the strip is erased first
    add ax, PL_RH_W
    mov bx, [pl_goy]
    add bx, PL_FB_H
    push ax
    mov ax, [pl_vcols]
    call pl_vcx                        ; each column its own width (81.56)
    mov cx, ax
    pop ax
    add cx, ax
    dec cx
    mov dx, [pl_goy]
    add dx, PL_FB_H + PL_CH_H - 1
    call OSAPI_GFX_FILL
    call pl_drawcolhdrs
.nohdr:
    call pl_sbsync                     ; the horizontal thumb moved
    mov bx, pl_hsb
    call pl_hsb_draw
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_flrect - stage 3.0b: point the formula bar's line block at the content
; box's CURRENT screen rect. Called before every draw and every hit-test
; rather than once at startup, because the window moves and resizes and
; os88line reads the same four words for both drawing and clicking - a stale
; rect would put the caret somewhere the box no longer is. These are exactly
; the coordinates pl_drawbar frames the content box with, so the field's own
; frame lands on top of the same pixels.
; -----------------------------------------------------------------------------
pl_flrect:
    push ax
    mov ax, [pl_ox]
    add ax, PL_REF_W
    mov [pl_fline + LN_X1], ax
    mov ax, [pl_goy]
    mov [pl_fline + LN_Y1], ax
    mov ax, [pl_ox]
    add ax, [pl_cw]
    dec ax
    mov [pl_fline + LN_X2], ax
    mov ax, [pl_goy]
    add ax, PL_FB_H - 1
    mov [pl_fline + LN_Y2], ax
    pop ax
    ret

pl_drawbar:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov al, CBLACK
    call OSAPI_SET_COLOR

    ; --- reference box outline: (ox, goy) to (ox+PL_REF_W-1, goy+PL_FB_H-1) ---
    mov ax, [pl_ox]
    mov bx, ax
    add bx, PL_REF_W - 1
    mov dx, [pl_goy]
    call OSAPI_GFX_HLINE
    add dx, PL_FB_H - 1
    call OSAPI_GFX_HLINE
    mov ax, [pl_ox]
    mov bx, [pl_goy]
    mov dx, [pl_goy]
    add dx, PL_FB_H - 1
    call OSAPI_GFX_VLINE
    mov ax, [pl_ox]
    add ax, PL_REF_W - 1
    call OSAPI_GFX_VLINE               ; also the content box's own left edge

    ; --- content box outline: (ox+PL_REF_W, goy) to (ox+cw-1, goy+PL_FB_H-1) ---
    mov ax, [pl_ox]
    add ax, PL_REF_W
    mov bx, [pl_ox]
    add bx, [pl_cw]
    dec bx
    mov dx, [pl_goy]
    call OSAPI_GFX_HLINE
    add dx, PL_FB_H - 1
    call OSAPI_GFX_HLINE
    mov ax, [pl_ox]
    add ax, [pl_cw]
    dec ax
    mov bx, [pl_goy]
    mov dx, [pl_goy]
    add dx, PL_FB_H - 1
    call OSAPI_GFX_VLINE

    ; --- the reference box's interior, erased: its text is transparent and
    ; this bar repaints on every selection move WITHOUT the window-wide
    ; white fill behind it now (pl_selpaint), so it owns its own pixels ---
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [pl_ox]
    inc ax
    mov bx, [pl_goy]
    inc bx
    mov cx, [pl_ox]
    add cx, PL_REF_W - 2
    mov dx, [pl_goy]
    add dx, PL_FB_H - 2
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR

    ; --- reference text, into pl_tbuf ---
    ; Formula > Reference switches this between A1 and R1C1, which is the only
    ; place in the app that had an answer to show: the A1<->R1C1 converters
    ; already existed for SYLK's own ;E field (81.7.1), and this is what makes
    ; the setting visible rather than a file-format detail.
    mov di, pl_tbuf
    cmp byte [pl_a1style], 0
    jne .refrc
    mov ax, [pl_selcol]
    call pl_colname
    mov si, pl_colbuf
    call pl_strcpy_to_di
    mov ax, [pl_selrow]
    inc ax
    call pl_itoa
    mov si, pl_numbuf
    call pl_strcpy_to_di
    jmp .refdone
.refrc:
    mov byte [di], 'R'
    inc di
    mov ax, [pl_selrow]
    inc ax
    call pl_itoa
    mov si, pl_numbuf
    call pl_strcpy_to_di
    mov byte [di], 'C'
    inc di
    mov ax, [pl_selcol]
    inc ax
    call pl_itoa
    mov si, pl_numbuf
    call pl_strcpy_to_di
.refdone:
    mov cx, [pl_ox]
    add cx, 4
    mov dx, [pl_goy]
    add dx, 4
    mov si, pl_tbuf
    call OSAPI_FONT_STR_XPARENT

    ; --- while EDITING, the content box is a real text field: os88line owns
    ; the box, the text, the caret and the horizontal scroll, so this path
    ; hands it over entirely rather than drawing a string itself.
    cmp byte [pl_editing], 0
    je .static
    call pl_flrect
    mov si, pl_fline
    call pl_flmarg                     ; the span between the frame and the
    call os88line_draw                 ; field's 8-aligned pen, which the
    jmp .done                          ; field's own one-pass draw never
                                        ; touches

.static:
    ; --- not editing: the cell's current value/formula, as static text, into
    ; pl_tbuf+16 (past the reference text's own small span, so the two never
    ; overlap in the same shared buffer) ---
    mov di, pl_tbuf + 16
    push di                            ; pl_findcell's own DI output would
                                        ; otherwise clobber our cursor
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    call pl_findcell
    jnc .empty2
    push es
    mov es, [pl_cellseg]
    test byte [es:di+4], 1
    jnz .isformula
    cmp byte [es:di+PL_C_TYPE], PL_T_TEXT     ; stage 4.5: a label shows its
    jne .plainval2                     ; own text here, unprefixed - the '='
    mov ax, [es:di+PL_C_FOFF]          ; below is what makes a formula look
    pop es                             ; like one, and a label is not one
    pop di
    mov si, ax
    push es
    mov es, [pl_txtseg]
    jmp .copyfm
.isformula:
    mov ax, [es:di+PL_C_FOFF]                 ; formula_off
    pop es
    pop di                             ; DI = content cursor, restored
    mov byte [di], '='
    inc di
    mov si, ax
    push es
    mov es, [pl_txtseg]
.copyfm:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyfm
    pop es
    jmp .draw
.plainval2:
    call pl_cellnum                    ; pl_numbuf already holds the decimal
    pop es                             ; text; pl_itoa would overwrite it with
    pop di                             ; the low word's worth
    mov si, pl_numbuf
    call pl_strcpy_to_di
    jmp .draw
.empty2:
    pop di                             ; DI = content cursor, restored
    mov byte [di], 0
.draw:
    mov al, CWHITE                     ; the content box's interior, erased:
    call OSAPI_SET_COLOR               ; the text below is transparent and of
    mov ax, [pl_ox]                    ; varying length (the ref box's reason
    add ax, PL_REF_W + 1               ; above)
    mov bx, [pl_goy]
    inc bx
    mov cx, [pl_ox]
    add cx, [pl_cw]
    sub cx, 2
    mov dx, [pl_goy]
    add dx, PL_FB_H - 2
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov cx, [pl_ox]
    add cx, PL_REF_W + 4
    mov dx, [pl_goy]
    add dx, 3                          ; the same row os88line's own run uses
                                        ; (LN_INSET), so the field covers this
                                        ; text exactly when an edit begins
    mov si, pl_tbuf + 16
    call OSAPI_FONT_STR_XPARENT
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_drawstatus - the status bar: a single divider line above a strip at
; the very bottom of the content area, showing [pl_msg] if a command just
; set one, else the idle "Ready" real Excel's own status bar shows.
; -----------------------------------------------------------------------------
pl_drawstatus:
    push ax
    push bx
    push cx
    push dx
    push si

    mov al, CWHITE                     ; the strip's interior, erased: the
    call OSAPI_SET_COLOR               ; message is transparent text of
    mov ax, [pl_ox]                    ; varying length, and this bar repaints
    mov bx, [pl_oy]                    ; on selection moves without the
    add bx, [pl_ch]                    ; window-wide white fill behind it
    sub bx, PL_SB_H                    ; (pl_selpaint)
    inc bx
    mov cx, [pl_ox]
    add cx, [pl_cw]
    dec cx
    mov dx, [pl_oy]
    add dx, [pl_ch]
    dec dx
    call OSAPI_GFX_FILL

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [pl_ox]
    mov bx, ax
    add bx, [pl_cw]
    dec bx
    mov dx, [pl_oy]
    add dx, [pl_ch]
    sub dx, PL_SB_H
    call OSAPI_GFX_HLINE

    mov si, [pl_msg]
    or si, si
    jnz .havemsg
    mov si, pl_s_ready
.havemsg:
    mov cx, [pl_ox]
    add cx, 4
    mov dx, [pl_oy]
    add dx, [pl_ch]
    sub dx, PL_SB_H
    add dx, 4
    call OSAPI_FONT_STR_XPARENT

    ; The right-hand indicator block, which real Excel uses for NUM/CAPS/SCRL
    ; and for the word CALCULATE when Manual mode has left the sheet stale.
    ; CALCULATE takes precedence, because it is the one that means something
    ; is WRONG on screen rather than something is set on the keyboard.
    mov si, pl_s_num
    cmp byte [pl_calcmanual], 0
    je .indi
    mov si, pl_s_calcind
.indi:
    mov cx, [pl_ox]
    add cx, [pl_cw]
    sub cx, 88
    mov dx, [pl_oy]
    add dx, [pl_ch]
    sub dx, PL_SB_H
    add dx, 4
    call OSAPI_FONT_STR_XPARENT

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_drawcolhdrs - the column letters, centred in each visible column's band
; -----------------------------------------------------------------------------
pl_drawcolhdrs:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov word [pl_wcol], 0
.col:
    mov bx, [pl_wcol]
    cmp bx, [pl_vcols]
    jae .out
    mov ax, bx
    call pl_vreal_col                  ; 81.70
    call pl_colname
    mov ax, bx
    call pl_vcx                        ; each letter over its own column
    add ax, [pl_ox]                    ; (81.56)
    add ax, PL_RH_W
    mov cx, ax
    mov si, pl_colbuf
    call OSAPI_FONT_WIDTH
    push ax
    mov ax, [pl_wcol]
    call pl_vwidth
    mov dx, ax
    pop ax
    sub dx, ax
    shr dx, 1
    add cx, dx
    mov dx, [pl_goy]
    add dx, PL_FB_H
    mov si, pl_colbuf
    call OSAPI_FONT_STR_XPARENT
    mov bx, [pl_wcol]
    inc bx
    mov [pl_wcol], bx
    jmp .col
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_drawrowhdrs - the row numbers, right-aligned in PL_RH_W
; -----------------------------------------------------------------------------
pl_drawrowhdrs:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov word [pl_wrow], 0
.row:
    mov bx, [pl_wrow]
    cmp bx, [pl_vrows]
    jae .out
    mov ax, bx
    call pl_vreal_row                  ; 81.70
    inc ax
    call pl_itoa
    mov si, pl_numbuf
    call OSAPI_FONT_WIDTH
    mov cx, PL_RH_W - 4
    sub cx, ax
    add cx, [pl_ox]
    mov ax, bx
    call pl_vry                        ; its own top (81.60)...
    mov dx, ax
    mov ax, bx
    call pl_vtoff                      ; ...and as low as its cells' text
    add dx, ax
    add dx, [pl_goy]
    add dx, PL_FB_H + PL_CH_H
    mov si, pl_numbuf
    call OSAPI_FONT_STR_XPARENT
    mov bx, [pl_wrow]
    inc bx
    mov [pl_wrow], bx
    jmp .row
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_drawgrid - every cell in the damage range (pl_dmgc1..pl_dmgr2, window-
; relative - pl_dmgfull for the whole viewport) as one fixed-width
; OSAPI_FONT_RUN, number-formatted and justified per its own PL_FMT_* bits
; (stage 1.6), all spaces for empty. Sparse lookup: no bitmap.
; -----------------------------------------------------------------------------
pl_drawgrid:
    push ax
    push bx
    push cx
    push dx
    push si
    cmp word [pl_vcols], 0
    je .out
    cmp word [pl_vrows], 0
    je .out
    mov ax, [pl_dmgr1]
    mov [pl_wrow], ax
.row:
    mov ax, [pl_wrow]
    cmp ax, [pl_dmgr2]
    ja .out
    call pl_vheight                    ; THIS ROW'S OWN HEIGHT (81.60), and
    mov [pl_cellh], ax                 ; how far down it the text sits
    mov ax, [pl_wrow]
    call pl_vtoff
    mov [pl_rtoff], ax
    mov ax, [pl_dmgc1]
    mov [pl_wcol], ax
.col:
    mov ax, [pl_wcol]
    cmp ax, [pl_dmgc2]
    ja .rownext
    call pl_vwidth                     ; THIS COLUMN'S OWN WIDTH (81.56): the
    mov [pl_cellw], ax                 ; justifiers, the number fit, the blank
    mov cl, 3                          ; and the spill all read these two, so
    shr ax, cl                         ; setting them per cell is all they
    mov [pl_cellch], ax                ; need to know about it
    call pl_mkblank
    mov ax, [pl_wcol]
    call pl_vreal_col                  ; 81.70
    push ax                            ; the real column, banked - pl_vreal_
    mov ax, [pl_wrow]                  ; row only touches AX and flags, but
    call pl_vreal_row                  ; the bank costs nothing to be sure
    mov bx, ax
    pop ax
    call pl_getcell2
    jc .have
    call pl_spill                      ; ...unless a label to its left runs
    mov si, pl_tbuf                    ; on into it (81.54) - MOV keeps CF
    jc .got
    mov si, pl_blank
    jmp .got
.have:
    cmp byte [pl_showformulas], 0      ; stage 2.x Options > Formulas: On -
    je .valpath                        ; show the formula TEXT, not its
                                        ; value, matching real Excel's
                                        ; Display dialog's "Formulas" box.
                                        ; AX/BX are still this cell's own
                                        ; col/row (pl_getcell2 preserves
                                        ; both), so re-finding it costs
                                        ; nothing extra to set up.
    call pl_findcell
    jnc .valpath                       ; can't happen (getcell2 said
                                        ; occupied) - stay safe regardless
    push es
    mov es, [pl_cellseg]
    test byte [es:di+4], 1             ; HASFORMULA
    jz .noformula3
    mov ax, [es:di+PL_C_FOFF]                  ; formula_off
    pop es
    mov byte [pl_tbuf], '='
    mov di, pl_tbuf + 1
    mov si, ax
    push es
    mov es, [pl_txtseg]
.fcopy:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .fcopy
    pop es
    mov cx, di
    sub cx, pl_tbuf
    dec cx                             ; cx = chars written, excluding NUL
    cmp cx, [pl_cellch]
    jbe .fpad
    mov bx, [pl_cellch]
    mov byte [pl_tbuf + bx], 0         ; longer than a cell: truncate
    jmp .fshow
.fpad:
    mov ax, [pl_cellch]
    sub ax, cx
    jz .fshow
    mov cx, ax
.fploop:
    mov byte [di], ' '
    inc di
    loop .fploop
    mov byte [di], 0
.fshow:
    mov si, pl_tbuf
    jmp .got
.noformula3:
    pop es
.valpath:
    cmp byte [pl_curtype], PL_T_ERR    ; an error draws its NAME - the number
    je .errpath                        ; underneath it is meaningless
    cmp byte [pl_curtype], PL_T_TEXT   ; stage 4.5: a label draws its own
    je .textpath                       ; characters, not its value
    cmp byte [pl_curtype], PL_T_BOOL   ; ...and a LOGICAL its name (81.51),
    je .boolpath                       ; which no number format touches
    xor bh, bh                         ; 81.75: the format byte names every
                                       ; number format there is now
    mov bl, [pl_curfmt]
    mov ax, dx
    call pl_numfmt
    call pl_justify
    mov si, pl_tbuf
    jmp .got
.boolpath:
    mov ax, dx
    call pl_boolname                   ; -> pl_numbuf
    jmp short .centred
.errpath:
    call pl_errname                    ; -> pl_numbuf
.centred:
    mov bl, [pl_curfmt]
    call pl_justify_c                  ; General CENTRES a logical and an
    mov si, pl_tbuf                    ; error, Excel's third General rule
    jmp .got                           ; beside numbers right and labels left.
                                       ; An error sat right, "like the number
                                       ; it replaces", until 81.51
.textpath:
    call pl_text_to_numbuf             ; the arena string, clipped to the cell
    mov bl, [pl_curfmt]
    call pl_justify_t                  ; General means LEFT for a label
    mov si, pl_tbuf
.got:
    mov ax, [pl_wcol]
    call pl_vcx                        ; its own left edge (81.56)
    add ax, [pl_ox]
    add ax, PL_RH_W
    mov cx, ax
    mov ax, [pl_wrow]
    call pl_vry                        ; its own top (81.60)
    add ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    mov dx, ax                         ; DX = the cell's top, for the shade;
                                       ; the text goes pl_rtoff below it
    ; 81.75: no Shade, so no dither to draw the text transparently over -
    ; which means every cell takes FONT_RUN's one pass (6.1), and the one
    ; place in this file that had to letter transparently is gone.
    add dx, [pl_rtoff]
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_RUN
.aftertext:
    test byte [pl_curfmt], PL_FMT_BOLD
    jz .nobold
    push cx
    push dx
    inc cx
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_STR_XPARENT                ; a 1px-right overprint - the same
                                        ; double-strike trick texpad uses
                                        ; for bold on this same 8x8 font
    pop dx
    pop cx
.nobold:
    test byte [pl_curfmt], PL_FMT_UNDER
    jz .nounder
    call pl_drawunderline
.nounder:
    mov ax, [pl_wcol]
    inc ax
    mov [pl_wcol], ax
    jmp .col
.rownext:
    mov ax, [pl_wrow]
    inc ax
    mov [pl_wrow], ax
    jmp .row
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_drawlines - the cell-boundary lines over the damage range (pl_dmgc1..
; pl_dmgr2; pl_dmgfull for the whole viewport): c2-c1+2 vertical and r2-r1+2
; horizontal, each a degenerate (1px) OSAPI_GFX_FILL rectangle spanning just
; the damaged cells. Drawn AFTER pl_drawgrid: OSAPI_FONT_RUN's opaque erase
; is exactly one cell wide and would otherwise paint back over a line drawn
; first.
; -----------------------------------------------------------------------------
pl_drawlines:
    push ax
    push bx
    push cx
    push dx
    cmp byte [pl_gridlines], 0         ; stage 2.x Options > Gridlines: Off
    je .out                            ; skips this whole pass, same as real
                                        ; Excel's Display dialog
    cmp word [pl_vcols], 0
    je .out
    cmp word [pl_vrows], 0
    je .out
    mov al, CBLACK
    call OSAPI_SET_COLOR

    mov ax, [pl_dmgr1]                 ; the damaged rows' pixel span, each
    call pl_vry                        ; its own height (81.60)...
    add ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    mov [pl_ly1], ax
    mov ax, [pl_dmgr2]
    inc ax
    call pl_vry
    add ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    dec ax
    mov [pl_ly2], ax

    mov ax, [pl_dmgc1]                 ; ...and the damaged columns', each
    call pl_vcx                        ; its own width (81.56)
    add ax, [pl_ox]
    add ax, PL_RH_W
    mov [pl_lx1], ax
    mov ax, [pl_dmgc2]
    inc ax
    call pl_vcx
    add ax, [pl_ox]
    add ax, PL_RH_W
    dec ax
    mov [pl_lx2], ax

    mov ax, [pl_dmgc1]
    mov [pl_wcol], ax
.vline:
    mov ax, [pl_wcol]
    mov dx, [pl_dmgc2]
    inc dx
    cmp ax, dx
    ja .vdone
    call pl_vcx
    add ax, [pl_ox]
    add ax, PL_RH_W
    mov cx, ax
    mov bx, [pl_ly1]
    mov dx, [pl_ly2]
    call OSAPI_GFX_FILL
    mov ax, [pl_wcol]
    inc ax
    mov [pl_wcol], ax
    jmp .vline
.vdone:
    mov ax, [pl_dmgr1]
    mov [pl_wrow], ax
.hline:
    mov ax, [pl_wrow]
    mov dx, [pl_dmgr2]
    inc dx
    cmp ax, dx
    ja .hdone
    call pl_vry
    add ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    mov bx, ax
    mov dx, ax
    mov ax, [pl_lx1]
    mov cx, [pl_lx2]
    call OSAPI_GFX_FILL
    mov ax, [pl_wrow]
    inc ax
    mov [pl_wrow], ax
    jmp .hline
.hdone:
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
pl_drawsel:
    push ax
    push bx
    push cx
    push dx
    call pl_selrect                    ; stage 3.0a: -> pl_selc1..pl_selr2,
                                        ; already ordered

    ; --- clip the block's own cell rect to the visible viewport. Each edge is
    ; clamped rather than the whole block rejected, so a selection that runs
    ; off the screen still draws the part that shows (Excel's own behaviour,
    ; and what a drag past the edge needs). 81.70: pl_vclip_col/row do both
    ; edges at once, frozen-aware, the same clamp pl_updsel needs too
    mov ax, [pl_selc1]
    mov bx, [pl_selc2]
    call pl_vclip_col
    jnc .out
    mov [pl_wcol], ax
    mov [pl_selvc2], bx

    mov ax, [pl_selr1]
    mov bx, [pl_selr2]
    call pl_vclip_row
    jnc .out
    mov [pl_wrow], ax
    mov [pl_selvr2], bx

    ; --- cell coords -> pixels
    mov ax, [pl_wcol]
    call pl_vcx                        ; each column its own width (81.56)
    add ax, [pl_ox]
    add ax, PL_RH_W
    mov [pl_selx1], ax

    mov ax, [pl_selvc2]
    inc ax                             ; one past the last column...
    call pl_vcx                        ; each column its own width (81.56)
    add ax, [pl_ox]
    add ax, PL_RH_W
    dec ax                             ; ...minus a pixel = its right edge
    mov [pl_selx2], ax

    mov ax, [pl_wrow]
    call pl_vry                        ; each row its own height (81.60)
    add ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    mov [pl_sely1], ax

    mov ax, [pl_selvr2]
    inc ax
    call pl_vry
    add ax, [pl_goy]
    add ax, PL_FB_H + PL_CH_H
    dec ax
    mov [pl_sely2], ax

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [pl_selx1]
    mov bx, [pl_sely1]
    mov cx, [pl_selx2]
    mov dx, [pl_sely2]
    call OSAPI_GFX_FRAME
    call pl_selsingle                  ; a single cell keeps the plain 1px
    jc .out                            ; frame it has always had; a real
                                        ; RANGE gets a second, inset frame so
                                        ; it reads as a block rather than as
                                        ; one very large cell (this OS has no
                                        ; wide-pen primitive, and XOR fill
                                        ; over the text would be worse - see
                                        ; os88ui_btn's own note on XOR)
    mov ax, [pl_selx1]
    inc ax
    mov bx, [pl_sely1]
    inc bx
    mov cx, [pl_selx2]
    dec cx
    mov dx, [pl_sely2]
    dec dx
    cmp ax, cx                         ; degenerate after the inset?
    jae .out
    cmp bx, dx
    jae .out
    call OSAPI_GFX_FRAME
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; Sheet's own in-window menu bar (see the PL_MBAR_H section comment for why
; this exists instead of OS88_MENUSET): File > New / Open... / Save / Save
; As..., Edit > Cut/Copy/Paste/..., Format > dialogs, Data > Sort Column,
; Sheets > switch, Options > Display toggles, Macro > Run, Help > About.
; =============================================================================

; -----------------------------------------------------------------------------
; pl_mtab_calc - measure each menu title's pixel width once (pl_mw), so
; pl_mboxof never has to call OSAPI_FONT_WIDTH itself on every click/paint.
; Called once from pl_entry - the titles are fixed strings, so this never
; needs to run again.
; -----------------------------------------------------------------------------
pl_mtab_calc:
    push ax
    push bx
    push cx
    push si
    push di
    xor cx, cx
.loop:
    cmp cx, PL_MENU_N
    jae .done
    mov ax, cx
    mov bx, 6
    mul bx
    mov bx, ax
    mov si, [pl_mtab + bx]
    call OSAPI_FONT_WIDTH
    mov di, cx
    shl di, 1
    mov [pl_mw + di], ax
    inc cx
    jmp .loop
.done:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mboxof - AL = menu index -> pl_mbx1/pl_mbx2 (screen-absolute box
; bounds, using the raw [pl_ox]/[pl_oy], not the grid-shifted [pl_goy]).
; preserves everything
; -----------------------------------------------------------------------------
pl_mboxof:
    push ax
    push bx
    push cx
    push dx
    push di
    mov cl, al
    xor ch, ch
    mov dx, [pl_ox]
    xor bx, bx
.loop:
    cmp bx, cx
    jae .found
    mov di, bx
    shl di, 1
    mov ax, [pl_mw + di]
    add ax, PL_MPAD*2
    add dx, ax
    inc bx
    jmp .loop
.found:
    mov [pl_mbx1], dx
    mov di, bx
    shl di, 1
    mov ax, [pl_mw + di]
    add ax, PL_MPAD*2
    add dx, ax
    dec dx
    mov [pl_mbx2], dx
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mbar_draw - the whole menu bar strip: white ground, black rule under
; it, every title (inverted if it is [pl_mopen]). Monochrome-safe black/
; white/invert, matching every other Sheet dialog in this app, rather than
; real Excel 2.1's cyan bar
; (LIBRARY/documentation/screenshots/excel/excel_main.png) - this OS
; supports 1bpp Hercules/CGA-mono adapters Sheet's own chrome has stayed
; safe for since stage 1.8, and introducing a new color here would be the
; first thing in this app to depend on one existing at all.
; -----------------------------------------------------------------------------
pl_mbar_draw:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [pl_ox]
    mov bx, [pl_oy]
    mov cx, [pl_ox]
    add cx, [pl_cw]
    dec cx
    mov dx, [pl_oy]
    add dx, PL_MBAR_H - 1
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [pl_ox]
    mov bx, [pl_ox]
    add bx, [pl_cw]
    dec bx
    mov dx, [pl_oy]
    add dx, PL_MBAR_H - 1
    call OSAPI_GFX_HLINE
    mov word [pl_mli], 0
    mov word [pl_mto], 0
.loop:
    mov ax, [pl_mli]
    cmp ax, PL_MENU_N
    jae .done
    mov al, [pl_mli]
    call pl_mboxof
    mov al, [pl_mli]
    cmp al, [pl_mopen]
    jne .normal
    mov ax, [pl_mbx1]
    mov bx, [pl_oy]
    mov cx, [pl_mbx2]
    mov dx, [pl_oy]
    add dx, PL_MBAR_H - 1
    call OSAPI_GFX_FILL
    mov al, CWHITE
    call OSAPI_SET_COLOR
    jmp .drawtitle
.normal:
    mov al, CBLACK
    call OSAPI_SET_COLOR
.drawtitle:
    mov bx, [pl_mto]
    mov si, [pl_mtab + bx]
    mov cx, [pl_mbx1]
    add cx, PL_MPAD
    mov dx, [pl_oy]
    add dx, 3
    call OSAPI_FONT_STR_XPARENT
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [pl_mto]
    add ax, 6
    mov [pl_mto], ax
    mov ax, [pl_mli]
    inc ax
    mov [pl_mli], ax
    jmp .loop
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mbar_hit - CX,DX (screen-absolute) -> AL = menu index or PL_M_NONE
; -----------------------------------------------------------------------------
pl_mbar_hit:
    push bx
    push cx
    push dx
    mov ax, [pl_oy]
    cmp dx, ax
    jb .no
    add ax, PL_MBAR_H - 1
    cmp dx, ax
    ja .no
    mov word [pl_mli], 0
.loop:
    mov ax, [pl_mli]
    cmp ax, PL_MENU_N
    jae .no
    mov al, [pl_mli]
    call pl_mboxof
    cmp cx, [pl_mbx1]
    jb .next
    cmp cx, [pl_mbx2]
    ja .next
    mov ax, [pl_mli]
    jmp .out
.next:
    mov ax, [pl_mli]
    inc ax
    mov [pl_mli], ax
    jmp .loop
.no:
    mov ax, PL_M_NONE
.out:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_mdrop_geo - compute the open menu's ([pl_mopen]) dropdown rect into
; pl_mrx1/mry1/mrx2/mry2, and stash its items ptr/count into pl_mip/
; pl_mcnt for pl_mdrop_draw and pl_mitem_hit to share. Width is the widest
; item label (skipping a leading MENU_DIS byte when measuring); height is
; item_count*PL_MI_H plus a little top/bottom padding. No sliding-under-
; the-screen-edge case (unlike word.asm's wd_mgeo) - Sheet's own dropdowns
; are short enough that this has never yet needed one.
; -----------------------------------------------------------------------------
pl_mdrop_geo:
    push ax
    push bx
    push cx
    push si
    mov al, [pl_mopen]
    call pl_mboxof
    mov ax, [pl_mbx1]
    mov [pl_mrx1], ax
    mov ax, [pl_oy]
    add ax, PL_MBAR_H
    mov [pl_mry1], ax

    mov bl, [pl_mopen]
    xor bh, bh
    mov ax, bx
    mov cx, 6
    mul cx
    mov bx, ax
    mov si, [pl_mtab + bx + 2]
    mov [pl_mip], si
    mov ax, [pl_mtab + bx + 4]
    mov [pl_mcnt], ax

    mov word [pl_mmaxw], 0
    mov word [pl_mli], 0
.wloop:
    mov ax, [pl_mli]
    cmp ax, [pl_mcnt]
    jae .wdone
    mov bx, [pl_mli]
    shl bx, 1
    mov si, [pl_mip]
    add si, bx
    mov si, [si]
    mov al, [si]
    cmp al, MENU_DIS
    jne .measure
    inc si
.measure:
    call OSAPI_FONT_WIDTH
    cmp ax, [pl_mmaxw]
    jbe .wnext
    mov [pl_mmaxw], ax
.wnext:
    mov ax, [pl_mli]
    inc ax
    mov [pl_mli], ax
    jmp .wloop
.wdone:
    mov ax, [pl_mmaxw]
    add ax, PL_MPAD*2 + PL_MCHKW
    mov bx, [pl_mrx1]
    add bx, ax
    dec bx
    mov [pl_mrx2], bx

    mov ax, [pl_mcnt]
    mov cx, PL_MI_H
    mul cx
    add ax, 4
    add ax, [pl_mry1]
    dec ax
    mov [pl_mry2], ax

    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mdrop_draw - paint the open dropdown from pl_mrx1/y1/x2/y2 + pl_mip/
; pl_mcnt (pl_mdrop_geo must already have run). White panel, black frame,
; one row per item at PL_MI_H apart: disabled items (MENU_DIS) drawn under
; OSAPI_GFX_PEN's disabled (grey) pen; the hot item ([pl_mhi]) drawn
; inverted. Redraws the WHOLE panel on every highlight change rather than
; word.asm's per-row XOR - Sheet's dropdowns are short lists, so this is
; cheap enough not to need that finer granularity.
; -----------------------------------------------------------------------------
pl_mdrop_draw:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [pl_mrx1]
    mov bx, [pl_mry1]
    mov cx, [pl_mrx2]
    mov dx, [pl_mry2]
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [pl_mrx1]
    mov bx, [pl_mry1]
    mov cx, [pl_mrx2]
    mov dx, [pl_mry2]
    call OSAPI_GFX_FRAME
    mov word [pl_mli], 0
.loop:
    mov ax, [pl_mli]
    cmp ax, [pl_mcnt]
    jae .done
    mov cx, PL_MI_H
    mul cx
    add ax, [pl_mry1]
    add ax, 2
    mov [pl_mry_row], ax
    mov bx, [pl_mip]
    mov cx, [pl_mli]
    shl cx, 1
    add bx, cx
    mov si, [bx]
    mov byte [pl_mchk], 0
    mov al, [si]
    cmp al, PL_MENU_CHK               ; stage 3.0c: the same relabel-by-
    jne .notchk                       ; repointing trick MENU_DIS documents,
    inc si                            ; for a mark rather than for grey
    mov byte [pl_mchk], 1
    mov al, [si]
.notchk:
    cmp al, MENU_DIS
    jne .live
    inc si
    stc
    call OSAPI_GFX_PEN
    jmp .drawtext
.live:
    mov ax, [pl_mli]
    cmp al, [pl_mhi]
    jne .plain
    mov ax, [pl_mrx1]
    inc ax
    mov bx, [pl_mry_row]
    mov cx, [pl_mrx2]
    dec cx
    mov dx, [pl_mry_row]
    add dx, PL_MI_H - 1
    push ax
    mov al, CBLACK
    call OSAPI_SET_COLOR
    pop ax
    call OSAPI_GFX_FILL
    clc
    call OSAPI_GFX_PEN
    mov al, CWHITE
    call OSAPI_SET_COLOR
    jmp .drawtext
.plain:
    clc
    call OSAPI_GFX_PEN
.drawtext:
    cmp byte [pl_mchk], 0
    je .nochk
    push ax                           ; the check: A SOLID SQUARE and not a
    push bx                           ; tick (SPEC.md 81.30), because a thin
    push cx                           ; diagonal reads as scattered pixels on
    push dx                           ; the two 1bpp adapters (SPEC.md 39.4) -
    mov ax, [pl_mrx1]                 ; os88ui_chk's own mark and its own
    add ax, PL_MCHKX                  ; reason. The pen is already the right
    mov bx, [pl_mry_row]              ; colour, set by the highlight branch
    add bx, PL_MCHKY                  ; above, so the mark inverts with the row
    mov cx, ax                        ; exactly as the text does
    add cx, PL_MCHKS - 1
    mov dx, bx
    add dx, PL_MCHKS - 1
    call OSAPI_GFX_FILL
    pop dx
    pop cx
    pop bx
    pop ax
.nochk:
    mov cx, [pl_mrx1]
    add cx, PL_MPAD + PL_MCHKW
    mov dx, [pl_mry_row]
    call OSAPI_FONT_STR_XPARENT
    mov ax, [pl_mli]
    inc ax
    mov [pl_mli], ax
    jmp .loop
.done:
    clc
    call OSAPI_GFX_PEN                 ; leave the pen live (its own "put it
                                        ; back" rule) for whatever draws next
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mitem_hit - CX,DX (screen-absolute) -> AL = item index, or PL_M_NONE
; if outside the panel, on a separator gap, or on a disabled (MENU_DIS)
; item - a disabled row cannot become the hot item at all, which is what
; lets pl_mdrop_draw assume a highlighted row is always live.
; -----------------------------------------------------------------------------
pl_mitem_hit:
    push bx
    push si
    cmp cx, [pl_mrx1]
    jb .no
    cmp cx, [pl_mrx2]
    ja .no
    cmp dx, [pl_mry1]
    jb .no
    cmp dx, [pl_mry2]
    ja .no
    mov ax, dx
    sub ax, [pl_mry1]
    sub ax, 2
    js .no
    push dx
    xor dx, dx
    mov bx, PL_MI_H
    div bx
    pop dx
    cmp ax, [pl_mcnt]
    jae .no
    mov bx, [pl_mip]
    push cx
    mov cx, ax
    shl cx, 1
    add bx, cx
    pop cx
    mov si, [bx]
    cmp byte [si], MENU_DIS
    je .no
    jmp .out
.no:
    mov ax, PL_M_NONE
.out:
    pop si
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_mclose - close the open dropdown and repaint what it covered. Always a
; full pl_repaint (menu bar included, since pl_drawall draws it first) -
; Sheet's own grid redraw is cheap, unlike word.asm's wd_mrepair, which
; repaints piecewise specifically to avoid a full-document reflow.
; -----------------------------------------------------------------------------
pl_mclose:
    push ax
    push si
    mov byte [pl_mopen], PL_M_NONE
    mov byte [pl_mhi], PL_M_NONE
    mov si, [pl_ownwin]
    call pl_repaint
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mtrack - the press-drag-release gesture (word.asm's wd_mtrack pattern:
; a tight OSAPI_MOUSE poll with an unlock/yield/relock between reads, never
; W_ONDRAG - see the PL_MBAR_H section comment for why). in: AL = menu
; index to open, SI = window ptr (this callback's own, untouched SI - see
; pl_onclick); called with the gfx lock already held, exactly the state
; the unlock/relock pair expects.
; -----------------------------------------------------------------------------
pl_mtrack:
    push ax
    push bx
    push si
    mov [pl_mopen], al
    mov byte [pl_mhi], PL_M_NONE
    call pl_mdrop_geo
    call pl_mbar_draw
    call pl_mdrop_draw
.loop:
    call OSAPI_GFX_UNLOCK
    call OSAPI_GET_TICKS
    mov bx, ax
.spin:
    call OSAPI_TASK_YIELD
    call OSAPI_GET_TICKS
    cmp ax, bx
    je .spin
    call OSAPI_GFX_LOCK
    call OSAPI_MOUSE                   ; cx=x, dx=y, al=buttons
    test al, 1
    jz .release
    call pl_mitem_hit
    cmp al, [pl_mhi]
    je .loop
    mov [pl_mhi], al
    call pl_mdrop_draw
    jmp .loop
.release:
    call pl_mitem_hit
    cmp al, PL_M_NONE
    je .closeonly
    mov ah, [pl_mopen]
    push ax
    call pl_mclose
    pop ax
    call pl_mfire
    jmp .out
.closeonly:
    call pl_mclose
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mfire - AH = menu index, AL = item index -> dispatch. Sets SI to
; [pl_ownwin] unconditionally before calling anything: this runs from
; pl_mtrack's own polling loop, not a kernel AM_ONCMD callback, so nothing
; here can assume SI already IS the window the way pl_oncmd's old kernel-
; supplied SI always was.
; -----------------------------------------------------------------------------
pl_mfire:
    push ax
    push si
    mov si, [pl_ownwin]
    ; WHAT UNDO CANNOT REVERSE ENDS IT (81.57): a snapshot older than a
    ; format, a name, a note or a macro would put them back too, silently.
    ; Excel 2.1 cannot undo any of these either
    cmp ah, PL_MI_FORMAT               ; Format, all of it
    je .udrop
    cmp ah, PL_MI_MACRO                ; Macro
    je .udrop
    cmp ah, PL_MI_FORMULA              ; Formula: Define Name and Note
    jne .ukept
    cmp al, 3
    je .udrop
    cmp al, 4
    jne .ukept
.udrop:
    call pl_undo_drop
.ukept:
    cmp ah, PL_MI_FILE
    je .file
    cmp ah, PL_MI_EDIT
    je .edit
    cmp ah, PL_MI_FORMAT
    je .format
    cmp ah, PL_MI_DATA
    je .data
    cmp ah, PL_MI_OPTIONS
    je .options
    cmp ah, PL_MI_MACRO
    je .macro
    jmp .out
.file:
    or al, al
    jnz .fopen
    mov al, PL_FDK_NEW
    call pl_fdlg_open_r
    jmp .out
.fopen:
    cmp al, 1
    jne .fsave
    mov al, FDLG_OPEN
    call pl_dlg
    jmp .out
.fsave:
    cmp al, 2
    jne .fsaveas
    call pl_dowrite
    mov si, [pl_ownwin]
    call pl_repaint
    jmp .out
.fsaveas:
    mov al, PL_FDK_SAVEFMT             ; 3, and the last item. ASK for the
    call pl_fdlg_open_r                  ; format, then name it - the format used
    jmp .out                           ; to be whatever extension the typed
                                       ; name happened to end in
.edit:
    call pl_docmd_edit
    jmp .out
.format:
    call pl_docmd_format
    jmp .out
; 81.75: without the database, Data is whatever is left of it - Sort, then
; the three chart items - and the items RENUMBER rather than being greyed.
; A menu showing six commands that cannot happen is worse than a short one,
; and SPEC.md 47 wants a fact to grey on; "not in this build" is not one the
; user can act on. With nothing left the menu itself is gone and PL_MI_DATA
; is 0xFD, so this arm is unreachable rather than absent.
.data:
    jmp .out
.options:
    call pl_docmd_options
    jmp .out
.macro:                                ; 81.75: PL_MI_MACRO is 0xFE in this
    jmp .out                           ; arm, so nothing can reach it
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_docmd_options - AL = 0 Gridlines / 1 Formulas: flip the flag, re-point
; the item's own string to the matching On/Off label (the same relabel-by-
; repointing idea documented above MENU_DIS in apps/os88api.inc, applied to
; pl_i_options directly rather than through the kernel), repaint.
; -----------------------------------------------------------------------------
pl_docmd_options:
    push si
    cmp al, 3                          ; 81.75: four items. Protect Document
    je .ref                            ; went with cell protection, Freeze
    cmp al, 2                          ; Panes with the row-height walk, and
    je .calc                           ; Reference came the other way when the
    or al, al                          ; Formula menu emptied
.formulas:
    xor byte [pl_showformulas], 1
    cmp byte [pl_showformulas], 0
    je .foff
    mov word [pl_i_options+2], pl_it_form_on
    jmp .repaint
.foff:
    mov word [pl_i_options+2], pl_it_form_off
    jmp .repaint
    .ref:
    xor byte [pl_a1style], 1          ; the item relabels itself, which is the
    mov word [pl_i_options+6], pl_it_ref_a1
    cmp byte [pl_a1style], 0
    je .repaint
    mov word [pl_i_options+6], pl_it_ref_rc
    jmp .repaint
.calc:
    mov al, PL_FDK_CALC
    call pl_fdlg_open_r
    pop si
    ret
; FREEZE PANES (81.70). Excel's own: the split is AT the active cell, so
; everything ABOVE and LEFT of it stops scrolling, and choosing the item
; again unfreezes. The ANCHOR is the active cell, not the extent - a
; dragged range freezes at the corner it was dragged FROM.
.freeze:
    mov ax, [pl_freezecol]
    or ax, [pl_freezerow]
    jnz .unfreeze
    mov ax, [pl_selcol]
    or ax, [pl_selrow]
    jnz .dofreeze
    mov word [pl_msg], pl_s_frz_at_a1  ; A1 has nothing above or left of it
    jmp .repaint                       ; to freeze: REFUSED in its own words
                                        ; (47), not silently done as nothing
.dofreeze:
    mov ax, [pl_selcol]
    mov [pl_freezecol], ax
    mov ax, [pl_selrow]
    mov [pl_freezerow], ax
    mov ax, [pl_scrollcol]             ; the scrolling region can never start
    cmp ax, [pl_freezecol]             ; inside the frozen prefix - every
    jae .fcok                          ; other reader takes that invariant
    mov ax, [pl_freezecol]             ; for granted
    mov [pl_scrollcol], ax
.fcok:
    mov ax, [pl_scrollrow]
    cmp ax, [pl_freezerow]
    jae .frok
    mov ax, [pl_freezerow]
    mov [pl_scrollrow], ax
.frok:
    call pl_frzmark
    jmp .repaint
.unfreeze:
    mov word [pl_freezecol], 0
    mov word [pl_freezerow], 0
    call pl_frzmark
    jmp .repaint
.repaint:
    mov si, [pl_ownwin]
    call pl_repaint
    pop si
    ret

; -----------------------------------------------------------------------------
; pl_docmd_help - the only Help item, About Sheet...
; -----------------------------------------------------------------------------
pl_abdismiss:
    cmp byte [pl_abon], 0
    je .none
    push bx
    push si
    mov byte [pl_abon], 0
    mov bx, [pl_ownwin]
    mov si, bx
    call OSAPI_WM_CLIP_SET          ; nothing has armed a region for a click
    jc .gone                        ; or a key (SPEC.md 11.3)
    call pl_repaint                 ; ...which white-fills and draws it all
.gone:
    pop si
    pop bx
    stc
    ret
.none:
    clc
    ret

; -----------------------------------------------------------------------------
; pl_docmd_format - Format menu item AL opens the matching dialog (stage
; 1.8: real Excel's own Format menu is dialog-per-verb - Number.../
; Alignment.../Font... - not a flat immediate-apply list, per the reference
; screenshots at
; LIBRARY/documentation/screenshots/excel/dialog_{number,alignment,font}.png;
; Sheet's menu now matches that shape, see the item table below). AL is 0
; Number, 1 Alignment, 2 Font - the same order pl_fdlg_open expects.
; -----------------------------------------------------------------------------
; pl_docmd_format - Format menu item AL: 0 Number/1 Alignment/2 Font map
; straight onto pl_fdlg_open's own kind numbers. 3 Border opens the
; separate pl_bdlg_* checkbox dialog, 4 Cell Protection is kind
; PL_FDK_PROT, and 5 Row Height/6 Column Width are pl_idlg_open's typed
; fields - pl_fdlg_open's own kinds 5/6, the presets they replaced, are
; retired (81.59).
pl_docmd_format:
    ; 81.75: four items - Number, Alignment, Font, Column Width. Number is the
    ; four-way radio again, because the scrolling list 81.55 gave it was there
    ; to offer the seventeen formats the side table held, and the side table
    ; has gone. Border, Cell Protection and Row Height went with their
    ; features.
    cmp al, 3
    jne .fdlg
    mov al, PL_ID_COLW
    call pl_idlg_open_r
    ret
.fdlg:                                 ; 0 Number / 1 Alignment / 2 Font are
    call pl_fdlg_open_r                ; pl_fdlg's own kinds 0..2, in order
    ret

; -----------------------------------------------------------------------------
; pl_docmd_edit - Edit menu item AL. 0 is "Can't Undo" (MENU_DIS - the
; kernel never sends a click for a disabled item, so index 0 is dead here,
; not a bug). 1 Cut, 2 Copy, 3 Paste use the real system clipboard
; (OSAPI_CLIP_*). 4 Clear. 5 Delete... / 6 Insert... both open the
; Row/Column picker (pl_fdlg_* kinds 4 and 3 - see the dialog engine's own
; comment for why one engine now serves 5 kinds). 7 Fill Right / 8 Fill
; Down are deliberately scoped down from real Excel: fill acts on just the
; one adjacent cell.
;
; THIS USED TO SAY "no range selection exists in this app (W_ONDRAG is
; missing... so a real rectangular selection was ruled out)". Stage 3.0a
; built one - drag, shift+click and shift+arrows - and the note stayed, in
; three places (here, pl_rowcol_op and pl_docmd_sortcol) all pointing at
; this one as the source. The BEHAVIOUR those two describe is still true;
; the REASON is not, and a reason that has expired is worse than none,
; because it says the thing cannot be done.
; -----------------------------------------------------------------------------
pl_docmd_edit:
    or al, al                          ; 0 is Undo or Redo when there is a
    jnz .notundo                       ; snapshot, and MENU_DIS - so it never
    call pl_undo_do                    ; arrives - when there is not (81.57)
    ret
.notundo:
    push ax                            ; the commands that act at once take
    mov ah, al                         ; their snapshot here; the dialogs'
    mov al, PL_UL_CUT                  ; take it at OK, in pl_fdlg_apply
    cmp ah, 2
    je .snap
    mov al, PL_UL_PASTE
    cmp ah, 4
    je .snap
    jmp short .nosnap
.snap:
    call pl_undo_begin
    pop ax
    call .cmd
    call pl_undo_end
    ret
.nosnap:
    pop ax
.cmd:
    cmp al, 2                          ; 1 Can't Repeat is MENU_DIS, so it
    je .cut                            ; never arrives
    cmp al, 3
    je .copy
    cmp al, 4
    je .paste
    cmp al, 5
    je .clear
    ret                                ; THERE WAS A `cmp al, 9 / je .sort`
                                       ; HERE, left behind when Sort moved to
                                       ; the Data menu - unreachable from a
                                       ; nine-item menu and therefore invisible.
                                       ; Adding three items made index 9 into
                                       ; Insert..., so the orphan would have
                                       ; turned Insert into Sort, silently, on
                                       ; a menu nobody had changed
.cut:
    call pl_docmd_cut
    ret
.copy:
    call pl_docmd_copy
    ret
.paste:
    mov byte [pl_ps_mode], PL_PS_ALL
    call pl_docmd_paste
    ret
.clear:
    mov al, PL_FDK_CLEAR
    call pl_fdlg_open_r
    ret

; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; pl_ps_src - the SOURCE cell for the block position being pasted into.
; out: AX = column, BX = row. The block walker keeps (pl_pb_x, pl_pb_y) as the
; offset within the block, and pl_clip_col/pl_clip_row is where the block was
; copied FROM, so the source is just the two added - the same arithmetic the
; reference shift does in the other direction.
;
; Only meaningful when pl_clip_valid: an external clipboard has text and no
; cells behind it. Every caller here is reached only after that test.
; -----------------------------------------------------------------------------
pl_ps_src:
    mov ax, [pl_clip_col]
    add ax, [pl_pb_x]
    mov bx, [pl_clip_row]
    add bx, [pl_pb_y]
    ret

; -----------------------------------------------------------------------------
; pl_ps_srcsheet / pl_ps_mysheet - step into the sheet the block was COPIED
; from, and back out again. (81.45.4)
;
; An address is not a cell here: pl_findcell, pl_bt_get and pl_nt_get all pack
; pl_cursheet into the row word, so reading the source cell's format, border or
; note while standing on the DESTINATION sheet reads whatever happens to live
; at that address on the wrong grid. Copy on Sheet1, switch to Sheet2, Paste
; Special > Formats, and the formats came from Sheet2's own cell.
;
; The pair is symmetric and nests nowhere - one caller enters, does its reads
; and leaves before writing anything, because the WRITES go to the current
; sheet and only the READS belong to the other one.
;
; TWO RULES, AND BREAKING EITHER IS SILENT. The banked sheet lives in ONE bss
; word, so (1) every path that enters must leave - a leave without a matching
; enter restores whatever the slot held last and moves the USER's sheet under
; them, which is how an experiment here left the grid showing Sheet1 after a
; paste onto Sheet2; and (2) the two callers must never nest, or the inner
; enter overwrites the outer's bank. They do not: pl_paste_cell reaches
; pl_ps_valtext for PL_PS_VAL and pl_ps_props for ALL/FORMATS/NOTES, and no
; mode reaches both.
; -----------------------------------------------------------------------------
pl_ps_srcsheet:
    push ax
    mov ax, [pl_cursheet]
    mov [pl_ps_ownsheet], ax
    mov ax, [pl_clip_sheet]
    mov [pl_cursheet], ax
    pop ax
    ret
pl_ps_mysheet:
    push ax
    mov ax, [pl_ps_ownsheet]
    mov [pl_cursheet], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_ps_props - copy the source cell's PROPERTIES onto the destination, which
; parts depending on [pl_ps_mode]: the format byte and the border for All and
; Formats, the note for All and Notes.
;
; The destination is wherever pl_selcol/pl_selrow point, which pl_paste_cell
; has just set. A source cell with no record contributes nothing rather than
; writing a default over what is already there - "paste formats" from an empty
; cell is not "clear the formats".
; -----------------------------------------------------------------------------
pl_ps_props:
    push ax
    push bx
    push cx
    push dx
    push si                           ; SI is kept because the version this
    push di                           ; replaced kept it, and a caller may
    push es                           ; have come to rely on that
    ; 81.75: what a paste carries besides the CONTENTS is the format byte, and
    ; that is now all of it - there are no borders, no protection bits and no
    ; notes left for the five Paste Special modes to choose between, so there
    ; is no mode either. The source is read standing on the sheet the block
    ; came from and the write goes to the current one, which is 81.45.4's
    ; ordering rule and the reason the two halves do not interleave.
    xor cx, cx
    call pl_ps_srcsheet
    call pl_ps_src
    call pl_findcell
    jnc .done                         ; no source record: nothing to copy
    mov es, [pl_cellseg]
    mov dl, [es:di+PL_C_FMT]
    mov cl, 1
.done:
    call pl_ps_mysheet                ; ...and back, before anything is written
    or cl, cl
    jz .out
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    call pl_findcell
    jnc .out                          ; no DESTINATION record either - the
    mov es, [pl_cellseg]              ; same scope limit pl_fdlg_apply
    mov [es:di+PL_C_FMT], dl          ; documents for the Format dialogs
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_ps_valtext - the SOURCE cell's value, as text, into pl_editbuf: what
; "Values" means. A formula cell yields the number it produced, not the
; formula; a label yields its characters.
;
; This is pl_cell_totext's .notformula branch, reached UNCONDITIONALLY - which
; is the whole difference between the two routines and the reason this is not
; a flag on that one. pl_cell_totext exists to reproduce what the user typed;
; this exists to discard it.
; -----------------------------------------------------------------------------
pl_ps_valtext:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    mov byte [pl_editbuf], 0
    call pl_ps_srcsheet               ; the source cell is on the sheet the
    call pl_ps_src                    ; block was COPIED from (81.45.4)
    call pl_findcell
    jnc .valdone                      ; an empty source pastes an empty cell
    mov es, [pl_cellseg]
    cmp byte [es:di+PL_C_TYPE], PL_T_TEXT
    je .label
    call pl_cellnum                   ; the eight value bytes, as decimal
    mov si, pl_numbuf
    mov di, pl_editbuf
    call pl_strcpy
    jmp .valdone
.label:
    mov ax, [es:di+PL_C_FOFF]         ; a label shares the formula arena
    mov si, ax
    mov di, pl_editbuf
    mov es, [pl_txtseg]
.acopy:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .acopy
.valdone:
    call pl_ps_mysheet                ; EVERY path leaves it, not just the
.count:                               ; empty one - the caller commits to the
                                      ; CURRENT sheet immediately after
    xor cx, cx
    mov si, pl_editbuf
.len:
    cmp byte [si], 0
    je .haslen
    inc si
    inc cx
    jmp .len
.haslen:
    mov [pl_editlen], cl
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_ps_linktext - "=<the source cell>" into pl_editbuf: what Paste Link
; means. Written as A1-style text and handed to pl_commit like anything else,
; so the result is an ordinary formula that happens to name one cell - which
; is exactly what Excel produces, and means every later Insert/Delete/Sort
; rewrites it through the machinery that already exists (81.28).
;
; RELATIVE, not absolute. Excel 2.1's Paste Link writes a relative reference,
; so a linked block dragged elsewhere follows the same rule as any other
; copied formula.
; -----------------------------------------------------------------------------
pl_ps_linktext:
    push ax
    push bx
    push cx
    push si
    push di
    mov byte [pl_editbuf], '='
    mov di, pl_editbuf + 1
    ; --- a link to ANOTHER sheet has to say which one (81.45.4) -----------
    mov ax, [pl_clip_sheet]
    cmp ax, [pl_cursheet]
    je .samesheet                     ; the ordinary case writes no prefix, so
    push ax                           ; a same-sheet link is byte-for-byte
    mov si, pl_s_sheetpfx             ; what it always was
    call pl_strcpy_to_di
    pop ax
    add al, '1'                       ; "Sheet1".."Sheet4" are the only names
    mov [di], al                      ; there are (pl_psheetpfx), so the index
    inc di                            ; IS the digit
    mov byte [di], '!'
    inc di
.samesheet:
    call pl_ps_src
    push bx                           ; pl_colname and pl_itoa both go through
    call pl_colname                   ; scratch buffers, so the row is banked
    mov si, pl_colbuf                 ; rather than recomputed
    call pl_strcpy_to_di
    pop ax
    inc ax                            ; rows are 1-based on screen
    call pl_itoa
    mov si, pl_numbuf
    call pl_strcpy_to_di
    mov byte [di], 0                  ; A1 STYLE UNCONDITIONALLY, even with
                                      ; the reference box set to R1C1: that is
                                      ; a DISPLAY setting (81.31), and this
                                      ; text goes to pl_commit, whose parser
                                      ; reads A1 and nothing else
    xor cx, cx
    mov si, pl_editbuf
.len:
    cmp byte [si], 0
    je .haslen
    inc si
    inc cx
    jmp .len
.haslen:
    mov [pl_editlen], cl
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_cell_totext - the text of the cell at (AX,BX) into pl_clipbuf: a formula's
; own source with its '=' restored, a label's characters, or a number as
; decimal. An empty cell gives an empty string. out: CX = the length.
;
; Copy used to do this inline and got two of the three wrong. It read a WORD at
; PL_C_VAL and ran pl_itoa over it - which is what everything did before stage
; 4.0, and is meaningless now that the value is an eight-byte double whose low
; word is mantissa bits (pl_cellnum exists to say exactly that). And it had no
; case for a label at all, so copying a column heading ran the numeric path
; over its text offset. One routine now, so the next thing that needs a cell as
; text cannot get a third answer.
; -----------------------------------------------------------------------------
pl_cell_totext:
    push ax
    push bx
    push dx                           ; callers loop on DX; pl_cellnum and the
    push si                           ; arena copy below both go through it
    push di
    push es
    mov byte [pl_clipbuf], 0
    call pl_findcell
    jnc .count
    mov es, [pl_cellseg]
    test byte [es:di+4], 1            ; HASFORMULA
    jz .notformula
    mov ax, [es:di+PL_C_FOFF]
    mov byte [pl_clipbuf], '='
    mov di, pl_clipbuf + 1
    jmp .arena
.notformula:
    cmp byte [es:di+PL_C_TYPE], PL_T_TEXT
    je .label
    call pl_cellnum                   ; the eight value bytes, as decimal
    mov si, pl_numbuf
    mov di, pl_clipbuf
    call pl_strcpy
    jmp .count
.label:
    mov ax, [es:di+PL_C_FOFF]         ; a label shares the formula arena
    mov di, pl_clipbuf
.arena:
    mov si, ax
    mov es, [pl_txtseg]
.acopy:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .acopy
.count:
    xor cx, cx
    mov si, pl_clipbuf
.cnt:
    cmp byte [si], 0
    je .out
    inc si
    inc cx
    jmp .cnt
.out:
    pop es
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_docmd_copy - builds the selected cell's text (a formula's own source
; text with its '=' restored, or a plain value's decimal text - the same
; two cases pl_beginedit already knows how to build, just targeting
; pl_clipbuf instead of pl_editbuf) and hands it to the real clipboard. An
; empty cell empties the clipboard instead (CX=0 is documented as not an
; error).
; -----------------------------------------------------------------------------
pl_docmd_copy:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    ; THE TOP-LEFT of the selection, not the anchor: a drag can start at any
    ; corner, and Paste's reference shift is measured from where the block
    ; began rather than from where the mouse went down.
    mov ax, [pl_selcol]
    mov bx, [pl_selcol2]
    cmp ax, bx
    jbe .cpc
    xchg ax, bx
.cpc:
    mov [pl_clip_col], ax
    mov cx, bx                         ; cx = last column
    mov ax, [pl_selrow]
    mov bx, [pl_selrow2]
    cmp ax, bx
    jbe .cpr
    xchg ax, bx
.cpr:
    mov [pl_clip_row], ax
    mov ax, [pl_cursheet]              ; WHICH SHEET the block came from, which
    mov [pl_clip_sheet], ax            ; matters the moment Paste Special reads
    mov byte [pl_clip_valid], 1        ; the SOURCE CELLS again (81.45.4)
    ; --- build the block as TAB-SEPARATED TEXT in the staging segment ------
    ; Tabs between columns, CR/LF between rows, and nothing after the last
    ; one - which is exactly what Excel puts on the clipboard, makes a 1x1
    ; block byte-identical to what this used to write, and means a copied
    ; block pastes into Word as text that lines up.
    push bp
    mov es, [pl_stgseg]
    xor di, di                         ; di = the write cursor
    mov dx, ax                         ; dx = the current row
.rowloop:
    mov bp, [pl_clip_col]              ; bp = the current column
.colloop:
    push ax
    push bx
    push cx
    push dx
    mov ax, bp
    mov bx, dx
    call pl_cell_totext                ; -> pl_clipbuf, CX = length
    mov si, pl_clipbuf
.emit:
    or cx, cx
    jz .emitted
    cmp di, PL_STAGE_MAX - 4           ; the staging area is the bound here
    jae .emitted
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    dec cx
    jmp .emit
.emitted:
    pop dx
    pop cx
    pop bx
    pop ax
    cmp bp, cx
    jae .rowend
    cmp di, PL_STAGE_MAX - 4
    jae .rowend
    mov byte [es:di], 9                ; TAB between columns
    inc di
    inc bp
    jmp .colloop
.rowend:
    cmp dx, bx                         ; bx is still the last row
    jae .blockdone
    cmp di, PL_STAGE_MAX - 4
    jae .blockdone
    mov byte [es:di], 13               ; CR/LF between rows, none after the
    inc di                             ; last - so a single cell is exactly
    mov byte [es:di], 10               ; its own text, as before
    inc di
    inc dx
    jmp .rowloop
.blockdone:
    pop bp
    mov cx, di
    xor si, si
    call OSAPI_CLIP_PUT                ; ES is already the staging segment
.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; pl_docmd_cut - Copy, then Clear
pl_docmd_cut:
    push ax
    push bx
    push cx
    push si
    push di
    jc .refused                       ; pl_commit, so the funnel guard misses
    call pl_docmd_copy                 ; the whole block goes to the clipboard,
    mov ax, [pl_selrow]                ; so the whole block has to leave the
    mov bx, [pl_selrow2]               ; sheet - it cleared the anchor alone
    cmp ax, bx                         ; and left the rest of what it had just
    jbe .cutrows                       ; copied sitting there
    xchg ax, bx
.cutrows:
    mov cx, [pl_selcol]
    mov si, [pl_selcol2]
    cmp cx, si
    jbe .cutcols
    xchg cx, si
.cutcols:
.cutcolloop:
    mov di, ax
.cutrowloop:
    push ax
    push bx
    mov ax, cx
    mov bx, di
    call pl_clearcell
    pop bx
    pop ax
    inc di
    cmp di, bx
    jbe .cutrowloop
    inc cx
    cmp cx, si
    jbe .cutcolloop
    mov si, [pl_ownwin]
    call pl_repaint
    jmp .out
.refused:                             ; A REFUSAL STILL HAS TO REPAINT. Jumping
    mov si, [pl_ownwin]               ; straight to the exit skipped the redraw
    call pl_repaint                   ; and the message pl_prot_blocked had just
.out:                                 ; set was never painted - the command did
    pop di                            ; nothing and said nothing
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_docmd_paste - reads the system clipboard straight into pl_editbuf
; (capped to PL_EDITMAX, same as anything a keyboard could ever produce
; there); if this instance's own last Copy captured a formula AND a
; source cell (pl_clip_valid), and the destination differs from it,
; shifts every reference in the pasted formula by the (col, row) delta
; between them (pl_formula_copyshift) - real Excel's own default
; relative-reference behavior - before calling pl_commit to reuse its
; existing value/formula parsing exactly as if this (possibly rewritten)
; text had been typed. An empty clipboard is a no-op.
; -----------------------------------------------------------------------------
pl_docmd_paste:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    call OSAPI_CLIP_SIZE
    jc .out
    or ax, ax
    jz .out
    cmp ax, PL_STAGE_MAX - 2           ; the staging segment holds the block
    jbe .fits                          ; while it is taken apart
    mov ax, PL_STAGE_MAX - 2
.fits:
    mov cx, ax
    mov es, [pl_stgseg]
    xor di, di
    call OSAPI_CLIP_GET
    mov [pl_pb_len], cx
    mov ax, [pl_selcol]                ; where the block lands
    mov [pl_pb_c0], ax
    mov ax, [pl_selrow]
    mov [pl_pb_r0], ax
    mov word [pl_pb_x], 0
    mov word [pl_pb_y], 0
    mov word [pl_pb_cur], 0
.cell:
    mov ax, [pl_pb_cur]
    cmp ax, [pl_pb_len]
    jae .done
    ; --- one cell's text out of the block, up to TAB, CR, LF or the end ----
    mov es, [pl_stgseg]
    mov si, ax
    mov di, pl_editbuf
    xor cx, cx
.take:
    cmp si, [pl_pb_len]
    jae .took
    mov al, [es:si]
    cmp al, 9
    je .took
    cmp al, 13
    je .took
    cmp al, 10
    je .took
    cmp cx, PL_EDITMAX
    jae .skiptail
    mov [di], al
    inc di
    inc si
    inc cx
    jmp .take
.skiptail:
    inc si                             ; over-long cell: drop the rest, so the
    jmp .take                          ; dispatch below sees the cell's real
                                       ; terminator - its 64th character read
                                       ; as "new row" and smeared each further
                                       ; 63-byte chunk one row down
.took:
    mov byte [di], 0
    mov [pl_editlen], cl
    mov [pl_pb_cur], si                ; the terminator is consumed below
    call pl_paste_cell
    ; --- what ended it decides where the next one goes --------------------
    mov es, [pl_stgseg]
    mov si, [pl_pb_cur]
    cmp si, [pl_pb_len]
    jae .done
    mov al, [es:si]
    inc si
    mov [pl_pb_cur], si
    cmp al, 9                          ; TAB: the next column
    jne .newrow
    inc word [pl_pb_x]
    jmp .cell
.newrow:
    cmp al, 13                         ; CR, and swallow an LF behind it
    jne .lfonly
    cmp si, [pl_pb_len]
    jae .rowdone
    cmp byte [es:si], 10
    jne .rowdone
    inc si
    mov [pl_pb_cur], si
.rowdone:
.lfonly:
    mov word [pl_pb_x], 0
    inc word [pl_pb_y]
    jmp .cell
.done:
    mov ax, [pl_pb_c0]                 ; put the selection back where it was
    mov [pl_selcol], ax
    mov [pl_selcol2], ax
    mov ax, [pl_pb_r0]
    mov [pl_selrow], ax
    mov [pl_selrow2], ax
    mov si, [pl_ownwin]                ; ONE repaint for the whole block
    call pl_repaint
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_paste_cell - commit pl_editbuf into the block cell at (pl_pb_x, pl_pb_y),
; shifting a formula's relative references by the SAME delta for every cell in
; the block: where the block landed, less where it was copied from. That is
; Excel's rule, and it is what makes a copied column of =A1*B1 still line up a
; column over.
;
; It moves pl_selcol/pl_selrow and calls pl_commit rather than reimplementing
; the decision, because pl_commit is the ONE place that decides whether text
; is a formula, a number or a label - a second copy of that would be a second
; answer. The selection is restored by the caller when the block is done.
; -----------------------------------------------------------------------------
pl_paste_cell:
    push ax
    push bx
    push cx
    push si
    push di
    mov ax, [pl_pb_c0]
    add ax, [pl_pb_x]
    cmp ax, PL_COLS
    jae .out                           ; a block that runs off the edge stops
    mov [pl_selcol], ax                ; at it rather than wrapping
    mov [pl_selcol2], ax
    mov bx, [pl_pb_r0]
    add bx, [pl_pb_y]
    cmp bx, PL_ROWS
    jae .out
    mov [pl_selrow], bx
    mov [pl_selrow2], bx
    jc .out                           ; DIRECTLY and never reach pl_commit, so
                                      ; the funnel guard does not cover them
    ; --- WHICH PARTS OF THE SOURCE CELL THIS PASTE IS FOR (81.45) ----------
    mov al, [pl_ps_mode]
    cmp al, PL_PS_LINK
    je .dolink
    cmp al, PL_PS_FMT                 ; Formats and Notes leave the CONTENTS
    jb .contents                      ; alone entirely - they are the two
    call pl_ps_props                  ; modes with nothing to commit
    jmp .out
.dolink:
    call pl_ps_linktext               ; "=<the source cell>" - no shifting,
    jmp .commit                       ; the whole point is that it points back
.contents:
    cmp al, PL_PS_VAL
    jne .astyped
    call pl_ps_valtext                ; the source's VALUE, so a formula lands
    jmp .commit                       ; as the number it produced. Never
                                      ; reference-shifted: there is no
                                      ; reference left in it to shift
.astyped:
    cmp byte [pl_clip_valid], 0
    je .commit
    cmp byte [pl_editbuf], '='
    jne .commit
    mov ax, [pl_pb_c0]
    sub ax, [pl_clip_col]
    mov [pl_cp_coldelta], ax
    mov bx, [pl_pb_r0]
    sub bx, [pl_clip_row]
    mov [pl_cp_rowdelta], bx
    or ax, bx
    jz .commit                         ; pasted onto the cell it came from
    mov si, pl_editbuf
    inc si
    mov di, pl_rwsrc
.copyin:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov si, pl_rwsrc
    call pl_formula_copyshift
    mov byte [pl_editbuf], '='
    mov si, pl_rwdst
    mov di, pl_editbuf + 1
    mov cx, PL_EDITMAX - 1             ; a shifted reference can grow a digit
.copyout:                              ; or two, so clip rather than overrun
    mov al, [si]
    or al, al
    jz .copyoutdone
    mov [di], al
    inc si
    inc di
    dec cx
    jnz .copyout
.copyoutdone:
    mov byte [di], 0
    xor cx, cx
    mov si, pl_editbuf
.relen:
    cmp byte [si], 0
    je .haverelen
    inc si
    inc cx
    jmp .relen
.haverelen:
    mov [pl_editlen], cl
.commit:
    mov byte [pl_editing], 1
    call pl_commit
    cmp byte [pl_ps_mode], PL_PS_ALL  ; All is contents AND properties, which
    jne .out                          ; is what Excel's plain Paste does too
    call pl_ps_props
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_docmd_fillright / pl_docmd_filldown - fill the SELECTED RANGE from its
; own first column/row, the way Excel does: Fill Down copies the selection's
; top row into every row under it, for every column in the selection, and
; Fill Right copies its left column across.
;
; These two used to copy exactly one cell into exactly one neighbour, because
; they were written before range selection existed (stage 3.0a) and were never
; taught about pl_selcol2/pl_selrow2. Selecting a block and choosing Fill Down
; changed a single cell and reported nothing - the selection stayed drawn over
; cells that had not been touched. A SINGLE-CELL selection still fills the one
; neighbour, which is what the old behaviour was and what collapsing the
; anchor and extent already means here.
;
; A formula source has its text copied through pl_formula_copyshift (the same
; relative-reference shift Copy/Paste uses), and the delta is the FULL offset
; from the source rather than always one - filling five rows down has to shift
; the fifth by five. A plain value is copied as its current value.
; -----------------------------------------------------------------------------
; pl_fill_copy - one cell to another. in: pl_fl_scol/srow = source,
; pl_fl_dcol/drow = destination. An empty source copies nothing. Preserves
; every register, so the loops below can keep their bounds in theirs.
; -----------------------------------------------------------------------------






; -----------------------------------------------------------------------------
; pl_sort_vof / pl_sort_ldds / pl_sort_cmp - the three places the sort's value
; array is touched, so its EIGHT-BYTE stride lives in exactly one of them.
; It was a word per entry and the multiply was written inline six times; a
; widening done that way is how a missed site returns a plausible wrong number
; with no crash (the risk this file's own record-layout comment names).
;
; pl_sort_vof - in: BX = entry index, out: DI = its offset in pl_stgseg
; -----------------------------------------------------------------------------
section PL_MODSEC                      ; 81.71.6: Data > Sort's worker, CHART.OVL
section .text


; =============================================================================
; Format dialogs (stage 1.8). Real Excel's Number/Alignment/Font dialogs
; each boil down to "pick one of a short list, then OK/Cancel" for what
; this app actually supports (Number's real dialog is a much longer
; scrollable list of format-code strings,
; LIBRARY/documentation/screenshots/excel/dialog_number.png - Sheet only ever
; has 4 number formats, so a plain 4-item radio list stands
; in for it, same shape as the real Alignment and Font dialogs). All three
; are really the SAME dialog (a title, 4 radio rows, OK/Cancel) with
; different labels and a different 2-bit field of the format byte to read
; and write - see pl_fdlg_kind - which is why one implementation serves
; all three rather than three near-copies.
;
; Built directly on apps/os88ui.inc's primitives (os88ui_glyph for the
; radio dots, os88ui_btn for OK/Cancel) rather than os88ui_ask, which only
; ever offers a message and a button row - there is no generic
; "N controls" dialog builder in this codebase (apps/word/word.asm rolled
; its own, ~900 lines, for a dozen much bigger dialogs; three small
; identical-shaped ones don't need that). Only one can be open at a time
; (pl_fdlg_win is the gate, same single-instance idea as os88ui_awin, just
; simpler: this dialog doesn't need "refuse and raise" since the menu
; command that opens it can't fire again while it's up).
;
; Radio index 0-3 in each dialog is deliberately identical to that
; category's own PL_FMT_* encoding (PL_FMT_ALIGN_LEFT=1, PL_FMT_NUM_COMMA=2,
; etc, and Font's 0=Normal/1=Bold/2=Underline/3=Bold+Underline is just
; PL_FMT_BOLD|PL_FMT_UNDER's own bit pattern) - so applying a choice is a
; plain mask-and-OR, no translation table needed anywhere.
; =============================================================================
PL_FDLG_W      equ 170
PL_FDLG_ROWTOP equ 12
PL_FDLG_ROWH   equ 16
PL_FDLG_NITEMS equ 4
; THE BUTTON ROW AND THE WINDOW HEIGHT ARE ONE NUMBER, not two that have to be
; kept in agreement by hand. They were two, and they disagreed: the height was
; a flat 116 while the buttons were drawn at content-relative 86..102, and a
; window's content is only W_H - TITLE_H - 1 tall (wm_content: the origin is
; W_X+1, W_Y+TITLE_H). 116 - 18 - 1 = 97, so the bottom HALF of OK and Cancel
; was outside the window in every one of this engine's kinds - Number,
; Alignment, Font, Insert, Delete, Column Width and Row Height since stage 1.8,
; and the four stage 3.0c added. Deriving it means the next kind that needs a
; taller body cannot reintroduce this by changing one of the two.
PL_FDLG_MAXROWS equ 7                ; the tallest kind's row count, and the
                                     ; reason the button row is derived from
                                     ; it rather than fixed: the Gallery kind
                                     ; has five rows and the row at index 4
                                     ; landed ON the buttons, because 86 was
                                     ; chosen when four was the most any kind
                                     ; had. A new kind with more rows changes
                                     ; this one number.
PL_FDLG_BTY1   equ PL_FDLG_ROWTOP + PL_FDLG_MAXROWS * PL_FDLG_ROWH + 4
PL_FDLG_BTY2   equ PL_FDLG_BTY1 + 16
PL_DLG_BMARG   equ 8                 ; the gap every dialog leaves below its
                                     ; lowest element, and the reason all four
                                     ; heights below are DERIVED: a window's
                                     ; content is W_H - TITLE_H - 1 tall, so a
                                     ; hand-written height is a second number
                                     ; that has to agree with the first and
                                     ; silently did not
PL_FDLG_H      equ PL_FDLG_BTY2 + PL_DLG_BMARG + TITLE_H + 1

pl_fdlg_tpl:
    dw 0, 0, PL_FDLG_W, PL_FDLG_H
    dw 0, pl_fdlg_paint_r, 0, pl_fdlg_click_r

; Stage 2.x's Edit menu Insert.../Delete... reuse this same engine as kinds
; 3 and 4 - just a 2-item Row/Column pick instead of a 4-item format
; radio, and a different [pl_fdlg_count] (see pl_fdlg_open) since these
; two kinds don't have 4 rows to show. pl_fdlg_apply branches to
; pl_rowcol_op for these two kinds instead of writing a format bit.
; Kinds 5/6 are RETIRED: they were the Narrow/Normal/Wide and Short/Normal/
; Tall presets Column Width.../Row Height... used before stage 3.0c gave
; them pl_idlg_open's typed field, and nothing has opened them since. Their
; code went in 81.59; the two slots stay, as zeros, so every later kind keeps
; its number - pl_ud_kind and the PL_FDK_* equates are indexed by it.
; Kinds 7-10 (stage 3.0c) are the last four radio dialogs Excel 2.1d has and
; this app was doing as immediate menu commands: Clear, New, Calculation and
; Sort. Each was a one-line "just do it" item, which is wrong twice - Excel
; asks, and asking is what lets Clear mean something other than "everything"
; and Sort mean something other than "ascending".
; 81.75: kinds 15 and 16 are Extract and Series. They go the way 5 and 6 did
; when they were retired - the SLOT stays, because a kind is an index into
; these three tables and into pl_ud_kind, and the entry becomes 0.
pl_fdlg_titles: dw pl_s_fd_num, pl_s_fd_align, pl_s_fd_font, pl_s_fd_insert, pl_s_fd_delete, 0, 0, pl_s_fd_clear, pl_s_fd_new, pl_s_fd_calc, pl_s_fd_sort, pl_s_fd_gal, pl_s_fd_savefmt, pl_s_fd_pspec, pl_s_fd_prot
                dw 0, 0
pl_s_fd_pspec:  db 'Paste Special', 0
pl_s_fd_prot:   db 'Cell Protection', 0
pl_s_fd_savefmt: db 'File Format', 0
pl_s_fd_gal:    db 'Gallery', 0
pl_s_fd_clear:  db 'Clear', 0
pl_s_fd_new:    db 'New', 0
pl_s_fd_calc:   db 'Calculation', 0
pl_s_fd_sort:   db 'Sort', 0
pl_s_fd_num:    db 'Format Number', 0
pl_s_fd_align:  db 'Alignment', 0
pl_s_fd_font:   db 'Font', 0
pl_s_fd_insert: db 'Insert', 0
pl_s_fd_delete: db 'Delete', 0

pl_fdlg_items:  dw pl_fd_i_num, pl_fd_i_align, pl_fd_i_font, pl_fd_i_rowcol, pl_fd_i_rowcol, 0, 0, pl_fd_i_clear, pl_fd_i_new, pl_fd_i_calc, pl_fd_i_sort, pl_fd_i_gal, pl_fd_i_savefmt, pl_fd_i_pspec, pl_fd_i_prot
                dw 0, 0
; Excel's Cell Protection dialog is two INDEPENDENT CHECK BOXES, Locked and
; Hidden. This is the four combinations as a radio, which is exactly what the
; Font dialog above already does with Bold and Underline - the same engine and
; the same compression, so it is at least consistent with itself. The order
; mirrors Font's: the default first, then each one alone, then both.
pl_fd_i_prot:   dw pl_fd_prlock, pl_fd_prunlock, pl_fd_prlockh, pl_fd_prunlockh
pl_fd_prlock:   db 'Locked', 0
pl_fd_prunlock: db 'Unlocked', 0
pl_fd_prlockh:  db 'Locked, Hidden', 0
pl_fd_prunlockh: db 'Unlocked, Hidden', 0
; 81.71: Excel's own Extract dialog carries ONE control, a `Unique Records
; Only` CHECK BOX. This engine paints a radio column, so the same single bit
; is asked as a two-way pick instead - identical meaning, no sixth dialog
; engine, and the divergence is the one §81.31 already took for Gridlines and
; Formulas. Index 1 IS the flag, so pl_fdlg_apply0 stores it with no mapping.
; 81.72: Excel's Series dialog carries FIVE controls - Series In, Type, Date
; Unit, Step Value and Stop Value. Type and Date Unit fold into one radio
; column here (a date unit is only ever read when the type IS Date, so the
; two questions are really one), Step Value is the second dialog, and the
; other two are 81.72's own documented shortfalls
; Excel's own five, in Excel's own order (Reference Guide p.236). The dialog
; there ALSO carries an Operation group (None/Add/Subtract/Multiply/Divide)
; and two check boxes (Skip Blanks, Transpose); this engine paints ONE radio
; column and an OK/Cancel, so those are absent rather than faked - see 81.45.
pl_fd_i_pspec:  dw pl_fd_psall, pl_fd_psform, pl_fd_psval, pl_fd_psfmt, pl_fd_psnote
pl_fd_psall:    db 'All', 0
pl_fd_psform:   db 'Formulas', 0
pl_fd_psval:    db 'Values', 0
pl_fd_psfmt:    db 'Formats', 0
pl_fd_psnote:   db 'Notes', 0
; Excel's own words: the app's OWN format is "Normal", and the interchange
; formats are named after themselves. The order is Excel's too.
; PLAN has no BIFF, so there is no "Normal" to be distinct FROM: SYLK is this
; package's own format and heads its own list (81.75).
pl_fd_i_savefmt: dw pl_fd_sfsylk, pl_fd_sfcsv, pl_fd_sftxt
pl_fd_sfsylk:   db 'SYLK', 0
pl_fd_sfcsv:    db 'CSV', 0         ; 81.40: two of the nine formats Excel 2.0
pl_fd_sftxt:    db 'Text', 0
                                    ; own words for them in its Save As list
; Excel's own Gallery order, which is alphabetical and is NOT the order CH_T_*
; happens to be in - pl_gal_map translates, the same way chart.asm's own
; ct_gal_map does, rather than either side renumbering to suit the other.
pl_fd_i_gal:    dw pl_fd_garea, pl_fd_gbar, pl_fd_gcol, pl_fd_gline, pl_fd_gpie, pl_fd_gsca, pl_fd_gcmb
pl_fd_garea:    db 'Area', 0
pl_fd_gbar:     db 'Bar', 0
pl_fd_gcol:     db 'Column', 0
pl_fd_gline:    db 'Line', 0
pl_fd_gpie:     db 'Pie', 0
pl_fd_gsca:     db 'Scatter', 0
pl_fd_gcmb:     db 'Combination', 0
pl_fd_i_clear:  dw pl_fd_clall, pl_fd_clform, pl_fd_clfmt
pl_fd_clall:    db 'All', 0
pl_fd_clform:   db 'Formulas', 0       ; Excel's own order and its own words:
pl_fd_clfmt:    db 'Formats', 0        ; "Formulas" means the CONTENTS
pl_fd_i_new:    dw pl_fd_nwsheet, pl_fd_nwchart, pl_fd_nwmacro
pl_fd_nwsheet:  db 'Worksheet', 0
pl_fd_nwchart:  db 'Chart', 0
pl_fd_nwmacro:  db 'Macro Sheet', 0
pl_fd_i_calc:   dw pl_fd_cauto, pl_fd_cmanual, pl_fd_cnow
pl_fd_cauto:    db 'Automatic', 0
pl_fd_cmanual:  db 'Manual', 0
pl_fd_cnow:     db 'Calculate Now', 0
pl_fd_i_sort:   dw pl_fd_sasc, pl_fd_sdesc
pl_fd_sasc:     db 'Ascending', 0
pl_fd_sdesc:    db 'Descending', 0
pl_fd_i_num:    dw pl_fd_numnum, pl_fd_numtext, pl_fd_numcur
pl_fd_numnum:   db 'Number', 0
pl_fd_numtext:  db 'Text', 0
pl_fd_numcur:   db 'Currency', 0
pl_fd_i_align:  dw pl_fd_agen, pl_fd_aleft, pl_fd_acenter, pl_fd_aright
pl_fd_agen:     db 'General', 0
pl_fd_aleft:    db 'Left', 0
pl_fd_acenter:  db 'Center', 0
pl_fd_aright:   db 'Right', 0
pl_fd_i_font:   dw pl_fd_fnorm, pl_fd_fbold, pl_fd_funder, pl_fd_fboth
pl_fd_fnorm:    db 'Normal', 0
pl_fd_fbold:    db 'Bold', 0
pl_fd_funder:   db 'Underline', 0
pl_fd_fboth:    db 'Bold, Underline', 0
pl_fd_i_rowcol: dw pl_fd_rcrow, pl_fd_rccol
pl_fd_rcrow:    db 'Row', 0
pl_fd_rccol:    db 'Column', 0

pl_s_fd_ok:     db 'OK', 0
pl_s_fd_cancel: db 'Cancel', 0

; per-kind row count (0 Number/1 Align/2 Font = 4 rows, 3 Insert/4 Delete
; = 2 rows, 5/6 retired) - pl_fdlg_open copies the
; matching entry into [pl_fdlg_count], which pl_fdlg_paint/pl_fdlg_onclick
; loop and hit-test against instead of the fixed PL_FDLG_NITEMS.
pl_fdlg_counts: dw 3, 4, 4, 2, 2, 0, 0, 3, 3, 3, 2, 7, 3, 5, 4, 2, 6
                                      ; 0 Number is three now: Number, Text,
                                      ; Currency (81.75)

PL_FDK_CLEAR equ 7
PL_FDK_NEW   equ 8
PL_FDK_CALC  equ 9
PL_FDK_SORT  equ 10
PL_FDK_GAL   equ 11
PL_FDK_SAVEFMT equ 12                 ; stage 4.6: Save As asks for the format
PL_FDK_PSPEC equ 13                   ; instead of deriving it silently
PL_FDK_PROT  equ 14
PL_FDK_EXTRACT equ 15                 ; 81.71: Data ▸ Extract...
PL_FDK_SERIES equ 16                  ; 81.72: Data ▸ Series..., part one of
PL_FDK_N     equ 17                   ; two (the step value follows)
    times (pl_ud_kind_end - pl_ud_kind - PL_FDK_N) db 0  ; pl_ud_kind (81.57)
    times (PL_FDK_N - (pl_ud_kind_end - pl_ud_kind)) db 0 ; has a kind each
section PL_MODSEC                      ; 81.74.2: the radio dialog engine, CHART.OVL

; -----------------------------------------------------------------------------
; pl_fdlg_open - in: AL = 0 Number / 1 Alignment / 2 Font. Preselects the
; radio matching the selected cell's current format (0/General if the cell
; has no record yet - the dialog still opens; OK on a still-empty cell is a
; no-op, same scope limit the old flat menu already had).
; -----------------------------------------------------------------------------
pl_fdlg_open:
    push ax
    push bx
    push cx
    push si
    push di
    cmp word [pl_fdlg_win], 0
    jne .out                          ; already open (can't happen via the
                                       ; menu, which is inert while a dialog
                                       ; owns input focus, but stay safe)
    mov [pl_fdlg_kind], al
    mov word [pl_fdlg_sel], 0
    mov bl, al
    xor bh, bh
    shl bx, 1
    mov cx, [pl_fdlg_counts + bx]
    mov [pl_fdlg_count], cx
    cmp al, PL_FDK_SAVEFMT
    je .prefillfmt                    ; File Format opens on the format the
    cmp al, PL_FDK_CALC               ; OK alone cannot silently change it
    je .prefillcalc                   ; Calculation opens SHOWING the mode it
    cmp al, PL_FDK_CLEAR              ; what the cell already IS, for exactly
    jae .noprefill                    ; that reason. Clear/New/Sort have
                                       ; nothing current
    cmp al, 3
    jae .noprefill                    ; Insert/Delete (kinds 3/4): no
                                       ; "current" selection to preselect,
                                       ; just default to row 0 ("Row")
    jmp .cellpre
.prefillfmt:
    mov word [pl_fdlg_sel], 0         ; PLAN's list starts at SYLK, which is
    jmp .noprefill                    ; also what pl_dowrite falls through to
.prefillcalc:
    xor ah, ah
    mov al, [pl_calcmanual]
    mov [pl_fdlg_sel], ax
    jmp .noprefill
.cellpre:
    mov ax, [pl_selcol]
    mov bx, [pl_selrow]
    SHOUT pl_findcell
    jnc .noprefill
    push es
    mov es, [pl_cellseg]
    mov al, [es:di+5]
    pop es
    mov ah, 0
    cmp byte [pl_fdlg_kind], 0
    je .pfnum
    cmp byte [pl_fdlg_kind], 1
    je .pfalign
    and al, 0x03                      ; Font: bits0-1 directly
    jmp .havesel
.pfnum:
    and al, PL_FMT_NUM_MASK
    mov cl, PL_FMT_NUM_SHIFT
    shr al, cl
    jmp .havesel
.pfalign:
    and al, PL_FMT_ALIGN_MASK
    mov cl, PL_FMT_ALIGN_SHIFT
    shr al, cl
.havesel:
    mov [pl_fdlg_sel], ax
    jmp .noprefill
.noprefill:
    mov bl, [pl_fdlg_kind]
    xor bh, bh
    shl bx, 1
    mov ax, [pl_fdlg_titles + bx]
    mov [pl_fdlg_tpl + WT_TITLE], ax
    call OSAPI_VIDEO                  ; centre on the LIVE screen, the same
    sub ax, PL_FDLG_W                 ; way os88ui_ask does (apps/os88ui.inc)
    sar ax, 1
    mov [pl_fdlg_tpl + WT_X], ax
    sub bx, PL_FDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8                ; never under the menu bar
.placed:
    mov [pl_fdlg_tpl + WT_Y], bx
    mov si, pl_fdlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [pl_fdlg_win], bx
    call OSAPI_WM_SHOW
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_fdlg_paint - SI = the dialog window. Uses bss scratch (pl_fdlg_ox/oy/
; itemsptr/rowidx/rowy) rather than stack juggling to hold state across the
; os88ui_glyph/OSAPI_FONT_RUN calls, since both take CX/DX as their own
; position input - a register-only approach would need constant reshuffling
; for no real benefit here (this paints at most once per click).
; -----------------------------------------------------------------------------
pl_fdlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si                         ; OSAPI_WM_CONTENT wants BX=window
    call OSAPI_WM_CONTENT              ; -> ax=content x, dx=content y
    mov [pl_fdlg_ox], ax
    mov [pl_fdlg_oy], dx
    mov bl, [pl_fdlg_kind]
    xor bh, bh
    shl bx, 1
    mov si, [pl_fdlg_items + bx]       ; the window's own title bar already
    mov [pl_fdlg_itemsptr], si         ; names the dialog (pl_fdlg_open set
                                        ; WT_TITLE) - no need to repeat it as
                                        ; content
    mov word [pl_fdlg_rowidx], 0
.rowloop:
    mov cx, [pl_fdlg_rowidx]
    cmp cx, [pl_fdlg_count]
    jae .rowsdone
    mov ax, cx
    mov bx, PL_FDLG_ROWH
    mul bx
    add ax, PL_FDLG_ROWTOP
    add ax, [pl_fdlg_oy]
    mov [pl_fdlg_rowy], ax
    mov ax, [pl_fdlg_sel]
    cmp ax, [pl_fdlg_rowidx]
    mov al, OS88UI_GRADIO
    jne .goff
    or al, OS88UI_GON
.goff:
    mov ah, 0
    mov cx, [pl_fdlg_ox]
    add cx, 8
    mov dx, [pl_fdlg_rowy]
    SHOUT os88ui_glyph                  ; preserves all registers (its own doc)
    mov si, [pl_fdlg_itemsptr]
    mov bx, [pl_fdlg_rowidx]
    shl bx, 1
    add si, bx
    mov si, [si]                       ; si = this row's label string
    mov cx, [pl_fdlg_ox]
    add cx, 24
    mov dx, [pl_fdlg_rowy]
    add dx, 2
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_RUN
    mov ax, [pl_fdlg_rowidx]
    inc ax
    mov [pl_fdlg_rowidx], ax
    jmp .rowloop
.rowsdone:
    mov ax, [pl_fdlg_ox]
    add ax, 8
    mov [pl_fdlg_rect], ax
    mov ax, [pl_fdlg_oy]
    add ax, PL_FDLG_BTY1
    mov [pl_fdlg_rect+2], ax
    mov ax, [pl_fdlg_ox]
    add ax, 62
    mov [pl_fdlg_rect+4], ax
    mov ax, [pl_fdlg_oy]
    add ax, PL_FDLG_BTY2
    mov [pl_fdlg_rect+6], ax
    mov bx, pl_fdlg_rect
    mov si, pl_s_fd_ok
    mov di, OS88UI_DEF
    SHOUT os88ui_btn
    mov ax, [pl_fdlg_ox]
    add ax, 96
    mov [pl_fdlg_rect], ax
    mov ax, [pl_fdlg_oy]
    add ax, PL_FDLG_BTY1
    mov [pl_fdlg_rect+2], ax
    mov ax, [pl_fdlg_ox]
    add ax, 150
    mov [pl_fdlg_rect+4], ax
    mov ax, [pl_fdlg_oy]
    add ax, PL_FDLG_BTY2
    mov [pl_fdlg_rect+6], ax
    mov bx, pl_fdlg_rect
    mov si, pl_s_fd_cancel
    xor di, di
    SHOUT os88ui_btn
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_fdlg_onclick - in: CX=x, DX=y (screen-absolute, same convention as
; pl_onclick), SI=the dialog window
; -----------------------------------------------------------------------------
pl_fdlg_onclick:
    push ax
    push bx
    push si
    push di
    push cx
    push dx
    mov bx, si
    call OSAPI_WM_CONTENT              ; -> ax=content x, dx=content y
    pop bx
    sub bx, dx                         ; bx = click y, content-relative
    pop cx
    sub cx, ax                         ; cx = click x, content-relative
    cmp cx, 8
    jb .checkcancel
    cmp cx, 62
    ja .checkcancel
    cmp bx, PL_FDLG_BTY1
    jb .checkcancel
    cmp bx, PL_FDLG_BTY2
    ja .checkcancel
    jmp .doOK
.checkcancel:
    cmp cx, 96
    jb .checkrows
    cmp cx, 150
    ja .checkrows
    cmp bx, PL_FDLG_BTY1
    jb .checkrows
    cmp bx, PL_FDLG_BTY2
    ja .checkrows
    jmp .doCancel
.checkrows:
    cmp cx, 8
    jb .out
    cmp bx, PL_FDLG_ROWTOP
    jb .out
    mov ax, bx
    sub ax, PL_FDLG_ROWTOP
    xor dx, dx
    mov si, PL_FDLG_ROWH
    div si                             ; ax = row index
    cmp ax, [pl_fdlg_count]
    jae .out
    mov [pl_fdlg_sel], ax
    mov si, [pl_fdlg_win]
    call pl_fdlg_paint
    jmp .out
.doOK:
    call pl_fdlg_apply
    call pl_fdlg_close
    cmp byte [pl_savepend], 0         ; File Format's OK owes a Save As, and it
    je .out                           ; runs only now that the format dialog's
    mov byte [pl_savepend], 0         ; window is DESTROYED. Opening the file
    mov si, [pl_ownwin]               ; dialog from inside apply would stack a
    mov al, FDLG_SAVE                 ; second dialog on a window slot that is
    SHOUT pl_dlg                       ; still in use, which is how one gets
    jmp .out                          ; orphaned behind the other
.doCancel:
    call pl_fdlg_close
.out:
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_setext - in: SI -> a 4-byte ".XXX". Replaces [pl_name]'s extension, or
; appends one if it has none, so picking a format in the Save As dialog
; renames BUDGET.SLK to BUDGET.BIF rather than leaving the name disagreeing
; with the bytes. pl_dowrite still decides by extension - this makes the
; extension follow the CHOICE instead of the other way round.
;
; pl_name is 13 bytes and holds an 8.3 name, so the worst case (an 8-char
; stem with no dot) writes 8+4+1 = 13. Nothing longer can arrive: the file
; dialog is what fills this buffer and it enforces 8.3.
; -----------------------------------------------------------------------------
pl_setext:
    push ax
    push cx
    push si
    push di
    mov di, pl_name
    xor cx, cx                        ; cx = where the '.' is, 0 = none yet
.scan:
    mov al, [di]
    or al, al
    jz .atend
    cmp al, '.'
    jne .next
    mov cx, di
.next:
    inc di
    jmp .scan
.atend:
    or cx, cx
    jz .append                        ; no extension: write one on the end
    mov di, cx                        ; there is one: overwrite from the '.'
.append:
    mov cx, 4
.cp:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    loop .cp
    mov byte [di], 0
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_clear_one - Clear's work for ONE cell, by [pl_fdlg_sel]: 0 All /
; 1 Formulas / 2 Formats. "Formulas" is Excel's word for the CONTENTS - a cell
; cleared that way keeps its border, its number format and its font, which is
; the whole reason the dialog exists - and a cell with nothing of that kind
; to keep goes altogether. in: AX = col, BX = row. Preserves all.
; -----------------------------------------------------------------------------
pl_clear_one:
    push ax
    push bx
    push di
    push es
    cmp word [pl_fdlg_sel], 2
    je .fmt
    cmp word [pl_fdlg_sel], 1
    je .contents
    SHOUT pl_clearcell                 ; All: the record and all of it
    jmp .out
.contents:
    SHOUT pl_findcell                  ; NOTHING TO KEEP - no format byte
    jnc .out                          ; either - then the contents going
    mov es, [pl_cellseg]              ; leave no cell at all, as All's do,
    cmp byte [es:di+5], 0             ; rather than a zero where Excel shows
    jne .keep2                        ; nothing (81.63)
    SHOUT pl_clearcell
    jmp .out
    SHOUT pl_findcell
    jnc .out
    mov es, [pl_cellseg]
.keep2:
    mov byte [es:di+4], 0             ; not a formula any more...
    mov byte [es:di+PL_C_TYPE], PL_T_NUM
    mov word [es:di+PL_C_VAL], 0      ; ...and zero, but the format byte at
    mov word [es:di+PL_C_VAL+2], 0    ; +5 is deliberately untouched
    mov word [es:di+PL_C_PASS], 0
    jmp .out
.fmt:
    SHOUT pl_findcell
    jnc .out
    mov es, [pl_cellseg]
    mov byte [es:di+5], 0             ; Formats: the format byte, which is now
                                      ; the whole of what a format is
.out:
    pop es
    pop di
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_fmt_one - apply the format dialog's current choice to ONE cell.
; in: AX = col, BX = row. An empty cell has no record to carry a format and is
; skipped, which is what the single-cell version did too. Preserves all.
; -----------------------------------------------------------------------------
pl_fmt_one:
    push ax
    push bx
    push cx
    push di
    push es
    SHOUT pl_findcell
    jnc .out
    mov es, [pl_cellseg]
    mov bl, [es:di+5]
    mov al, [pl_fdlg_sel]
    cmp byte [pl_fdlg_kind], 0
    je .num
    cmp byte [pl_fdlg_kind], 1
    je .align
    and bl, PL_FMT_BU_CLR              ; Font: bits0-1 directly
    or bl, al
    jmp .put
.num:
    and bl, PL_FMT_NUM_CLR
    mov cl, PL_FMT_NUM_SHIFT
    shl al, cl
    or bl, al
    jmp .put
.align:
    and bl, PL_FMT_ALIGN_CLR
    mov cl, PL_FMT_ALIGN_SHIFT
    shl al, cl
    or bl, al
.put:
    mov [es:di+5], bl
.out:
    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_fdlg_apply - kinds 0-2 (Number/Alignment/Font): write [pl_fdlg_sel]
; into the selected cell's format byte, in the field [pl_fdlg_kind] names -
; a no-op if the cell has no record (see pl_fdlg_open's own comment on
; that scope limit). Kinds 3-4 (Insert/Delete): [pl_fdlg_sel] is 0 Row / 1
; Column, so hand off to pl_rowcol_op with the selected cell's own row or
; column as the pivot index - these have no "cell must have a record"
; limit, since they act on the grid's structure, not a cell's content.
; -----------------------------------------------------------------------------
pl_fdlg_apply:
    ; UNDO AT OK, NOT AT THE MENU (81.57): a dialog the user cancels changes
    ; nothing, so nothing is snapshot for it. pl_ud_kind says, per kind, the
    ; action's label, or that it ends Undo (a format, New), or neither
    push ax
    push bx
    mov bl, [pl_fdlg_kind]
    xor bh, bh
    cmp bx, PL_FDK_N
    jae .ukeep
    mov al, [pl_ud_kind + bx]
    cmp al, PL_UL_KEEP
    je .ukeep
    cmp al, PL_UL_DROP
    jne .usnap
    SHOUT pl_undo_drop
    jmp short .ukeep
.usnap:
    SHOUT pl_undo_begin
.ukeep:
    pop bx
    pop ax
    call pl_fdlg_apply0
    SHOUT pl_undo_end                  ; 81.74.2: a tail JUMP would enter a
    ret                                ; resident body with no far frame

pl_fdlg_apply0:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    cmp byte [pl_fdlg_kind], PL_FDK_CLEAR
    je .doclear
    cmp byte [pl_fdlg_kind], PL_FDK_NEW
    je .donew
    cmp byte [pl_fdlg_kind], PL_FDK_CALC
    je .docalc
    cmp byte [pl_fdlg_kind], PL_FDK_SAVEFMT
    je .dosavefmt
    cmp byte [pl_fdlg_kind], PL_FDK_PSPEC
    je .dopspec
    ; Number/Alignment/Font apply to the WHOLE SELECTION. They used to read
    ; pl_selcol/pl_selrow and format the anchor alone, so selecting a column
    ; of figures and choosing Currency changed exactly one cell - the same
    ; thing Fill Right/Down did before 81.13, and for the same reason: written
    ; before range selection existed and never taught about pl_selcol2/
    ; pl_selrow2. A single-cell selection is a 1x1 range, so it still works.
    mov ax, [pl_selrow]
    mov bx, [pl_selrow2]
    cmp ax, bx
    jbe .fmtrows
    xchg ax, bx
.fmtrows:                              ; ax = top row, bx = bottom row
    mov cx, [pl_selcol]
    mov si, [pl_selcol2]
    cmp cx, si
    jbe .fmtcols
    xchg cx, si
.fmtcols:                              ; cx = first col, si = last col
.fmtcolloop:
    mov di, ax                         ; di = the current row, from the top
.fmtrowloop:
    push ax
    push bx
    mov ax, cx
    mov bx, di
    call pl_fmt_one
    pop bx
    pop ax
    inc di
    cmp di, bx
    jbe .fmtrowloop
    inc cx
    cmp cx, si
    jbe .fmtcolloop
    SHOUT pl_repaint                    ; ONE repaint for the whole block
    jmp .out
; --- stage 3.0c: the four that used to be immediate menu commands -----------
.doclear:
    jc .refused                       ; ...and the same here: this engine's
                                      ; .out does not repaint either
    ; Over the WHOLE SELECTION, like Excel's Clear and like the block the user
    ; has highlighted. It used to clear the anchor alone (81.17's third case,
    ; after Fill and the format dialogs).
    mov ax, [pl_selrow]
    mov bx, [pl_selrow2]
    cmp ax, bx
    jbe .clrows
    xchg ax, bx
.clrows:                              ; ax = top row, bx = bottom row
    mov cx, [pl_selcol]
    mov si, [pl_selcol2]
    cmp cx, si
    jbe .clcols
    xchg cx, si
.clcols:                              ; cx = first col, si = last col
.clcolloop:
    mov di, ax
.clrowloop:
    push ax
    push bx
    mov ax, cx
    mov bx, di
    call pl_clear_one
    pop bx
    pop ax
    inc di
    cmp di, bx
    jbe .clrowloop
    inc cx
    cmp cx, si
    jbe .clcolloop
.cldone:
    mov si, [pl_ownwin]               ; ONE repaint for the block
    SHOUT pl_repaint
    jmp .out

.donew:
    ; Excel asks which KIND of new document. This app has one grid type, so
    ; Chart and Macro Sheet do the honest thing rather than the flattering
    ; one: a new sheet, and a status line saying what was actually made.
    SHOUT pl_new
    mov word [pl_msg], pl_s_nw_sheet
    cmp word [pl_fdlg_sel], 1
    jne .nwnotchart
    mov word [pl_msg], pl_s_nw_chart
.nwnotchart:
    cmp word [pl_fdlg_sel], 2
    jne .nwdone
    mov word [pl_msg], pl_s_nw_macro
.nwdone:
    mov si, [pl_ownwin]
    SHOUT pl_repaint
    jmp .out

.docalc:
    ; 0 Automatic / 1 Manual / 2 Calculate Now. Manual is not a no-op with a
    ; label on it: pl_drawgrid re-evaluates every formula cell on every
    ; repaint, so switching it off is what a big sheet on a 4.77MHz 8088
    ; actually needs, and Calculate Now is then the only way to catch up.
    cmp word [pl_fdlg_sel], 2
    je .calcnow
    mov ax, [pl_fdlg_sel]
    mov [pl_calcmanual], al
    mov word [pl_msg], pl_s_calc_auto
    or al, al
    jz .calcrepaint
    mov word [pl_msg], pl_s_calc_man
    jmp .calcrepaint
.calcnow:
    inc word [pl_pass]                ; a pass stamp nothing has cached, which
    mov word [pl_msg], pl_s_calc_now  ; is exactly what forces the recompute
.calcrepaint:
    mov si, [pl_ownwin]
    SHOUT pl_repaint
    jmp .out

.protdoc:
    mov word [pl_msg], pl_s_protdoc
.refused:
    mov si, [pl_ownwin]
    SHOUT pl_repaint
    jmp .out
.dopspec:
    mov al, [pl_fdlg_sel]             ; the radio IS the mode: All/Formulas/
    mov [pl_ps_mode], al              ; Values/Formats/Notes are PL_PS_ALL..
    SHOUT pl_docmd_paste               ; PL_PS_NOTE in that order, on purpose
    jmp .out
.dosavefmt:
    mov si, pl_s_ext_sylk             ; 0 SYLK / 1 CSV / 2 Text (81.75)
    mov ax, [pl_fdlg_sel]
    or ax, ax
    jz .fmtset
    mov si, pl_s_ext_csv
    cmp ax, 1
    je .fmtset
    mov si, pl_s_ext_txt
.fmtset:
    call pl_setext
    mov byte [pl_savepend], 1         ; the file dialog cannot open until
    jmp .out                          ; THIS one is destroyed - see .doOK

.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_fdlg_close
; -----------------------------------------------------------------------------
pl_fdlg_close:
    push ax
    push bx
    mov bx, [pl_fdlg_win]
    or bx, bx
    jz .out
    mov word [pl_fdlg_win], 0
    call OSAPI_WM_DESTROY               ; NOT OSAPI_WM_CLOSE. Close means
                                        ; "quit the instance owning this
                                        ; window" (app_close_win); a dialog
                                        ; has no owning instance, so that path
                                        ; falls through to a plain wm_hide -
                                        ; the pixels go but THE SLOT STAYS
                                        ; USED. MAX_WIN is 12, so ten dialogs
                                        ; into a session no dialog would open
                                        ; again, in this app or any other.
                                        ; os88api.inc names this exact case:
                                        ; the unowned species is "a driver's
                                        ; windows, and a package's second one".
                                        ; The gfx lock is already held - every
                                        ; callback holds it - which is what
                                        ; DESTROY wants (os88ui_adone does the
                                        ; same, gate first then destroy).
.out:
    pop bx
    pop ax
    ret

; =============================================================================
; The ONE-LINE INPUT DIALOG (stage 3.0c) - a prompt, an os88line field, OK and
; Cancel. Four menu items want exactly this and differ only in their prompt and
; in what OK does with the string, so it is written once with a KIND byte and
; a dispatch on it, the same way pl_fdlg_* already serves five radio-list
; kinds rather than being copied five times.
;
; This is what the text widget was for. Row Height... and Column Width... have
; been a THREE-PRESET RADIO PICK since stage 1.8 purely because no free-text
; entry existed at the app level - pl_m_format's own comment says so. They are
; now real numeric entry, which is what Excel 2.1d has.
; =============================================================================
PL_ID_GOTO   equ 0                   ; Formula > Goto...
PL_ID_ROWH   equ 1                   ; Format > Row Height...
PL_ID_COLW   equ 2                   ; Format > Column Width...
PL_ID_DEFN   equ 3                   ; Formula > Define Name...
PL_ID_FIND   equ 4                   ; Formula > Find...
PL_ID_SORT   equ 5                   ; Data > Sort... (stage 4.5): the KEY.
                                     ; Excel 2.1's Sort dialog takes its keys
                                     ; as cell references typed into fields,
                                     ; which is exactly what this engine is,
                                     ; and it is the only way to name a key
                                     ; that is not an edge of the selection
                                     ; (81.19 recorded that as a known limit;
                                     ; 81.27 is this)
PL_ID_RUN    equ 6                   ; Macro > Run... (81.63): where to start
PL_ID_INPUT  equ 7                   ; ...and INPUT(), a macro's own question
PL_ID_SERSTEP equ 8                  ; 81.72: Data ▸ Series...' step value,
PL_ID_RECNAME equ 9                  ; part two of two; 81.74: what to call
PL_ID_NKIND  equ 10                  ; the recording about to be made

PL_IDLG_W    equ 268
PL_IDLG_FX1  equ 8                   ; the field, content-relative
PL_IDLG_FY1  equ 28
PL_IDLG_FX2  equ 176
PL_IDLG_FY2  equ 46
PL_IDLG_BTX1 equ 186                 ; OK / Cancel, 64 wide - 'Cancel' needs
PL_IDLG_BTX2 equ 250                 ; 6 glyphs at the fixed 8px cell
PL_IDLG_OKY1 equ 26
PL_IDLG_OKY2 equ 46
PL_IDLG_CAY1 equ 54
PL_IDLG_CAY2 equ 74
PL_IDLG_H    equ PL_IDLG_CAY2 + PL_DLG_BMARG + TITLE_H + 1

pl_idlg_tpl:
    dw 0, 0, PL_IDLG_W, PL_IDLG_H
    dw pl_s_id_tgoto, pl_idlg_paint_r, pl_idlg_key_r, pl_idlg_click_r
; The title above is only a PLACEHOLDER: pl_idlg_open overwrites
; [pl_idlg_tpl + WT_TITLE] with whichever of pl_s_id_t* the kind names, before
; OSAPI_WM_CREATE. WT_TITLE is a pointer TO the text, so the pointer has to go
; into the template itself - putting it in a cell and pointing the template at
; that cell makes the kernel letter the pointer's own two bytes and then run on
; into whatever follows, which is exactly what it did.
pl_id_titles:  dw pl_s_id_tgoto, pl_s_id_trowh, pl_s_id_tcolw, pl_s_id_tdefn, pl_s_id_tfind
               dw pl_s_id_tsort, pl_s_id_trun, pl_s_id_tinput, pl_s_id_tser
               dw pl_s_id_trec
pl_id_prompts: dw pl_s_id_pgoto, pl_s_id_prowh, pl_s_id_pcolw, pl_s_id_pdefn, pl_s_id_pfind
               dw pl_s_id_psort, pl_s_id_pgoto, pl_macro_msg, pl_s_id_pser
               dw pl_s_id_prec
pl_s_id_trec:  db 'Record Macro', 0
pl_s_id_prec:  db 'Name:', 0
pl_s_id_tser:  db 'Series', 0
pl_s_id_pser:  db 'Step value:', 0
pl_s_id_tgoto: db 'Goto', 0
pl_s_id_trowh: db 'Row Height', 0
pl_s_id_tcolw: db 'Column Width', 0
pl_s_id_tdefn: db 'Define Name', 0
pl_s_id_tfind: db 'Find', 0
pl_s_id_tsort: db 'Sort', 0
pl_s_id_trun:  db 'Run', 0
pl_s_id_tinput: db 'Input', 0
pl_s_id_pgoto: db 'Reference:', 0
pl_s_id_prowh: db 'Row height:', 0
pl_s_id_pcolw: db 'Column width:', 0
pl_s_id_pdefn: db 'Name:', 0
pl_s_id_pfind: db 'Find what:', 0
pl_s_id_psort: db '1st Key:', 0     ; Excel 2.1's own label for the field
pl_s_idlg_ok:  db 'OK', 0
pl_s_idlg_can: db 'Cancel', 0
section PL_MODSEC                      ; 81.74.2: the one-line input dialog, CHART.OVL

; -----------------------------------------------------------------------------
; pl_idlg_open - in: AL = PL_ID_*. Preloads the field with the CURRENT value
; (the selection's reference, or the live row height / column width) so the
; dialog opens showing what it is about to change, and Enter alone is a no-op
; rather than a surprise.
; -----------------------------------------------------------------------------
pl_idlg_open:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    cmp word [pl_idlg_win], 0
    jne .out
    cmp al, PL_ID_NKIND
    jae .out
    mov [pl_idlg_kind], al
    xor ah, ah
    mov bx, ax
    shl bx, 1                          ; word index into the two tables
    mov ax, [pl_id_titles + bx]
    mov [pl_idlg_tpl + WT_TITLE], ax
    mov byte [pl_idlg_buf], 0
    cmp byte [pl_idlg_kind], PL_ID_DEFN ; key you get by pressing Enter
    jae .prenone                       ; Define Name and Find open EMPTY: there
    mov ax, [pl_selcol]                ; the SELECTED column's own width, in
    SHOUT pl_colwidth                   ; characters, matching what OK reads
    SHOUT pl_itoa
.precopy:
    mov di, pl_idlg_buf
    mov si, pl_numbuf
    SHOUT pl_strcpy_to_di
    jmp .haveinit
.pregoto:
    mov di, pl_idlg_buf                ; the selection, as 'A1'
    mov ax, [pl_selcol]
    SHOUT pl_colname
    mov si, pl_colbuf
    SHOUT pl_strcpy_to_di
    mov ax, [pl_selrow]
    inc ax
    SHOUT pl_itoa
    mov si, pl_numbuf
    SHOUT pl_strcpy_to_di
.prenone:
.haveinit:
    mov si, pl_idlg_line
    mov word [si + LN_BUF], pl_idlg_buf
    mov word [si + LN_MAX], PL_EDITMAX
    mov byte [si + LN_FOCUS], 1
    mov di, pl_idlg_buf
    SHOUT os88line_set                  ; sets LEN/CAR/VIEW from the content
    call OSAPI_VIDEO
    sub ax, PL_IDLG_W
    sar ax, 1
    mov [pl_idlg_tpl + WT_X], ax
    sub bx, PL_IDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8
.placed:
    mov [pl_idlg_tpl + WT_Y], bx
    mov si, pl_idlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [pl_idlg_win], bx
    call OSAPI_WM_SHOW
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_idlg_paint - SI = the dialog window
; -----------------------------------------------------------------------------
pl_idlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call OSAPI_WM_CONTENT
    mov [pl_idlg_ox], ax
    mov [pl_idlg_oy], dx
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov bl, [pl_idlg_kind]             ; the prompt for this kind
    xor bh, bh
    shl bx, 1
    mov si, [pl_id_prompts + bx]
    mov cx, [pl_idlg_ox]
    add cx, PL_IDLG_FX1
    mov dx, [pl_idlg_oy]
    add dx, 8
    call OSAPI_FONT_STR_XPARENT

    mov si, pl_idlg_line               ; the field's rect from the LIVE origin
    mov ax, [pl_idlg_ox]               ; every paint - the window moves
    add ax, PL_IDLG_FX1
    mov [si + LN_X1], ax
    mov ax, [pl_idlg_ox]
    add ax, PL_IDLG_FX2
    mov [si + LN_X2], ax
    mov ax, [pl_idlg_oy]
    add ax, PL_IDLG_FY1
    mov [si + LN_Y1], ax
    mov ax, [pl_idlg_oy]
    add ax, PL_IDLG_FY2
    mov [si + LN_Y2], ax
    SHOUT os88line_draw

    mov ax, [pl_idlg_ox]               ; OK
    add ax, PL_IDLG_BTX1
    mov [pl_idlg_rect], ax
    mov ax, [pl_idlg_oy]
    add ax, PL_IDLG_OKY1
    mov [pl_idlg_rect+2], ax
    mov ax, [pl_idlg_ox]
    add ax, PL_IDLG_BTX2
    mov [pl_idlg_rect+4], ax
    mov ax, [pl_idlg_oy]
    add ax, PL_IDLG_OKY2
    mov [pl_idlg_rect+6], ax
    mov bx, pl_idlg_rect
    mov si, pl_s_idlg_ok
    mov di, OS88UI_DEF
    SHOUT os88ui_btn
    mov ax, [pl_idlg_oy]               ; Cancel - same x, two new y's
    add ax, PL_IDLG_CAY1
    mov [pl_idlg_rect+2], ax
    mov ax, [pl_idlg_oy]
    add ax, PL_IDLG_CAY2
    mov [pl_idlg_rect+6], ax
    mov bx, pl_idlg_rect
    mov si, pl_s_idlg_can
    xor di, di
    SHOUT os88ui_btn

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_idlg_onkey - Enter is OK and Escape is Cancel, which is what a one-field
; dialog should do; os88line_key deliberately does NOT consume Enter (its own
; header says so) precisely so the caller can use it for this.
; -----------------------------------------------------------------------------
pl_idlg_onkey:
    push ax
    push si
    cmp al, 27
    je .cancel
    cmp al, 0x0D
    je .accept
    mov si, pl_idlg_line
    SHOUT os88line_key
    jc .out
    mov si, [pl_idlg_win]
    call pl_idlg_paint
    jmp .out
.accept:
    call pl_idlg_apply
    call pl_idlg_close
    jmp .out
.cancel:
    call pl_idlg_close
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_idlg_onclick - CX,DX = the click, screen-absolute
; -----------------------------------------------------------------------------
pl_idlg_onclick:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, pl_idlg_line               ; the field's rect is already
    SHOUT os88line_click                ; screen-absolute from the last paint
    jnc .redraw
    mov bx, [pl_idlg_win]
    push cx
    push dx
    call OSAPI_WM_CONTENT
    pop dx
    pop cx
    sub cx, ax
    sub dx, [pl_idlg_oy]
    cmp cx, PL_IDLG_BTX1
    jb .out
    cmp cx, PL_IDLG_BTX2
    ja .out
    cmp dx, PL_IDLG_OKY1
    jb .out
    cmp dx, PL_IDLG_OKY2
    jle .doOK
    cmp dx, PL_IDLG_CAY1
    jb .out
    cmp dx, PL_IDLG_CAY2
    jle .doCancel
    jmp .out
.redraw:
    mov si, [pl_idlg_win]
    call pl_idlg_paint
    jmp .out
.doOK:
    call pl_idlg_apply
    call pl_idlg_close
    jmp .out
.doCancel:
    call pl_idlg_close
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_idlg_apply - dispatch on the kind. A value this cannot make sense of is
; REFUSED SILENTLY and the old one kept, rather than being coerced to zero:
; a column of width 0 is invisible and a Goto to a reference that does not
; parse has nowhere to go, so doing nothing is the honest answer.
; -----------------------------------------------------------------------------
pl_idlg_apply:
    push ax
    push bx
    push cx
    push dx
    push si
    cmp byte [pl_idlg_kind], PL_ID_ROWH
    je .rowh
    mov si, pl_idlg_buf                ; the column width
    SHOUT pl_pnum_at
    jc .out                            ; not a number at all
    or ax, ax                          ; 81.73: ZERO HIDES IT, which is how
    jz .cwhide                         ; Excel hides a column and why this
    cmp ax, PL_CW_MINCH                ; COLUMN WIDTH IS IN CHARACTERS, which
    jb .out                            ; is Excel's own unit for it - the
    cmp ax, PL_CW_MAXCH                ; pixel width is a consequence, not the
    ja .out                            ; thing the user types
    ; THE SELECTED COLUMNS, each - Excel's Column Width (81.56). It set the
    ; one width the whole sheet had. The standard width is stored as 0, so a
    ; column set back to it costs a file nothing.
    mov cl, al
    cmp ax, [pl_defch]
    jne .cwset
    xor cl, cl
    jmp short .cwset
.cwhide:
    mov cl, PL_CW_HIDDEN               ; ...and a nonzero width typed over a
.cwset:                                ; selection that SPANS a hidden column
                                        ; unhides it, which is Excel's own way
                                        ; back and needs no second command:
                                        ; the loop below walks real columns
    mov ax, [pl_selcol]
    mov bx, [pl_selcol2]
    cmp ax, bx
    jbe .cwl
    xchg ax, bx
.cwl:
    SHOUT pl_colw_set
    inc ax
    cmp ax, bx
    jbe .cwl
    jmp .redraw
.rowh:
    ; ROW HEIGHT IS IN POINTS, Excel's unit, fractions allowed, and applies
; Data > Sort..., part one of two. The KEY is a reference, so it needs a field;
; the ORDER is a two-way pick, so it needs radios; and no dialog engine here
; has both. Asking in sequence is what File > Save As... already does - the
; format radio first, then the file dialog - so this follows the app's own
; idiom rather than growing a third engine.
; 81.74: the recording's own name, bound to the cell it is about to start in
; so Macro ▸ Run can list it. An EMPTY name is not a refusal - the Run dialog
; takes a reference too, and Excel's own Name field may be left alone.

; 81.72: the step value, and the whole of Data ▸ Series' second question.
; The TEXT is read rather than an integer parsed: Growth by 1.5 and a linear
; step of 0.25 are both ordinary, and pl_pnum_at answers integers only -
; which is what the three numeric kinds above it want and this one does not.
.redraw:
    SHOUT pl_geom                       ; the cell size may have changed, so the
    mov si, [pl_ownwin]                ; visible row/column counts must be
    SHOUT pl_repaint                    ; recomputed before anything is drawn
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_idlg_close
; -----------------------------------------------------------------------------
pl_idlg_close:
    push ax
    push bx
    mov bx, [pl_idlg_win]
    or bx, bx
    jz .out
    mov word [pl_idlg_win], 0
    call OSAPI_WM_DESTROY               ; see pl_fdlg_close on why not CLOSE
.out:
    pop bx
    pop ax
    ret

section .text


pl_fdlg_open_r:
    jmp pl_fdlg_open
pl_fdlg_paint_r:
    jmp pl_fdlg_paint
pl_fdlg_click_r:
    jmp pl_fdlg_onclick
pl_fdlg_close_r:
    jmp pl_fdlg_close
pl_idlg_open_r:
    jmp pl_idlg_open
pl_idlg_paint_r:
    jmp pl_idlg_paint
pl_idlg_key_r:
    jmp pl_idlg_onkey
pl_idlg_click_r:
    jmp pl_idlg_onclick


; -----------------------------------------------------------------------------
; pl_pnum_at - read an unsigned decimal from the NUL string at SI.
; out: CF=0 and AX = the value; CF=1 if there was no digit at all or it ran
; past 65535. Leading blanks are skipped; anything after the digits is
; ignored, so '12 wide' reads as 12.
; -----------------------------------------------------------------------------
pl_pnum_at:
    push bx
    push cx
    push dx
    push si
    xor ax, ax
    xor cx, cx                         ; cx = how many digits were seen
.skip:
    cmp byte [si], ' '
    jne .loop
    inc si
    jmp .skip
.loop:
    mov bl, [si]
    cmp bl, '0'
    jb .done
    cmp bl, '9'
    ja .done
    cmp ax, 6553                       ; 6553*10 is the last product that fits,
    ja .over                           ; checked BEFORE the shifts rather than
    mov dx, ax                         ; from the carry of one of them - the
    shl ax, 1                          ; first two can overflow silently
    shl ax, 1
    add ax, dx
    shl ax, 1                          ; ax = ax*10 (8086: shift by 1 or CL)
    sub bl, '0'
    xor bh, bh
    add ax, bx
    jc .over
    inc cx
    inc si
    jmp .loop
.done:
    or cx, cx
    jz .none
    clc
    jmp .out
.over:
.none:
    stc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    ret



; =============================================================================


section .text

pl_dlg:
    push bx
    push si
    push di
    mov bx, si
    mov di, pl_ondlg
    mov si, pl_name
    call OSAPI_FILE_DLG
    pop di
    pop si
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_ondlg - the file dialog's completion proc (SPEC.md 38.6)
; in:  AL=mode, SI=our window ptr, DI=chosen name (ES=KERNEL_SEG); UI task,
;      gfx lock HELD, dialog already destroyed - we owe the repaint
; -----------------------------------------------------------------------------
pl_ondlg:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bl, al
    mov cx, si                       ; CX = our window ptr (SI about to move)
    mov si, di
    mov di, pl_name
    mov dx, PL_NAMEMAX               ; the count lives in DX - the loop body
.copy:                               ; writes AL, so AX cannot hold it, and
    mov al, [es:si]                  ; CX holds the window
    mov [di], al
    or al, al
    jz .copied
    inc si
    inc di
    dec dx
    jnz .copy
    mov byte [di], 0
.copied:
    mov si, cx                       ; SI = our window again
    or bl, bl
    jz .load
    call pl_dowrite
    jmp short .draw
.load:
    call pl_doread
.draw:
    call pl_repaint
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_new - File > New: clear the sheet and the name, reselect A1
; -----------------------------------------------------------------------------
pl_new:
    push ax
    push cx
    push dx
    push si
    push di
    mov dx, si                       ; DX = window ptr, stashed
    mov si, pl_defname
    mov di, pl_name
    call pl_strcpy
    mov si, dx                       ; SI = window ptr, restored
    mov word [pl_ncells], 0
    mov word [pl_txtlen], 0
    SHOUT pl_colw_clear                ; ...and every column's width (81.56)
                                     ; into the next document and go on
                                     ; pointing at cells no longer there
                                     ; an OFFSET into the arena reset above,
                                     ; and would read new text through it
    mov word [pl_cursheet], 0
    mov cx, PL_SHEETS * 6            ; 6 words per sheet: sel/row/scl/scr,
                                      ; and 81.70's own fcl/frw
    mov di, pl_selsave
    xor ax, ax
.clrsave:
    mov [di], ax
    add di, 2
    loop .clrsave
    mov word [pl_selcol], 0
    mov word [pl_selrow], 0
    mov word [pl_scrollcol], 0
    mov word [pl_scrollrow], 0
    mov word [pl_freezecol], 0         ; 81.70: a new document is unfrozen,
    mov word [pl_freezerow], 0         ; like every other view setting here
    call pl_frzmark                    ; ...and the item says so again
    mov byte [pl_editing], 0
    mov word [pl_msg], 0
    call pl_repaint
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_switchsheet - in: AX = target sheet index (0..PL_SHEETS-1); saves the
; outgoing sheet's selection/scroll into its slot and restores the
; incoming sheet's own (all-zero the first time it's ever visited)
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; pl_sheetmark - point every Sheets item at its plain string, then the CURRENT
; one at its marked twin. Called at startup and after every switch, so the mark
; is derived from pl_cursheet rather than tracked alongside it.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; pl_frzmark - point Options' Freeze Panes item at whichever of its two
; labels the CURRENT state wants (81.70), derived rather than tracked - the
; same shape pl_sheetmark below uses for the Sheets menu's own tick, and the
; reason a sheet switch or a new document cannot leave "Unfreeze Panes"
; standing over a sheet that is not frozen.
; -----------------------------------------------------------------------------
pl_frzmark:
    push ax
    mov ax, [pl_freezecol]
    or ax, [pl_freezerow]
    jnz .on
    mov word [pl_i_options+8], pl_it_frz_off
    pop ax
    ret
.on:
    mov word [pl_i_options+8], pl_it_frz_on
    pop ax
    ret



; =============================================================================
; File I/O: SYLK write and read, over the sparse array directly
; =============================================================================

; -----------------------------------------------------------------------------
; pl_dowrite - write the sheet to [pl_name], format chosen by its extension
; (SPEC-free scope decision, this project's own: ".DIF" writes DIF,
; everything else writes SYLK, matching stage 1.0's default).
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; pl_sheets_used - out: AX = how many of the PL_SHEETS grids hold at least one
; cell, and BX = a bitmap of which. One walk of the array, not four.
; -----------------------------------------------------------------------------
section PL_MODSEC                      ; 82.16.9

; -----------------------------------------------------------------------------
; pl_dowrite - pick the writer from the file name's extension.
;
; AND SAY SO WHEN A SAVE CANNOT CARRY EVERYTHING. SYLK and DIF have no
; multi-sheet concept at all - SYLK has no notion of a sheet and DIF is one
; table - so a workbook with data on more than one of them loses the rest, and
; used to lose it in silence. It says so in the status bar now. BIFF is the one
; format here that CAN carry them, and does (81.10.5).
; -----------------------------------------------------------------------------
plm_dowrite:
    push si
    push di
    mov si, pl_name
    mov di, pl_s_ext_csv
    SHOUT pl_nameends
    pop di
    pop si
    jc .csv
    push si
    push di
    mov si, pl_name
    mov di, pl_s_ext_txt
    SHOUT pl_nameends
    pop di
    pop si
    jc .txt
    call pl_dowrite_sylk
    jmp .warn
.csv:
    call pl_dowrite_csv
    jmp .warn
.txt:
    call pl_dowrite_txt
    jmp .warn
.warn:
    push ax
    push bx
    cmp word [pl_msg], pl_m_saved     ; only upgrade a plain success: a failed
    jne .warned                       ; write's "Err N" (or a truncated save's
                                      ; message) must not be replaced by a
                                      ; string that begins with "Saved"
.warned:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_wr_colw - SYLK's F;W<first> <last> <width> for every column of the
; current sheet that is not the standard width, at ES:DI (81.56)
; -----------------------------------------------------------------------------
pl_wr_colw:
    push ax
    push bx
    push si
    xor bx, bx
.l:
    mov ax, bx
    SHOUT pl_colwidth
    cmp ax, [pl_defch]
    je .n
    push ax
    mov si, pl_s_sylk_fw
    call pl_stgput
    mov ax, bx
    inc ax
    SHOUT pl_itoa
    mov si, pl_numbuf
    call pl_stgput
    mov al, ' '
    call pl_stgputb
    mov si, pl_numbuf
    call pl_stgput
    mov al, ' '
    call pl_stgputb
    pop ax
    SHOUT pl_itoa
    mov si, pl_numbuf
    call pl_stgput
    mov si, pl_s_crlf
    call pl_stgput
.n:
    inc bx
    cmp bx, 256
    jb .l
    pop si
    pop bx
    pop ax
    ret


; -----------------------------------------------------------------------------
; pl_dowrite_sylk - write the sheet to [pl_name] as SYLK. Walks the sorted
; cell array directly (already row-major), so no grid loop is needed at
; all. A formatted cell's C (value) record is followed by a real SYLK F
; (formatting) record - "F;X<col>;Y<row>;F<c1><n><c2>[;K]" - using
; MultiPlan-era SYLK's actual format codes (stage 1.6): c1 is '$' for
; Currency or 'G' for everything else (General/Comma/Percent all share
; 'G' - real SYLK has no comma or percent code of its own; Comma instead
; sets the separate ;K "commas are set" flag, and Percent has no real
; equivalent at all so it degrades to General on disk), c2 is the real
; alignment code (G/L/C/R) matching this app's own alignment 1:1. Real
; SYLK, per the era's own documentation, has no bold/underline concept
; whatsoever - MultiPlan predates that - so neither persists here; this is
; the same "only persist what the real format actually has" rule DIF
; follows below, not an oversight.
; -----------------------------------------------------------------------------
pl_dowrite_sylk:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [pl_stgseg]
    xor di, di
    mov si, pl_s_id
    call pl_stgput
    call pl_wr_colw                   ; 81.56: F;W for each column's width
                                       ; reader that is not this app can find
                                       ; the ranges too (81.29.1)

    mov byte [pl_trunc], 0
    mov word [pl_wrow], 0            ; reused here as the record index
.rec:
    mov bx, [pl_wrow]
    cmp bx, [pl_ncells]
    jae .footer
    cmp byte [pl_trunc], 0
    jne .footer
    mov ax, di
    add ax, 200                      ; worst case a LABEL's C line: the head
                                      ; ("C;X256;Y16384;K"), the quoted text
                                      ; with every embedded quote DOUBLED
                                      ; (2 + 2*PL_EDITMAX), CRLF, plus its
                                      ; F line ("F;X256;Y16384;F$0R;K\r\n");
                                      ; the ;E formula case is smaller
    cmp ax, PL_STAGE_MAX
    jbe .room
    mov byte [pl_trunc], 1
    jmp .footer
.room:
    mov ax, bx
    mov cx, PL_C_SZ
    mul cx
    mov si, ax                        ; SI = this record's offset in cellseg
    push es
    mov es, [pl_cellseg]
    mov ax, [es:si]
    SHOUT pl_unpackrow                 ; -> ax=real row, bx=this record's
                                       ; sheet (see the stage 2.0 comment
                                       ; above the cell record layout)
    cmp bx, [pl_cursheet]
    jne .recskip                      ; a save only ever writes the CURRENT
                                       ; sheet - the array may hold other
                                       ; sheets' records too, interleaved
    mov [pl_wrec_row], ax
    mov ax, [es:si+2]
    mov [pl_wrec_col], ax
    mov word [pl_wrec_foff], 0xFFFF   ; ...and this cell's formula, if it has
    test byte [es:si+4], 1            ; one: SYLK carries the EXPRESSION in a
    jz .noformula_w                   ; ;E field beside the cached ;K value,
    mov ax, [es:si+PL_C_FOFF]         ; which is what makes a saved sheet a
    mov [pl_wrec_foff], ax            ; spreadsheet rather than a table of
.noformula_w:                         ; numbers
    SHOUT pl_cellval_to_acc_si         ; bank the whole value: the row and
    push si                           ; column are formatted through pl_numbuf
    push di                           ; before it is wanted, so it cannot be
    mov si, pl_acc                    ; turned into text here
    mov di, pl_wrec_dval
    mov ax, [si]
    mov [di], ax
    mov ax, [si+2]
    mov [di+2], ax
    mov ax, [si+4]
    mov [di+4], ax
    mov ax, [si+6]
    mov [di+6], ax
    pop di
    pop si
    mov ax, [es:si+PL_C_VAL]
    mov [pl_wrec_val], ax
    mov al, [es:si+5]
    mov [pl_wrec_fmt], al
    mov al, [es:si+PL_C_AUX]
    mov [pl_wrec_aux], al
    mov al, [es:si+PL_C_TYPE]         ; stage 4.5: and the tag, because a LABEL
    mov [pl_wrec_type], al            ; goes out as a QUOTED K field rather
    mov ax, [es:si+PL_C_FOFF]         ; than as a number, and its characters
    mov [pl_wrec_toff], ax            ; come from the same arena a formula's do
    test byte [es:si+4], 1            ; A FORMULA THAT RETURNED TEXT keeps its
    jz .toffok1                          ; result in PL_C_VAL, because FOFF is
    cmp byte [es:si+PL_C_TYPE], PL_T_TEXT  ; already holding the formula's own
    jne .toffok1                         ; text (81.22.1) - so the label this
    mov ax, [es:si+PL_C_VAL]          ; writer emits is the RESULT, not the
    mov [pl_wrec_toff], ax            ; expression that produced it
.toffok1:
    pop es                            ; ES = stgseg again

    mov si, pl_s_c
    call pl_stgput
    mov ax, [pl_wrec_col]
    inc ax
    SHOUT pl_itoa
    mov si, pl_numbuf
    call pl_stgput
    mov si, pl_s_y
    call pl_stgput
    mov ax, [pl_wrec_row]
    inc ax
    SHOUT pl_itoa
    mov si, pl_numbuf
    call pl_stgput
    cmp word [pl_wrec_foff], 0xFFFF   ; ";E<expr>" comes BEFORE ";K", the
    je .noexpr                        ; order a real file from the period uses
    push si
    push di
    mov ax, [pl_wrec_col]             ; every relative offset is measured from
    mov [pl_rc_ccol], ax              ; the cell being written
    mov ax, [pl_wrec_row]
    mov [pl_rc_crow], ax
    push es
    mov es, [pl_txtseg]               ; copy the formula text out of the arena
    mov si, [pl_wrec_foff]            ; into DS, where the converter reads
    mov di, pl_rwsrc
    mov cx, PL_EDITMAX
.ecopy:
    mov al, [es:si]
    mov [di], al
    or al, al
    jz .ecopied
    inc si
    inc di
    dec cx
    jnz .ecopy
    mov byte [di], 0
.ecopied:
    pop es
    mov si, pl_rwsrc
    call pl_formula_to_r1c1
    pop di
    pop si
    mov si, pl_s_e
    call pl_stgput
    mov si, pl_rwdst                  ; ...with every ';' DOUBLED, as the K
.edbl:                                ; field's are: a string constant can
    mov al, [si]                      ; hold one, and a single one ends the
    or al, al                         ; field there, in a file that parses
    jz .noexpr
    inc si
    cmp al, ';'
    jne .edbl1
    call pl_stgputb
.edbl1:
    call pl_stgputb
    jmp short .edbl
.noexpr:
    mov si, pl_s_k
    call pl_stgput
    cmp byte [pl_wrec_type], PL_T_TEXT
    je .ktext
    cmp byte [pl_wrec_type], PL_T_BOOL ; a LOGICAL is QUOTED, Walden's rule:
    je .kbool                          ; "Logical values TRUE and FALSE must
                                       ; also be quoted" (81.51)
    cmp byte [pl_wrec_type], PL_T_ERR ; ...and an ERROR is its NAME, bare. The
    je .kerr                          ; leading '#' is what tells it from a
    push si                           ; SYLK's K field IS a decimal literal,
    push di                           ; so the full value goes out, not a
    mov si, pl_wrec_dval              ; truncation of it
    SHOUT fx_unpack_a
    mov di, pl_numbuf
    mov ax, 10
    SHOUT fx_ftoa
    pop di
    pop si
    mov si, pl_numbuf
    call pl_stgput
    jmp .kdone
.kerr:
    ; number, on both sides - no number starts with one, and SYLK has no type
    ; field to consult. Writing the value UNDERNEATH an error instead (a zero)
    ; is what this did, and it turned #DIV/0! into a perfectly ordinary 0 on
    ; the next load.
    push ax
    mov al, [pl_curaux]               ; pl_errname names the CURRENT cell, and
    push ax                           ; a save is not a paint - bank what the
    mov al, [pl_wrec_aux]             ; painter left there
    mov [pl_curaux], al
    SHOUT pl_errname                   ; -> pl_numbuf
    pop ax
    mov [pl_curaux], al
    pop ax
    mov si, pl_numbuf
    call pl_stgput
    jmp .kdone
.kbool:
    mov al, 34
    call pl_stgputb
    mov ax, [pl_wrec_dval]
    SHOUT pl_boolname
    mov si, pl_numbuf
    call pl_stgput
    mov al, 34
    call pl_stgputb
    jmp .kdone
.ktext:
    ; A LABEL'S K FIELD IS QUOTED, and that is the whole of how SYLK tells text
    ; from a number - there is no type field to consult, on either side.
    ; SYLK HAS TWO RESERVED CHARACTERS AND BOTH ARE ESCAPED BY DOUBLING.
    ; The quote was always doubled here, because the charset gate admits one
    ; and a bare one would end the field early. The SEMICOLON was not, and it
    ; is the worse of the two: it is the FIELD SEPARATOR, so a label
    ; containing one was written as `K"a;b"` and any conforming reader splits
    ; that into a `K"a` field and a stray `b"` - the text silently truncated
    ; at the semicolon, in a file that still parses. Walden: "Any field
    ; containing the reserved semicolon character must have two of them."
    ;
    ; This was invisible for as long as SHEET was the only thing that ever
    ; read the file, because 81.38's reader did not double it either and the
    ; two errors cancelled exactly.
    mov al, 34
    call pl_stgputb
    mov si, [pl_wrec_toff]
.kt:
    push es
    mov es, [pl_txtseg]
    mov al, [es:si]
    pop es
    or al, al
    jz .ktend
    inc si
    cmp al, 34
    je .kdup
    cmp al, ';'
    jne .kt1
.kdup:
    call pl_stgputb                   ; doubled: a quote or a semicolon
.kt1:
    call pl_stgputb
    jmp .kt
.ktend:
    mov al, 34
    call pl_stgputb
.kdone:
    mov si, pl_s_crlf
    call pl_stgput

    mov al, [pl_wrec_fmt]
    and al, (PL_FMT_ALIGN_MASK | PL_FMT_NUM_MASK)
    jz .noformat                      ; bold/underline alone don't get an F
                                       ; record - real SYLK has no code for
                                       ; either, see pl_parsefrec's comment
    mov si, pl_s_sylk_fx               ; "F;X"
    call pl_stgput
    mov ax, [pl_wrec_col]
    inc ax
    SHOUT pl_itoa
    mov si, pl_numbuf
    call pl_stgput
    mov si, pl_s_y
    call pl_stgput
    mov ax, [pl_wrec_row]
    inc ax
    SHOUT pl_itoa
    mov si, pl_numbuf
    call pl_stgput
    mov si, pl_s_sylk_ff                ; ";F"
    call pl_stgput
    mov bl, [pl_wrec_fmt]
    and bl, PL_FMT_NUM_MASK
    mov cl, PL_FMT_NUM_SHIFT
    shr bl, cl
    mov al, '$'
    cmp bl, PL_FMT_NUM_CURRENCY
    je .c1ok
    mov al, 'G'
.c1ok:
    call pl_stgputb                      ; c1
    mov al, '0'
    call pl_stgputb                      ; n (digit count - always 0, this
                                         ; app's values are whole numbers)
    mov al, [pl_wrec_fmt]
    and al, PL_FMT_ALIGN_MASK
    mov cl, PL_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, PL_FMT_ALIGN_LEFT
    je .c2l
    cmp al, PL_FMT_ALIGN_CENTER
    je .c2c
    cmp al, PL_FMT_ALIGN_RIGHT
    je .c2r
    mov al, 'G'
    jmp .c2ok
.c2l:
    mov al, 'L'
    jmp .c2ok
.c2c:
    mov al, 'C'
    jmp .c2ok
.c2r:
    mov al, 'R'
.c2ok:
    call pl_stgputb                      ; c2
    cmp bl, PL_FMT_NUM_COMMA
    jne .nok
    mov si, pl_s_k
    call pl_stgput                      ; ";K"
.nok:
    mov si, pl_s_crlf
    call pl_stgput
.noformat:
    jmp .recnext
.recskip:
    pop es
.recnext:
    mov ax, [pl_wrow]
    inc ax
    mov [pl_wrow], ax
    jmp .rec
.footer:
    mov si, pl_s_end
    call pl_stgput
    mov [pl_stagelen], di

    mov ax, [pl_stgseg]
    mov es, ax
    xor bx, bx
    mov cx, [pl_stagelen]
    xor dx, dx
    mov si, pl_name
    call OSAPI_FILE_WRITE
    jc .werr
    mov word [pl_msg], pl_m_saved
    cmp byte [pl_trunc], 0            ; cells dropped for room must not be
    je .wdone                         ; reported as a plain success
    mov word [pl_msg], pl_m_trunc
    jmp .wdone
.werr:
    call pl_setferr
.wdone:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_stgput - append DS:SI (NUL-terminated) to ES:DI, advancing DI. ES must
; already be the staging segment (the caller's job); no NUL is written to
; the destination, since the staging buffer is a raw byte stream whose
; total length is tracked separately, not a re-readable C string.
; -----------------------------------------------------------------------------
pl_stgput:
    push ax
.loop:
    mov al, [si]
    or al, al
    jz .done
    mov [es:di], al
    inc si
    inc di
    jmp .loop
.done:
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_doread - read [pl_name], format chosen by its extension (see pl_dowrite)
; -----------------------------------------------------------------------------
plm_doread:
    push si
    push di
    mov si, pl_name
    mov di, pl_s_ext_csv
    SHOUT pl_nameends
    pop di
    pop si
    jc .csv
    push si
    push di
    mov si, pl_name
    mov di, pl_s_ext_txt
    SHOUT pl_nameends
    pop di
    pop si
    jc .txt
    jmp pl_doread_sylk
.csv:
    jmp pl_doread_csv
.txt:
    jmp pl_doread_txt

; -----------------------------------------------------------------------------
; pl_doread_sylk - read [pl_name] as SYLK, replacing the sheet
; -----------------------------------------------------------------------------
pl_doread_sylk:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [pl_stgseg]
    xor bx, bx
    mov cx, PL_STAGE_MAX
    xor dx, dx
    mov si, pl_name
    call OSAPI_FILE_READ              ; out: DX:AX = bytes read, or CF=1
    jc .rerr

    mov word [pl_ncells], 0
    mov word [pl_txtlen], 0           ; "replacing the sheet" means the old
    mov word [pl_nbord], 0            ; document's arena text, borders and
    mov word [pl_nnote], 0            ; notes too, not just its cells
    SHOUT pl_colw_clear                ; ...and every column's width (81.56)
    mov cx, ax                        ; a file this small never exceeds 64KB
    xor si, si
    call pl_parseslk
    mov word [pl_msg], pl_m_loaded
    jmp .out
.rerr:
    call pl_setferr
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; File I/O: DIF write and read - the "expanded file format" alongside SYLK
; (SPEC-free, this project's own subset - round-trips against itself, like
; the SYLK subset already does, not certified interchange with a specific
; external product, but DOES follow the real per-cell data-line grammar so
; a genuine DIF-reading program can open it). DIF is fundamentally DENSE -
; it declares a column and row count up front and must then supply a value
; for every cell in that rectangle - so unlike SYLK's sparse C-records, the
; write walks the sheet's USED BOUNDING BOX (pl_difbbox), not the full
; 256x16384 grid: a handful of cells clustered near the origin, which is
; what this stage's sheets actually look like, stays a small file; the
; roadmap's full grid size is a ceiling on what a cell address can BE, not
; a promise that every format scales to a dense encoding of all of it.
;
; Each occupied cell is written as real DIF's numeric data item: type 0
; (NUMERIC), the value, then the literal value-indicator keyword V (valid)
; on its own line - NOT a comment string. An earlier version of this
; writer got this wrong (it emitted an empty quoted comment string, "",
; where V belongs, since a type-0 item has no comment-string line at all
; in the real format) and marked a gap in the bounding box as type 1
; (STRING) with the bare word NA where a quoted string was required; both
; are fixed now - a gap is type 0 with the NA indicator instead, per the
; real spec's own "0 - numeric type ... indicator: V/NA/ERROR/TRUE/FALSE"
; rule. On read, TRUE and FALSE are the logical (81.51) and ERROR is #N/A;
; any other indicator (a foreign file's NA) means "leave this cell blank",
; the same as this app's own concept of empty. Like SYLK, only the cached VALUE is carried -
; a formula's source text is not, and per the user's explicit direction
; this stage does NOT extend DIF with any per-cell formatting: real DIF
; has no such concept (unlike real SYLK, which has actual P/font records -
; see the SYLK section below), so this format only ever carries values.
; =============================================================================

; -----------------------------------------------------------------------------
; pl_nameends - in: SI=name (NUL-terminated), DI=suffix (NUL-terminated);
; out: CF=1 if name ends with suffix (case-sensitive: 8.3 names arrive
; already uppercase from the kernel, and so do the suffixes this file
; compares against)
; -----------------------------------------------------------------------------
section .text
pl_nameends:
    push ax
    push bx
    push cx
    push si
    push di
    xor cx, cx
    mov bx, si
.namelen:
    cmp byte [bx], 0
    je .havenamelen
    inc bx
    inc cx
    jmp .namelen
.havenamelen:
    push cx                          ; CX = strlen(name)
    xor cx, cx
    mov bx, di
.suflen:
    cmp byte [bx], 0
    je .havesuflen
    inc bx
    inc cx
    jmp .suflen
.havesuflen:
    pop bx                           ; BX = strlen(name), CX = strlen(suffix)
    cmp cx, bx
    ja .no                           ; suffix longer than the whole name
    mov ax, si
    add ax, bx
    sub ax, cx                       ; AX = name + (namelen - suflen)
    mov si, ax
.cmp:
    or cx, cx
    jz .yes
    mov al, [si]
    cmp al, [di]
    jne .no
    inc si
    inc di
    dec cx
    jmp .cmp
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_difbbox - the sheet's used bounding box (0,0)-(pl_bbcol,pl_bbrow),
; both 0 for an empty sheet. pl_bbrow is free (the array is row-sorted, so
; it is just the last record's row); pl_bbcol needs a scan.
; -----------------------------------------------------------------------------
section PL_MODSEC                      ; 82.16.9
plm_difbbox:
    push ax
    push bx
    push cx
    push si
    push es
    mov word [pl_bbrow], 0
    mov word [pl_bbcol], 0
    cmp word [pl_ncells], 0
    je .out
    mov es, [pl_cellseg]
    xor cx, cx
.scan:
    cmp cx, [pl_ncells]
    jae .out
    mov ax, cx
    mov bx, PL_C_SZ
    mul bx
    mov si, ax                        ; si = this record's byte offset
    mov ax, [es:si]                   ; packed row/sheet (stage 2.0)
    SHOUT pl_unpackrow                 ; -> ax=real row, bx=sheet
    cmp bx, [pl_cursheet]
    jne .next                         ; a sheet's records aren't
                                       ; necessarily contiguous from index 0,
                                       ; so this scans every record rather
                                       ; than assuming the last one is ours
    cmp ax, [pl_bbrow]
    jbe .rowok
    mov [pl_bbrow], ax
.rowok:
    mov ax, [es:si+2]                 ; this record's col
    cmp ax, [pl_bbcol]
    jbe .next
    mov [pl_bbcol], ax
.next:
    inc cx
    jmp .scan
.out:
    pop es
    pop si
    pop cx
    pop bx
    pop ax
    ret


; -----------------------------------------------------------------------------
; pl_stgputb - append raw byte AL to ES:DI, advancing DI by 1. ES must
; already be the staging segment (the caller's job, as with pl_stgput).
; Used for a BIFF length-prefix byte (pl_biffw only writes whole words) and
; for a SYLK F record's single-character format codes.
; -----------------------------------------------------------------------------
pl_stgputb:
    mov [es:di], al
    inc di
    ret


section .text

; -----------------------------------------------------------------------------
; pl_biff_numfmt_from_id - in: AL = a real BIFF built-in number-format id;
; out: AL = this app's PL_FMT_NUM_* code (General for anything that isn't
; one of the four ids pl_biff_numfmt_tab itself ever writes - a custom
; FORMAT record's id, or a built-in this app doesn't have an equivalent
; for, both just degrade to General rather than guessed at)
; -----------------------------------------------------------------------------
section PL_MODSEC                      ; 82.16.9
; pl_cwbyte - AX = a width in characters from a file -> CL = what the width
; table keeps: clamped to what the Column Width dialog allows, and 0 for the
; standard width, so a file that states it costs the table nothing (81.56)
pl_cwbyte:
    cmp ax, PL_CW_MINCH
    jae .a
    mov ax, PL_CW_MINCH
.a:
    cmp ax, PL_CW_MAXCH
    jbe .b
    mov ax, PL_CW_MAXCH
.b:
    mov cl, al
    cmp ax, [pl_defch]
    jne .c
    xor cl, cl
.c:
    ret


; -----------------------------------------------------------------------------
; pl_parseslk - walk every line of a buffer, applying each 'C' record found
; in: SI = buffer start (offset in ES), CX = length; ES = the buffer's
; segment (the caller's job, e.g. pl_doread sets it to pl_stgseg)
; -----------------------------------------------------------------------------
pl_parseslk:
    push ax
    push bx
    push dx
    push si
    push di
    mov di, si
    add di, cx
.lineloop:
    cmp si, di
    jae .donelines
    mov bx, si
.findeol:
    cmp bx, di
    jae .goteol
    mov al, [es:bx]
    cmp al, 13
    je .goteol
    cmp al, 10
    je .goteol
    inc bx
    jmp .findeol
.goteol:
    mov ax, bx
    sub ax, si
    ; 81.75: the NN record - a DEFINED NAME - is not read or written any
    ; more. Nothing in this build can make one, so a file that carries them
    ; simply loses them, which is what SYLK's own "unknown record" rule
    ; already says happens to everything else it does not know.
.not2:
    cmp ax, 2
    jb .advance
    cmp byte [es:si+1], ';'
    jne .advance
    cmp byte [es:si], 'C'
    jne .notc
    push si
    add si, 2
    call pl_parsecrec                ; in: SI=tokens start, BX=line end
    pop si
    jmp .advance
.notc:
    cmp byte [es:si], 'F'
    jne .advance
    push si
    add si, 2
    call pl_parsefrec                ; in: SI=tokens start, BX=line end
    pop si
.advance:
    mov si, bx
.skipterm:
    cmp si, di
    jae .lineloop
    mov al, [es:si]
    cmp al, 13
    je .isterm
    cmp al, 10
    je .isterm
    jmp .lineloop
.isterm:
    inc si
    jmp .skipterm
.donelines:
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_parsenrec - one 'NN' record: NN;N<name>;E<R1C1>[:<R1C1>]
; in: SI = start of tokens (right after "NN;"), BX = line end (exclusive);
; ES = the buffer's segment, same as pl_parseslk's caller set
;
; This is the other half of pl_wr_names, and it was missing. Sheet wrote these
; records so CHART could find a named range (82.15) and never read one itself,
; so a name survived being saved and did not survive being loaded - the file
; was right and the app forgot. Fields are taken in any order, like the 'C'
; record's, because a SYLK writer is not obliged to emit them in ours.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; pl_parsecrec - the fields of one 'C' record, order-independent
; in: SI = start of tokens (right after "C;"), BX = line end (exclusive);
; ES = the buffer's segment, same as pl_parseslk's caller set
; -----------------------------------------------------------------------------
pl_parsecrec:
    push ax
    push bx
    push si
    mov word [PL_TCOL], 0
    mov word [PL_TROW], 0
    mov word [PL_TVAL], 0
    mov byte [PL_THASE], 0
    mov byte [PL_TISTXT], 0
    mov byte [PL_TISERR], 0
    mov word [PL_TDVAL], 0
    mov word [PL_TDVAL+2], 0
    mov word [PL_TDVAL+4], 0
    mov word [PL_TDVAL+6], 0
    mov byte [PL_THAVE], 0
.tok:
    cmp si, bx
    jae .apply
    mov al, [es:si]
    cmp al, ';'
    je .skipsemi
    cmp al, 'X'
    je .isx
    cmp al, 'Y'
    je .isy
    cmp al, 'K'
    je .isk
    cmp al, 'E'
    je .ise
.scan:
    cmp si, bx
    jae .apply
    mov al, [es:si]
    inc si
    cmp al, ';'
    jne .scan
    jmp .tok
.skipsemi:
    inc si
    jmp .tok
.isx:
    inc si
    SHOUT pl_pint
    mov [PL_TCOL], ax
    jmp .tok
.isy:
    inc si
    SHOUT pl_pint
    mov [PL_TROW], ax
    jmp .tok
.isk:
    inc si
    cmp si, bx                        ; stage 4.5: a QUOTED K field is a label.
    jae .knum                         ; SYLK has no type field - the quotes are
    cmp byte [es:si], '#'             ; the entire signal, on both sides, and
    je .kerr                          ; a leading '#' is an ERROR VALUE for
    cmp byte [es:si], 34              ; the same reason
    jne .knum
    inc si                            ; past the opening quote
    push di
    mov di, pl_rwsrc                  ; pl_rwsrc, NOT PL_TEXPR - the same
    mov cx, PL_EDITMAX                ; correction .kerr below already carries,
                                      ; and for the same reason. This used to
                                      ; say "the same buffer ;E uses, and never
                                      ; at the same time: a label has no
                                      ; formula", which is true of a LABEL and
                                      ; false of A FORMULA WHOSE RESULT IS
                                      ; TEXT. That cell writes both fields -
                                      ; `;EVLOOKUP("SU",...);K"Mulcahy"` - with
                                      ; ;E first, so the cached text landed on
                                      ; top of the formula and the cell loaded
                                      ; as `=Mulcahy`, which is #NAME?.
                                      ;
                                      ; Every text-returning function was
                                      ; affected - UPPER, LEFT, TEXT, the
                                      ; lookups when they find a label - and
                                      ; only on the RELOAD, so the sheet that
                                      ; wrote the file was still right on
                                      ; screen. 81.22 made a formula able to
                                      ; answer with text long after this loop
                                      ; was written, and nothing came back to
                                      ; re-read the premise.
.kt:
    jcxz .ktend
    cmp si, bx
    jae .ktend
    mov al, [es:si]
    cmp al, 13
    je .ktend
    cmp al, 10
    je .ktend
    cmp al, 34
    jne .ktsemi
    inc si                            ; a quote: doubled means one literal
    cmp si, bx                        ; quote, single means end of field
    jae .ktend
    cmp byte [es:si], 34
    jne .ktend
    jmp .ktkeep
.ktsemi:
    cmp al, ';'                       ; ...and the SEMICOLON is the same rule,
    jne .ktkeep                       ; which this loop did not know: it is
    inc si                            ; the field separator, so a doubled one
    cmp si, bx                        ; is one literal ';' and a single one
    jae .ktend                        ; ends the field even inside the quotes
    cmp byte [es:si], ';'
    jne .ktend
.ktkeep:
    mov [di], al
    inc di
    inc si
    dec cx
    jmp .kt
.ktend:
    mov byte [di], 0
    pop di
    mov byte [PL_TISTXT], 1
    mov byte [PL_THAVE], 1
    jmp .tok
.kerr:
    push di                           ; the name goes into pl_rwsrc, NOT into
    mov di, pl_rwsrc                  ; PL_TEXPR: a FORMULA cell writes both
    mov cx, PL_EDITMAX                ; ;E and ;K, ;E comes first, and parsing
                                       ; the ;K into ;E's buffer overwrote the
                                       ; formula with the error's name - which
                                       ; then went in as the cell's formula,
                                       ; `=#DIV/0!`, and evaluated to #VALUE!
.ke:
    jcxz .keend
    cmp si, bx
    jae .keend
    mov al, [es:si]
    cmp al, ';'
    je .keend
    cmp al, 13
    je .keend
    cmp al, 10
    je .keend
    mov [di], al
    inc di
    inc si
    dec cx
    jmp .ke
.keend:
    mov byte [di], 0
    pop di
    push si
    mov si, pl_rwsrc
    call pl_errcode                   ; -> AL, 0 for a spelling we do not know
    pop si
    mov [PL_TISERR], al
    mov byte [PL_THAVE], 1
    jmp .tok
.knum:
    call pl_esatof                    ; a full decimal, not an integer
    push ax
    push si
    push di
    mov si, pl_acc
    mov di, PL_TDVAL
    mov ax, [si]
    mov [di], ax
    mov ax, [si+2]
    mov [di+2], ax
    mov ax, [si+4]
    mov [di+4], ax
    mov ax, [si+6]
    mov [di+6], ax
    pop di
    pop si
    pop ax
    mov byte [PL_THAVE], 1
    jmp .tok
.ise:
    inc si
    push di                           ; the expression, copied out of the
    mov di, PL_TEXPR                  ; staging segment into DS so the R1C1
    mov cx, PL_EDITMAX                ; converter can read it
.ecpy:
    jcxz .ecpyd
    cmp si, bx
    jae .ecpyd
    mov al, [es:si]
    cmp al, ';'                       ; the field separator ends it - unless
    jne .ecnl                         ; DOUBLED, Walden's escape, which is one
    inc si                            ; literal ';' - in a string constant, the
    cmp si, bx                        ; one place a formula can hold one. This
    jae .ecpyd                        ; loop took the first of the pair as the
    cmp byte [es:si], ';'             ; field's end, as .kt did for labels
    jne .ecpyd                        ; until 81.38.1
    jmp short .eckeep
.ecnl:
    cmp al, 13
    je .ecpyd
    cmp al, 10
    je .ecpyd
.eckeep:
    mov [di], al
    inc di
    inc si
    dec cx
    jmp .ecpy
.ecpyd:
    mov byte [di], 0
    pop di
    mov byte [PL_THASE], 1
    jmp .tok
.apply:
    cmp byte [PL_THAVE], 0
    je .out
    mov ax, [PL_TCOL]
    cmp ax, 1
    jb .out
    cmp ax, PL_COLS
    ja .out
    mov cx, [PL_TROW]
    cmp cx, 1
    jb .out
    cmp cx, PL_ROWS
    ja .out
    dec ax
    dec cx
    mov bx, cx
    cmp byte [PL_THASE], 0            ; a ;E field wins over ;K: the value is
    je .notformula_c                  ; only the cached result of it, and
    push ax                           ; storing that instead would flatten the
    push bx                           ; formula exactly as this used to
    push si
    push di
    mov [pl_rc_ccol], ax
    mov [pl_rc_crow], bx
    mov si, PL_TEXPR
    call pl_formula_from_r1c1
    pop di
    pop si
    pop bx
    pop ax
    mov si, pl_rwdst                  ; AFTER the pops: setting SI before them
    SHOUT pl_setformula                ; put the saved value straight back over
                                      ; it, and pl_setformula stored whatever
                                      ; the staging pointer happened to be
    jmp .out
.notformula_c:
    cmp byte [PL_TISERR], 0
    je .noterr_c
    mov dl, [PL_TISERR]
    SHOUT pl_seterr
    jmp .out
.noterr_c:
    cmp byte [PL_TISTXT], 0
    je .plainval_c
    push si
    mov si, pl_rwsrc                  ; where .isk's quoted ;K now lands
    SHOUT pl_setlabel                 ; "TRUE" quoted is the LOGICAL: Walden
    pop si                            ; quotes both, so the spelling decides,
    jmp .out                          ; as it does when one is typed (81.51)
.plainval_c:
    push si
    push di
    mov si, PL_TDVAL
    mov di, pl_acc
    push ax
    mov ax, [si]
    mov [di], ax
    mov ax, [si+2]
    mov [di+2], ax
    mov ax, [si+4]
    mov [di+4], ax
    mov ax, [si+6]
    mov [di+6], ax
    pop ax
    pop di
    pop si
    SHOUT pl_setvald
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_parsefrec - the fields of an "F" (formatting) record, stage 1.6's real
; SYLK support. In: SI = start of tokens (right after "F;"), BX = line end
; (exclusive); ES = the buffer's segment. Real SYLK's F record predates
; MultiPlan-era bold/underline entirely (this book's own field list never
; mentions either), so only alignment (;F's c2 code) and number format
; (;F's c1 code, plus the separate ;K comma flag) round-trip through SYLK -
; matching the same "only what the real format actually has" principle
; DIF's fix above just established. The cell itself must already exist
; (from an earlier C record) for this to do anything, per SYLK's own
; documented convention that referenced things are defined before use -
; this app's own writer always emits a formatted cell's C record first for
; exactly that reason.
; -----------------------------------------------------------------------------
pl_parsefrec:
    push ax
    push bx
    push cx
    push si
    push di                           ; pl_findcell below is called for its
                                       ; side effect on DI, but pl_parseslk's
                                       ; caller keeps its own buffer-end in
                                       ; DI live across this whole call - it
                                       ; must come back unchanged
    mov word [PL_TCOL], 0
    mov word [PL_TROW], 0
    mov byte [PL_TALIGN], 0
    mov byte [PL_TNUMFMT], 0
    mov byte [PL_TCOMMA], 0
.tok:
    cmp si, bx
    jae .apply
    mov al, [es:si]
    cmp al, ';'
    je .skipsemi
    cmp al, 'X'
    je .isx
    cmp al, 'Y'
    je .isy
    cmp al, 'F'
    je .isf
    cmp al, 'K'
    je .isk
    cmp al, 'W'
    je .isw
.scan:
    cmp si, bx
    jae .apply
    mov al, [es:si]
    inc si
    cmp al, ';'
    jne .scan
    jmp .tok
.skipsemi:
    inc si
    jmp .tok
.isx:
    inc si
    SHOUT pl_pint
    mov [PL_TCOL], ax
    jmp .tok
.isy:
    inc si
    SHOUT pl_pint
    mov [PL_TROW], ax
    jmp .tok
.isk:
    inc si
    mov byte [PL_TCOMMA], 1
    jmp .tok
.isw:                                  ; ;W<first> <last> <width>: column
    inc si                             ; widths, Walden's F-record field (7)
    SHOUT pl_pint                      ; (81.56). 1-based, spaces between
    push ax
    inc si
    SHOUT pl_pint
    push ax
    inc si
    SHOUT pl_pint
    call pl_cwbyte                     ; CL = what the table keeps
    pop di                             ; DI = the last
    pop ax                             ; AX = the first
.wl:
    cmp ax, di
    ja .tok
    or ax, ax
    jz .wn
    cmp ax, 256
    ja .tok
    dec ax
    SHOUT pl_colw_set
    inc ax
.wn:
    inc ax
    jmp short .wl
.isf:                                  ; ;F<c1>[space]<digits>[space]<c2> -
                                        ; one field, not semicolon-delimited
                                        ; internally, so it's parsed as its
                                        ; own little grammar before control
                                        ; returns to the outer ;-scan loop
    inc si
    cmp si, bx
    jae .tok
    mov al, [es:si]
    call pl_sylk_numfmt_from_c1
    mov [PL_TNUMFMT], al
    inc si
    cmp si, bx
    jae .tok
    cmp byte [es:si], ' '
    jne .fdigits
    inc si
.fdigits:
    cmp si, bx
    jae .tok
    mov al, [es:si]
    cmp al, '0'
    jb .fspace2
    cmp al, '9'
    ja .fspace2
    inc si
    jmp .fdigits
.fspace2:
    cmp si, bx
    jae .tok
    cmp byte [es:si], ' '
    jne .fc2
    inc si
.fc2:
    cmp si, bx
    jae .tok
    mov al, [es:si]
    call pl_sylk_align_from_c2
    mov [PL_TALIGN], al
    inc si
    jmp .tok
.apply:
    mov ax, [PL_TCOL]
    cmp ax, 1
    jb .out
    cmp ax, PL_COLS
    ja .out
    mov cx, [PL_TROW]
    cmp cx, 1
    jb .out
    cmp cx, PL_ROWS
    ja .out
    dec ax
    dec cx
    mov bx, cx
    SHOUT pl_findcell
    jnc .out                          ; no prior C record for this cell:
                                       ; nothing to attach the format to
    mov al, [PL_TNUMFMT]
    cmp byte [PL_TCOMMA], 0
    je .noupgrade
    or al, al
    jnz .noupgrade                    ; ;K only promotes a still-General
                                       ; code to Comma - an explicit c1 of
                                       ; '$' (Currency) wins if both appear
    mov al, PL_FMT_NUM_COMMA
.noupgrade:
    mov cl, PL_FMT_NUM_SHIFT
    shl al, cl
    mov ah, [PL_TALIGN]
    mov cl, PL_FMT_ALIGN_SHIFT
    shl ah, cl
    or al, ah
    push es
    mov es, [pl_cellseg]
    mov [es:di+5], al
    pop es
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_sylk_numfmt_from_c1 - in: AL = an F record's c1 formatting-code char;
; out: AL = this app's PL_FMT_NUM_* code. Real SYLK's c1 codes are
; 0/C/E/F/G/$/* (default/continuous/scientific/fixed/general/currency/
; bargraph) - only '$' has an equivalent here; everything else (including
; the codes this app never writes, like scientific or bargraph) falls back
; to General, which is the honest answer since this app has no comparable
; format for them either.
; -----------------------------------------------------------------------------
pl_sylk_numfmt_from_c1:
    cmp al, '$'
    je .cur
    xor al, al
    ret
.cur:
    mov al, PL_FMT_NUM_CURRENCY
    ret

; -----------------------------------------------------------------------------
; pl_sylk_align_from_c2 - in: AL = an F record's c2 alignment-code char
; ('0' default, 'C' center, 'G' general, 'L' left, 'R' right); out: AL =
; this app's PL_FMT_ALIGN_* code
; -----------------------------------------------------------------------------
pl_sylk_align_from_c2:
    cmp al, 'L'
    je .left
    cmp al, 'C'
    je .center
    cmp al, 'R'
    je .right
    xor al, al
    ret
.left:
    mov al, PL_FMT_ALIGN_LEFT
    ret
.center:
    mov al, PL_FMT_ALIGN_CENTER
    ret
.right:
    mov al, PL_FMT_ALIGN_RIGHT
    ret

; -----------------------------------------------------------------------------
; pl_pint - parse a signed decimal integer
; in: ES:SI=ptr, BX=limit (exclusive, an offset); also stops at NUL
; out: AX=value, SI=advanced; BX preserved; ES must be set by the caller
; -----------------------------------------------------------------------------
section .text
pl_pint:
    push bx
    push cx
    push dx
    xor cx, cx
    xor ax, ax
    cmp si, bx
    jae .fin
    cmp byte [es:si], '-'
    jne .digits
    mov cx, 1
    inc si
.digits:
    cmp si, bx
    jae .fin
    mov dl, [es:si]
    or dl, dl
    jz .fin
    cmp dl, '0'
    jb .fin
    cmp dl, '9'
    ja .fin
    sub dl, '0'
    xor dh, dh
    push dx
    push bx
    mov bx, 10
    mul bx
    pop bx
    pop dx
    add ax, dx
    inc si
    jmp .digits
.fin:
    or cx, cx
    jz .nosign
    neg ax
.nosign:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_setferr - build "Err N" from a FERR_* code and point pl_msg at it
; in: AX = FERR_* (CF was set on the API call that produced it)
; -----------------------------------------------------------------------------
section PL_MODSEC                      ; 82.16.9
pl_setferr:
    push di
    push si
    mov di, pl_errbuf
    mov si, pl_s_errpfx
    SHOUT pl_strcpy_to_di              ; DI advances past "Err " to the new NUL
    SHOUT pl_itoa                      ; AX (the FERR_* code) -> pl_numbuf;
                                       ; preserves DI
    mov si, pl_numbuf
    SHOUT pl_strcpy_to_di
    mov word [pl_msg], pl_errbuf
    pop si
    pop di
    ret

; =============================================================================
; Cell storage - a sorted array of (row, col, flags, format, value,
; formula_off, pass) records in the claimed pl_cellseg, searched with a
; binary search and kept sorted by shifting on insert/remove. 12 bytes/rec:
;   +0 row (word) - stage 2.0: PACKED, not a plain row. Bits 0-13 are the
;   real row (0..16383, PL_ROW_MASK); bits 14-15 are the sheet index
;   (0..PL_SHEETS-1). Sorting and searching a plain 16-bit compare on this
;   word therefore sorts every sheet's records into one contiguous run,
;   ordered first by sheet and then by row within it, with NO change to the
;   comparison logic itself - only the few places that construct or take
;   apart the word (pl_findcell packing it from [pl_cursheet], pl_unpackrow
;   splitting it back out for the SYLK/DIF/BIFF writers, which must skip
;   every sheet but the one being saved) know this isn't just a row.
;   +2 col (word)  +4 flags (byte)  +5 format (byte, the
;   PL_FMT_* bits, stage 1.6 - this byte was unused padding before)
;   +6 value (word)  +8 formula_off (word, 0xFFFF=none)  +10 pass (word)
; Only three routines (pl_findcell/pl_addcell/pl_removecell) know this
; layout and the shifting; everything else goes through pl_getcell2/
; pl_setvald/pl_clearcell.
; =============================================================================

; -----------------------------------------------------------------------------
; pl_unpackrow - in: AX = a cell record's packed row/sheet word; out: AX =
; the real row (0..16383), BX = the sheet index it belongs to
; -----------------------------------------------------------------------------
section .text
pl_unpackrow:
    push cx
    mov bx, ax
    mov cl, PL_ROW_BITS
    shr bx, cl
    and ax, PL_ROW_MASK
    pop cx
    ret

; -----------------------------------------------------------------------------
; pl_findcell - binary search for (col, row)
; in: AX=col, BX=row
; out: CF=1 found, DI=byte offset of the record
;      CF=0 not found, DI=byte offset where it would be inserted
; -----------------------------------------------------------------------------
pl_findcell:
    push ax
    push bx
    push cx
    push dx
    push si
    mov [pl_fcol], ax
    mov ax, [pl_cursheet]              ; the stored "row" word is really a
    mov cl, PL_ROW_BITS                ; packed (sheet<<PL_ROW_BITS | row) -
    shl ax, cl                         ; see the stage 2.0 comment above the
    or ax, bx                          ; cell record layout - so every
    mov [pl_frow], ax                  ; existing caller of this proc (all
                                        ; of them pass a plain 0..16383 row)
                                        ; keeps working unchanged, searching
                                        ; only the CURRENT sheet's records
    xor cx, cx                        ; CX = lo
    mov dx, [pl_ncells]                ; DX = hi
.loop:
    cmp cx, dx
    jae .notfound
    mov si, dx
    sub si, cx
    shr si, 1
    add si, cx                        ; SI = mid
    mov ax, si
    mov bx, PL_C_SZ
    push dx                           ; MUL clobbers DX (the high word of
    mul bx                            ; the product) - DX is also this
    pop dx                            ; loop's search bound, so it must
    mov di, ax                        ; survive every iteration, not just
                                       ; the one that happens to find a match
                                       ; on its first probe
    push es
    mov es, [pl_cellseg]
    mov ax, [es:di]                   ; candidate row
    mov bx, [es:di+2]                 ; candidate col
    pop es
    cmp ax, [pl_frow]
    jl .lower
    jg .higher
    cmp bx, [pl_fcol]
    jl .lower
    jg .higher
    stc
    jmp .out
.lower:
    mov cx, si
    inc cx
    jmp .loop
.higher:
    mov dx, si
    jmp .loop
.notfound:
    mov ax, cx
    mov bx, PL_C_SZ
    mul bx
    mov di, ax
    clc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_addcell - find or create the record for (col, row)
; in: AX=col, BX=row
; out: CF=0, DI=byte offset of the record (existing or new, zeroed if new)
;      CF=1 the table is full - no new record could be created
; -----------------------------------------------------------------------------
pl_addcell:
    push ax
    push bx
    push cx
    push dx
    push si
    mov byte [pl_chartdirty], 1        ; whoever asked is about to write this
                                        ; record - pl_repaint's chart tail
                                        ; reads the byte instead of rescanning
                                        ; the column on every repaint
    call pl_findcell
    jc .found
    cmp word [pl_ncells], PL_CELL_CAP
    jae .full
    push di                            ; insertion offset, kept across the
                                        ; shift below
    mov ax, [pl_ncells]
    mov bx, PL_C_SZ
    mul bx                             ; AX = current end-of-array offset
    mov cx, ax
    sub cx, di                         ; CX = bytes to shift up (may be 0)
    push ds
    push es
    mov dx, [pl_cellseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, ax
    dec si
    mov di, si
    add di, PL_C_SZ
    std
    rep movsb
    cld
.noshift:
    pop es
    pop ds
    pop di                             ; DI = insertion offset, restored
    inc word [pl_ncells]
    push es
    mov es, [pl_cellseg]
    mov ax, [pl_frow]
    mov [es:di], ax
    mov ax, [pl_fcol]
    mov [es:di+2], ax
    mov byte [es:di+4], 0
    mov byte [es:di+5], 0
    mov byte [es:di+PL_C_TYPE], PL_T_NUM
    mov byte [es:di+PL_C_AUX], 0
    mov word [es:di+PL_C_VAL], 0      ; ALL EIGHT value bytes, not just the low
    mov word [es:di+PL_C_VAL+2], 0    ; word the integer model uses today. The
                                      ; record above it left here - harmless
                                      ; while only the low word is read, and a
                                      ; genuinely nasty surprise the moment the
                                      ; full double goes live
    mov word [es:di+PL_C_FOFF], 0xFFFF
    mov word [es:di+PL_C_PASS], 0
    pop es
    clc
    jmp .out
.found:
    clc
    jmp .out
.full:
    stc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_removecell - in: AX=col, BX=row; removes the record if present
; -----------------------------------------------------------------------------
pl_removecell:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov byte [pl_chartdirty], 1        ; pl_addcell's reason
    call pl_findcell
    jnc .out
    mov ax, [pl_ncells]
    mov bx, PL_C_SZ
    mul bx                             ; AX = end offset (before shrink)
    mov cx, ax
    sub cx, di
    sub cx, PL_C_SZ                    ; CX = bytes after this record
    push ds
    push es
    mov dx, [pl_cellseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, di
    add si, PL_C_SZ
    cld
    rep movsb
.noshift:
    pop es
    pop ds
    dec word [pl_ncells]
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; 81.75: THE TWO SIDE TABLES ARE GONE, and with them two of the eight claims.
;
; 81.55's border table kept a sparse record per bordered cell - the border
; bits, the protection bits, and the number format beyond the four the format
; byte can name - in a 4KB claim. 81.71.5.1's note table kept another, in 5KB.
; Both are features a budget does not have, and between them they were 9,216
; bytes of a 53,760-byte arena: a ninth of the machine, for borders nobody
; draws and notes nobody writes.
;
; WHAT WENT WITH THEM, because it was only reachable through them: Format >
; Border... and its check-box dialog engine (the only pl_bdlg_* caller),
; Format > Cell Protection..., Options > Protect Document, and every number
; format past the four the format byte itself can name.
; =============================================================================

; -----------------------------------------------------------------------------
; pl_rowcol_op - Insert or delete a whole row or column on the CURRENT
; sheet only. in: AL = 0 insert row / 1 delete row / 2 insert column /
; 3 delete column; BX = the row or column index the operation pivots on
; (the selected cell's own row/col - Edit menu Insert.../Delete... has no
; other way to name one: a pivot is a single index, and a selection that
; spans several rows does not name one).
;
; The cell array is sorted by (sheet, row) then col (see the stage 2.0
; comment above pl_findcell) - shifting a COLUMN can reorder cells WITHIN
; a row relative to their row-mates, which the sorted array's own binary
; search depends on getting right. Rather than hand-roll an in-place
; resort, this stages every record's (sheet, row, col, flags, format,
; value, formula_off) into pl_stgseg with the shift already applied (or
; marked dropped, if inserting pushes a row/col past the edge of the
; grid, or if it sits exactly on a deleted row/col), empties the whole
; array, then re-inserts every staged record through pl_addcell (which
; already keeps the array sorted on every insert, so re-insertion order
; doesn't matter). Formula TEXT is untouched - only the cell record's own
; formula_off is carried over as-is, so an existing formula's cell
; references are NOT relatively adjusted by this operation (same scope
; reasoning as pl_docmd_fillright/pl_docmd_sortcol); its cached value is
; simply left to go stale, since pl_addcell's own default pass=0 on the
; fresh record forces a re-evaluation on the next paint regardless.
; -----------------------------------------------------------------------------

; =============================================================================
; pl_rowcol_reidx and its helpers - stage 2.x: after pl_rowcol_op has
; shifted every cell record's own position, this second pass fixes up the
; TEXT of every formula whose cell references point at or past the pivot,
; so a formula still means what it looked like it meant before the
; insert/delete. Previously (and still true of Fill Right/Down and Sort
; Column, a deliberate scope cut documented at their own call sites)
; formula TEXT was left completely untouched by a row/col shift - only
; the referenced CELLS moved, silently breaking any formula that pointed
; at or past the pivot (a formula "=A1" one row below an inserted row
; kept saying A1 even though the data it meant is now at A2). This pass
; closes that gap for Insert/Delete Row/Column specifically, per direct
; user report.
;
; Method: walk the cell array once (this is now in its POST-shift,
; correct positions), and for every formula cell, copy its text out,
; run it through pl_formula_reidx (a character scanner - not a full
; parse/reserialize - that recognizes exactly the same token shapes the
; real formula grammar does: an optional "SheetN!" prefix, then 1-7
; letters immediately followed by digits is a cell reference; anything
; inside a double-quoted string, per ALERT's own argument, is copied
; byte-for-byte and never scanned), and if the text actually changed,
; appends the new text to the pool (formula text is append-only - see
; pl_setformula's own header comment - so an edit here is "append new,
; abandon old" exactly like every other formula edit already is) and
; repoints the cell record's formula_off at it.
;
; A reference is only ever touched if it is KNOWN to name the sheet this
; whole operation is acting on: either a bare, unprefixed reference
; inside a formula that itself lives on that sheet (the overwhelmingly
; common case - editing your own sheet's own formulas), or an explicit
; "SheetN!" reference naming that sheet from ANYWHERE else. A bare
; reference inside a formula that lives on a DIFFERENT sheet is left
; alone - it means that OTHER sheet's own same cell, never the one being
; shifted.
;
; A reference at exactly the pivot on a DELETE is clamped to stay at the
; pivot (the row/col that used to be one further along now occupies that
; slot) rather than invented as some error value - this project has no
; error-value concept anywhere else either (RK's unsupported subtype and
; a division by zero both degrade the same "closest sane fallback, never
; crash" way).
; =============================================================================

; pl_isletter_at - in: SI; out: CF=1 if [SI] is A-Z or a-z (SI untouched)
pl_isletter_at:
    push ax
    mov al, [si]
    cmp al, '$'                       ; stage 3.0e: '$A$1' starts a reference
    je .yes                           ; just as 'A1' does - the rewriters'
    cmp al, 'A'                       ; scanners enter on this test, so an
    jb .no                            ; absolute ref is invisible to them
                                      ; without it
    cmp al, 'Z'
    jbe .yes
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    ja .no
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop ax
    ret

; pl_rw_emit - in: AL = one byte; appends it to pl_rwdst at [pl_rw_di],
; clipping (silently dropping the byte) rather than overrunning the
; buffer - same "clip, don't refuse" policy ALERT's own message copy uses.
;
; The clip is at PL_EDITMAX, NOT at pl_rwdst's own PL_RW_CAP size: every
; consumer of a rewritten formula assumes formula text fits the same
; PL_EDITMAX+1 = 64 bytes a typed formula does - pl_eval_cell's own
; per-recursion-level pl_fbuf slot, pl_beginedit's pl_editbuf,
; pl_docmd_copy's pl_clipbuf, and pl_drawbar's pl_tbuf+16 span are all
; exactly that size. A shift CAN legitimately grow text (row 9 -> 10,
; column Z -> AA), so the extra PL_RW_CAP slack is real working room; but
; letting the RESULT exceed PL_EDITMAX would overrun all four of those
; downstream buffers (pl_setformula/pl_txt_append only bound against the
; whole pool, not against 64), so growth past the cap is dropped here at
; the single choke point every rewriter shares rather than re-checked at
; each of the five call sites.
pl_rw_emit:
    push bx
    push di
    mov bx, [pl_rw_di]
    cmp bx, PL_EDITMAX
    jae .full
    mov di, pl_rwdst
    add di, bx
    mov [di], al
    inc bx
    mov [pl_rw_di], bx
.full:
    pop di
    pop bx
    ret

; pl_txt_append - in: DS:SI = NUL-terminated text (no leading '=');
; out: CF=0 and AX = its new offset in the text pool, or CF=1 if there is
; no room (the pool is left unchanged either way)
pl_txt_append:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov bx, si
    xor cx, cx
.len:
    cmp byte [bx], 0
    je .havelen
    inc bx
    inc cx
    jmp .len
.havelen:
    mov ax, [pl_txtlen]
    add ax, cx
    inc ax
    cmp ax, PL_TXT_CAP
    ja .noroom
    mov es, [pl_txtseg]
    mov di, [pl_txtlen]
    mov ax, di
    push ax
.copy:
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    or al, al
    jnz .copy
    mov [pl_txtlen], di
    pop ax
    clc
    jmp .out
.noroom:
    stc
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; pl_reidx_shift - in: AX = a reference's original 0-based row or col,
; BX = the pivot, [pl_rw_op] = pl_rowcol_op's own AL (0 ins-row/1 del-row/
; 2 ins-col/3 del-col); out: AX = the adjusted index
pl_reidx_shift:
    push cx
    push dx
    mov dl, [pl_rw_op]
    test dl, 1
    jnz .delete
    cmp ax, bx
    jb .out
    inc ax
    mov cx, PL_ROWS                    ; an insert that pushes a reference
    cmp dl, 2                          ; PAST the last row or column has moved
    jb .havecap                        ; the cell it names off the sheet, so
    mov cx, PL_COLS                    ; the reference is dead. It used to
.havecap:                              ; clamp to the last real index, which
    cmp ax, cx                         ; silently named different data
    jb .out
    jmp .dead
.delete:
    cmp ax, bx
    jb .out                            ; before the pivot: untouched
    je .dead                           ; ON THE PIVOT: THE CELL IS GONE. This
    dec ax                             ; used to leave the index alone, so the
.out:                                  ; reference quietly started naming
    clc                                ; whatever slid into the vacated slot -
    jmp .ret                           ; a wrong number with nothing to show
.dead:                                 ; for it. #REF! is Excel's answer and
    stc                                ; the whole point of it is that it
.ret:                                  ; cannot be mistaken for a live one
    pop dx
    pop cx
    ret

; pl_reidx_apply - in: [pl_rw_refcol]/[pl_rw_refrow] = the reference as
; parsed, [pl_rw_ostart]/[pl_rw_lettersend]/[pl_rw_refend] = its own text
; spans, [pl_rw_op]/[pl_rw_pivot] = the shift; emits the adjusted
; reference (only the axis [pl_rw_op] actually operates on is
; recomputed - the other axis's ORIGINAL text is copied verbatim, so a
; row-only shift never touches a column's own case/spelling)
pl_reidx_apply:
    push ax
    push bx
    mov al, [pl_rw_op]
    cmp al, 2
    jae .colop
    mov ax, [pl_rw_refrow]             ; INSERT/DELETE SHIFTS AN ABSOLUTE
    mov bx, [pl_rw_pivot]              ; REFERENCE TOO, and that is not an
    call pl_reidx_shift                ; oversight. '$' means "do not adjust
    jc .dead
    mov [pl_rw_refrow], ax             ; when this formula is COPIED"; it does
.rowletcopy:                           ; not mean "keep pointing at row 1 no
                                       ; matter what". Inserting a row above
                                       ; physically moves the referenced cell
                                       ; down, so every reference to it must
                                       ; follow or it silently starts naming
                                       ; different data - '$A$1' becomes
                                       ; '$A$2', exactly as Excel does. The
                                       ; markers are preserved below; only the
                                       ; index moves.
    mov bx, [pl_rw_ostart]             ; ostart is before any '$', so this
.rowletloop:                           ; copy carries the column's marker
    cmp bx, [pl_rw_lettersend]
    jae .rowdigits
    mov al, [bx]
    call pl_rw_emit
    inc bx
    jmp .rowletloop
.rowdigits:
    cmp byte [pl_rw_absr], 0           ; put the row's own '$' back
    je .rownodollar
    mov al, '$'
    call pl_rw_emit
.rownodollar:
    mov ax, [pl_rw_refrow]
    inc ax                             ; back to 1-based display text
    call pl_itoa
    mov bx, pl_numbuf
.rowdigemit:
    mov al, [bx]
    or al, al
    jz .out
    call pl_rw_emit
    inc bx
    jmp .rowdigemit
.colop:
    mov ax, [pl_rw_refcol]             ; same rule for a column insert/delete
    mov bx, [pl_rw_pivot]              ; as for a row - see .rowletcopy above
    call pl_reidx_shift
    jc .dead
    mov [pl_rw_refcol], ax
.colemitstart:
    cmp byte [pl_rw_absc], 0           ; the letters are REGENERATED here, so
    je .colnodollar                    ; the marker has to be re-emitted
    mov al, '$'
    call pl_rw_emit
.colnodollar:
    mov ax, [pl_rw_refcol]
    call pl_colname
    mov bx, pl_colbuf
.colemit:
    mov al, [bx]
    or al, al
    jz .coldigits
    call pl_rw_emit
    inc bx
    jmp .colemit
.coldigits:
    mov bx, [pl_rw_lettersend]
.coldigcopy:
    cmp bx, [pl_rw_refend]
    jae .out
    mov al, [bx]
    call pl_rw_emit
    inc bx
    jmp .coldigcopy
.dead:
    call pl_rw_emitref                 ; the cell this named no longer exists
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_rw_emitref - put the literal "#REF!" in a rewritten formula, in place of
; a reference whose cell is gone. It reads the SAME string pl_errname prints,
; so the text a Delete writes is exactly the text pl_perrlit reads back.
; -----------------------------------------------------------------------------
pl_rw_emitref:
    push ax
    push bx
    mov bx, pl_s_err_ref
.l:
    mov al, [bx]
    or al, al
    jz .out
    call pl_rw_emit
    inc bx
    jmp .l
.out:
    pop bx
    pop ax
    ret

; pl_reidx_cellpart - in: SI at a cell reference's first letter (the
; caller has already confirmed one is there via pl_isletter_at), DL = 1
; adjust this reference (it is known to name the sheet being shifted) or
; 0 leave it exactly as written; out: SI advanced past the whole
; reference (letters and, if any followed, digits) and the reference (or
; the bare word, if a letter run here turns out NOT to be followed by a
; digit - a function name, not a cell reference) emitted to pl_rwdst
; either verbatim or adjusted
pl_reidx_cellpart:
    push ax
    push bx
    push cx
    push dx
    push di
    mov [pl_rw_adj], dl
    mov [pl_rw_ostart], si
    mov byte [pl_rw_absc], 0           ; stage 3.0e: '$' before the letters
    mov byte [pl_rw_absr], 0           ; pins the COLUMN, '$' before the
    cmp byte [si], '$'                 ; digits pins the ROW
    jne .nocoldollar
    mov byte [pl_rw_absc], 1
    inc si
.nocoldollar:
    mov di, pl_ident
    xor cx, cx
.letters:
    mov al, [si]
    cmp al, 'A'
    jb .doneletters
    cmp al, 'Z'
    jbe .isletter
    cmp al, 'a'
    jb .doneletters
    cmp al, 'z'
    ja .doneletters
.isletter:
    cmp cx, 7
    jae .doneletters
    mov ah, al
    and ah, 0xDF
    mov [di], ah
    inc di
    inc cx
    inc si
    jmp .letters
.doneletters:
    mov byte [di], 0
    mov [pl_rw_lettersend], si
    cmp byte [si], '$'
    jne .norowdollar
    mov byte [pl_rw_absr], 1
    inc si
.norowdollar:
    mov al, [si]
    cmp al, '0'
    jb .notref
    cmp al, '9'
    ja .notref
    call pl_identcol                   ; ax = 0-based col (from pl_ident)
    mov [pl_rw_refcol], ax
    mov bx, si
    add bx, PL_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call pl_pint                       ; ax = 1-based row text; si advances
    pop es
    dec ax                             ; ax = 0-based row
    mov [pl_rw_refrow], ax
    mov [pl_rw_refend], si
    cmp byte [pl_rw_adj], 0
    je .verbatim
    call pl_reidx_apply
    jmp .out
.verbatim:
    mov bx, [pl_rw_ostart]
.vcopy:
    cmp bx, si
    jae .out
    mov al, [bx]
    call pl_rw_emit
    inc bx
    jmp .vcopy
.notref:
    mov bx, [pl_rw_ostart]
.wcopy:
    cmp bx, si
    jae .out
    mov al, [bx]
    call pl_rw_emit
    inc bx
    jmp .wcopy
.out:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; A1 <-> R1C1, for SYLK's ;E field (stage 4.x)
;
; SYLK CARRIES FORMULAS IN R1C1 RELATIVE FORM, not in the A1 form this app
; stores and shows. That is not a preference - it is what the format is, and a
; real file from the period reads
;
;     C;X3;E+R[-6]C[-1]-RC[-1];K100.73
;
; where R[-6]C[-1] is "six rows up, one column left" of the cell being defined.
; An ABSOLUTE reference has no brackets: R6C3 means row 6, column 3 outright,
; which is exactly what '$' means in A1 form - so the two notations carry the
; same distinction and it survives the trip.
;
; Both directions reuse pl_formula_reidx's scanner shape: walk the text, copy
; everything that is not a reference verbatim, and transform the references.
; A quoted string is passed through untouched, as it is there.
;
; THE CROSS-SHEET PREFIX IS AN EXTENSION. SYLK has no notion of a second sheet
; - it is a single-grid format - so "Sheet2!" is written through verbatim. It
; round-trips within this app and means nothing to anything else, which is the
; honest position: the alternative is silently dropping the reference.
; =============================================================================

; pl_emit_num - AX as signed decimal, into pl_rwdst via pl_rw_emit
section PL_MODSEC                      ; 82.16.9
pl_emit_num:
    push ax
    push bx
    SHOUT pl_itoa
    mov bx, pl_numbuf
.e:
    mov al, [bx]
    or al, al
    jz .o
    SHOUT pl_rw_emit
    inc bx
    jmp .e
.o:
    pop bx
    pop ax
    ret

; pl_emit_rc - one R or C part. in: AL = 'R' or 'C', BX = the value,
; CL = 0 relative (bracketed offset, omitted entirely when zero) or 1 absolute
; (a bare 1-based index).
pl_emit_rc:
    push ax
    push bx
    SHOUT pl_rw_emit                   ; the letter itself
    or cl, cl
    jnz .abs
    or bx, bx
    jz .out                           ; a zero offset is written as nothing:
    mov al, '['                       ; "RC" means "this row, this column"
    SHOUT pl_rw_emit
    mov ax, bx
    call pl_emit_num
    mov al, ']'
    SHOUT pl_rw_emit
    jmp .out
.abs:
    mov ax, bx
    inc ax                            ; absolute parts are 1-based
    call pl_emit_num
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_formula_to_r1c1 - in: SI = A1-form formula text (no leading '='),
; [pl_rc_ccol]/[pl_rc_crow] = the cell that owns it.
; out: pl_rwdst holds the R1C1 form, [pl_rw_di] its length.
; -----------------------------------------------------------------------------
pl_formula_to_r1c1:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [pl_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    SHOUT pl_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    SHOUT pl_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    SHOUT pl_isletter_at
    jnc .literal
    mov [pl_rw_ostart], si
    SHOUT pl_psheetpfx
    jnc .noxsheet
    mov si, [pl_rw_ostart]            ; the prefix goes through verbatim
    mov bx, 7
.pfx:
    mov al, [si]
    SHOUT pl_rw_emit
    inc si
    dec bx
    jnz .pfx
    mov [pl_rw_ostart], si
.noxsheet:
    call pl_reidx_cellpart_probe      ; is this really a reference?
    jc .isref
    mov si, [pl_rw_ostart]            ; no: a function name or a bare word
.word:
    SHOUT pl_isletter_at
    jnc .loop
    mov al, [si]
    SHOUT pl_rw_emit
    inc si
    jmp .word
.isref:
    mov al, 'R'                       ; ...the row part
    mov bx, [pl_rw_refrow]
    mov cl, [pl_rw_absr]
    or cl, cl
    jnz .rowabs
    sub bx, [pl_rc_crow]              ; relative: an offset from this cell
.rowabs:
    call pl_emit_rc
    mov al, 'C'                       ; ...and the column part
    mov bx, [pl_rw_refcol]
    mov cl, [pl_rw_absc]
    or cl, cl
    jnz .colabs
    sub bx, [pl_rc_ccol]
.colabs:
    call pl_emit_rc
    jmp .loop
.literal:
    mov al, [si]
    SHOUT pl_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [pl_rw_di]
    mov byte [pl_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; pl_reidx_cellpart_probe - SI at a possible reference. Fills pl_rw_refcol/
; refrow/absc/absr and returns CF=1 with SI past it. CF=0 means the letters
; were NOT followed by a row number (a function name, say) - SI is left where
; the scan stopped, and the caller rewinds it from pl_rw_ostart, which is the
; same contract pl_reidx_cellpart works to.
pl_reidx_cellpart_probe:
    push ax
    push cx
    push di
    mov di, pl_ident
    xor cx, cx
    mov byte [pl_rw_absc], 0
    mov byte [pl_rw_absr], 0
    cmp byte [si], '$'
    jne .nc
    mov byte [pl_rw_absc], 1
    inc si
.nc:
.letters:
    mov al, [si]
    cmp al, 'A'
    jb .doneletters
    cmp al, 'Z'
    jbe .isl
    cmp al, 'a'
    jb .doneletters
    cmp al, 'z'
    ja .doneletters
.isl:
    cmp cx, 2
    jae .doneletters
    and al, 0xDF
    mov [di], al
    inc di
    inc cx
    inc si
    jmp .letters
.doneletters:
    mov byte [di], 0
    or cx, cx
    jz .no
    cmp byte [si], '$'
    jne .nr
    mov byte [pl_rw_absr], 1
    inc si
.nr:
    mov al, [si]
    cmp al, '0'
    jb .no
    cmp al, '9'
    ja .no
    SHOUT pl_identcol
    mov [pl_rw_refcol], ax
    push bx
    mov bx, si
    add bx, PL_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    SHOUT pl_pint
    pop es
    pop bx
    dec ax
    mov [pl_rw_refrow], ax
    pop di
    pop cx
    pop ax
    stc
    ret
.no:
    pop di
    pop cx
    pop ax
    clc
    ret

; -----------------------------------------------------------------------------
; pl_formula_from_r1c1 - in: SI = R1C1-form text, [pl_rc_ccol]/[pl_rc_crow] =
; the cell that owns it. out: pl_rwdst holds the A1 form, NUL-terminated.
;
; The inverse of the above. A reference starts at an 'R' that is followed by
; '[', a digit, '-' or 'C' - which is what tells "R[-1]C" apart from a function
; name beginning with R, and the reason this looks one character further ahead
; than the A1 scanner needs to.
;
; AND IT IS A WHOLE WORD (81.62): the 'R' must not follow a letter, digit, '.'
; or '_', and what the reference ends at must not be one either, or '('. The
; RC inside SEARCH was read as "this cell" and the function came in as
; SEAC16H - #NAME? on every SYLK load, SHEET's own files included, and a
; defined name like SOURCE the same way.
; -----------------------------------------------------------------------------
pl_formula_from_r1c1:
    push ax
    push bx
    push cx
    push dx
    push si
    mov dx, si                        ; DX = the text's start, for the check
    mov word [pl_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    SHOUT pl_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    SHOUT pl_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    mov al, [si]
    and al, 0xDF
    cmp al, 'R'
    jne .literal
    cmp si, dx                        ; ...at the start of a WORD
    je .rstart
    mov al, [si-1]
    call pl_rcident
    jc .literal
.rstart:
    mov [pl_rw_ostart], si
    inc si
    call pl_read_rc                   ; -> BX = value, CL = 1 if absolute
    jc .notref
    mov [pl_rw_refrow], bx
    mov [pl_rw_absr], cl
    mov al, [si]
    and al, 0xDF
    cmp al, 'C'
    jne .notref
    inc si
    call pl_read_rc
    jc .notref
    mov al, [si]                      ; ...and ending one: RCOST is a name,
    cmp al, '('                       ; RC( a function
    je .notref
    call pl_rcident
    jc .notref
    mov [pl_rw_refcol], bx
    mov [pl_rw_absc], cl
    ; --- emit it as A1 ---
    cmp byte [pl_rw_absc], 0
    je .colrel
    mov al, '$'
    SHOUT pl_rw_emit
    jmp .colemit
.colrel:
    mov ax, [pl_rw_refcol]
    add ax, [pl_rc_ccol]
    mov [pl_rw_refcol], ax
.colemit:
    mov ax, [pl_rw_refcol]
    SHOUT pl_colname
    mov bx, pl_colbuf
.cl:
    mov al, [bx]
    or al, al
    jz .rowpart
    SHOUT pl_rw_emit
    inc bx
    jmp .cl
.rowpart:
    cmp byte [pl_rw_absr], 0
    je .rowrel
    mov al, '$'
    SHOUT pl_rw_emit
    jmp .rowemit
.rowrel:
    mov ax, [pl_rw_refrow]
    add ax, [pl_rc_crow]
    mov [pl_rw_refrow], ax
.rowemit:
    mov ax, [pl_rw_refrow]
    inc ax                            ; back to the 1-based display row
    call pl_emit_num
    jmp .loop
.notref:
    mov si, [pl_rw_ostart]            ; not a reference after all: the 'R' and
    mov al, [si]                      ; whatever follows go through as text
    SHOUT pl_rw_emit
    inc si
    jmp .loop
.literal:
    mov al, [si]
    SHOUT pl_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [pl_rw_di]
    mov byte [pl_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; pl_rcident - CF=1 when AL can be part of a word: a letter, a digit, '.' or
; '_' (81.62)
pl_rcident:
    push ax
    cmp al, '.'
    je .yes
    cmp al, '_'
    je .yes
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .yes
    and al, 0xDF
    cmp al, 'A'
    jb .no
    cmp al, 'Z'
    jbe .yes
.no:
    pop ax
    clc
    ret
.yes:
    pop ax
    stc
    ret

; pl_read_rc - SI just past an 'R' or 'C'. out: BX = the value (a signed offset
; when relative, a 0-based index when absolute), CL = 1 if absolute, SI
; advanced. CF=1 if what follows is neither a bracket nor a digit.
pl_read_rc:
    push ax
    push dx
    xor bx, bx
    xor cl, cl
    cmp byte [si], '['
    je .rel
    mov al, [si]                      ; a bare digit means absolute
    cmp al, '0'
    jb .zero                          ; neither: "RC" - a zero offset
    cmp al, '9'
    ja .zero
    mov cl, 1
    call pl_read_int
    dec bx                            ; absolute parts are 1-based on the wire
    jmp .ok
.rel:
    inc si
    call pl_read_int                  ; the bracketed offset, sign and all
    cmp byte [si], ']'
    jne .bad
    inc si
    jmp .ok
.zero:
    cmp byte [si], 'C'                ; "RC..." - this part is simply zero
    je .ok
    cmp byte [si], 'c'
    je .ok
    or bx, bx                         ; end of the reference is fine too
    jmp .ok
.ok:
    pop dx
    pop ax
    clc
    ret
.bad:
    pop dx
    pop ax
    stc
    ret

; pl_read_int - a signed decimal at SI into BX; SI advanced. Used only by the
; R1C1 reader, where the number is known to be short.
pl_read_int:
    push ax
    push cx
    push dx
    xor bx, bx
    xor cx, cx                        ; cx = 1 when negative
    cmp byte [si], '-'
    jne .d
    mov cx, 1
    inc si
.d:
    mov al, [si]
    cmp al, '0'
    jb .fin
    cmp al, '9'
    ja .fin
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, bx
    mov dx, 10
    imul dx
    mov bx, ax
    pop ax
    add bx, ax
    inc si
    jmp .d
.fin:
    or cx, cx
    jz .o
    neg bx
.o:
    pop dx
    pop cx
    pop ax
    ret

; pl_formula_reidx - in: SI = source formula text (DS-resident, NUL-
; terminated, no leading '='); [pl_rw_op]/[pl_rw_pivot]/[pl_rw_tsheet]/
; [pl_rw_home] already set by the caller (pl_rowcol_reidx). Out:
; pl_rwdst holds the rewritten, NUL-terminated text, [pl_rw_di] = its
; length. See the section header comment above for the token rules.
section .text
pl_formula_reidx:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [pl_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    call pl_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    call pl_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    call pl_isletter_at
    jnc .literal
    mov [pl_rw_ostart], si
    call pl_psheetpfx
    jnc .noxsheet
    mov cx, ax                         ; cx = the sheet the prefix names
    call pl_isletter_at
    jc .pfxisref
    mov si, [pl_rw_ostart]             ; "SheetN!" not actually followed by
    mov bx, 7                          ; a reference: emit the 7 prefix
.pfxverb:                              ; bytes VERBATIM and carry on.
    mov al, [si]                       ; pl_psheetpfx has already advanced
    call pl_rw_emit                    ; SI past them, so just jumping back
    inc si                             ; to .loop (as this did before) threw
    dec bx                             ; them away - silently deleting the
    jnz .pfxverb                       ; "SHEET2!" from the rewritten text
    jmp .loop
.pfxisref:
    mov si, [pl_rw_ostart]
    mov bx, 7                          ; "SHEET" + one digit + "!" always
.copypfx:
    mov al, [si]
    call pl_rw_emit
    inc si
    dec bx
    jnz .copypfx
    cmp cx, [pl_rw_tsheet]
    jne .pfxnoadj
    mov dl, 1
    jmp .pfxgo
.pfxnoadj:
    mov dl, 0
.pfxgo:
    call pl_reidx_cellpart
    jmp .loop
.noxsheet:
    mov dl, [pl_rw_home]
    call pl_reidx_cellpart
    jmp .loop
.literal:
    mov al, [si]
    call pl_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [pl_rw_di]
    mov byte [pl_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; pl_rowcol_reidx - the driver: walk every cell, and for each formula
; cell, run its text through pl_formula_reidx and repoint its
; formula_off if the text actually changed. [pl_rc_op]/[pl_rc_idx] are
; still exactly what pl_rowcol_op's caller passed (untouched since
; entry); [pl_cursheet] has just been restored to the sheet this whole
; operation acted on.
pl_rowcol_reidx:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov ax, [pl_cursheet]
    mov [pl_rw_tsheet], ax
    mov al, [pl_rc_op]
    mov [pl_rw_op], al
    mov ax, [pl_rc_idx]
    mov [pl_rw_pivot], ax
    xor cx, cx
.scan:
    cmp cx, [pl_ncells]
    jae .done
    mov ax, cx
    mov bx, PL_C_SZ
    mul bx
    mov [pl_rw_recdi], ax
    mov si, ax
    mov es, [pl_cellseg]
    test byte [es:si+4], 1             ; HASFORMULA
    jz .next
    mov ax, [es:si]
    call pl_unpackrow                  ; bx = this record's own sheet
    mov byte [pl_rw_home], 0
    cmp bx, [pl_rw_tsheet]
    jne .gothome
    mov byte [pl_rw_home], 1
.gothome:
    mov si, [pl_rw_recdi]
    mov ax, [es:si+PL_C_FOFF]          ; formula_off
    mov si, ax
    mov es, [pl_txtseg]
    mov di, pl_rwsrc
.copyin:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov si, pl_rwsrc
    call pl_formula_reidx
    mov si, pl_rwsrc
    mov di, pl_rwdst
    call pl_streq                      ; CF=1 if identical
    jc .next                           ; unchanged: nothing to do
    mov si, pl_rwdst
    call pl_txt_append
    jc .next                           ; no room left: leave the stale
                                        ; (still valid, just unshifted)
                                        ; text in place rather than losing
                                        ; the formula entirely
    mov es, [pl_cellseg]
    mov di, [pl_rw_recdi]
    mov [es:di+PL_C_FOFF], ax
    mov word [es:di+PL_C_PASS], 0xFFFF        ; force re-evaluation
.next:
    inc cx
    jmp .scan
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; Copy/Paste relative-reference adjustment (stage 2.x, per direct user
; report). pl_docmd_copy already remembers WHERE it copied from
; (pl_clip_col/pl_clip_row/pl_clip_valid, set below); pl_docmd_paste uses
; that plus its own destination (pl_selcol/pl_selrow) to compute a
; constant (col, row) delta and runs the copied formula's text through
; pl_formula_copyshift before handing it to pl_commit - the same "copy a
; formula, keep the cell it landed in" behavior every other spreadsheet's
; own default (non-absolute) reference already has.
;
; This reuses pl_rowcol_reidx's own low-level pieces (pl_isletter_at,
; pl_rw_emit, pl_rwsrc/pl_rwdst/pl_rw_di, pl_psheetpfx/pl_identcol/
; pl_colname/pl_pint/pl_itoa) but is otherwise a SEPARATE top-level scan,
; not a generalization of pl_formula_reidx: an Insert/Delete Row/Column
; shift only ever touches ONE axis (row XOR column) and only for
; references at or past a pivot; a copy/paste shift touches BOTH axes
; unconditionally by a fixed delta (pasting diagonally moves a reference
; diagonally too) and has no pivot or target-sheet concept at all - every
; reference in the formula, bare or "SheetN!"-prefixed alike, shifts by
; the exact same delta, matching real Excel's own relative-reference
; behavor when copying between sheets (the sheet name itself never
; changes, only the cell part does).
;
; pl_clip_valid is this instance's own memory of "the last thing *I*
; copied, and from where" - the real clipboard (OSAPI_CLIP_PUT/GET) is
; plain bytes with no provenance, so if something else overwrites it
; between the Copy and the Paste (a different app, or a different Sheet
; instance), a resulting paste here would only misfire if that unrelated
; text ALSO happens to start with '=' - accepted as a known, low-
; probability edge case rather than something worth adding real
; clipboard versioning for.
; =============================================================================

; pl_copy_shift - in: AX = a reference's original 0-based index, BX =
; the signed delta (pl_cp_coldelta or pl_cp_rowdelta), CX = that axis's
; cap (PL_COLS or PL_ROWS); out: AX = adjusted index, clamped to
; [0, CX-1] rather than allowed to go negative or off the grid - this
; project has no error-value concept anywhere (RK's unsupported subtype
; and division by zero both degrade the same "closest sane fallback,
; never crash" way)
pl_copy_shift:
    add ax, bx
    jns .nonneg
    jmp .dead                         ; off the top or the left edge: Excel
.nonneg:                              ; writes #REF! rather than clamping to
    cmp ax, cx                        ; A1, and clamping is what made
    jb .out                           ; `=A1` pasted one column left read as
    jmp .dead                         ; `=A1` again
.out:
    clc
    ret
.dead:
    stc
    ret

; pl_copy_cellpart - in: SI at a cell reference's first letter (the
; caller has already confirmed one is there via pl_isletter_at); out: SI
; advanced past the whole reference (letters and, if any followed,
; digits), and the reference emitted to pl_rwdst with BOTH its column
; and row shifted by [pl_cp_coldelta]/[pl_cp_rowdelta] - or, if this
; letter run turns out not to be followed by a digit (a function name,
; not a cell reference), the bare word emitted verbatim instead
pl_copy_cellpart:
    push ax
    push bx
    push cx
    push di
    mov [pl_cp_ostart], si
    mov byte [pl_cp_absc], 0           ; stage 3.0e: see pl_rw_absc
    mov byte [pl_cp_absr], 0
    mov byte [pl_cp_dead], 0           ; ...and stage 4.5: whether the shift
    cmp byte [si], '$'                 ; took this reference off the sheet.
    jne .nocoldollar                   ; The DECISION is deferred to the emit
    mov byte [pl_cp_absc], 1           ; below, because SI still has to be
    inc si                             ; advanced past the whole reference
                                       ; either way
.nocoldollar:
    mov di, pl_ident
    xor cx, cx
.letters:
    mov al, [si]
    cmp al, 'A'
    jb .doneletters
    cmp al, 'Z'
    jbe .isletter
    cmp al, 'a'
    jb .doneletters
    cmp al, 'z'
    ja .doneletters
.isletter:
    cmp cx, 7
    jae .doneletters
    mov ah, al
    and ah, 0xDF
    mov [di], ah
    inc di
    inc cx
    inc si
    jmp .letters
.doneletters:
    mov byte [di], 0
    mov [pl_cp_lettersend], si
    cmp byte [si], '$'
    jne .norowdollar
    mov byte [pl_cp_absr], 1
    inc si
.norowdollar:
    mov al, [si]
    cmp al, '0'
    jb .notref
    cmp al, '9'
    ja .notref
    call pl_identcol                   ; ax = 0-based col (from pl_ident)
    cmp byte [pl_cp_absc], 0           ; a pinned column does not follow the
    jne .colpinned                     ; paste's own displacement
    mov bx, [pl_cp_coldelta]
    mov cx, PL_COLS
    call pl_copy_shift
    jnc .colpinned
    mov byte [pl_cp_dead], 1
.colpinned:
    mov [pl_cp_refcol], ax
    mov bx, si
    add bx, PL_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call pl_pint                       ; ax = 1-based row text; si advances
    pop es
    dec ax                             ; ax = 0-based row
    cmp byte [pl_cp_absr], 0
    jne .rowpinned
    mov bx, [pl_cp_rowdelta]
    mov cx, PL_ROWS
    call pl_copy_shift
    jnc .rowpinned
    mov byte [pl_cp_dead], 1
.rowpinned:
    mov [pl_cp_refrow], ax
    mov [pl_cp_refend], si
    cmp byte [pl_cp_dead], 0
    je .cpalive
    call pl_rw_emitref
    jmp .out
.cpalive:
    cmp byte [pl_cp_absc], 0           ; both halves are REGENERATED below, so
    je .cpnocoldollar                  ; both markers have to be re-emitted
    mov al, '$'
    call pl_rw_emit
.cpnocoldollar:
    mov ax, [pl_cp_refcol]
    call pl_colname
    mov bx, pl_colbuf
.colemit:
    mov al, [bx]
    or al, al
    jz .rowdigits
    call pl_rw_emit
    inc bx
    jmp .colemit
.rowdigits:
    cmp byte [pl_cp_absr], 0
    je .cpnorowdollar
    mov al, '$'
    call pl_rw_emit
.cpnorowdollar:
    mov ax, [pl_cp_refrow]
    inc ax                             ; back to 1-based display text
    call pl_itoa
    mov bx, pl_numbuf
.rowdigemit:
    mov al, [bx]
    or al, al
    jz .out
    call pl_rw_emit
    inc bx
    jmp .rowdigemit
.notref:
    mov bx, [pl_cp_ostart]
.wcopy:
    cmp bx, si
    jae .out
    mov al, [bx]
    call pl_rw_emit
    inc bx
    jmp .wcopy
.out:
    pop di
    pop cx
    pop bx
    pop ax
    ret

; pl_formula_copyshift - in: SI = source formula text (DS-resident, NUL-
; terminated, no leading '='); [pl_cp_coldelta]/[pl_cp_rowdelta] already
; set by the caller (pl_docmd_paste). Out: pl_rwdst holds the shifted,
; NUL-terminated text, [pl_rw_di] = its length. Same token-recognition
; and quoted-string-is-verbatim rules as pl_formula_reidx (see that
; proc's own header comment for why a character scan, not a re-parse, is
; both sufficient and safe here).
pl_formula_copyshift:
    push ax
    push bx
    push si
    mov word [pl_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    call pl_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    call pl_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    call pl_isletter_at
    jnc .literal
    mov [pl_cp_ostart], si
    call pl_psheetpfx
    jnc .noxsheet
    call pl_isletter_at
    jc .pfxisref
    mov si, [pl_cp_ostart]             ; "SheetN!" not actually followed by
    mov bx, 7                          ; a reference: emit the 7 prefix
.pfxverb:                              ; bytes VERBATIM rather than letting
    mov al, [si]                       ; them be silently deleted (see the
    call pl_rw_emit                    ; matching fix in pl_formula_reidx)
    inc si
    dec bx
    jnz .pfxverb
    jmp .loop
.pfxisref:
    mov si, [pl_cp_ostart]
    mov bx, 7                          ; "SHEET" + one digit + "!" always
.copypfx:
    mov al, [si]
    call pl_rw_emit
    inc si
    dec bx
    jnz .copypfx
    call pl_copy_cellpart              ; the sheet name itself never
    jmp .loop                          ; shifts - only the cell part does
.noxsheet:
    call pl_copy_cellpart
    jmp .loop
.literal:
    mov al, [si]
    call pl_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [pl_rw_di]
    mov byte [pl_rwdst + bx], 0
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_getcell2 - in: AX=col, BX=row; out: CF=1 occupied + DX=value, CF=0 empty.
; Also always sets [pl_curfmt] to the cell's format byte (0 if empty) -
; a side channel the drawing code reads, since none of this proc's other
; callers (SYLK/DIF/BIFF export, range folding) care about it.
; -----------------------------------------------------------------------------
pl_getcell2:
    push ax
    push bx
    push di
    call pl_findcell
    jnc .empty
    push es
    mov es, [pl_cellseg]
    mov al, [es:di+5]
    mov [pl_curfmt], al
    mov al, [es:di+PL_C_TYPE]         ; stage 4.5: and the tag, so a caller can
    mov [pl_curtype], al              ; tell a label from the zero it would
    mov al, [es:di+PL_C_AUX]          ; the error code travels with the tag,
    mov [pl_curaux], al               ; so the painter can name it
    cmp byte [pl_curtype], PL_T_TEXT   ; ...and a LABEL loads its characters
    jne .nottext                       ; into pl_sacc, so a formula that names
    push ax                            ; one has something to work WITH rather
    call pl_txtslot                    ; than the zero underneath it (81.22)
    call pl_str_load
    pop ax
.nottext:
    mov ax, [es:di+PL_C_FOFF]         ; otherwise read as this cell's value
    mov [pl_curtoff], ax
    test byte [es:di+4], 1            ; HASFORMULA. An ERROR tag raises
    jz .plain                         ; pl_evalerr only AFTER this split
                                      ; (81.20): a formula cell's stored tag
                                      ; may predate the fix that unbreaks it,
                                      ; and raising from it here survived the
                                      ; clean re-evaluation below and wrote
                                      ; the old error back for the whole pass
    pop es
    ; BANK THIS CELL'S OWN IDENTITY ACROSS THE EVALUATION. pl_eval_cell
    ; recurses back through pl_getcell2 for every cell the formula names, and
    ; each of those overwrites every one of these - so a formula rendered with
    ; the FORMAT of the last cell it referenced, and, worse, with that cell's
    ; TYPE and text offset: `=A2+0` where A2 holds a label drew the label.
    ; The cell showed something that was not its value, and said nothing.
    ; Only the FORMAT is banked here - the one thing an evaluation cannot
    ; change. The type, the error code and the text offset all come back from
    ; pl_eval_cell's own writeback, because a text result's offset is its
    ; RESULT slot and not the formula text the banked copy would restore
    ; (81.22.1).
    mov al, [pl_curfmt]
    mov bx, [pl_curtoff]
    push ax
    push bx
    call pl_eval_cell                 ; leaves the full result in pl_acc, and
    pop bx                            ; DX as its truncated form
    pop ax
    mov [pl_curfmt], al
    cmp byte [pl_curtype], PL_T_TEXT   ; A TEXT RESULT KEEPS THE OFFSET THE
    je .offkept                        ; WRITEBACK PUBLISHED: it is the RESULT
    mov [pl_curtoff], bx               ; slot, and the banked one is the
.offkept:                              ; formula's own source text, which the
                                       ; cell would then draw instead (81.22.1).
                                       ; pl_curtype/pl_curaux are not banked at
                                       ; all: the evaluation decides them and
                                       ; publishes them at its writeback
    cmp byte [pl_curtype], PL_T_ERR   ; ...and an ERROR spreads: anything built
    jne .fresh                        ; on a broken cell is broken too - raised
    mov al, [pl_curaux]               ; from what the writeback (or a cache
    mov [pl_evalerr], al              ; hit's current tag) JUST published,
.fresh:                               ; never from the pre-evaluation one
    stc
    jmp .out
.plain:
    cmp byte [pl_curtype], PL_T_ERR   ; a formula-less error cell (pl_seterr,
    jne .pnum                         ; the BIFF reader) has no evaluation to
    mov al, [pl_curaux]               ; republish its tag, so the stored one
    mov [pl_evalerr], al              ; is current and spreads as before
.pnum:
    push si                           ; stage 4.0: the stored value is a full
    push cx                           ; double, so it comes out into pl_acc.
    mov si, pl_acc                    ; DX stays the truncated integer for the
    mov cx, 4                         ; callers that still want one.
.pcopy:
    mov ax, [es:di+PL_C_VAL]
    mov [si], ax
    add di, 2
    add si, 2
    dec cx
    jnz .pcopy
    pop cx
    pop si
    pop es
    call pl_acc_toint
    mov dx, ax
    stc
    jmp .out
.empty:
    mov byte [pl_curfmt], 0
    mov byte [pl_curtype], PL_T_BLANK
    push ax                           ; an empty cell is a zero value, and
    xor ax, ax                        ; pl_acc must say so rather than keeping
    call pl_acc_int                   ; whatever the last cell left there
    pop ax
    clc
.out:
    pop di
    pop bx
    pop ax
    ret

; =============================================================================
; The value accumulator (stage 4.0). The evaluator's working value is a double
; in pl_acc, not an integer in AX - a double does not fit a register, so it
; lives in memory and the machine stack carries a binary operator's left
; operand across the parse of its right.
;
; The INTEGER entry points below are kept as converting wrappers rather than
; being deleted. Roughly forty callers pass values as words - file readers,
; the chart scan, sort, fill, the macro engine - and converting them all in
; one change would have made a fault impossible to localise. They convert at
; the boundary and are correct for any value an integer can hold.
; =============================================================================

; pl_acc_store - pack the fp A accumulator into pl_acc
pl_acc_store:
    push di
    mov di, pl_acc
    call fx_pack_a
    pop di
    ret

; pl_acc_load_a - unpack pl_acc into fp A
pl_acc_load_a:
    push si
    mov si, pl_acc
    call fx_unpack_a
    pop si
    ret

; pl_acc_load_b - unpack pl_acc into fp B
pl_acc_load_b:
    push si
    mov si, pl_acc
    call fx_unpack_b
    pop si
    ret

; pl_acc_int - AX (signed) -> pl_acc
pl_acc_int:
    call fx_i2a
    call pl_acc_store
    ret

; pl_acc_toint - pl_acc -> AX (signed, truncated); CF=1 if it did not fit
pl_acc_toint:
    call pl_acc_load_a
    call fx_a2i
    ret

; pl_vpush - bank pl_acc on the machine stack. CLOBBERS AX (the return address
; goes through it), which is safe because the evaluator's value now lives in
; pl_acc rather than in a register.
pl_vpush:
    ; STKBALANCE-NET: +2 - 81.75: TWO WORDS now, not four; banks pl_acc on the CALLER's stack for a binary operator; pl_binop_pre takes it off
    pop ax
    push word [pl_acc+2]
    push word [pl_acc]
    push ax
    ret

; pl_binop_pre - recover a banked left operand into fp A and load pl_acc, the
; right operand, into fp B. Pairs with exactly one pl_vpush.
pl_binop_pre:
    ; STKBALANCE-NET: -2 - the other half of pl_vpush - one call each, always paired
    pop ax
    pop word [pl_lhs]
    pop word [pl_lhs+2]
    push ax
; pl_binop_ld - fp A = the banked left operand, fp B = pl_acc: pl_binop_pre's
; half that touches no stack, which CHART.OVL's copy calls back to (81.62)
pl_binop_ld:
    push si
    mov si, pl_lhs
    call fx_unpack_a
    pop si
    call pl_acc_load_b
    ret

; -----------------------------------------------------------------------------
; pl_setvald - in: AX=col, BX=row; the value is pl_acc. Out: CF=1 when
; refused (cell table full) - the cell keeps what it had.
; -----------------------------------------------------------------------------
pl_setvald:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    call pl_addcell
    jc .dfull
    push es
    mov es, [pl_cellseg]
    mov byte [es:di+4], 0             ; a plain value has no formula
    mov byte [es:di+PL_C_TYPE], PL_T_NUM
    mov si, pl_acc                    ; all EIGHT bytes of it
    mov cx, 4
.dcopy:
    mov ax, [si]
    mov [es:di+PL_C_VAL], ax
    add si, 2
    add di, 2
    dec cx
    jnz .dcopy
    pop es
    clc                               ; stored
    jmp .ddone
.dfull:
    stc                               ; refused - see the header
.ddone:
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_seterr - in: AX=col, BX=row, DL=an PL_ERR_* code (1..7). The cell
; becomes an ERROR VALUE with a zero underneath it, which is exactly what a
; file carrying one means. Used by the file readers, and (81.61) by Fill
; Right/Down, which is why it is RESIDENT: Fill turned an error constant into
; 0, and the readers reach it through a vector now.
; -----------------------------------------------------------------------------
section .text
pl_seterr:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    mov cl, dl                        ; the code, across pl_setvald
    push cx
    push ax                           ; the column, across pl_acc_int
    xor ax, ax
    call pl_acc_int
    pop ax
    call pl_setvald                    ; creates the record, tagged PL_T_NUM
    pop cx
    jc .out                            ; refused: CF=1 says so (81.61)
    call pl_findcell                   ; ...and now say what it really is
    jnc .out
    push es
    mov es, [pl_cellseg]
    mov byte [es:di+PL_C_TYPE], PL_T_ERR
    mov [es:di+PL_C_AUX], cl
    pop es
    clc
.out:
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

section .text

; -----------------------------------------------------------------------------
; pl_fsep - CF=1 when AL is a byte a space beside it can never matter to: an
; operator, a parenthesis, the argument comma, the range colon, or 0 (the
; start or the end of the text). For pl_setformula's space squeeze.
; -----------------------------------------------------------------------------
pl_fsep:
    push bx
    mov bx, pl_fseps
.lp:
    cmp al, [bx]
    je .yes
    inc bx
    cmp bx, pl_fseps_end
    jb .lp
    pop bx
    clc
    ret
.yes:
    pop bx
    stc
    ret

pl_fseps:     db 0, '+-*/^&=<>(),:'
pl_fseps_end:

; -----------------------------------------------------------------------------
; THE LOGICAL VALUE (81.51). A logical is the double 1.0 or 0.0 tagged
; PL_T_BOOL, so everything that only wants a number - arithmetic, IF's test,
; a chart - reads it unchanged, and only what SHOWS a value, STORES one or
; FOLDS a reference has to know it is there.
;
; pl_boolname - AX nonzero -> "TRUE", else "FALSE", into pl_numbuf. Bit 15 is
; ignored, so the top word of either double does as well as an integer.
; -----------------------------------------------------------------------------
pl_boolname:
    push ax
    push si
    push di
    mov si, pl_f_true
    and ax, 0x7FFF
    jnz .t
    mov si, pl_f_false
.t:
    mov di, pl_numbuf
    call pl_strcpy
    pop di
    pop si
    pop ax
    ret

; pl_boolword - CF=1 when the text at DS:SI is TRUE or FALSE, in any case and
; with nothing either side of it, and AX = 1 or 0 then.
pl_boolword:
    push di
    mov di, pl_f_true
    call pl_wordeq
    mov ax, 1                         ; MOV leaves CF as pl_wordeq set it
    jc .out
    mov di, pl_f_false
    call pl_wordeq
    mov ax, 0
.out:
    pop di
    ret

; pl_errword - CF=1 when the text at DS:SI is one of the seven error values,
; in any case and with nothing either side, and AX = its ERROR.TYPE then
pl_errword:
    push bx
    push di
    xor bx, bx
.l:
    cmp bx, 14
    jae .no
    mov di, [pl_errtab + bx]
    call pl_wordeq
    jc .yes
    add bx, 2
    jmp short .l
.yes:
    mov ax, bx
    shr ax, 1
    inc ax
    stc
    jmp short .out
.no:
    clc
.out:
    pop di
    pop bx
    ret

pl_wordeq:                            ; DS:SI in any case against DS:DI, upper
    push ax
    push si
    push di
.l:
    mov al, [si]
    cmp al, 'a'
    jb .u
    cmp al, 'z'
    ja .u
    sub al, 32
.u:
    cmp al, [di]
    jne .ne
    or al, al
    jz .eq
    inc si
    inc di
    jmp short .l
.eq:
    stc
    jmp short .out
.ne:
    clc
.out:
    pop di
    pop si
    pop ax
    ret

; pl_setbool - in: AX=col, BX=row, DL = the value (nonzero is TRUE). A logical
; CONSTANT: pl_setvald's record, retagged - pl_seterr's shape. Out: CF=1 when
; refused (the cell table is full) and the cell keeps what it had.
pl_setbool:
    push ax
    push di
    push es
    push ax
    xor ax, ax
    or dl, dl
    jz .v
    inc ax
.v:
    call pl_acc_int
    pop ax
    call pl_setvald
    jc .out
    call pl_findcell
    mov es, [pl_cellseg]
    mov byte [es:di+PL_C_TYPE], PL_T_BOOL
    clc
.out:
    pop es
    pop di
    pop ax
    ret

; pl_setlabel - pl_settext for text as a PERSON would have typed it: TRUE and
; FALSE are the logical, the way Excel reads that entry, and anything else is
; a label. Typing, SYLK's quoted K and a CSV field come through here; BIFF
; and DIF have a type of their own to say which it is, and do not.
pl_setlabel:
    push dx
    push ax
    call pl_boolword
    mov dx, ax
    pop ax
    jnc .text
    call pl_setbool
    pop dx
    ret
.text:
    call pl_settext
    pop dx
    ret

; pl_fnlogical - CF=1 when the function [pl_pfid] answers TRUE or FALSE:
; NOT, AND, OR, TRUE, FALSE, the IS family and EXACT
pl_fnlogical:
    push ax
    push bx
    mov ax, [pl_pfid]
    or ah, ah
    jnz .no
    mov bx, pl_fnlog
.l:
    cmp al, [bx]
    je .yes
    inc bx
    cmp bx, pl_fnlog_end
    jb .l
.no:
    pop bx
    pop ax
    clc
    ret
.yes:
    pop bx
    pop ax
    stc
    ret

pl_fnlog:     db 6, 8, 9, 20, 21, 25, 26, 27, 28, 29, 30, 31, 32, 48, 107
pl_fnlog_end:

; -----------------------------------------------------------------------------
; pl_setformula - in: AX=col, BX=row, SI=formula text (DS-resident,
; NUL-terminated, NOT including the leading '='). Out: CF=1 when refused
; (arena or cell table full) - the cell keeps what it had (pl_settext's
; contract, which this is a near-twin of).
; -----------------------------------------------------------------------------
pl_setformula:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [pl_fcol], ax
    mov [pl_frow], bx
    mov dx, si                        ; DX = start of the text, for the
                                       ; length count below
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov si, dx                        ; SI = start of the text again
    mov ax, [pl_txtlen]
    add ax, cx
    inc ax                            ; +1 for the NUL this stores too
    cmp ax, PL_TXT_CAP
    ja .noroom
    mov es, [pl_txtseg]
    mov di, [pl_txtlen]
    mov [pl_newoff], di               ; where THIS formula starts
    ; SPACES ARE DROPPED ON THE WAY IN (81.50), as Excel 2.1 drops them: its
    ; BIFF2 has no token to keep one in (tAttrSpace is BIFF3 on), so =1 + 2
    ; comes back =1+2. The evaluator does not step over a space between
    ; tokens, and never did - =1 + 2 used to answer 1. One space survives,
    ; where it stands between two OPERANDS (=1+2 3), because that is not a
    ; spacing but a mistake, and pl_eval_cell makes it #VALUE! rather than
    ; this closing it up into =1+23. A quoted string keeps every space.
    ; The count above is of the raw text, which this can only shorten.
    xor dx, dx                        ; DL = inside "...", DH = the last byte
.copy:                                ; stored (0 = none yet, a separator)
    lodsb
    cmp al, '"'
    jne .notq
    xor dl, 1
.notq:
    test dl, dl
    jnz .put
    cmp al, ' '
    jne .put
.sp:
    cmp byte [si], ' '                ; the whole run of spaces is one gap
    jne .spend
    inc si
    jmp short .sp
.spend:
    mov al, dh
    call pl_fsep
    jc .copy                          ; after an operator or '(': dropped
    mov al, [si]
    call pl_fsep
    jc .copy                          ; before one, or at the end: dropped
    mov al, ' '                       ; between two operands: ONE kept
.put:
    stosb
    mov dh, al
    or al, al
    jnz .copy
    mov [pl_txtlen], di
    mov ax, [pl_fcol]
    mov bx, [pl_frow]
    call pl_addcell
    jc .noroom
    push es
    mov es, [pl_cellseg]
    mov byte [es:di+4], 1             ; HASFORMULA
    mov byte [es:di+PL_C_TYPE], PL_T_NUM   ; stage 4.5: and RETAG it. Typing a
                                      ; formula over a label reuses that
                                      ; label's record, and without this the
                                      ; TEXT tag survived and the cell drew
                                      ; its old text forever while quietly
                                      ; computing the right answer underneath
    mov ax, [pl_newoff]
    mov [es:di+PL_C_FOFF], ax
    mov word [es:di+PL_C_PASS], 0xFFFF       ; a pass stamp pl_pass can never equal,
                                       ; forcing at least one real evaluation
    pop es
    clc                               ; stored
    jmp .done
.noroom:
    stc                               ; refused - see the header
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; RPN TOKENS - a formula that reaches BIFF as a FORMULA record instead of a
; flattened number.
;
; WHAT THIS DELIBERATELY DOES NOT DO, first, because the boundary is the whole
; design. It refuses any formula containing a FUNCTION CALL, and falls back to
; writing the cached value as NUMBER or RK exactly as before. The reason is not
; effort: docs/excelfileformat.pdf's section 3.12, "Built-in Sheet Functions",
; is marked *2do* - the index table is not written in that revision. A guessed
; index does not produce a broken file, it produces a file Excel opens happily
; and computes SOMETHING ELSE from, silently. That is strictly worse than
; carrying the value, which is at least right.
;
; BIFF3's tFunc and tFuncVar also take a ONE-BYTE index, so several of Sheet's
; own functions could not be expressed even with the table - POWER is 337.
;
; So: numbers, cell references, ranges, the six comparisons, + - * / ^, unary
; minus and parentheses. That is most of what a sheet actually holds, and every
; one of them is verifiable against a spec section that IS written.
;
; THE PARSER HERE IS A SECOND ONE, not the evaluator with a mode bolted on.
; pl_pexpr and friends compute; this walks the same grammar and emits. Two
; parsers can drift - but this one only ever has to answer "can I express
; this", and when it cannot the writer falls back to a path that was already
; correct. A shared parser with an emit flag would have put a second set of
; states inside the routine every cell value already depends on.
; =============================================================================
PL_PTG_ADD     equ 0x03                 ; the operator tokens (excelfileformat 3.5.7)
PL_PTG_SUB     equ 0x04
PL_PTG_MUL     equ 0x05
PL_PTG_DIV     equ 0x06
PL_PTG_POWER   equ 0x07
PL_PTG_LT      equ 0x09
PL_PTG_LE      equ 0x0A
PL_PTG_EQ      equ 0x0B
PL_PTG_GE      equ 0x0C
PL_PTG_GT      equ 0x0D
PL_PTG_NE      equ 0x0E
PL_PTG_UMINUS  equ 0x13
PL_PTG_PAREN   equ 0x15
PL_PTG_CONCAT  equ 0x08               ; 81.61: '&', a string constant and an
PL_PTG_STR     equ 0x17               ; error constant - cch byte, then bytes
PL_PTG_ERR     equ 0x1C               ; one byte, BIFF's own error code
PL_PTG_INT     equ 0x1E                 ; + a 16-bit unsigned
PL_PTG_NUM     equ 0x1F                 ; + an IEEE double
PL_PTG_FUNCV   equ 0x41                 ; tFuncV / tFuncVarV (3.7.1, 3.7.2).
PL_PTG_FUNCVARV equ 0x42                ; VALUE class throughout, like the refs
                                         ; below: a cell formula's result is a
                                         ; value, whatever the function's own
                                         ; default return class is
PL_PTG_REFV    equ 0x44                 ; value class: 3.3.4's transformation
PL_PTG_AREAV   equ 0x45                 ; turns the default R class into V inside
                                      ; an ordinary cell formula
PL_RPN_MAX   equ 96                   ; a token array longer than this is
                                      ; refused rather than truncated

; THE CONSTANTS ABOVE STAY IN BOTH ARMS and the code below does not. They are
; `equ`s and emit nothing, and PL_RPN_MAX still SIZES a bss slot further down
; (pl_rpn_buf, which pl_rwsrc is chained off) - so gating it out makes the
; whole bss chain non-constant and the two OS88_BSS assertions fail with
; "non-constant argument supplied to TIMES", which names neither the flag nor
; the symbol. PLAN's own bss ladder is 81.75's later stage; until it lands,
; PLAN reserves this buffer and never fills it.

; -----------------------------------------------------------------------------
; pl_settext - stage 4.5: store TEXT in a cell.
; in: AX = col, BX = row, SI = the NUL-terminated text
;
; Deliberately a near-twin of pl_setformula above rather than a shared routine
; the two both call. They agree on the arena copy and disagree on every flag
; that follows it, and a merged version would have been a copy of the first
; half wrapped in a parameter deciding the second - which is the same amount
; of code with a branch through the middle of it.
;
; THE TEXT LIVES IN THE FORMULA ARENA, at PL_C_FOFF, and the two never collide
; because a cell is one thing or the other: HASFORMULA clear plus a TEXT tag
; is the whole discrimination. Notes share this arena too (stage 3.0b) and are
; keyed separately, in their own table.
;
; Like a formula, retyping a label APPENDS and abandons the old bytes - the
; arena has no free list and never compacts. 8 KB is a lot of labels and this
; matches what formulas have always done, but it is a real ceiling rather than
; an oversight, and it is why .noroom below is a no-op rather than a wrong
; value written. Out: CF=1 when refused (arena or cell table full) - the cell
; keeps what it had, and a caller mid-permutation must STOP (see
; pl_sort_permcol).
; -----------------------------------------------------------------------------
section .text
pl_settext:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [pl_fcol], ax
    mov [pl_frow], bx
    mov dx, si
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov si, dx
    mov ax, [pl_txtlen]
    add ax, cx
    inc ax                            ; +1 for the NUL
    cmp ax, PL_TXT_CAP
    ja .noroom
    mov es, [pl_txtseg]
    mov di, [pl_txtlen]
    mov [pl_newoff], di
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    mov [pl_txtlen], di
    mov ax, [pl_fcol]
    mov bx, [pl_frow]
    call pl_addcell
    jc .noroom
    push es
    mov es, [pl_cellseg]
    mov byte [es:di+4], 0             ; NOT a formula: the tag is what says
    mov byte [es:di+PL_C_TYPE], PL_T_TEXT
    mov byte [es:di+PL_C_AUX], 0
    mov ax, [pl_newoff]
    mov [es:di+PL_C_FOFF], ax
    mov word [es:di+PL_C_PASS], 0
    xor ax, ax                        ; and a numeric value of zero, so every
    mov [es:di+PL_C_VAL], ax          ; reader that has never heard of text
    mov [es:di+PL_C_VAL+2], ax        ; still gets a defined number out of it
    pop es
    clc                               ; stored
    jmp .done
.noroom:
    stc                               ; refused - see the header
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_eval_cell - evaluate a formula cell, with cycle detection and
; per-repaint memoization
; in: DI = record offset (a HASFORMULA record); ES = pl_cellseg
; out: DX = value; the record's cached value and pass stamp are updated
; -----------------------------------------------------------------------------
pl_eval_cell:
    push ax
    push bx
    push si
    push di
    push es
    mov es, [pl_cellseg]
    mov ax, [es:di+PL_C_PASS]                ; this cell's last-computed pass
    cmp ax, [pl_pass]
    jne .stale
    test byte [es:di+4], 2            ; EVALUATING - already mid-computation
    jnz .cycle                        ; means a cycle, not a cache hit
    call pl_cellval_to_acc            ; a cache hit is a full double now, not
    call pl_acc_toint                 ; a word; DX stays the truncated form
    mov dx, ax                        ; for the callers that still want one
    jmp .out
.stale:
    test byte [es:di+4], 2
    jnz .cycle
    or byte [es:di+4], 2              ; EVALUATING = 1
    push di                           ; this cell's record offset, kept on
                                       ; the stack (NOT a global) because
                                       ; evaluating this formula may recurse
                                       ; into pl_eval_cell again for a cell
                                       ; it references, and call/ret through
                                       ; pl_pexpr is stack-neutral either way
    push word [pl_evrow]              ; stage 3.0d: ROW()/COLUMN()'s context,
    push word [pl_evcol]              ; banked for the SAME reason and popped
    mov ax, [es:di]                   ; at .writeback. A referenced cell's own
    and ax, PL_ROW_MASK               ; formula must answer for ITSELF, so this
    mov [pl_evrow], ax                ; is per-frame, not set once
    mov ax, [es:di+2]
    mov [pl_evcol], ax
    mov ax, [es:di+PL_C_FOFF]                 ; formula_off
    mov si, ax
    mov es, [pl_txtseg]
    cmp word [pl_evaldepth], PL_EVAL_MAXDEPTH
    jae .toodeep
    cmp word [pl_evaldepth], 0        ; a FRESH evaluation starts clean; a
    jne .depthok                      ; nested one must not, or a referenced
    mov byte [pl_evalerr], 0          ; cell's error would be wiped on the way
    mov word [pl_sstk_sp], 0          ; back up. The string bank is reset with
.depthok:                             ; it, so an error path that returned
                                       ; early cannot leak a level into the
                                       ; next formula
    mov bx, [pl_evaldepth]
    inc word [pl_evaldepth]
    push bx                           ; this recursion level's buffer slot
    mov ax, PL_EDITMAX + 1
    mul bx
    add ax, pl_fbuf
    mov di, ax                        ; DI = this level's OWN copy of the
                                       ; formula text - a nested evaluation
                                       ; (of a cell THIS formula references)
                                       ; gets a DIFFERENT slot, so it cannot
                                       ; overwrite the text we are still
                                       ; parsing
    mov bx, di
.copyin:
    mov al, [es:si]
    mov [di], al                      ; DS-relative: our own scratch buffer
    inc si
    inc di
    or al, al
    jnz .copyin
    mov si, bx
    call pl_pcmp                      ; the result lands in pl_acc, and may
                                       ; have recursed to get there
    cmp byte [si], 0                  ; THE WHOLE FORMULA, OR IT IS NOT ONE
    je .whole                         ; (81.50). The parse used to stop quietly
    cmp byte [pl_evalerr], 0          ; at the first character it could not
    jne .whole                        ; use, so =1+2 3 answered 3 and =(1+2)3
    mov byte [pl_evalerr], PL_ERR_VALUE ; answered 3 - the "3.5kg" rule pl_commit
.whole:                               ; keeps for a number, and =1+'s rule
    pop bx                            ; for a formula that stops too soon
    dec word [pl_evaldepth]
    jmp .writeback
.toodeep:
    xor dx, dx
    push ax
    xor ax, ax
    call pl_acc_int                   ; too deep is a zero, in both forms
    pop ax
.writeback:
    pop word [pl_evcol]               ; stage 3.0d: ROW()/COLUMN() context,
    pop word [pl_evrow]               ; restored in the order it was pushed
    pop di                            ; this cell's record offset, restored
    mov es, [pl_cellseg]
    and byte [es:di+4], 0xFD          ; EVALUATING = 0 (HASFORMULA untouched)
    call pl_acc_toint                 ; DX = the truncated form, for callers
    mov dx, ax
    ; CACHING THE DOUBLE IS NOT THE FIRST THING ANY MORE, and it cannot be:
    ; pl_acc_to_cellval writes eight bytes over PL_C_VAL, and a TEXT result's
    ; slot offset lives in that same union (81.22.1). Doing it up front wiped
    ; the slot on every pass, so pl_str_store found VAL zero, allocated a fresh
    ; 65 bytes, and the arena was empty inside a hundred repaints - after which
    ; every text formula quietly fell back to the number underneath it, which
    ; is 0. Each branch below caches for itself, and the text one does not.
    mov al, [pl_evalerr]              ; the cell is stored by what it IS: an
    or al, al                         ; error, or a number again once whatever
    jz .notanerr                      ; broke it has been fixed
    call pl_acc_to_cellval
    mov byte [es:di+PL_C_TYPE], PL_T_ERR
    mov [es:di+PL_C_AUX], al
    mov byte [pl_curtype], PL_T_ERR   ; and PUBLISH it: the caller banked these
    mov [pl_curaux], al               ; two before the evaluation ran, so its
    jmp .errdone                      ; copy names the cell as it USED to be -
.notanerr:                            ; which paints #DIV/0! on a cell whose
    cmp byte [pl_curtype], PL_T_TEXT  ; stage 4.5: ...or the answer is a
    jne .notatext                     ; STRING, which PL_C_FOFF cannot hold
    call pl_str_store                 ; because the formula's own text is
    jc .notatext                      ; already there (81.22.1)
    mov byte [es:di+PL_C_TYPE], PL_T_TEXT
    mov byte [es:di+PL_C_AUX], 0
    mov ax, [es:di+PL_C_VAL]          ; the painter reads the RESULT, not the
    mov [pl_curtoff], ax              ; formula, so publish where it went
    jmp .errdone
.notatext:
    call pl_acc_to_cellval            ; cache the whole double
    mov ax, [es:di+PL_C_FOFF]         ; and a NUMERIC result publishes the
    mov [pl_curtoff], ax              ; formula's own text, which is what every
                                       ; reader of it has always expected
    mov al, PL_T_NUM                  ; ...or a LOGICAL one, the same double
    cmp byte [pl_curtype], PL_T_BOOL  ; with its own tag (81.51)
    jne .tagnum
    mov al, PL_T_BOOL
.tagnum:
    mov byte [es:di+PL_C_TYPE], al    ; divisor has since been fixed, and
    mov byte [es:di+PL_C_AUX], 0      ; #ERR on the one that is still broken
    mov [pl_curtype], al              ; (its code having been overwritten by
    mov byte [pl_curaux], 0           ; the last cell the formula referenced)
.errdone:
    mov ax, [pl_pass]
    mov [es:di+PL_C_PASS], ax
    jmp .out
.cycle:
    xor dx, dx
    push ax
    xor ax, ax
    call pl_acc_int                   ; a cycle is a zero, in both forms
    pop ax
.out:
    pop es
    pop di
    pop si
    pop bx
    pop ax
    ret

; =============================================================================
; Formula parser/evaluator - recursive descent over pl_fbuf (a DS-resident
; copy of the formula text; see pl_eval_cell). Grammar:
;   expr   := term (('+'|'-') term)*
;   term   := pow (('*'|'/') pow)*
;   pow    := factor ('^' pow)?            ; right-associative (stage 3.0d)
;   factor := '-' factor | '(' expr ')' | NUMBER | CELLREF | NAME '(' args ')'
;   args   := arg (',' arg)*
;   arg    := CELLREF ':' CELLREF | expr
; No whitespace skipping: pl_setformula drops every space on the way in
; except one between two operands, which is a mistake, and pl_eval_cell makes
; whatever the parse leaves over #VALUE! (81.50). This used to say the editor
; never let a space through, which no file reader ever promised.
; Every value is a 16-bit signed integer; division truncates toward zero
; (IDIV) and division by zero yields 0 rather than faulting - a stated
; simplification, not an oversight, matching this project's "no formulas,
; no formatting" -> "formulas, still no formatting" progression: nothing
; here produces or accepts a fraction. SUM/AVERAGE/MIN/MAX/COUNT are "the
; most common formulas" the roadmap asks for first; comparisons, IF() and
; the rest are later-stage work.
; =============================================================================

; pl_pcmp / pl_pcmpcont - comparison level, the actual top of the grammar
; (pl_eval_cell enters here, not at pl_pexpr): '=' '<' '>' '<=' '>=' '<>'
; between two '&'-level operands, answering a LOGICAL (81.51) by Excel's
; ordering of types (81.53). LEFT-ASSOCIATIVE, as Excel's are: =1<2<3 is
; (1<2)<3, TRUE against 3, and a logical is above every number - FALSE. It
; stopped after one comparison, which since 81.50 left "<3" over, #VALUE!.
pl_pcmp:
    call pl_pconcat
pl_pcmpcont:
    mov al, [si]
    cmp al, '='
    je .eq
    cmp al, '<'
    je .lt
    cmp al, '>'
    je .gt
    ret
.eq:                                  ; AH = the outcomes that answer TRUE:
    inc si                            ; 1 left below, 2 equal, 4 left above
    mov ah, 2
    jmp short .have
.lt:
    inc si
    mov ah, 1
    cmp byte [si], '='
    jne .lt2
    inc si
    mov ah, 3
    jmp short .have
.lt2:
    cmp byte [si], '>'
    jne .have
    inc si
    mov ah, 5
    jmp short .have
.gt:
    inc si
    mov ah, 4
    cmp byte [si], '='
    jne .have
    inc si
    mov ah, 6
    ; COMPARED BY TYPE (81.53). This compared the two NUMBERS and nothing
    ; else, so two texts compared as the zeros underneath them: ="a"="b" was
    ; TRUE and every IF(A1="yes",...) took its first branch. Excel's rule:
    ; text against text, case-insensitively (pl_lkstrcmp, the lookups' own);
    ; across types every number is below every text, below FALSE, below TRUE;
    ; a blank is 0 to a number, "" to a text and FALSE to a logical. BX, CX
    ; and DX are kept - CHOOSE counts in two of them across a whole argument.
.have:
    push bx
    push cx
    push dx
    mov al, [pl_curtype]              ; the LEFT operand's type, and its text
    cmp al, PL_T_TEXT                 ; banked where the right one's parse
    jne .nobank                       ; cannot reach it
    call pl_spush
    jnc .nobank
    mov al, PL_T_ERR                  ; the bank is full: #VALUE! is raised,
.nobank:                              ; and there is nothing to drop later
    push ax
    call pl_vpush
    call pl_pconcat                   ; the RIGHT at the '&' level: this was
    call pl_binop_pre                 ; pl_pexpr, so ="ab"="a"&"b" left the
    pop dx                            ; &"b" over. DH = outcomes, DL = left
    mov cl, [pl_curtype]              ; CL = the right's type
    mov bl, dl                        ; BL, CH: the types as COMPARED - a blank
    mov ch, cl                        ; takes the other side's
    cmp bl, PL_T_BLANK
    jne .lset
    mov bl, ch
.lset:
    cmp ch, PL_T_BLANK
    jne .rset
    mov ch, bl
.rset:
    mov al, bl
    call pl_cmprank
    mov ah, al
    mov al, ch
    call pl_cmprank                   ; AH = the left's rank, AL = the right's
    cmp ah, al
    je .same
    mov ax, -1                        ; MOV keeps CMP's flags
    jb .outcome
    mov ax, 1
    jmp short .outcome
.same:
    cmp al, 1
    je .text
    call fx_cmpab                     ; numbers and logicals: AX = -1/0/1
    jmp short .outcome
.text:
    push si
    push di
    mov si, pl_snull                  ; a blank side is ""
    cmp dl, PL_T_TEXT
    jne .ltext
    xor ax, ax
    call pl_sslot                     ; SI = the banked left text
.ltext:
    mov di, pl_snull
    cmp cl, PL_T_TEXT
    jne .rtext
    mov di, pl_sacc
.rtext:
    call pl_lkstrcmp
    pop di
    pop si
.outcome:
    cmp dl, PL_T_TEXT
    jne .nodrop
    call pl_spop                      ; the left text's bank
.nodrop:
    mov cl, 2
    or ax, ax
    jz .bit
    mov cl, 1
    js .bit
    mov cl, 4
.bit:
    xor ax, ax
    test dh, cl
    jz .res
    inc ax
.res:
    call pl_acc_int
    mov byte [pl_curtype], PL_T_BOOL  ; a COMPARISON answers a LOGICAL (81.51)
    pop dx
    pop cx
    pop bx
    jmp pl_pcmpcont                   ; ...and may be the left of another

; pl_cmprank - AL = a type -> AL = its rank for a comparison: 0 a number (or
; a blank that met one), 1 text, 2 a logical
pl_cmprank:
    cmp al, PL_T_TEXT
    je .t
    cmp al, PL_T_BOOL
    je .b
    xor al, al
    ret
.t:
    mov al, 1
    ret
.b:
    mov al, 2
    ret

; pl_pexpr / pl_pexprcont - additive level. pl_pexprcont is a real entry
; point of its own: pl_prange calls it to resume the +/- loop after folding
; a lone cell reference that turned out not to start a range.
pl_pexpr:
    call pl_pterm
pl_pexprcont:
    cmp byte [si], '+'
    je .add
    cmp byte [si], '-'
    je .sub
    ret
.add:
    call pl_chktext                   ; the LEFT operand, which pl_curtype
    inc si                            ; still describes
    call pl_vpush                     ; the left operand goes on the machine
    call pl_pterm                     ; stack: a double does not fit a register
    call pl_chktext                   ; ...and now the right
    call pl_binop_pre                 ; and the parse of the right may recurse
    call fx_add
    call pl_acc_store
    mov byte [pl_curtype], PL_T_NUM   ; stage 4.5: the RESULT of arithmetic is
    jmp pl_pexprcont                  ; a NUMBER whatever its operands were
                                       ; tagged. Nothing used to say so, so the
                                       ; tag left by the last cell an operand
                                       ; touched still stood - unobservable
                                       ; until pl_pargclass below made a
                                       ; mid-expression tag answerable
.sub:
    call pl_chktext
    inc si
    call pl_vpush
    call pl_pterm
    call pl_chktext
    call pl_binop_pre
    call fx_sub
    call pl_acc_store
    mov byte [pl_curtype], PL_T_NUM
    jmp pl_pexprcont

; -----------------------------------------------------------------------------
; pl_pconcat (stage 4.5) - the '&' level. Excel binds it LOOSER than '+' and
; TIGHTER than a comparison, so `="a"&"b"="ab"` compares two concatenations
; rather than concatenating a comparison (81.22.2).
;
; Either side may be a number - `=A1&"x"` with A1 holding 12 gives "12x", which
; is what every spreadsheet does - so a numeric operand is formatted into
; pl_sacc first. The left operand is banked in pl_sacc2 across the right one's
; parse, because parsing the right may recurse all the way back through here.
; -----------------------------------------------------------------------------
pl_pconcat:
    call pl_pexpr
pl_pconcatcont:
    cmp byte [si], '&'
    je .cat
    ret
.cat:
    inc si
    call pl_str_want                  ; the LEFT operand, as text, BANKED ON
    call pl_spush                     ; THE STRING STACK: the right one's parse
    sbb ax, ax                        ; can reach this routine again, and the
    push ax                           ; one global it was banked in was
    call pl_pexpr                     ; overwritten - ="a"&("b"&"c") was "bbc"
    call pl_str_want                  ; (81.53). AX = -1: the bank was full
    push si                           ; the RIGHT operand, as text, out of
    push di                           ; the way...
    mov si, pl_sacc
    mov di, pl_sacc2
    call pl_strcpy
    pop di
    pop si
    pop ax
    or ax, ax
    jnz .nobank                       ; #VALUE! is raised already
    call pl_srestore                  ; ...the left back into pl_sacc...
.nobank:
    push si
    push di
    mov si, pl_sacc2                  ; ...and the right appended
    call pl_str_cat
    pop di
    pop si
    mov byte [pl_curtype], PL_T_TEXT
    xor ax, ax
    call pl_acc_int
    jmp pl_pconcatcont

; -----------------------------------------------------------------------------
; pl_str_want - make pl_sacc hold the current result AS TEXT, whatever it is.
; A number is formatted the way the General format shows it, so `=1.5&"x"` is
; "1.5x" and not "1.500000x".
; -----------------------------------------------------------------------------
pl_str_want:
    cmp byte [pl_curtype], PL_T_TEXT
    je .done
    push ax
    push si
    push di
    cmp byte [pl_curtype], PL_T_BOOL  ; a LOGICAL is its name: ="x"&TRUE is
    jne .num                          ; "xTRUE", LEN(TRUE) is 4 (81.51)
    mov ax, [pl_acc]
    call pl_boolname
    jmp short .copy
.num:
    call pl_acc_load_a
    mov di, pl_numbuf
    mov ax, 10
    call fx_ftoa
.copy:
    mov si, pl_numbuf
    mov di, pl_sacc
    call pl_strcpy
    pop di
    pop si
    pop ax
.done:
    ret

; pl_pterm / pl_ptermcont - multiplicative level, same reasoning as above.
pl_pterm:
    call pl_ppow
pl_ptermcont:
    cmp byte [si], '*'
    je .mul
    cmp byte [si], '/'
    je .div
    ret
.mul:
    call pl_chktext
    inc si
    call pl_vpush
    call pl_ppow
    call pl_chktext
    call pl_binop_pre
    call fx_mul
    call pl_acc_store
    mov byte [pl_curtype], PL_T_NUM
    jmp pl_ptermcont
.div:
    call pl_chktext
    inc si
    call pl_vpush
    call pl_ppow
    call pl_chktext
    call pl_binop_pre
    call fx_div                       ; CF=1 means the divisor was zero
    jnc .divok
    mov byte [pl_evalerr], PL_ERR_DIV0
    xor ax, ax                        ; the value is still zero underneath -
    call pl_acc_int                   ; the flag is what the cell is stored by
    mov byte [pl_curtype], PL_T_NUM
    jmp pl_ptermcont
.divok:
    call pl_acc_store
    mov byte [pl_curtype], PL_T_NUM
    jmp pl_ptermcont

; pl_ppow (stage 3.0d) - the '^' level, between multiplication and the
; factors. RIGHT-associative, so 2^3^2 is 2^(3^2) = 512, which is what every
; spreadsheet does; the recursion below is what makes it so, where a loop like
; pl_ptermcont's would have made it left-associative.
;
; It binds TIGHTER than '*' and looser than unary minus, so -2^2 is -(2^2).
; That is Excel's own precedence and it surprises people, but matching it is
; the point.
;
; A negative exponent is a fraction and there is no fraction here, so it
; yields 0 - the same answer this evaluator already gives for division by
; zero, and for the same stated reason.
; pl_ppowcont is a real entry point of its own, like pl_ptermcont's: pl_prange
; calls it FIRST to resume a lone cell reference that turned out not to start
; a range - without it, `=SUM(A1^2)` left the '^' for pl_pfunc's argument loop,
; which can only stop at it.
pl_ppow:
    call pl_pfactor
pl_ppowcont:
    cmp byte [si], '^'
    jne .out
    call pl_chktext
    inc si
    call pl_pnest_enter               ; '^' recurses too (81.3)
    jc .nestfull
    call pl_vpush                     ; the BASE, banked
    call pl_ppow                      ; recurse: right-associative
    call pl_pnest_leave
    call pl_chktext
    mov byte [pl_curtype], PL_T_NUM
    call pl_acc_load_a                ; THE EXPONENT MAY BE FRACTIONAL NOW.
    call fx_a_to_b                    ; This banked it through pl_acc_toint
    pop word [pl_lhs]                 ; and multiplied the base by itself that
    pop word [pl_lhs+2]               ; many times, with a comment saying "a
    push si                           ; stopped being true at 84.8. 2^0.5 is
    mov si, pl_lhs                    ; 1.414 and not 1
    call fx_unpack_a
    pop si
    call fx_pow
    jnc .powok
    mov byte [pl_evalerr], PL_ERR_NUM ; a negative base to a fractional power
    call fx_azero                     ; has no real value
.powok:
    call pl_acc_store
.out:
    ret
.nestfull:
    push ax                           ; over the budget: the base is dropped,
    xor ax, ax                        ; and the #VALUE! pl_pnest_enter raised
    call pl_acc_int                   ; stands
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_pnest_enter / pl_pnest_leave - the parser's shared nesting budget (81.3).
; PL_EVAL_MAXDEPTH bounds cell-to-cell recursion, but nothing bounded a
; formula's OWN nesting: every '(', unary '-', '^' and nested call recurses
; the parser and banks bytes on task 0's 512-byte stack, and six
; memoization-cold cells chained that way could run SP off the stack's floor
; into .lowbss - silent corruption that fails later, somewhere unrelated.
; One counter charges every recursion point, with the cell depth folded in;
; over PL_PNEST_MAX the parse refuses with #VALUE! - the same refusal shape
; pl_eval_cell's .toodeep already has.
; out: CF=1 refused (pl_evalerr raised, NOTHING charged - do not leave),
;      CF=0 charged - pair with exactly one pl_pnest_leave
; -----------------------------------------------------------------------------
pl_pnest_enter:
    push ax
    mov ax, [pl_pnest]
    inc ax
    add ax, [pl_evaldepth]
    cmp ax, PL_PNEST_MAX
    ja .full
    inc word [pl_pnest]
    pop ax
    clc
    ret
.full:
    pop ax
    mov byte [pl_evalerr], PL_ERR_VALUE
    stc
    ret

pl_pnest_leave:
    dec word [pl_pnest]
    ret

; pl_pfactor - unary minus, parens, a number, or an identifier (cell
; reference or function call, pl_pident tells them apart)
pl_pfactor:
    cmp byte [si], '-'
    jne .notneg
    inc si
    call pl_pnest_enter               ; unary minus recurses (81.3)
    jc .nestfull
    call pl_pfactor
    call pl_pnest_leave
    call pl_chktext                   ; -"text" is arithmetic too
    call pl_acc_neg                   ; 81.75: two's complement, not a sign
    mov byte [pl_curtype], PL_T_NUM   ; bit. A NUMBER, as every operator's
    ret                               ; result is: -TRUE is -1, not a logical
                                      ; (81.51)
.notneg:
    cmp byte [si], '('
    jne .notparen
    inc si
    call pl_pnest_enter               ; ...and so does a parenthesis
    jc .nestfull
    call pl_pcmp
    call pl_pnest_leave
    cmp byte [si], ')'
    jne .out                          ; malformed; return whatever we have
    inc si
    ret
.nestfull:
    push ax                           ; over the budget: pl_pnest_enter has
    xor ax, ax                        ; raised #VALUE!, and the refusal
    call pl_acc_int                   ; answers zero underneath it
    pop ax
    ret
.notparen:
    mov al, [si]
    cmp al, 34                        ; stage 4.5: a QUOTED LITERAL is a text
    je .strlit                        ; value (81.22)
    cmp al, '#'                       ; ...and an ERROR VALUE spelled out is a
    je .errlit                        ; literal too (81.26.2)
    cmp al, '$'                       ; stage 3.0e: '$A$1' is an IDENTIFIER,
    je .ident                         ; and this router decides that on the
    cmp al, 'A'                       ; FIRST character - without this line a
    jb .maybenum                      ; leading '$' falls through to the
    cmp al, 'Z'                       ; number path and the whole reference
    jbe .ident                        ; evaluates to 0. pl_pident tolerating
    cmp al, 'a'                       ; '$' is necessary but not sufficient.
    jb .maybenum
    cmp al, 'z'
    ja .maybenum
.ident:
    call pl_pident
    ret
.maybenum:
    jmp .maybenum2
.strlit:
    inc si                            ; past the opening quote
    push cx
    push di
    mov di, pl_sacc
    mov cx, PL_STR_MAX
.slc:
    jcxz .slend
    mov al, [si]
    or al, al
    jz .slend
    cmp al, 34                        ; a DOUBLED quote is one literal quote,
    jne .slkeep                       ; the same rule SYLK's K field uses
    cmp byte [si+1], 34
    jne .slend
    inc si
.slkeep:
    mov [di], al
    inc di
    inc si
    dec cx
    jmp .slc
.slend:
    mov byte [di], 0
    cmp byte [si], 34                 ; step over the closing quote if it is
    jne .slnoq                        ; there; an unterminated literal ends at
    inc si                            ; the end of the formula rather than
.slnoq:                               ; running off it
    pop di
    pop cx
    mov byte [pl_curtype], PL_T_TEXT
    xor ax, ax                        ; the number underneath a string is zero,
    call pl_acc_int                   ; so a reader that wants one gets a
    ret                               ; defined answer
.errlit:
    call pl_perrlit
    ret
.maybenum2:
    mov byte [pl_curtype], PL_T_NUM   ; a LITERAL is a number - say so, or the
    call fx_atof                      ; tag left by the last cell referenced
    jnc .numok                        ; still stands and `=B4+1` is judged by
    mov byte [pl_evalerr], PL_ERR_VALUE ; B4's type twice over
    xor ax, ax                        ; nothing parseable at all: `=1+` used to
    call pl_acc_int                   ; read as 1, an answer to a formula the
    ret                               ; user never finished writing
.numok:
    call pl_acc_store
.out:
    ret

; -----------------------------------------------------------------------------
; pl_perrlit (stage 4.5) - SI is at a '#'. An error value written out in full
; is a LITERAL, as it is in Excel, and this file needs to read one for a
; reason of its own: Delete Row and Delete Column now write `#REF!` into every
; formula that named a deleted cell (81.26.1), so the parser has to be able to
; read back what the rewriter wrote. Typing `=#N/A` works for the same reason,
; which is also what Excel does.
;
; The names come from pl_errtab - the same table pl_errname prints and
; pl_errcode reads - so the spelling written and the spelling recognised
; cannot drift apart. No name is a prefix of another, so first match wins.
;
; out: the error raised in pl_evalerr, pl_acc zero, SI past the name. A '#'
; followed by something else is #NAME?, which is what an unknown word already
; gets, and SI steps over the '#' so the parse can still make progress.
; -----------------------------------------------------------------------------
pl_perrlit:
    push bx
    push cx
    push di
    xor cx, cx
.try:
    cmp cx, 7
    jae .unknown
    mov bx, cx
    shl bx, 1
    mov di, [pl_errtab + bx]
    call pl_matchat                   ; is that name a prefix of SI?
    jc .found
    inc cx
    jmp .try
.found:
    mov bx, cx
    shl bx, 1
    mov di, [pl_errtab + bx]
.skip:
    cmp byte [di], 0
    je .done
    inc di
    inc si
    jmp .skip
.done:
    inc cx                            ; the table is 0-based, the ERROR.TYPE
    mov [pl_evalerr], cl              ; codes are 1-based
    jmp .out
.unknown:
    mov byte [pl_evalerr], PL_ERR_NAME
    inc si
.out:
    mov byte [pl_curtype], PL_T_NUM
    xor ax, ax
    call pl_acc_int
    pop di
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_psheetpfx - stage 2.0: does SI start a "SheetN!" cross-sheet prefix?
; Sheet names are the fixed "Sheet1".."SheetN" strings (see the Sheets menu
; comment), so this is a literal, case-insensitive match against "SHEET"
; plus a digit '1'..PL_SHEETS - not a general name lookup.
; in: SI; out: CF=1 and AX=0-based sheet index, SI advanced past the '!';
; CF=0 and SI unchanged otherwise
; -----------------------------------------------------------------------------
pl_psheetpfx:
    push bx
    push cx
    mov bx, si
    mov al, [bx]
    and al, 0xDF
    cmp al, 'S'
    jne .no
    inc bx
    mov al, [bx]
    and al, 0xDF
    cmp al, 'H'
    jne .no
    inc bx
    mov al, [bx]
    and al, 0xDF
    cmp al, 'E'
    jne .no
    inc bx
    mov al, [bx]
    and al, 0xDF
    cmp al, 'E'
    jne .no
    inc bx
    mov al, [bx]
    and al, 0xDF
    cmp al, 'T'
    jne .no
    inc bx
    mov al, [bx]
    cmp al, '1'
    jb .no
    cmp al, '0' + PL_SHEETS
    ja .no
    sub al, '1'
    xor ah, ah
    mov cx, ax                        ; cx = sheet index 0..PL_SHEETS-1
    inc bx
    cmp byte [bx], '!'
    jne .no
    inc bx
    mov si, bx
    mov ax, cx
    stc
    jmp .out
.no:
    clc
.out:
    pop cx
    pop bx
    ret

; pl_pident - in: SI at an identifier's first letter
; out: AX = value (a cell's value, or a function call's result), SI advanced
pl_pident:
    push bx
    push cx
    push dx
    push di
    mov byte [pl_pxsheet], 0xFF
    call pl_psheetpfx
    jnc .noxsheet
    mov [pl_pxsheet], al
.noxsheet:
    cmp byte [si], '$'                ; stage 3.0e: skip an absolute marker
    jne .nocoldollar                  ; before the column letters
    inc si
.nocoldollar:
    mov di, pl_ident
    xor cx, cx
.collect:
    mov al, [si]
    cmp al, 'A'
    jb .trydot
    cmp al, 'Z'
    jbe .isletter
    cmp al, 'a'
    jb .trydot
    cmp al, 'z'
    ja .trydot
    jmp .isletter
.trydot:
    cmp al, '.'                       ; stage 4.5: a '.' INSIDE a name, which
    jne .doneletters                  ; is how ERROR.TYPE is spelled. Only
    or cx, cx                         ; after a letter, so a LEADING '.' is
    jz .doneletters                   ; still the start of a number (`.5`) and
    cmp cx, PL_NAME_MAX               ; a cell reference still cannot hold one
    jae .doneletters
    jmp .store                        ; ...and it does NOT go through the
                                       ; uppercase fold below: '.' AND 0xDF is
                                       ; 0x0E, which would have put a control
                                       ; character in the middle of the name
.isletter:
    cmp cx, PL_NAME_MAX               ; a DEFINED NAME can be this long, so the
    jae .doneletters                  ; cap is its length rather than a column
                                       ; pair's - a function name is shorter
                                       ; than either
    and al, 0xDF                      ; normalize to uppercase
.store:
    mov [di], al
    inc di
    inc cx
    inc si
    jmp .collect
.doneletters:
    ; A NAME MAY END IN DIGITS - LOG10 is the first one that does, and it lexed
    ; as the column LOG followed by the row 10 (81.35). Excel's own rule is
    ; what settles it: letters then digits then '(' is a FUNCTION, and letters
    ; then digits then anything else is a CELL. So the digits are looked past
    ; without being consumed, and only a '(' beyond them pulls them into the
    ; name - a lookahead, so A1 and $A$1 reach the reference path untouched.
    push si
    push cx
.lkdig:
    mov al, [si]
    cmp al, '0'
    jb .lkend
    cmp al, '9'
    ja .lkend
    inc si
    inc cx
    jmp short .lkdig
.lkend:
    cmp byte [si], '('
    jne .nodigname
    cmp cx, PL_NAME_MAX
    ja .nodigname
    pop cx
    pop si
.digname:                             ; take them after all
    mov al, [si]
    cmp al, '0'
    jb .digdone
    cmp al, '9'
    ja .digdone
    mov [di], al
    inc di
    inc si
    inc cx
    jmp short .digname
.digdone:
    mov byte [di], 0
    jmp .isfunc
.nodigname:
    pop cx
    pop si
    mov byte [di], 0
    cmp byte [si], '$'                ; ...and before the row digits
    jne .norowdollar
    inc si
.norowdollar:
    mov al, [si]
    cmp al, '0'
    jb .isfunc
    cmp al, '9'
    ja .isfunc
    call pl_identcol                  ; pl_ident -> AX = 0-based column
    mov [pl_pcol], ax
    mov bx, si
    add bx, PL_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call pl_pint                      ; SI advances past the digits
    pop es
    dec ax                            ; AX = 0-based row
    mov bx, ax
    mov ax, [pl_pcol]
    cmp byte [pl_pxsheet], 0xFF
    je .samesheet
    mov cx, [pl_cursheet]              ; stage 2.0: a "SheetN!" prefix -
    push cx                            ; temporarily point pl_findcell (via
    mov cl, [pl_pxsheet]               ; pl_cursheet) at the target sheet
    xor ch, ch                         ; for this one lookup, then put it
    mov [pl_cursheet], cx              ; back - every OTHER caller of
    call pl_getcell2                   ; pl_getcell2/pl_findcell is none the
    pop cx                             ; wiser
    mov [pl_cursheet], cx
    jmp .havecell
.samesheet:
    call pl_getcell2
.havecell:
    jmp .out                          ; nothing to do: pl_getcell2 leaves the
                                      ; value in pl_acc, and leaves a ZERO
                                      ; there for a cell that does not exist -
                                      ; which is what both branches here used
                                      ; to arrange by hand
.isfunc:
    ; 81.75: an identifier that is not a call used to be looked up as a
    ; DEFINED NAME and resolved to its rectangle. There are none - the only
    ; thing that could make one was Formula > Define Name - so every
    ; identifier here is a function call or a misspelling, and pl_pfunc's
    ; own .noname already says which.
    call pl_pfunc
.out:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; pl_identcol - in: pl_ident = NUL-terminated uppercase letters (1-2 chars)
; out: AX = 0-based column index (the bijective base-26 pl_colname inverts)
pl_identcol:
    push bx
    push cx
    push si
    mov si, pl_ident
    xor ax, ax
.loop:
    mov cl, [si]
    or cl, cl
    jz .done
    sub cl, 'A'
    inc cl
    xor ch, ch
    mov bx, 26
    mul bx
    add ax, cx
    inc si
    jmp .loop
.done:
    dec ax
    pop si
    pop cx
    pop bx
    ret

; pl_pcellref - a backtracking probe: does SI start a bare cell reference?
; in: SI; out: CF=1 yes (AX=col, BX=row, SI advanced past it),
;             CF=0 no (SI UNCHANGED - the caller falls back to pl_pexpr)
; Used only to tell a range's "A1:B5" apart from a plain expression that
; merely starts with a cell reference, like "A1+5".
pl_pcellref:
    push cx
    push di
    push si                           ; the only way back out on failure
    cmp byte [si], '$'                ; stage 3.0e: '$' is PURELY TEXTUAL -
    jne .nocoldollar                  ; it changes what the rewriters do, not
    inc si                            ; what this evaluates to, so the parser
.nocoldollar:                         ; only has to skip it
    mov al, [si]
    cmp al, 'A'
    jb .fail
    cmp al, 'Z'
    jbe .ok
    cmp al, 'a'
    jb .fail
    cmp al, 'z'
    ja .fail
.ok:
    mov di, pl_ident
    xor cx, cx
.collect:
    mov al, [si]
    cmp al, 'A'
    jb .doneletters
    cmp al, 'Z'
    jbe .isletter
    cmp al, 'a'
    jb .doneletters
    cmp al, 'z'
    ja .doneletters
.isletter:
    cmp cx, 2
    jae .doneletters                  ; 3+ letters: a NAME, not a column
    and al, 0xDF
    mov [di], al
    inc di
    inc cx
    inc si
    jmp .collect
.doneletters:
    mov byte [di], 0
    or cx, cx
    jz .fail
    cmp byte [si], '$'                ; ...and again before the row digits
    jne .norowdollar
    inc si
.norowdollar:
    mov al, [si]
    cmp al, '0'
    jb .fail
    cmp al, '9'
    ja .fail
    call pl_identcol
    mov cx, ax                        ; CX = col, held across pl_pint
    mov bx, si
    add bx, PL_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call pl_pint
    pop es
    dec ax                            ; AX = 0-based row
    mov bx, ax
    mov ax, cx                        ; AX = col
    add sp, 2                         ; discard the saved SI - keep advancing
    stc
    jmp .out
.fail:
    pop si                            ; restore SI - this was not a cellref
    clc
.out:
    pop di
    pop cx
    ret

; pl_prange - one comma-separated function argument: a range, or a single
; expression (which may itself start with, but not be, a cell reference -
; "A1" alone IS the range-shorthand for a single cell; "A1+5" is not a
; range at all). Folds into pl_pacc/pl_pcnt/pl_phave per pl_pfid.
pl_prange:
    push ax
    push bx
    ; 81.75: `=SUM(Sales)` folded a DEFINED NAME's block here. There are no
    ; defined names in this build, so a range argument is a reference or a
    ; plain expression and nothing else.
    call pl_pcellref
    jnc .plainexpr
    cmp byte [si], ':'
    jne .singlecell
    inc si
    mov [pl_r1col], ax
    mov [pl_r1row], bx
    call pl_pcellref
    jnc .out                          ; malformed range; contributes nothing
    mov [pl_r2col], ax
    mov [pl_r2row], bx
    call pl_normrange
.isect:
    cmp byte [si], ' '                ; stage 4.5: Excel's INTERSECTION
    jne .fold                         ; operator is a space, and an empty
    mov ax, si                        ; intersection is the one and only
    call pl_pintersect                ; thing that produces #NULL! (81.26.3)
    jc .out                           ; empty: there is nothing to fold
    cmp ax, si
    je .fold                          ; nothing consumed - the space was not
    jmp .isect                        ; an operator after all
.fold:
    call pl_foldrange
    jmp .out
.singlecell:
    call pl_getcell2                  ; the value lands in pl_acc either way -
.havev:                               ; getcell2 puts a zero there for a cell
    call pl_ppowcont                  ; that does not exist. Tightest binding
    call pl_ptermcont                 ; first: '^', then '*', then '+', then
    call pl_pexprcont                 ; '&', then the comparison (81.22.2)
    call pl_pconcatcont
    call pl_pcmpcont
    call pl_foldvalue
    jmp .out
.plainexpr:
    call pl_pcmp
    cmp byte [pl_curtype], PL_T_BOOL  ; SUM(TRUE,1) is 2: a logical TYPED as
    jne .pefold                       ; an argument is its number, and only
    mov byte [pl_curtype], PL_T_NUM   ; one read from a cell is stepped over
.pefold:                              ; (81.51)
    call pl_foldvalue
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_pnamerange - is the argument at SI a DEFINED NAME and nothing else?
;
; in:  SI at the start of an argument
; out: CF=1 - pl_r1col/row..pl_r2col/row hold the rectangle it names and SI is
;             past it; CF=0 - not a name, SI UNCHANGED.
;
; Strict about "nothing else" for the same reason pl_pargref is (81.23): a ','
; or the ')' has to follow, so `=SUM(Sales+1)` is an expression about Sales
; and not a fold over it. A name followed by '(' is a FUNCTION CALL - that is
; the only thing separating SUM from a cell called SUM - and is declined here
; so pl_pfunc still gets it.
;
; A one-cell name resolves to a 1x1 rectangle and folds to the same single
; value the expression path already gave it, so nothing that worked before
; takes a different route to a different answer.
; -----------------------------------------------------------------------------
pl_normrange:
    push ax
    push bx
    mov ax, [pl_r1col]
    mov bx, [pl_r2col]
    cmp ax, bx
    jle .colok
    xchg ax, bx
.colok:
    mov [pl_r1col], ax
    mov [pl_r2col], bx
    mov ax, [pl_r1row]
    mov bx, [pl_r2row]
    cmp ax, bx
    jle .rowok
    xchg ax, bx
.rowok:
    mov [pl_r1row], ax
    mov [pl_r2row], bx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
pl_pintersect:
    push ax
    push bx
    push si
.spaces:
    cmp byte [si], ' '
    jne .second
    inc si
    jmp .spaces
.second:
    call pl_pcellref
    jnc .nope
    mov [pl_ix1col], ax
    mov [pl_ix1row], bx
    mov [pl_ix2col], ax
    mov [pl_ix2row], bx
    cmp byte [si], ':'
    jne .haveit
    inc si
    call pl_pcellref
    jnc .nope
    mov [pl_ix2col], ax
    mov [pl_ix2row], bx
.haveit:
    mov ax, [pl_ix1col]               ; normalise the second rectangle too -
    mov bx, [pl_ix2col]               ; `B5:A1` names the same block as
    cmp ax, bx                        ; `A1:B5` and must intersect the same
    jle .c2ok
    xchg ax, bx
.c2ok:
    mov [pl_ix1col], ax
    mov [pl_ix2col], bx
    mov ax, [pl_ix1row]
    mov bx, [pl_ix2row]
    cmp ax, bx
    jle .r2ok
    xchg ax, bx
.r2ok:
    mov [pl_ix1row], ax
    mov [pl_ix2row], bx
    mov ax, [pl_ix1col]               ; the intersection is the later start
    cmp ax, [pl_r1col]                ; and the earlier end, on each axis
    jbe .e1
    mov [pl_r1col], ax
.e1:
    mov ax, [pl_ix2col]
    cmp ax, [pl_r2col]
    jae .e2
    mov [pl_r2col], ax
.e2:
    mov ax, [pl_ix1row]
    cmp ax, [pl_r1row]
    jbe .e3
    mov [pl_r1row], ax
.e3:
    mov ax, [pl_ix2row]
    cmp ax, [pl_r2row]
    jae .e4
    mov [pl_r2row], ax
.e4:
    mov ax, [pl_r1col]
    cmp ax, [pl_r2col]
    ja .empty
    mov ax, [pl_r1row]
    cmp ax, [pl_r2row]
    ja .empty
    add sp, 2                         ; discard the saved SI - keep advancing
    pop bx
    pop ax
    clc
    ret
.empty:
    mov byte [pl_evalerr], PL_ERR_NULL
    add sp, 2
    pop bx
    pop ax
    stc
    ret
.nope:
    pop si                            ; not a range after the space: put SI
    pop bx                            ; back, and the caller folds the first
    pop ax                            ; range alone
    clc
    ret

; -----------------------------------------------------------------------------
; pl_foldrange - in: pl_r1col/row, pl_r2col/row (either corner order);
; folds every OCCUPIED cell in the rectangle via pl_foldvalue.
;
; It walks the RECORD ARRAY, not the rectangle (81.3): records are sorted by
; (packed row, col) - the stage 2.0 comment above pl_findcell - so ONE binary
; search finds the first corner and a forward scan visits exactly the records
; in the row span. Walking every coordinate was O(area x log n): the ordinary
; =SUM(A1:A16384) idiom was 16,384 searches inside the paint callback, seconds
; per repaint on the 8088 and invisible in an emulator (PERFORMANCE.md rule 6).
; The bound rides in SI and the cursor in DI because pl_getcell2 preserves
; both across the evaluation a formula cell runs; the end offset is a
; function of [pl_ncells] alone, the same for a nested fold, so pl_rrow can
; hold it.
; -----------------------------------------------------------------------------
pl_foldrange:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    call pl_normrange                  ; split out for pl_pintersect's sake
    mov ax, [pl_ncells]
    mov bx, PL_C_SZ
    mul bx
    mov [pl_rrow], ax                  ; end-of-array offset
    mov ax, [pl_cursheet]              ; the far corner, PACKED the way the
    mov cl, PL_ROW_BITS                ; records store a row (pl_findcell)
    shl ax, cl
    or ax, [pl_r2row]
    mov si, ax                         ; SI = the packed bound
    mov ax, [pl_r1col]
    mov bx, [pl_r1row]
    call pl_findcell                   ; found or not, DI = the first record
                                        ; at or after the near corner
.scan:
    cmp di, [pl_rrow]
    jae .done                          ; past the last record
    mov es, [pl_cellseg]               ; reloaded every pass: an evaluation
    mov ax, [es:di]                    ; below moves ES. AX = packed row
    cmp ax, si
    jg .done                           ; sorted (signed, as pl_findcell
    mov bx, [es:di+2]                  ; compares): past the last row is done
    cmp bx, [pl_r1col]
    jb .next
    cmp bx, [pl_r2col]
    ja .next
    and ax, PL_ROW_MASK                ; a hit: unpack the row and fold it
    xchg ax, bx                        ; AX = col, BX = row
    push word [pl_r1col]               ; A FORMULA CELL IN THE RANGE MAY FOLD A
    push word [pl_r2col]               ; RANGE OF ITS OWN, through these same
    call pl_getcell2                   ; two words: =SUM(D55:I55) over six
    pop word [pl_r2col]                ; column SUMs scanned D alone after the
    pop word [pl_r1col]                ; first one ran, and answered its total.
                                       ; Excel 2.1d's own EXPENSES.XLS found it
                                       ; (81.52). The row bound is in SI and
                                       ; pl_rrow cannot change; the lookups
                                       ; refuse the same shape instead (47)
    jnc .next                          ; tag, format and pl_acc, exactly as
                                       ; an operand's read loads them
    call pl_foldvalue                  ; pl_acc is the value; see pl_foldvalue
.next:
    add di, PL_C_SZ
    jmp .scan
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_foldvalue - fold the value in pl_acc into the running pl_pacc, per the
; function being parsed (pl_pfid).
;
; pl_pacc is EIGHT BYTES now, not a word: SUM over a column of decimals has to
; keep them. The incoming value arrives in pl_acc rather than in AX for the
; same reason, and both are packed doubles - fp A and B are scratch here and
; are reloaded on every fold, because the range walker between calls uses them
; itself.
; -----------------------------------------------------------------------------
pl_foldvalue:
    push ax
    push bx
    cmp byte [pl_curtype], PL_T_BOOL   ; A LOGICAL IN A REFERENCE is stepped
    jne .notbool                       ; over like a label - Excel's rule for
    cmp word [pl_pfid], 8              ; SUM and every numeric fold - except
    je .counted                        ; by AND and OR, which are about
    cmp word [pl_pfid], 9              ; nothing else. One typed as an argument
    je .counted                        ; counts: pl_prange makes it a number
    jmp short .astext                  ; before it gets here (81.51)
.notbool:
    cmp byte [pl_curtype], PL_T_TEXT   ; stage 4.5: a LABEL is not a number and
    jne .counted                       ; every numeric fold steps over it -
.astext:
    cmp word [pl_pfid], 11             ; SUM, MIN, MAX and PRODUCT because a
    jne .out                           ; label has no value, and AVERAGE for a
    inc word [pl_pcnt]                 ; second reason on top of that: it
    jmp .out                           ; divides by pl_pcnt, so counting a
                                       ; label would drag the mean toward zero
                                       ; without ever adding to the total.
                                       ; COUNTA (11) is the one that WANTS it,
                                       ; and this is the first release in
                                       ; which COUNT and COUNTA can disagree
                                       ; about anything at all.
.counted:
    inc word [pl_pcnt]
    mov bx, [pl_pfid]
    cmp bx, 0
    je .sum
    cmp bx, 1
    je .sum                           ; AVERAGE sums here; pl_funcfinish
                                       ; divides once the count is final
    cmp bx, 2
    je .min
    cmp bx, 3
    je .max
    cmp bx, 8
    je .and
    cmp bx, 9
    je .or
    cmp bx, 10
    je .product
    cmp bx, 77
    jae .stat
    jmp .out                          ; COUNT (4), COUNTA (11) or unknown:
                                       ; pcnt alone is enough
.stat:
    call pl_pacc_to_a                 ; the running sum, as SUM does...
    call pl_acc_load_b
    call fx_add
    call pl_pacc_from_a
    call pl_acc_load_a                ; ...and the sum of SQUARES beside it
    call pl_acc_load_b
    call fx_mul                       ; A = x * x
    call fx_a_to_b                    ; ...to B, so the running total can
    push si                           ; come into A
    mov si, pl_pacc2
    call fx_unpack_a
    pop si
    call fx_add
    push di
    mov di, pl_pacc2
    call fx_pack_a
    pop di
    jmp .out
.sum:
    call pl_pacc_to_a
    call pl_acc_load_b
    call fx_add
    call pl_pacc_from_a
    jmp .out
.product:
    call pl_pacc_to_a
    call pl_acc_load_b
    call fx_mul
    call pl_pacc_from_a
    jmp .out
.min:
    cmp word [pl_phave], 0
    jnz .mincmp
    call pl_acc_to_pacc
    mov word [pl_phave], 1
    jmp .out
.mincmp:
    call pl_acc_load_a                ; is the new value below the running one?
    call pl_pacc_to_b
    call fx_cmpab
    jge .out
    call pl_acc_to_pacc
    jmp .out
.max:
    cmp word [pl_phave], 0
    jnz .maxcmp
    call pl_acc_to_pacc
    mov word [pl_phave], 1
    jmp .out
.maxcmp:
    call pl_acc_load_a
    call pl_pacc_to_b
    call fx_cmpab
    jle .out
    call pl_acc_to_pacc
    jmp .out
.and:
    call pl_acc_iszero
    jnc .out                          ; nonzero folds in as true: no-op
    xor ax, ax                        ; any false value forces AND to false
    call pl_int_to_pacc
    jmp .out
.or:
    call pl_acc_iszero
    jc .out                           ; zero folds in as false: no-op
    mov ax, 1                         ; any true value forces OR to true
    call pl_int_to_pacc
.out:
    pop bx
    pop ax
    ret

; --- the small movers the fold above is written in terms of ------------------
pl_pacc_to_a:
    push si
    mov si, pl_pacc
    call fx_unpack_a
    pop si
    ret

pl_pacc_to_b:
    push si
    mov si, pl_pacc
    call fx_unpack_b
    pop si
    ret

pl_pacc_from_a:
    push di
    mov di, pl_pacc
    call fx_pack_a
    pop di
    ret

pl_acc_to_pacc:
    push ax
    push si
    push di
    mov si, pl_acc
    mov di, pl_pacc
    mov ax, [si]
    mov [di], ax
    mov ax, [si+2]
    mov [di+2], ax
    mov ax, [si+4]
    mov [di+4], ax
    mov ax, [si+6]
    mov [di+6], ax
    pop di
    pop si
    pop ax
    ret

; pl_int_to_pacc - AX (signed) -> pl_pacc
pl_int_to_pacc:
    call fx_i2a
    call pl_pacc_from_a
    ret

; pl_esatof - parse a decimal number from ES:SI into pl_acc, advancing SI past
; it. fx_atof reads DS:SI and the file staging buffer is in ES, so the token is
; copied across first - up to a ';' or the record's end. Without this, a SYLK
; K field would still be read by the integer parser and "3.5" would come back
; as 3, which is what the round trip actually did before this existed.
section PL_MODSEC                      ; 82.16.9
pl_esatof:
    push ax
    push cx
    push di
    mov di, pl_numbuf
    mov cx, 24
.copy:
    jcxz .done
    cmp si, bx
    jae .done
    mov al, [es:si]
    cmp al, ';'
    je .done
    cmp al, 13
    je .done
    cmp al, 10
    je .done
    mov [di], al
    inc di
    inc si
    dec cx
    jmp .copy
.done:
    mov byte [di], 0
    push si
    mov si, pl_numbuf
    SHOUT fx_atof
    pop si
    SHOUT pl_acc_store
    pop di
    pop cx
    pop ax
    ret

; The same three, for a record addressed through SI - the file writers, the
; chart scan and sort all walk the array with SI rather than DI.
section .text
pl_cellval_to_acc_si:
    push ax
    push cx
    push si
    push di
    mov di, pl_acc
    mov cx, 2                          ; 81.75: TWO words, not four
.s2a:
    mov ax, [es:si+PL_C_VAL]
    mov [di], ax
    add si, 2
    add di, 2
    dec cx
    jnz .s2a
    pop di
    pop si
    pop cx
    pop ax
    ret



; pl_cellnum - the value of the record at ES:DI, formatted into pl_numbuf as
; a decimal. What "read the word and pl_itoa it" used to do, except that the
; value is eight bytes now and its low word on its own is meaningless.
pl_cellnum:
    cmp byte [es:di+PL_C_TYPE], PL_T_ERR   ; ...and an ERROR its name (81.61):
    jne .noterr                           ; this wrote the zero underneath, so
    push ax                               ; a copied #N/A pasted as 0
    mov al, [pl_curaux]
    push ax
    mov al, [es:di+PL_C_AUX]
    mov [pl_curaux], al
    call pl_errname
    pop ax
    mov [pl_curaux], al
    pop ax
    ret
.noterr:
    cmp byte [es:di+PL_C_TYPE], PL_T_BOOL  ; a LOGICAL is its name here too -
    jne .num                              ; the formula bar, Copy and Paste
    push ax                               ; all read it through this (81.51)
    mov ax, [es:di+PL_C_VAL]
    call pl_boolname
    pop ax
    ret
.num:
    push ax
    push di
    call pl_cellval_to_acc
    call pl_acc_load_a
    mov di, pl_numbuf
    mov ax, 10
    call fx_ftoa
    pop di
    pop ax
    ret

; pl_cellval_to_acc / pl_acc_to_cellval - the eight value bytes of the record
; at ES:DI. DI is left where it started, which matters: every caller is still
; using it as the record's offset.
pl_cellval_to_acc:
    push ax
    push cx
    push si
    push di
    mov si, pl_acc
    mov cx, 4
.c2a:
    mov ax, [es:di+PL_C_VAL]
    mov [si], ax
    add di, 2
    add si, 2
    dec cx
    jnz .c2a
    pop di
    pop si
    pop cx
    pop ax
    ret

pl_acc_to_cellval:
    push ax
    push cx
    push si
    push di
    mov si, pl_acc
    mov cx, 2                          ; 81.75: TWO words, not four
.a2c:
    mov ax, [si]
    mov [es:di+PL_C_VAL], ax
    add di, 2
    add si, 2
    dec cx
    jnz .a2c
    pop di
    pop si
    pop cx
    pop ax
    ret

; pl_acc_neg - pl_acc = -pl_acc.  pl_acc_abs - pl_acc = |pl_acc|.
;
; 81.75: BOTH OF THESE USED TO BE ONE INSTRUCTION on the IEEE sign BIT -
; `xor byte [pl_acc+7], 0x80` and `and byte [pl_acc+7], 0x7F`. A packed
; double carries its sign in a bit, so negate and absolute-value were free
; and exact. Two's complement does not: clearing the top bit of a negative
; count gives a different number, not its magnitude. These are the two
; places that has to be spelled out, and the +7 is why a sweep that looked
; for +4 and +6 did not find them - `=-5` came out as 5.
; Every register preserved.
pl_acc_neg:
    push ax
    push dx
    mov ax, [pl_acc]
    mov dx, [pl_acc+2]
    not ax
    not dx
    add ax, 1
    adc dx, 0
    mov [pl_acc], ax
    mov [pl_acc+2], dx
    pop dx
    pop ax
    ret

pl_acc_abs:
    test byte [pl_acc+3], 0x80
    jz .out
    call pl_acc_neg
.out:
    ret

; pl_acc_iszero - CF=1 if pl_acc is zero. 81.75: a fixed-point zero is four
; zero bytes and there is no negative zero to mask off.
pl_acc_iszero:
    push ax
    push bx
    mov ax, [pl_acc]
    or ax, [pl_acc+2]
    pop bx
    pop ax
    jnz .no
    stc
    ret
.no:
    clc
    ret

; pl_funcfinish - the accumulated pl_pacc/pl_pcnt -> the function's result
pl_funcfinish:
    push bx
    mov bx, [pl_pfid]
    cmp bx, 1
    je .average
    cmp bx, 4
    je .count
    cmp bx, 11
    je .count                         ; COUNTA answers from the COUNT of things
                                       ; folded, not from the accumulator - it
                                       ; is identical to COUNT while every
                                       ; value in this model is a number, and
                                       ; separating them is Stage 4.0's job,
                                       ; when text and blanks become tellable
                                       ; apart. Without this it returned
                                       ; pl_pacc, which for a non-summing fold
                                       ; is always 0.
    cmp bx, 77
    jae .stat
    call pl_pacc_to_a                 ; SUM/MIN/MAX/PRODUCT (and unknown):
    call pl_acc_store                 ; whatever was folded, zero if nothing
    jmp .fout
; --- VAR / VARP / STDEV / STDEVP (SPEC.md 81.34) -----------------------------
; variance = (sum of squares - sum*sum/n) / d, where d is n for the POPULATION
; forms and n-1 for the SAMPLE ones; the standard deviations are its square
; root. ONE PASS, which is what the fold machinery gives - Excel 2.1's own
; arithmetic, and its accuracy: subtracting two large nearly-equal numbers
; loses digits when the mean is far from zero. A spreadsheet of this era did
; the same, and the two-pass form would need the range walked twice, which
; this parser cannot do - it folds as it PARSES.
.stat:
    mov cx, [pl_pcnt]
    cmp bx, 78                        ; VARP and STDEVP divide by n...
    je .popn
    cmp bx, 80
    je .popn
    dec cx                            ; ...VAR and STDEV by n-1, and a single
.popn:                                ; value therefore has no sample variance
    or cx, cx
    jg .statok
    mov byte [pl_evalerr], PL_ERR_DIV0  ; #DIV/0! is Excel's own answer to
    xor ax, ax                        ; VAR of one number
    call pl_acc_int
    jmp .fout
.statok:
    push cx                           ; CX = the divisor, banked across the
    call pl_pacc_to_a                 ; arithmetic below
    call pl_pacc_to_b                 ; A = B = the sum
    call fx_mul                       ; A = sum * sum
    mov ax, [pl_pcnt]
    call fx_i2b
    call fx_div                       ; A = sum*sum/n
    call fx_a_to_b                    ; ...to B
    push si
    mov si, pl_pacc2                  ; A = the sum of squares
    call fx_unpack_a
    pop si
    call fx_sub                       ; A = sumsq - sum*sum/n
    pop cx
    mov ax, cx
    call fx_i2b
    call fx_div                       ; A = that / d
    cmp bx, 79                        ; STDEV and STDEVP are its square root
    jb .statdone
    call fx_sqrt
.statdone:
    call pl_acc_store                 ; pl_stbusy is not cleared here: pl_pfunc
    jmp .fout                         ; banks and restores it, so every exit
                                       ; path is covered and not just this one
.average:
    cmp word [pl_pcnt], 0
    jne .avgok
    xor ax, ax
    call pl_acc_int
    jmp .fout
.avgok:
    call pl_pacc_to_a                 ; A REAL MEAN NOW, not a truncated one:
    mov ax, [pl_pcnt]                 ; AVERAGE(1,2) is 1.5 where the integer
    call fx_i2b                       ; evaluator gave 1
    call fx_div
    call pl_acc_store
    jmp .fout
.count:
    mov ax, [pl_pcnt]
    call pl_acc_int
    jmp .fout
.fout:
.out:
    pop bx
    ret

; pl_pfunc - in: SI right after a function NAME (pl_ident holds it),
; expecting '(' next; out: AX=value, SI advanced past the closing ')'.
; Saves/restores pl_pfid/pl_pacc/pl_pcnt/pl_phave around itself, so a
; function call nested inside another's argument list (SUM(A1,MAX(B1:B9)))
; cannot corrupt the outer accumulator.
pl_pfunc:
    push bx
    push cx
    push dx
    push word [pl_pfid]
    push word [pl_pacc+2]             ; its low word handed the outer fold the
    push word [pl_pacc]               ; inner call's accumulator back
    push word [pl_pcnt]
    push word [pl_phave]
    push word [pl_stbusy]             ; BANKED, not cleared on the way out: an
                                       ; error path that never reached
                                       ; pl_funcfinish would otherwise leave a
                                       ; variance fold marked live for the
                                       ; rest of the session, and every VAR
                                       ; after it would refuse (81.34.1)
    xor dx, dx                        ; DX = result; 0 covers every bad exit
    mov word [pl_pfid], 0xFFFF        ; THIS call's id, for .done's logical
                                      ; test (81.51); banked above, so a nested
                                      ; call's cannot outlive it
    call pl_pnest_enter               ; a nested call is a recursion point too
    jc .popout                        ; (81.3); too deep answers 0 + #VALUE!
    cmp byte [si], '('
    je .paren
    call pl_funcid                    ; =TRUE WITHOUT BRACKETS is Excel's
    cmp al, 20                        ; logical constant, and was #NAME? here
    je .bare                          ; (81.51). pl_ident still holds the word
    cmp al, 21
    jne .noparen
.bare:
    xor ah, ah
    mov [pl_pfid], ax
    neg al
    add al, 21                        ; TRUE (20) is 1, FALSE (21) is 0
    mov dx, ax
    call pl_acc_int
    jmp .typed
.paren:                               ; a bare word that resolved to no defined
    inc si                            ; name is #NAME?, exactly as in Excel -
    call pl_funcid                    ; pl_pident only routes one here once
    xor ah, ah                        ; pl_name_lookup has already declined it
    mov [pl_pfid], ax
    cmp ax, 0xFF                      ; ...and so is a CALL to a function this
    je .noname                        ; app does not have. Reading either as a
    cmp ax, 5
    je .doif
    cmp ax, 24                        ; CHOOSE answers a VALUE, not an integer
    je .dochoose                      ; (81.49) - IF's route, not pl_pspecial's
    cmp ax, 6
    je .donot
    cmp ax, 7
    je .doabs
    cmp ax, 109                        ; RAND() is nullary like NOW()
    je .dorand
    cmp ax, 106                        ; NOW() is nullary and reads the BIOS
    je .donow                          ; clock - nothing else here does either
    cmp ax, PL_FID_MDETERM              ; 143+ are the ARRAY/MATRIX functions
    jae .domatrix                      ; (81.67) - ABOVE PL_FID_CELL's own id,
                                        ; so this test runs first
    cmp ax, PL_FID_CELL                ; 142 is CELL (81.66)
    je .docell
    cmp ax, PL_FID_DATABASE            ; 131+ are the DATABASE functions
    jae .dodatabase                    ; (81.65) - ABOVE PL_FID_MACRO's own
                                        ; range, so this test runs FIRST or
                                        ; the macro check below would catch
                                        ; them too
    cmp ax, PL_FID_MACRO               ; 111+ are the MACRO functions (81.63),
    jae .domacro                       ; which act only for the step engine
    cmp ax, 93                         ; 93+ are the FINANCIAL functions, on
    jae .dofin                         ; the same layer one level up
    cmp ax, 81                         ; 81+ are the LOGARITHMS and their
    jae .dotrans                       ; friends, on the transcendental layer
    cmp ax, 25                         ; 81.75: 25..80 are INFORMATION, TEXT,
    jae .noname                        ; DATE, LOOKUP and the VARIANCE folds,
                                       ; every one of them cut
    cmp ax, 12                         ; 12+ are stage 3.0d's special forms:
    jae .dospecial                     ; fixed arity, parsed by pl_pspecial,
                                       ; not folded over ranges
.fold:
    mov [pl_pfid], ax
    push ax
    xor ax, ax
    cmp word [pl_pfid], 8              ; AND folds by ANDing in each value, so
    je .accone                         ; it must start true (1), not the false
    cmp word [pl_pfid], 10             ; (0) every other fold starts at.
    jne .accset                        ; PRODUCT starts at 1 for the same
.accone:                               ; reason - a running product seeded with
    mov ax, 1                          ; 0 can only ever be 0
.accset:
    call pl_int_to_pacc
    pop ax
    mov word [pl_pcnt], 0
    mov word [pl_phave], 0
    mov word [pl_pacc2], 0             ; the sum of squares starts at zero for
    mov word [pl_pacc2+2], 0           ; every fold; only the variance ones
.args:
    call pl_prange
    cmp byte [si], ','
    jne .argsdone
    inc si
    jmp .args
.argsdone:
    cmp byte [si], ')'
    jne .badtail
    inc si
    call pl_funcfinish
    mov dx, ax
    jmp .typed                        ; a fold's answer is a NUMBER: this went
                                      ; to .done, which left the type of the
                                      ; LAST CELL FOLDED standing, so a SUM
                                      ; whose range ended on a label stored
                                      ; the label's text as its result (81.51)
.badtail:
    mov byte [pl_evalerr], PL_ERR_VALUE ; an argument tail this grammar cannot
    jmp .done                          ; parse (=SUM(A1:A9^2)) must ERR, not
                                       ; answer with a partial fold (81.20)
.doif:
    call pl_pif
    mov dx, ax
    jmp .done
.dochoose:
    call pl_pchoose
    mov dx, ax
    jmp .done                         ; NOT .typed: a chosen TEXT stays text
.donot:
    call pl_pnot
    mov dx, ax
    jmp .done
.doabs:
    call pl_pabs
    mov dx, ax
    jmp .done
.dorand:
    call pl_prand
    jmp .nullary
.donow:
    call pl_pnow
.nullary:                              ; A NULLARY CALL PARSES NO ARGUMENTS, so
    mov dx, ax                         ; nothing has stepped over its ')': .fold
    cmp byte [si], ')'                 ; does that at .argsdone and these two
    jne .badtail                       ; never reach it. This used to jump
    inc si                             ; straight to .typed under a comment
    jmp .typed                         ; saying "the ')' is skipped by the
                                       ; common tail" - .typed touches SI at
                                       ; all. SI was left ON the ')', the
                                       ; expression parser read that as the end
                                       ; of the formula, and =RAND()*1000
                                       ; SILENTLY ANSWERED RAND(). No error,
                                       ; a plausible number, and the same for
                                       ; =NOW()+1 ever since NOW landed
.dofin:                                ; 81.75: #NAME?, and the arguments
    jmp .noname                        ; stepped over
.dodatabase:                           ; 81.75, .docell's reason below
    jmp .noname
.docell:                               ; 81.75: THE NAMES STAY IN THE TABLE and
.domatrix:                             ; the ids stay where they are - dropping
    jmp .noname                        ; table entries would renumber every
                                       ; family after them. `=MDETERM(A1:B2)`
                                       ; answers #NAME? here, which is the
                                       ; same thing `.noname` already says
                                       ; about a function that was never
                                       ; spelled right, and it steps over the
                                       ; arguments rather than parsing on
.domacro:                              ; 81.75, .docell's reason below
    jmp .noname
.dotrans:
    jmp .noname                        ; 81.75
.dospecial:
    call pl_pspecial
    mov dx, ax
    jmp .typed
.noname:                              ; zero is how a typo silently becomes an
    call pl_skipargs                  ; answer, and the whole point of an error
.noparen:                             ; value is that it cannot be mistaken for
    mov byte [pl_evalerr], PL_ERR_NAME  ; one. Only the CALL form has arguments
.typed:                               ; to step over - `=FOO+1` has none, and
                                       ; skipping there would eat the `+1`
    mov byte [pl_curtype], PL_T_NUM   ; a call's RESULT is a number whatever it
                                       ; folded over: without this the TEXT tag
                                       ; left by the last cell a range touched
                                       ; would make `=SUM(A1:A9)*2` a #VALUE!
.done:
    cmp byte [pl_curtype], PL_T_ERR   ; A FUNCTION THAT ANSWERS TRUE OR FALSE
    je .notlog                        ; says so in the type (81.51), whatever
    call pl_fnlogical                 ; its own routine left there - NOT
    jnc .notlog                       ; sets none at all
    mov byte [pl_curtype], PL_T_BOOL
.notlog:
    call pl_pnest_leave
.popout:
    pop word [pl_stbusy]
    pop word [pl_phave]
    pop word [pl_pcnt]
    pop word [pl_pacc]
    pop word [pl_pacc+2]
    pop word [pl_pfid]
    mov ax, dx
    pop dx
    pop cx
    pop bx
    ret

; =============================================================================
; pl_pspecial (stage 3.0d) - the fixed-arity functions, ids 12 and up. These
; do not fold over a range the way SUM does; each parses exactly the arguments
; it takes and computes a value.
;
; THIS BLOCK USED TO LIST ISBLANK, ISNUMBER, ISNA AND NA AS "DELIBERATELY
; ABSENT". ALL FOUR SHIP - ids 25, 26, 31 and 33, dispatched by pl_pinfo a
; thousand lines down, which reads its argument through pl_pargclass and so
; has the reference the comment said had already been folded away.
;
; The reasons given were true when they were written and expired twice over:
; the first version said "all of these need the value model Stage 4.0 brings",
; which 4.0 delivered; the rewrite said the argument is folded before the
; function sees it, which pl_pargclass fixed. Neither edit removed the entry.
; The cost is not a wrong result - it is that a reader looking for somewhere
; to put a new INFORMATION function reads this and concludes the category is
; blocked, which is exactly what happened on the way to 81.44.
;
; A COMMENT THAT NAMES WHAT IS MISSING HAS TO BE DELETED WHEN THE THING
; ARRIVES, and nothing enforces that. What is genuinely absent now is listed
; in SPEC.md 81, which is at least read as a whole often enough to notice.
;
; in: AX = the id, SI just past '('. out: AX = the value, SI past ')'.
; =============================================================================
; pl_parg - one argument, as an integer. The special forms below are integer
; functions by nature; a fractional MOD or FACT is not a thing they mean.
; Truncation is the same rule TRUNC itself uses, so INT(3.7) is 3.
pl_parg:
    call pl_pcmp
    call pl_acc_toint
    ret

pl_pspecial:
    push bx
    push cx
    push dx
    push di
    mov di, ax                        ; DI holds the id: every pl_pcmp below
                                      ; clobbers AX/BX/CX/DX
    cmp di, 13                        ; the four that are REAL functions of a
    je .dfloor                        ; real number now that cells hold one -
    cmp di, 14                        ; everything else here is a function of
    je .dtrunc                        ; whole numbers by nature and stays
    cmp di, 17                        ; integer (see .close)
    je .dsqrt
    cmp di, 19
    je .dround
    cmp di, 18
    je .dpower                        ; POWER is a REAL power now (81.37.7)
    cmp di, 20
    jb .arg1                          ; 12..18 take one or two arguments
    cmp di, 23
    jbe .noargs                       ; 20..23 take none
    jmp .zeroout                      ; 24 CHOOSE is pl_pchoose's (81.49) and
                                      ; the dispatcher never sends it here

; ---- POWER(x, y), on doubles ------------------------------------------------
; It parsed both arguments as 16-BIT INTEGERS and multiplied with `imul` - a
; stage 3.0d routine that nothing upgraded when the value model became a
; double, so POWER(1.12, 6) truncated its base to 1 and answered 1. It went
; unnoticed because the only thing that exercised it was `^` on whole numbers,
; which agreed; MIRR asking for (1.12)^6 is what finally showed it.
.dpower:
    call pl_pcmp
    call pl_acc_load_a
    cmp byte [si], ','
    jne .powbad
    inc si
    push si
    mov si, pl_acc
    mov bx, pl_tr0
    call pl_trcopy                    ; the base, across the second parse
    pop si
    call pl_pcmp
    call pl_acc_load_b
    push si
    mov si, pl_tr0
    call fx_unpack_a
    pop si
    call fx_pow
    jnc .dstore
    mov byte [pl_evalerr], PL_ERR_NUM
    call fx_azero
    jmp .dstore
.powbad:
    mov byte [pl_evalerr], PL_ERR_VALUE
    call fx_azero
    jmp .dstore

; ---- INT / TRUNC / SQRT / ROUND, on doubles ---------------------------------
; INT FLOORS and TRUNC cuts toward zero, which differ for negatives: Excel's
; INT(-3.7) is -4 and TRUNC(-3.7) is -3. While every value was an integer the
; two were indistinguishable and both were the identity; they are not any more.
.dfloor:
    call pl_pcmp
    call pl_acc_load_a
    call fx_floor
    jmp .dstore
.dtrunc:
    call pl_pcmp
    call pl_acc_load_a
    call fx_trunc
    jmp .dstore
.dsqrt:
    call pl_pcmp
    test byte [pl_acc+3], 0x80        ; the sign bit of the packed double: a
    jz .sqrtok                        ; negative has no real square root, and
    mov byte [pl_evalerr], PL_ERR_NUM ; Excel says #NUM! rather than 0
.sqrtok:
    call pl_acc_load_a
    call fx_sqrt                      ; a REAL root: SQRT(2) is 1.414213562,
    jmp .dstore                       ; where the integer version gave 1
.dround:
    call pl_pcmp                      ; the value, banked across the second
    call pl_vpush                     ; argument's parse
    xor cx, cx
    cmp byte [si], ','
    jne .dround1                      ; ROUND(x) with no count means 0 places
    inc si
    call pl_parg                      ; the digit count IS a whole number
    mov cx, ax
.dround1:
    call pl_binop_pre                 ; A = the value again
    call fx_round
.dstore:
    call pl_acc_store
    cmp byte [si], ')'
    jne .dout
    inc si
.dout:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; ---- TRUE() FALSE() ROW() COLUMN() ------------------------------------------
.noargs:
    xor ax, ax
    cmp di, 20                        ; TRUE
    jne .nf
    mov ax, 1
    jmp .close
.nf:
    cmp di, 21                        ; FALSE - AX is already 0
    je .close
    mov ax, [pl_evrow]                ; ROW / COLUMN answer for the cell being
    cmp di, 22                        ; EVALUATED, not the one selected - a
    je .ctx1                          ; formula's own position is what Excel
    mov ax, [pl_evcol]                ; means by these
.ctx1:
    inc ax                            ; 1-based, as displayed
    jmp .close

; ---- the one- and two-argument forms ----------------------------------------
.arg1:
    call pl_parg                      ; every id from here takes a first value
    mov bx, ax                        ; BX = first argument
    cmp di, 12
    je .two
    cmp di, 18
    je .two
    cmp di, 19
    je .two
    ; --- single argument: INT TRUNC SIGN FACT SQRT ---
    mov ax, bx
    cmp di, 13                        ; INT - truncation toward zero on a whole
    je .close                         ; number is the identity. Present for
    cmp di, 14                        ; formula compatibility, not effect; it
    je .close                         ; becomes real work in Stage 4.0. TRUNC
                                      ; likewise.
    cmp di, 15
    je .sign
    cmp di, 16
    je .fact
    call pl_isqrt                     ; 17 SQRT
    jmp .close
.sign:
    or ax, ax
    jz .close
    jns .signpos
    mov ax, -1
    jmp .close
.signpos:
    mov ax, 1
    jmp .close
.fact:
    or ax, ax
    js .factnum                       ; negative has no factorial here
    cmp ax, 7
    ja .factnum                       ; 8! = 40320 does not fit a signed word,
    mov cx, ax                        ; so refuse rather than hand back a
    mov ax, 1                         ; wrapped number that looks like an answer
    or cx, cx
    jz .close                         ; 0! = 1
.factloop:
    imul cx
    dec cx
    jnz .factloop
    jmp .close
.factnum:                             ; out of FACT's domain, or out of the
    mov byte [pl_evalerr], PL_ERR_NUM ; range a word can hold: #NUM! either
    jmp .zeroout                      ; way, which is what Excel reports

.two:
    cmp byte [si], ','
    jne .zeroout
    inc si
    push bx                           ; first argument, across the second parse
    call pl_parg
    mov cx, ax                        ; CX = second argument
    pop bx
    cmp di, 12
    je .mod
    cmp di, 18
    je .power
    ; --- 19 ROUND(x, digits) ---
    mov ax, bx
    or cx, cx
    jns .close                        ; digits >= 0 leaves a whole number
    neg cx                            ; alone; only rounding to tens and up
    cmp cx, 4                         ; can do anything here
    ja .zeroout                       ; 10^5 exceeds the value range entirely
    mov bx, 1
.p10:
    or cx, cx
    jz .havep10
    push ax
    mov ax, bx
    mov dx, 10
    imul dx
    mov bx, ax
    pop ax
    dec cx
    jmp .p10
.havep10:                             ; BX = the power of ten
    cwd
    idiv bx                           ; AX = quotient, DX = remainder
    push ax
    mov ax, dx
    or ax, ax                         ; |remainder| * 2 vs the divisor decides
    jns .roundabs                     ; the direction; away from zero on a tie,
    neg ax                            ; which is Excel's own rule
.roundabs:
    shl ax, 1
    cmp ax, bx
    pop ax
    jb .scaleback
    or dx, dx                         ; step away from zero, following the
    js .rounddown                     ; remainder's own sign
    inc ax
    jmp .scaleback
.rounddown:
    dec ax
.scaleback:
    imul bx
    jmp .close
.mod:
    mov ax, bx
    or cx, cx
    jz .zeroout                       ; MOD by zero -> 0, this evaluator's
    cwd                               ; standing divide-by-zero policy
    idiv cx
    mov ax, dx                        ; IDIV's remainder takes the DIVIDEND's
    or ax, ax                         ; sign; Excel's MOD takes the DIVISOR's,
    jz .close                         ; so a mismatch needs one correction
    mov bx, ax
    xor bx, cx
    jns .close                        ; signs already agree
    add ax, cx
    jmp .close
.power:
    mov ax, 1
    or cx, cx
    js .zeroout                       ; a negative exponent is a fraction
    jz .close                         ; anything^0 = 1, including 0^0 here
.powloop:
    imul bx
    dec cx
    jnz .powloop
    jmp .close

.zeroout:
    xor ax, ax
.close:
    call pl_acc_int                   ; these thirteen are integer functions by
                                      ; nature - MOD, FACT, ROW, CHOOSE - so
                                      ; they take integers and give one back,
                                      ; converting only at this boundary
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; pl_isqrt - in: AX = n; out: AX = floor(sqrt(n)), 0 for n < 0.
; Successive odd numbers: 1+3+5+... = k^2, so subtracting them until AX runs
; out counts the root. At most 181 iterations for a signed word, and it needs
; no division at all.
pl_isqrt:
    push bx
    push cx
    or ax, ax
    js .zero
    xor cx, cx
    mov bx, 1
.loop:
    cmp ax, bx
    jb .done
    sub ax, bx
    add bx, 2
    inc cx
    jmp .loop
.zero:
    xor cx, cx
.done:
    mov ax, cx
    pop cx
    pop bx
    ret

; =============================================================================
; REFERENCE-TYPED ARGUMENTS (stage 4.5)
;
; Every argument in this evaluator has always been FOLDED TO A VALUE before
; the function saw it, so by the time ISBLANK was called there was no
; reference left to ask about: an empty cell and a cell holding 0 both arrived
; as 0, and a label arrived as the zero underneath it. That is why the comment
; above pl_pspecial listed ISBLANK, ISNUMBER and ISNA as deliberately absent -
; a version of any of them that returned a plausible constant would have been
; worse than its absence. These two routines are what ends that (81.23).
;
; pl_pargref - is the argument at SI a reference AND NOTHING ELSE? It is
; deliberately strict about "nothing else": ISNUMBER(A1+1) is a question about
; the sum, not about A1, so a reference only counts when the ',' or the ')'
; follows it immediately.
;
; in:  SI at the start of an argument
; out: CF=1 - pl_arg1col/pl_arg1row/pl_arg2col/pl_arg2row hold it (a single
;             cell puts the same cell in both corners), pl_refarea = 1 for an
;             A1:B9 form, and SI is past it
;
; THESE ARE NOT pl_r1col/pl_r2col, AND THE DISTINCTION IS NOT COSMETIC. Those
; four are pl_foldrange's loop bounds, read on EVERY iteration of its walk -
; so a cell inside the range that itself calls an information function used to
; overwrite the bounds mid-walk. `=SUM(A5:A9)` over a column of ISBLANK()
; formulas answered 1: A5's own argument reset the corners to A3, and the
; second iteration compared row 4 against row 2 and stopped. The right answer
; on the first cell and then nothing, with no error anywhere.
;
; The caller must still CONSUME these before evaluating anything, because a
; nested reference argument overwrites them in turn. pl_pargclass reads them
; into AX/BX on the line before its pl_getcell2 call for exactly that reason.
;      CF=0 - not a reference; SI is UNCHANGED, exactly as pl_pcellref leaves
;             it, and the caller parses an ordinary expression instead
; =============================================================================
pl_pargref:
    push ax
    push bx
    push si                           ; the only way back out on failure
    mov byte [pl_refarea], 0
    call pl_pcellref
    jnc .fail
    mov [pl_arg1col], ax
    mov [pl_arg1row], bx
    mov [pl_arg2col], ax
    mov [pl_arg2row], bx
    cmp byte [si], ':'
    jne .whole
    inc si
    call pl_pcellref
    jnc .fail
    mov [pl_arg2col], ax
    mov [pl_arg2row], bx
    mov byte [pl_refarea], 1
.whole:
    mov al, [si]
    cmp al, ','
    je .ok
    cmp al, ')'
    jne .fail
.ok:
    add sp, 2                         ; discard the saved SI - keep advancing
    pop bx
    pop ax
    stc
    ret
.fail:
    pop si
    pop bx
    pop ax
    clc
    ret

section PL_MODSEC                      ; 81.62: pl_pargclass, ISxxx's classifier
; =============================================================================
; pl_pargclass - one argument, CLASSIFIED rather than folded.
;
; out: pl_argtype  = the PL_T_* the argument IS. PL_T_BLANK for a cell that
;                    does not exist, which is the distinction this whole
;                    routine exists to make
;      pl_argaux   = its error code, 0 when it is not an error
;      pl_argisref = 1 when the argument was a bare reference
;      pl_acc      = its value, for the callers that want the number too
;      SI past the argument
;
; THE ARGUMENT'S ERROR IS THIS FUNCTION'S ANSWER, NOT THE SHEET'S. pl_evalerr
; is banked across the argument and put back afterwards, so ISERROR(1/0) is
; TRUE rather than being a #DIV/0! itself - trapping the error is the entire
; point of asking. Every other caller in this file WANTS an argument's error
; to spread (that is what puts one #DIV/0! at the bottom of a column), which
; is why the banking lives here and not in pl_getcell2.
; =============================================================================

; =============================================================================
; THE FINANCIAL FAMILY IS CHART.OVL'S THIRD TENANT (SPEC.md 82.16.10): from
; here to pl_trcopy it is module code, bracketed where it stands the way the
; file formats were (82.16.9) - and since 81.62 pl_pargclass above and
; pl_ptrans below are in the same block. Every call out is SHOUT; the one way in is the
; resident stub pl_pfin, beside the other three. The three constants below
; stay in .text, because what reads them is resident fx_* code through DS.
; =============================================================================
section PL_MODSEC

section .text                       ; ...DATA, and the resident fx_* routines
                                    ; read it through DS (68.10 rule 2)
; 81.75: pl_c_r10 / pl_c_r01 / pl_c_eps and the five routines that stood here
; - pl_fntyv, pl_fnsetty, pl_fnfac, pl_pfargs - were the FINANCIAL family's
; shared half: the annuity factor, the type flag and the argument parser. The
; family went in Tier 1 and these stayed behind with no caller at all.

pl_trcopy:
    push ax
    push bx
    push cx
    push si
    mov cx, 4
.c:
    mov ax, [si]
    mov [bx], ax
    add si, 2
    add bx, 2
    loop .c
    pop si
    pop cx
    pop bx
    pop ax
    ret


; =============================================================================
; pl_pinfo - the INFORMATION functions, ids 25 and up. Every one of these is a
; question about what an argument IS rather than what it is worth, so each is
; one pl_pargclass call and a comparison.
;
; in: AX = the id, SI just past '('. out: AX = the value, SI past ')'.
; =============================================================================
; pl_lkstrcmp / pl_lkup - case-insensitive string compare, AX = -1/0/1.
; 81.75: these came out of the LOOKUP family with the rest of it and had to go
; straight back: the general comparison operator uses them whenever both sides
; of a `<` or `=` are text, which has nothing to do with lookups.
pl_lkstrcmp:
    push bx
    push cx
    push si
    push di
.c:
    mov al, [si]
    mov bl, [di]
    call pl_lkup
    xchg al, bl
    call pl_lkup
    xchg al, bl
    cmp al, bl
    jb .lo
    ja .hi
    or al, al
    jz .eq
    inc si
    inc di
    jmp short .c
.eq:
    xor ax, ax
    jmp short .out
.lo:
    mov ax, -1
    jmp short .out
.hi:
    mov ax, 1
.out:
    pop di
    pop si
    pop cx
    pop bx
    ret

pl_lkup:
    cmp al, 'a'
    jb .out
    cmp al, 'z'
    ja .out
    sub al, 32
.out:
    ret

pl_ins_at:
    push ax
    push bx
    push cx
    push si
    push di
    mov bl, al
    mov cx, di                        ; CX = where to stop shifting
    mov si, di
.flen:
    cmp byte [si], 0
    je .found
    inc si
    jmp .flen
.found:
    mov di, si
    inc di
.shift:
    mov al, [si]
    mov [di], al
    cmp si, cx
    je .place
    dec si
    dec di
    jmp .shift
.place:
    mov di, cx
    mov [di], bl
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_group3 - thousands separators through pl_numbuf's INTEGER part, however
; many it takes.
;
; IT REPLACES pl_comma_ins, WHICH HAD SILENTLY BECOME WRONG. That routine's
; own comment said "a 16-bit value never needs more than one - max 5 digits",
; and that was true right up until stage 4.0 made every value a double. It
; counted digits to the NUL, so the fraction counted as part of the run:
; 1234.5 in the Comma format drew as "123,4.5", and 1234567 as "1234,567".
; Nothing in the app could show a number that large or that precise when the
; routine was written.
;
; Separators go in RIGHT TO LEFT, which is why each insertion can ignore the
; ones already placed - they are all to its right.
; -----------------------------------------------------------------------------
pl_group3:
    push ax
    push bx
    push cx
    push si
    push di
    mov si, pl_numbuf
    cmp byte [si], '-'
    jne .nosign
    inc si
.nosign:
    cmp byte [si], '$'
    jne .nodollar
    inc si
.nodollar:
    mov bx, si                        ; BX = the first integer digit
.ilen:
    mov al, [si]
    cmp al, '0'
    jb .iend
    cmp al, '9'
    ja .iend
    inc si
    jmp .ilen
.iend:
    mov cx, si
    sub cx, bx                        ; CX = how many integer digits
.loop:
    cmp cx, 4
    jb .out                           ; three or fewer need no separator
    sub cx, 3
    mov di, bx
    add di, cx
    mov al, ','
    call pl_ins_at
    jmp .loop
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret


section PL_MODSEC                      ; 81.62: a less-used function, CHART.OVL
; -----------------------------------------------------------------------------
; pl_dollar_ins - '$' in front of pl_numbuf's digits but AFTER a leading '-',
; so -123 in a currency format is "-$123" and not "$-123".
; -----------------------------------------------------------------------------
pl_dollar_ins:
    push ax
    push di
    mov di, pl_numbuf
    cmp byte [di], '-'
    jne .here
    inc di
.here:
    mov al, '$'
    SHOUT pl_ins_at
    pop di
    pop ax
    ret

section .text

section PL_MODSEC                      ; 81.62: a less-used function, CHART.OVL
; -----------------------------------------------------------------------------
; pl_upcase - AL and AH both to upper case, for SEARCH's folded compare
; -----------------------------------------------------------------------------
pl_upcase:
    cmp al, 'a'
    jb .a1
    cmp al, 'z'
    ja .a1
    sub al, 32
.a1:
    cmp ah, 'a'
    jb .a2
    cmp ah, 'z'
    ja .a2
    sub ah, 32
.a2:
    ret

section .text
; -----------------------------------------------------------------------------
; pl_matchat - in: SI, DI; out: CF=1 if the string at DI is a prefix of the
; one at SI. Both preserved.
;
; AN EMPTY NEEDLE NEVER MATCHES, deliberately: SUBSTITUTE walks the text one
; character at a time and advances by the needle's length on a hit, so an
; empty one that matched would advance by nothing and never terminate.
; -----------------------------------------------------------------------------
pl_matchat:
    push ax
    push si
    push di
    cmp byte [di], 0
    je .no
.l:
    mov al, [di]
    or al, al
    jz .yes
    mov ah, [si]
    cmp al, ah
    jne .no
    inc si
    inc di
    jmp .l
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop di
    pop si
    pop ax
    ret

section PL_MODSEC                      ; 81.62: a less-used function, CHART.OVL


section .text
; =============================================================================
; THE STRING STACK (stage 4.5)
;
; A text function with more than one string argument has to hold the first one
; while the second is parsed - and parsing the second can reach any text
; function again, which writes pl_sacc. pl_sacc alone is therefore not enough,
; and neither is a second fixed buffer: `=FIND(A1, LEFT(A2,3))` would have the
; inner LEFT overwrite the outer FIND's banked needle.
;
; This is NOT the machine stack. SPEC.md 20.6 rule 6 gives a task 384 bytes
; and says in as many words: no deep recursion, no big stack buffers. Banking
; 65 bytes per argument per frame there, under six levels of pl_eval_cell
; recursion, is exactly the buffer that rule forbids. So the bank is bss, it
; is bounded at PL_SSTK_N levels, and running out is a #VALUE! rather than a
; silent overwrite.
; =============================================================================
; pl_smove - copy PL_STR_MAX+1 bytes SI -> DI, both DS-relative. Not `rep
; movsb`, because ES belongs to the cell segment through most of this file.
pl_smove:
    push ax
    push cx
    push si
    push di
    mov cx, PL_STR_MAX + 1
.l:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jnz .l
    pop di
    pop si
    pop cx
    pop ax
    ret

; pl_sslot - in: AX = depth from the TOP (0 = the string banked last)
; out: SI = its address. Reading past the bottom gives the EMPTY string, not
; whatever bss lies below it.
pl_sslot:
    push ax
    push dx
    mov si, pl_snull
    mov dx, [pl_sstk_sp]
    inc ax
    cmp ax, dx
    ja .out
    sub dx, ax
    mov ax, dx
    mov dx, PL_STR_MAX + 1
    mul dx
    add ax, pl_sstk
    mov si, ax
.out:
    pop dx
    pop ax
    ret

; pl_spush - bank pl_sacc. out: CF=1 the stack is full, and #VALUE! is raised
pl_spush:
    push ax
    push dx
    push si
    push di
    mov ax, [pl_sstk_sp]
    cmp ax, PL_SSTK_N
    jae .full
    inc word [pl_sstk_sp]
    mov dx, PL_STR_MAX + 1
    mul dx                            ; DX:AX, and PL_SSTK_N * 65 is far
    add ax, pl_sstk                   ; inside a segment, so DX is zero
    mov di, ax
    mov si, pl_sacc
    call pl_smove
    clc
    jmp .out
.full:
    mov byte [pl_evalerr], PL_ERR_VALUE
    stc
.out:
    pop di
    pop si
    pop dx
    pop ax
    ret

; pl_spop - drop the top bank
pl_spop:
    cmp word [pl_sstk_sp], 0
    je .out
    dec word [pl_sstk_sp]
.out:
    ret

; pl_srestore - put the top bank back in pl_sacc and drop it
pl_srestore:
    push ax
    push si
    push di
    xor ax, ax
    call pl_sslot
    mov di, pl_sacc
    call pl_smove
    call pl_spop
    pop di
    pop si
    pop ax
    ret


section PL_MODSEC                      ; 81.62: a less-used function, CHART.OVL

; plm_vpush / plm_binop_pre - pl_vpush and pl_binop_pre for the module (81.62).
; Those two move pl_acc on and off their CALLER's stack past their own return
; address, so behind a far call and a shim they would bank it on the shim's
; frame and retf into the value. The stack work has to happen here; the fp
; loading, which touches no stack, calls back as pl_binop_ld
plm_vpush:
    ; STKBALANCE-NET: +2 - 81.75: TWO WORDS now, not four; banks pl_acc on the CALLER's stack for a binary operator; plm_binop_pre takes it off
    pop ax
    push word [pl_acc+2]
    push word [pl_acc]
    push ax
    ret
plm_binop_pre:
    ; STKBALANCE-NET: -4 - the other half of plm_vpush - one call each, always paired
    pop ax
    pop word [pl_lhs]
    pop word [pl_lhs+2]
    push ax
    SHOUT pl_binop_ld
    ret


section .text
; =============================================================================
; DATE SERIALS (stage 4.5)
;
; A date is a NUMBER: the count of days since the epoch, with the time of day
; in the fraction. That is Excel's model and it is why dates arithmetic at all
; - tomorrow is +1, an interval is a subtraction, and a date sorts because it
; is a number that happens to be shown as a date.
;
; THE EPOCH IS SERIAL 1 = 1 JANUARY 1900, AND SERIAL 60 IS 29 FEBRUARY 1900 -
; A DAY THAT NEVER EXISTED. 1900 was not a leap year; Lotus 1-2-3 thought it
; was, Excel copied the mistake so the two could exchange files, and every
; version since has kept it for the same reason. Getting it "right" here would
; put every date in a shared file one day out from what Excel shows, which is
; a worse bug than the one being reproduced. So serial 60 is the phantom day,
; and 61 is 1 March 1900.
;
; The range is what an UNSIGNED word holds, which is almost exactly Excel
; 2.1's own: serial 65535 is 5 June 2079, and 2.1 stops at 31 December 2078.
; -----------------------------------------------------------------------------
; pl_fp_32768_b - B = 32768.0. Clobbers A, so build it BEFORE loading the
; value. fx_i2b cannot: 32768 is not a signed 16-bit integer.
; -----------------------------------------------------------------------------
pl_fp_32768_b:
    push ax
    mov word [fx_q+0], 0x8000
    mov word [fx_q+2], 0
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    call fx_u32_to_a
    call fx_a_to_b
    pop ax
    ret


; -----------------------------------------------------------------------------
; pl_acc_fromudw - AX, an unsigned word, becomes pl_acc. fx_i2a is signed and
; would make 46265 negative.
; -----------------------------------------------------------------------------
pl_acc_fromudw:
    push ax
    mov [fx_q+0], ax
    mov word [fx_q+2], 0
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    call fx_u32_to_a
    call pl_acc_store
    pop ax
    ret

; pl_isleap - in: pl_dt_ly = the year; out: CF=1 if it is a leap year.
; The full rule, not "divisible by four": 1900 is not a leap year and 2000 is,
; and both are inside the range this app covers.
pl_isleap:
    push ax
    push bx
    push dx
    mov ax, [pl_dt_ly]
    mov bx, 400
    xor dx, dx
    div bx
    or dx, dx
    jz .yes                           ; a multiple of 400 always is
    mov ax, [pl_dt_ly]
    mov bx, 100
    xor dx, dx
    div bx
    or dx, dx
    jz .no                            ; a multiple of 100 (but not 400) is not
    mov ax, [pl_dt_ly]
    mov bx, 4
    xor dx, dx
    div bx
    or dx, dx
    jz .yes
.no:
    clc
    jmp .out
.yes:
    stc
.out:
    pop dx
    pop bx
    pop ax
    ret

; pl_yearlen - in: AX = year; out: AX = 365 or 366
pl_yearlen:
    mov [pl_dt_ly], ax
    call pl_isleap
    mov ax, 365
    jnc .out
    inc ax
.out:
    ret

; pl_monlen - in: AX = month 1..12, BX = year; out: AX = days in it
pl_monlen:
    push bx
    push si
    cmp ax, 1
    jb .bad
    cmp ax, 12
    ja .bad
    mov si, ax
    dec si
    mov [pl_dt_ly], bx
    xor bh, bh
    mov bl, [pl_dt_mlen + si]
    mov ax, bx
    cmp si, 1                         ; February
    jne .out
    call pl_isleap
    jnc .out
    inc ax
    jmp .out
.bad:
    xor ax, ax
.out:
    pop si
    pop bx
    ret


; -----------------------------------------------------------------------------
; pl_ymd_to_ser - in: pl_dt_y/m/d; out: AX = the serial, CF=1 if the date is
; outside 1900-01-01 .. 2079-06-06 (what an unsigned word holds).
;
; The month is allowed to run outside 1..12 and the day outside a month's
; length, exactly as Excel's DATE() does: DATE(1990,13,1) is January 1991 and
; DATE(1990,1,32) is 1 February. Rolling the month first and then simply
; ADDING the days is what makes both fall out for free.
; -----------------------------------------------------------------------------
pl_ymd_to_ser:
    push bx
    push cx
    push dx
.mroll:
    mov ax, [pl_dt_m]
    cmp ax, 1
    jge .mrollhi
    add word [pl_dt_m], 12            ; month 0 is December of the year before
    dec word [pl_dt_y]
    jmp .mroll
.mrollhi:
    cmp ax, 12
    jle .mdone
    sub word [pl_dt_m], 12
    inc word [pl_dt_y]
    jmp .mroll
.mdone:
    mov ax, [pl_dt_y]
    cmp ax, 1900
    jb .bad
    cmp ax, 2080
    ja .bad
    xor cx, cx                        ; CX = whole days before this year
    mov word [pl_dt_ys], 1900
.yloop:
    mov ax, [pl_dt_ys]
    cmp ax, [pl_dt_y]
    jae .ydone
    call pl_yearlen
    add cx, ax
    inc word [pl_dt_ys]
    jmp .yloop
.ydone:
    mov word [pl_dt_ms], 1
.mloop:
    mov ax, [pl_dt_ms]
    cmp ax, [pl_dt_m]
    jae .mdone2
    mov bx, [pl_dt_y]
    call pl_monlen
    add cx, ax
    inc word [pl_dt_ms]
    jmp .mloop
.mdone2:
    add cx, [pl_dt_d]                 ; the day, which may itself overflow the
    mov ax, cx                        ; month - Excel lets it, and adding is
    cmp ax, 60                        ; what makes that work
    jb .noskip
    inc ax                            ; step over the phantom 29 February 1900
.noskip:
    clc
    jmp .out
.bad:
    xor ax, ax
    stc
.out:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_pnow - NOW(), id 106. The serial date plus the fraction of the day, which
; is what Excel's NOW() is: the same number DATE() gives plus the same fraction
; TIME() gives.
;
; THE BIOS IS READ THE WAY THE KERNEL READS IT, poison and all: CX/DX are set
; to 0xFFFF before the call and checked after, because a BIOS that does not
; implement the service can return with CF clear having touched nothing, and
; the sentinel is the only thing that catches it. Every BCD field is validated
; before it is believed - a clock reporting hour 0x99 is not an hour.
;
; A machine with no usable RTC gets #N/A, which is the honest answer and the
; one a spreadsheet can test with ISNA. It does NOT get the uptime dressed up
; as a date, which is what the old comment here rightly refused to fake.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; pl_prand - RAND(), id 109. A number in [0,1).
;
; A 32-BIT LINEAR CONGRUENTIAL GENERATOR, seed = seed*25173 + 13849, which has
; the full 2^32 period because the multiplier is 1 mod 4 and the increment is
; odd. The multiplier fits a word, so the 32x16 product is two `mul`s and an
; add rather than a long-multiply routine.
;
; SEEDED FROM THE BIOS TICK COUNT, int 1Ah AH=00h - CX:DX is ticks since
; midnight, and unlike AH=02h/04h it works on a PC with no RTC at all, which
; is exactly the machine 81.42 found here. A tick count is a poor source of
; entropy and a fine source of a seed: it only has to differ between sessions.
;
; The value is the HIGH word over 65536. The low bits of an LCG are the weak
; ones - taking the top half is the standard remedy and costs nothing.
; -----------------------------------------------------------------------------
pl_prand:
    push bx
    push cx
    push dx
    cmp word [pl_rndhi], 0            ; unseeded? the very first RAND() of a
    jne .step                         ; session pays for the BIOS call
    cmp word [pl_rndlo], 0
    jne .step
    xor ah, ah
    int 0x1a                          ; CX:DX = ticks since midnight
    mov [pl_rndhi], cx
    mov [pl_rndlo], dx
    or dx, cx
    jnz .step
    mov word [pl_rndlo], 1            ; a clock reading exactly zero would
.step:                                ; leave the generator stuck at zero
    mov ax, [pl_rndlo]
    mov cx, 25173
    mul cx                            ; DX:AX = lo * 25173
    mov bx, dx                        ; BX = the carry into the high word
    push ax
    mov ax, [pl_rndhi]
    mul cx                            ; only the low half of this matters
    add ax, bx
    mov bx, ax                        ; BX = the new high word, pre-increment
    pop ax
    add ax, 13849
    adc bx, 0
    mov [pl_rndlo], ax
    mov [pl_rndhi], bx
    mov ax, 256                       ; /256 TWICE = /65536, which is what a
    call pl_acc_int                   ; 16-bit word cannot hold in one go.
    call pl_acc_load_b                ; THE DIVISOR IS BUILT FIRST, because
    mov ax, bx                        ; pl_acc_int goes through fx_i2a and
    call pl_acc_fromudw               ; pl_acc_fromudw through fx_u32_to_a -
    call pl_acc_load_a                ; BOTH WRITE A. Loading the value into A
    call fx_div                       ; and then building 256 overwrote it, and
    call fx_div                       ; RAND() answered a constant 256/256 = 1
    call pl_acc_store                 ; (81.42.1 again, verbatim). B is loaded
                                      ; once for both divides: fpx_div and
                                      ; fps_div stage from memory and write
                                      ; back A alone, so B survives one
    xor ax, ax                        ; PL_T_NUM
    inc ax
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_bios_ymd - the calendar date from the BIOS into pl_dt_y/m/d.
; out: CF=1 if there is no usable clock. Every other register preserved.
;
; AH=04h answers CH/CL = century and year and DH/DL = month and day, all packed
; BCD. CX and DX are POISONED with 0xFFFF first and checked after, because a
; BIOS without the service can return CF clear having touched nothing - the
; sentinel is the only thing that catches that, and it is the check the kernel's
; own clk_rtc_read makes for the same reason.
; -----------------------------------------------------------------------------
pl_bios_ymd:
    push ax
    push bx
    push cx
    push dx
    mov cx, 0xFFFF
    mov dx, 0xFFFF
    mov ah, 0x04
    stc
    int 0x1a
    jc .bad
    cmp cx, 0xFFFF
    je .bad
    mov al, ch
    call pl_bcd2bin
    jc .bad
    mov bl, al                        ; the century
    mov al, cl
    call pl_bcd2bin
    jc .bad
    mov bh, al                        ; ...and the year within it
    push dx                           ; MUL WRITES DX, and DX is holding the
    mov al, bl                        ; month and day. Reading dh afterwards
    xor ah, ah                        ; got the high word of century*100 - a
    mov cx, 100                       ; month of zero, and NOW() answered #N/A
    mul cx                            ; on a machine whose clock was fine
    xor ch, ch
    mov cl, bh
    add ax, cx
    pop dx
    cmp ax, 1900
    jb .bad
    cmp ax, 2080
    ja .bad
    mov [pl_dt_y], ax
    mov al, dh
    call pl_bcd2bin
    jc .bad
    xor ah, ah
    or ax, ax
    jz .bad
    cmp ax, 12
    ja .bad
    mov [pl_dt_m], ax
    mov al, dl
    call pl_bcd2bin
    jc .bad
    xor ah, ah
    or ax, ax
    jz .bad
    cmp ax, 31
    ja .bad
    mov [pl_dt_d], ax
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret
.bad:
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

pl_pnow:
    push bx
    push cx
    push dx
    push si
    call pl_bios_ymd                  ; -> pl_dt_y/m/d, CF=1 if no clock
    jc .na
    call pl_ymd_to_ser                ; -> AX = the whole days
    jc .na
    push ax
    mov cx, 0xFFFF                    ; the time: AH=02h -> CH/CL/DH = hour,
    mov dx, 0xFFFF                    ; minute and second, BCD
    mov ah, 0x02
    stc
    int 0x1a
    jc .napop
    cmp cx, 0xFFFF
    je .napop
    mov al, ch
    call pl_bcd2bin
    jc .napop
    cmp al, 23
    ja .napop
    xor bh, bh
    mov bl, al                        ; BX = hours
    mov al, cl
    call pl_bcd2bin
    jc .napop
    cmp al, 59
    ja .napop
    push bx
    xor ah, ah
    mov cx, ax                        ; CX = minutes
    mov al, dh
    call pl_bcd2bin
    pop bx
    jc .napop
    cmp al, 59
    ja .napop
    xor ah, ah
    mov dx, ax                        ; DX = seconds
    call pl_hms_to_acc                ; pl_acc = the fraction of the day
    call pl_acc_load_b                ; ...into B, WHICH MUST COME FIRST:
    pop ax                            ; pl_acc_fromudw goes through fx_u32_to_a
    call pl_acc_fromudw               ; and CLOBBERS A, so a fraction parked
    call pl_acc_load_a                ; there is gone by the add. It answered
    call fx_add                       ; twice the serial, both operands being
                                      ; the day count (81.42.1)
    call pl_acc_store
    clc
    jmp .out
.napop:
    pop ax
.na:
    mov byte [pl_evalerr], PL_ERR_NA  ; no usable clock: #N/A, and ISNA can
    stc                               ; see it
.out:
    pop si
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_bcd2bin - AL packed BCD -> AL binary. CF=1 if either nibble is not a
; decimal digit, which is how a clock that is not running is caught: it answers
; 0xFF or 0x99 rather than failing the call.
; -----------------------------------------------------------------------------
pl_bcd2bin:
    push cx
    mov cl, al
    and cl, 0x0F
    cmp cl, 9
    ja .bad
    shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1
    cmp al, 9
    ja .bad
    mov ch, al
    add al, al
    add al, al
    add al, ch                        ; al = high*5
    add al, al                        ; ...*2 = high*10
    add al, cl
    pop cx
    clc
    ret
.bad:
    pop cx
    stc
    ret

; -----------------------------------------------------------------------------
; pl_pdate - the DATE and TIME functions, ids 58 and up.
;
; NOW() IS HERE NOW, and the paragraph that used to stand in this place was
; wrong in a way worth keeping a record of. It said NOW() "cannot be written:
; no kernel call publishes the calendar date... the only clocks a package can
; read are OSAPI_GET_TICKS and OSAPI_BOOT_TICKS, both of which count since
; boot... It needs one new API slot, and that is a kernel change with its own
; review".
;
; EVERY SENTENCE ABOUT THE OSAPI TABLE IS TRUE. The conclusion does not follow,
; because the OSAPI table is not the only way out of a package. The kernel does
; not read the clock through its own API either - clk_rtc_read calls the BIOS,
; `int 0x1a` with AH=04h for the date and AH=02h for the time - and a package
; may make that identical call. MISSILE, CYCLONE and PAINT already use
; `int 0x16`; TASKMGR uses `int 0x12`. There is no rule against it and there is
; precedent for it four files away.
;
; A MISSING API IS NOT A MISSING CAPABILITY. The claim came from grepping the
; SDK for a date slot, finding none, and stopping there - and it then travelled
; into SPEC.md twice as a reason NOW() was blocked on a kernel decision. It was
; blocked on nobody having looked past os88api.inc (81.42).
;
; in: AX = the id, SI just past '('. out: AX = the value, SI past ')'.
; -----------------------------------------------------------------------------
pl_hms_to_acc:
    push ax
    push bx
    push cx
    push dx
    mov ax, bx                        ; hours -> seconds, in DX:AX
    mov bx, 3600
    mul bx                            ; unsigned: 24*3600 already needs 17 bits
    push dx
    push ax
    mov ax, cx
    mov bx, 60
    mul bx
    pop bx
    pop cx                            ; CX:BX = the hours' seconds
    add ax, bx
    adc dx, cx
    pop cx                            ; the ORIGINAL DX (seconds argument)
    push cx
    add ax, cx
    adc dx, 0
    mov [fx_q+0], ax                   ; the whole thing as an unsigned 32-bit
    mov [fx_q+2], dx
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    call fx_u32_to_a
    call pl_acc_store
    call pl_dt_86400_b
    call pl_acc_load_a
    call fx_div                       ; a fraction of one day
    call pl_acc_store
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; pl_dt_86400_b - B = 86400.0, the seconds in a day. Clobbers A.
pl_dt_86400_b:
    push ax
    mov word [fx_q+0], 86400 & 0xFFFF
    mov word [fx_q+2], 86400 >> 16
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    call fx_u32_to_a
    call fx_a_to_b
    pop ax
    ret


; pl_dt_tmp_store / pl_dt_tmp_load_b - park fp A in bss and bring it back as
; B. pl_vpush cannot be used here: it banks on the CALLER's stack and pairs
; with exactly one pl_binop_pre (81.25.3).
pl_dt_tmp_store:
    push di
    mov di, pl_dt_tmp                 ; fx_pack_a writes at DI; fx_unpack_b
    call fx_pack_a                    ; reads at SI, and leaves A alone
    pop di
    ret
pl_dt_tmp_load_b:
    push si
    mov si, pl_dt_tmp
    call fx_unpack_b
    pop si
    ret
pl_dt_tmp_load_a:
    push si
    mov si, pl_dt_tmp
    call fx_unpack_a
    pop si
    ret


; pl_pif - IF(cond,then,else): the one function that does not fold - its
; branches are not even both evaluated the way a real spreadsheet expects
; only ONE side effect-free path to matter, but here both sides just get
; parsed unconditionally (the parse is what advances SI) and the condition
; alone picks which value survives. Parsing IS evaluation here, and it has
; one side effect since errors landed: a raise of the sticky pl_evalerr - so
; the raise of the branch the condition did NOT pick is banked and unraised
; (81.20), or =IF(B1=0,0,A1/B1) answered #DIV/0! for the case it guards.
; in: SI right after "IF("; out: AX=result, SI advanced past ')' if found
pl_pif:
    push bx
    push cx
    call pl_pcmp                      ; the condition, kept as a truth value
    call pl_acc_iszero                ; rather than as a number
    mov bx, 0
    jc .condfalse
    mov bx, 1
.condfalse:
    cmp byte [si], ','
    jne .bad
    inc si
    mov al, [pl_evalerr]              ; banked across the then-parse, and
    mov ah, [pl_macro_exec]           ; restored if then was NOT chosen - and
    push ax                           ; the branch the condition did NOT pick
    or bx, bx                         ; runs no MACRO command (81.63): parsed,
    jnz .thenrun                      ; as it has to be, but inert - or
    mov byte [pl_macro_exec], 0       ; IF(H7=3,BREAK()) broke at 1
.thenrun:
    call pl_pcmp                      ; the then-value, banked whole
    pop ax
    mov [pl_macro_exec], ah
    or bx, bx
    jnz .thenkept
    mov [pl_evalerr], al
.thenkept:
    call pl_vpush                     ; the then-VALUE...
    mov al, [pl_curtype]              ; ...AND WHAT KIND OF VALUE IT IS, which
    mov ah, [pl_curaux]               ; pl_vpush does not carry. Without this
    push ax                           ; the else-parse left ITS type behind, and
    cmp al, PL_T_TEXT                 ; a TEXT then-value's characters are not
    jne .nottext                      ; in pl_acc at all but in pl_sacc, which
    call pl_spush                     ; the else-parse overwrites: so
.nottext:                             ; =IF(A1>1,"big","small") answered
    cmp byte [si], ','                ; "small" for every A1 (81.10.10 found
    jne .badpop                       ; it). Banked on the string stack, the
    inc si                            ; way & banks its left operand
    mov al, [pl_evalerr]              ; ...and the same for the else-parse
    mov ah, [pl_macro_exec]
    push ax
    or bx, bx
    jz .elserun
    mov byte [pl_macro_exec], 0
.elserun:
    call pl_pcmp                      ; the else-value, left in pl_acc
    pop ax
    mov [pl_macro_exec], ah
    or bx, bx
    jz .elsekept
    mov [pl_evalerr], al
.elsekept:
    pop cx                            ; CL/CH: the then-value's type and aux
    or bx, bx
    jz .dropthen                      ; false: pl_acc already holds the else
    mov [pl_curtype], cl              ; true: the then-value back WHOLE - its
    mov [pl_curaux], ch               ; kind, and its four bytes restored as
    pop word [pl_acc]                 ; they were banked rather than through
    pop word [pl_acc+2]               ; the arithmetic layer, which a TEXT
    cmp cl, PL_T_TEXT
    jne .out
    call pl_srestore                  ; ...and its characters
    jmp .out
.dropthen:
    add sp, 4                         ; 81.75: FOUR, not eight - pl_vpush banks
                                      ; a fixed-point value now. The banked
                                      ; then-value is not wanted,
    cmp cl, PL_T_TEXT                 ; and nor are its characters: a bank
    jne .out                          ; left on the string stack would shift
    call pl_spop                      ; every string after it by one
    jmp .out
.badpop:
    add sp, 6                         ; 81.75: six - four of value and two of
                                      ; type. The banked value, and its type...
    cmp al, PL_T_TEXT                 ; (AL still is: nothing since has
    jne .bad                          ; touched it)
    call pl_spop                      ; ...and any characters
.bad:
    xor ax, ax
    call pl_acc_int
.out:
    cmp byte [si], ')'
    jne .noclose
    inc si
.noclose:
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_pchoose - CHOOSE(index, v1, v2, ...) (SPEC.md 81.49)
; in: SI right after "CHOOSE("; out: the chosen value WHOLE - pl_acc,
; pl_curtype, and pl_sacc when it is text - and SI past ')'. AX is its
; truncation, for the callers that still want a word.
;
; IT WAS AN INTEGER FUNCTION: parsed in pl_pspecial beside MOD and FACT, every
; value taken through pl_parg as a word and the answer handed back through
; pl_acc_int. So =CHOOSE(2,1.5,2.5) answered 2, any fractional cell it picked
; lost its fraction, and a text value came back 0. Excel's CHOOSE returns the
; value it picked, whatever it is.
;
; THE CHOSEN VALUE IS NOT BANKED, because nothing is parsed after it: the
; values before it are parsed and dropped (their raise of the sticky error
; does not stand - 81.20), the chosen one is parsed and left where the parser
; put it, and the rest are STEPPED OVER by pl_skipargs, never evaluated -
; which is also Excel's behaviour, and why a #DIV/0! in an unchosen argument
; after the chosen one never mattered. An index outside 1..n is #VALUE!.
; -----------------------------------------------------------------------------
pl_pchoose:
    push bx
    push cx
    call pl_parg                      ; the 1-based index, truncated as Excel
    mov bx, ax                        ; truncates it
    xor cx, cx
.next:
    cmp byte [si], ','
    jne .short                        ; the list ran out first
    inc si
    inc cx
    cmp cx, bx
    je .chosen
    mov al, [pl_evalerr]              ; banked across an unchosen value, and
    mov ah, [pl_macro_exec]           ; put back after it - which runs no
    push ax                           ; macro command, as IF's does not (81.63)
    mov byte [pl_macro_exec], 0
    call pl_pcmp
    pop ax
    mov [pl_evalerr], al
    mov [pl_macro_exec], ah
    jmp .next
.chosen:
    call pl_pcmp                      ; its value, its type, its text - and its
    call pl_skipargs                  ; raise stands. The rest are stepped over
    xor ax, ax                        ; to the matching ')', and SI past it
    cmp byte [pl_curtype], PL_T_NUM
    jne .out
    call pl_acc_toint
    jmp .out
.short:
    mov byte [pl_evalerr], PL_ERR_VALUE
    xor ax, ax
    call pl_acc_int
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    pop cx
    pop bx
    ret

; pl_pnot - NOT(x): logical negation
; in: SI right after "NOT("; out: AX=1 or 0, SI advanced past ')' if found
pl_pnot:
    call pl_pcmp
    call pl_acc_iszero
    jc .true
    xor ax, ax
    call pl_acc_int
    jmp .close
.true:
    mov ax, 1
    call pl_acc_int
.close:
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    ret

; pl_pabs - ABS(x): absolute value
; in: SI right after "ABS("; out: AX=|x|, SI advanced past ')' if found
pl_pabs:
    call pl_pcmp
    call pl_acc_abs                   ; 81.75: two's complement (see there)
.close:
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    ret

; =============================================================================
; MACROS, the package's half (SPEC.md 81.63): the Run dialog, the door, and
; the two ways a paused run comes back. The engine and every macro function
; are CHART.OVL's - the module's own header, at plm_pmacro, is the design.
; =============================================================================
PL_MACRO_MAXSTEPS equ 10000          ; a runaway loop ENDS rather than hangs:
                                     ; the system is cooperative and the step
                                     ; loop yields to nothing (81.8). It was
                                     ; 5000, before a macro could loop
PL_FID_MACRO   equ 111               ; the first macro function's id...
PL_FID_DATABASE equ 131              ; the first DATABASE function's id
                                     ; (81.65) - one past the last macro
                                     ; command (111 + 20)
PL_FID_CELL     equ 142              ; CELL's id (81.66) - one past the last
                                     ; DATABASE function (131 + 11)
PL_FID_MDETERM  equ 143              ; the first ARRAY/MATRIX function's id
                                     ; (81.67) - one past CELL
PL_FID_MINVERSE equ 144
PL_FID_MMULT    equ 145
PL_FID_TRANSPOSE equ 146
PL_FID_LINEST   equ 147
PL_FID_LOGEST   equ 148
PL_FID_TREND    equ 149
PL_FID_GROWTH   equ 150
PL_MF_ACTCELL  equ 14                ; ...and ACTIVE.CELL's, counted from it
PL_MC_NONE     equ 0                 ; what a step asked for (pl_macro_ctl):
PL_MC_GOTO     equ 1                 ; the next cell is [pl_macro_ncol/nrow]
PL_MC_STOP     equ 2                 ; RETURN, HALT, or a macro error
PL_MC_PAUSEN   equ 3                 ; ALERT: wait, then the next cell
PL_MC_PAUSEH   equ 4                 ; INPUT: wait, then THIS cell again
PL_MC_SKIP     equ 5                 ; on past the NEXT of the loop at ncol/nrow
PL_MW_START    equ 1                 ; what a resume means (pl_macro_wait)
PL_MW_ALERT    equ 2
PL_MW_INPUT    equ 3
PL_MLOOPS      equ 4                 ; FOR/WHILE frames, nested
PL_LF_KIND     equ 0                 ; a frame: 1 FOR / 2 WHILE,
PL_LF_COL      equ 1                 ; its own cell,
PL_LF_ROW      equ 3
PL_LF_CCOL     equ 5                 ; FOR's counter cell,
PL_LF_CROW     equ 7
PL_LF_END      equ 9                 ; its end and step, doubles
PL_LF_STEP     equ 17
PL_LF_SZ       equ 25
PL_MPROMPT     equ 30                ; INPUT's prompt, as the dialog shows it
PL_MSTMSG      equ 40                ; MESSAGE's text on the status bar
section PL_MODSEC                      ; 81.65: DAVERAGE...DVARP, CHART.OVL


section .text

; pl_funcid - in: pl_ident; out: AL = the function's id, or 0xFF unknown.
; TABLE-DRIVEN as of stage 3.0d: the id IS the entry's index in pl_functab, so
; adding a function is one string and one table word. It was an unrolled
; compare chain of five lines per function, which at ten functions was merely
; verbose and at twenty-five would have been a hundred lines of boilerplate
; with a hand-written id on each - exactly the shape that drifts.
pl_funcid:
    push bx
    push cx
    push si
    push di
    xor cx, cx
    mov bx, pl_functab
.loop:
    mov di, [bx]
    or di, di
    jz .unknown                       ; the table's 0 terminator
    mov si, pl_ident
    call pl_streq
    jc .found
    inc cx
    add bx, 2
    jmp .loop
.found:
    mov ax, cx
    jmp .out
.unknown:
    mov ax, 0xFF
.out:
    pop di
    pop si
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; pl_chktext - the operand pl_curtype describes is TEXT, and something
; arithmetic is about to happen to it: raise #VALUE!. Excel's own answer, and
; the reason it is raised HERE rather than in pl_getcell2 is that a bare `=B4`
; must still SHOW the label, and SUM must still skip it - only an operator
; makes a label a mistake.
; -----------------------------------------------------------------------------
pl_chktext:
    cmp byte [pl_curtype], PL_T_TEXT
    jne .out
    mov byte [pl_evalerr], PL_ERR_VALUE
.out:
    ret

; -----------------------------------------------------------------------------
; pl_skipargs - SI is just past an unknown function's '('; leave it just past
; the matching ')'. Counting depth rather than scanning for the first ')' is
; what keeps `=FOO(SUM(A1:A2))` from leaving a stray parenthesis behind for
; the rest of the parse to trip over.
; -----------------------------------------------------------------------------
pl_skipargs:
    push cx
    mov cx, 1
.loop:
    mov al, [si]
    or al, al
    jz .out                           ; end of the formula: unbalanced, and
    inc si                            ; pl_paren_ok already refuses those at
    cmp al, '"'                       ; entry - this is belt and braces
    je .instr
    cmp al, '('
    jne .notopen
    inc cx
    jmp .loop
.notopen:
    cmp al, ')'
    jne .loop
    dec cx
    jnz .loop
.out:
    pop cx
    ret
.instr:                               ; A QUOTED STRING IS SKIPPED WHOLE, the
    mov al, [si]                      ; rule pl_paren_ok already kept: counted,
    or al, al                         ; the ')' in =FOO("a)")+1 closed FOO
    jz .out                           ; early and left "+1 as the tail. A
    inc si                            ; doubled quote closes and reopens, which
    cmp al, '"'                       ; comes out right (81.49)
    jne .instr
    jmp .loop

; -----------------------------------------------------------------------------
; pl_str_load - in: AX = an offset in pl_txtseg; copies that NUL string into
; pl_sacc, clipped to PL_STR_MAX. Every register preserved.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; pl_txtslot - in: ES:DI = a cell record whose type is PL_T_TEXT
; out: AX = the arena offset its characters live at.
;
; A plain LABEL keeps them in PL_C_FOFF. A FORMULA whose result is text keeps
; PL_C_FOFF for its own SOURCE and the result in PL_C_VAL (81.22.1), so
; reading FOFF for both loads the formula's own text - which is what the cell
; would draw on a pass-cache hit, with no evaluation to correct it.
;
; It is a proc rather than four inline instructions because the caller needs
; it inside a push/pop pair, and a label there is a chunk boundary stkbalance
; walks into without the push - which reads as an unbalanced path.
; -----------------------------------------------------------------------------
pl_txtslot:
    mov ax, [es:di+PL_C_FOFF]
    test byte [es:di+4], 1            ; HASFORMULA
    jz .out
    mov ax, [es:di+PL_C_VAL]
.out:
    ret

pl_str_load:
    push ax
    push cx
    push si
    push di
    push es
    mov es, [pl_txtseg]
    mov si, ax
    mov di, pl_sacc
    mov cx, PL_STR_MAX
.c:
    jcxz .term
    mov al, [es:si]
    or al, al
    jz .term
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .c
.term:
    mov byte [di], 0
    pop es
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_str_store - ES:DI = a cell record whose result is TEXT; put pl_sacc into
; that cell's result slot, claiming the slot on first use (81.22.1).
; out: CF=1 if the arena had no room, in which case the cell keeps whatever it
; had. Every register preserved.
; -----------------------------------------------------------------------------
pl_str_store:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    cmp byte [es:di+PL_C_TYPE], PL_T_TEXT  ; VAL IS ONLY A SLOT OFFSET IF THE
    jne .newslot                      ; CELL ALREADY HELD TEXT. On a formula
    mov ax, [es:di+PL_C_VAL]          ; that returned a number last time it is
    or ax, ax                         ; the low word of a DOUBLE, and treating
    jnz .haveslot                     ; that as an arena offset writes 64 bytes
.newslot:                             ; wherever the mantissa happens to point
    mov ax, [pl_txtlen]               ; claim one: PL_STR_MAX+1, once, for the
    mov bx, ax                        ; life of the cell - the arena never
    add bx, PL_STR_MAX + 1            ; frees, so a slot PER RECALCULATION
    cmp bx, PL_TXT_CAP                ; would empty it in seconds
    ja .noroom
    mov [pl_txtlen], bx
    mov [es:di+PL_C_VAL], ax          ; the union's first word IS the offset
    mov word [es:di+PL_C_VAL+2], 0
.haveslot:
    mov di, ax                        ; DI = the slot, ES = the arena
    mov es, [pl_txtseg]
    mov si, pl_sacc
    mov cx, PL_STR_MAX
.c:
    jcxz .term
    mov al, [si]
    or al, al
    jz .term
    mov [es:di], al
    inc si
    inc di
    dec cx
    jmp .c
.term:
    mov byte [es:di], 0
    clc
    jmp .out
.noroom:
    stc
.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_str_cat - append the NUL string at SI to pl_sacc, clipped to PL_STR_MAX.
; -----------------------------------------------------------------------------
pl_str_cat:
    push ax
    push cx
    push si
    push di
    mov di, pl_sacc
    mov cx, PL_STR_MAX
.find:
    cmp byte [di], 0
    je .app
    inc di
    dec cx
    jnz .find
.app:
    jcxz .term
    mov al, [si]
    or al, al
    jz .term
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .app
.term:
    mov byte [di], 0
    pop di
    pop si
    pop cx
    pop ax
    ret

; pl_streq - in: SI, DI (two NUL-terminated strings); out: CF=1 equal
pl_streq:
    push ax
    push si
    push di
.loop:
    mov al, [si]
    cmp al, [di]
    jne .neq
    or al, al
    jz .eq
    inc si
    inc di
    jmp .loop
.eq:
    stc
    jmp .out
.neq:
    clc
.out:
    pop di
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_clearcell - in: AX=col, BX=row
; -----------------------------------------------------------------------------
pl_clearcell:
    call pl_removecell
    ret

; =============================================================================
; String / number utilities
; =============================================================================

; pl_colname - bijective base-26 column letters (0-based index in AX)
; out: pl_colbuf = NUL-terminated letters (up to 2 for a 256-column grid)
pl_colname:
    ; STKBALANCE-LOOP: one digit pushed a turn and the second loop pops them; the count is in CX
    push ax
    push bx
    push cx
    push dx
    inc ax
    xor cx, cx
.divloop:
    or ax, ax
    jz .popall
    dec ax
    xor dx, dx
    mov bx, 26
    div bx
    push dx
    inc cx
    jmp .divloop
.popall:
    mov bx, pl_colbuf
.popone:
    or cx, cx
    jz .term
    pop dx
    add dl, 'A'
    mov [bx], dl
    inc bx
    dec cx
    jmp .popone
.term:
    mov byte [bx], 0
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; pl_itoa - signed AX to a NUL-terminated decimal string in pl_numbuf
pl_itoa:
    ; STKBALANCE-LOOP: one digit pushed a turn and the second loop pops them; the count is in CX
    push ax
    push bx
    push cx
    push dx
    push di
    mov di, pl_numbuf
    or ax, ax
    jns .pos
    mov byte [di], '-'
    inc di
    neg ax
.pos:
    xor cx, cx
    or ax, ax
    jnz .divloop
    mov byte [di], '0'
    inc di
    jmp .term
.divloop:
    or ax, ax
    jz .emit
    xor dx, dx
    mov bx, 10
    div bx
    push dx
    inc cx
    jmp .divloop
.emit:
    or cx, cx
    jz .term
    pop dx
    add dl, '0'
    mov [di], dl
    inc di
    dec cx
    jmp .emit
.term:
    mov byte [di], 0
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_mkblank - rebuild pl_blank (every empty cell's display text) as exactly
; [pl_cellch] spaces + NUL. Called once at startup and again whenever
; Format > Column Width... changes the preset - pl_blank can't be a fixed
; string once the cell width is a runtime value.
; -----------------------------------------------------------------------------
pl_mkblank:
    push ax
    push cx
    push di
    mov cx, [pl_cellch]
    mov di, pl_blank
.fill:
    jcxz .term
    mov byte [di], ' '
    inc di
    loop .fill
.term:
    mov byte [di], 0
    pop di
    pop cx
    pop ax
    ret

; pl_rjust - right-justify pl_numbuf into a fixed PL_CELL_CH-wide pl_tbuf
pl_rjust:
    push ax
    push cx
    push si
    push di
    mov si, pl_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov di, pl_tbuf
    mov ax, [pl_cellch]
    sub ax, cx
    jbe .nopad
    push cx
    mov cx, ax
.pad:
    mov byte [di], ' '
    inc di
    loop .pad
    pop cx
.nopad:
    mov si, pl_numbuf
.copy:
    jcxz .term
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .copy
.term:
    mov byte [di], 0
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_ljust - left-justify pl_numbuf into a fixed PL_CELL_CH-wide pl_tbuf
; (padding trails, mirroring pl_rjust which pads first)
; -----------------------------------------------------------------------------
pl_ljust:
    push ax
    push cx
    push si
    push di
    mov si, pl_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov [pl_jlen], cx
    mov di, pl_tbuf
    mov si, pl_numbuf
.copy:
    jcxz .copydone
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .copy
.copydone:
    mov ax, [pl_cellch]
    sub ax, [pl_jlen]
    jbe .term
    mov cx, ax
.pad:
    mov byte [di], ' '
    inc di
    loop .pad
.term:
    mov byte [di], 0
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_cjust - center-justify pl_numbuf into a fixed PL_CELL_CH-wide pl_tbuf
; (the odd leftover space, if any, goes on the right)
; -----------------------------------------------------------------------------
pl_cjust:
    push ax
    push bx
    push cx
    push si
    push di
    mov si, pl_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov [pl_jlen], cx
    mov di, pl_tbuf
    mov ax, [pl_cellch]
    sub ax, cx
    jle .nopad
    mov bx, ax                        ; bx = total pad
    shr ax, 1                         ; ax = left pad (floor)
    mov cx, ax
    jcxz .lpdone
.lp:
    mov byte [di], ' '
    inc di
    loop .lp
.lpdone:
    sub bx, ax                        ; bx = right pad = total - left
    mov si, pl_numbuf
    mov cx, [pl_jlen]
.cp:
    jcxz .cpdone
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .cp
.cpdone:
    mov cx, bx
    jcxz .term
.rp:
    mov byte [di], ' '
    inc di
    loop .rp
    jmp .term
.nopad:
    mov si, pl_numbuf
    mov cx, [pl_jlen]
.cp2:
    jcxz .term
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .cp2
.term:
    mov byte [di], 0
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_justify - in: BL=format byte; dispatches to pl_ljust/pl_cjust/pl_rjust
; by the alignment bits (General and explicit Right both right-justify,
; since this app's cells are only ever numeric - matching how real Excel's
; own "General" alignment right-justifies a number)
; -----------------------------------------------------------------------------
pl_justify:
    push ax
    push cx
    mov al, bl                         ; 81.75: the TEXT number format is a
    and al, PL_FMT_NUM_MASK            ; left alignment and nothing else -
    mov cl, PL_FMT_NUM_SHIFT           ; which is what Excel's @ does to a
    shr al, cl                         ; cell that holds a number. An explicit
    cmp al, PL_NF_TEXT                 ; Alignment still wins, because it is
    jne .align                         ; tested after
    mov al, bl
    and al, PL_FMT_ALIGN_MASK
    jz .left                           ; General alignment: Text decides
.align:
    mov al, bl
    and al, PL_FMT_ALIGN_MASK
    mov cl, PL_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, PL_FMT_ALIGN_LEFT
    je .left
    cmp al, PL_FMT_ALIGN_CENTER
    je .center
    jmp .right
.left:
    call pl_ljust
    jmp .out
.center:
    call pl_cjust
    jmp .out
.right:
    call pl_rjust
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_justify_c - pl_justify for a LOGICAL or an ERROR value: General centres
; both (81.51). An explicit alignment means what it means for anything else.
; in: BL = the format byte
; -----------------------------------------------------------------------------
pl_justify_c:
    push ax
    push cx
    mov al, bl
    and al, PL_FMT_ALIGN_MASK
    mov cl, PL_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, PL_FMT_ALIGN_GENERAL
    jne .explicit
    call pl_cjust
    jmp short .out
.explicit:
    call pl_justify
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_justify_t - pl_justify for a LABEL rather than a number.
;
; The one difference, and it is Excel's: General aligns a number RIGHT and a
; label LEFT. An EXPLICIT alignment means the same thing for both, so this
; only intercepts General and hands everything else straight over.
; in: BL = the format byte
; -----------------------------------------------------------------------------
pl_justify_t:
    push ax
    push cx
    mov al, bl
    and al, PL_FMT_ALIGN_MASK
    mov cl, PL_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, PL_FMT_ALIGN_GENERAL
    jne .explicit
    call pl_ljust
    jmp .out
.explicit:
    call pl_justify
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_text_to_numbuf - copy the label at pl_curtoff (in pl_txtseg) into
; pl_numbuf, clipped to what the cell can show, so that the justifiers - which
; all read pl_numbuf and write pl_tbuf - need to know nothing about text.
;
; The label's OWN cell is clipped here; what runs on into the empty cells to
; its right, as Excel draws it, is theirs to draw (pl_spill, 81.54). That was
; thought to need a draw order - the neighbours' occupancy before this cell
; is drawn - and it does not: each cell draws only its own slice.
; -----------------------------------------------------------------------------
pl_text_to_numbuf:
    push ax
    push cx
    push si
    push di
    push es
    mov es, [pl_txtseg]
    mov si, [pl_curtoff]
    mov di, pl_numbuf
    mov cx, [pl_cellch]
    cmp cx, PL_NUMBUF_MAX             ; pl_numbuf is a fixed buffer and the
    jbe .cap                          ; cell width is a RUNTIME value now
    mov cx, PL_NUMBUF_MAX             ; (stage 3.0c's Column Width), so the
.cap:                                 ; clip is against both
    jcxz .term
.copy:
    mov al, [es:si]
    or al, al
    jz .term
    mov [di], al
    inc si
    inc di
    dec cx
    jnz .copy
.term:
    mov byte [di], 0
    pop es
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_spill - does a LABEL to the left run on into this empty cell? (81.54)
; in: AX = col, BX = row, the cell known empty. out: CF=1 with pl_tbuf holding
; this cell's slice of it and [pl_curfmt] the label's format; CF=0 otherwise.
;
; Excel draws a label wider than its column across the EMPTY cells to its
; right and stops at the first that holds anything. So the one label that can
; reach this cell is the NEAREST cell to its left in the row - any further one
; is stopped by it - and that is the record just before this cell's insertion
; point, the table being sorted by (row, col): one search, the one
; pl_getcell2 has just made. Each cell draws its own slice and nothing else,
; so no draw order and no ranged repaint can undo another cell's. Only a
; label that is General or left-aligned: centred and right-aligned ones run
; the other way in Excel, and are still clipped here.
; -----------------------------------------------------------------------------
pl_spill:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    cmp byte [pl_showformulas], 0     ; formulas on show: a cell shows its
    jne .no                           ; formula, and nothing runs on
    or ax, ax
    jz .no                            ; column A has nothing to its left
    mov dx, ax                        ; DX = this column
    call pl_findcell                  ; not there: DI = where it would go
    jc .no
    or di, di
    jz .no
    sub di, PL_C_SZ                   ; the record before it...
    mov es, [pl_cellseg]
    mov ax, [pl_cursheet]
    mov cl, PL_ROW_BITS
    shl ax, cl
    or ax, bx
    cmp [es:di], ax                   ; ...in this row of this sheet
    jne .no
    cmp byte [es:di+PL_C_TYPE], PL_T_TEXT
    jne .no                           ; a label, or a formula's text result
    mov bl, [es:di+5]                 ; its format
    mov al, bl
    and al, PL_FMT_ALIGN_MASK
    mov cl, PL_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, PL_FMT_ALIGN_GENERAL
    je .left
    cmp al, PL_FMT_ALIGN_LEFT
    jne .no
.left:
    mov si, [es:di+PL_C_FOFF]         ; a label's own text...
    test byte [es:di+4], 1
    jz .haveoff
    mov si, [es:di+PL_C_VAL]          ; ...or a formula's RESULT (81.22.1)
.haveoff:
    push si
    mov si, [es:di+2]                 ; its characters before this cell: the
    xor cx, cx                        ; widths of the columns between, each
.wsum:                                ; its own (81.56) - scrolled out of
    cmp si, dx                        ; view or not
    jae .wdone
    mov ax, si
    call pl_colwidth
    add cx, ax
    inc si
    jmp short .wsum
.wdone:
    pop si
    mov es, [pl_txtseg]
.skip:
    jcxz .skipped
    cmp byte [es:si], 0
    je .no                            ; it ends before this cell...
    inc si
    dec cx
    jmp short .skip
.skipped:
    cmp byte [es:si], 0
    je .no                            ; ...or exactly at its edge
    mov di, pl_numbuf
    mov cx, [pl_cellch]
    cmp cx, PL_NUMBUF_MAX
    jbe .copy
    mov cx, PL_NUMBUF_MAX
.copy:
    mov al, [es:si]
    or al, al
    jz .end
    mov [di], al
    inc si
    inc di
    loop .copy
.end:
    mov byte [di], 0
    call pl_ljust                     ; -> pl_tbuf, padded to the cell
    mov [pl_curfmt], bl               ; bold and underline are the label's
    stc
    jmp short .out
.no:
    clc
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_strlen - in: SI=NUL-terminated string; out: AX=length (SI preserved)
; -----------------------------------------------------------------------------
pl_strlen:
    push si
    xor ax, ax
.lp:
    cmp byte [si], 0
    je .done
    inc si
    inc ax
    jmp .lp
.done:
    pop si
    ret

; -----------------------------------------------------------------------------
; pl_errname - the current cell's error, by name, into pl_numbuf. Excel's own
; spellings, because they are what a person recognises and what every book
; about spreadsheets prints. An unknown code cannot arise from this app's own
; evaluator, but a file could carry one, so it reads as #ERR rather than
; running off the end of the table.
; -----------------------------------------------------------------------------
pl_errname:
    push ax
    push bx
    push si
    push di
    mov al, [pl_curaux]
    or al, al
    jz .unknown
    cmp al, 7
    ja .unknown
    xor ah, ah
    dec ax
    shl ax, 1
    mov bx, ax
    mov si, [pl_errtab + bx]
    jmp .copy
.unknown:
    mov si, pl_s_err_unk
.copy:
    mov di, pl_numbuf
    call pl_strcpy
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_errcode - in: SI = a NUL-terminated error name; out: AL = its Excel
; ERROR.TYPE number, or 0 if this is not a spelling we write. The inverse of
; pl_errname, and it reads the SAME table, so the two cannot drift apart.
; -----------------------------------------------------------------------------
section PL_MODSEC                      ; 82.16.9
pl_errcode:
    push bx
    push cx
    push si
    push di
    xor cx, cx
.loop:
    cmp cx, 7
    jae .unknown
    mov bx, cx
    shl bx, 1
    mov di, [pl_errtab + bx]
    SHOUT pl_streq
    jc .found
    inc cx
    jmp .loop
.found:
    mov ax, cx
    inc ax
    jmp .out
.unknown:
    xor ax, ax
.out:
    pop di
    pop si
    pop cx
    pop bx
    ret

section .text
pl_errtab:  dw pl_s_err_null, pl_s_err_div0, pl_s_err_value, pl_s_err_ref
            dw pl_s_err_name, pl_s_err_num, pl_s_err_na
pl_s_err_null:  db '#NULL!', 0
pl_s_err_div0:  db '#DIV/0!', 0
pl_s_err_value: db '#VALUE!', 0
pl_s_err_ref:   db '#REF!', 0
pl_s_err_name:  db '#NAME?', 0
pl_s_err_num:   db '#NUM!', 0
pl_s_err_na:    db '#N/A', 0
pl_s_err_unk:   db '#ERR', 0

; =============================================================================
; NUMBER FORMAT CODES (81.55) - Excel 2.1d's twenty-one built-ins, in its own
; order (which is the BIFF built-in id, and the position a BIFF2 cell names),
; and ONE engine that draws a value by any code: the grid through a cell's
; format, TEXT() through the code it is handed. It was two: pl_numfmt knew four
; formats and TEXT() knew '$', ',', '0', '#', '.' and '%', and neither knew a
; date - DATE() and NOW() answered correctly and showed a serial number.
; =============================================================================
; =============================================================================
; NUMBER FORMATS (81.75): THREE, and no interpreter.
;
; What stood here was an Excel FORMAT-CODE interpreter - `$#,##0.00 ;($#,##0)`,
; `m/d/yy`, `h:mm AM/PM` - walking a code string section by section, with the
; twenty-one built-in codes, the month and weekday name tables, a date
; serial-to-calendar conversion and a scientific-notation path. It was there
; because 81.55 offered Excel's twenty-one formats out of a scrolling list and
; a side table to hold the ones the format byte could not name.
;
; PLAN offers three, so there is nothing to interpret:
;
;   NUMBER    what the value is, up to four places, trailing zeros trimmed.
;             fx_ftoa's own General, and no decoration at all
;   TEXT      the same characters, but LEFT-aligned - which is the whole of
;             what Excel's @ means for a cell that holds a number
;   CURRENCY  a '$', thousands separators and exactly two places, with a
;             negative in parentheses as Excel's own built-in id 5 has it
;
; pl_group3 and pl_dollar_ins already existed and do the decorating; they live
; up beside pl_ftoa's other helpers rather than in here, which is why they
; survived the interpreter going.
; =============================================================================
PL_NF_NUMBER   equ 0                 ; the 2-bit field in the format byte
PL_NF_TEXT     equ 1
PL_NF_CURRENCY equ 2

; -----------------------------------------------------------------------------
; pl_numfmt - in: pl_acc = the value, BL = the cell's format byte; writes the
; display text into pl_numbuf. BH is ignored and kept only so that the one
; caller needs no edit.
; -----------------------------------------------------------------------------
pl_numfmt:
    push ax
    push bx
    push cx
    push si
    push di
    mov al, bl
    and al, PL_FMT_NUM_MASK
    mov cl, PL_FMT_NUM_SHIFT
    shr al, cl
    mov di, pl_numbuf
    cmp al, PL_NF_CURRENCY
    je .currency
    call pl_acc_load_a                 ; NUMBER and TEXT are the same string:
    mov ax, 10                         ; General. They differ in ALIGNMENT,
    SHOUT fx_ftoa                      ; which pl_justify reads from the same
    jmp short .out                     ; byte
.currency:
    call pl_acc_load_a
    test byte [pl_acc+3], 0x80         ; the magnitude is what gets decorated;
    pushf                              ; the sign becomes parentheses
    call pl_acc_abs
    call pl_acc_load_a
    mov ax, 2                          ; exactly two places, as money is
    SHOUT fx_ftoa
    call pl_group3
    call pl_dollar_ins
    popf
    jz .out
    call pl_parens
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_parens - wrap pl_numbuf in '(' and ')', which is how Excel's Currency
; shows a negative. Every register preserved.
; -----------------------------------------------------------------------------
pl_parens:
    push ax
    push cx
    push si
    push di
    mov si, pl_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .have
    inc si
    inc cx
    jmp short .len
.have:
    cmp cx, PL_NUMBUF_MAX - 3          ; no room for both: leave it plain
    jae .out
    mov di, si
    inc di
    mov byte [di+1], 0                 ; shift the whole string one right,
    mov byte [di], ')'                 ; from the far end back
.shift:
    dec si
    dec di
    mov al, [si]
    mov [di], al
    or cx, cx
    jz .opened
    dec cx
    jmp short .shift
.opened:
    mov byte [pl_numbuf], '('
.out:
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_drawunderline - in: CX=cell text x (left edge, as passed to
; OSAPI_FONT_RUN), DX=cell text y (top); reads pl_numbuf (the UNPADDED
; decorated text - not pl_tbuf, which carries alignment padding) and
; [pl_curfmt] to underline exactly the text's own extent, not the whole
; cell, positioned by the same alignment the text itself used.
; -----------------------------------------------------------------------------
pl_drawunderline:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [pl_ulx], cx
    mov [pl_uly], dx
    mov si, pl_numbuf
    call pl_strlen                    ; ax = text length (chars)
    mov bx, ax                        ; bx = length (chars)
    mov ax, [pl_cellch]
    sub ax, bx
    jns .padok
    xor ax, ax
.padok:                                ; ax = total pad chars
    mov dl, [pl_curfmt]
    and dl, PL_FMT_ALIGN_MASK
    mov cl, PL_FMT_ALIGN_SHIFT
    shr dl, cl                         ; dl = align code
    cmp dl, PL_FMT_ALIGN_LEFT
    je .lp0
    cmp dl, PL_FMT_ALIGN_CENTER
    je .lphalf
    mov di, ax                         ; General/Right: full pad on the left
    jmp .havelp
.lp0:
    xor di, di
    jmp .havelp
.lphalf:
    shr ax, 1
    mov di, ax
.havelp:                               ; di = left-pad chars
    shl di, 1
    shl di, 1
    shl di, 1                          ; di = left-pad pixels (*8)
    shl bx, 1
    shl bx, 1
    shl bx, 1                          ; bx = text width pixels (*8)
    mov ax, [pl_ulx]
    add ax, di                         ; ax = underline x1
    mov cx, ax
    add cx, bx
    dec cx                             ; cx = underline x2
    mov bx, [pl_uly]
    add bx, 9                          ; a couple px below the 8px glyph row
    mov dx, bx
    call OSAPI_GFX_FILL                ; AX=x1, BX=y1, CX=x2, DX=y2
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; pl_strcpy - copy a NUL-terminated string, SI->DI, including the NUL
pl_strcpy:
    push ax
.loop:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .loop
    pop ax
    ret

; pl_strcpy_to_di - append a NUL-terminated string at the DI cursor,
; advancing DI to the new NUL (so successive calls concatenate)
pl_strcpy_to_di:
    push ax
.loop:
    mov al, [si]
    or al, al
    jz .term
    mov [di], al
    inc si
    inc di
    jmp .loop
.term:
    mov byte [di], 0
    pop ax
    ret

; =============================================================================
; Window template, menu, strings
; =============================================================================
pl_tpl:
    dw 60, 40, 560, 380
    dw pl_ttl, pl_paint, pl_onkey, pl_onclick

; The EMPTY kernel menu set (SPEC.md 12.2), same idea as apps/word/word.asm's
; wd_menus0: zero real menus, but its AM_NAME still puts 'Sheet' in the
; kernel bar. pl_mf_ret can never actually be called (there is nothing to
; pick) - it only satisfies the macro's layout.
    OS88_MENUSET pl_menus, pl_s_appname, pl_mf_ret
    OS88_MENUSET_END pl_menus
pl_mf_ret:
    ret

; pl_mtab - Sheet's own in-window menu bar (see the PL_MBAR_H section
; comment). Each entry: title string ptr, item string-ptr array, item
; count (word each, so 6 bytes/entry) - menu index 0..PL_MENU_N-1 is this
; array's own order, which pl_mfire's dispatch and pl_docmd_sortcol/
; pl_docmd_options/pl_docmd_help all key off directly.
; Stage 3.0b puts FORMULA at index 2, which is where Excel 2.1d has it -
; File Edit Formula Format Data Options Macro Window Help. Sheet's own
; multi-sheet menu stands in for Window and now sits where Window does, after
; Macro. Every index below 2 is unchanged and everything above it shifted, so
; pl_mfire's dispatch chain moved with it; nothing else in this file keys off a
; menu index (the macro language names commands, not menu positions), which is
; what made the renumber safe to do at all.
pl_mtab:
    dw pl_m_file,    pl_i_file,    4
    dw pl_m_edit,    pl_i_edit,    6
    dw pl_m_format,  pl_i_format,  4
    dw pl_m_options, pl_i_options, 4

; Excel 2.1d's Formula menu, in its own order: Paste Name.../Paste Function.../
; Reference/Define Name.../Note.../Goto.../Find... - all seven now. The note
; this replaced said the rest would arrive with the features behind them rather
; than as items that open nothing, and that is what happened: the list dialog
; is what Paste Name and Paste Function were waiting on, the name table is what
; Define Name needed, and Reference had nowhere to show its answer until the
; reference box existed.
; 81.75: Reference is an OPTIONS item now. The Formula menu held Paste Name,
; Paste Function, Define Name, Note, Goto and Find, and every one of them has
; gone - a menu with one toggle left in it is not a menu.
pl_it_ref_a1:    db 'Reference: A1', 0     ; the same relabel-by-repointing
pl_it_ref_rc:    db 'Reference: R1C1', 0   ; the Options toggles use

; 81.75: the window title and the kernel menu bar's AM_NAME. The PACKAGE name
; in OS88_HEADER is PLAN; these two are what the user reads, so they have to
; agree with it - a window captioned "Sheet" launched from PLAN.O88 is two
; things answering to one name, which is the rule (73.12) this build exists
; to keep on the right side of.
pl_ttl:        db 'Plan', 0
pl_s_appname:  db 'Plan', 0
pl_m_file:     db 'File', 0
pl_i_file:     dw pl_it_new, pl_it_open, pl_it_save, pl_it_saveas
pl_it_new:     db 'New...', 0
pl_it_open:    db 'Open...', 0
pl_it_save:    db 'Save', 0
pl_it_saveas:  db 'Save As...', 0
pl_s_sheetpfx: db 'Sheet', 0
pl_s_protdoc:  db 'The document is protected.', 0

; Stage 1.8/2.x: matches real Excel 2.0/2.1's own Format menu shape
; (LIBRARY/documentation/screenshots/excel/menu_format.png) -
; Number.../Alignment.../Font... open
; dialogs (pl_docmd_format's AL 0/1/2 is pl_fdlg_open's own kind number, so
; this array's first 3 entries must stay in that order). Border... is real
; (pl_bdlg_*). Row Height.../Column Width... are real too and take A TYPED
; NUMBER: PL_ID_ROWH/PL_ID_COLW through pl_idlg_open, in CHARACTERS for the
; width because that is Excel's own unit, range-checked PL_CW_MINCH..MAXCH.
;
; This said "a 3-preset radio pick ... since this app has no text-input widget
; at the app level" until 2026-09-03, and stage 3.0c had replaced both halves
; of that long before: os88line.inc gave the app a text field and
; pl_docmd_format says so in its own comment two screens up ("a typed number
; now, not the 3-preset radio pick this had to be while no text field
; existed"). Read as current it understates the app by a whole feature, and it
; did - it is where the claim "Column Width is three presets" in an assessment
; of what SHEET still lacks came from.
;
; The other half - that it applied to the WHOLE sheet - went too: 81.56 made
; the widths per column and 81.60 the heights per row, the height in POINTS
; because that is Excel's unit for it. pl_gridhit walks both now.
pl_m_format:    db 'Format', 0
; LIBRARY/documentation/screenshots/excel/menu_format_full.png:
; Number/Alignment/Font/Border/CELL PROTECTION/Row Height/Column
; Width/Justify. Cell Protection sits between
; Border and Row Height, which is not where it would have been guessed.
pl_i_format:    dw pl_it_fnum, pl_it_falign, pl_it_ffont, pl_it_fcolw
pl_it_fnum:      db 'Number...', 0
pl_it_falign:    db 'Alignment...', 0
pl_it_ffont:     db 'Font...', 0
pl_it_fcolw:     db 'Column Width...', 0

; Stage 2.0: the Sheet menu switches which of this instance's PL_SHEETS
; grids is active (see the multi-sheet cell-record comment above
; pl_findcell for why this lives in one instance rather than several).
; Sheet names are the fixed strings below, not user-renameable in this
; stage - simpler, and a macro's "SheetN!" reference (see pl_pident) needs
; a name it can recognize regardless of what the user might have typed.
; ...and the same four with the mark, which pl_sheetmark repoints between.

; Stage 2.0: no generic text-prompt dialog exists in this OS (only a FILE
; picker), so "Run" starts a macro at whatever cell is CURRENTLY SELECTED,
; rather than asking for a typed/picked starting reference - see the
; Macro engine section comment for the full reasoning.
; Excel's own Macro menu is Record.../Run.../Start Recorder/Set Recorder/
; Relative Record. 81.74 adds three of the four it was missing; Start
; Recorder and Resume are that section's own documented shortfalls.

; Edit - "Can't Undo" is a real Excel item with no real implementation
; behind it (no undo system exists) - shown disabled (MENU_DIS) rather than
; omitted, same honesty as Format's Border/Row Height/Column Width
; placeholders. Sort Column now lives in its own Data menu (below) - it
; only had to share Edit's list while the bar was the kernel's own
; MENU_APPMAX=5 one; Sheet's own in-window bar (pl_mtab) has no such cap.
; PL_MENU_CHK is Sheet's own leading-byte convention beside the kernel's
; MENU_DIS: the item is drawn with a check in the left margin. It is 2 rather
; than 1 so the two can never be confused, and pl_mdrop_draw handles both.
pl_m_edit:     db 'Edit', 0
; READ OFF THE REAL MENU
; (LIBRARY/documentation/screenshots/excel/menu_edit_full.png, and the
; Reference Guide's own picture of it on p.117): Can't Undo / Can't Repeat /
; Cut / Copy / Paste / Clear... / Paste Special... / Paste Link / Delete... /
; Insert... / Fill Right / Fill Down. PASTE SPECIAL AND PASTE LINK COME
; AFTER CLEAR, not after Paste, which is where they would have gone from
; memory.
; 81.75: six items, and the indices of those six are UNCHANGED - Paste
; Special, Paste Link, Delete..., Insert..., Fill Right and Fill Down all sat
; above them, so cutting the tail renumbers nothing.
pl_i_edit:     dw pl_it_undo, pl_it_repeat, pl_it_cut, pl_it_copy, pl_it_paste, pl_it_clear
pl_it_undo:    db MENU_DIS, "Can't Undo", 0     ; REWRITTEN by pl_undo_label
               times 10 db 0                      ; (81.57): "Undo Paste Special"
                                                  ; and its NUL fit the slack
pl_it_repeat:  db MENU_DIS, "Can't Repeat", 0
pl_it_cut:     db 'Cut', 0
pl_it_copy:    db 'Copy', 0
pl_it_paste:   db 'Paste', 0
pl_it_clear:   db 'Clear...', 0


; Options - Display toggles (stage 2.x). Each item's own string SWAPS
; between an On/Off pair (same relabel-by-repointing idea MENU_DIS's own
; doc shows) rather than drawing a separate checkmark glyph.
pl_m_options:  db 'Options', 0
; Real Excel's Options menu puts Protect Document... between Display... and
; Calculation...
; (LIBRARY/documentation/screenshots/excel/menu_options_full.png). Gridlines
; and Formulas are items here where Excel keeps them inside Display... - that
; divergence is 81.31's, not this one's.
pl_i_options:  dw pl_it_grid_off, pl_it_form_off, pl_it_calc, pl_it_ref_a1
pl_it_grid_on:  db 'Gridlines: On', 0
pl_it_grid_off: db 'Gridlines: Off', 0
pl_it_form_on:  db 'Formulas: On', 0
pl_it_form_off: db 'Formulas: Off', 0
pl_it_calc:     db 'Calculation...', 0
pl_it_frz_off:  db 'Freeze Panes', 0     ; 81.70, relabelled like the three
pl_it_frz_on:   db 'Unfreeze Panes', 0   ; toggles above rather than ticked
pl_s_frz_at_a1: db 'Select below or right of the split first.', 0

; Help
; --- the About card's lines (SPEC.md 20.5.1) ----------------------------------
pl_ablines:
    dw pl_ab1, pl_ab2, pl_ab3, pl_ab4, 0
pl_ab1:        db 'Sheet for os8088', 0
pl_ab2:        db 'A spreadsheet in the shape of Excel 2.1d', 0
pl_ab3:        db 0
pl_ab4:        db 'Contributed by Koriban', 0

pl_defname:    db 'SHEET1.SLK', 0
pl_s_ready:    db 'Ready', 0
pl_s_badparen: db 'Unbalanced ( ) - kept as text.', 0
pl_s_num:      db 'NUM', 0
pl_s_calcind:  db 'CALCULATE', 0
pl_s_nw_sheet: db 'New worksheet.', 0
pl_s_nw_chart: db 'New sheet - use Data > Chart Column to chart it.', 0
pl_s_nw_macro: db 'New sheet - Macro > Run reads commands from cells.', 0
pl_s_calc_auto: db 'Calculation: Automatic', 0
pl_s_calc_man:  db 'Calculation: Manual - Calculate Now to recompute.', 0
pl_s_calc_now:  db 'Recalculated.', 0
pl_s_id:       db 'ID;PWXL;N;E', 13, 10, 0
pl_s_c:        db 'C;X', 0
pl_s_y:        db ';Y', 0
pl_s_e:        db ';E', 0                  ; the expression field (stage 4.x)
pl_s_k:        db ';K', 0                  ; also the "commas are set" flag
                                            ; on an F record (stage 1.6)
pl_s_sylk_fw:  db 'F;W', 0                 ; F;W<first> <last> <width> (81.56)
pl_s_sylk_fx:  db 'F;X', 0                 ; an F (formatting) record -
pl_s_sylk_ff:  db ';F', 0                  ; stage 1.6's real SYLK support
pl_s_crlf:     db 13, 10, 0
pl_s_r:        db 'R', 0
pl_s_cu:       db 'C', 0
pl_s_end:      db 'E', 13, 10, 0
pl_m_saved:    db 'Saved', 0
pl_m_trunc:    db 'Saved - TRUNCATED; sheet too large for this format.', 0
pl_m_loaded:   db 'Loaded', 0
pl_f_sum:      db 'SUM', 0
pl_f_average:  db 'AVERAGE', 0
pl_f_min:      db 'MIN', 0
pl_f_max:      db 'MAX', 0
pl_f_count:    db 'COUNT', 0
pl_f_if:       db 'IF', 0
pl_f_not:      db 'NOT', 0
pl_f_abs:      db 'ABS', 0
pl_f_and:      db 'AND', 0
pl_f_or:       db 'OR', 0
; stage 3.0d. ORDER IS THE ID - pl_functab below indexes by position and
; pl_pfunc/pl_foldvalue/pl_pspecial switch on that number, so entries may be
; APPENDED but never reordered or removed.
pl_f_product:  db 'PRODUCT', 0
pl_f_counta:   db 'COUNTA', 0
pl_f_mod:      db 'MOD', 0
pl_f_int:      db 'INT', 0
pl_f_trunc:    db 'TRUNC', 0
pl_f_sign:     db 'SIGN', 0
pl_f_fact:     db 'FACT', 0
pl_f_sqrt:     db 'SQRT', 0
pl_f_power:    db 'POWER', 0
pl_f_round:    db 'ROUND', 0
pl_f_true:     db 'TRUE', 0
pl_f_false:    db 'FALSE', 0
pl_f_row:      db 'ROW', 0
pl_f_column:   db 'COLUMN', 0
pl_f_choose:   db 'CHOOSE', 0
; stage 4.5: the INFORMATION functions. Absent until now because an argument
; was folded to a value before the function saw it - see pl_pargclass.
pl_f_isblank:  db 'ISBLANK', 0
pl_f_isnumber: db 'ISNUMBER', 0
pl_f_istext:   db 'ISTEXT', 0
pl_f_islogicl: db 'ISLOGICAL', 0
pl_f_iserror:  db 'ISERROR', 0
pl_f_iserr:    db 'ISERR', 0
pl_f_isna:     db 'ISNA', 0
pl_f_isref:    db 'ISREF', 0
pl_f_na:       db 'NA', 0
pl_f_type:     db 'TYPE', 0
pl_f_n:        db 'N', 0
pl_f_errtype:  db 'ERROR.TYPE', 0     ; the only name here with a '.' in it,
                                       ; which is what pl_pident's .trydot is
                                       ; for
; stage 4.5: the TEXT functions - Excel 2.1's own category, less the seven
; that search and format
; stage 4.5: the DATE and TIME functions. NOW() is absent and pl_pdate's
; header says why - no kernel call publishes the calendar date.
pl_f_date:     db 'DATE', 0
pl_f_day:      db 'DAY', 0
pl_f_month:    db 'MONTH', 0
pl_f_year:     db 'YEAR', 0
pl_f_weekday:  db 'WEEKDAY', 0
pl_f_time:     db 'TIME', 0
pl_f_hour:     db 'HOUR', 0
pl_f_minute:   db 'MINUTE', 0
pl_f_second:   db 'SECOND', 0
pl_f_datevalue: db 'DATEVALUE', 0
pl_f_timevalue: db 'TIMEVALUE', 0
pl_f_now:      db 'NOW', 0
pl_f_isnontext: db 'ISNONTEXT', 0
pl_f_rand:     db 'RAND', 0
pl_f_indirect: db 'INDIRECT', 0
pl_f_rows:      db 'ROWS', 0
pl_f_columns:   db 'COLUMNS', 0
pl_f_areas:     db 'AREAS', 0
pl_f_index:     db 'INDEX', 0
pl_f_match:     db 'MATCH', 0
pl_f_vlookup:   db 'VLOOKUP', 0
pl_f_hlookup:   db 'HLOOKUP', 0
pl_f_lookup:    db 'LOOKUP', 0
pl_f_var:       db 'VAR', 0
pl_f_varp:      db 'VARP', 0
pl_f_stdev:     db 'STDEV', 0
pl_f_stdevp:    db 'STDEVP', 0
; 81.65: the DATABASE functions, in the same order pl_db_foldkind reads them
; 81.67: the ARRAY/MATRIX functions
pl_dt_mlen:    db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
pl_snull:      db 0                   ; pl_sslot's answer for a read below the
                                       ; bottom of the string stack

; pl_functab - the id is the INDEX. 0 terminates.
; 81.75: A NAME NOTHING CAN ANSWER POINTS AT AN EMPTY STRING. An id is this
; table's own index, so an entry cannot be removed without renumbering every
; family after it - but the NAME can go, and pl_funcid compares typed
; identifiers, which are never empty, so pl_fgone can never match. That is
; every name of the seven families whose bodies are cut, at the cost of one
; byte shared between them.
pl_fgone:     db 0
pl_functab:
    dw pl_f_sum, pl_f_average, pl_f_min, pl_f_max, pl_f_count
    dw pl_f_if, pl_f_not, pl_f_abs, pl_f_and, pl_f_or
    dw pl_f_product, pl_f_counta, pl_f_mod, pl_f_int, pl_f_trunc
    dw pl_f_sign, pl_f_fact, pl_f_sqrt, pl_f_power, pl_f_round
    dw pl_f_true, pl_f_false, pl_f_row, pl_f_column, pl_f_choose
    dw pl_f_isblank, pl_f_isnumber, pl_f_istext, pl_f_islogicl, pl_f_iserror
    dw pl_f_iserr, pl_f_isna, pl_f_isref, pl_f_na, pl_f_type
    dw pl_f_n, pl_f_errtype
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone
    dw pl_f_date, pl_f_day, pl_f_month, pl_f_year, pl_f_weekday
    dw pl_f_time, pl_f_hour, pl_f_minute, pl_f_second, pl_f_datevalue
    dw pl_f_timevalue
    dw pl_f_rows, pl_f_columns, pl_f_areas, pl_f_index
    dw pl_f_match, pl_f_vlookup, pl_f_hlookup, pl_f_lookup
    dw pl_f_var, pl_f_varp, pl_f_stdev, pl_f_stdevp
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone
    dw pl_fgone, pl_fgone
    dw pl_f_now                       ; 106 (81.42)
    dw pl_f_isnontext, pl_fgone, pl_f_rand   ; 107 108 109 (81.43)
    dw pl_f_indirect                  ; 110 (81.44)
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone ; 111- :
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone  ; the
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone     ; MACRO
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone     ; (81.63)
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone ; 131- :
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone, pl_fgone ; the
    dw pl_fgone                                                    ; DATABASE
                                                                      ; functions (81.65)
    dw pl_fgone                      ; 142 (81.66)
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone        ; 143- :
    dw pl_fgone, pl_fgone, pl_fgone, pl_fgone              ; ARRAY/
                                                                      ; MATRIX (81.67)
    dw 0
pl_functab_end:
; -----------------------------------------------------------------------------
; FOUR TABLES INDEXED BY THE SAME NUMBER, and nothing used to check they were
; the same length. pl_rpn_func indexes pl_rpn_fid and pl_rpn_fvar by the id
; pl_funcid returns, which is a position in pl_functab - so appending a
; function here and forgetting one of the other two reads whatever byte
; follows it and writes THAT as the BIFF function index. A wrong number in a
; saved file, no crash, no message. These four TIMES lines make it a build
; error instead, the same idiom OS88_BSS's literal uses; read the LINE NUMBER
; to see which table is short.
; -----------------------------------------------------------------------------
%define PL_NFUNCS ((pl_functab_end - pl_functab) / 2 - 1)
pl_s_errpfx:   db 'Err ', 0
section PL_MODSEC                      ; 82.16.9's tenant: CSV and TXT (81.40)

; =============================================================================
; CSV and TAB-DELIMITED TEXT (81.40).
;
; Excel 2.0's own open/save list (Reference Guide p.273) is .XLS/.XLC/.XLM/.XLW,
; .TXT, .CSV, .SLK, .WKS, .WK1, .DIF and .DBF - so these two are not an
; extension of the era's Excel, they are two of the nine it had and this app
; did not. They are ONE writer and ONE reader with a delimiter in [pl_sepch],
; because the only difference between them is that byte.
;
; QUOTING IS CSV'S, NOT DIF'S. A field carrying the delimiter, a quote, a CR
; or an LF is wrapped in quotes and its own quotes are doubled - the same rule
; SYLK uses for ';' (81.38.1) and the one that makes a field with a comma in it
; survive. DIF drops an embedded quote instead (see pl_dowrite_dif's .dt),
; which is right for DIF because DIF has no escape at all; CSV does.
; =============================================================================

section .text

section PL_MODSEC
pl_dowrite_csv:
    mov byte [pl_sepch], ','
    jmp pl_dowrite_sep
pl_dowrite_txt:
    mov byte [pl_sepch], 9
    jmp pl_dowrite_sep

pl_dowrite_sep:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    call plm_difbbox                  ; the module's own copy (82.16.9)
    mov byte [pl_trunc], 0
    mov es, [pl_stgseg]
    xor di, di
    mov word [pl_wrow], 0
.rloop:
    mov ax, [pl_wrow]
    cmp ax, [pl_bbrow]
    ja .footer
    mov word [pl_wcol], 0
.cloop:
    mov ax, [pl_wcol]
    cmp ax, [pl_bbcol]
    ja .rnext
    mov ax, di
    add ax, PL_EDITMAX + 8            ; the widest a field can get: a label,
    cmp ax, PL_STAGE_MAX              ; its quotes, and the delimiter
    ja .truncf
    cmp word [pl_wcol], 0
    je .nosep
    mov al, [pl_sepch]
    call pl_stgputb
.nosep:
    mov ax, [pl_wcol]
    mov bx, [pl_wrow]
    SHOUT pl_getcell2
    jnc .cnext                        ; an empty cell is an EMPTY FIELD, not a
    cmp byte [pl_curtype], PL_T_TEXT  ; zero - the delimiters still count it
    je .ctext
    cmp byte [pl_curtype], PL_T_ERR
    je .cerr
    cmp byte [pl_curtype], PL_T_BOOL  ; a LOGICAL goes out as its name, which
    je .cbool                         ; is how it reads back in, too (81.51)
    push si
    push di
    mov si, pl_acc                    ; a FULL DECIMAL, the lesson
    SHOUT fx_unpack_a                 ; pl_dowrite_dif learned the hard way
    mov di, pl_numbuf
    mov ax, 10
    SHOUT fx_ftoa
    pop di
    pop si
    mov si, pl_numbuf
    call pl_stgput
    jmp .cnext
.cbool:
    mov ax, [pl_acc]
    SHOUT pl_boolname
    jmp short .cname
.cerr:
    SHOUT pl_errname                  ; -> pl_numbuf, the error's own spelling
.cname:
    mov si, pl_numbuf
    call pl_stgput
    jmp .cnext
.ctext:
    call pl_sep_needq
    jnc .ctplain
    mov al, 34
    call pl_stgputb
    mov si, [pl_curtoff]
.ctq:
    push es
    mov es, [pl_txtseg]
    mov al, [es:si]
    pop es
    or al, al
    jz .ctqend
    inc si
    cmp al, 34
    jne .ctq1
    call pl_stgputb                   ; an embedded quote is DOUBLED
.ctq1:
    call pl_stgputb
    jmp .ctq
.ctqend:
    mov al, 34
    call pl_stgputb
    jmp .cnext
.ctplain:
    mov si, [pl_curtoff]
.ctp:
    push es
    mov es, [pl_txtseg]
    mov al, [es:si]
    pop es
    or al, al
    jz .cnext
    inc si
    call pl_stgputb
    jmp .ctp
.cnext:
    inc word [pl_wcol]
    jmp .cloop
.rnext:
    mov si, pl_s_crlf
    call pl_stgput
    inc word [pl_wrow]
    jmp .rloop
.truncf:
    mov byte [pl_trunc], 1
.footer:
    mov [pl_stagelen], di
    mov ax, [pl_stgseg]
    mov es, ax
    xor bx, bx
    mov cx, [pl_stagelen]
    xor dx, dx
    mov si, pl_name
    call OSAPI_FILE_WRITE
    jc .werr
    mov word [pl_msg], pl_m_saved
    cmp byte [pl_trunc], 0
    je .wdone
    mov word [pl_msg], pl_m_trunc
    jmp .wdone
.werr:
    call pl_setferr                   ; module-local: 82.16.9 absorbed it
.wdone:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_sep_needq - does the current cell's label need quoting? out: CF=1 if so.
; Preserves everything else.
; -----------------------------------------------------------------------------
pl_sep_needq:
    push ax
    push si
    push es
    mov si, [pl_curtoff]
    mov es, [pl_txtseg]
.l:
    mov al, [es:si]
    or al, al
    jz .no
    inc si
    cmp al, [pl_sepch]                ; [pl_sepch] is DS-relative and DS is
    je .yes                           ; still the package - only ES moved
    cmp al, 34
    je .yes
    cmp al, 13
    je .yes
    cmp al, 10
    je .yes
    jmp .l
.yes:
    pop es
    pop si
    pop ax
    stc
    ret
.no:
    pop es
    pop si
    pop ax
    clc
    ret

; -----------------------------------------------------------------------------
; pl_doread_csv / _txt - read [pl_name], replacing the sheet.
; -----------------------------------------------------------------------------
pl_doread_csv:
    mov byte [pl_sepch], ','
    jmp pl_doread_sep
pl_doread_txt:
    mov byte [pl_sepch], 9
    jmp pl_doread_sep

pl_doread_sep:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, [pl_stgseg]
    xor bx, bx
    mov cx, PL_STAGE_MAX
    xor dx, dx
    mov si, pl_name
    call OSAPI_FILE_READ
    jc .rerr
    mov word [pl_ncells], 0
    mov word [pl_txtlen], 0           ; "replacing the sheet", the same three
    mov word [pl_nbord], 0            ; pl_doread_dif clears
    mov word [pl_nnote], 0
    SHOUT pl_colw_clear                ; ...and every column's width (81.56)
    mov es, [pl_stgseg]
    mov [pl_sepend], ax               ; the end, for pl_sep_field
    xor si, si
    mov word [pl_wrow], 0
.rowloop:
    cmp si, [pl_sepend]
    jae .done
    cmp word [pl_wrow], PL_ROWS
    jae .done
    mov word [pl_wcol], 0
.fieldloop:
    call pl_sep_field                 ; -> pl_rwsrc; SI at the terminator
    call pl_sep_store
    inc word [pl_wcol]
    cmp si, [pl_sepend]
    jae .done
    mov al, [es:si]
    cmp al, [pl_sepch]
    jne .eol
    inc si                            ; past the delimiter
    mov ax, [pl_wcol]
    cmp ax, PL_COLS
    jae .eol                          ; past the last column: drop the rest
    jmp .fieldloop
.eol:
    cmp si, [pl_sepend]
    jae .done
    mov al, [es:si]
    cmp al, 13
    je .eat
    cmp al, 10
    je .eat
    inc si                            ; anything else past the last column
    jmp .eol
.eat:
    inc si
    cmp si, [pl_sepend]
    jae .done
    mov al, [es:si]
    cmp al, 13
    je .eat
    cmp al, 10
    je .eat
    inc word [pl_wrow]
    jmp .rowloop
.done:
    mov word [pl_msg], pl_m_loaded
    jmp .rdone
.rerr:
    call pl_setferr                   ; module-local: 82.16.9 absorbed it
.rdone:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_sep_field - one field at ES:SI into pl_rwsrc, NUL-terminated. SI is left
; AT the terminator (the delimiter, a CR/LF or [pl_sepend]) and never past it,
; so the caller decides what the terminator means.
; -----------------------------------------------------------------------------
pl_sep_field:
    push ax
    push cx
    push di
    mov di, pl_rwsrc
    mov cx, PL_EDITMAX
    cmp si, [pl_sepend]
    jae .end
    cmp byte [es:si], 34
    jne .plain
    inc si
.q:
    cmp si, [pl_sepend]
    jae .end
    mov al, [es:si]
    inc si
    cmp al, 34
    jne .qkeep
    cmp si, [pl_sepend]
    jae .end
    cmp byte [es:si], 34
    jne .end                          ; a lone quote CLOSES the field
    inc si                            ; a doubled one is a literal quote
.qkeep:
    jcxz .q
    mov [di], al
    inc di
    dec cx
    jmp .q
.plain:
    cmp si, [pl_sepend]
    jae .end
    mov al, [es:si]
    cmp al, [pl_sepch]
    je .end
    cmp al, 13
    je .end
    cmp al, 10
    je .end
    inc si
    jcxz .plain
    mov [di], al
    inc di
    dec cx
    jmp .plain
.end:
    mov byte [di], 0
    pop di
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; pl_sep_store - pl_rwsrc into the cell at [pl_wcol],[pl_wrow].
;
; CSV HAS NO TYPE FIELD, so the field's own spelling decides. fx_atof reports
; CF=1 when there was no number there at all, and SI is left where it stopped -
; so "12abc" is TEXT rather than 12, which is the whole reason the position is
; checked and not just the carry.
; -----------------------------------------------------------------------------
pl_sep_store:
    push ax
    push bx
    push si
    cmp byte [pl_rwsrc], 0
    je .out                           ; an empty field leaves the cell blank
    mov si, pl_rwsrc
    SHOUT fx_atof
    jc .text
    cmp byte [si], 0
    jne .text
    SHOUT pl_acc_store
    mov ax, [pl_wcol]
    mov bx, [pl_wrow]
    SHOUT pl_setvald
    jmp .out
.text:
    mov ax, [pl_wcol]
    mov bx, [pl_wrow]
    mov si, pl_rwsrc
    SHOUT pl_setlabel                 ; a TRUE field is the logical, as Excel
.out:                                 ; reads one (81.51)
    pop si
    pop bx
    pop ax
    ret

section .text

pl_s_ext_sylk: db '.SLK', 0
pl_s_ext_csv:  db '.CSV', 0
pl_s_ext_txt:  db '.TXT', 0

; Stage 2.0's ALERT() needs a real message box; SPEC.md 75.3's os88ui_ask is
; the project's own answer to that (a kernel-resident version was tried and
; measured too costly for every app to pay for - see SPEC.md 75.3).
; Included here, above OS88_BSS, because the
; pl_macro_msg bss field below sizes itself from OS88UI_AMAX, which this
; needs to have already defined.
%define OS88UI_ALERT
%define OS88UI_SCROLL               ; stage 3.0a+: SPEC.md 13.10's shared
                                     ; scroll bar - OPT IN, and without it
                                     ; os88ui_sbar is simply not assembled
%define OS88UI_SBDRAG               ; ...and the thumb-drag half of it
                                     ; shared scroll bar (SPEC.md 13.10.5),
                                     ; which needs W_ONCLICK/W_ONDRAG/
                                     ; W_ONMOUSEUP - Sheet already has the
                                     ; first two for range selection
%define OS88UI_ABOUT                ; ...and the standard About card (20.5.1),
%include "os88ui.inc"                ; which replaced a one-line alert here

; stage 3.0b: the one-line text field, the shared control browser.asm and
; telnet.asm already use. It gives the formula bar's content box a real caret
; and mid-string editing, replacing the append-only in-cell editor this app
; had before. MUST come after os88ui.inc (it uses its UI_* macros) and before
; OS88_BSS, which is os88ui.inc's own placement rule for the same reason.
%include "os88line.inc"

; stage 3.0b: its multi-line sibling, new in this stage and written to the same
; conventions (caller owns the block, passed in SI; no storage of its own).
; First consumer: Formula > Note..., which is Excel 2.1's cell notes and the
; first place in this app where free text can be typed at all.
%include "os88text.inc"

; stage 2.x: Data > Chart Column.../Export Chart as BMP...'s shared
; rasterizer + BMP writer - see that file's own header comment for the
; CH_* constants and ch_* bss words it requires, both declared above
; stage 4.0: the software IEEE-754 double. Included before os88chart.inc for
; no reason other than tidiness - it depends on nothing but the caller's own
; scratch, declared in the bss chain below.
%include "os88fix.inc"      ; 81.75: fixed-point decimal, not a double


; =============================================================================
; bss (loader-zeroed, SPEC.md 21 step 5) - small now: the grid itself lives
; in claimed heap segments, not here.
; =============================================================================
    OS88_BSS 3152                     ; 81.75, PLAN's own and already far from
                                       ; SHEET's: -191 for the ch_* working
                                       ; set, -568 for the vector table that a
                                       ; one-file build has no use for, -4
                                       ; because PL_MENU_N is 7 rather than 9
                                       ; (pl_mw is a word per menu, and both
                                       ; Macro and Data are gone), +2 for
                                       ; pl_planvec. The claim ladder will
                                       ; move it again
    OS88_IMAGE_END

; THE ch_* BLOCK GOES FIRST, at bss offset 0, and that is a requirement and
; not a tidy-up: apps/os88chart.inc is about to become an OVERLAY shared by
; both callers (82.16), the module keeps DS = the package's segment (SPEC.md
; 68.10), so every ch_* reference in it assembles to THIS package's address.
; One binary can serve both only if both put the block at the same offset, and
; offset zero is the only one neither package has to negotiate for.
%define CH_BSS_BASE (os88_image_end + 0)
; 81.75: no chart, no rasterizer, so none of its 191 bytes of working set
; either - and nothing to keep at a fixed offset, because the reason offset
; zero was a REQUIREMENT is that one CHART.OVL served two hosts.
%define CH_BSS_END CH_BSS_BASE

pl_selcol     equ CH_BSS_END
pl_selrow     equ pl_selcol + 2
pl_scrollcol  equ pl_selrow + 2
pl_scrollrow  equ pl_scrollcol + 2
pl_editing    equ pl_scrollrow + 2
pl_editlen    equ pl_editing + 1
pl_editbuf    equ pl_editlen + 1            ; 64: PL_EDITMAX + NUL
pl_name       equ pl_editbuf + 64           ; 13: 8.3 name + NUL
pl_ox         equ pl_name + 13
pl_oy         equ pl_ox + 2
pl_cw         equ pl_oy + 2
pl_ch         equ pl_cw + 2
pl_vcols      equ pl_ch + 2
pl_vrows      equ pl_vcols + 2
pl_freezecol  equ pl_vrows + 2       ; word: Options > Freeze Panes (81.70) -
                                     ; columns 0..pl_freezecol-1 never scroll
pl_freezerow  equ pl_freezecol + 2   ; ...and rows 0..pl_freezerow-1. 0 means
                                     ; no freeze on that axis; pl_scrollcol/
                                     ; row can never fall below these once set
                                     ; scrolling phase's row offset (visible
                                     ; index minus pl_freezerow), named
                                     ; because every other register is
                                     ; already spoken for in that loop
; 81.73: a HIDDEN row or column takes no slot, so the visible slots stopped
; marching in step with the real indices and pl_geom records the mapping it
; actually built. Everything that used to compute it now reads these.
pl_vrc            equ pl_freezerow + 2   ; PL_MAXVC words: slot -> real column
pl_vrr        equ pl_vrc + PL_MAXVC * 2   ; PL_MAXVR words: slot -> real row
pl_geom_rc    equ pl_vrr + PL_MAXVR * 2   ; the walks' own real cursors...
pl_geom_rr    equ pl_geom_rc + 2
                                     ; began, which is what turns a real row
                                     ; into the key the table is streaming
pl_vcl_lo         equ pl_geom_rr + 2  ; pl_vclip's own four
pl_vcl_hi     equ pl_vcl_lo + 2
pl_vcl_a      equ pl_vcl_hi + 2
pl_vcl_b      equ pl_vcl_a + 2
; 81.74's own: the macro recorder. pl_rec_col/row/sheet is where the next
; macro formula goes - Set Recorder's corner, and the SHEET with it, because
; the recording lands on the macro sheet while the user works on theirs.
pl_wcol           equ pl_vcl_b + 2
pl_wrow       equ pl_wcol + 2
pl_selx1      equ pl_wrow + 2
pl_selx2      equ pl_selx1 + 2
pl_sely1      equ pl_selx2 + 2
pl_sely2      equ pl_sely1 + 2
pl_lx1        equ pl_sely2 + 2
pl_lx2        equ pl_lx1 + 2
pl_ly1        equ pl_lx2 + 2
pl_ly2        equ pl_ly1 + 2
pl_trunc      equ pl_ly2 + 2
PL_TCOL       equ pl_trunc + 1
PL_TROW       equ PL_TCOL + 2
PL_TVAL       equ PL_TROW + 2               ; the integer form, still used by
                                             ; the DIF and BIFF readers
PL_TDVAL      equ PL_TVAL + 2               ; 8: SYLK's, as a real double
PL_THASE      equ PL_TDVAL + 8              ; byte: this record had a ;E field
PL_TEXPR      equ PL_THASE + 1              ; PL_EDITMAX+1: its text
PL_TISTXT     equ PL_TEXPR + PL_EDITMAX + 1 ; byte: the ;K field was QUOTED,
                                             ; so PL_TEXPR holds a label
PL_TISERR     equ PL_TISTXT + 1             ; byte: ...or was an ERROR NAME,
PL_THAVE      equ PL_TISERR + 1             ; and which one
PL_TALIGN     equ PL_THAVE + 1             ; pl_parsefrec's own scratch -
PL_TNUMFMT    equ PL_TALIGN + 1            ; an "F" record's parsed
PL_TCOMMA     equ PL_TNUMFMT + 1           ; alignment/number-format/;K
pl_stagelen   equ PL_TCOMMA + 1
pl_tbuf       equ pl_stagelen + 2           ; 96: formula bar text (a formula
                                             ; can run to PL_EDITMAX chars)
pl_colbuf     equ pl_tbuf + 96              ; 4: up to 2 letters + NUL
pl_numbuf     equ pl_colbuf + 4             ; PL_NUMBUF_MAX+1: what all three
                                             ; justifiers read. Ten bytes held
                                             ; the widest DECORATED number
                                             ; ("$-32768", stage 1.6) and that
                                             ; was its whole job until stage
                                             ; 4.5 put LABELS through the same
                                             ; three routines - a label is as
                                             ; wide as the column, and a
                                             ; column runs to PL_CW_MAXCH
pl_msg        equ pl_numbuf + PL_NUMBUF_MAX + 1  ; 2: pointer to a status string
pl_errbuf     equ pl_msg + 2                ; 8: "Err " + up to 2 digits + NUL
pl_cellseg    equ pl_errbuf + 8
pl_txtseg     equ pl_cellseg + 2
pl_stgseg     equ pl_txtseg + 2
pl_bordseg    equ pl_stgseg + 2            ; stage 2.x: the border table's
                                             ; own claim, see PL_CLAIM_BORD_KB
pl_nbord      equ pl_bordseg + 2            ; word: records in pl_bordseg
pl_ncells     equ pl_nbord + 2
pl_txtlen     equ pl_ncells + 2
pl_fcol       equ pl_txtlen + 2             ; pl_findcell's search key stash
pl_frow       equ pl_fcol + 2
pl_wrec_row   equ pl_frow + 2               ; pl_dowrite's per-record stash
pl_wrec_col   equ pl_wrec_row + 2
pl_wrec_val   equ pl_wrec_col + 2
pl_wrec_fmt   equ pl_wrec_val + 2           ; SYLK's and BIFF's writers'
                                             ; stash of the record's format
                                             ; byte (DIF carries no format
                                             ; at all, see pl_dowrite_dif)
pl_newoff     equ pl_wrec_fmt + 1           ; pl_setformula's new text offset
pl_sacc       equ pl_newoff + 2             ; PL_STR_MAX+1: THE STRING HALF of
                                             ; the evaluator's result, the way
                                             ; pl_acc is the numeric half -
                                             ; pl_curtype says which is live
pl_sacc2      equ pl_sacc + PL_STR_MAX + 1  ; PL_STR_MAX+1: '&'s right operand,
                                             ; held while the left comes back off
                                             ; the string stack. It was TWO
                                             ; buffers, the left banked in the
                                             ; first - where a nested '&' in the
                                             ; right overwrote it (81.53)
pl_curaux     equ pl_sacc2 + PL_STR_MAX + 1  ; pl_getcell2's error code
pl_evalerr    equ pl_curaux + 2             ; byte: the error this evaluation
                                             ; ran into, 0 = none. STICKY for
                                             ; the whole of one top-level
                                             ; evaluation, which is what makes
                                             ; propagation free: no operator
                                             ; has to test it
pl_evaldepth  equ pl_evalerr + 2             ; pl_eval_cell's recursion depth
pl_pnest      equ pl_evaldepth + 2           ; live parser recursion points -
                                             ; pl_pnest_enter's counter (81.3),
                                             ; balanced so it needs no reset
pl_fbuf       equ pl_pnest + 2              ; PL_EVAL_MAXDEPTH * 64: one
                                             ; formula-text copy per
                                             ; recursion level (see
                                             ; pl_eval_cell), copied out of
                                             ; pl_txtseg so the parser never
                                             ; needs a segment override
pl_ident      equ pl_fbuf + (PL_EVAL_MAXDEPTH * 64) ; PL_NAME_MAX+1: a collected name/column
pl_pxsheet    equ pl_ident + PL_NAME_MAX + 1              ; stage 2.0: a "SheetN!" prefix
                                             ; pl_pident just consumed,
                                             ; 0xFF = none (see pl_psheetpfx)
pl_pcol       equ pl_pxsheet + 1              ; pl_pident's cell-ref column
pl_pfid       equ pl_pcol + 2               ; the function currently parsing:
                                             ; 0 SUM 1 AVERAGE 2 MIN 3 MAX
                                             ; 4 COUNT 0xFF unknown
pl_pacc       equ pl_pfid + 2               ; 8: the running sum / min / max /
                                             ; product, a packed double since
                                             ; stage 4.0 - SUM over a column of
                                             ; decimals has to keep them
pl_pcnt       equ pl_pacc + 8               ; cells folded so far
pl_phave      equ pl_pcnt + 2               ; MIN/MAX has a candidate yet
pl_r1col      equ pl_phave + 2              ; a range's two corners...
pl_r1row      equ pl_r1col + 2
pl_r2col      equ pl_r1row + 2
pl_r2row      equ pl_r2col + 2
pl_ix1col     equ pl_r2row + 2              ; pl_pintersect's SECOND rectangle
pl_ix1row     equ pl_ix1col + 2             ; - it cannot borrow pl_r1col,
pl_ix2col     equ pl_ix1row + 2             ; which is the running result it
pl_ix2row     equ pl_ix2col + 2             ; is reducing
pl_rrow       equ pl_ix2row + 2             ; ...and pl_foldrange's end-of-
                                             ; since the record-array walk)
pl_pass           equ pl_rrow + 2               ; recalculation pass counter
pl_bbrow      equ pl_pass + 2               ; pl_difbbox's used bounding box
pl_bbcol      equ pl_bbrow + 2
pl_curfmt     equ pl_bbcol + 2              ; pl_getcell2's format-byte output
pl_curtype    equ pl_curfmt + 1             ; ...and its PL_T_* tag, and where
pl_curtoff    equ pl_curtype + 1            ; a TEXT cell's characters live
pl_argtype    equ pl_curtoff + 2            ; stage 4.5: pl_pargclass's answer
pl_argaux     equ pl_argtype + 1            ; - what the argument IS, its error
pl_argisref   equ pl_argaux + 1             ; code, and whether it was a bare
pl_refarea    equ pl_argisref + 1           ; reference; pl_pargref's A1:B9 flag
pl_arg1col    equ pl_refarea + 1            ; ...and the reference itself, in
pl_arg1row    equ pl_arg1col + 2            ; FOUR WORDS OF ITS OWN. Sharing
pl_arg2col    equ pl_arg1row + 2            ; pl_r1col/pl_r2col with the range
pl_arg2row    equ pl_arg2col + 2            ; folder overwrote its loop bounds
                                             ; mid-walk - see pl_pargref
pl_sstk_sp    equ pl_arg2row + 2            ; the string stack's depth...
pl_sstk       equ pl_sstk_sp + 2            ; ...and PL_SSTK_N slots of
                                             ; PL_STR_MAX+1 bytes each
pl_fnd_hb     equ pl_sstk + PL_SSTK_N * (PL_STR_MAX + 1)  ; pl_strfind's two
pl_fnd_nd     equ pl_fnd_hb + 2             ; bases: the inner compare needs
                                             ; SI and DI and the outer scan a
                                             ; third pointer, and the 8086
                                             ; addresses memory through four
                                             ; registers of which one is BP
                                             ; In bss because nothing may sit
                                             ; on the stack between pl_vpush
                                             ; and pl_binop_pre
pl_dt_y           equ pl_fnd_nd + 2             ; stage 4.5: a broken-down date,
pl_dt_m       equ pl_dt_y + 2               ; shared by both directions of the
pl_dt_d       equ pl_dt_m + 2               ; serial conversion
pl_dt_ly      equ pl_dt_d + 2               ; pl_isleap's year
pl_dt_ys      equ pl_dt_ly + 2              ; pl_ymd_to_ser's two counters
pl_dt_ms      equ pl_dt_ys + 2
pl_dt_acc     equ pl_dt_ms + 2              ; pl_dt_parse3's running total
pl_dt_min     equ pl_dt_acc + 2             ; pl_dt_hms's minutes since midnight
pl_dt_tmp     equ pl_dt_min + 2             ; 8: one parked double
                                             ; parenthesises it afterwards, so
                                             ; the sign is banked here
pl_jlen           equ pl_dt_tmp + 8             ; pl_cjust's stashed text length
pl_ulx        equ pl_jlen + 2               ; pl_drawunderline's stashed
pl_uly        equ pl_ulx + 2                ; cell text origin (x, y)
                                             ; xf index stash
                                             ; new record's own index)
                                             ; tracked font's bold/underline
                                             ; bits
                                             ; each tracked XF's align|
                                             ; numfmt packed byte
                                             ; each tracked XF's font index
                                             ; each tracked XF's border and
                                             ; protection bits, in THIS app's
                                             ; PL_BORD_*/PL_PROT_* spelling
                                             ; rather than BIFF's (81.47)
                                             ; tracked XF's number format when
                                             ; the format byte cannot hold it -
                                             ; Excel's id plus one, or 0 (81.55)
                                             ; which is its format byte unless
                                             ; it also has a border record

pl_cursheet       equ pl_uly + 2           ; the sheet pl_findcell
                                             ; packs into every search (see
                                             ; the stage 2.0 cell-record
                                             ; comment above pl_findcell)
pl_selsave    equ pl_cursheet + 2           ; PL_SHEETS words each: the
pl_rowsave    equ pl_selsave + (PL_SHEETS*2) ; other 3 sheets' own
pl_sclsave    equ pl_rowsave + (PL_SHEETS*2) ; selection/scroll, saved and
pl_scrsave    equ pl_sclsave + (PL_SHEETS*2) ; restored by pl_switchsheet
pl_fclsave    equ pl_scrsave + (PL_SHEETS*2) ; ...and its FROZEN PANES
pl_frwsave    equ pl_fclsave + (PL_SHEETS*2) ; (81.70), which are per sheet
                                             ; in Excel as the scroll is here

pl_ownwin     equ pl_frwsave + (PL_SHEETS*2) ; our own window ptr, stashed
                                             ; once in pl_entry for
                                             ; os88ui_ask's sake
                                             ; against PL_MACRO_MAXSTEPS
                                             ; formula text, copied out of
                                             ; pl_txtseg the same way
                                             ; pl_eval_cell's pl_fbuf is
pl_macro_msg      equ pl_ownwin + 2 ; OS88UI_AMAX+1: ALERT's
                                             ; string-literal argument

pl_fdlg_win    equ pl_macro_msg + OS88UI_AMAX + 1 ; stage 1.8's Format
                                             ; dialogs: 0 = none, the gate
pl_fdlg_kind   equ pl_fdlg_win + 2          ; byte: 0 Number/1 Align/2 Font
pl_fdlg_sel    equ pl_fdlg_kind + 1         ; word: the selected radio 0-3
pl_fdlg_ox     equ pl_fdlg_sel + 2          ; this paint's content origin,
pl_fdlg_oy     equ pl_fdlg_ox + 2           ; stashed across widget calls
pl_fdlg_itemsptr equ pl_fdlg_oy + 2         ; this dialog's 4-item label
                                             ; array, for the row loop
pl_fdlg_rowidx equ pl_fdlg_itemsptr + 2     ; the row loop's own index
pl_fdlg_rowy   equ pl_fdlg_rowidx + 2       ; ...and that row's y
pl_fdlg_rect   equ pl_fdlg_rowy + 2         ; 4 words: one button rect,
                                             ; reused for OK then Cancel
pl_fdlg_count  equ pl_fdlg_rect + 8         ; word: this kind's row count
                                             ; (4 for Number/Align/Font, 2
                                             ; for Insert/Delete's Row/
                                             ; Column pick) - see
                                             ; pl_fdlg_counts

; Edit menu (stage 2.x)
pl_clipbuf    equ pl_fdlg_count + 2         ; PL_EDITMAX+1: Copy/Cut build
                                             ; their clipboard text here;
                                             ; Paste goes straight into
                                             ; pl_editbuf instead (see
                                             ; pl_docmd_paste)
pl_rc_op      equ pl_clipbuf + PL_EDITMAX + 1 ; pl_rowcol_op's own working
pl_rc_idx     equ pl_rc_op + 1              ; state - see its header
pl_rc_stgcnt  equ pl_rc_idx + 2             ; comment for what each field
pl_rc_savedsheet equ pl_rc_stgcnt + 2       ; holds; kept here rather than
pl_rc_tsheet  equ pl_rc_savedsheet + 2      ; on the stack purely because
pl_rc_trow    equ pl_rc_tsheet + 2          ; there are enough of them
pl_rc_tcol    equ pl_rc_trow + 2            ; that stack-relative addressing
pl_rc_tflags  equ pl_rc_tcol + 2            ; would be more error-prone
pl_rc_tfmt    equ pl_rc_tflags + 1          ; than a few named bytes
pl_wrec_foff  equ pl_rc_tfmt + 1            ; word: the formula text offset of
                                             ; the cell being written, or FFFF
pl_wrec_dval  equ pl_wrec_foff + 2          ; 8: the SYLK writer's banked value
pl_wrec_type  equ pl_wrec_dval + 8          ; byte: PL_T_* of the cell being
pl_wrec_toff  equ pl_wrec_type + 1          ; written, where its label is, and
pl_wrec_aux       equ pl_wrec_toff + 2      ; byte: and, if it is an ERROR, which
pl_rc_tval        equ pl_wrec_aux + 1           ; 8: a whole double, not a word
pl_rc_tfml    equ pl_rc_tval + 8
pl_rc_ttype   equ pl_rc_tfml + 2            ; byte: PL_C_TYPE in transit
pl_rc_taux    equ pl_rc_ttype + 1           ; byte: ...and PL_C_AUX

                                             ; staged-pair count
                                             ; slots are staged so far
                                             ; row, stashed across the
                                             ; pl_getcell2 call below it
                                             ; whole double since stage 4.5
                                             ; formula cell just staged into
                                             ; against, both in DS because
                                             ; fx_unpack_* read DS:SI and the
                                             ; array lives in pl_stgseg
                                            ; keyed on, which since stage 4.5
                                            ; the dialog picks and which need
                                            ; not be the selection's anchor
pl_calcmanual     equ pl_rc_taux + 1        ; byte: Options > Calculation
pl_mchk         equ pl_calcmanual + 1       ; byte: this dropdown row is the
                                             ; checked one
pl_a1style      equ pl_mchk + 1             ; byte: 0 = A1, 1 = R1C1 - what
                                             ; the reference box and Goto show
pl_nm_tmp         equ pl_a1style + 1     ; word: pl_wr_r1c1 banks the column
                                             ; it is writing here, because the
                                             ; one it is GIVEN can come from a
                                             ; file buffer that the next read
                                             ; overwrites

; Sheet's own in-window menu bar (stage 2.x, see the PL_MBAR_H section
; comment) - pl_goy is the grid's own origin (raw [pl_oy] + PL_MBAR_H);
; everything from pl_mopen down is pl_mtrack/pl_mbar_*/pl_mdrop_*/
; pl_mitem_hit's shared working state.
pl_goy            equ pl_nm_tmp + 2
pl_mopen      equ pl_goy + 2               ; byte: open menu index, PL_M_NONE
pl_mhi        equ pl_mopen + 1             ; byte: hot item in the open
                                             ; dropdown, PL_M_NONE
pl_mrx1       equ pl_mhi + 1               ; the open dropdown's own rect
pl_mry1       equ pl_mrx1 + 2
pl_mrx2       equ pl_mry1 + 2
pl_mry2       equ pl_mrx2 + 2
pl_mbx1       equ pl_mry2 + 2              ; pl_mboxof's own output: one
pl_mbx2       equ pl_mbx1 + 2              ; menu title's screen box
pl_mw         equ pl_mbx2 + 2              ; PL_MENU_N words: each title's
                                             ; pixel width (pl_mtab_calc)
pl_mli        equ pl_mw + (PL_MENU_N*2)    ; generic loop-index scratch,
                                             ; shared by every pl_m* routine
                                             ; above (none of them nest)
pl_mto        equ pl_mli + 2               ; generic pl_mtab byte-offset
                                             ; scratch, same sharing rule
pl_mip        equ pl_mto + 2               ; the open menu's items array ptr
pl_mcnt       equ pl_mip + 2               ; the open menu's item count
pl_mmaxw      equ pl_mcnt + 2              ; pl_mdrop_geo's running max
                                             ; item-label width
pl_mry_row    equ pl_mmaxw + 2             ; pl_mdrop_draw's current row y

pl_gridlines     equ pl_mry_row + 2        ; byte: Options > Gridlines, 1=on
pl_showformulas  equ pl_gridlines + 1      ; byte: Options > Formulas, 1=on

; Border dialog (stage 2.x, pl_bdlg_*) - same "own scratch, not stack
; juggling" shape as pl_fdlg_*'s own bss block above
                                             ; PL_BDLG_B_* bits
                                             ; reused for OK then Cancel

; pl_drawborders' own scratch (stage 2.x) - the four edges' screen rect for
; whichever bordered cell it is currently drawing
                                             ; (not CX - see pl_drawborders)

; stage 2.x: runtime cell dimensions (Format > Column Width.../Row
; Height...) - see the PL_CW_*/PL_RH_* section comment above pl_entry
pl_cellw          equ pl_showformulas + 1              ; word: the drawn column's width, px
pl_cellh       equ pl_cellw + 2            ; word: the drawn row's height, px
pl_cellch      equ pl_cellh + 2            ; word: pl_cellw / 8, in chars
pl_blank       equ pl_cellch + 2           ; PL_CW_MAXCH+1: as many spaces as
                                             ; the WIDEST column the Column
                                             ; Width dialog will accept, plus
                                             ; the NUL (pl_mkblank). It was 11
                                             ; - PL_CW_WIDE/8 plus a NUL, right
                                             ; for the three presets it was
                                             ; written for and wrong the moment
                                             ; a numeric width could be typed:
                                             ; a width of 12 wrote 13 bytes and
                                             ; the two that fell off the end
                                             ; landed on pl_chartseg, one word
                                             ; further down. See 81.21

; Data > Chart Column... (stage 2.x) - a live second window; see the
; PL_CLAIM_CHART_KB comment above pl_entry for why it exists and the
; window-lifecycle note above pl_docmd_chart for why pl_chartwin, once
; set, is never zeroed again this session (only shown/hidden)
                                             ; window ptr, permanently valid
                                             ; is pinned to (frozen at open)
                                           ; column below (81.30)
                                             ; (frozen at open - re-run the
                                             ; menu item to retarget)
                                             ; 0 = nothing yet (Export checks
                                             ; this)
                                             ; name buffer (separate from
                                             ; pl_name, which is Sheet's own
                                             ; load/save filename)

; apps/os88chart.inc's own required scratch (see that file's header comment)
pl_rpn_buf        equ pl_blank + PL_CW_MAXCH + 1     ; PL_RPN_MAX: the token array
pl_rwsrc          equ pl_rpn_buf + PL_RPN_MAX             ; PL_EDITMAX+1: the formula
                                              ; text copied out for rewriting
pl_rwdst          equ pl_rwsrc + PL_EDITMAX + 1  ; PL_RW_CAP: the rewritten
                                              ; text being built
pl_rw_di          equ pl_rwdst + PL_RW_CAP   ; word: pl_rw_emit's own cursor
pl_rw_op          equ pl_rw_di + 2           ; byte: pl_rc_op, copied in
pl_rw_pivot       equ pl_rw_op + 1           ; word: pl_rc_idx, copied in
pl_rw_tsheet      equ pl_rw_pivot + 2        ; word: the sheet this whole
                                              ; operation is acting on
pl_rw_home        equ pl_rw_tsheet + 2       ; byte: 1 if the formula being
                                              ; rewritten right now lives on
                                              ; pl_rw_tsheet itself
pl_rw_adj         equ pl_rw_home + 1         ; byte: pl_reidx_cellpart's own
                                              ; "adjust this one" flag
pl_rw_ostart      equ pl_rw_adj + 1          ; word: the reference's own
                                              ; text start, for a verbatim copy
pl_rw_lettersend  equ pl_rw_ostart + 2       ; word: where its letters end
                                              ; (and its digits, if any, start)
pl_rw_refcol      equ pl_rw_lettersend + 2   ; word: the reference as parsed
pl_rw_refrow      equ pl_rw_refcol + 2
pl_rw_refend      equ pl_rw_refrow + 2       ; word: just past its digits
pl_rw_recdi       equ pl_rw_refend + 2       ; word: pl_rowcol_reidx's own
                                              ; current record offset

; Copy/Paste relative-reference adjustment (stage 2.x) - see the section
; comment above pl_copy_shift for what each of these holds
pl_clip_col       equ pl_rw_recdi + 2        ; word: pl_docmd_copy's own
pl_clip_row       equ pl_clip_col + 2        ; source cell
pl_clip_sheet     equ pl_clip_row + 2        ; word: and which sheet it was
pl_clip_valid     equ pl_clip_sheet + 2      ; byte: 1 once any Copy has
                                              ; run this session
pl_cp_coldelta    equ pl_clip_valid + 1      ; word: pl_docmd_paste's own
pl_cp_rowdelta    equ pl_cp_coldelta + 2     ; (dest - source) delta
pl_cp_ostart      equ pl_cp_rowdelta + 2     ; word: pl_copy_cellpart's own
                                              ; scratch - same shape as
                                              ; pl_rw_ostart/lettersend/
                                              ; refcol/refrow/refend above,
                                              ; just a separate copy since
                                              ; a row/col insert and a
                                              ; paste never run at once but
                                              ; sharing the same words
                                              ; would still be confusing
pl_cp_lettersend  equ pl_cp_ostart + 2
pl_cp_refcol      equ pl_cp_lettersend + 2
pl_cp_refrow      equ pl_cp_refcol + 2
pl_cp_refend      equ pl_cp_refrow + 2

; Stage 3.0a: multi-cell range selection. pl_selcol/pl_selrow keep their
; existing meaning as the ANCHOR (and, for every single-cell operation, still
; simply "the selected cell"); these two are the moving end of the block. A
; collapsed selection has extent == anchor, which is what pl_select sets, so
; every existing single-cell caller keeps working untouched.
pl_selcol2        equ pl_cp_refend + 2
pl_selrow2        equ pl_selcol2 + 2
pl_selc1          equ pl_selrow2 + 2   ; pl_selrect's normalized output -
pl_selc2          equ pl_selc1 + 2     ; c1<=c2, r1<=r2, so no consumer has
pl_selr1          equ pl_selc2 + 2     ; to care which corner was dragged
pl_selr2          equ pl_selr1 + 2     ; from
pl_sc_tcol        equ pl_selr2 + 2     ; pl_scrollto_t's target cell
pl_sc_trow        equ pl_sc_tcol + 2
pl_drag_col       equ pl_sc_trow + 2   ; the cell the drag handler last
pl_drag_row       equ pl_drag_col + 2  ; landed on - "redraw only on a
                                        ; change", per OSAPI_WM_ONDRAG's own
                                        ; warning that it fires per mouse
                                        ; packet and a repaint per packet is
                                        ; tens of ms on a 4.77MHz machine
pl_dragging       equ pl_drag_row + 2  ; byte: a press is armed on the grid
pl_selvc2         equ pl_dragging + 1  ; pl_drawsel's viewport-clamped
pl_selvr2         equ pl_selvc2 + 2    ; bottom-right, in window cells

; stage 3.0b: the formula bar's content box, as a real os88line field. Its
; rect is refreshed from the live geometry on every draw (the window moves and
; resizes), so only LN_BUF/LN_MAX are set once at entry.
pl_fline          equ pl_selvr2 + 2    ; OS88LINE_SZ bytes

; stage 3.0a+: the two scroll bars. Both use os88ui.inc's OWN seven-word block
; layout - x1,y1,x2,y2 (absolute, inclusive), total, fit, pos - so the vertical
; one is passed straight to os88ui_sbar/sbhit/sbgrab/sbtrack, and the private
; horizontal one below is a transposition of the same words rather than a
; different structure (see pl_hsb_* for why it is private and what it is
; staged to become).
pl_vsb            equ pl_fline + 20    ; 7 words
pl_hsb            equ pl_vsb + 14      ; 7 words
pl_sb_oldpos      equ pl_hsb + 14      ; word: the pos a scroll started from,
                                        ; for os88ui_sbmove's cheap redraw
pl_hsb_dragon     equ pl_sb_oldpos + 2 ; byte: 1 = a horizontal thumb drag is
                                        ; live (the vertical one's state is
                                        ; os88ui.inc's own static)
pl_hsb_dragoff    equ pl_hsb_dragon + 1 ; word: press x - thumb left
; pl_hsb_*'s own scratch. The rect is copied out of the block before ANY
; drawing, because the gfx primitives take AX/BX/CX/DX as their rect and BX is
; also the block pointer - holding both in BX is the clobber this codebase has
; hit three times already.
pl_hsb_x1         equ pl_hsb_dragoff + 2
pl_hsb_y1         equ pl_hsb_x1 + 2
pl_hsb_x2         equ pl_hsb_y1 + 2
pl_hsb_y2         equ pl_hsb_x2 + 2
pl_hsb_tl         equ pl_hsb_y2 + 2    ; the thumb's left
pl_hsb_tw         equ pl_hsb_tl + 2    ; ...and its width

; stage 3.0b: the note table's claim, and the Note... dialog's state. The
; EDIT BUFFER IS REAL BSS rather than a pointer into the arena, because the
; arena is append-only: the dialog edits a copy and only commits it on OK, so
; Cancel costs nothing and a refused commit leaves the old note intact.
pl_nnote          equ pl_hsb_tw + 2   ; word: records in it
                                       ; user can still move behind a
                                       ; non-modal dialog
                                       ; per button (os88ui_btn takes a
                                       ; POINTER to it)

; stage 3.0c: the generic one-line input dialog, shared by Goto..., Row
; Height... and Column Width... (see PL_ID_* for why one dialog serves three).
pl_idlg_win       equ pl_nnote + 2 ; word: 0 = none, the single-instance
pl_idlg_kind      equ pl_idlg_win + 2  ; byte: PL_ID_*                   gate
pl_idlg_buf       equ pl_idlg_kind + 1 ; PL_EDITMAX bytes: what is typed
pl_idlg_line      equ pl_idlg_buf + PL_EDITMAX   ; OS88LINE_SZ bytes
pl_idlg_ox        equ pl_idlg_line + 20
pl_idlg_oy        equ pl_idlg_ox + 2
pl_idlg_rect      equ pl_idlg_oy + 2   ; 4 words: one button rect

; stage 3.0e: absolute references. Each scanner records whether the reference
; it is looking at pinned its column and/or its row with '$', and its adjuster
; then declines to move the pinned half - that refusal is the whole feature.
pl_rw_absc        equ pl_idlg_rect + 8 ; byte: Insert/Delete's scanner
pl_rw_absr        equ pl_rw_absc + 1
pl_cp_absc        equ pl_rw_absr + 1   ; byte: Copy/Paste + Fill's scanner
pl_cp_absr        equ pl_cp_absc + 1
pl_cp_dead        equ pl_cp_absr + 1   ; byte: the paste shift took this
                                       ; reference off the sheet (81.26.1)

; stage 3.0d: which cell the evaluator is CURRENTLY inside, for ROW()/COLUMN().
; Saved and restored around each pl_eval_cell so a formula reached through
; another cell's reference still answers for itself, not for whoever asked.
pl_rc_ccol        equ pl_cp_dead + 1   ; the cell that OWNS the formula being
pl_rc_crow        equ pl_rc_ccol + 2   ; converted to or from R1C1 - every
                                       ; relative offset is measured from it
pl_evrow          equ pl_rc_crow + 2   ; word: 0-based
pl_evcol          equ pl_evrow + 2     ; word: 0-based
; 81.75: the value accumulator the evaluator carries, and every scratch word
; apps/os88fix.inc's header says the caller owes it. FOUR BYTES, not eight -
; a hundredth-count, not a double - and the block that fed the IEEE mantissa,
; its sticky bit, the 128-bit product, the 80-bit coprocessor forms and the
; transcendental layer's four temporaries is gone with it: 170 bytes to 42.
pl_acc            equ pl_evcol + 2     ; 4: the expression's current value
pl_lhs            equ pl_acc + 4       ; 4: a binary operator's left operand,
                                       ; recovered from the stack
fx_a              equ pl_lhs + 4       ; 4: accumulator A
fx_b              equ fx_a + 4         ; 4: ...and B
fx_q              equ fx_b + 4         ; 8: the 64-bit intermediate
fx_m0             equ fx_q + 8         ; the multiplier's operand copies
fx_m1             equ fx_m0 + 2
fx_n0             equ fx_m1 + 2
fx_n1             equ fx_n0 + 2
fx_sgn            equ fx_n1 + 2        ; byte: the sign a magnitude owes back
fx_tmp            equ fx_sgn + 1       ; 4: general scratch
fx_dig            equ fx_tmp + 4       ; 16: fx_ftoa's digit string
fx_nn             equ fx_dig + 16      ; 8: fx_sqrt's radicand, kept across a
                                       ; divide that consumes fx_q
pl_pb_c0          equ fx_nn + 8        ; the paste block's landing
pl_pb_r0          equ pl_pb_c0 + 2     ; corner...
pl_pb_x           equ pl_pb_r0 + 2     ; ...the cell being written
pl_pb_y           equ pl_pb_x + 2
pl_pb_cur         equ pl_pb_y + 2      ; ...and where the reader is
pl_pb_len         equ pl_pb_cur + 2
pl_tabanchor      equ pl_pb_len + 2        ; word: 0 = no Tab run in progress,
                                       ; else the run's start column PLUS ONE
pl_fl_scol        equ pl_tabanchor + 2 ; pl_fill_copy's source cell...
pl_fl_dcol        equ pl_fl_scol + 2   ; ...and its destination
pl_needld         equ pl_fl_dcol + 2   ; byte: an ARG_FILE document is
                                       ; noted and not yet read
pl_argdir         equ pl_needld + 1    ; word: the directory it is in
pl_argdrv         equ pl_argdir + 2    ; byte: ...and that volume
pl_savepend       equ pl_argdrv + 1    ; byte: File Format's OK owes a Save As

; The damage-rect machinery (perf review): what a selection move or a scroll
; actually dirtied, so the hot paths stop paying the ~1s full repaint.
pl_commitdirty    equ pl_savepend + 1  ; byte: pl_commit stored something -
                                       ; pl_selpaint consumes it and pays the
                                       ; full repaint (dependent formulas)
pl_chartdirty     equ pl_commitdirty + 1 ; byte: a cell record changed since
                                       ; the chart last resynced (pl_repaint's
                                       ; tail reads it, pl_addcell/
                                       ; pl_removecell set it)
pl_oldc1          equ pl_chartdirty + 1 ; pl_selbank's bank of the ordered
pl_oldc2          equ pl_oldc1 + 2     ; rect a selection move started from...
pl_oldr1          equ pl_oldc2 + 2
pl_oldr2          equ pl_oldr1 + 2
pl_oldscol        equ pl_oldr2 + 2     ; ...and the scroll origin
pl_oldsrow        equ pl_oldscol + 2
pl_dmgc1          equ pl_oldsrow + 2   ; the range the ranged grid painters
pl_dmgc2          equ pl_dmgc1 + 2     ; draw (window-relative cells,
pl_dmgr1          equ pl_dmgc2 + 2     ; inclusive; pl_dmgfull = the whole
pl_dmgr2          equ pl_dmgr1 + 2     ; viewport)
pl_blitx1         equ pl_dmgr2 + 2     ; pl_scrollrow_blit's rect (also
pl_blitx2         equ pl_blitx1 + 2    ; pl_dmgdraw's band-fill x span)...
pl_blity1         equ pl_blitx2 + 2
pl_blity2         equ pl_blity1 + 2
pl_blitdel        equ pl_blity2 + 2    ; ...and its signed row delta
; --- the lookup search's banked state (SPEC.md 81.32) ------------------------
; THE SCAN CALLS pl_getcell2 PER CANDIDATE, and that recurses into a whole
; evaluation for any formula cell it lands on - which is exactly why 81.23's
; pl_arg1col/pl_arg1row are not pl_r1col/pl_r1row. Everything the scan needs
; across that call is banked here, out of the parser's reach.
                                       ; 65 bytes and the task stack is 384
                                       ; (20.6 rule 6), so banking it per
                                       ; nesting level is not available -
                                       ; a search reached from inside a
                                       ; searched range REFUSES instead (47),
                                       ; which is a stated limit rather than
                                       ; a silently wrong answer
                                       ; MATCH's match type
                                       ; pl_lk_idx - see pl_lkone
pl_pacc2          equ pl_blitdel + 2       ; 8: the SUM OF SQUARES, beside pl_pacc's
                                       ; sum, for the variance folds (81.34)
pl_tr0        equ pl_pacc2 + 8        ; 8 } two packed doubles that survive a
                                       ; arguments (81.37). Not banked per
                                       ; nesting level - forty bytes against a
                                       ; 384-byte stack - so a financial
                                       ; function inside another's arguments
                                       ; REFUSES, the shape 81.32.1 and 81.34.1
                                       ; already take
                                       ; IPMT, PPMT and RATE take that many
                                       ; which is NOT always argument 1 - IPMT
                                       ; evaluates the same annuity at per-1
                                       ; is argument 4 for PMT/PV/FV and
                                       ; argument 5 for IPMT/PPMT
                                       ; argument 0 any more: RATE varies it,
                                       ; which is the whole of what a
                                       ; root-finder does (81.37.5)
                                       ; across the arithmetic (81.36)
                                       ; as its own temporaries (81.35)
pl_stbusy         equ pl_tr0 + 8        ; byte: a variance fold is running. Only
                                       ; ONE can be, for pl_pacc2's sake - see
                                       ; 81.34.1
pl_rndlo      equ pl_stbusy + 2      ; RAND's 32-bit LCG state
pl_rndhi      equ pl_rndlo + 2
pl_ps_ownsheet    equ pl_rndhi + 2   ; word: 81.45.4's banked sheet
pl_ps_mode    equ pl_ps_ownsheet + 2  ; byte: which parts of a copied cell the
                                       ; paste in progress is for (81.45)
                                       ; a volatile function (81.44)
pl_sepch          equ pl_ps_mode + 2      ; byte: CSV/TXT's delimiter (81.40)
pl_sepend     equ pl_sepch + 2       ; word: the staging buffer's end
; 81.75: with the module resident, SHOUT is a near call and nothing reaches
; back through a vector - so the table is not merely unused, it is 568 bytes
; of bss that would be zeroed at every launch. The chain carries on from
; where it would have started.
pl_colwtab    equ pl_sepend + 2      ; 256: 81.56's column widths (81.75)
pl_v_end      equ pl_colwtab + 256

pl_abon           equ pl_v_end         ; byte: the About card is up (20.5.1)
                                       ; UPSTREAM added this against
                                       ; pl_blitdel, where this fork had
                                       ; already grown a chain - so it is
                                       ; re-anchored on the end of it
pl_nf_sec         equ pl_abon + 1       ; PL_STR_MAX+1: the format section
pl_nf_num         equ pl_nf_sec + PL_STR_MAX + 1 ; PL_NUMBUF_MAX+1: its number
pl_nf_cx          equ pl_nf_num + PL_NUMBUF_MAX + 1 ; word: decimals, zeros
pl_nf_fl          equ pl_nf_cx + 2       ; byte: grouping, percent, exponent
pl_nf_neg         equ pl_nf_fl + 1       ; byte: the mantissa was negative
pl_nf_wd          equ pl_nf_neg + 1      ; byte: weekday 0-6
pl_nf_h           equ pl_nf_wd + 1       ; byte: hour 0-23
pl_nf_mi          equ pl_nf_h + 1        ; byte: minute
pl_nf_s           equ pl_nf_mi + 1       ; byte: second
pl_nf_12          equ pl_nf_s + 1        ; byte: AM/PM in the code
pl_nf_lasth       equ pl_nf_12 + 1       ; byte: the last token was an h
pl_nf_rl          equ pl_nf_lasth + 1    ; byte: an m run's length
pl_nf_id          equ pl_nf_rl + 1       ; byte: the id pl_numfmt drew by
pl_nf_r1          equ pl_nf_id + 1       ; word: Format Number's top row
pl_nf_r2          equ pl_nf_r1 + 2       ; word: ...and bottom
pl_defch          equ pl_nf_r2 + 2       ; word: the standard column width
pl_vcw            equ pl_defch + 2       ; PL_MAXVC: the visible columns'
                                         ; widths, in characters (81.56)
pl_undoseg        equ pl_vcw + PL_MAXVC  ; word: Undo's claim, 0 when none (81.57)
pl_ud_busy        equ pl_undoseg + 2     ; byte: an undoable command is running
pl_ud_lab         equ pl_ud_busy + 1     ; byte: its label (PL_UL_*)
pl_ud_redo        equ pl_ud_lab + 1      ; byte: the snapshot is the REDO
pl_vrh            equ pl_ud_redo + 1     ; PL_MAXVR: the visible rows' heights,
                                         ; in pixels (81.60)
pl_gridw          equ pl_vrh + PL_MAXVR  ; word: the grid's width in pixels...
pl_gridh          equ pl_gridw + 2       ; word: ...and its height (pl_geom)
pl_rtoff          equ pl_gridh + 2       ; word: the drawn row's text offset
pl_macro_ctl      equ pl_rtoff + 2   ; byte: what the step asked (PL_MC_*)
pl_macro_ncol     equ pl_macro_ctl + 1   ; word: ...where to, for GOTO, NEXT,
pl_macro_exec     equ pl_macro_ncol + 2  ; byte: the step engine is evaluating
pl_macro_wait     equ pl_macro_exec + 1 ; byte: what a resume means (PL_MW_*)

; 81.65's own scratch: the database and criteria rectangles, kept apart from
; pl_arg1col/pl_arg2col (which a nested reference argument overwrites the
; instant the NEXT argument is parsed, pl_pargref's own header) and from
; pl_r1col/pl_r2col (pl_foldrange's own loop bounds) for the same reason -
; these stay live across the WHOLE scan, not just across one pl_pargref call.
                                       ; resolved once
                                       ; re-resolved per column per row
                                       ; testing (pl_dbrowmatch)
                                       ; across the database cell's own read
                                       ; (pl_dbtest)
                                       ; - re-entrancy is REFUSED, not guarded
                                       ; (see plm_pdatabase's own header)
                                       ; it knows to clear it again

; 81.66's own scratch: CELL's parsed type_of_info and the (col,row) it is
; answering about, from an explicit reference or the current selection

; 81.67's own scratch: the array/matrix functions. pl_mx_r1/c1/r2/c2 is the
; first (or only) array argument's rectangle, pl_mx_r1b/c1b/r2b/c2b MMULT's
; second; pl_mx_rows/cols and pl_mx_rows2/cols2 their sizes, capped at
; PL_MX_N each way. pl_mx_buf is the shared elimination workspace -
; PL_MX_N rows by PL_MX_W (twice that) columns of packed doubles, wide
; enough to hold [A|I] for MINVERSE's Gauss-Jordan and MDETERM's plain
; triangulation alike, never both at once (pl_mx_busy). The regression
; family (LINEST/LOGEST/TREND/GROWTH) needs no matrix at all - just the
; four running sums a least-squares line is built from.
                                     ; refused, not guarded, pl_db_busy's
                                     ; own reason (81.65)
                                     ; explicitly FALSE

; the regression family's own scratch (LINEST/LOGEST/TREND/GROWTH). t1/t2 are
; a generic pair of packed-double temps - the CURRENT point's x and y while
; pl_mx_regsums is summing, then a subexpression each while pl_mx_fitline is
; solving for the line - never live at once, so one pair covers both, the
; way pl_mx_buf covers MDETERM's triangulation and MINVERSE's Gauss-Jordan
; without needing to be two buffers.
                                       ; `const` argument was FALSE
                                         ; rather than the default 1,2,3,...
                                          ; given explicitly
                                         ; summing (LOGEST/GROWTH fit
                                         ; ln(y) = ln(b) + x*ln(m))
                                     ; through AX/BX, since pl_mx_addr wants
                                     ; both at once and only has two input
                                     ; registers
                                     ; elimination workspace
; 81.71's own state: the Data menu's four database COMMANDS. pl_ex_* is the
; extract range, PINNED when Extract's dialog opens rather than read live at
; OK (81.6 - these dialogs are not modal, and the selection can move under
; one). pl_dfindmode is the Find/Exit Find relabel, and pl_dbc_res is how the
; module answers, since CF on that door already means "is there a module".
pl_planvec        equ pl_macro_wait + 1   ; 81.75: PLAN's ch_ovcall stages
                                              ; the verb body's offset here -
                                              ; a near `call [mem]` needs one
                                              ; and every register is the
                                              ; caller's argument. IN PLAN'S
                                              ; ARM ONLY: SHEET's bss chain
                                              ; has to come out byte for byte
                                              ; as it was (t_appsmall.py)
                                              ; one's header resolves to

; 81.72's own: Data ▸ Series. The range is PINNED when the TYPE dialog opens,
; because the step is a SECOND dialog and the selection can move between them.
                                              ; arms compute from those two
                                              ; rather than from the cell
                                              ; before them (pl_ser_next)

; Data ▸ Form (81.71.5) - the sixth dialog engine's own state. The rectangle
; is PINNED at open, like Extract's; pl_df_rec/fld/top are where the form is
; standing in it, and pl_df_sv* bank the real selection across the pl_commit
; that writes a field back (pl_commit's argument IS the selection).
pl_bss_end        equ pl_planvec + 2

; -----------------------------------------------------------------------------
; The bss size above is a PLAIN LITERAL and nothing in the toolchain checks it
; against the equ chain - setting it low is silent corruption of whatever the
; loader placed next, not a build error. It cannot simply be written as
; `OS88_BSS pl_bss_end - os88_image_end`: OS88_BSS_SIZE goes into the package
; header's dw at a FIXED OFFSET near the top of the image, so it has to be
; known on pass 1, and a forward reference to a label defined down here makes
; NASM size instructions differently per pass - the "changed during code
; generation" failure this file has already hit twice.
;
; So it stays a literal, and this asserts it instead. A mismatch drives one of
; the two TIMES counts negative, which -w+error turns into a build failure that
; prints the exact shortfall. Both are zero when the literal is right, so
; nothing is emitted.
;
; READ THE LINE NUMBER, not just the sign: the two TIMES lines report the same
; shortfall with opposite signs, so "which one fired" is what says whether the
; literal is too small or too large. Mistaking one for the other sends you
; chasing a discrepancy that is not there.
; -----------------------------------------------------------------------------
%define PL_BSS_NEED (pl_bss_end - os88_image_end)
    times (PL_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - PL_BSS_NEED) db 0
