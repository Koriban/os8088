; =============================================================================
; os8088 - apps/plan/plan.asm
;
; PLAN - a spreadsheet for the machines SHEET cannot reach. Prefix lg_.
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
; to `lg_` could be proved the same way: 8,038 identifiers, not one byte of
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

    OS88_HEADER 'LEDGER', lg_entry, 3    ; a package NAME is a literal
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
LG_COLS      equ 256                ; the roadmap's stage 1.2 ceiling
; 81.75: 256 x 1024, AND THE TWO NUMBERS THIS FILE KEEPS APART.
;
; LG_COLS x LG_ROWS is THE ADDRESSABLE RANGE - which cell references exist and
; how far the view can scroll. It costs NOTHING, because storage is sparse:
; the cell array is records of (row, col, value), so what a grid costs is the
; cells that are OCCUPIED, never the ones that could be. 2048 rows and 1024
; rows assemble to BYTE-IDENTICAL images; that was measured, not assumed.
;
; HOW MANY CELLS MAY BE OCCUPIED AT ONCE is a different number entirely, and
; it is the one that is tight: LG_CELL_CAP, which is the cells CLAIM divided
; by LG_C_SZ. Do not read one as the other.
;
; LG_ROW_BITS stays 14. The packed key has room for 16384 either way and
; narrowing it would be a second change with no second benefit.
LG_ROWS      equ 1024
; stage 2.x: Format > Column Width.../Row Height... make these RUNTIME
; values (lg_cellw/lg_cellh/lg_cellch bss words) rather than compile-time
; constants. Stage 3.0c made both dialogs real numeric entry (lg_idlg_*, over
; os88line.inc); 81.56 gave each column its own width and 81.60 each row its
; own height, so the two words now mean THE CELL BEING DRAWN, and these are
; the standard width and height. Widths
; must stay multiples of 8 - lg_blank and every OSAPI_FONT_RUN cell text
; is built one glyph (8px) at a time, so a non-multiple would leave a
; fractional glyph column with nothing sensible to draw there.
LG_CW_NORMAL equ 56                 ; 7 chars - the original fixed default
LG_RH_NORMAL equ 14                 ; the original fixed default
; stage 3.0c: the bounds real numeric entry has to enforce, now that Row
; Height.../Column Width... take a typed number instead of a 3-way radio.
; Width is in CHARACTERS (Excel's own unit); height is in pixels.
LG_CW_MINCH  equ 1
LG_NUMBUF_MAX equ 40                ; stage 4.5: lg_numbuf's usable length,
                                    ; which is LG_CW_MAXCH because a label is
                                    ; clipped to its column and nothing wider
                                    ; can ever reach a justifier
LG_CW_MAXCH  equ 40                 ; 320px - wider than the window, but the
                                    ; renderer clips and the user asked
LG_RH_MIN    equ 8                  ; one glyph cell: below this no text fits
LG_RH_MAX    equ 48
; 81.60: EACH ROW ITS OWN HEIGHT, kept - as Excel keeps it and BIFF writes it -
; in TWIPS, a twentieth of a point, and drawn at LG_RH_NORMAL pixels for the
; standard 12.75 points: px = (tw * 14 + 127) / 255. The dialog takes points.
; The bounds are the twips that round to LG_RH_MIN and LG_RH_MAX pixels
LG_RH_STDTW  equ 255                ; the standard height, 12.75 points
LG_RH_TWMIN  equ 146                ; 7.3 points -> 8 px
LG_RH_TWMAX  equ 874                ; 43.7 points -> 48 px
LG_MAXVR     equ 64                 ; visible rows at most: 480px / LG_RH_MIN
LG_RH_W      equ 32                 ; row-header column: 81.75's 1024 rows are
                                    ; four digits, not five, so the grid gets
                                    ; the eighth column of it back
LG_CH_H      equ 14
LG_FB_H      equ 16
LG_REF_W     equ 64                 ; stage 2.x: the formula bar's own
                                     ; reference box width - wide enough
                                     ; for the longest possible reference
                                     ; text (a 2-letter column + a 5-digit
                                     ; row, LG_COLS=256/LG_ROWS=16384's own
                                     ; worst case) plus a little padding
; Mirrors of os88ui.inc's own scroll-bar constants. Duplicated here for the
; same reason the CH_* chart constants are (see their comment below): that file
; is %included at the END of this one, so its equs are FORWARD references, and
; a forward-referenced value used as an IMMEDIATE makes NASM size the
; instruction differently on each pass - `cmp cx, imm8` vs `cmp cx, imm16` -
; which fails the assembly outright with "label changed during code
; generation". Values must track os88ui.inc's; they are part of the block
; contract lg_hsb_* is written to be promoted into.
LG_SB_NONE   equ 0
LG_SB_UP     equ 1                  ; the LEFT arrow on a horizontal bar
LG_SB_DOWN   equ 2                  ; ...and the RIGHT one
LG_SB_PGUP   equ 3
LG_SB_PGDN   equ 4
LG_SB_THUMB  equ 5
LG_SB_MINH   equ 8                  ; the shortest thumb that is still a thumb
LG_SB_CELL   equ 10                 ; the arrow cell's depth

LG_VSB_W     equ 14                 ; stage 3.0a+: the vertical scroll bar's
                                     ; width. 14 is what both kernel callers
                                     ; use and what os88ui.inc's arrow glyph
                                     ; is drawn for (5 rows, widths 1..9)
LG_HSB_H     equ 14                 ; ...and the horizontal bar's height, the
                                     ; same cell so the two agree at the
                                     ; corner where they meet
LG_SB_H      equ 16                 ; stage 2.x: the status bar strip at
                                     ; the very bottom of the window,
                                     ; same height as the formula bar for
                                     ; visual symmetry
LG_EDITMAX   equ 63                 ; room for a formula, not just a number
LG_NAME_MAX  equ 12                  ; characters an IDENTIFIER may run to in a
                                     ; formula - a function name, and once a
                                     ; defined name. The names went; the
                                     ; parser's cap on what it will collect
                                     ; stayed, since it sizes lg_ident
LG_NAMEMAX   equ 12                  ; characters in an 8.3 FILE name - the
                                     ; same number, a different thing
LG_RW_CAP    equ 80                  ; stage 2.x: lg_formula_reidx's own
                                     ; output cap - a shifted reference can
                                     ; grow by a digit or two (row 9->10,
                                     ; col Z->AA), so a little more than
                                     ; LG_EDITMAX+1

; 81.75's CLAIM LADDER. §24.5.2 is why SHEET is not on the 128KB machine:
; 32KB of cells alone is nearly twice the largest single run that machine can
; hand out (§50.6.2), and a package that merely wants heap can refuse itself
; in its own words - which is a refusal, not a spreadsheet. Every figure below
; is sized from what a BUDGET holds rather than from what a sheet could.
LG_CLAIM_CELLS_KB equ 5             ; 320 records of 16 bytes (81.75)
LG_CLAIM_TXT_KB   equ 1             ; formula text only: no notes here
LG_CLAIM_STG_KB   equ 8             ; file I/O staging. NOT the 2KB the plan
                                    ; first wrote: the readers take a whole
                                    ; file into this buffer in one
                                    ; OSAPI_FILE_READ, so it is the DOCUMENT
                                    ; size and not a streaming window, and a
                                    ; 409-cell SYLK is about 15KB. What Sort's
                                    ; going buys is the 32KB its own layout
                                    ; forced (offsets to 30,720), not the
                                    ; buffer itself
; lg_docmd_sortcol's own layout within lg_stgseg (stage 2.x: formula cells
; now participate in the sort too, so alongside the original rows[]/
; values[] arrays it also needs a source-index permutation, an
; is-this-a-formula flag, and staged formula text for each one - see the
; section comment above lg_docmd_sortcol for the full design)
; STAGE 4.5 RELAID THIS OUT because values[] had to grow. It was a WORD per
; entry - the truncated integer - which was right while every cell held one and
; became silently wrong the moment cells held doubles: 1.2, 1.5 and 1.9 all
; truncate to 1, so a column of decimals sorted into whatever order the
; insertion sort's stability happened to leave them in. Nothing reported it,
; because a sorted-looking column IS what you get.
;
; Entries are capped at LG_SORT_CAP now as well. There was no cap before, and
; nothing stopped a long column walking off the end of one array into the next.
LG_MENU_CHK       equ 2              ; a leading byte meaning "checked", the
                                     ; companion to the kernel's MENU_DIS
LG_SORT_CAP       equ 512            ; entries one sort can carry
LG_SORT_ROWS_OFF  equ 0              ; word/entry
LG_SORT_VALS_OFF  equ 1024           ; EIGHT bytes/entry: a whole double
LG_SORT_ORIG_OFF  equ 5120           ; word/entry: origidx[] (which
                                     ; pre-sort entry ended up here)
LG_SORT_ISF_OFF   equ 6144           ; byte/entry: 1 if that entry is a
                                     ; formula cell
LG_SORT_FIDX_OFF  equ 6656           ; word/entry: which LG_SORT_FTXT_OFF
                                     ; slot holds that formula's own text
                                     ; (only meaningful when ISF is set)
LG_SORT_FTXT_OFF  equ 7680           ; LG_SORT_FCAP slots of 64 bytes each,
                                     ; ending at 7680+180*64=19200, safely
                                     ; inside the 32KB claim
LG_SORT_FCAP      equ 180           ; max formula cells one sort can carry
LG_SORT_SNAP_OFF  equ 19200          ; LG_SORT_SNAPCAP slots of 64 bytes: ONE
                                     ; other column's cells as text, while the
                                     ; permutation is applied to it. It starts
                                     ; where the formula slots end (7680 +
                                     ; 180*64) and fits inside LG_STAGE_MAX
LG_SORT_CLS_OFF   equ 30720          ; byte/entry, by ORIGINAL index (81.61):
                                     ; 0 number, 1 text, 2 logical, 3 error -
                                     ; Excel's ascending order of the four.
                                     ; A text entry's eight value bytes hold
                                     ; the offset of its text, staged in a
                                     ; SNAP slot, which nothing else uses
                                     ; until the carry, after the write-back
LG_SORT_SNAPCAP   equ 180            ; rows a multi-column sort can carry
                                     ; through - far more than any real
                                     ; column needs; a cell beyond this cap
                                     ; is simply excluded from the sort
                                     ; entirely (same "clip, don't crash"
                                     ; policy used throughout this file)
LG_CHART_S2  equ 512                ; where a chart's SECOND series lands in
                                    ; lg_stgseg - the first sits at 0 and needs
                                    ; CH_MAXBARS words, so 512 is clear of it
                                    ; with room to spare
LG_CHART_D1  equ 1024               ; stage 4.6: and where the DOUBLES the scan
LG_CHART_D2  equ 1536               ; collects sit, before ch_scale turns them
                                    ; into the two word arrays above. Same 512
                                    ; spacing; CH_MAXBARS doubles is 320
LG_CLAIM_UNDO_KB  equ 6             ; 81.75: 256 records plus the widths, and
LG_CLAIM_CHART_KB equ 19            ; stage 2.x: the live Chart Column window's
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
; goes through LG_C_SZ, because this layout has now moved once and the plan's
; own risk list puts "a missed stride site" first: it reads a MISALIGNED
; record and hands back a plausible wrong number, with no crash to notice.
; Naming them makes the next move a four-line edit instead of an 87-site
; audit.
;
; +0 and +2 and +4 and +5 are shared in shape with the border and note tables
; (lg_bt_* / lg_nt_*), which is why those four are deliberately NOT renamed
; here - a rename would have had to reach into two other tables to stay
; honest, and they have their own strides.
; =============================================================================
LG_C_ROW     equ 0                  ; word: packed row | sheet
LG_C_COL     equ 2                  ; word
LG_C_FLAGS   equ 4                  ; byte: bit0 HASFORMULA, bit1 EVALUATING
LG_C_FMT     equ 5                  ; byte: LG_FMT_*, and the BIFF XF index
LG_C_TYPE    equ 6                  ; byte: LG_T_* - reserved by stage 4.0's
LG_C_AUX     equ 7                  ; byte: ...error code, likewise reserved.
                                    ; THE TAG IS ITS OWN BYTE AND NOT SPARE
                                    ; BITS OF LG_C_FMT: that byte's numeric
                                    ; value IS the XF index the BIFF writer
                                    ; emits, so borrowing bits 6-7 would
                                    ; silently change every XF in every file
                                    ; this app has ever written.
LG_C_VAL     equ 8                  ; 4 bytes: a signed count of HUNDREDTHS
                                    ; (81.75, apps/os88fix.inc). It was an
                                    ; IEEE-754 double and those four bytes are
                                    ; the expensive half of the switch: the
                                    ; record times the cells claim is how many
                                    ; cells the sheet can hold at all, so 20
                                    ; bytes becoming 16 is a quarter more
                                    ; cells for the same kilobyte.
LG_C_FOFF    equ 12                 ; word: formula text offset in lg_txtseg
LG_C_PASS    equ 14                 ; word: the repaint pass that cached VAL
; The value tags stage 4.0 reserves. Numbered so that BLANK is 0 and a
; zeroed record is therefore a blank one.
LG_SSTK_N    equ 6                   ; string-stack levels. The text
                                     ; functions bank one argument each, so six
                                     ; is several frames deep; past that a
                                     ; formula gets #VALUE! rather than a
                                     ; quietly overwritten argument
LG_STR_MAX   equ 64                 ; stage 4.5: the string accumulator's
                                    ; usable length, and the size of a text
                                    ; formula's result slot (81.22). A cell
                                    ; shows LG_CW_MAXCH=40 at most, so this is
                                    ; headroom for an intermediate concat
LG_T_BLANK   equ 0
LG_T_NUM     equ 1
LG_T_TEXT    equ 2
LG_T_BOOL    equ 3
LG_T_ERR     equ 4

; Error codes, in LG_C_AUX. These are EXCEL'S OWN ERROR.TYPE numbers, so
; ERROR.TYPE and ISERR become a table lookup if they are ever added.
;
; THE BIFF BOOLERR RECORD DOES NOT USE THIS NUMBERING. That claim stood here
; for a long time and cost a wrong byte in every error cell SHEET ever
; exported - the format has its own codes and lg_biff_e2b/lg_biff_b2e convert
; between them.
LG_ERR_NULL  equ 1                  ; #NULL!
LG_ERR_DIV0  equ 2                  ; #DIV/0!   - the only one produced today
LG_ERR_VALUE equ 3                  ; #VALUE!
LG_PS_ALL    equ 0                  ; Edit Paste Special's five, in the order
LG_PS_FORM   equ 1                  ; the dialog lists them
LG_PS_VAL    equ 2
LG_PS_FMT    equ 3
LG_PS_NOTE   equ 4
LG_PS_LINK   equ 5                  ; ...and Paste Link, which has no dialog
LG_ERR_REF   equ 4                  ; #REF!
LG_ERR_NAME  equ 5                  ; #NAME?
LG_ERR_NUM   equ 6                  ; #NUM!
LG_ERR_NA    equ 7                  ; #N/A

LG_C_SZ      equ 16                 ; ...and an EVEN stride, so the array
                                    ; shuffle can move words rather than bytes

; lg_rowcol_op stages every record through lg_stgseg while it shifts a row or
; column. It is a transient copy, not storage - but it CARRIES the whole
; cell across the shift, so it had to grow with the cell record: the value
; at stage 4.0, the type tag and error code at stage 4.5. Named for exactly
; the reason above: the two layouts look alike and one was silently edited
; into the other.
LG_S_SHEET   equ 0
LG_S_ROW     equ 2
LG_S_COL     equ 4
LG_S_FLAGS   equ 6
LG_S_FMT     equ 7
LG_S_VAL     equ 8                  ; 8 bytes since stage 4.0: this record
                                    ; CARRIES a cell's value across a row or
                                    ; column shift, so it had to grow with the
                                    ; cell record or every decimal in the
                                    ; sheet would have been truncated to the
                                    ; low half of its own double - silently,
                                    ; on an Insert Row
LG_S_FML     equ 16
LG_S_TYPE    equ 18                 ; byte: LG_C_TYPE, carried for the same
LG_S_AUX     equ 19                 ; byte: ...reason - lg_addcell retags a
                                    ; fresh record LG_T_NUM, so a label whose
                                    ; tag was not carried came back a number.
                                    ; Free bytes: LG_S_SZ was already 20, so
                                    ; 18..19 existed before anything used them
LG_S_SZ      equ 20                 ; ...and the code says LG_S_SZ where it
                                    ; means this, so changing it is a change
                                    ; to ONE layout and not silently to both

LG_CELL_CAP  equ 320                ; floor(LG_CLAIM_CELLS_KB*1024 / LG_C_SZ)
LG_TXT_CAP   equ 1024               ; LG_CLAIM_TXT_KB in bytes
LG_STAGE_MAX equ 8192
LG_BT_SZ     equ 6                  ; the border table's record (81.55): row,
                                    ; col, the border+protection byte, and
                                    ; the number format beyond the four the
                                    ; format byte can name. It was 5
LG_BORD_CAP  equ 682                ; floor(4096 / LG_BT_SZ) - 819 at 5
LG_NOTE_REC  equ 6                  ; stage 3.0b: the note table's record -
                                    ; packed row/sheet, col, and the note
                                    ; text's offset in the SHARED formula
                                    ; arena (see lg_nt_findcell's header)
LG_NOTE_CAP  equ 512                ; 682 - floor(4096 / LG_NOTE_REC) - until
                                    ; 81.56 took the claim's top kilobyte:
LG_COLW_OFF  equ LG_NOTE_CAP * LG_NOTE_REC ; 3072: the COLUMN WIDTHS, 256
                                    ; bytes a sheet (lg_colwidth). A new claim
                                    ; would have been SHEET's eighth and last,
                                    ; and bss the headroom's third; notes are
                                    ; the least-used table there is
LG_ROWH_OFF  equ LG_COLW_OFF + 1024 ; 4096: the ROW HEIGHTS (81.60), a sorted
                                    ; sparse table - packed row/sheet word,
                                    ; twips word - of the rows that are not
                                    ; the standard height. Paragraph-aligned,
                                    ; so lg_rc_table can walk it at offset 0
LG_ROWH_CAP  equ 255                ; records; the count is the KB's last word
LG_ROWH_N    equ LG_ROWH_OFF + 1022
LG_ROWH_REC  equ 4
LG_MAXVC     equ 80                 ; visible columns at most: 640px / 8
LG_NOTEMAX   equ 240                ; the longest note the dialog will take,
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
LG_CHARTWIN_W equ 260                ; a little margin around the CH_W x
LG_CHARTWIN_H equ 200                ; CH_H canvas - real size comes back
                                      ; from OSAPI_WM_CONTENT either way
LG_EVAL_MAXDEPTH equ 6               ; a formula referencing a formula
                                      ; referencing a formula...; each level
                                      ; gets its own text buffer (below) so a
                                      ; nested evaluation cannot overwrite
                                      ; the text an outer one is still
                                      ; parsing. Beyond this many levels a
                                      ; reference just reads as 0 - the same
                                      ; honest simplification as every other
                                      ; unbounded case here.
LG_PNEST_MAX equ 12                  ; the parser's own nesting budget (81.3):
                                      ; live recursion points plus cell depth,
                                      ; charged by lg_pnest_enter. 12 is what
                                      ; the deepest LG_EVAL_MAXDEPTH chain of
                                      ; folds needs (one call + one depth per
                                      ; level); each level holds tens of bytes
                                      ; of task 0's 512-byte stack, so the
                                      ; cap is sized to that stack, not to the
                                      ; grammar

; --- stage 1.6: per-cell text formatting -----------------------------------
; Packed into the cell record's byte at +5 (previously unused padding, see
; the record layout comment above lg_findcell): bit0 bold, bit1 underline,
; bits3-2 alignment, bits5-4 number format. Bits6-7 are unused. This exact
; 6-bit space is also, not coincidentally, this app's BIFF XF index on disk
; (lg_dowrite_biff) - see the comment there for why that pairing is safe.
LG_FMT_BOLD          equ 0x01
LG_FMT_UNDER         equ 0x02
LG_FMT_BU_CLR        equ 0xFC        ; ~(LG_FMT_BOLD|LG_FMT_UNDER) & 0xFF -
                                      ; stage 1.8's Font dialog clears bits
                                      ; 0-1 in one mask, not two XORs
LG_FMT_ALIGN_MASK    equ 0x0C
LG_FMT_ALIGN_CLR     equ 0xF3        ; ~LG_FMT_ALIGN_MASK & 0xFF
LG_FMT_ALIGN_SHIFT   equ 2
LG_FMT_ALIGN_GENERAL equ 0           ; General: right, same as this app's
                                      ; only-ever-numeric default
LG_FMT_ALIGN_LEFT    equ 1
LG_FMT_ALIGN_CENTER  equ 2
LG_FMT_ALIGN_RIGHT   equ 3
LG_FMT_NUM_MASK      equ 0x30
LG_FMT_NUM_CLR       equ 0xCF        ; ~LG_FMT_NUM_MASK & 0xFF
LG_FMT_NUM_SHIFT     equ 4
; THE THREE FORMATS (81.75), and they live HERE, beside the field they are
; values of, rather than beside lg_numfmt which reads them. There used to be
; two sets of names for this one 2-bit field - LG_FMT_NUM_GENERAL/CURRENCY/
; COMMA/PERCENT from the twenty-one-format interpreter, and LG_NF_* from the
; three that replaced it - and they DISAGREED: Currency was 1 in one set and
; 2 in the other, so the SYLK writer wrote a Text cell as currency and a
; Currency cell as comma, and the reader turned Excel's own '$' into Text.
; Nothing said a word, because both names existed and both assembled.
LG_NF_NUMBER         equ 0            ; what the value is, up to four places
LG_NF_TEXT           equ 1            ; ...the same characters, LEFT-aligned
LG_NF_CURRENCY       equ 2            ; '$', separators, two places, negative
                                      ; in parentheses

; --- stage 2.x: cell borders (Format > Border..., its own lg_bordseg claim
; and lg_bt_* table - see the LG_CLAIM_BORD_KB comment above for why this
; isn't just more bits in the format byte) ----------------------------------
LG_BORD_LEFT   equ 0x01
LG_BORD_RIGHT  equ 0x02
LG_BORD_TOP    equ 0x04
LG_BORD_BOTTOM equ 0x08
LG_BORD_SHADE  equ 0x10
LG_BORD_EDGES  equ 0x0F             ; Left|Right|Top|Bottom together
; --- cell protection (81.46) lives in the SPARE BITS OF THE SAME BYTE ------
; The border byte uses bits 0-4 and every reader of it tests single bits or
; masks with 0x1F, so bits 5-7 were free. Protection goes there rather than
; into LG_C_FLAGS - which also has spare bits - because several sites write
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
LG_PROT_UNLOCK equ 0x20             ; bit 5: this cell is NOT locked
LG_PROT_HIDDEN equ 0x40             ; bit 6: hide its formula when protected
LG_PROT_MASK   equ 0x60             ; the two together, for preserving them

; lg_doread_biff's FONT/XF tracking tables (a real file might reference more
; than this app itself ever writes - beyond the cap, a cell just reads back
; as unformatted rather than growing these tables without bound)
LG_BIFF_FONT_CAP equ 32
LG_BIFF_XF_CAP   equ 128
LG_B2_XF         equ LG_BIFF_XF_CAP - 1 ; the slot a BIFF2 cell's own
                                        ; attributes are decoded into (81.52)            ; 64 was exactly the format-byte space,
                                    ; and 81.47 writes XFs past it for the
                                    ; cells that also carry a border
LG_XFP_CAP       equ 64             ; distinct (format, border) pairs one file
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
; would run out fast). LG_ROWS needs exactly 14 bits (0..16383), leaving
; exactly 2 spare bits in that word for a sheet index - hence exactly
; LG_SHEETS=4, not a rounder number chosen for its own sake.
LG_SHEETS    equ 1                   ; 81.75: one grid, so the packed key's
                                     ; two sheet bits are always zero
LG_ROW_BITS  equ 14                  ; row occupies bits 0-13
LG_ROW_MASK  equ 0x3FFF

; --- stage 2.x: Sheet's own in-window menu bar -----------------------------
; MENU_APPMAX is five (apps/os88api.inc) and real Excel 2.1's bar is eight
; real menus (File/Edit/Format/Data/Options/Macro/Help, plus this app's own
; Sheets switcher, which has no real-Excel equivalent since Excel used
; separate windows per sheet rather than one packed instance - see the
; stage 2.0 comment above). Word.O88 hit the exact same ceiling and answered
; it the same way (see apps/word/word.asm's "Word chrome" section, SPEC.md
; 68.2): draw the bar and its dropdowns IN THE WINDOW instead of asking the
; kernel for one, and register only the kernel's minimum single-item
; placeholder (lg_mf_ret below) so the bar still gets an app-name pulldown.
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
LG_MBAR_H    equ 14                  ; the in-window menu bar strip
LG_MI_H      equ 12                  ; a dropdown item's row height
LG_MPAD      equ 8                   ; left/right pixel pad per title/item
LG_MCHKX     equ 2                   ; SPEC.md 81.30: the check mark, a solid
LG_MCHKY     equ 4                   ; square centred in the 8px check column
LG_MCHKS     equ 5                   ; and on the row's 8px glyph line
LG_MCHKW     equ 8                   ; stage 3.0c: the DROPDOWN's extra left
                                     ; gutter, where a checked item's mark
                                     ; goes. Not folded into LG_MPAD because
                                     ; that one also sets the spacing of the
                                     ; BAR's own titles, which have no marks
                                     ; and would just drift apart
; File,Edit,Formula,Format,Data,Options,Macro,Sheets,Help - Excel 2.1d's own
; bar order (see lg_mtab). NOTE LG_MENU_N also sizes lg_mw in the bss chain,
; so changing it moves OS88_BSS too.
;
; 81.75: A MENU'S INDEX IS NAMED rather than written as a number, because
; PLAN's bar is shorter - no Macro, no Sheets - and every index above a
; missing menu moves down one. lg_mfire's dispatch chain is the only thing
; that reads these, and it used bare 0..8; the names assemble to the identical
; bytes in SHEET's arm, which is what makes this restructure free. THE ORDER
; HERE IS THE BAR'S ORDER and lg_mtab below must agree line for line.
;
; THE DATA MENU IS DERIVED, not declared, because it is the only one whose
; CONTENTS decide whether it exists: Excel's six database items, Sort and
; Series, and this app's own three chart items. Take all of them and there
; is no menu left to open, so SHF_DATAMENU is the OR of what is left and
; LG_DATA_N is how many - one number, used by lg_mtab, by lg_i_data's own
; list and by nothing else.

LG_MI_FILE    equ 0
LG_MI_EDIT    equ 1
LG_MI_FORMAT  equ 2
LG_MI_OPTIONS equ 3
LG_MENU_N     equ LG_MI_OPTIONS + 1
; The five that are not on this bar, each a value AH can never hold so that
; its own arm in lg_mfire is unreachable rather than absent (81.75).
LG_MI_FORMULA equ 0xFB                ; Goto went; Reference moved to Options
LG_MI_SHEET   equ 0xFC
LG_MI_DATA    equ 0xFD
LG_MI_MACRO   equ 0xFE
LG_MI_HELP    equ 0xFA                ; the About card went with it
LG_M_NONE    equ 0xFF

; =============================================================================
; lg_reloc - THE HEAP COMPACTOR MOVED ONE OF OUR CLAIMS (SPEC.md 66.2)
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
; LG_STGSEG IS NOT IN THE TABLE AND IS NOT DECLARED. It is the ES:BX of every
; one of this package's seven OSAPI_FILE_READ/WRITE calls (SPEC.md 66.9 reason
; 4), and a file call claims, so a compaction inside one would move the buffer
; out from under a transfer the kernel has already been given the address of.
; SPEC.md 66.5.7.1's pin/unpin pair is what it would take; 67KB of the 99 move
; without it.
;
; Everything else in this package is an OFFSET into one of these segments -
; a cell record, a formula's text, a note - so nothing else needs fixing.
; =============================================================================
lg_reloc:
    push cx
    push si
    push di
    mov si, lg_segw
    mov cx, LG_NSEGW
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
lg_segw:
    dw lg_cellseg, lg_txtseg
    dw lg_undoseg
LG_NSEGW equ 3                       ; 81.75: cells, text and undo. No chart

; =============================================================================
; lg_entry - package entry point (SPEC.md 20.2). Claims run here, and only
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

  %define LG_MODSEC .text            ; every `section LG_MODSEC` below is this
; =============================================================================
; 81.75: NO MODULE, SO NO DISPATCH. sheet.asm reaches its overlay through
; forty `mov bp, <verb>` doors, a verb table and a far-call dispatcher; PLAN
; has nothing on the other side of any of it, so the doors are plain jumps
; and the table, the verb numbers, ch_ovcall and the lg_m_* wrappers that
; turned each near body into a far return are all gone. The CALL SITES are
; untouched - every one of them still says `call lg_fdlg_open_r`.
; =============================================================================
section .text

; -----------------------------------------------------------------------------
; The three resident stubs. Every existing caller still says `call lg_doread`
; and never learns the reader moved - which is the point of doing it this way
; round rather than editing the call sites (82.16.9).
; -----------------------------------------------------------------------------
lg_doread:
    call lgm_doread
    jmp lg_undo_drop                   ; another document now (81.57)
lg_dowrite:
    call lg_recalc_all                  ; every formula CURRENT before any
    jmp lgm_dowrite                     ; writer reads one

; -----------------------------------------------------------------------------
; lg_recalc_all - evaluate every formula cell on every sheet, as its own sheet
; (SPEC.md 81.48).
; Preserves all registers.
;
; EVALUATION IS LAZY: lg_eval_cell runs when a cell is READ, and a repaint only
; reads what is on the glass. The SYLK and BIFF writers read a cell's value
; with lg_cellval_to_acc_si, the STORED double, and never ask for a fresh one -
; so a formula scrolled out of sight since it was loaded, or since a cell it
; names changed, was written with whatever it last held. After a load that is
; the zero lg_setformula leaves, and BIFF's reader keeps the result and not the
; tokens, so a Save in Normal format turned an off-screen formula into a
; permanent 0. DIF and the text formats read through lg_getcell2, which
; evaluates, which is why it looked like a SYLK/BIFF quirk rather than a hole.
; Found by tests/sheetfin.py: the first four formulas - the ones on screen -
; came back right and all twenty-two below them came back 0.
;
; NOTHING HERE DECIDES WHAT IS STALE. lg_eval_cell's pass stamp already does,
; and does the right thing in both modes: automatic advances lg_pass on every
; repaint, so anything not recomputed since is stale and recomputes; manual
; does not, so only a cell never computed at all (stamped 0xFFFF) runs - which
; keeps manual mode meaning what it says.
;
; THE SHEET IS IMPERSONATED per record, lg_rowcol_op's idiom: lg_findcell packs
; [lg_cursheet] into every reference, so a Sheet 2 formula evaluated as Sheet 1
; would read Sheet 1's cells.
; -----------------------------------------------------------------------------
lg_recalc_all:
    push ax
    push cx
    push dx
    push di
    push es
    push word [lg_cursheet]
    xor di, di
    mov cx, [lg_ncells]
    jcxz .done
.l:
    mov es, [lg_cellseg]                ; re-read each time: the claim is
    test byte [es:di+LG_C_FLAGS], 1     ; movable (66.2) and a word is what
    jz .next                            ; lg_reloc keeps right, not ES
    mov ax, [es:di+LG_C_ROW]
    rol ax, 1                           ; the sheet is the row word's top two
    rol ax, 1                           ; bits
    and ax, 3
    mov [lg_cursheet], ax
    push cx                             ; the parser under lg_eval_cell is
    call lg_eval_cell                   ; free with CX and DX; DI and ES it
    pop cx                              ; keeps
.next:
    add di, LG_C_SZ
    loop .l
.done:
    pop word [lg_cursheet]
    pop es
    pop di
    pop dx
    pop cx
    pop ax
    ret
lg_difbbox:
    jmp lgm_difbbox

; lg_pfin - the financial family's door (82.16.10). The body is lgm_pfin in
; CHART.OVL; its contract is unchanged - AX the id, SI just past '(', the answer
; in lg_acc, SI past ')', AX 0, BX CX DX DI kept.
;
; THE ONE STUB HERE THAT HAS TO ANSWER A REFUSAL ITSELF. The other three hand
; ch_ovcall's CF to callers that already test it; this one's caller is the
; formula parser, which expects the arguments consumed and a value in lg_acc,
; and would otherwise carry on parsing from inside the argument list. So no
; module answers exactly what the family's own refusals do: zero, #VALUE!
; (47), and the arguments stepped over.
; 81.62: THE TEXT, TRANSCENDENTAL AND INFORMATION FAMILIES came through the
; same door, each with its own verb: the functions a sheet uses least, 2.8 KB
; the package needed more than the module did. SUM and its folds, IF, the
; special forms, the lookups, the dates and NOW stay resident.

lg_entry:
    push ax
    push dx
    push si
    push di
    call fx_init                      ; before the first claim, because every
                                      ; other thing here can fail and be
                                      ; recovered from and this one decides
                                      ; which arithmetic the session gets
    mov ax, LG_CLAIM_CELLS_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [lg_cellseg], dx
    mov ax, lg_reloc                     ; ...and MOVABLE (SPEC.md 66.2). SHEET
                                      ; has NO WORKER, so mem_can_move
                                      ; passes these on I_TASK = 0xFF
                                      ; alone and no park is involved
    call OSAPI_MEM_MOVABLE
    mov ax, LG_CLAIM_TXT_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [lg_txtseg], dx
    mov ax, lg_reloc
    call OSAPI_MEM_MOVABLE
    mov ax, LG_CLAIM_STG_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [lg_stgseg], dx
    mov ax, LG_CLAIM_UNDO_KB           ; Undo's, last and optional (81.57): a
    call OSAPI_MEM_CLAIM               ; heap that cannot spare it costs Undo,
    jc .noundo                         ; not the app
    mov [lg_undoseg], dx
    mov ax, lg_reloc
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
    ; lg_stgseg, which is pinned, and every copy of a movable segment is
    ; either in lg_segw or dead across no compaction point. The image and
    ; CHART.OVL are what stay put.
    mov word [lg_ncells], 0
    mov word [lg_txtlen], 0
    mov si, lg_tpl
    call OSAPI_WM_CREATE
    jc .fail
    mov [lg_ownwin], bx               ; stage 2.0: os88ui_ask needs our own
                                       ; window ptr, and it's asked for from
                                       ; the macro engine, which has no window
                                       ; ptr of its own to hand it - Sheet
                                       ; only ever has the one window, so
                                       ; capturing it once here is safe
    mov byte [lg_mopen], LG_M_NONE    ; stage 2.x: Sheet's own menu bar -
    mov byte [lg_mhi], LG_M_NONE      ; see the LG_MBAR_H section comment
    mov byte [lg_gridlines], 1
    mov byte [lg_showformulas], 0
    mov word [lg_i_options], lg_it_grid_on   ; match lg_i_options's own
                                              ; label to the actual default
                                              ; (lg_it_form_off already does,
                                              ; since Formulas defaults off)
    mov word [lg_cellw], LG_CW_NORMAL        ; stage 2.x: runtime cell size
    mov word [lg_cellh], LG_RH_NORMAL        ; defaults - see the LG_CW_*/
    mov word [lg_cellch], LG_CW_NORMAL / 8   ; LG_RH_* section comment
    mov word [lg_defch], LG_CW_NORMAL / 8    ; 81.56: the STANDARD width - a
                                             ; column's own is in the table,
                                             ; and lg_cellch/lg_cellw are the
                                             ; column being drawn
    call lg_mkblank
    call lg_mtab_calc

    ; 81.75: NO DRAG AT ALL. W_ONDRAG and W_ONMOUSEUP are exactly what
    ; kern_small refuses (kernel.asm's own OSAPI_WM_ONDRAG arm answers CF=1
    ; and carries the slot without the body), so on the machine this package
    ; exists for every byte of drag-to-select, thumb dragging and
    ; heading-resize was code that could never execute. Shift+click and
    ; shift+arrows build a range and need no kernel support at all; a scroll
    ; bar's arrows and its page areas still work, and only the thumb has
    ; stopped being draggable.

    ; stage 3.0b: the formula bar's content box. Only the buffer binding is
    ; set once - the rect is refreshed per draw by lg_flrect, since the window
    ; moves and resizes and a stale rect would draw and hit-test in the wrong
    ; place.
    mov word [lg_fline + LN_BUF], lg_editbuf
    mov word [lg_fline + LN_MAX], LG_EDITMAX + 1

    ; Arm the key-state map now rather than on the user's first shift+click.
    ; kbd_down arms itself on the first ASK and its first answer is always
    ; "up" (kernel/mouse.inc's own note), so without this the very first
    ; shift+click of a session would read as an unshifted one.
    mov al, 0x2A
    call OSAPI_KEY_DOWN

    mov si, lg_menus
    call OSAPI_MENU_SET
    ; 81.75: NO ABOUT CARD. OSAPI_ABOUT_SET takes 0 for "none" and is simply
    ; not called, which is the slot's own sanctioned state rather than the
    ; 12.2 defect of putting the same text in a Help menu of one's own - that
    ; menu is gone too. What it costs is that PLAN carries no attribution
    ; anywhere a user can reach.
    mov si, lg_defname
    mov di, lg_name
    call lg_strcpy
    call lg_note_arg                  ; a document double-clicked in the Disk
                                       ; window. NOTED here, READ at the first
                                       ; paint - see lg_note_arg's header
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
; lg_geom - in: BX = window ptr
; out: [lg_ox]/[lg_oy] content origin, [lg_cw]/[lg_ch] content size,
;      [lg_vcols]/[lg_vrows] grid cells that fit given the current scroll;
;      all registers preserved
; -----------------------------------------------------------------------------
lg_geom:
    push ax
    push cx
    push dx
    call OSAPI_WM_CONTENT
    mov [lg_ox], ax
    mov [lg_oy], dx
    add dx, LG_MBAR_H                  ; lg_goy: where the formula bar and
    mov [lg_goy], dx                   ; everything below it actually starts,
                                        ; now that the menu bar (LG_MBAR_H
                                        ; section comment) sits above them -
                                        ; lg_oy itself stays the RAW content
                                        ; origin, since lg_mbar_draw needs
                                        ; that one, not the shifted one
    call OSAPI_WM_GEOM
    mov [lg_cw], cx
    mov [lg_ch], dx

    mov ax, cx
    sub ax, LG_RH_W + LG_VSB_W         ; the vertical bar owns a strip at the
    jns .cw_ok                          ; right, so the grid is that much
    xor ax, ax                          ; narrower
.cw_ok:
    mov [lg_gridw], ax                  ; what lg_scrollto_t fits a column in
    ; EACH COLUMN ITS OWN WIDTH (81.56): walked from the scroll position until
    ; the next would not fit whole, and kept in lg_vcw for everything that
    ; places a column - lg_vcx is the only arithmetic that turns a visible
    ; column into pixels. It was one division by the one width.
    ;
    ; 81.75: no frozen panes, so there is one phase and not two - but the
    ; slot cursor is still not the real-column cursor, because a HIDDEN
    ; column is walked and takes no slot.
    push bx
    push di
    mov dx, ax                          ; DX = the pixels left
    xor di, di                          ; DI = the SLOTS filled so far
    mov ax, [lg_scrollcol]
    mov [lg_geom_rc], ax
.fcwalk:
    mov ax, [lg_geom_rc]
.cwalk:
    cmp di, LG_MAXVC
    jae .cset
    mov ax, [lg_geom_rc]
    cmp ax, LG_COLS
    jae .cset
    call lg_geom_col
    jc .cwalk
.cset:
    mov [lg_vcols], di
    pop di
    pop bx

    mov ax, [lg_ch]
    sub ax, LG_MBAR_H + LG_FB_H + LG_CH_H + LG_SB_H + LG_HSB_H
    jns .chh_ok                         ; ...and the horizontal bar a strip
    xor ax, ax                          ; above the status bar
.chh_ok:
    mov [lg_gridh], ax
    ; 81.75: every row is LG_RH_NORMAL and none can be hidden, so what 81.60
    ; and 81.73 needed a streaming walk over a sparse table for is arithmetic
    ; again. lg_vrr is still FILLED rather than dropped: lg_vclip_row and
    ; lg_vreal_row read it, and the COLUMNS still need their own table beside
    ; it, so one shape for both is cheaper than two.
    push bx
    push di
    mov dx, ax                          ; DX = the pixels left
    xor di, di                          ; DI = the rows so far
    mov ax, [lg_scrollrow]
    mov [lg_geom_rr], ax
.rwalk:
    cmp di, LG_MAXVR
    jae .rset
    mov ax, [lg_geom_rr]
    cmp ax, LG_ROWS
    jae .rset
    call lg_geom_row
    jc .rwalk
.rset:
    mov [lg_vrows], di
    pop di
    pop bx

    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_geom_col / lg_geom_row - ONE column (or row) of lg_geom's walk (81.73).
;
; in:  [lg_geom_rc]/[lg_geom_rr] = the real index to consider, DI = the next
;      free slot, DX = the pixels left; for rows, ES:SI/CX/BX are the row
;      height table's streaming cursor exactly as the walk left them.
; out: the cursor advanced, and CF=1 to carry on / CF=0 when this one did not
;      fit and the walk is finished. DI and DX updated in place.
;
; A HIDDEN index takes no slot and no pixels and does not end the walk, which
; is the whole of what hiding is here - every other reader sees a viewport
; that simply does not contain it.
; -----------------------------------------------------------------------------
lg_geom_col:
    push bx
    mov ax, [lg_geom_rc]
    inc word [lg_geom_rc]
    call lg_colwidth                   ; 0 = hidden
    or ax, ax
    jz .skip
    mov [lg_vcw + di], al
    mov cl, 3
    shl ax, cl
    cmp ax, dx
    ja .full
    sub dx, ax
    mov bx, di
    shl bx, 1
    mov ax, [lg_geom_rc]
    dec ax
    mov [lg_vrc + bx], ax              ; slot DI shows THIS real column
    inc di
.skip:
    pop bx
    stc
    ret
.full:
    pop bx
    clc
    ret

lg_geom_row:
    mov ax, LG_RH_NORMAL
    cmp ax, dx
    ja .full
    sub dx, ax
    mov [lg_vrh + di], al
    push bx
    mov bx, di
    shl bx, 1
    mov ax, [lg_geom_rr]
    mov [lg_vrr + bx], ax              ; slot DI shows THIS real row
    pop bx
    inc word [lg_geom_rr]
    inc di
    stc
    ret
.full:
    clc
    ret

; -----------------------------------------------------------------------------
; COLUMN WIDTHS (81.56, and 81.75 moved them). 256 bytes, each a column's
; width in CHARACTERS - Excel's own unit - with 0 meaning the standard width
; lg_defch and 255 meaning HIDDEN. They used to live in the top kilobyte of
; the note claim, four sheets' worth; with notes gone and one sheet left it is
; 256 bytes of this package's OWN bss, which costs the region a quarter of a
; kilobyte and gives the heap five back.
; -----------------------------------------------------------------------------
LG_CW_HIDDEN equ 255

; lg_colwidth - in: AX = a column; out: AX = its width in characters, and ZERO
; when it is hidden - which is what makes lg_geom skip it without a second
; question (81.73)
lg_colwidth:
    push bx
    mov bx, ax
    mov al, [lg_colwtab + bx]
    xor ah, ah
    cmp al, LG_CW_HIDDEN               ; 81.73: hidden is no width at all
    je .hidden
    or al, al
    jnz .out
    mov ax, [lg_defch]
    jmp short .out
.hidden:
    xor ax, ax
.out:
    pop bx
    ret

; lg_colw_set - in: AX = a column, CL = its width in characters (0 standard)
lg_colw_set:
    push bx
    mov bx, ax
    mov [lg_colwtab + bx], cl
    pop bx
    ret

; lg_colw_clear - every column the standard width
lg_colw_clear:
    push ax
    push cx
    push di
    push es
    push ds
    pop es
    mov di, lg_colwtab
    mov cx, 256
    xor al, al
    cld
    rep stosb
    pop es
    pop di
    pop cx
    pop ax
    ret


; -----------------------------------------------------------------------------
; ROW GEOMETRY (81.75). Every row is LG_RH_NORMAL pixels.
;
; 81.60 made a row's height a per-row TWIPS figure kept in a sorted sparse
; table, and 81.73 let a row be hidden; between them the visible-row mapping
; stopped being arithmetic and became a walk over lg_vrh. Neither survives
; here - a budget's rows are all the same height - so the three routines below
; are arithmetic again, and the table, its dialog, the twips conversions and
; the whole of lg_rc_sides/lg_rc_table (which existed to move the border, note
; and height records with their cells) go with them.
; -----------------------------------------------------------------------------

; lg_vry - in: AX = a visible row (0..lg_vrows); out: AX = its top edge, in
; pixels from the grid's
lg_vry:
    push dx
    mov dx, LG_RH_NORMAL
    mul dx
    pop dx
    ret

; lg_vheight - in: AX = a visible row; out: AX = its height in pixels
lg_vheight:
    mov ax, LG_RH_NORMAL
    ret

; lg_vtoff - in: AX = a visible row; out: how far below its top the text
; starts, which with one height for every row is nothing
lg_vtoff:
    xor ax, ax
    ret

lg_vcx:
    push bx
    push cx
    mov cx, ax
    xor ax, ax
    xor bx, bx
.l:
    jcxz .d
    add al, [lg_vcw + bx]
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

; lg_vwidth - in: AX = a visible column; out: AX = its width in pixels
lg_vwidth:
    push bx
    mov bx, ax
    mov al, [lg_vcw + bx]
    xor ah, ah
    push cx
    mov cl, 3
    shl ax, cl
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; FREEZE PANES (81.70). A visible column/row index (0..lg_vcols/vrows-1) no
; longer means [lg_scrollcol/row + index] once lg_freezecol/row is nonzero:
; lg_geom lays lg_vcw/lg_vrh out as the frozen prefix (real columns/rows
; 0..freeze-1, always shown) followed by the scrolling suffix (real
; lg_scrollcol/row and up). lg_vreal_col/row is that mapping; lg_vclip_col/
; row is its inverse for clamping a REAL range (a selection, a damage rect)
; into visible-index space the way lg_updsel/lg_drawsel already needed to
; before freeze existed, just freeze-aware now.
; -----------------------------------------------------------------------------

; lg_vreal_col - in: AX = a visible column (0..lg_vcols-1); out: AX = the
; real column it shows.
;
; 81.73 made this a TABLE READ. It was arithmetic - the frozen prefix's index
; is its own real column, and past it the scrolling suffix picks up at
; lg_scrollcol - and a HIDDEN column ends that: the slots no longer march in
; step with the columns, so lg_geom records which real one each slot got and
; everything reads it back from here. It is the smaller routine of the two.
lg_vreal_col:
    push bx
    mov bx, ax
    shl bx, 1
    mov ax, [lg_vrc + bx]
    pop bx
    ret

; lg_vreal_row - the same, for rows
lg_vreal_row:
    push bx
    mov bx, ax
    shl bx, 1
    mov ax, [lg_vrr + bx]
    pop bx
    ret

; lg_vclip_col - in: AX = real c1, BX = real c2 (c1 <= c2). out: CF=1, AX =
; visible c1 (rounded UP into view), BX = visible c2 (rounded DOWN into
; view); CF=0 if the whole [c1,c2] is off-screen. A column short of
; lg_freezecol is always visible, at its own index; lg_updsel/lg_drawsel
; used to do this inline with a bare [lg_scrollcol] subtraction - this is
; that clamp, freeze-aware, factored out because now two axes' worth of
; caller need the identical shape
; -----------------------------------------------------------------------------
; lg_vclip - in: AX = lo, BX = hi (REAL indices, lo <= hi), SI = the slot
; table, CX = how many slots it holds. out: AX = the first slot whose real
; index lies in [lo,hi], BX = the last; CF=0 when no slot does.
;
; 81.73 made this a SCAN. Before hidden rows and columns it was arithmetic
; with each edge clamped, and it cannot be any more - the visible slots no
; longer march in step with the real indices. The scan is over at most
; LG_MAXVC = 80 entries and runs on a selection move, not per cell.
;
; A range that is ENTIRELY hidden answers CF=0, which is the right answer and
; the same one an off-screen range gives: there is nothing to draw either way.
; -----------------------------------------------------------------------------
lg_vclip:
    push dx
    push di
    mov [lg_vcl_lo], ax
    mov [lg_vcl_hi], bx
    mov word [lg_vcl_a], 0xFFFF
    xor di, di
.l:
    cmp di, cx
    jae .done
    mov bx, di
    shl bx, 1
    mov dx, [si + bx]
    cmp dx, [lg_vcl_lo]
    jb .next
    cmp dx, [lg_vcl_hi]
    ja .next
    cmp word [lg_vcl_a], 0xFFFF
    jne .setb
    mov [lg_vcl_a], di
.setb:
    mov [lg_vcl_b], di
.next:
    inc di
    jmp short .l
.done:
    cmp word [lg_vcl_a], 0xFFFF
    je .no
    mov ax, [lg_vcl_a]
    mov bx, [lg_vcl_b]
    pop di
    pop dx
    stc
    ret
.no:
    pop di
    pop dx
    clc
    ret

; lg_vclip_col / lg_vclip_row - in: AX = real c1/r1, BX = real c2/r2. out: the
; visible range, CF=0 when none of it shows
lg_vclip_col:
    push cx
    push si
    mov si, lg_vrc
    mov cx, [lg_vcols]
    call lg_vclip
    pop si
    pop cx
    ret

lg_vclip_row:
    push cx
    push si
    mov si, lg_vrr
    mov cx, [lg_vrows]
    call lg_vclip
    pop si
    pop cx
    ret

; lg_vreal_col - lg_vclip_col clamps a RANGE into view, this answers whether
; one already-real column (the border table's own stored key, in
; lg_drawborders' sparse walk) is showing at all
lg_vidx_col:
    push bx
    push cx
    xor bx, bx
    mov cx, [lg_vcols]
.l:
    jcxz .no
    cmp [lg_vrc + bx], ax
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

; lg_vidx_row - the same, for rows
lg_vidx_row:
    push bx
    push cx
    xor bx, bx
    mov cx, [lg_vrows]
.l:
    jcxz .no
    cmp [lg_vrr + bx], ax
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
; it. Taken into Undo's own claim (LG_CLAIM_UNDO_KB) before the command runs;
; a document too big for it cannot be undone ("Can't Undo"), the honest
; answer. Undo SWAPS the two, through the staging claim, so Redo is the same
; operation again.
;
; Layout in lg_undoseg, and in staging during a swap: LG_UD_HDR bytes of
; header - ncells, nbord, nnote, txtlen - then the three arrays and the 2048
; bytes of widths and row heights (the height table carries its own count).
; =============================================================================
LG_UD_HDR    equ 8
LG_UL_ENTRY  equ 0                     ; the labels, lg_ud_names' order
LG_UL_CUT    equ 1
LG_UL_PASTE  equ 2
LG_UL_CLEAR  equ 3
LG_UL_PSPEC  equ 4
LG_UL_PLINK  equ 5
LG_UL_DEL    equ 6
LG_UL_INS    equ 7
LG_UL_FILLR  equ 8
LG_UL_FILLD  equ 9
LG_UL_SORT   equ 10
LG_UL_KEEP   equ 0xFE                  ; lg_ud_kind: changes nothing Undo holds
LG_UL_DROP   equ 0xFF                  ; ...or changes what it cannot reverse
lg_ud_names:  dw lg_ud_n0, lg_ud_n1, lg_ud_n2, lg_ud_n3, lg_ud_n4, lg_ud_n5
              dw lg_ud_n6, lg_ud_n7, lg_ud_n8, lg_ud_n9, lg_ud_n10
lg_ud_n0:     db 'Entry', 0
lg_ud_n1:     db 'Cut', 0
lg_ud_n2:     db 'Paste', 0
lg_ud_n3:     db 'Clear', 0
lg_ud_n4:     db 'Paste Special', 0
lg_ud_n5:     db 'Paste Link', 0
lg_ud_n6:     db 'Delete', 0
lg_ud_n7:     db 'Insert', 0
lg_ud_n8:     db 'Fill Right', 0
lg_ud_n9:     db 'Fill Down', 0
lg_ud_n10:    db 'Sort', 0
lg_ud_sundo:  db 'Undo ', 0
lg_ud_sredo:  db 'Redo ', 0
lg_ud_cant:   db MENU_DIS, "Can't Undo", 0
; lg_fdlg_apply's kinds: Number Align Font Insert Delete ColW RowH Clear New
; Calc Sort Gallery SaveFmt PasteSpecial Protection
lg_ud_kind:   db LG_UL_DROP, LG_UL_DROP, LG_UL_DROP, LG_UL_INS, LG_UL_DEL
              db LG_UL_DROP, LG_UL_DROP, LG_UL_CLEAR, LG_UL_DROP, LG_UL_KEEP
              db LG_UL_SORT, LG_UL_KEEP, LG_UL_KEEP, LG_UL_PSPEC, LG_UL_DROP
              db LG_UL_DROP, LG_UL_DROP    ; 81.71: Extract WRITES cells, and
                                             ; 81.72's Series does too
                                             ; the Reference Guide says Undo
                                             ; cannot reverse it - so DROP,
                                             ; which is Undo saying so
lg_ud_kind_end:                        ; one entry per lg_fdlg kind: asserted
                                       ; beside LG_FDK_N, which is defined later

; lg_undo_begin - AL = the label. Snapshot the document into Undo's claim and
; mark the command in progress, so lg_commit does not take one of its own
lg_undo_begin:
    push ax
    push dx
    mov byte [lg_ud_busy], 1
    mov [lg_ud_lab], al
    mov dx, [lg_undoseg]
    or dx, dx
    jz .no
    call lg_undo_save                  ; CF=1: too big for it
    jc .no
    mov byte [lg_ud_redo], 0
    call lg_undo_label
    jmp short .out
.no:
    call lg_undo_drop
.out:
    pop dx
    pop ax
    ret

lg_undo_end:
    mov byte [lg_ud_busy], 0
    ret

; lg_undo_drop - nothing to undo: "Can't Undo", greyed
lg_undo_drop:
    push si
    push di
    mov si, lg_ud_cant
    mov di, lg_it_undo
    call lg_strcpy
    pop di
    pop si
    ret

; lg_undo_label - "Undo <action>" or "Redo <action>", enabled
lg_undo_label:
    push ax
    push bx
    push si
    push di
    mov si, lg_ud_sundo
    cmp byte [lg_ud_redo], 0
    je .u
    mov si, lg_ud_sredo
.u:
    mov di, lg_it_undo
    call lg_strcpy
    mov di, lg_it_undo
.end:
    cmp byte [di], 0
    je .cat
    inc di
    jmp short .end
.cat:
    mov bl, [lg_ud_lab]
    xor bh, bh
    shl bx, 1
    mov si, [lg_ud_names + bx]
    call lg_strcpy
    pop di
    pop si
    pop bx
    pop ax
    ret

; lg_undo_size - out: AX = the bytes a snapshot of the document takes, CF=1
; when that is more than Undo's claim holds
lg_undo_size:
    push dx
    mov ax, [lg_ncells]
    mov dx, LG_C_SZ
    mul dx
    jc .big
    add ax, LG_UD_HDR + 256            ; 81.75: the cells, and the 256 column
    jc .big                            ; widths. The border and note tables
    cmp ax, LG_CLAIM_UNDO_KB * 1024    ; have gone and the row heights with
    ja .big                            ; them
    clc
    pop dx
    ret
.big:
    stc
    pop dx
    ret

; lg_fcopy - CX bytes from AX:SI to DX:DI, forward. SI and DI advance.
lg_fcopy:
    push ds
    push es
    mov es, dx
    mov ds, ax
    cld
    rep movsb
    pop es
    pop ds
    ret

; lg_undo_save - the live document into segment DX at offset 0.
; CF=1 when it does not fit Undo's claim, and nothing is written
lg_undo_save:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    call lg_undo_size
    jc .out
    mov es, dx
    mov ax, [lg_ncells]
    mov [es:0], ax
    mov ax, [lg_txtlen]
    mov [es:6], ax
    mov di, LG_UD_HDR
    mov ax, [lg_ncells]                ; every length from OUR bss before any
    mov bx, LG_C_SZ                    ; segment register moves (the lesson of
    push dx                            ; the DS-switch hang)
    mul bx
    pop dx
    mov cx, ax
    mov ax, [lg_cellseg]
    xor si, si
    call lg_fcopy
    mov cx, 256                        ; ...and the column widths, which are
    mov ax, ds                         ; this package's OWN bss now (81.75)
    mov si, lg_colwtab
    call lg_fcopy
    clc
.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; lg_undo_load - segment AX at offset 0 back into the live document
lg_undo_load:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, ax
    mov bx, [es:0]
    mov [lg_ncells], bx
    mov bx, [es:6]
    mov [lg_txtlen], bx
    mov si, LG_UD_HDR
    push ax
    mov ax, [lg_ncells]
    mov bx, LG_C_SZ
    mul bx
    mov cx, ax
    pop ax
    mov dx, [lg_cellseg]
    xor di, di
    call lg_fcopy
    mov cx, 256
    mov dx, ds
    mov di, lg_colwtab
    call lg_fcopy
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; lg_undo_do - Edit > Undo (or Redo): the live document and the snapshot
; change places, through the staging claim, so doing it again redoes it
lg_undo_do:
    push ax
    push cx
    push dx
    push si
    push di
    mov dx, [lg_undoseg]
    or dx, dx
    jz .out
    mov byte [lg_editing], 0           ; an edit in progress is abandoned, as
                                       ; Excel's Undo abandons one - committing
                                       ; it would snapshot over the snapshot
    mov dx, [lg_stgseg]                ; now -> staging
    call lg_undo_save
    jc .out                            ; it has outgrown Undo: leave both
    call lg_undo_size                  ; ...measured NOW, before the load
    push ax                            ; changes the counts it is made of
    mov ax, [lg_undoseg]               ; the snapshot -> live
    call lg_undo_load
    pop cx                             ; staging -> the snapshot: what live was
    push ds
    push es
    mov es, [lg_undoseg]
    mov ds, [lg_stgseg]
    xor si, si
    xor di, di
    cld
    rep movsb
    pop es
    pop ds
    xor byte [lg_ud_redo], 1
    call lg_undo_label
    inc word [lg_pass]                 ; every formula recomputes against what
    mov byte [lg_commitdirty], 1       ; is there now
    mov byte [lg_chartdirty], 1
    call lg_geom
    mov si, [lg_ownwin]
    call lg_repaint
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
; lg_note_arg - take the document this instance was launched with, if any.
; OSAPI_ARG_FILE is READ-AND-CLEAR (SPEC.md 54.5), so asking once here spends
; it and a later instance can never inherit it.
;
; THIS COPIES A NAME AND TOUCHES NO DISK, and that is the whole point of
; splitting it from lg_deferred_ld. A floppy read inside the entry proc runs
; under the LOADER LOCK and freezes the desktop (SPEC.md 69.6) - texpad's own
; ARG_FILE note carries the same warning, having paid for it.
; -----------------------------------------------------------------------------
lg_note_arg:
    push ax
    push bx                           ; ARG_FILE answers in BL, and the entry
    push cx                           ; proc that calls this has not banked BX
    push dx
    push si
    push di
    push es
    call OSAPI_ARG_FILE
    jc .none                          ; CF=1 = launched empty, the usual case
    mov [lg_argdir], dx
    mov [lg_argdrv], bl
    mov ax, KERNEL_SEG                ; the name lives in the KERNEL's segment,
    mov es, ax                        ; not ours
    mov di, lg_name
    mov cx, LG_NAMEMAX
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
    mov byte [lg_needld], 1
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
; lg_deferred_ld - and NOW the disk read, from the first paint, which happens
; after the window is up and the loader lock is long gone. Clears the flag
; first, so a read that fails is not retried on every repaint for the rest of
; the session.
; -----------------------------------------------------------------------------
lg_deferred_ld:
    push ax
    push bx
    push cx
    push dx
    push si                           ; lg_paint takes SI as its window ptr
    push di                           ; the instruction after this returns -
    push es                           ; OSAPI_FILE_GOTO documents no output
    mov byte [lg_needld], 0           ; but promises nothing about SI either

    mov dx, [lg_argdir]
    mov bl, [lg_argdrv]
    call OSAPI_FILE_GOTO
    jc .out                           ; could not list it: the volume is back
    call lg_doread                    ; at the root and lg_name still names a
.out:                                 ; file that is not here - leave the
    pop es                            ; sheet empty rather than half-read
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

lg_paint:
    push bx
    cmp byte [lg_needld], 0           ; the associated document lands HERE, so
    je .nold                          ; it is on screen at the first paint
    call lg_deferred_ld               ; instead of waiting for a key or click
.nold:
    mov bx, si
    call lg_geom
    call lg_drawall
    cmp byte [lg_abon], 0             ; ...and the About card LAST, over the
    je .noab                          ; grid it is opaque about (SPEC.md 20.5.1)
    push si
    mov bx, si
    mov si, lg_ablines
    call os88ui_about_d               ; _d: this paint's region is already armed
    pop si
.noab:
    pop bx
    ret

lg_repaint:
    push ax
    push bx
    push cx
    push dx
    mov bx, si
    call lg_geom
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [lg_ox]
    mov bx, [lg_oy]
    mov cx, [lg_ox]
    add cx, [lg_cw]
    dec cx
    mov dx, [lg_oy]
    add dx, [lg_ch]
    dec dx
    call OSAPI_GFX_FILL
    call lg_drawall
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_onclick - W_ONCLICK: CX=x, DX=y (screen), SI=window; gfx lock held
; -----------------------------------------------------------------------------
lg_onclick:
    push ax
    push bx
    push cx
    push dx
    call lg_abdismiss                  ; the credits are up: this click is
    jc .out                            ; spent taking them down
    cmp word [lg_fdlg_win], 0
    je .nofdlg
    call lg_fdlg_close_r                 ; stage 1.8: a Format dialog isn't
                                        ; kernel-modal (no fdlg_grab/fdlg_top
                                        ; machinery outside the kernel - see
                                        ; the section comment above
                                        ; lg_fdlg_open), so a click that
                                        ; reaches the main grid at all means
                                        ; the dialog visually lost focus;
                                        ; treat it as Cancel rather than
                                        ; leave lg_fdlg_win stuck non-zero,
                                        ; which would gate every future
                                        ; Format menu command shut for good
.nofdlg:
    mov word [lg_msg], 0
    mov bx, si
    call lg_geom
    call lg_mbar_hit                   ; stage 2.x: Sheet's own in-window
    cmp al, LG_M_NONE                  ; menu bar (see the LG_MBAR_H section
    je .notmenu                        ; comment) claims a click on its strip
    call lg_mtrack                     ; before anything below ever sees it -
    jmp .out                           ; AL=menu index (from lg_mbar_hit),
                                        ; SI=window (still this callback's own
                                        ; untouched SI)
.notmenu:
    call lg_sbclick                    ; stage 3.0a+: the two scroll bars get
    jc .out                            ; the click before the grid does
    call lg_gridhit                    ; CX=x, DX=y -> CF=1 + AX=col, BX=row
    jnc .out
    call lg_shiftdown                  ; stage 3.0a: shift+click extends the
    jc .extend                         ; range from the existing anchor
    call lg_select                     ; plain click: collapse and move
    mov byte [lg_dragging], 1          ; ...and arm the drag from here
    push ax
    mov ax, [lg_selcol]
    mov [lg_drag_col], ax
    mov ax, [lg_selrow]
    mov [lg_drag_row], ax
    pop ax
    jmp .out
.extend:
    call lg_select_to
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_select - commit any pending edit, move the selection, scroll to show
; it, and repaint. AX = new column, BX = new row. SI must be the window
; ptr; not touched here so it stays that way for lg_repaint.
; -----------------------------------------------------------------------------
lg_select:
    push ax
    push bx
    mov word [lg_tabanchor], 0       ; ANY other move ends a Tab run - only the
    call lg_selbank                  ; Tab arm puts the anchor back afterwards
    call lg_commit
    mov [lg_selcol], ax
    mov [lg_selrow], bx
    mov [lg_selcol2], ax               ; stage 3.0a: a plain select COLLAPSES
    mov [lg_selrow2], bx               ; the range - anchor and extent become
                                        ; the same cell, which is exactly the
                                        ; old single-cell behaviour every
                                        ; existing caller still expects
    call lg_scrollto
    call lg_selpaint                   ; only what the move dirtied - the full
                                        ; repaint costs ~1s on a 4.77MHz 8088
                                        ; and this path runs per arrow key
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_select_to - stage 3.0a: move only the EXTENT of the range, leaving the
; anchor where it is. AX = column, BX = row. Used by shift+click, shift+arrows
; and the drag handler. SI must be the window ptr (lg_repaint's contract).
;
; Deliberately does NOT call lg_commit: extending a selection is not a
; different-cell move, and committing here would end an in-progress edit
; halfway through a drag.
; -----------------------------------------------------------------------------
lg_select_to:
    push ax
    push bx
    call lg_selbank
    cmp ax, LG_COLS
    jb .colok
    mov ax, LG_COLS - 1
.colok:
    cmp bx, LG_ROWS
    jb .rowok
    mov bx, LG_ROWS - 1
.rowok:
    mov [lg_selcol2], ax
    mov [lg_selrow2], bx
    call lg_scrollto2
    call lg_selpaint
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_selbank - bank the rect and the scroll origin a selection move starts
; from, so lg_selpaint can price the damage afterwards. Preserves everything.
; -----------------------------------------------------------------------------
lg_selbank:
    push ax
    call lg_selrect
    mov ax, [lg_selc1]
    mov [lg_oldc1], ax
    mov ax, [lg_selc2]
    mov [lg_oldc2], ax
    mov ax, [lg_selr1]
    mov [lg_oldr1], ax
    mov ax, [lg_selr2]
    mov [lg_oldr2], ax
    mov ax, [lg_scrollcol]
    mov [lg_oldscol], ax
    mov ax, [lg_scrollrow]
    mov [lg_oldsrow], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_selpaint - repaint after a selection move: as little of the window as
; the move actually dirtied. SI = the window (lg_repaint's own contract).
;
; The full repaint is ~1s on the target (PERFORMANCE.md's own table: one
; OSAPI_FONT_RUN per visible cell, plus all the chrome, plus a recalc pass),
; and this path runs once per keystroke-repeat and per drag packet - so it
; pays that price only when it must:
;   * lg_commit stored something -> full, because a dependent formula
;     anywhere on screen may now show a new value and only lg_drawall's
;     pass advance re-evaluates them;
;   * the view scrolled by rows only -> blit the surviving rows
;     (lg_scrollrow_blit) and letter just the vacated ones;
;   * by columns only -> the grid and its column half, nothing else
;     (lg_scrollcol_part - OSAPI_GFX_SCROLL is vertical-only, SPEC.md 5.5);
;   * no scroll at all -> the old cells and the new ones (lg_updsel).
; -----------------------------------------------------------------------------
lg_selpaint:
    push ax
    push cx
    cmp byte [lg_commitdirty], 0
    jne .full
    mov ax, [lg_oldscol]
    cmp ax, [lg_scrollcol]
    jne .cols
    mov cx, [lg_oldsrow]
    cmp cx, [lg_scrollrow]
    jne .rows
    call lg_updsel
    jmp .out
.rows:
    call lg_scrollrow_blit             ; CX = the row the view is leaving
    jc .full                           ; refused: pay the full price
    call lg_updsel                     ; old cells + new cells + the bars
    jmp .out
.cols:
    mov cx, [lg_oldsrow]
    cmp cx, [lg_scrollrow]
    jne .full                          ; both axes moved: a Goto, not a walk
    call lg_scrollcol_part
    call lg_drawbar                    ; the reference box changed too
    call lg_drawstatus
    jmp .out
.full:
    mov byte [lg_commitdirty], 0
    call lg_repaint
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_updsel - the no-scroll damage path: redraw the union of the old and the
; new selection rects (which covers both frames), then the two bars whose
; text names the selection. SI = the window.
; -----------------------------------------------------------------------------
lg_updsel:
    push ax
    push bx
    push cx
    push dx
    mov bx, si
    call lg_geom
    cmp word [lg_vcols], 0
    je .chrome
    cmp word [lg_vrows], 0
    je .chrome
    call lg_selrect                    ; the NEW rect, ordered
    mov ax, [lg_selc1]                 ; the union's columns...
    cmp ax, [lg_oldc1]
    jbe .c1
    mov ax, [lg_oldc1]
.c1:
    mov bx, [lg_selc2]
    cmp bx, [lg_oldc2]
    jae .c2
    mov bx, [lg_oldc2]
.c2:
    call lg_vclip_col                  ; 81.70: real range -> visible-index
    jnc .chrome                        ; range, frozen-aware; CF=0 = wholly
    mov [lg_dmgc1], ax                 ; off-screen (what the old inline
    mov [lg_dmgc2], bx                 ; [lg_scrollcol] clamp used to do)
    mov ax, [lg_selr1]                 ; the union's rows, the same
    cmp ax, [lg_oldr1]
    jbe .r1
    mov ax, [lg_oldr1]
.r1:
    mov bx, [lg_selr2]
    cmp bx, [lg_oldr2]
    jae .r2
    mov bx, [lg_oldr2]
.r2:
    call lg_vclip_row
    jnc .chrome
    mov [lg_dmgr1], ax
    mov [lg_dmgr2], bx
    call lg_dmgdraw
    call lg_drawsel
.chrome:
    call lg_drawbar
    call lg_drawstatus
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_gridhit - stage 3.0a: which cell is this screen point on?
; in:  CX = x, DX = y (screen coords, W_ONCLICK/W_ONDRAG's own)
; out: CF=1 and AX = column, BX = row (both absolute, scroll-adjusted);
;      CF=0 if the point is not over a grid cell. CX/DX restored.
;
; Lifted verbatim out of lg_onclick so the drag handler hit-tests exactly the
; same way a click does - two copies of this arithmetic would drift the first
; time the header or menu-bar height changed.
; -----------------------------------------------------------------------------
lg_gridhit:
    push cx
    push dx
    mov ax, cx
    sub ax, [lg_ox]
    sub ax, LG_RH_W
    js .no
    mov bx, dx
    sub bx, [lg_goy]                   ; grid origin, NOT raw content origin -
    sub bx, LG_FB_H + LG_CH_H          ; the menu bar strip sits above it
    js .no
    mov dx, ax                         ; DX = pixels into the grid: walked
    xor cx, cx                         ; across the columns' own widths (81.56)
.hwalk:
    cmp cx, [lg_vcols]
    jae .no
    mov ax, cx
    call lg_vwidth
    cmp dx, ax
    jb .hcol
    sub dx, ax
    inc cx
    jmp short .hwalk
.hcol:
    mov ax, cx
    call lg_vreal_col                  ; 81.70: frozen or scrolling, the
    mov [lg_wcol], ax                  ; visible->real mapping is the same
    xor cx, cx                         ; ...and down the rows' own heights
.vwalk:                                ; (81.60), BX = pixels into the grid
    cmp cx, [lg_vrows]
    jae .no
    mov ax, cx
    call lg_vheight
    cmp bx, ax
    jb .vrow
    sub bx, ax
    inc cx
    jmp short .vwalk
.vrow:
    mov ax, cx
    call lg_vreal_row
    mov bx, ax
    mov ax, [lg_wcol]
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
; lg_flkey - stage 3.0b: hand one keystroke to the formula bar's field, then
; resync this app's own lg_editlen from the field's LN_LEN so lg_commit and
; every other existing reader keeps working unchanged.
; in: AL = ascii, AH = scan.
;
; REDRAWS ONLY THE FIELD. An editing keystroke changes no cell, so the full
; lg_repaint this used to end with - every visible cell re-lettered plus a
; recalc pass, ~1s per keystroke on a 4.77MHz 8088 - repainted identical
; pixels and dropped keys on the target. os88line_draw is one opaque run
; plus the strip past the text; lg_flmarg covers the one span it does not.
; -----------------------------------------------------------------------------
lg_flkey:
    push ax
    push si
    call lg_flrect                     ; the box may have moved since the last
                                        ; draw - os88line hit-tests and draws
                                        ; from the same four words
    mov si, lg_fline
    call os88line_key
    mov ax, [si + LN_LEN]
    mov [lg_editlen], al               ; LN_LEN is a word and LG_EDITMAX is
                                        ; 63, so the low byte is the whole of
                                        ; it - but keep them in step, because
                                        ; lg_commit still reads lg_editlen
    call lg_flmarg
    call os88line_draw
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_flmarg - white the strip between the content box's frame and os88line's
; 8-aligned pen. The field's own draw covers its run and the strip PAST the
; text (os88line_draw's header), so this margin is the one span neither
; touches - and on the first keystroke of an edit it still holds the leftmost
; pixels of the static text lg_drawbar drew there. SI = lg_fline, whose rect
; lg_flrect has already refreshed. Preserves everything.
; -----------------------------------------------------------------------------
lg_flmarg:
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
; lg_flsync - stage 3.0b: the buffer was filled by someone other than the
; field (F2's seed-from-cell, or a Paste). Recompute the field's own length
; from the NUL and park the caret at the end, which is where a just-loaded
; value should leave it. Preserves everything.
; -----------------------------------------------------------------------------
lg_flsync:
    push ax
    push cx
    push si
    xor cx, cx
    mov si, lg_editbuf
.cnt:
    cmp byte [si], 0
    je .done
    cmp cx, LG_EDITMAX                 ; never trust an unterminated buffer
    jae .done
    inc si
    inc cx
    jmp .cnt
.done:
    mov [lg_editlen], cl
    mov si, lg_fline
    mov [si + LN_LEN], cx
    mov [si + LN_CAR], cx              ; caret at the end
    mov word [si + LN_VIEW], 0
    mov byte [si + LN_FOCUS], 1
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_editstart - stage 3.0b: begin a fresh, EMPTY edit (the first character
; typed into a cell). Resets both this app's own edit state and the field's.
; -----------------------------------------------------------------------------
lg_editstart:
    push si
    mov byte [lg_editing], 1
    mov byte [lg_editlen], 0
    mov byte [lg_editbuf], 0
    mov si, lg_fline
    mov word [si + LN_LEN], 0
    mov word [si + LN_CAR], 0
    mov word [si + LN_VIEW], 0
    mov byte [si + LN_FOCUS], 1
    pop si
    ret

; -----------------------------------------------------------------------------
; lg_arrowsrc - stage 3.0a: where does an arrow key start counting from?
; out: AX = column, BX = row - the ANCHOR normally, the EXTENT while shift is
; held, which is what makes shift+arrow grow the block from the end the user
; last moved rather than snapping it back to the anchor.
; -----------------------------------------------------------------------------
lg_arrowsrc:
    call lg_shiftdown
    jc .ext
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    ret
.ext:
    mov ax, [lg_selcol2]
    mov bx, [lg_selrow2]
    ret

; -----------------------------------------------------------------------------
; lg_shiftdown - out: CF=1 if either shift key is held. Preserves everything.
; 0x2A/0x36 are the set-1 make codes; kbd_down's map is 128 bits wide, one per
; make code, so it answers for any key and not just the named KSC_* few.
; -----------------------------------------------------------------------------
lg_shiftdown:
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
; lg_selrect - stage 3.0a: normalize the anchor/extent pair into an ordered
; rect. Out: [lg_selc1] <= [lg_selc2], [lg_selr1] <= [lg_selr2]. Every range
; consumer reads these rather than comparing the raw pair itself, so "which
; corner did the user start from" is answered in exactly one place.
; -----------------------------------------------------------------------------
lg_selrect:
    push ax
    push bx
    mov ax, [lg_selcol]
    mov bx, [lg_selcol2]
    cmp ax, bx
    jbe .cols_ok
    xchg ax, bx
.cols_ok:
    mov [lg_selc1], ax
    mov [lg_selc2], bx
    mov ax, [lg_selrow]
    mov bx, [lg_selrow2]
    cmp ax, bx
    jbe .rows_ok
    xchg ax, bx
.rows_ok:
    mov [lg_selr1], ax
    mov [lg_selr2], bx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_selsingle - out: CF=1 if the selection is a single cell (anchor==extent).
; The gate every command that has no range semantics yet uses.
; -----------------------------------------------------------------------------
lg_selsingle:
    push ax
    mov ax, [lg_selcol]
    cmp ax, [lg_selcol2]
    jne .no
    mov ax, [lg_selrow]
    cmp ax, [lg_selrow2]
    jne .no
    stc
    jmp .out
.no:
    clc
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_scrollto - move the scroll origin the least amount that brings the
; current selection into the viewport described by [lg_vcols]/[lg_vrows]
; -----------------------------------------------------------------------------
lg_scrollto:
    push ax
    mov ax, [lg_selcol]
    mov [lg_sc_tcol], ax
    mov ax, [lg_selrow]
    mov [lg_sc_trow], ax
    pop ax
    jmp lg_scrollto_t

; stage 3.0a: the same scroll, aimed at the range's moving END instead of its
; anchor - what a drag or a shift+arrow needs, since it is the extent that
; walks off-screen, not the anchor.
lg_scrollto2:
    push ax
    mov ax, [lg_selcol2]
    mov [lg_sc_tcol], ax
    mov ax, [lg_selrow2]
    mov [lg_sc_trow], ax
    pop ax
    jmp lg_scrollto_t
; =============================================================================
; the core: bring [lg_sc_tcol]/[lg_sc_trow] into the viewport, moving the
; scroll origin the least amount that does it
lg_scrollto_t:
    push ax
    push bx
    ; 81.73 made the "is it already on screen?" test ASK THE VIEWPORT rather
    ; than compute it. It used to be lg_scrollcol + the scrolling window's
    ; width, which is only the last visible column while the slots march in
    ; step with the columns - a hidden one anywhere between them breaks that,
    ; and lg_vidx_col is the routine that already knows.
    mov ax, [lg_sc_tcol]
    cmp ax, [lg_freezecol]             ; 81.70: the frozen prefix is always
    jb .rows                           ; visible - nothing to scroll for it,
                                        ; and lg_scrollcol may never go there
    call lg_vidx_col
    jc .rows                           ; already showing: leave the view alone
    mov ax, [lg_sc_tcol]
    cmp ax, [lg_scrollcol]
    jae .cfwd
    mov [lg_scrollcol], ax             ; it is to the LEFT: scroll onto it
    jmp short .rows
.cfwd:
    call lg_backcols                   ; to the RIGHT: walk back from it until
    mov [lg_scrollcol], ax             ; the window is full (81.56 - the
                                        ; columns are not one width, so this
                                        ; is walked and not subtracted)
.rows:
    mov ax, [lg_sc_trow]
    cmp ax, [lg_freezerow]
    jb .out
    call lg_vidx_row
    jc .out
    mov ax, [lg_sc_trow]
    cmp ax, [lg_scrollrow]
    jae .rfwd
    mov [lg_scrollrow], ax
    jmp short .out
.rfwd:
    call lg_backrows                   ; nor the rows one height (81.60)
    mov [lg_scrollrow], ax
.out:
    pop bx
    pop ax
    ret

; lg_backcols - AX = a column past the view's right edge -> AX = the scroll
; column that shows it WHOLE at the right: the columns before it, each its own
; width, as many as still fit [lg_gridw]. It subtracted the column count the
; OLD view held, which put a column wider than the ones it scrolled past
; partly or wholly off the glass
lg_backcols:
    push bx
    push cx
    push dx
    mov bx, ax                         ; BX = the first column shown
    call lg_colwidth
    mov cl, 3
    shl ax, cl
    mov dx, ax                         ; DX = the pixels they take
.l:
    or bx, bx
    jz .out
    mov ax, bx
    dec ax
    call lg_colwidth
    mov cl, 3
    shl ax, cl
    add ax, dx
    cmp ax, [lg_gridw]
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

; lg_backrows - AX = a row below the view -> AX = the scroll row that shows it
; whole at the bottom. 81.75: one height for every row, so it is a count.
lg_backrows:
    push bx
    push dx
    mov bx, ax                         ; BX = the first row shown
    mov dx, LG_RH_NORMAL               ; DX = the pixels they take
.l:
    or bx, bx
    jz .out
    mov ax, dx
    add ax, LG_RH_NORMAL
    cmp ax, [lg_gridh]
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
; lg_onkey - W_ONKEY: AL=ascii (0 for a navigation key), AH=scan, SI=window
; -----------------------------------------------------------------------------
lg_onkey:
    push ax
    push bx
    push cx
    push dx
    call lg_abdismiss                  ; any key takes the credits down, and
    jc .out                            ; is spent doing it
    cmp word [lg_fdlg_win], 0
    je .nofdlg
    call lg_fdlg_close_r                 ; see lg_onclick's own copy of this
                                        ; guard for why
.nofdlg:
    mov word [lg_msg], 0
    mov bx, si
    call lg_geom
    or al, al
    jz .navkey
    ; stage 3.0a: a shift+arrow arrives WITH an ASCII byte. The arrow and the
    ; keypad digit share one scancode - 0x4D is both Right and KP-6, the E0
    ; prefix naming no key of its own (kernel/mouse.inc's own note) - so the
    ; kernel's shifted translation hands us '6'. Without this test, holding
    ; shift and pressing an arrow would TYPE A DIGIT into the cell instead of
    ; extending the selection, which is exactly what it did before this check.
    call lg_shiftdown
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
    cmp byte [lg_editing], 0
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
    call lg_flkey
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
    cmp byte [lg_editing], 0
    je .out
    mov byte [lg_editing], 0
    call lg_repaint
    jmp .out
.notesc:
    cmp al, 13                       ; Enter: commit, move down - and back to
    jne .nottab                      ; the column this ROW's entry started in,
    call lg_commit                   ; which is what Excel does after a run of
    mov ax, [lg_tabanchor]           ; Tabs. lg_select clears the anchor, so
    or ax, ax                        ; Enter consuming it needs no extra step
    jz .noanchor
    dec ax                           ; stored as col+1, see the Tab arm below
    jmp .enterrow
.noanchor:
    mov ax, [lg_selcol]
.enterrow:
    mov bx, [lg_selrow]
    inc bx
    cmp bx, LG_ROWS
    jb .entergo
    mov bx, LG_ROWS - 1
.entergo:
    call lg_select
    jmp .out
.nottab:
    cmp al, 9                        ; Tab: commit, move right
    jne .notbs
    call lg_commit
    mov ax, [lg_tabanchor]           ; the first Tab of a run records where it
    or ax, ax                        ; started; later ones keep that. Stored as
    jnz .haveanchor                  ; col+1, so a ZEROED bss reads as "none"
    mov ax, [lg_selcol]              ; and no init pass is needed
    inc ax
.haveanchor:
    push ax                          ; lg_select clears it, so it is put back
    mov ax, [lg_selcol]              ; afterwards rather than before
    mov bx, [lg_selrow]
    inc ax
    cmp ax, LG_COLS
    jb .tabgo
    mov ax, LG_COLS - 1
.tabgo:
    call lg_select
    pop ax
    mov [lg_tabanchor], ax
    jmp .out
.notbs:
    cmp al, 8                        ; Backspace: the field owns it now, so it
    jne .notdigit                    ; deletes AT THE CARET rather than only
    cmp byte [lg_editing], 0         ; ever chopping the last character
    je .out
    call lg_flkey
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
    ; what the characters MEAN to lg_commit, which is where that decision
    ; belongs and where it already lives.
    cmp al, ' '
    jb .out                            ; control characters are handled above
    cmp al, 0x7E                       ; (Enter, Escape, Backspace, arrows)
    ja .out                            ; and are not text
.accept:
    cmp byte [lg_editing], 0
    jnz .append
    call lg_editstart                ; first character into an empty cell
.append:
    call lg_flkey                    ; the field inserts AT THE CARET and
    jmp .out                         ; bounds itself against LN_MAX
; stage 3.0a: an arrow moves the ANCHOR (collapsing the range) normally, or
; walks the EXTENT when shift is held. Both halves share one source-load and
; one dispatch rather than four near-copies of each.
.left:
    call lg_arrowsrc
    or ax, ax
    jz .out
    dec ax
    jmp .arrowgo
.right:
    call lg_arrowsrc
    cmp ax, LG_COLS - 1
    jae .out
    inc ax
    jmp .arrowgo
.up:
    call lg_arrowsrc
    or bx, bx
    jz .out
    dec bx
    jmp .arrowgo
.down:
    call lg_arrowsrc
    cmp bx, LG_ROWS - 1
    jae .out
    inc bx
.arrowgo:
    call lg_shiftdown
    jc .arrowext
    call lg_select
    jmp .out
.arrowext:
    call lg_select_to
    jmp .out
.pgup:
    mov bx, [lg_selrow]
    mov ax, [lg_vrows]
    cmp bx, ax
    jae .pgup_sub
    xor bx, bx
    jmp .pgup_go
.pgup_sub:
    sub bx, ax
.pgup_go:
    mov ax, [lg_selcol]
    call lg_select
    jmp .out
.pgdn:
    mov bx, [lg_selrow]
    add bx, [lg_vrows]
    cmp bx, LG_ROWS - 1
    jbe .pgdn_go
    mov bx, LG_ROWS - 1
.pgdn_go:
    mov ax, [lg_selcol]
    call lg_select
    jmp .out
.home:
    xor ax, ax
    mov bx, [lg_selrow]
    call lg_select
    jmp .out
.f2:
    call lg_beginedit
    jmp .out
.delcell:
    mov byte [lg_editing], 0
    mov al, LG_UL_CLEAR                ; Del is Edit Clear's key, and undoable
    call lg_undo_begin                 ; as it is (81.57)
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    call lg_clearcell
    call lg_undo_end
    call lg_repaint
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_beginedit - F2: seed the edit buffer from the selected cell's current
; value (blank if the cell is empty) and enter edit mode. SI must be the
; window ptr for lg_repaint.
; -----------------------------------------------------------------------------
lg_beginedit:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov dx, si                        ; DX = window ptr, stashed (SI is used
                                       ; as scratch throughout this function)
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    call lg_findcell
    jnc .blank
    push es
    mov es, [lg_cellseg]
    test byte [es:di+4], 1
    jz .plainval
    mov ax, [es:di+LG_C_FOFF]                 ; formula_off
    pop es
    mov byte [lg_editbuf], '='
    mov di, lg_editbuf + 1
    mov si, ax
    push es
    mov es, [lg_txtseg]
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
    call lg_cellnum                   ; the value as decimal text
    pop es
    mov si, lg_numbuf
    mov di, lg_editbuf
    call lg_strcpy
.havelen:
    xor cx, cx
    mov si, lg_editbuf
.cnt:
    cmp byte [si], 0
    je .setlen
    inc si
    inc cx
    jmp .cnt
.setlen:
    mov [lg_editlen], cl
    jmp .go
.blank:
    mov byte [lg_editbuf], 0
    mov byte [lg_editlen], 0
.go:
    mov byte [lg_editing], 1
    call lg_flsync                    ; stage 3.0b: the field's own length,
                                       ; caret and scroll must match the
                                       ; buffer we just seeded, or the caret
                                       ; draws somewhere the text is not
    mov si, dx                        ; SI = window ptr, restored
    call lg_repaint
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_paren_ok - do the parentheses in [lg_editbuf] balance? out: CF=1 = no.
;
; Lexical only, and deliberately so: it runs at COMMIT, where re-running the
; evaluator would mean recursion, cycle marks and memoisation stamps as a side
; effect of typing. It catches the bracket a person actually drops; it does not
; claim to be a syntax check, and something like `=1+` still commits and reads
; as 0. A real answer needs an error VALUE - LG_T_ERR is reserved and nothing
; produces one yet - and that is a feature, not this.
;
; A quoted string is skipped whole, so a bracket inside a label literal does
; not count toward the balance.
; -----------------------------------------------------------------------------
lg_paren_ok:
    push ax
    push cx
    push si
    mov si, lg_editbuf
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
; lg_commit - if a cell is being edited, parse the buffer and store it (an
; empty buffer, or one that doesn't parse as a single signed integer,
; clears the cell instead); either way stop editing. SI is not touched.
; Out: CF=1 when the store was REFUSED (text arena or cell table full) and
; the cell keeps what it had - lg_sort_permcol stops on it; every older
; caller ignores it, which is what the silence always was.
; -----------------------------------------------------------------------------
lg_commit:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    cmp byte [lg_editing], 0
    je .out
    cmp byte [lg_ud_busy], 0          ; a TYPED entry is undoable on its own
    jne .inside                       ; (81.57); one made by Paste, Fill or
    mov al, LG_UL_ENTRY               ; Sort is part of theirs, which took
    call lg_undo_begin                ; the snapshot already
    call lg_undo_end
.inside:
    mov byte [lg_editing], 0
    mov byte [lg_commitdirty], 1      ; cell data changes below (even an empty
                                      ; buffer clears the cell) - lg_selpaint
                                      ; reads this and pays the full repaint,
                                      ; whose pass advance is what re-shows
                                      ; every dependent formula
    cmp byte [lg_editlen], 0
    jne .have
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    call lg_clearcell
    clc                               ; clearing is never refused
    jmp .out
.have:
    cmp byte [lg_editbuf], '='
    jne .numeric
    call lg_paren_ok                  ; ...and a formula must be well formed,
    jc .badformula                    ; for the same reason "3.5kg" is not 3.5
    mov si, lg_editbuf
    inc si                            ; past the '='
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    call lg_setformula
    jmp .out
.badformula:
    ; `=SUM(E2:E5` - one missing bracket - used to be STORED AS A FORMULA and
    ; quietly evaluated to 0, which is the worst answer available: a plausible
    ; number, in the right place, that nobody has reason to doubt. It is kept
    ; as a LABEL instead, so the cell shows the text that was typed, and the
    ; status bar says why. That is this app's existing rule for input that
    ; cannot be what it looks like, applied to the one type that was exempt.
    mov word [lg_msg], lg_s_badparen
    jmp .astext
.numeric:
    mov si, lg_editbuf                ; stage 4.0: a full decimal, not a signed
    call fx_atof                      ; integer. "3.5", "-0.25" and "1e3" are
    jc .astext                        ; all values now; anything fx_atof does
    mov al, [si]                      ; not consume ENTIRELY is not a number,
    or al, al                         ; which is what keeps "3.5kg" from
    jnz .astext                       ; silently becoming 3.5
    call lg_acc_store
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    call lg_setvald
    jmp .out
.astext:
    ; stage 4.5: what used to happen here was lg_clearcell - anything that
    ; would not parse as a number was DISCARDED, and typing a column heading
    ; left the cell empty. Content decides the type, exactly as Excel does it:
    ; '=' is a formula, a complete number is a number, and everything else is
    ; a label. There is no forcing prefix because Excel 2.1 has none either
    ; (the leading ' " ^ \ are Lotus's, not Excel's) - a cell that must hold
    ; "1990" as text is a Format problem, not an entry one.
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    mov si, lg_editbuf
    push ax                           ; ...except an ERROR VALUE's name, which
    call lg_errword                   ; is the error constant, as a typed #N/A
    mov dx, ax                        ; is in Excel - and so what Paste and
    pop ax                            ; Sort's carry commit for one, both of
    jnc .label                        ; which go through here as text (81.61)
    call lg_seterr
    jmp short .out
.label:
    call lg_setlabel                  ; ...and TRUE and FALSE, which are
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

lg_drawall:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    cmp byte [lg_calcmanual], 0       ; stage 3.0c Options > Calculation. NOT
    jne .nocalc                       ; advancing the pass stamp is the whole
    inc word [lg_pass]                ; mechanism: lg_eval_cell's memoization
.nocalc:                              ; keys off it, so every formula reads as
                                       ; a cache hit and nothing re-evaluates.
                                       ; One recalculation pass per full
                                       ; repaint, when it is automatic.
    call lg_mbar_draw
    call lg_drawbar
    call lg_drawstatus
    call lg_sbsync                    ; stage 3.0a+: both scroll bars, from
    mov bx, lg_vsb                    ; the live geometry and scroll position
    call os88ui_sbar
    mov bx, lg_hsb
    call lg_hsb_draw
    call lg_drawcolhdrs
    call lg_drawrowhdrs
    call lg_dmgfull                   ; the three grid painters below are
    call lg_drawgrid                  ; RANGED now (lg_dmgc1..lg_dmgr2); a
    call lg_drawlines                 ; full draw is the whole viewport
    call lg_drawsel
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_dmgfull - point the damage range at the whole viewport. The ranged grid
; painters guard [lg_vcols]/[lg_vrows] == 0 themselves, so the wrapped-around
; bounds an empty viewport produces here are never read. Preserves everything.
; -----------------------------------------------------------------------------
lg_dmgfull:
    push ax
    xor ax, ax
    mov [lg_dmgc1], ax
    mov [lg_dmgr1], ax
    mov ax, [lg_vcols]
    dec ax
    mov [lg_dmgc2], ax
    mov ax, [lg_vrows]
    dec ax
    mov [lg_dmgr2], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_dmgdraw - redraw ONLY the cells in [lg_dmgc1..c2] x [lg_dmgr1..r2]
; (window-relative, inclusive, already clamped to the viewport), plus the
; gridline segments and border edges over them. This is the partial-repaint
; core: OSAPI_FONT_RUN owns each cell's 8 glyph rows, so when a cell is
; taller the band below them is filled here - the full repaint's window-wide
; white fill does not run on this path, and the mover owns its stale pixels
; (the old selection frame's edges land in exactly that band).
; -----------------------------------------------------------------------------
lg_dmgdraw:
    push ax
    push bx
    push cx
    push dx
    cmp word [lg_vcols], 0
    je .out
    cmp word [lg_vrows], 0
    je .out
    mov ax, [lg_dmgc1]                 ; the damaged columns' pixel span
    call lg_vcx                        ; each column its own width (81.56)
    add ax, [lg_ox]
    add ax, LG_RH_W
    mov [lg_blitx1], ax
    mov ax, [lg_dmgc2]
    inc ax
    call lg_vcx                        ; each column its own width (81.56)
    add ax, [lg_ox]
    add ax, LG_RH_W
    dec ax
    mov [lg_blitx2], ax
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov cx, [lg_dmgr1]
.band:
    ; EACH ROW ITS OWN HEIGHT (81.60): the band ABOVE the glyphs, where a
    ; tall row's text sits low (lg_vtoff), and the band below them
    cmp cx, [lg_dmgr2]
    ja .nobands
    mov ax, cx
    call lg_vry
    add ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    mov bx, ax                         ; BX = the row's top
    mov ax, cx
    call lg_vtoff
    or ax, ax
    jz .below
    mov dx, bx
    add dx, ax
    dec dx                             ; down to the line above the glyphs
    mov ax, [lg_blitx1]
    push cx
    mov cx, [lg_blitx2]
    call OSAPI_GFX_FILL
    pop cx
.below:
    mov ax, cx
    call lg_vheight
    mov dx, bx
    add dx, ax
    dec dx                             ; DX = the row's last pixel line
    mov ax, cx
    call lg_vtoff
    add bx, ax
    add bx, 8                          ; below the glyphs
    cmp bx, dx
    ja .bandn                          ; an 8px row: the run covers it all
    mov ax, [lg_blitx1]
    push cx
    mov cx, [lg_blitx2]
    call OSAPI_GFX_FILL
    pop cx
.bandn:
    inc cx
    jmp .band
.nobands:
    call lg_drawgrid
    call lg_drawlines
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_drawbar - the formula bar (stage 2.x: real Excel's own two-box look -
; a fixed-width reference box on the left, a boxed content area on the
; right showing the selected cell's current value/formula, or the live
; edit buffer while typing). Status messages have their own bar now
; (lg_drawstatus) - this one only ever shows the reference and the
; content, matching real Excel's own division of labor between the two.
; -----------------------------------------------------------------------------
; =============================================================================
; The two scroll bars (stage 3.0a+)
;
; The VERTICAL one is os88ui.inc's shared element, used exactly as files.inc
; and fdlg.inc use it. The HORIZONTAL one is lg_hsb_* below - private to this
; app for now, but written to os88ui.inc's own conventions (same seven-word
; block, same OS88UI_SB* part codes, same "geometry not policy" split) so that
; promoting it into the shared file after Sheet 2.0 is a rename rather than a
; redesign. os88ui.inc has no horizontal bar today: its arrow cells are
; derived as y1+10/y2-10 and os88ui_sbtrack deliberately takes DX and not CX
; (SPEC.md 13.10.5.2, "x is never read"), so the axis is structural.
;
; SCROLL EXTENT. `total` is not LG_ROWS/LG_COLS - a bar over 16384 rows would
; have a one-pixel thumb that says nothing. It is the USED extent plus one
; screen, so the thumb is proportional to the sheet a person actually has, and
; it collapses to "no thumb" when everything already fits (os88ui_sbthumb
; answers CF=1 for that case on its own).
; =============================================================================

; -----------------------------------------------------------------------------
; lg_sbsync - refill both blocks from the live geometry and scroll position.
; Called before every draw and every hit-test, for lg_flrect's reason: the
; window moves and resizes, and a painter and a hit-tester reading different
; rects is the one bug this element is designed to make impossible.
; -----------------------------------------------------------------------------
lg_sbsync:
    push ax
    push bx
    push cx
    push dx
    call lg_difbbox                    ; -> [lg_bbcol]/[lg_bbrow], the used
                                        ; bounding box (walks only OCCUPIED
                                        ; cells, not the whole grid)

    ; --- vertical: the strip at the right of the grid area
    mov ax, [lg_ox]
    add ax, [lg_cw]
    sub ax, LG_VSB_W
    mov [lg_vsb + 0], ax               ; x1
    mov ax, [lg_ox]
    add ax, [lg_cw]
    dec ax
    mov [lg_vsb + 4], ax               ; x2
    mov ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    mov [lg_vsb + 2], ax               ; y1 - the top of the grid proper
    mov ax, [lg_oy]
    add ax, [lg_ch]
    sub ax, LG_SB_H + LG_HSB_H
    dec ax
    mov [lg_vsb + 6], ax               ; y2 - just above the horizontal bar
    mov ax, [lg_bbrow]
    inc ax                             ; the USED extent, not LG_ROWS - a bar
    cmp ax, [lg_vrows]                 ; over 16384 rows has a one-pixel thumb
    jae .vtot                          ; that says nothing. Floored at `fit`,
    mov ax, [lg_vrows]                 ; so an empty sheet has total == fit and
.vtot:                                 ; correctly shows no thumb at all.
    sub ax, [lg_freezerow]             ; 81.70: total/fit/pos all shift into
    mov [lg_vsb + 8], ax               ; the SCROLLING region's own space -
    mov ax, [lg_vrows]                 ; the frozen prefix is never part of
    sub ax, [lg_freezerow]             ; what the thumb represents at all
    mov [lg_vsb + 10], ax              ; fit
    mov ax, [lg_scrollrow]
    sub ax, [lg_freezerow]
    mov dx, [lg_vsb + 8]               ; pos, CLAMPED to total - fit: keyboard
    sub dx, [lg_vsb + 10]              ; navigation and Goto move the origin
    cmp ax, dx                         ; without consulting the bars, and both
    jbe .vpos                          ; thumb routines divide pos * track by
    mov ax, dx                         ; total - unclamped, the quotient can
.vpos:                                 ; overflow 16 bits and the DIV raises
    mov [lg_vsb + 12], ax              ; INT 0 (a crash on real hardware)

    ; --- horizontal: the strip below the grid, left of the vertical bar
    mov ax, [lg_ox]
    add ax, LG_RH_W
    mov [lg_hsb + 0], ax               ; x1
    mov ax, [lg_ox]
    add ax, [lg_cw]
    sub ax, LG_VSB_W
    dec ax
    mov [lg_hsb + 4], ax               ; x2 - stops at the vertical bar
    mov ax, [lg_oy]
    add ax, [lg_ch]
    sub ax, LG_SB_H + LG_HSB_H
    mov [lg_hsb + 2], ax               ; y1
    mov ax, [lg_oy]
    add ax, [lg_ch]
    sub ax, LG_SB_H
    dec ax
    mov [lg_hsb + 6], ax               ; y2
    mov ax, [lg_bbcol]
    inc ax
    cmp ax, [lg_vcols]
    jae .htot
    mov ax, [lg_vcols]
.htot:
    sub ax, [lg_freezecol]             ; 81.70: see the vertical bar's own
    mov [lg_hsb + 8], ax               ; comment above
    mov ax, [lg_vcols]
    sub ax, [lg_freezecol]
    mov [lg_hsb + 10], ax              ; fit
    mov ax, [lg_scrollcol]
    sub ax, [lg_freezecol]
    mov dx, [lg_hsb + 8]               ; pos, clamped to total - fit, for the
    sub dx, [lg_hsb + 10]              ; vertical bar's reason above
    cmp ax, dx
    jbe .hpos
    mov ax, dx
.hpos:
    mov [lg_hsb + 12], ax

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; lg_hsb_* - A HORIZONTAL SCROLL BAR, staged for os88ui.inc
;
; os88ui.inc's bar is structurally vertical and says so: its arrow cells are
; y1+10 and y2-10, and os88ui_sbtrack takes DX and refuses CX on purpose
; (SPEC.md 13.10.5.2). This is that element transposed, and NOTHING about it
; is Sheet-specific:
;
;   * the same seven-word block (x1,y1,x2,y2,total,fit,pos), so a promoted
;     version needs no caller to change its .bss;
;   * the same part codes - LG_SB_UP/SBDOWN mean LEFT/RIGHT here, which is
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
; lg_hsb_* - A HORIZONTAL SCROLL BAR, staged for os88ui.inc
;
; os88ui.inc's bar is structurally vertical and says so: its arrow cells are
; y1+10 and y2-10, and os88ui_sbtrack takes DX and refuses CX on purpose
; (SPEC.md 13.10.5.2, "x is never read"). This is that element transposed, and
; nothing about it is Sheet-specific:
;
;   * the same seven-word block (x1,y1,x2,y2,total,fit,pos), so a promoted
;     version needs no caller to change its .bss;
;   * the same part codes - LG_SB_UP/SBDOWN read as LEFT/RIGHT here, which
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
; lg_hsb_load - copy the block's rect into scratch. in: BX = the block.
; Preserves everything. Every drawing routine calls this FIRST and then never
; dereferences BX again, which is what keeps the block pointer and the gfx
; rect from fighting over the same register.
; -----------------------------------------------------------------------------
lg_hsb_load:
    push ax
    mov ax, [bx + 0]
    mov [lg_hsb_x1], ax
    mov ax, [bx + 2]
    mov [lg_hsb_y1], ax
    mov ax, [bx + 4]
    mov [lg_hsb_x2], ax
    mov ax, [bx + 6]
    mov [lg_hsb_y2], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_hsb_thumb - the thumb's geometry (os88ui_sbthumb, transposed)
; in:  BX = the block
; out: CF=1 = there is no thumb; else CF=0 and [lg_hsb_tl]/[lg_hsb_tw] hold
;      its left and width, absolute. Every register preserved.
; -----------------------------------------------------------------------------
lg_hsb_thumb:
    push ax
    push cx
    push dx
    push si
    mov cx, [bx + 4]
    sub cx, [bx + 0]
    sub cx, (LG_SB_CELL + 1) * 2    ; cx = the track's width
    cmp cx, LG_SB_MINH
    jb .none
    mov ax, [bx + 10]                  ; fit
    or ax, ax
    jz .none
    cmp ax, [bx + 8]                   ; fit >= total: everything fits
    jae .none
    xor dx, dx
    mul cx                             ; dx:ax = fit * track
    div word [bx + 8]                  ; / total
    cmp ax, LG_SB_MINH
    jae .wok
    mov ax, LG_SB_MINH
.wok:
    mov si, ax                         ; si = the thumb's width
    mov ax, [bx + 12]                  ; pos
    xor dx, dx
    mul cx                             ; dx:ax = pos * track
    div word [bx + 8]                  ; / total
    add ax, [bx + 0]
    add ax, LG_SB_CELL + 1          ; ax = the thumb's left
    ; Clamp the tail inside the track: pos == total-fit can overshoot by a
    ; pixel once both divisions have truncated.
    mov dx, [bx + 4]
    sub dx, LG_SB_CELL + 1          ; dx = the track's last column
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
    mov [lg_hsb_tl], ax
    mov [lg_hsb_tw], si
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
; lg_hsb_draw - the whole bar. in: BX = the block; gfx lock held.
; Preserves everything; leaves the pen BLACK, as os88ui_sbar does.
; -----------------------------------------------------------------------------
lg_hsb_draw:
    push ax
    push bx
    push cx
    push dx
    call lg_hsb_load

    mov al, CWHITE                     ; the arrow cells are plain white...
    call OSAPI_SET_COLOR
    mov ax, [lg_hsb_x1]
    mov bx, [lg_hsb_y1]
    mov cx, [lg_hsb_x2]
    mov dx, [lg_hsb_y2]
    call OSAPI_GFX_FILL
    mov ax, [lg_hsb_x1]                ; ...and the TRACK between them is the
    add ax, LG_SB_CELL + 1             ; grey dither, which is what the thumb
    mov cx, [lg_hsb_x2]                ; reads as a knob against
    sub cx, LG_SB_CELL + 1
    mov bx, [lg_hsb_y1]
    inc bx
    mov dx, [lg_hsb_y2]
    dec dx
    cmp ax, cx
    jg .notrack
    call OSAPI_GFX_FILL_GRAY
.notrack:

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [lg_hsb_x1]                ; the outline
    mov bx, [lg_hsb_y1]
    mov cx, [lg_hsb_x2]
    mov dx, [lg_hsb_y2]
    call OSAPI_GFX_FRAME

    mov ax, [lg_hsb_x1]                ; the two arrow-cell rules
    add ax, LG_SB_CELL
    mov bx, [lg_hsb_y1]
    mov dx, [lg_hsb_y2]
    call OSAPI_GFX_VLINE
    mov ax, [lg_hsb_x2]
    sub ax, LG_SB_CELL
    mov bx, [lg_hsb_y1]
    mov dx, [lg_hsb_y2]
    call OSAPI_GFX_VLINE

    pop dx
    pop cx
    pop bx
    pop ax
    call lg_hsb_arrows
    call lg_hsb_thdraw
    ret

; -----------------------------------------------------------------------------
; lg_hsb_arrows - the two triangles. os88ui.inc's vertical arrow is 5 rows of
; widths 1..9; this is that rotated, so 5 columns of growing height.
; in: BX = the block (already loaded into scratch by the caller).
; -----------------------------------------------------------------------------
lg_hsb_arrows:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, [lg_hsb_y1]
    add si, [lg_hsb_y2]
    shr si, 1                          ; si = the cells' vertical centre

    ; The tips point OUTWARD - `<` on the left cell and `>` on the right, not
    ; `>` and `<`. Each arrow starts one pixel in from its OUTER edge, where
    ; the tip belongs, and widens INWARD.
    mov di, [lg_hsb_x1]                ; LEFT arrow: tip at the outer edge...
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

    mov di, [lg_hsb_x2]                ; RIGHT arrow: tip at ITS outer edge,
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
; lg_hsb_thdraw - just the thumb. in: BX = the block; gfx lock held.
; -----------------------------------------------------------------------------
lg_hsb_thdraw:
    push ax
    push bx
    push cx
    push dx
    call lg_hsb_thumb
    jc .out
    ; The same two-part thumb os88ui_sbthdraw draws, transposed: a BLACK
    ; frame with a WHITE interior inside it - not a solid block, which is what
    ; makes it read as a knob against the dithered track rather than as a bar.
    mov ax, [lg_hsb_tl]
    mov cx, ax
    add cx, [lg_hsb_tw]
    dec cx
    mov bx, [lg_hsb_y1]
    add bx, 2
    mov dx, [lg_hsb_y2]
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
; lg_hsb_hit - which part is this point on? (os88ui_sbhit, transposed)
; in:  BX = the block, CX = x, DX = y (both ABSOLUTE)
; out: AL = OS88UI_SB*; AH clobbered, everything else preserved.
; -----------------------------------------------------------------------------
lg_hsb_hit:
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
    add ax, LG_SB_CELL
    cmp cx, ax
    jbe .up                            ; the LEFT arrow cell
    mov ax, [bx + 4]
    sub ax, LG_SB_CELL
    cmp cx, ax
    jae .down                          ; the RIGHT arrow cell
    call lg_hsb_thumb
    jc .pgdn                           ; no thumb: the track is all page-fwd
    mov ax, [lg_hsb_tl]
    cmp cx, ax
    jb .pgup
    add ax, [lg_hsb_tw]
    cmp cx, ax
    jae .pgdn
    mov al, LG_SB_THUMB
    jmp .out
.up:
    mov al, LG_SB_UP
    jmp .out
.down:
    mov al, LG_SB_DOWN
    jmp .out
.pgup:
    mov al, LG_SB_PGUP
    jmp .out
.pgdn:
    mov al, LG_SB_PGDN
    jmp .out
.none:
    mov al, LG_SB_NONE
.out:
    pop dx
    pop cx
    ret

; -----------------------------------------------------------------------------
; lg_hsb_grab / lg_hsb_track / lg_hsb_drop - the thumb drag, the same three
; edges os88ui.inc's own uses (13.10.5), with the anchor banked as
; press_x - thumb_left so the thumb does not jump under the hand.
; -----------------------------------------------------------------------------
lg_hsb_grab:
    push ax
    call lg_hsb_thumb
    jc .no
    mov ax, cx
    sub ax, [lg_hsb_tl]
    mov [lg_hsb_dragoff], ax
    mov byte [lg_hsb_dragon], 1
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret



; -----------------------------------------------------------------------------
; lg_onmouseup - W_ONMOUSEUP: the press was released. Ends a thumb drag and,
; for the vertical bar's rate-0 grab, commits the pos the hand ended on -
; which is what "the view follows only on release" means (13.10.5.4).
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; lg_sbclick - stage 3.0a+: a press landed somewhere. If it was on either
; scroll bar, act on it and answer CF=1 ("mine"); otherwise CF=0 and the grid
; gets it. in: CX = x, DX = y (absolute), SI = the window.
;
; This is the POLICY half that os88ui.inc deliberately leaves to the caller
; (13.10.1): the element says which part was hit, and what a part MEANS to a
; sheet - one row, one screen, or take the thumb - is decided here.
; -----------------------------------------------------------------------------
lg_sbclick:
    push ax
    push bx
    push di
    call lg_sbsync

    mov bx, lg_vsb                     ; --- the vertical bar
    call os88ui_sbhit
    cmp al, LG_SB_NONE
    je .tryh
    xor ah, ah                         ; stash the part in DI: the very next
    mov di, ax                         ; instruction writes the whole of AX,
    mov ax, [lg_scrollrow]             ; so stashing it in AH (as this did)
    mov [lg_sb_oldpos], ax             ; destroyed it and every compare below
    cmp di, LG_SB_UP                   ; fell through to the thumb branch
                                        ; - which is why an arrow click did
                                        ; nothing at all
    je .vup
    cmp di, LG_SB_DOWN
    je .vdn
    cmp di, LG_SB_PGUP
    je .vpgup
    cmp di, LG_SB_PGDN
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
    mov ax, [lg_scrollrow]
    or ax, ax
    jz .mine
    dec ax
    jmp .vset
.vdn:
    mov ax, [lg_scrollrow]
    inc ax
    jmp .vset
.vpgup:
    mov ax, [lg_scrollrow]
    sub ax, [lg_vrows]
    jns .vset
    xor ax, ax
    jmp .vset
.vpgdn:
    mov ax, [lg_scrollrow]
    add ax, [lg_vrows]
.vset:
    call lg_setscrollrow
    jmp .mine

.tryh:
    mov bx, lg_hsb                     ; --- the horizontal bar
    call lg_hsb_hit
    cmp al, LG_SB_NONE
    je .notmine
    xor ah, ah                         ; same AX-clobber trap as the vertical
    mov di, ax                         ; branch above
    mov ax, [lg_scrollcol]
    mov [lg_sb_oldpos], ax
    cmp di, LG_SB_UP
    je .hlf
    cmp di, LG_SB_DOWN
    je .hrt
    cmp di, LG_SB_PGUP
    je .hpgup
    cmp di, LG_SB_PGDN
    je .hpgdn
    call lg_hsb_grab                   ; SB_THUMB
    jmp .mine
.hlf:
    mov ax, [lg_scrollcol]
    or ax, ax
    jz .mine
    dec ax
    jmp .hset
.hrt:
    mov ax, [lg_scrollcol]
    inc ax
    jmp .hset
.hpgup:
    mov ax, [lg_scrollcol]
    sub ax, [lg_vcols]
    jns .hset
    xor ax, ax
    jmp .hset
.hpgdn:
    mov ax, [lg_scrollcol]
    add ax, [lg_vcols]
.hset:
    call lg_setscrollcol
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
; lg_setscrollrow / lg_setscrollcol - move the view to AX, clamped to the
; scrollable extent, and paint the move if it actually happened - the
; surviving rows blitted and only the vacated ones lettered (vertical), or
; the grid's own strip repainted (horizontal; OSAPI_GFX_SCROLL is
; vertical-only, SPEC.md 5.5). SI = the window.
; -----------------------------------------------------------------------------
lg_setscrollrow:
    push ax
    push bx
    push cx
    mov cx, [lg_vsb + 8]               ; total
    sub cx, [lg_vsb + 10]              ; ...minus fit = the last legal pos,
    jns .rok                           ; relative to the scrolling region
    xor cx, cx
.rok:
    add cx, [lg_freezerow]             ; 81.70: back to an ABSOLUTE row -
    cmp ax, cx                         ; every caller passes AX absolute
    jbe .rset
    mov ax, cx
.rset:
    cmp ax, [lg_freezerow]             ; 81.70: the frozen prefix is the
    jae .rset2                         ; floor - scrolling can never uncover
    mov ax, [lg_freezerow]             ; less of it than that
.rset2:
    cmp ax, [lg_scrollrow]
    je .rout                           ; no movement: draw nothing
    mov cx, [lg_scrollrow]             ; the row the view is leaving
    mov [lg_scrollrow], ax
    call lg_scrollrow_blit
    jnc .rout
    call lg_repaint                    ; the blit refused: pay the full price
.rout:
    pop cx
    pop bx
    pop ax
    ret

lg_setscrollcol:
    push ax
    push bx
    push cx
    mov cx, [lg_hsb + 8]
    sub cx, [lg_hsb + 10]
    jns .cok
    xor cx, cx
.cok:
    add cx, [lg_freezecol]             ; 81.70: the vertical bar's own
    cmp ax, cx                         ; comment applies here too
    jbe .cset
    mov ax, cx
.cset:
    cmp ax, [lg_freezecol]
    jae .cset2
    mov ax, [lg_freezecol]
.cset2:
    cmp ax, [lg_scrollcol]
    je .cout
    mov [lg_scrollcol], ax
    call lg_scrollcol_part
.cout:
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_scrollrow_blit - move the grid by whole rows with OSAPI_GFX_SCROLL
; instead of repainting every visible cell: the surviving rows are one blit,
; and only the |delta| vacated ones are lettered (~7 runs for an arrow click
; instead of ~119).
; in:  CX = the scroll row the view is leaving, SI = the window;
;      [lg_scrollrow] already holds the new one.
; out: CF=0 the view is painted; CF=1 nothing was drawn and the caller owes
;      the full repaint - the blit refused (the clip does not wholly contain
;      the rect, SPEC.md 5.5), the byte-alignment round-up would reach the
;      vertical bar, or the delta leaves no surviving band worth keeping.
; -----------------------------------------------------------------------------
lg_scrollrow_blit:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call lg_geom                       ; fresh geometry: the drag path arrives
                                        ; without lg_onclick's own lg_geom
    cmp word [lg_vcols], 0
    je .no
    cmp word [lg_vrows], 0
    je .no
    ; FROZEN ROWS REFUSE THE BLIT (81.70). OSAPI_GFX_SCROLL shifts a whole
    ; rect's pixels, and the frozen strip's must not move with the rest -
    ; cutting the rect below it is real work in the one routine whose
    ; rectangle arithmetic is hardest to get right, for a saving only a
    ; frozen sheet being scrolled would ever see. The caller already owns a
    ; refusal path (it repaints), so this takes it
    cmp word [lg_freezerow], 0
    jne .no
    mov ax, [lg_scrollrow]
    sub ax, cx                         ; ax = the delta, in rows (signed)
    mov [lg_blitdel], ax
    mov di, ax
    or di, di
    jns .abs
    neg di                             ; di = |delta|
.abs:
    cmp di, [lg_vrows]
    jae .no                            ; nothing survives: repaint instead
    ; 81.60 asked here whether every row in the band was the standard height,
    ; because a band of mixed heights does not move by delta*one-height.
    ; 81.75 gave every row one height, so the question has one answer.

    ; The rect. x1 and x2+1 must be multiples of 8 (the blit is byte-column
    ; granular, SPEC.md 5.5): x1 rounds DOWN into the row-header strip,
    ; which is redrawn whole below anyway; x2+1 rounds UP into the dead
    ; space right of the last gridline - refused if that would reach the
    ; vertical bar, whose pixels must not move.
    mov ax, [lg_ox]
    add ax, LG_RH_W
    and ax, 0xFFF8
    mov [lg_blitx1], ax
    mov ax, [lg_vcols]
    call lg_vcx                        ; each column its own width (81.56)
    add ax, [lg_ox]
    add ax, LG_RH_W                    ; ax = one past the grid's right edge
    add ax, 7
    and ax, 0xFFF8                     ; ...rounded up to the byte column
    mov dx, [lg_ox]
    add dx, [lg_cw]
    sub dx, LG_VSB_W                   ; dx = the vertical bar's x1
    cmp ax, dx
    ja .no
    dec ax
    mov [lg_blitx2], ax
    mov ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    mov [lg_blity1], ax
    mov bx, ax
    mov ax, [lg_vrows]
    mov dx, LG_RH_NORMAL               ; every row the standard, checked above
    mul dx
    add ax, bx
    dec ax
    mov [lg_blity2], ax

    mov ax, [lg_blitdel]
    mov dx, LG_RH_NORMAL
    imul dx                            ; the delta is under vrows, so AX is
    mov si, ax                         ; the whole of it: SI = signed dy
    mov ax, [lg_blitx1]
    mov bx, [lg_blity1]
    mov cx, [lg_blitx2]
    mov dx, [lg_blity2]
    call OSAPI_GFX_SCROLL              ; positive dy = content UP = view DOWN
    jc .no                             ; refused: nothing moved, fall back

    xor ax, ax                         ; the vacated rows, and only them:
    cmp word [lg_blitdel], 0           ; scrolled up = new rows on top,
    jl .vac                            ; scrolled down = at the bottom
    mov ax, [lg_vrows]
    sub ax, di
.vac:
    mov [lg_dmgr1], ax
    add ax, di
    dec ax
    mov [lg_dmgr2], ax
    xor ax, ax
    mov [lg_dmgc1], ax
    mov ax, [lg_vcols]
    dec ax
    mov [lg_dmgc2], ax
    call lg_dmgdraw
    call lg_drawsel                    ; the frame's share of the vacated
                                        ; band - its surviving part moved
                                        ; WITH the blit, to exactly where the
                                        ; frame now belongs

    mov al, CWHITE                     ; the row headers: every number
    call OSAPI_SET_COLOR               ; changed places, and their text is
    mov ax, [lg_ox]                    ; transparent, so the strip is erased
    mov bx, [lg_blity1]                ; first
    mov cx, [lg_ox]
    add cx, LG_RH_W - 1
    mov dx, [lg_blity2]
    call OSAPI_GFX_FILL
    call lg_drawrowhdrs

    call lg_sbsync                     ; ...and the thumb moved
    mov bx, lg_vsb
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
; lg_scrollcol_part - a horizontal scroll has no blit primitive to lean on,
; but it still owes nothing to the menu bar, the formula bar, the status bar
; or the vertical scroll bar: the grid, the column letters and the
; horizontal thumb are the whole of what moved - and no recalc pass, because
; no cell changed. SI = the window.
; -----------------------------------------------------------------------------
lg_scrollcol_part:
    push ax
    push bx
    push cx
    push dx
    mov bx, si
    call lg_geom                       ; lg_scrollrow_blit's reason
    ; THE STRIP PAST THE LAST WHOLE COLUMN (81.56): with one width it was
    ; always narrower than a column and the same each time; with each column
    ; its own, scrolling changes it, and the cells alone never cover it
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [lg_vcols]
    call lg_vcx
    add ax, [lg_ox]
    add ax, LG_RH_W
    mov cx, [lg_ox]
    add cx, [lg_cw]
    sub cx, LG_VSB_W + 1
    cmp ax, cx
    ja .nostrip
    mov bx, [lg_goy]
    add bx, LG_FB_H
    mov dx, [lg_oy]
    add dx, [lg_ch]
    sub dx, LG_SB_H + LG_HSB_H + 1
    call OSAPI_GFX_FILL
.nostrip:
    call lg_dmgfull
    call lg_dmgdraw
    call lg_drawsel
    cmp word [lg_vcols], 0
    je .nohdr
    mov al, CWHITE                     ; the column letters all changed
    call OSAPI_SET_COLOR               ; places; their text is transparent,
    mov ax, [lg_ox]                    ; so the strip is erased first
    add ax, LG_RH_W
    mov bx, [lg_goy]
    add bx, LG_FB_H
    push ax
    mov ax, [lg_vcols]
    call lg_vcx                        ; each column its own width (81.56)
    mov cx, ax
    pop ax
    add cx, ax
    dec cx
    mov dx, [lg_goy]
    add dx, LG_FB_H + LG_CH_H - 1
    call OSAPI_GFX_FILL
    call lg_drawcolhdrs
.nohdr:
    call lg_sbsync                     ; the horizontal thumb moved
    mov bx, lg_hsb
    call lg_hsb_draw
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_flrect - stage 3.0b: point the formula bar's line block at the content
; box's CURRENT screen rect. Called before every draw and every hit-test
; rather than once at startup, because the window moves and resizes and
; os88line reads the same four words for both drawing and clicking - a stale
; rect would put the caret somewhere the box no longer is. These are exactly
; the coordinates lg_drawbar frames the content box with, so the field's own
; frame lands on top of the same pixels.
; -----------------------------------------------------------------------------
lg_flrect:
    push ax
    mov ax, [lg_ox]
    add ax, LG_REF_W
    mov [lg_fline + LN_X1], ax
    mov ax, [lg_goy]
    mov [lg_fline + LN_Y1], ax
    mov ax, [lg_ox]
    add ax, [lg_cw]
    dec ax
    mov [lg_fline + LN_X2], ax
    mov ax, [lg_goy]
    add ax, LG_FB_H - 1
    mov [lg_fline + LN_Y2], ax
    pop ax
    ret

lg_drawbar:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov al, CBLACK
    call OSAPI_SET_COLOR

    ; --- reference box outline: (ox, goy) to (ox+LG_REF_W-1, goy+LG_FB_H-1) ---
    mov ax, [lg_ox]
    mov bx, ax
    add bx, LG_REF_W - 1
    mov dx, [lg_goy]
    call OSAPI_GFX_HLINE
    add dx, LG_FB_H - 1
    call OSAPI_GFX_HLINE
    mov ax, [lg_ox]
    mov bx, [lg_goy]
    mov dx, [lg_goy]
    add dx, LG_FB_H - 1
    call OSAPI_GFX_VLINE
    mov ax, [lg_ox]
    add ax, LG_REF_W - 1
    call OSAPI_GFX_VLINE               ; also the content box's own left edge

    ; --- content box outline: (ox+LG_REF_W, goy) to (ox+cw-1, goy+LG_FB_H-1) ---
    mov ax, [lg_ox]
    add ax, LG_REF_W
    mov bx, [lg_ox]
    add bx, [lg_cw]
    dec bx
    mov dx, [lg_goy]
    call OSAPI_GFX_HLINE
    add dx, LG_FB_H - 1
    call OSAPI_GFX_HLINE
    mov ax, [lg_ox]
    add ax, [lg_cw]
    dec ax
    mov bx, [lg_goy]
    mov dx, [lg_goy]
    add dx, LG_FB_H - 1
    call OSAPI_GFX_VLINE

    ; --- the reference box's interior, erased: its text is transparent and
    ; this bar repaints on every selection move WITHOUT the window-wide
    ; white fill behind it now (lg_selpaint), so it owns its own pixels ---
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [lg_ox]
    inc ax
    mov bx, [lg_goy]
    inc bx
    mov cx, [lg_ox]
    add cx, LG_REF_W - 2
    mov dx, [lg_goy]
    add dx, LG_FB_H - 2
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR

    ; --- reference text, into lg_tbuf ---
    ; Formula > Reference switches this between A1 and R1C1, which is the only
    ; place in the app that had an answer to show: the A1<->R1C1 converters
    ; already existed for SYLK's own ;E field (81.7.1), and this is what makes
    ; the setting visible rather than a file-format detail.
    mov di, lg_tbuf
    cmp byte [lg_a1style], 0
    jne .refrc
    mov ax, [lg_selcol]
    call lg_colname
    mov si, lg_colbuf
    call lg_strcpy_to_di
    mov ax, [lg_selrow]
    inc ax
    call lg_itoa
    mov si, lg_numbuf
    call lg_strcpy_to_di
    jmp .refdone
.refrc:
    mov byte [di], 'R'
    inc di
    mov ax, [lg_selrow]
    inc ax
    call lg_itoa
    mov si, lg_numbuf
    call lg_strcpy_to_di
    mov byte [di], 'C'
    inc di
    mov ax, [lg_selcol]
    inc ax
    call lg_itoa
    mov si, lg_numbuf
    call lg_strcpy_to_di
.refdone:
    mov cx, [lg_ox]
    add cx, 4
    mov dx, [lg_goy]
    add dx, 4
    mov si, lg_tbuf
    call OSAPI_FONT_STR_XPARENT

    ; --- while EDITING, the content box is a real text field: os88line owns
    ; the box, the text, the caret and the horizontal scroll, so this path
    ; hands it over entirely rather than drawing a string itself.
    cmp byte [lg_editing], 0
    je .static
    call lg_flrect
    mov si, lg_fline
    call lg_flmarg                     ; the span between the frame and the
    call os88line_draw                 ; field's 8-aligned pen, which the
    jmp .done                          ; field's own one-pass draw never
                                        ; touches

.static:
    ; --- not editing: the cell's current value/formula, as static text, into
    ; lg_tbuf+16 (past the reference text's own small span, so the two never
    ; overlap in the same shared buffer) ---
    mov di, lg_tbuf + 16
    push di                            ; lg_findcell's own DI output would
                                        ; otherwise clobber our cursor
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    call lg_findcell
    jnc .empty2
    push es
    mov es, [lg_cellseg]
    test byte [es:di+4], 1
    jnz .isformula
    cmp byte [es:di+LG_C_TYPE], LG_T_TEXT     ; stage 4.5: a label shows its
    jne .plainval2                     ; own text here, unprefixed - the '='
    mov ax, [es:di+LG_C_FOFF]          ; below is what makes a formula look
    pop es                             ; like one, and a label is not one
    pop di
    mov si, ax
    push es
    mov es, [lg_txtseg]
    jmp .copyfm
.isformula:
    mov ax, [es:di+LG_C_FOFF]                 ; formula_off
    pop es
    pop di                             ; DI = content cursor, restored
    mov byte [di], '='
    inc di
    mov si, ax
    push es
    mov es, [lg_txtseg]
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
    call lg_cellnum                    ; lg_numbuf already holds the decimal
    pop es                             ; text; lg_itoa would overwrite it with
    pop di                             ; the low word's worth
    mov si, lg_numbuf
    call lg_strcpy_to_di
    jmp .draw
.empty2:
    pop di                             ; DI = content cursor, restored
    mov byte [di], 0
.draw:
    mov al, CWHITE                     ; the content box's interior, erased:
    call OSAPI_SET_COLOR               ; the text below is transparent and of
    mov ax, [lg_ox]                    ; varying length (the ref box's reason
    add ax, LG_REF_W + 1               ; above)
    mov bx, [lg_goy]
    inc bx
    mov cx, [lg_ox]
    add cx, [lg_cw]
    sub cx, 2
    mov dx, [lg_goy]
    add dx, LG_FB_H - 2
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov cx, [lg_ox]
    add cx, LG_REF_W + 4
    mov dx, [lg_goy]
    add dx, 3                          ; the same row os88line's own run uses
                                        ; (LN_INSET), so the field covers this
                                        ; text exactly when an edit begins
    mov si, lg_tbuf + 16
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
; lg_drawstatus - the status bar: a single divider line above a strip at
; the very bottom of the content area, showing [lg_msg] if a command just
; set one, else the idle "Ready" real Excel's own status bar shows.
; -----------------------------------------------------------------------------
lg_drawstatus:
    push ax
    push bx
    push cx
    push dx
    push si

    mov al, CWHITE                     ; the strip's interior, erased: the
    call OSAPI_SET_COLOR               ; message is transparent text of
    mov ax, [lg_ox]                    ; varying length, and this bar repaints
    mov bx, [lg_oy]                    ; on selection moves without the
    add bx, [lg_ch]                    ; window-wide white fill behind it
    sub bx, LG_SB_H                    ; (lg_selpaint)
    inc bx
    mov cx, [lg_ox]
    add cx, [lg_cw]
    dec cx
    mov dx, [lg_oy]
    add dx, [lg_ch]
    dec dx
    call OSAPI_GFX_FILL

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [lg_ox]
    mov bx, ax
    add bx, [lg_cw]
    dec bx
    mov dx, [lg_oy]
    add dx, [lg_ch]
    sub dx, LG_SB_H
    call OSAPI_GFX_HLINE

    mov si, [lg_msg]
    or si, si
    jnz .havemsg
    mov si, lg_s_ready
.havemsg:
    mov cx, [lg_ox]
    add cx, 4
    mov dx, [lg_oy]
    add dx, [lg_ch]
    sub dx, LG_SB_H
    add dx, 4
    call OSAPI_FONT_STR_XPARENT

    ; The right-hand indicator block, which real Excel uses for NUM/CAPS/SCRL
    ; and for the word CALCULATE when Manual mode has left the sheet stale.
    ; CALCULATE takes precedence, because it is the one that means something
    ; is WRONG on screen rather than something is set on the keyboard.
    mov si, lg_s_num
    cmp byte [lg_calcmanual], 0
    je .indi
    mov si, lg_s_calcind
.indi:
    mov cx, [lg_ox]
    add cx, [lg_cw]
    sub cx, 88
    mov dx, [lg_oy]
    add dx, [lg_ch]
    sub dx, LG_SB_H
    add dx, 4
    call OSAPI_FONT_STR_XPARENT

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_drawcolhdrs - the column letters, centred in each visible column's band
; -----------------------------------------------------------------------------
lg_drawcolhdrs:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov word [lg_wcol], 0
.col:
    mov bx, [lg_wcol]
    cmp bx, [lg_vcols]
    jae .out
    mov ax, bx
    call lg_vreal_col                  ; 81.70
    call lg_colname
    mov ax, bx
    call lg_vcx                        ; each letter over its own column
    add ax, [lg_ox]                    ; (81.56)
    add ax, LG_RH_W
    mov cx, ax
    mov si, lg_colbuf
    call OSAPI_FONT_WIDTH
    push ax
    mov ax, [lg_wcol]
    call lg_vwidth
    mov dx, ax
    pop ax
    sub dx, ax
    shr dx, 1
    add cx, dx
    mov dx, [lg_goy]
    add dx, LG_FB_H
    mov si, lg_colbuf
    call OSAPI_FONT_STR_XPARENT
    mov bx, [lg_wcol]
    inc bx
    mov [lg_wcol], bx
    jmp .col
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_drawrowhdrs - the row numbers, right-aligned in LG_RH_W
; -----------------------------------------------------------------------------
lg_drawrowhdrs:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov word [lg_wrow], 0
.row:
    mov bx, [lg_wrow]
    cmp bx, [lg_vrows]
    jae .out
    mov ax, bx
    call lg_vreal_row                  ; 81.70
    inc ax
    call lg_itoa
    mov si, lg_numbuf
    call OSAPI_FONT_WIDTH
    mov cx, LG_RH_W - 4
    sub cx, ax
    add cx, [lg_ox]
    mov ax, bx
    call lg_vry                        ; its own top (81.60)...
    mov dx, ax
    mov ax, bx
    call lg_vtoff                      ; ...and as low as its cells' text
    add dx, ax
    add dx, [lg_goy]
    add dx, LG_FB_H + LG_CH_H
    mov si, lg_numbuf
    call OSAPI_FONT_STR_XPARENT
    mov bx, [lg_wrow]
    inc bx
    mov [lg_wrow], bx
    jmp .row
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_drawgrid - every cell in the damage range (lg_dmgc1..lg_dmgr2, window-
; relative - lg_dmgfull for the whole viewport) as one fixed-width
; OSAPI_FONT_RUN, number-formatted and justified per its own LG_FMT_* bits
; (stage 1.6), all spaces for empty. Sparse lookup: no bitmap.
; -----------------------------------------------------------------------------
lg_drawgrid:
    push ax
    push bx
    push cx
    push dx
    push si
    cmp word [lg_vcols], 0
    je .out
    cmp word [lg_vrows], 0
    je .out
    mov ax, [lg_dmgr1]
    mov [lg_wrow], ax
.row:
    mov ax, [lg_wrow]
    cmp ax, [lg_dmgr2]
    ja .out
    call lg_vheight                    ; THIS ROW'S OWN HEIGHT (81.60), and
    mov [lg_cellh], ax                 ; how far down it the text sits
    mov ax, [lg_wrow]
    call lg_vtoff
    mov [lg_rtoff], ax
    mov ax, [lg_dmgc1]
    mov [lg_wcol], ax
.col:
    mov ax, [lg_wcol]
    cmp ax, [lg_dmgc2]
    ja .rownext
    call lg_vwidth                     ; THIS COLUMN'S OWN WIDTH (81.56): the
    mov [lg_cellw], ax                 ; justifiers, the number fit, the blank
    mov cl, 3                          ; and the spill all read these two, so
    shr ax, cl                         ; setting them per cell is all they
    mov [lg_cellch], ax                ; need to know about it
    call lg_mkblank
    mov ax, [lg_wcol]
    call lg_vreal_col                  ; 81.70
    push ax                            ; the real column, banked - lg_vreal_
    mov ax, [lg_wrow]                  ; row only touches AX and flags, but
    call lg_vreal_row                  ; the bank costs nothing to be sure
    mov bx, ax
    pop ax
    call lg_getcell2
    jc .have
    call lg_spill                      ; ...unless a label to its left runs
    mov si, lg_tbuf                    ; on into it (81.54) - MOV keeps CF
    jc .got
    mov si, lg_blank
    jmp .got
.have:
    cmp byte [lg_showformulas], 0      ; stage 2.x Options > Formulas: On -
    je .valpath                        ; show the formula TEXT, not its
                                        ; value, matching real Excel's
                                        ; Display dialog's "Formulas" box.
                                        ; AX/BX are still this cell's own
                                        ; col/row (lg_getcell2 preserves
                                        ; both), so re-finding it costs
                                        ; nothing extra to set up.
    call lg_findcell
    jnc .valpath                       ; can't happen (getcell2 said
                                        ; occupied) - stay safe regardless
    push es
    mov es, [lg_cellseg]
    test byte [es:di+4], 1             ; HASFORMULA
    jz .noformula3
    mov ax, [es:di+LG_C_FOFF]                  ; formula_off
    pop es
    mov byte [lg_tbuf], '='
    mov di, lg_tbuf + 1
    mov si, ax
    push es
    mov es, [lg_txtseg]
.fcopy:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .fcopy
    pop es
    mov cx, di
    sub cx, lg_tbuf
    dec cx                             ; cx = chars written, excluding NUL
    cmp cx, [lg_cellch]
    jbe .fpad
    mov bx, [lg_cellch]
    mov byte [lg_tbuf + bx], 0         ; longer than a cell: truncate
    jmp .fshow
.fpad:
    mov ax, [lg_cellch]
    sub ax, cx
    jz .fshow
    mov cx, ax
.fploop:
    mov byte [di], ' '
    inc di
    loop .fploop
    mov byte [di], 0
.fshow:
    mov si, lg_tbuf
    jmp .got
.noformula3:
    pop es
.valpath:
    cmp byte [lg_curtype], LG_T_ERR    ; an error draws its NAME - the number
    je .errpath                        ; underneath it is meaningless
    cmp byte [lg_curtype], LG_T_TEXT   ; stage 4.5: a label draws its own
    je .textpath                       ; characters, not its value
    cmp byte [lg_curtype], LG_T_BOOL   ; ...and a LOGICAL its name (81.51),
    je .boolpath                       ; which no number format touches
    xor bh, bh                         ; 81.75: the format byte names every
                                       ; number format there is now
    mov bl, [lg_curfmt]
    mov ax, dx
    call lg_numfmt
    call lg_justify
    mov si, lg_tbuf
    jmp .got
.boolpath:
    mov ax, dx
    call lg_boolname                   ; -> lg_numbuf
    jmp short .centred
.errpath:
    call lg_errname                    ; -> lg_numbuf
.centred:
    mov bl, [lg_curfmt]
    call lg_justify_c                  ; General CENTRES a logical and an
    mov si, lg_tbuf                    ; error, Excel's third General rule
    jmp .got                           ; beside numbers right and labels left.
                                       ; An error sat right, "like the number
                                       ; it replaces", until 81.51
.textpath:
    call lg_text_to_numbuf             ; the arena string, clipped to the cell
    mov bl, [lg_curfmt]
    call lg_justify_t                  ; General means LEFT for a label
    mov si, lg_tbuf
.got:
    mov ax, [lg_wcol]
    call lg_vcx                        ; its own left edge (81.56)
    add ax, [lg_ox]
    add ax, LG_RH_W
    mov cx, ax
    mov ax, [lg_wrow]
    call lg_vry                        ; its own top (81.60)
    add ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    mov dx, ax                         ; DX = the cell's top, for the shade;
                                       ; the text goes lg_rtoff below it
    ; 81.75: no Shade, so no dither to draw the text transparently over -
    ; which means every cell takes FONT_RUN's one pass (6.1), and the one
    ; place in this file that had to letter transparently is gone.
    add dx, [lg_rtoff]
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_RUN
.aftertext:
    test byte [lg_curfmt], LG_FMT_BOLD
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
    test byte [lg_curfmt], LG_FMT_UNDER
    jz .nounder
    call lg_drawunderline
.nounder:
    mov ax, [lg_wcol]
    inc ax
    mov [lg_wcol], ax
    jmp .col
.rownext:
    mov ax, [lg_wrow]
    inc ax
    mov [lg_wrow], ax
    jmp .row
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_drawlines - the cell-boundary lines over the damage range (lg_dmgc1..
; lg_dmgr2; lg_dmgfull for the whole viewport): c2-c1+2 vertical and r2-r1+2
; horizontal, each a degenerate (1px) OSAPI_GFX_FILL rectangle spanning just
; the damaged cells. Drawn AFTER lg_drawgrid: OSAPI_FONT_RUN's opaque erase
; is exactly one cell wide and would otherwise paint back over a line drawn
; first.
; -----------------------------------------------------------------------------
lg_drawlines:
    push ax
    push bx
    push cx
    push dx
    cmp byte [lg_gridlines], 0         ; stage 2.x Options > Gridlines: Off
    je .out                            ; skips this whole pass, same as real
                                        ; Excel's Display dialog
    cmp word [lg_vcols], 0
    je .out
    cmp word [lg_vrows], 0
    je .out
    mov al, CBLACK
    call OSAPI_SET_COLOR

    mov ax, [lg_dmgr1]                 ; the damaged rows' pixel span, each
    call lg_vry                        ; its own height (81.60)...
    add ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    mov [lg_ly1], ax
    mov ax, [lg_dmgr2]
    inc ax
    call lg_vry
    add ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    dec ax
    mov [lg_ly2], ax

    mov ax, [lg_dmgc1]                 ; ...and the damaged columns', each
    call lg_vcx                        ; its own width (81.56)
    add ax, [lg_ox]
    add ax, LG_RH_W
    mov [lg_lx1], ax
    mov ax, [lg_dmgc2]
    inc ax
    call lg_vcx
    add ax, [lg_ox]
    add ax, LG_RH_W
    dec ax
    mov [lg_lx2], ax

    mov ax, [lg_dmgc1]
    mov [lg_wcol], ax
.vline:
    mov ax, [lg_wcol]
    mov dx, [lg_dmgc2]
    inc dx
    cmp ax, dx
    ja .vdone
    call lg_vcx
    add ax, [lg_ox]
    add ax, LG_RH_W
    mov cx, ax
    mov bx, [lg_ly1]
    mov dx, [lg_ly2]
    call OSAPI_GFX_FILL
    mov ax, [lg_wcol]
    inc ax
    mov [lg_wcol], ax
    jmp .vline
.vdone:
    mov ax, [lg_dmgr1]
    mov [lg_wrow], ax
.hline:
    mov ax, [lg_wrow]
    mov dx, [lg_dmgr2]
    inc dx
    cmp ax, dx
    ja .hdone
    call lg_vry
    add ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    mov bx, ax
    mov dx, ax
    mov ax, [lg_lx1]
    mov cx, [lg_lx2]
    call OSAPI_GFX_FILL
    mov ax, [lg_wrow]
    inc ax
    mov [lg_wrow], ax
    jmp .hline
.hdone:
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
lg_drawsel:
    push ax
    push bx
    push cx
    push dx
    call lg_selrect                    ; stage 3.0a: -> lg_selc1..lg_selr2,
                                        ; already ordered

    ; --- clip the block's own cell rect to the visible viewport. Each edge is
    ; clamped rather than the whole block rejected, so a selection that runs
    ; off the screen still draws the part that shows (Excel's own behaviour,
    ; and what a drag past the edge needs). 81.70: lg_vclip_col/row do both
    ; edges at once, frozen-aware, the same clamp lg_updsel needs too
    mov ax, [lg_selc1]
    mov bx, [lg_selc2]
    call lg_vclip_col
    jnc .out
    mov [lg_wcol], ax
    mov [lg_selvc2], bx

    mov ax, [lg_selr1]
    mov bx, [lg_selr2]
    call lg_vclip_row
    jnc .out
    mov [lg_wrow], ax
    mov [lg_selvr2], bx

    ; --- cell coords -> pixels
    mov ax, [lg_wcol]
    call lg_vcx                        ; each column its own width (81.56)
    add ax, [lg_ox]
    add ax, LG_RH_W
    mov [lg_selx1], ax

    mov ax, [lg_selvc2]
    inc ax                             ; one past the last column...
    call lg_vcx                        ; each column its own width (81.56)
    add ax, [lg_ox]
    add ax, LG_RH_W
    dec ax                             ; ...minus a pixel = its right edge
    mov [lg_selx2], ax

    mov ax, [lg_wrow]
    call lg_vry                        ; each row its own height (81.60)
    add ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    mov [lg_sely1], ax

    mov ax, [lg_selvr2]
    inc ax
    call lg_vry
    add ax, [lg_goy]
    add ax, LG_FB_H + LG_CH_H
    dec ax
    mov [lg_sely2], ax

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [lg_selx1]
    mov bx, [lg_sely1]
    mov cx, [lg_selx2]
    mov dx, [lg_sely2]
    call OSAPI_GFX_FRAME
    call lg_selsingle                  ; a single cell keeps the plain 1px
    jc .out                            ; frame it has always had; a real
                                        ; RANGE gets a second, inset frame so
                                        ; it reads as a block rather than as
                                        ; one very large cell (this OS has no
                                        ; wide-pen primitive, and XOR fill
                                        ; over the text would be worse - see
                                        ; os88ui_btn's own note on XOR)
    mov ax, [lg_selx1]
    inc ax
    mov bx, [lg_sely1]
    inc bx
    mov cx, [lg_selx2]
    dec cx
    mov dx, [lg_sely2]
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
; Sheet's own in-window menu bar (see the LG_MBAR_H section comment for why
; this exists instead of OS88_MENUSET): File > New / Open... / Save / Save
; As..., Edit > Cut/Copy/Paste/..., Format > dialogs, Data > Sort Column,
; Sheets > switch, Options > Display toggles, Macro > Run, Help > About.
; =============================================================================

; -----------------------------------------------------------------------------
; lg_mtab_calc - measure each menu title's pixel width once (lg_mw), so
; lg_mboxof never has to call OSAPI_FONT_WIDTH itself on every click/paint.
; Called once from lg_entry - the titles are fixed strings, so this never
; needs to run again.
; -----------------------------------------------------------------------------
lg_mtab_calc:
    push ax
    push bx
    push cx
    push si
    push di
    xor cx, cx
.loop:
    cmp cx, LG_MENU_N
    jae .done
    mov ax, cx
    mov bx, 6
    mul bx
    mov bx, ax
    mov si, [lg_mtab + bx]
    call OSAPI_FONT_WIDTH
    mov di, cx
    shl di, 1
    mov [lg_mw + di], ax
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
; lg_mboxof - AL = menu index -> lg_mbx1/lg_mbx2 (screen-absolute box
; bounds, using the raw [lg_ox]/[lg_oy], not the grid-shifted [lg_goy]).
; preserves everything
; -----------------------------------------------------------------------------
lg_mboxof:
    push ax
    push bx
    push cx
    push dx
    push di
    mov cl, al
    xor ch, ch
    mov dx, [lg_ox]
    xor bx, bx
.loop:
    cmp bx, cx
    jae .found
    mov di, bx
    shl di, 1
    mov ax, [lg_mw + di]
    add ax, LG_MPAD*2
    add dx, ax
    inc bx
    jmp .loop
.found:
    mov [lg_mbx1], dx
    mov di, bx
    shl di, 1
    mov ax, [lg_mw + di]
    add ax, LG_MPAD*2
    add dx, ax
    dec dx
    mov [lg_mbx2], dx
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_mbar_draw - the whole menu bar strip: white ground, black rule under
; it, every title (inverted if it is [lg_mopen]). Monochrome-safe black/
; white/invert, matching every other Sheet dialog in this app, rather than
; real Excel 2.1's cyan bar
; (LIBRARY/documentation/screenshots/excel/excel_main.png) - this OS
; supports 1bpp Hercules/CGA-mono adapters Sheet's own chrome has stayed
; safe for since stage 1.8, and introducing a new color here would be the
; first thing in this app to depend on one existing at all.
; -----------------------------------------------------------------------------
lg_mbar_draw:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [lg_ox]
    mov bx, [lg_oy]
    mov cx, [lg_ox]
    add cx, [lg_cw]
    dec cx
    mov dx, [lg_oy]
    add dx, LG_MBAR_H - 1
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [lg_ox]
    mov bx, [lg_ox]
    add bx, [lg_cw]
    dec bx
    mov dx, [lg_oy]
    add dx, LG_MBAR_H - 1
    call OSAPI_GFX_HLINE
    mov word [lg_mli], 0
    mov word [lg_mto], 0
.loop:
    mov ax, [lg_mli]
    cmp ax, LG_MENU_N
    jae .done
    mov al, [lg_mli]
    call lg_mboxof
    mov al, [lg_mli]
    cmp al, [lg_mopen]
    jne .normal
    mov ax, [lg_mbx1]
    mov bx, [lg_oy]
    mov cx, [lg_mbx2]
    mov dx, [lg_oy]
    add dx, LG_MBAR_H - 1
    call OSAPI_GFX_FILL
    mov al, CWHITE
    call OSAPI_SET_COLOR
    jmp .drawtitle
.normal:
    mov al, CBLACK
    call OSAPI_SET_COLOR
.drawtitle:
    mov bx, [lg_mto]
    mov si, [lg_mtab + bx]
    mov cx, [lg_mbx1]
    add cx, LG_MPAD
    mov dx, [lg_oy]
    add dx, 3
    call OSAPI_FONT_STR_XPARENT
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [lg_mto]
    add ax, 6
    mov [lg_mto], ax
    mov ax, [lg_mli]
    inc ax
    mov [lg_mli], ax
    jmp .loop
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_mbar_hit - CX,DX (screen-absolute) -> AL = menu index or LG_M_NONE
; -----------------------------------------------------------------------------
lg_mbar_hit:
    push bx
    push cx
    push dx
    mov ax, [lg_oy]
    cmp dx, ax
    jb .no
    add ax, LG_MBAR_H - 1
    cmp dx, ax
    ja .no
    mov word [lg_mli], 0
.loop:
    mov ax, [lg_mli]
    cmp ax, LG_MENU_N
    jae .no
    mov al, [lg_mli]
    call lg_mboxof
    cmp cx, [lg_mbx1]
    jb .next
    cmp cx, [lg_mbx2]
    ja .next
    mov ax, [lg_mli]
    jmp .out
.next:
    mov ax, [lg_mli]
    inc ax
    mov [lg_mli], ax
    jmp .loop
.no:
    mov ax, LG_M_NONE
.out:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; lg_mdrop_geo - compute the open menu's ([lg_mopen]) dropdown rect into
; lg_mrx1/mry1/mrx2/mry2, and stash its items ptr/count into lg_mip/
; lg_mcnt for lg_mdrop_draw and lg_mitem_hit to share. Width is the widest
; item label (skipping a leading MENU_DIS byte when measuring); height is
; item_count*LG_MI_H plus a little top/bottom padding. No sliding-under-
; the-screen-edge case (unlike word.asm's wd_mgeo) - Sheet's own dropdowns
; are short enough that this has never yet needed one.
; -----------------------------------------------------------------------------
lg_mdrop_geo:
    push ax
    push bx
    push cx
    push si
    mov al, [lg_mopen]
    call lg_mboxof
    mov ax, [lg_mbx1]
    mov [lg_mrx1], ax
    mov ax, [lg_oy]
    add ax, LG_MBAR_H
    mov [lg_mry1], ax

    mov bl, [lg_mopen]
    xor bh, bh
    mov ax, bx
    mov cx, 6
    mul cx
    mov bx, ax
    mov si, [lg_mtab + bx + 2]
    mov [lg_mip], si
    mov ax, [lg_mtab + bx + 4]
    mov [lg_mcnt], ax

    mov word [lg_mmaxw], 0
    mov word [lg_mli], 0
.wloop:
    mov ax, [lg_mli]
    cmp ax, [lg_mcnt]
    jae .wdone
    mov bx, [lg_mli]
    shl bx, 1
    mov si, [lg_mip]
    add si, bx
    mov si, [si]
    mov al, [si]
    cmp al, MENU_DIS
    jne .measure
    inc si
.measure:
    call OSAPI_FONT_WIDTH
    cmp ax, [lg_mmaxw]
    jbe .wnext
    mov [lg_mmaxw], ax
.wnext:
    mov ax, [lg_mli]
    inc ax
    mov [lg_mli], ax
    jmp .wloop
.wdone:
    mov ax, [lg_mmaxw]
    add ax, LG_MPAD*2 + LG_MCHKW
    mov bx, [lg_mrx1]
    add bx, ax
    dec bx
    mov [lg_mrx2], bx

    mov ax, [lg_mcnt]
    mov cx, LG_MI_H
    mul cx
    add ax, 4
    add ax, [lg_mry1]
    dec ax
    mov [lg_mry2], ax

    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_mdrop_draw - paint the open dropdown from lg_mrx1/y1/x2/y2 + lg_mip/
; lg_mcnt (lg_mdrop_geo must already have run). White panel, black frame,
; one row per item at LG_MI_H apart: disabled items (MENU_DIS) drawn under
; OSAPI_GFX_PEN's disabled (grey) pen; the hot item ([lg_mhi]) drawn
; inverted. Redraws the WHOLE panel on every highlight change rather than
; word.asm's per-row XOR - Sheet's dropdowns are short lists, so this is
; cheap enough not to need that finer granularity.
; -----------------------------------------------------------------------------
lg_mdrop_draw:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [lg_mrx1]
    mov bx, [lg_mry1]
    mov cx, [lg_mrx2]
    mov dx, [lg_mry2]
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [lg_mrx1]
    mov bx, [lg_mry1]
    mov cx, [lg_mrx2]
    mov dx, [lg_mry2]
    call OSAPI_GFX_FRAME
    mov word [lg_mli], 0
.loop:
    mov ax, [lg_mli]
    cmp ax, [lg_mcnt]
    jae .done
    mov cx, LG_MI_H
    mul cx
    add ax, [lg_mry1]
    add ax, 2
    mov [lg_mry_row], ax
    mov bx, [lg_mip]
    mov cx, [lg_mli]
    shl cx, 1
    add bx, cx
    mov si, [bx]
    mov byte [lg_mchk], 0
    mov al, [si]
    cmp al, LG_MENU_CHK               ; stage 3.0c: the same relabel-by-
    jne .notchk                       ; repointing trick MENU_DIS documents,
    inc si                            ; for a mark rather than for grey
    mov byte [lg_mchk], 1
    mov al, [si]
.notchk:
    cmp al, MENU_DIS
    jne .live
    inc si
    stc
    call OSAPI_GFX_PEN
    jmp .drawtext
.live:
    mov ax, [lg_mli]
    cmp al, [lg_mhi]
    jne .plain
    mov ax, [lg_mrx1]
    inc ax
    mov bx, [lg_mry_row]
    mov cx, [lg_mrx2]
    dec cx
    mov dx, [lg_mry_row]
    add dx, LG_MI_H - 1
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
    cmp byte [lg_mchk], 0
    je .nochk
    push ax                           ; the check: A SOLID SQUARE and not a
    push bx                           ; tick (SPEC.md 81.30), because a thin
    push cx                           ; diagonal reads as scattered pixels on
    push dx                           ; the two 1bpp adapters (SPEC.md 39.4) -
    mov ax, [lg_mrx1]                 ; os88ui_chk's own mark and its own
    add ax, LG_MCHKX                  ; reason. The pen is already the right
    mov bx, [lg_mry_row]              ; colour, set by the highlight branch
    add bx, LG_MCHKY                  ; above, so the mark inverts with the row
    mov cx, ax                        ; exactly as the text does
    add cx, LG_MCHKS - 1
    mov dx, bx
    add dx, LG_MCHKS - 1
    call OSAPI_GFX_FILL
    pop dx
    pop cx
    pop bx
    pop ax
.nochk:
    mov cx, [lg_mrx1]
    add cx, LG_MPAD + LG_MCHKW
    mov dx, [lg_mry_row]
    call OSAPI_FONT_STR_XPARENT
    mov ax, [lg_mli]
    inc ax
    mov [lg_mli], ax
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
; lg_mitem_hit - CX,DX (screen-absolute) -> AL = item index, or LG_M_NONE
; if outside the panel, on a separator gap, or on a disabled (MENU_DIS)
; item - a disabled row cannot become the hot item at all, which is what
; lets lg_mdrop_draw assume a highlighted row is always live.
; -----------------------------------------------------------------------------
lg_mitem_hit:
    push bx
    push si
    cmp cx, [lg_mrx1]
    jb .no
    cmp cx, [lg_mrx2]
    ja .no
    cmp dx, [lg_mry1]
    jb .no
    cmp dx, [lg_mry2]
    ja .no
    mov ax, dx
    sub ax, [lg_mry1]
    sub ax, 2
    js .no
    push dx
    xor dx, dx
    mov bx, LG_MI_H
    div bx
    pop dx
    cmp ax, [lg_mcnt]
    jae .no
    mov bx, [lg_mip]
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
    mov ax, LG_M_NONE
.out:
    pop si
    pop bx
    ret

; -----------------------------------------------------------------------------
; lg_mclose - close the open dropdown and repaint what it covered. Always a
; full lg_repaint (menu bar included, since lg_drawall draws it first) -
; Sheet's own grid redraw is cheap, unlike word.asm's wd_mrepair, which
; repaints piecewise specifically to avoid a full-document reflow.
; -----------------------------------------------------------------------------
lg_mclose:
    push ax
    push si
    mov byte [lg_mopen], LG_M_NONE
    mov byte [lg_mhi], LG_M_NONE
    mov si, [lg_ownwin]
    call lg_repaint
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_mtrack - the press-drag-release gesture (word.asm's wd_mtrack pattern:
; a tight OSAPI_MOUSE poll with an unlock/yield/relock between reads, never
; W_ONDRAG - see the LG_MBAR_H section comment for why). in: AL = menu
; index to open, SI = window ptr (this callback's own, untouched SI - see
; lg_onclick); called with the gfx lock already held, exactly the state
; the unlock/relock pair expects.
; -----------------------------------------------------------------------------
lg_mtrack:
    push ax
    push bx
    push si
    mov [lg_mopen], al
    mov byte [lg_mhi], LG_M_NONE
    call lg_mdrop_geo
    call lg_mbar_draw
    call lg_mdrop_draw
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
    call lg_mitem_hit
    cmp al, [lg_mhi]
    je .loop
    mov [lg_mhi], al
    call lg_mdrop_draw
    jmp .loop
.release:
    call lg_mitem_hit
    cmp al, LG_M_NONE
    je .closeonly
    mov ah, [lg_mopen]
    push ax
    call lg_mclose
    pop ax
    call lg_mfire
    jmp .out
.closeonly:
    call lg_mclose
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_mfire - AH = menu index, AL = item index -> dispatch. Sets SI to
; [lg_ownwin] unconditionally before calling anything: this runs from
; lg_mtrack's own polling loop, not a kernel AM_ONCMD callback, so nothing
; here can assume SI already IS the window the way lg_oncmd's old kernel-
; supplied SI always was.
; -----------------------------------------------------------------------------
lg_mfire:
    push ax
    push si
    mov si, [lg_ownwin]
    ; WHAT UNDO CANNOT REVERSE ENDS IT (81.57): a snapshot older than a
    ; format, a name, a note or a macro would put them back too, silently.
    ; Excel 2.1 cannot undo any of these either
    cmp ah, LG_MI_FORMAT               ; Format, all of it
    je .udrop
    cmp ah, LG_MI_MACRO                ; Macro
    je .udrop
    cmp ah, LG_MI_FORMULA              ; Formula: Define Name and Note
    jne .ukept
    cmp al, 3
    je .udrop
    cmp al, 4
    jne .ukept
.udrop:
    call lg_undo_drop
.ukept:
    cmp ah, LG_MI_FILE
    je .file
    cmp ah, LG_MI_EDIT
    je .edit
    cmp ah, LG_MI_FORMAT
    je .format
    cmp ah, LG_MI_DATA
    je .data
    cmp ah, LG_MI_OPTIONS
    je .options
    cmp ah, LG_MI_MACRO
    je .macro
    jmp .out
.file:
    or al, al
    jnz .fopen
    mov al, LG_FDK_NEW
    call lg_fdlg_open_r
    jmp .out
.fopen:
    cmp al, 1
    jne .fsave
    mov al, FDLG_OPEN
    call lg_dlg
    jmp .out
.fsave:
    cmp al, 2
    jne .fsaveas
    call lg_dowrite
    mov si, [lg_ownwin]
    call lg_repaint
    jmp .out
.fsaveas:
    mov al, LG_FDK_SAVEFMT             ; 3, and the last item. ASK for the
    call lg_fdlg_open_r                  ; format, then name it - the format used
    jmp .out                           ; to be whatever extension the typed
                                       ; name happened to end in
.edit:
    call lg_docmd_edit
    jmp .out
.format:
    call lg_docmd_format
    jmp .out
; 81.75: without the database, Data is whatever is left of it - Sort, then
; the three chart items - and the items RENUMBER rather than being greyed.
; A menu showing six commands that cannot happen is worse than a short one,
; and SPEC.md 47 wants a fact to grey on; "not in this build" is not one the
; user can act on. With nothing left the menu itself is gone and LG_MI_DATA
; is 0xFD, so this arm is unreachable rather than absent.
.data:
    jmp .out
.options:
    call lg_docmd_options
    jmp .out
.macro:                                ; 81.75: LG_MI_MACRO is 0xFE in this
    jmp .out                           ; arm, so nothing can reach it
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_docmd_options - AL = 0 Gridlines / 1 Formulas: flip the flag, re-point
; the item's own string to the matching On/Off label (the same relabel-by-
; repointing idea documented above MENU_DIS in apps/os88api.inc, applied to
; lg_i_options directly rather than through the kernel), repaint.
; -----------------------------------------------------------------------------
lg_docmd_options:
    push si
    cmp al, 3                          ; 81.75: four items. Protect Document
    je .ref                            ; went with cell protection, Freeze
    cmp al, 2                          ; Panes with the row-height walk, and
    je .calc                           ; Reference came the other way when the
    or al, al                          ; Formula menu emptied
.formulas:
    xor byte [lg_showformulas], 1
    cmp byte [lg_showformulas], 0
    je .foff
    mov word [lg_i_options+2], lg_it_form_on
    jmp .repaint
.foff:
    mov word [lg_i_options+2], lg_it_form_off
    jmp .repaint
    .ref:
    xor byte [lg_a1style], 1          ; the item relabels itself, which is the
    mov word [lg_i_options+6], lg_it_ref_a1
    cmp byte [lg_a1style], 0
    je .repaint
    mov word [lg_i_options+6], lg_it_ref_rc
    jmp .repaint
.calc:
    mov al, LG_FDK_CALC
    call lg_fdlg_open_r
    pop si
    ret
; FREEZE PANES (81.70). Excel's own: the split is AT the active cell, so
; everything ABOVE and LEFT of it stops scrolling, and choosing the item
; again unfreezes. The ANCHOR is the active cell, not the extent - a
; dragged range freezes at the corner it was dragged FROM.
.freeze:
    mov ax, [lg_freezecol]
    or ax, [lg_freezerow]
    jnz .unfreeze
    mov ax, [lg_selcol]
    or ax, [lg_selrow]
    jnz .dofreeze
    mov word [lg_msg], lg_s_frz_at_a1  ; A1 has nothing above or left of it
    jmp .repaint                       ; to freeze: REFUSED in its own words
                                        ; (47), not silently done as nothing
.dofreeze:
    mov ax, [lg_selcol]
    mov [lg_freezecol], ax
    mov ax, [lg_selrow]
    mov [lg_freezerow], ax
    mov ax, [lg_scrollcol]             ; the scrolling region can never start
    cmp ax, [lg_freezecol]             ; inside the frozen prefix - every
    jae .fcok                          ; other reader takes that invariant
    mov ax, [lg_freezecol]             ; for granted
    mov [lg_scrollcol], ax
.fcok:
    mov ax, [lg_scrollrow]
    cmp ax, [lg_freezerow]
    jae .frok
    mov ax, [lg_freezerow]
    mov [lg_scrollrow], ax
.frok:
    call lg_frzmark
    jmp .repaint
.unfreeze:
    mov word [lg_freezecol], 0
    mov word [lg_freezerow], 0
    call lg_frzmark
    jmp .repaint
.repaint:
    mov si, [lg_ownwin]
    call lg_repaint
    pop si
    ret

; -----------------------------------------------------------------------------
; lg_docmd_help - the only Help item, About Sheet...
; -----------------------------------------------------------------------------
lg_abdismiss:
    cmp byte [lg_abon], 0
    je .none
    push bx
    push si
    mov byte [lg_abon], 0
    mov bx, [lg_ownwin]
    mov si, bx
    call OSAPI_WM_CLIP_SET          ; nothing has armed a region for a click
    jc .gone                        ; or a key (SPEC.md 11.3)
    call lg_repaint                 ; ...which white-fills and draws it all
.gone:
    pop si
    pop bx
    stc
    ret
.none:
    clc
    ret

; -----------------------------------------------------------------------------
; lg_docmd_format - Format menu item AL opens the matching dialog (stage
; 1.8: real Excel's own Format menu is dialog-per-verb - Number.../
; Alignment.../Font... - not a flat immediate-apply list, per the reference
; screenshots at
; LIBRARY/documentation/screenshots/excel/dialog_{number,alignment,font}.png;
; Sheet's menu now matches that shape, see the item table below). AL is 0
; Number, 1 Alignment, 2 Font - the same order lg_fdlg_open expects.
; -----------------------------------------------------------------------------
; lg_docmd_format - Format menu item AL: 0 Number/1 Alignment/2 Font map
; straight onto lg_fdlg_open's own kind numbers. 3 Border opens the
; separate lg_bdlg_* checkbox dialog, 4 Cell Protection is kind
; LG_FDK_PROT, and 5 Row Height/6 Column Width are lg_idlg_open's typed
; fields - lg_fdlg_open's own kinds 5/6, the presets they replaced, are
; retired (81.59).
lg_docmd_format:
    ; 81.75: four items - Number, Alignment, Font, Column Width. Number is the
    ; four-way radio again, because the scrolling list 81.55 gave it was there
    ; to offer the seventeen formats the side table held, and the side table
    ; has gone. Border, Cell Protection and Row Height went with their
    ; features.
    cmp al, 3
    jne .fdlg
    mov al, LG_ID_COLW
    call lg_idlg_open_r
    ret
.fdlg:                                 ; 0 Number / 1 Alignment / 2 Font are
    call lg_fdlg_open_r                ; lg_fdlg's own kinds 0..2, in order
    ret

; -----------------------------------------------------------------------------
; lg_docmd_edit - Edit menu item AL. 0 is "Can't Undo" (MENU_DIS - the
; kernel never sends a click for a disabled item, so index 0 is dead here,
; not a bug). 1 Cut, 2 Copy, 3 Paste use the real system clipboard
; (OSAPI_CLIP_*). 4 Clear. 5 Delete... / 6 Insert... both open the
; Row/Column picker (lg_fdlg_* kinds 4 and 3 - see the dialog engine's own
; comment for why one engine now serves 5 kinds). 7 Fill Right / 8 Fill
; Down are deliberately scoped down from real Excel: fill acts on just the
; one adjacent cell.
;
; THIS USED TO SAY "no range selection exists in this app (W_ONDRAG is
; missing... so a real rectangular selection was ruled out)". Stage 3.0a
; built one - drag, shift+click and shift+arrows - and the note stayed, in
; three places (here, lg_rowcol_op and lg_docmd_sortcol) all pointing at
; this one as the source. The BEHAVIOUR those two describe is still true;
; the REASON is not, and a reason that has expired is worse than none,
; because it says the thing cannot be done.
; -----------------------------------------------------------------------------
lg_docmd_edit:
    or al, al                          ; 0 is Undo or Redo when there is a
    jnz .notundo                       ; snapshot, and MENU_DIS - so it never
    call lg_undo_do                    ; arrives - when there is not (81.57)
    ret
.notundo:
    push ax                            ; the commands that act at once take
    mov ah, al                         ; their snapshot here; the dialogs'
    mov al, LG_UL_CUT                  ; take it at OK, in lg_fdlg_apply
    cmp ah, 2
    je .snap
    mov al, LG_UL_PASTE
    cmp ah, 4
    je .snap
    jmp short .nosnap
.snap:
    call lg_undo_begin
    pop ax
    call .cmd
    call lg_undo_end
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
    call lg_docmd_cut
    ret
.copy:
    call lg_docmd_copy
    ret
.paste:
    mov byte [lg_ps_mode], LG_PS_ALL
    call lg_docmd_paste
    ret
.clear:
    mov al, LG_FDK_CLEAR
    call lg_fdlg_open_r
    ret

; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; lg_ps_src - the SOURCE cell for the block position being pasted into.
; out: AX = column, BX = row. The block walker keeps (lg_pb_x, lg_pb_y) as the
; offset within the block, and lg_clip_col/lg_clip_row is where the block was
; copied FROM, so the source is just the two added - the same arithmetic the
; reference shift does in the other direction.
;
; Only meaningful when lg_clip_valid: an external clipboard has text and no
; cells behind it. Every caller here is reached only after that test.
; -----------------------------------------------------------------------------
lg_ps_src:
    mov ax, [lg_clip_col]
    add ax, [lg_pb_x]
    mov bx, [lg_clip_row]
    add bx, [lg_pb_y]
    ret

; -----------------------------------------------------------------------------
; lg_ps_srcsheet / lg_ps_mysheet - step into the sheet the block was COPIED
; from, and back out again. (81.45.4)
;
; An address is not a cell here: lg_findcell, lg_bt_get and lg_nt_get all pack
; lg_cursheet into the row word, so reading the source cell's format, border or
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
; enter overwrites the outer's bank. They do not: lg_paste_cell reaches
; lg_ps_valtext for LG_PS_VAL and lg_ps_props for ALL/FORMATS/NOTES, and no
; mode reaches both.
; -----------------------------------------------------------------------------
lg_ps_srcsheet:
    push ax
    mov ax, [lg_cursheet]
    mov [lg_ps_ownsheet], ax
    mov ax, [lg_clip_sheet]
    mov [lg_cursheet], ax
    pop ax
    ret
lg_ps_mysheet:
    push ax
    mov ax, [lg_ps_ownsheet]
    mov [lg_cursheet], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_ps_props - copy the source cell's PROPERTIES onto the destination, which
; parts depending on [lg_ps_mode]: the format byte and the border for All and
; Formats, the note for All and Notes.
;
; The destination is wherever lg_selcol/lg_selrow point, which lg_paste_cell
; has just set. A source cell with no record contributes nothing rather than
; writing a default over what is already there - "paste formats" from an empty
; cell is not "clear the formats".
; -----------------------------------------------------------------------------
lg_ps_props:
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
    call lg_ps_srcsheet
    call lg_ps_src
    call lg_findcell
    jnc .done                         ; no source record: nothing to copy
    mov es, [lg_cellseg]
    mov dl, [es:di+LG_C_FMT]
    mov cl, 1
.done:
    call lg_ps_mysheet                ; ...and back, before anything is written
    or cl, cl
    jz .out
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    call lg_findcell
    jnc .out                          ; no DESTINATION record either - the
    mov es, [lg_cellseg]              ; same scope limit lg_fdlg_apply
    mov [es:di+LG_C_FMT], dl          ; documents for the Format dialogs
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
; lg_ps_valtext - the SOURCE cell's value, as text, into lg_editbuf: what
; "Values" means. A formula cell yields the number it produced, not the
; formula; a label yields its characters.
;
; This is lg_cell_totext's .notformula branch, reached UNCONDITIONALLY - which
; is the whole difference between the two routines and the reason this is not
; a flag on that one. lg_cell_totext exists to reproduce what the user typed;
; this exists to discard it.
; -----------------------------------------------------------------------------
lg_ps_valtext:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    mov byte [lg_editbuf], 0
    call lg_ps_srcsheet               ; the source cell is on the sheet the
    call lg_ps_src                    ; block was COPIED from (81.45.4)
    call lg_findcell
    jnc .valdone                      ; an empty source pastes an empty cell
    mov es, [lg_cellseg]
    cmp byte [es:di+LG_C_TYPE], LG_T_TEXT
    je .label
    call lg_cellnum                   ; the eight value bytes, as decimal
    mov si, lg_numbuf
    mov di, lg_editbuf
    call lg_strcpy
    jmp .valdone
.label:
    mov ax, [es:di+LG_C_FOFF]         ; a label shares the formula arena
    mov si, ax
    mov di, lg_editbuf
    mov es, [lg_txtseg]
.acopy:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .acopy
.valdone:
    call lg_ps_mysheet                ; EVERY path leaves it, not just the
.count:                               ; empty one - the caller commits to the
                                      ; CURRENT sheet immediately after
    xor cx, cx
    mov si, lg_editbuf
.len:
    cmp byte [si], 0
    je .haslen
    inc si
    inc cx
    jmp .len
.haslen:
    mov [lg_editlen], cl
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_ps_linktext - "=<the source cell>" into lg_editbuf: what Paste Link
; means. Written as A1-style text and handed to lg_commit like anything else,
; so the result is an ordinary formula that happens to name one cell - which
; is exactly what Excel produces, and means every later Insert/Delete/Sort
; rewrites it through the machinery that already exists (81.28).
;
; RELATIVE, not absolute. Excel 2.1's Paste Link writes a relative reference,
; so a linked block dragged elsewhere follows the same rule as any other
; copied formula.
; -----------------------------------------------------------------------------
lg_ps_linktext:
    push ax
    push bx
    push cx
    push si
    push di
    mov byte [lg_editbuf], '='
    mov di, lg_editbuf + 1
    ; --- a link to ANOTHER sheet has to say which one (81.45.4) -----------
    mov ax, [lg_clip_sheet]
    cmp ax, [lg_cursheet]
    je .samesheet                     ; the ordinary case writes no prefix, so
    push ax                           ; a same-sheet link is byte-for-byte
    mov si, lg_s_sheetpfx             ; what it always was
    call lg_strcpy_to_di
    pop ax
    add al, '1'                       ; "Sheet1".."Sheet4" are the only names
    mov [di], al                      ; there are (lg_psheetpfx), so the index
    inc di                            ; IS the digit
    mov byte [di], '!'
    inc di
.samesheet:
    call lg_ps_src
    push bx                           ; lg_colname and lg_itoa both go through
    call lg_colname                   ; scratch buffers, so the row is banked
    mov si, lg_colbuf                 ; rather than recomputed
    call lg_strcpy_to_di
    pop ax
    inc ax                            ; rows are 1-based on screen
    call lg_itoa
    mov si, lg_numbuf
    call lg_strcpy_to_di
    mov byte [di], 0                  ; A1 STYLE UNCONDITIONALLY, even with
                                      ; the reference box set to R1C1: that is
                                      ; a DISPLAY setting (81.31), and this
                                      ; text goes to lg_commit, whose parser
                                      ; reads A1 and nothing else
    xor cx, cx
    mov si, lg_editbuf
.len:
    cmp byte [si], 0
    je .haslen
    inc si
    inc cx
    jmp .len
.haslen:
    mov [lg_editlen], cl
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_cell_totext - the text of the cell at (AX,BX) into lg_clipbuf: a formula's
; own source with its '=' restored, a label's characters, or a number as
; decimal. An empty cell gives an empty string. out: CX = the length.
;
; Copy used to do this inline and got two of the three wrong. It read a WORD at
; LG_C_VAL and ran lg_itoa over it - which is what everything did before stage
; 4.0, and is meaningless now that the value is an eight-byte double whose low
; word is mantissa bits (lg_cellnum exists to say exactly that). And it had no
; case for a label at all, so copying a column heading ran the numeric path
; over its text offset. One routine now, so the next thing that needs a cell as
; text cannot get a third answer.
; -----------------------------------------------------------------------------
lg_cell_totext:
    push ax
    push bx
    push dx                           ; callers loop on DX; lg_cellnum and the
    push si                           ; arena copy below both go through it
    push di
    push es
    mov byte [lg_clipbuf], 0
    call lg_findcell
    jnc .count
    mov es, [lg_cellseg]
    test byte [es:di+4], 1            ; HASFORMULA
    jz .notformula
    mov ax, [es:di+LG_C_FOFF]
    mov byte [lg_clipbuf], '='
    mov di, lg_clipbuf + 1
    jmp .arena
.notformula:
    cmp byte [es:di+LG_C_TYPE], LG_T_TEXT
    je .label
    call lg_cellnum                   ; the eight value bytes, as decimal
    mov si, lg_numbuf
    mov di, lg_clipbuf
    call lg_strcpy
    jmp .count
.label:
    mov ax, [es:di+LG_C_FOFF]         ; a label shares the formula arena
    mov di, lg_clipbuf
.arena:
    mov si, ax
    mov es, [lg_txtseg]
.acopy:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .acopy
.count:
    xor cx, cx
    mov si, lg_clipbuf
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
; lg_docmd_copy - builds the selected cell's text (a formula's own source
; text with its '=' restored, or a plain value's decimal text - the same
; two cases lg_beginedit already knows how to build, just targeting
; lg_clipbuf instead of lg_editbuf) and hands it to the real clipboard. An
; empty cell empties the clipboard instead (CX=0 is documented as not an
; error).
; -----------------------------------------------------------------------------
lg_docmd_copy:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    ; THE TOP-LEFT of the selection, not the anchor: a drag can start at any
    ; corner, and Paste's reference shift is measured from where the block
    ; began rather than from where the mouse went down.
    mov ax, [lg_selcol]
    mov bx, [lg_selcol2]
    cmp ax, bx
    jbe .cpc
    xchg ax, bx
.cpc:
    mov [lg_clip_col], ax
    mov cx, bx                         ; cx = last column
    mov ax, [lg_selrow]
    mov bx, [lg_selrow2]
    cmp ax, bx
    jbe .cpr
    xchg ax, bx
.cpr:
    mov [lg_clip_row], ax
    mov ax, [lg_cursheet]              ; WHICH SHEET the block came from, which
    mov [lg_clip_sheet], ax            ; matters the moment Paste Special reads
    mov byte [lg_clip_valid], 1        ; the SOURCE CELLS again (81.45.4)
    ; --- build the block as TAB-SEPARATED TEXT in the staging segment ------
    ; Tabs between columns, CR/LF between rows, and nothing after the last
    ; one - which is exactly what Excel puts on the clipboard, makes a 1x1
    ; block byte-identical to what this used to write, and means a copied
    ; block pastes into Word as text that lines up.
    push bp
    mov es, [lg_stgseg]
    xor di, di                         ; di = the write cursor
    mov dx, ax                         ; dx = the current row
.rowloop:
    mov bp, [lg_clip_col]              ; bp = the current column
.colloop:
    push ax
    push bx
    push cx
    push dx
    mov ax, bp
    mov bx, dx
    call lg_cell_totext                ; -> lg_clipbuf, CX = length
    mov si, lg_clipbuf
.emit:
    or cx, cx
    jz .emitted
    cmp di, LG_STAGE_MAX - 4           ; the staging area is the bound here
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
    cmp di, LG_STAGE_MAX - 4
    jae .rowend
    mov byte [es:di], 9                ; TAB between columns
    inc di
    inc bp
    jmp .colloop
.rowend:
    cmp dx, bx                         ; bx is still the last row
    jae .blockdone
    cmp di, LG_STAGE_MAX - 4
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

; lg_docmd_cut - Copy, then Clear
lg_docmd_cut:
    push ax
    push bx
    push cx
    push si
    push di
    ; ...and the SAME orphan as lg_paste_cell's, from the same cut: SHEET has
    ; `call sh_prot_blocked` here and tests ITS carry. Protection went with
    ; 81.75 and the test stayed, reading whatever CF the CALLER happened to
    ; leave - so Cut refused or ran depending on the command before it.
    call lg_docmd_copy                 ; the whole block goes to the clipboard,
    mov ax, [lg_selrow]                ; so the whole block has to leave the
    mov bx, [lg_selrow2]               ; sheet - it cleared the anchor alone
    cmp ax, bx                         ; and left the rest of what it had just
    jbe .cutrows                       ; copied sitting there
    xchg ax, bx
.cutrows:
    mov cx, [lg_selcol]
    mov si, [lg_selcol2]
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
    call lg_clearcell
    pop bx
    pop ax
    inc di
    cmp di, bx
    jbe .cutrowloop
    inc cx
    cmp cx, si
    jbe .cutcolloop
    mov si, [lg_ownwin]
    call lg_repaint
    jmp .out
                                      ; (Cut's `.refused` arm went with the
                                      ; orphan above: it repainted after a
                                      ; protection refusal, and nothing can
                                      ; reach it now that there is no refusal)
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_docmd_paste - reads the system clipboard straight into lg_editbuf
; (capped to LG_EDITMAX, same as anything a keyboard could ever produce
; there); if this instance's own last Copy captured a formula AND a
; source cell (lg_clip_valid), and the destination differs from it,
; shifts every reference in the pasted formula by the (col, row) delta
; between them (lg_formula_copyshift) - real Excel's own default
; relative-reference behavior - before calling lg_commit to reuse its
; existing value/formula parsing exactly as if this (possibly rewritten)
; text had been typed. An empty clipboard is a no-op.
; -----------------------------------------------------------------------------
lg_docmd_paste:
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
    cmp ax, LG_STAGE_MAX - 2           ; the staging segment holds the block
    jbe .fits                          ; while it is taken apart
    mov ax, LG_STAGE_MAX - 2
.fits:
    mov cx, ax
    mov es, [lg_stgseg]
    xor di, di
    call OSAPI_CLIP_GET
    mov [lg_pb_len], cx
    mov ax, [lg_selcol]                ; where the block lands
    mov [lg_pb_c0], ax
    mov ax, [lg_selrow]
    mov [lg_pb_r0], ax
    mov word [lg_pb_x], 0
    mov word [lg_pb_y], 0
    mov word [lg_pb_cur], 0
.cell:
    mov ax, [lg_pb_cur]
    cmp ax, [lg_pb_len]
    jae .done
    ; --- one cell's text out of the block, up to TAB, CR, LF or the end ----
    mov es, [lg_stgseg]
    mov si, ax
    mov di, lg_editbuf
    xor cx, cx
.take:
    cmp si, [lg_pb_len]
    jae .took
    mov al, [es:si]
    cmp al, 9
    je .took
    cmp al, 13
    je .took
    cmp al, 10
    je .took
    cmp cx, LG_EDITMAX
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
    mov [lg_editlen], cl
    mov [lg_pb_cur], si                ; the terminator is consumed below
    call lg_paste_cell
    ; --- what ended it decides where the next one goes --------------------
    mov es, [lg_stgseg]
    mov si, [lg_pb_cur]
    cmp si, [lg_pb_len]
    jae .done
    mov al, [es:si]
    inc si
    mov [lg_pb_cur], si
    cmp al, 9                          ; TAB: the next column
    jne .newrow
    inc word [lg_pb_x]
    jmp .cell
.newrow:
    cmp al, 13                         ; CR, and swallow an LF behind it
    jne .lfonly
    cmp si, [lg_pb_len]
    jae .rowdone
    cmp byte [es:si], 10
    jne .rowdone
    inc si
    mov [lg_pb_cur], si
.rowdone:
.lfonly:
    mov word [lg_pb_x], 0
    inc word [lg_pb_y]
    jmp .cell
.done:
    mov ax, [lg_pb_c0]                 ; put the selection back where it was
    mov [lg_selcol], ax
    mov [lg_selcol2], ax
    mov ax, [lg_pb_r0]
    mov [lg_selrow], ax
    mov [lg_selrow2], ax
    mov si, [lg_ownwin]                ; ONE repaint for the whole block
    call lg_repaint
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
; lg_paste_cell - commit lg_editbuf into the block cell at (lg_pb_x, lg_pb_y),
; shifting a formula's relative references by the SAME delta for every cell in
; the block: where the block landed, less where it was copied from. That is
; Excel's rule, and it is what makes a copied column of =A1*B1 still line up a
; column over.
;
; It moves lg_selcol/lg_selrow and calls lg_commit rather than reimplementing
; the decision, because lg_commit is the ONE place that decides whether text
; is a formula, a number or a label - a second copy of that would be a second
; answer. The selection is restored by the caller when the block is done.
; -----------------------------------------------------------------------------
lg_paste_cell:
    push ax
    push bx
    push cx
    push si
    push di
    mov ax, [lg_pb_c0]
    add ax, [lg_pb_x]
    cmp ax, LG_COLS
    jae .out                           ; a block that runs off the edge stops
    mov [lg_selcol], ax                ; at it rather than wrapping
    mov [lg_selcol2], ax
    mov bx, [lg_pb_r0]
    add bx, [lg_pb_y]
    cmp bx, LG_ROWS
    jae .out
    mov [lg_selrow], bx
    mov [lg_selrow2], bx
    ; NOTHING TESTS THE CARRY HERE, and there used to be a `jc .out` that did.
    ; It belonged to the `call lg_prot_blocked` above it - document protection,
    ; which 81.75 cut - and when the call went the test stayed. `mov` does not
    ; touch the flags, so what it read was the `cmp bx, LG_ROWS` two lines up,
    ; and an IN-RANGE row is exactly the case that leaves CF set (which is why
    ; the `jae` above it is not taken). So it was taken for every valid cell:
    ; lg_paste_cell returned before committing anything and PASTE NEVER PASTED,
    ; on any machine, with the menu item enabled and no message.
    ; --- WHICH PARTS OF THE SOURCE CELL THIS PASTE IS FOR (81.45) ----------
    mov al, [lg_ps_mode]
    cmp al, LG_PS_LINK
    je .dolink
    cmp al, LG_PS_FMT                 ; Formats and Notes leave the CONTENTS
    jb .contents                      ; alone entirely - they are the two
    call lg_ps_props                  ; modes with nothing to commit
    jmp .out
.dolink:
    call lg_ps_linktext               ; "=<the source cell>" - no shifting,
    jmp .commit                       ; the whole point is that it points back
.contents:
    cmp al, LG_PS_VAL
    jne .astyped
    call lg_ps_valtext                ; the source's VALUE, so a formula lands
    jmp .commit                       ; as the number it produced. Never
                                      ; reference-shifted: there is no
                                      ; reference left in it to shift
.astyped:
    cmp byte [lg_clip_valid], 0
    je .commit
    cmp byte [lg_editbuf], '='
    jne .commit
    mov ax, [lg_pb_c0]
    sub ax, [lg_clip_col]
    mov [lg_cp_coldelta], ax
    mov bx, [lg_pb_r0]
    sub bx, [lg_clip_row]
    mov [lg_cp_rowdelta], bx
    or ax, bx
    jz .commit                         ; pasted onto the cell it came from
    mov si, lg_editbuf
    inc si
    mov di, lg_rwsrc
.copyin:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov si, lg_rwsrc
    call lg_formula_copyshift
    mov byte [lg_editbuf], '='
    mov si, lg_rwdst
    mov di, lg_editbuf + 1
    mov cx, LG_EDITMAX - 1             ; a shifted reference can grow a digit
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
    mov si, lg_editbuf
.relen:
    cmp byte [si], 0
    je .haverelen
    inc si
    inc cx
    jmp .relen
.haverelen:
    mov [lg_editlen], cl
.commit:
    mov byte [lg_editing], 1
    call lg_commit
    cmp byte [lg_ps_mode], LG_PS_ALL  ; All is contents AND properties, which
    jne .out                          ; is what Excel's plain Paste does too
    call lg_ps_props
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_docmd_fillright / lg_docmd_filldown - fill the SELECTED RANGE from its
; own first column/row, the way Excel does: Fill Down copies the selection's
; top row into every row under it, for every column in the selection, and
; Fill Right copies its left column across.
;
; These two used to copy exactly one cell into exactly one neighbour, because
; they were written before range selection existed (stage 3.0a) and were never
; taught about lg_selcol2/lg_selrow2. Selecting a block and choosing Fill Down
; changed a single cell and reported nothing - the selection stayed drawn over
; cells that had not been touched. A SINGLE-CELL selection still fills the one
; neighbour, which is what the old behaviour was and what collapsing the
; anchor and extent already means here.
;
; A formula source has its text copied through lg_formula_copyshift (the same
; relative-reference shift Copy/Paste uses), and the delta is the FULL offset
; from the source rather than always one - filling five rows down has to shift
; the fifth by five. A plain value is copied as its current value.
; -----------------------------------------------------------------------------
; lg_fill_copy - one cell to another. in: lg_fl_scol/srow = source,
; lg_fl_dcol/drow = destination. An empty source copies nothing. Preserves
; every register, so the loops below can keep their bounds in theirs.
; -----------------------------------------------------------------------------






; -----------------------------------------------------------------------------
; lg_sort_vof / lg_sort_ldds / lg_sort_cmp - the three places the sort's value
; array is touched, so its EIGHT-BYTE stride lives in exactly one of them.
; It was a word per entry and the multiply was written inline six times; a
; widening done that way is how a missed site returns a plausible wrong number
; with no crash (the risk this file's own record-layout comment names).
;
; lg_sort_vof - in: BX = entry index, out: DI = its offset in lg_stgseg
; -----------------------------------------------------------------------------
section LG_MODSEC                      ; 81.71.6: Data > Sort's worker, CHART.OVL
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
; and write - see lg_fdlg_kind - which is why one implementation serves
; all three rather than three near-copies.
;
; Built directly on apps/os88ui.inc's primitives (os88ui_glyph for the
; radio dots, os88ui_btn for OK/Cancel) rather than os88ui_ask, which only
; ever offers a message and a button row - there is no generic
; "N controls" dialog builder in this codebase (apps/word/word.asm rolled
; its own, ~900 lines, for a dozen much bigger dialogs; three small
; identical-shaped ones don't need that). Only one can be open at a time
; (lg_fdlg_win is the gate, same single-instance idea as os88ui_awin, just
; simpler: this dialog doesn't need "refuse and raise" since the menu
; command that opens it can't fire again while it's up).
;
; Radio index 0-3 in each dialog is deliberately identical to that
; category's own LG_FMT_*/LG_NF_* encoding (LG_FMT_ALIGN_LEFT=1,
; LG_NF_CURRENCY=2,
; etc, and Font's 0=Normal/1=Bold/2=Underline/3=Bold+Underline is just
; LG_FMT_BOLD|LG_FMT_UNDER's own bit pattern) - so applying a choice is a
; plain mask-and-OR, no translation table needed anywhere.
; =============================================================================
LG_FDLG_W      equ 170
LG_FDLG_ROWTOP equ 12
LG_FDLG_ROWH   equ 16
LG_FDLG_NITEMS equ 4
; THE BUTTON ROW AND THE WINDOW HEIGHT ARE ONE NUMBER, not two that have to be
; kept in agreement by hand. They were two, and they disagreed: the height was
; a flat 116 while the buttons were drawn at content-relative 86..102, and a
; window's content is only W_H - TITLE_H - 1 tall (wm_content: the origin is
; W_X+1, W_Y+TITLE_H). 116 - 18 - 1 = 97, so the bottom HALF of OK and Cancel
; was outside the window in every one of this engine's kinds - Number,
; Alignment, Font, Insert, Delete, Column Width and Row Height since stage 1.8,
; and the four stage 3.0c added. Deriving it means the next kind that needs a
; taller body cannot reintroduce this by changing one of the two.
LG_FDLG_MAXROWS equ 7                ; the tallest kind's row count, and the
                                     ; reason the button row is derived from
                                     ; it rather than fixed: the Gallery kind
                                     ; has five rows and the row at index 4
                                     ; landed ON the buttons, because 86 was
                                     ; chosen when four was the most any kind
                                     ; had. A new kind with more rows changes
                                     ; this one number.
LG_FDLG_BTY1   equ LG_FDLG_ROWTOP + LG_FDLG_MAXROWS * LG_FDLG_ROWH + 4
LG_FDLG_BTY2   equ LG_FDLG_BTY1 + 16
LG_DLG_BMARG   equ 8                 ; the gap every dialog leaves below its
                                     ; lowest element, and the reason all four
                                     ; heights below are DERIVED: a window's
                                     ; content is W_H - TITLE_H - 1 tall, so a
                                     ; hand-written height is a second number
                                     ; that has to agree with the first and
                                     ; silently did not
LG_FDLG_H      equ LG_FDLG_BTY2 + LG_DLG_BMARG + TITLE_H + 1

lg_fdlg_tpl:
    dw 0, 0, LG_FDLG_W, LG_FDLG_H
    dw 0, lg_fdlg_paint_r, 0, 0    ; W_ONCLICK: os88ui_btninit's (20.5.1.3.3)

; Stage 2.x's Edit menu Insert.../Delete... reuse this same engine as kinds
; 3 and 4 - just a 2-item Row/Column pick instead of a 4-item format
; radio, and a different [lg_fdlg_count] (see lg_fdlg_open) since these
; two kinds don't have 4 rows to show. lg_fdlg_apply branches to
; lg_rowcol_op for these two kinds instead of writing a format bit.
; Kinds 5/6 are RETIRED: they were the Narrow/Normal/Wide and Short/Normal/
; Tall presets Column Width.../Row Height... used before stage 3.0c gave
; them lg_idlg_open's typed field, and nothing has opened them since. Their
; code went in 81.59; the two slots stay, as zeros, so every later kind keeps
; its number - lg_ud_kind and the LG_FDK_* equates are indexed by it.
; Kinds 7-10 (stage 3.0c) are the last four radio dialogs Excel 2.1d has and
; this app was doing as immediate menu commands: Clear, New, Calculation and
; Sort. Each was a one-line "just do it" item, which is wrong twice - Excel
; asks, and asking is what lets Clear mean something other than "everything"
; and Sort mean something other than "ascending".
; 81.75: kinds 15 and 16 are Extract and Series. They go the way 5 and 6 did
; when they were retired - the SLOT stays, because a kind is an index into
; these three tables and into lg_ud_kind, and the entry becomes 0.
lg_fdlg_titles: dw lg_s_fd_num, lg_s_fd_align, lg_s_fd_font, lg_s_fd_insert, lg_s_fd_delete, 0, 0, lg_s_fd_clear, lg_s_fd_new, lg_s_fd_calc, lg_s_fd_sort, lg_s_fd_gal, lg_s_fd_savefmt, lg_s_fd_pspec, lg_s_fd_prot
                dw 0, 0
lg_s_fd_pspec:  db 'Paste Special', 0
lg_s_fd_prot:   db 'Cell Protection', 0
lg_s_fd_savefmt: db 'File Format', 0
lg_s_fd_gal:    db 'Gallery', 0
lg_s_fd_clear:  db 'Clear', 0
lg_s_fd_new:    db 'New', 0
lg_s_fd_calc:   db 'Calculation', 0
lg_s_fd_sort:   db 'Sort', 0
lg_s_fd_num:    db 'Format Number', 0
lg_s_fd_align:  db 'Alignment', 0
lg_s_fd_font:   db 'Font', 0
lg_s_fd_insert: db 'Insert', 0
lg_s_fd_delete: db 'Delete', 0

lg_fdlg_items:  dw lg_fd_i_num, lg_fd_i_align, lg_fd_i_font, lg_fd_i_rowcol, lg_fd_i_rowcol, 0, 0, lg_fd_i_clear, lg_fd_i_new, lg_fd_i_calc, lg_fd_i_sort, lg_fd_i_gal, lg_fd_i_savefmt, lg_fd_i_pspec, lg_fd_i_prot
                dw 0, 0
; Excel's Cell Protection dialog is two INDEPENDENT CHECK BOXES, Locked and
; Hidden. This is the four combinations as a radio, which is exactly what the
; Font dialog above already does with Bold and Underline - the same engine and
; the same compression, so it is at least consistent with itself. The order
; mirrors Font's: the default first, then each one alone, then both.
lg_fd_i_prot:   dw lg_fd_prlock, lg_fd_prunlock, lg_fd_prlockh, lg_fd_prunlockh
lg_fd_prlock:   db 'Locked', 0
lg_fd_prunlock: db 'Unlocked', 0
lg_fd_prlockh:  db 'Locked, Hidden', 0
lg_fd_prunlockh: db 'Unlocked, Hidden', 0
; 81.71: Excel's own Extract dialog carries ONE control, a `Unique Records
; Only` CHECK BOX. This engine paints a radio column, so the same single bit
; is asked as a two-way pick instead - identical meaning, no sixth dialog
; engine, and the divergence is the one §81.31 already took for Gridlines and
; Formulas. Index 1 IS the flag, so lg_fdlg_apply0 stores it with no mapping.
; 81.72: Excel's Series dialog carries FIVE controls - Series In, Type, Date
; Unit, Step Value and Stop Value. Type and Date Unit fold into one radio
; column here (a date unit is only ever read when the type IS Date, so the
; two questions are really one), Step Value is the second dialog, and the
; other two are 81.72's own documented shortfalls
; Excel's own five, in Excel's own order (Reference Guide p.236). The dialog
; there ALSO carries an Operation group (None/Add/Subtract/Multiply/Divide)
; and two check boxes (Skip Blanks, Transpose); this engine paints ONE radio
; column and an OK/Cancel, so those are absent rather than faked - see 81.45.
lg_fd_i_pspec:  dw lg_fd_psall, lg_fd_psform, lg_fd_psval, lg_fd_psfmt, lg_fd_psnote
lg_fd_psall:    db 'All', 0
lg_fd_psform:   db 'Formulas', 0
lg_fd_psval:    db 'Values', 0
lg_fd_psfmt:    db 'Formats', 0
lg_fd_psnote:   db 'Notes', 0
; Excel's own words: the app's OWN format is "Normal", and the interchange
; formats are named after themselves. The order is Excel's too.
; PLAN has no BIFF, so there is no "Normal" to be distinct FROM: SYLK is this
; package's own format and heads its own list (81.75).
lg_fd_i_savefmt: dw lg_fd_sfsylk, lg_fd_sfcsv, lg_fd_sftxt
lg_fd_sfsylk:   db 'SYLK', 0
lg_fd_sfcsv:    db 'CSV', 0         ; 81.40: two of the nine formats Excel 2.0
lg_fd_sftxt:    db 'Text', 0
                                    ; own words for them in its Save As list
; Excel's own Gallery order, which is alphabetical and is NOT the order CH_T_*
; happens to be in - lg_gal_map translates, the same way chart.asm's own
; ct_gal_map does, rather than either side renumbering to suit the other.
lg_fd_i_gal:    dw lg_fd_garea, lg_fd_gbar, lg_fd_gcol, lg_fd_gline, lg_fd_gpie, lg_fd_gsca, lg_fd_gcmb
lg_fd_garea:    db 'Area', 0
lg_fd_gbar:     db 'Bar', 0
lg_fd_gcol:     db 'Column', 0
lg_fd_gline:    db 'Line', 0
lg_fd_gpie:     db 'Pie', 0
lg_fd_gsca:     db 'Scatter', 0
lg_fd_gcmb:     db 'Combination', 0
lg_fd_i_clear:  dw lg_fd_clall, lg_fd_clform, lg_fd_clfmt
lg_fd_clall:    db 'All', 0
lg_fd_clform:   db 'Formulas', 0       ; Excel's own order and its own words:
lg_fd_clfmt:    db 'Formats', 0        ; "Formulas" means the CONTENTS
lg_fd_i_new:    dw lg_fd_nwsheet, lg_fd_nwchart, lg_fd_nwmacro
lg_fd_nwsheet:  db 'Worksheet', 0
lg_fd_nwchart:  db 'Chart', 0
lg_fd_nwmacro:  db 'Macro Sheet', 0
lg_fd_i_calc:   dw lg_fd_cauto, lg_fd_cmanual, lg_fd_cnow
lg_fd_cauto:    db 'Automatic', 0
lg_fd_cmanual:  db 'Manual', 0
lg_fd_cnow:     db 'Calculate Now', 0
lg_fd_i_sort:   dw lg_fd_sasc, lg_fd_sdesc
lg_fd_sasc:     db 'Ascending', 0
lg_fd_sdesc:    db 'Descending', 0
lg_fd_i_num:    dw lg_fd_numnum, lg_fd_numtext, lg_fd_numcur
lg_fd_numnum:   db 'Number', 0
lg_fd_numtext:  db 'Text', 0
lg_fd_numcur:   db 'Currency', 0
lg_fd_i_align:  dw lg_fd_agen, lg_fd_aleft, lg_fd_acenter, lg_fd_aright
lg_fd_agen:     db 'General', 0
lg_fd_aleft:    db 'Left', 0
lg_fd_acenter:  db 'Center', 0
lg_fd_aright:   db 'Right', 0
lg_fd_i_font:   dw lg_fd_fnorm, lg_fd_fbold, lg_fd_funder, lg_fd_fboth
lg_fd_fnorm:    db 'Normal', 0
lg_fd_fbold:    db 'Bold', 0
lg_fd_funder:   db 'Underline', 0
lg_fd_fboth:    db 'Bold, Underline', 0
lg_fd_i_rowcol: dw lg_fd_rcrow, lg_fd_rccol
lg_fd_rcrow:    db 'Row', 0
lg_fd_rccol:    db 'Column', 0

lg_s_fd_ok:     db 'OK', 0
lg_s_fd_cancel: db 'Cancel', 0

; per-kind row count (0 Number/1 Align/2 Font = 4 rows, 3 Insert/4 Delete
; = 2 rows, 5/6 retired) - lg_fdlg_open copies the
; matching entry into [lg_fdlg_count], which lg_fdlg_paint/lg_fdlg_onclick
; loop and hit-test against instead of the fixed LG_FDLG_NITEMS.
lg_fdlg_counts: dw 3, 4, 4, 2, 2, 0, 0, 3, 3, 3, 2, 7, 3, 5, 4, 2, 6
                                      ; 0 Number is three now: Number, Text,
                                      ; Currency (81.75)

LG_FDK_CLEAR equ 7
LG_FDK_NEW   equ 8
LG_FDK_CALC  equ 9
LG_FDK_SORT  equ 10
LG_FDK_GAL   equ 11
LG_FDK_SAVEFMT equ 12                 ; stage 4.6: Save As asks for the format
LG_FDK_PSPEC equ 13                   ; instead of deriving it silently
LG_FDK_PROT  equ 14
LG_FDK_EXTRACT equ 15                 ; 81.71: Data ▸ Extract...
LG_FDK_SERIES equ 16                  ; 81.72: Data ▸ Series..., part one of
LG_FDK_N     equ 17                   ; two (the step value follows)
    times (lg_ud_kind_end - lg_ud_kind - LG_FDK_N) db 0  ; lg_ud_kind (81.57)
    times (LG_FDK_N - (lg_ud_kind_end - lg_ud_kind)) db 0 ; has a kind each
section LG_MODSEC                      ; 81.74.2: the radio dialog engine, CHART.OVL

; -----------------------------------------------------------------------------
; lg_fdlg_open - in: AL = 0 Number / 1 Alignment / 2 Font. Preselects the
; radio matching the selected cell's current format (0/General if the cell
; has no record yet - the dialog still opens; OK on a still-empty cell is a
; no-op, same scope limit the old flat menu already had).
; -----------------------------------------------------------------------------
lg_fdlg_open:
    push ax
    push bx
    push cx
    push si
    push di
    cmp word [lg_fdlg_win], 0
    jne .out                          ; already open (can't happen via the
                                       ; menu, which is inert while a dialog
                                       ; owns input focus, but stay safe)
    mov [lg_fdlg_kind], al
    mov word [lg_fdlg_sel], 0
    mov bl, al
    xor bh, bh
    shl bx, 1
    mov cx, [lg_fdlg_counts + bx]
    mov [lg_fdlg_count], cx
    cmp al, LG_FDK_SAVEFMT
    je .prefillfmt                    ; File Format opens on the format the
    cmp al, LG_FDK_CALC               ; OK alone cannot silently change it
    je .prefillcalc                   ; Calculation opens SHOWING the mode it
    cmp al, LG_FDK_CLEAR              ; what the cell already IS, for exactly
    jae .noprefill                    ; that reason. Clear/New/Sort have
                                       ; nothing current
    cmp al, 3
    jae .noprefill                    ; Insert/Delete (kinds 3/4): no
                                       ; "current" selection to preselect,
                                       ; just default to row 0 ("Row")
    jmp .cellpre
.prefillfmt:
    mov word [lg_fdlg_sel], 0         ; PLAN's list starts at SYLK, which is
    jmp .noprefill                    ; also what lg_dowrite falls through to
.prefillcalc:
    xor ah, ah
    mov al, [lg_calcmanual]
    mov [lg_fdlg_sel], ax
    jmp .noprefill
.cellpre:
    mov ax, [lg_selcol]
    mov bx, [lg_selrow]
    SHOUT lg_findcell
    jnc .noprefill
    push es
    mov es, [lg_cellseg]
    mov al, [es:di+5]
    pop es
    mov ah, 0
    cmp byte [lg_fdlg_kind], 0
    je .pfnum
    cmp byte [lg_fdlg_kind], 1
    je .pfalign
    and al, 0x03                      ; Font: bits0-1 directly
    jmp .havesel
.pfnum:
    and al, LG_FMT_NUM_MASK
    mov cl, LG_FMT_NUM_SHIFT
    shr al, cl
    jmp .havesel
.pfalign:
    and al, LG_FMT_ALIGN_MASK
    mov cl, LG_FMT_ALIGN_SHIFT
    shr al, cl
.havesel:
    mov [lg_fdlg_sel], ax
    jmp .noprefill
.noprefill:
    mov bl, [lg_fdlg_kind]
    xor bh, bh
    shl bx, 1
    mov ax, [lg_fdlg_titles + bx]
    mov [lg_fdlg_tpl + WT_TITLE], ax
    call OSAPI_VIDEO                  ; centre on the LIVE screen, the same
    sub ax, LG_FDLG_W                 ; way os88ui_ask does (apps/os88ui.inc)
    sar ax, 1
    mov [lg_fdlg_tpl + WT_X], ax
    sub bx, LG_FDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8                ; never under the menu bar
.placed:
    mov [lg_fdlg_tpl + WT_Y], bx
    mov si, lg_fdlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [lg_fdlg_win], bx
    push ax                            ; **THE GESTURE'S THREE SLOTS** (SPEC.md
    push bx                            ; 20.5.1.3): the buttons fire on the
    push si                            ; RELEASE, and the library takes the
    push di                            ; press first
    push dx
    mov ax, bx
    mov bx, lg_fdlg_btrec
    call lg_btunlink                   ; off the list first: a re-open would
    mov si, lg_fdlg_onup                ; otherwise link the record to itself
    mov di, lg_fdlg_ondrag
    mov dx, lg_fdlg_click_r             ; our own click work (rows / field)
    call os88ui_btninit
    pop dx
    pop di
    pop si
    pop bx
    pop ax
    call OSAPI_WM_SHOW
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_fdlg_paint - SI = the dialog window. Uses bss scratch (lg_fdlg_ox/oy/
; itemsptr/rowidx/rowy) rather than stack juggling to hold state across the
; os88ui_glyph/OSAPI_FONT_RUN calls, since both take CX/DX as their own
; position input - a register-only approach would need constant reshuffling
; for no real benefit here (this paints at most once per click).
; -----------------------------------------------------------------------------
lg_fdlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si                         ; OSAPI_WM_CONTENT wants BX=window
    call OSAPI_WM_CONTENT              ; -> ax=content x, dx=content y
    mov [lg_fdlg_ox], ax
    mov [lg_fdlg_oy], dx
    mov bl, [lg_fdlg_kind]
    xor bh, bh
    shl bx, 1
    mov si, [lg_fdlg_items + bx]       ; the window's own title bar already
    mov [lg_fdlg_itemsptr], si         ; names the dialog (lg_fdlg_open set
                                        ; WT_TITLE) - no need to repeat it as
                                        ; content
    mov word [lg_fdlg_rowidx], 0
.rowloop:
    mov cx, [lg_fdlg_rowidx]
    cmp cx, [lg_fdlg_count]
    jae .rowsdone
    mov ax, cx
    mov bx, LG_FDLG_ROWH
    mul bx
    add ax, LG_FDLG_ROWTOP
    add ax, [lg_fdlg_oy]
    mov [lg_fdlg_rowy], ax
    mov ax, [lg_fdlg_sel]
    cmp ax, [lg_fdlg_rowidx]
    mov al, OS88UI_GRADIO
    jne .goff
    or al, OS88UI_GON
.goff:
    mov ah, 0
    mov cx, [lg_fdlg_ox]
    add cx, 8
    mov dx, [lg_fdlg_rowy]
    SHOUT os88ui_glyph                  ; preserves all registers (its own doc)
    mov si, [lg_fdlg_itemsptr]
    mov bx, [lg_fdlg_rowidx]
    shl bx, 1
    add si, bx
    mov si, [si]                       ; si = this row's label string
    mov cx, [lg_fdlg_ox]
    add cx, 24
    mov dx, [lg_fdlg_rowy]
    add dx, 2
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_RUN
    mov ax, [lg_fdlg_rowidx]
    inc ax
    mov [lg_fdlg_rowidx], ax
    jmp .rowloop
.rowsdone:
    mov ax, [lg_fdlg_ox]
    add ax, 8
    mov [lg_fdlg_rect], ax
    mov ax, [lg_fdlg_oy]
    add ax, LG_FDLG_BTY1
    mov [lg_fdlg_rect+2], ax
    mov ax, [lg_fdlg_ox]
    add ax, 62
    mov [lg_fdlg_rect+4], ax
    mov ax, [lg_fdlg_oy]
    add ax, LG_FDLG_BTY2
    mov [lg_fdlg_rect+6], ax
    mov ax, [lg_fdlg_ox]               ; ...and Cancel into rect ONE, beside it
    add ax, 96
    mov [lg_fdlg_rect+8], ax
    mov ax, [lg_fdlg_oy]
    add ax, LG_FDLG_BTY1
    mov [lg_fdlg_rect+10], ax
    mov ax, [lg_fdlg_ox]
    add ax, 150
    mov [lg_fdlg_rect+12], ax
    mov ax, [lg_fdlg_oy]
    add ax, LG_FDLG_BTY2
    mov [lg_fdlg_rect+14], ax
    mov word [lg_fdlg_btrec+OS88UI_BT_RECTS], lg_fdlg_rect
    mov word [lg_fdlg_btrec+OS88UI_BT_LABELS], lg_dlg_blfd
    mov word [lg_fdlg_btrec+OS88UI_BT_FLAGS], lg_dlg_bflags
    mov word [lg_fdlg_btrec+OS88UI_BT_N], 2
    mov bx, lg_fdlg_btrec
    mov al, 1
    SHOUT os88ui_btn                    ; OK
    mov al, 2
    SHOUT os88ui_btn                    ; ...and Cancel
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- the dialogs' button groups (SPEC.md 20.5.1.3) ---------------------------
; OK is index 1 and Cancel index 2 in both, so the FLAGS are shared outright:
; OK carries the default ring and Cancel carries nothing.
lg_dlg_bflags: dw OS88UI_DEF, 0
lg_dlg_blfd:   dw lg_s_fd_ok,   lg_s_fd_cancel
lg_dlg_blidlg: dw lg_s_idlg_ok, lg_s_idlg_can

; -----------------------------------------------------------------------------
; lg_fdlg_onclick - in: CX=x, DX=y (screen-absolute, same convention as
; lg_onclick), SI=the dialog window
; -----------------------------------------------------------------------------
lg_fdlg_onclick:
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
                                       ; (OK/Cancel are the library's press
                                       ; now, and fire in lg_fdlg_onup)
.checkrows:
    cmp cx, 8
    jb .out
    cmp bx, LG_FDLG_ROWTOP
    jb .out
    mov ax, bx
    sub ax, LG_FDLG_ROWTOP
    xor dx, dx
    mov si, LG_FDLG_ROWH
    div si                             ; ax = row index
    cmp ax, [lg_fdlg_count]
    jae .out
    mov [lg_fdlg_sel], ax
    mov si, [lg_fdlg_win]
    call lg_fdlg_paint
.out:
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_fdlg_onup / lg_fdlg_ondrag - the release and the tracking edge (13.7/13.8.2)
; -----------------------------------------------------------------------------
lg_fdlg_onup:
    push ax
    push bx
    push si
    push di
    mov bx, lg_fdlg_btrec
    call os88ui_btnup                 ; AX = what FIRED, 0 = cancelled
    or ax, ax
    jz .uout
    cmp al, 1
    jne .ucancel
    call lg_fdlg_apply
    call lg_fdlg_close
    cmp byte [lg_savepend], 0         ; File Format's OK owes a Save As, and it
    je .uout                          ; runs only now that the format dialog's
    mov byte [lg_savepend], 0         ; window is DESTROYED. Opening the file
    mov si, [lg_ownwin]               ; dialog from inside apply would stack a
    mov al, FDLG_SAVE                 ; second dialog on a window slot that is
    SHOUT lg_dlg                       ; still in use, which is how one gets
    jmp short .uout                   ; orphaned behind the other
.ucancel:
    call lg_fdlg_close
.uout:
    pop di
    pop si
    pop bx
    pop ax
    ret

lg_fdlg_ondrag:
    push ax
    push bx
    mov bx, lg_fdlg_btrec
    call os88ui_btndrag
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_btunlink - BX = a button record: take it OFF os88ui_btlist if it is on it.
; Preserves all registers.
;
; os88ui_btninit PREPENDS its record every call, and a dialog re-opened calls
; it again with the SAME record - whose NEXT would then point at itself, and a
; press that has to walk past it would spin forever in os88ui_btnclick. So
; every btninit here is preceded by this.
; -----------------------------------------------------------------------------
lg_btunlink:
    push ax
    push si
    mov si, os88ui_btlist             ; SI -> the word that points at the
.walk:                                ; current node (the head, then a NEXT)
    mov ax, [si]
    or ax, ax
    jz .done                          ; not on the list
    cmp ax, bx
    je .unlink
    mov si, ax
    add si, OS88UI_BT_NEXT
    jmp short .walk
.unlink:
    mov ax, [bx+OS88UI_BT_NEXT]
    mov [si], ax
.done:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_setext - in: SI -> a 4-byte ".XXX". Replaces [lg_name]'s extension, or
; appends one if it has none, so picking a format in the Save As dialog
; renames BUDGET.SLK to BUDGET.BIF rather than leaving the name disagreeing
; with the bytes. lg_dowrite still decides by extension - this makes the
; extension follow the CHOICE instead of the other way round.
;
; lg_name is 13 bytes and holds an 8.3 name, so the worst case (an 8-char
; stem with no dot) writes 8+4+1 = 13. Nothing longer can arrive: the file
; dialog is what fills this buffer and it enforces 8.3.
; -----------------------------------------------------------------------------
lg_setext:
    push ax
    push cx
    push si
    push di
    mov di, lg_name
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
; lg_clear_one - Clear's work for ONE cell, by [lg_fdlg_sel]: 0 All /
; 1 Formulas / 2 Formats. "Formulas" is Excel's word for the CONTENTS - a cell
; cleared that way keeps its border, its number format and its font, which is
; the whole reason the dialog exists - and a cell with nothing of that kind
; to keep goes altogether. in: AX = col, BX = row. Preserves all.
; -----------------------------------------------------------------------------
lg_clear_one:
    push ax
    push bx
    push di
    push es
    cmp word [lg_fdlg_sel], 2
    je .fmt
    cmp word [lg_fdlg_sel], 1
    je .contents
    SHOUT lg_clearcell                 ; All: the record and all of it
    jmp .out
.contents:
    SHOUT lg_findcell                  ; NOTHING TO KEEP - no format byte
    jnc .out                          ; either - then the contents going
    mov es, [lg_cellseg]              ; leave no cell at all, as All's do,
    cmp byte [es:di+5], 0             ; rather than a zero where Excel shows
    jne .keep2                        ; nothing (81.63)
    SHOUT lg_clearcell
    jmp .out
    SHOUT lg_findcell
    jnc .out
    mov es, [lg_cellseg]
.keep2:
    mov byte [es:di+4], 0             ; not a formula any more...
    mov byte [es:di+LG_C_TYPE], LG_T_NUM
    mov word [es:di+LG_C_VAL], 0      ; ...and zero, but the format byte at
    mov word [es:di+LG_C_VAL+2], 0    ; +5 is deliberately untouched
    mov word [es:di+LG_C_PASS], 0
    jmp .out
.fmt:
    SHOUT lg_findcell
    jnc .out
    mov es, [lg_cellseg]
    mov byte [es:di+5], 0             ; Formats: the format byte, which is now
                                      ; the whole of what a format is
.out:
    pop es
    pop di
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_fmt_one - apply the format dialog's current choice to ONE cell.
; in: AX = col, BX = row. An empty cell has no record to carry a format and is
; skipped, which is what the single-cell version did too. Preserves all.
; -----------------------------------------------------------------------------
lg_fmt_one:
    push ax
    push bx
    push cx
    push di
    push es
    SHOUT lg_findcell
    jnc .out
    mov es, [lg_cellseg]
    mov bl, [es:di+5]
    mov al, [lg_fdlg_sel]
    cmp byte [lg_fdlg_kind], 0
    je .num
    cmp byte [lg_fdlg_kind], 1
    je .align
    and bl, LG_FMT_BU_CLR              ; Font: bits0-1 directly
    or bl, al
    jmp .put
.num:
    and bl, LG_FMT_NUM_CLR
    mov cl, LG_FMT_NUM_SHIFT
    shl al, cl
    or bl, al
    jmp .put
.align:
    and bl, LG_FMT_ALIGN_CLR
    mov cl, LG_FMT_ALIGN_SHIFT
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
; lg_fdlg_apply - kinds 0-2 (Number/Alignment/Font): write [lg_fdlg_sel]
; into the selected cell's format byte, in the field [lg_fdlg_kind] names -
; a no-op if the cell has no record (see lg_fdlg_open's own comment on
; that scope limit). Kinds 3-4 (Insert/Delete): [lg_fdlg_sel] is 0 Row / 1
; Column, so hand off to lg_rowcol_op with the selected cell's own row or
; column as the pivot index - these have no "cell must have a record"
; limit, since they act on the grid's structure, not a cell's content.
; -----------------------------------------------------------------------------
lg_fdlg_apply:
    ; UNDO AT OK, NOT AT THE MENU (81.57): a dialog the user cancels changes
    ; nothing, so nothing is snapshot for it. lg_ud_kind says, per kind, the
    ; action's label, or that it ends Undo (a format, New), or neither
    push ax
    push bx
    mov bl, [lg_fdlg_kind]
    xor bh, bh
    cmp bx, LG_FDK_N
    jae .ukeep
    mov al, [lg_ud_kind + bx]
    cmp al, LG_UL_KEEP
    je .ukeep
    cmp al, LG_UL_DROP
    jne .usnap
    SHOUT lg_undo_drop
    jmp short .ukeep
.usnap:
    SHOUT lg_undo_begin
.ukeep:
    pop bx
    pop ax
    call lg_fdlg_apply0
    SHOUT lg_undo_end                  ; 81.74.2: a tail JUMP would enter a
    ret                                ; resident body with no far frame

lg_fdlg_apply0:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    cmp byte [lg_fdlg_kind], LG_FDK_CLEAR
    je .doclear
    cmp byte [lg_fdlg_kind], LG_FDK_NEW
    je .donew
    cmp byte [lg_fdlg_kind], LG_FDK_CALC
    je .docalc
    cmp byte [lg_fdlg_kind], LG_FDK_SAVEFMT
    je .dosavefmt
    cmp byte [lg_fdlg_kind], LG_FDK_PSPEC
    je .dopspec
    ; Number/Alignment/Font apply to the WHOLE SELECTION. They used to read
    ; lg_selcol/lg_selrow and format the anchor alone, so selecting a column
    ; of figures and choosing Currency changed exactly one cell - the same
    ; thing Fill Right/Down did before 81.13, and for the same reason: written
    ; before range selection existed and never taught about lg_selcol2/
    ; lg_selrow2. A single-cell selection is a 1x1 range, so it still works.
    mov ax, [lg_selrow]
    mov bx, [lg_selrow2]
    cmp ax, bx
    jbe .fmtrows
    xchg ax, bx
.fmtrows:                              ; ax = top row, bx = bottom row
    mov cx, [lg_selcol]
    mov si, [lg_selcol2]
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
    call lg_fmt_one
    pop bx
    pop ax
    inc di
    cmp di, bx
    jbe .fmtrowloop
    inc cx
    cmp cx, si
    jbe .fmtcolloop
    SHOUT lg_repaint                    ; ONE repaint for the whole block
    jmp .out
; --- stage 3.0c: the four that used to be immediate menu commands -----------
.doclear:                             ; ...and the THIRD orphan of the same cut.
                                      ; SHEET has `SHOUT sh_prot_blocked` here
                                      ; and tests its carry; 81.75 cut
                                      ; protection and left the `jc .refused`
                                      ; behind. Control REACHES this label by a
                                      ; jump, so the flag it read belonged to
                                      ; whatever the dispatcher did last
    ; Over the WHOLE SELECTION, like Excel's Clear and like the block the user
    ; has highlighted. It used to clear the anchor alone (81.17's third case,
    ; after Fill and the format dialogs).
    mov ax, [lg_selrow]
    mov bx, [lg_selrow2]
    cmp ax, bx
    jbe .clrows
    xchg ax, bx
.clrows:                              ; ax = top row, bx = bottom row
    mov cx, [lg_selcol]
    mov si, [lg_selcol2]
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
    call lg_clear_one
    pop bx
    pop ax
    inc di
    cmp di, bx
    jbe .clrowloop
    inc cx
    cmp cx, si
    jbe .clcolloop
.cldone:
    mov si, [lg_ownwin]               ; ONE repaint for the block
    SHOUT lg_repaint
    jmp .out

.donew:
    ; Excel asks which KIND of new document. This app has one grid type, so
    ; Chart and Macro Sheet do the honest thing rather than the flattering
    ; one: a new sheet, and a status line saying what was actually made.
    SHOUT lg_new
    mov word [lg_msg], lg_s_nw_sheet
    cmp word [lg_fdlg_sel], 1
    jne .nwnotchart
    mov word [lg_msg], lg_s_nw_chart
.nwnotchart:
    cmp word [lg_fdlg_sel], 2
    jne .nwdone
    mov word [lg_msg], lg_s_nw_macro
.nwdone:
    mov si, [lg_ownwin]
    SHOUT lg_repaint
    jmp .out

.docalc:
    ; 0 Automatic / 1 Manual / 2 Calculate Now. Manual is not a no-op with a
    ; label on it: lg_drawgrid re-evaluates every formula cell on every
    ; repaint, so switching it off is what a big sheet on a 4.77MHz 8088
    ; actually needs, and Calculate Now is then the only way to catch up.
    cmp word [lg_fdlg_sel], 2
    je .calcnow
    mov ax, [lg_fdlg_sel]
    mov [lg_calcmanual], al
    mov word [lg_msg], lg_s_calc_auto
    or al, al
    jz .calcrepaint
    mov word [lg_msg], lg_s_calc_man
    jmp .calcrepaint
.calcnow:
    inc word [lg_pass]                ; a pass stamp nothing has cached, which
    mov word [lg_msg], lg_s_calc_now  ; is exactly what forces the recompute
.calcrepaint:
    mov si, [lg_ownwin]
    SHOUT lg_repaint
    jmp .out

.protdoc:
    mov word [lg_msg], lg_s_protdoc
.refused:
    mov si, [lg_ownwin]
    SHOUT lg_repaint
    jmp .out
.dopspec:
    mov al, [lg_fdlg_sel]             ; the radio IS the mode: All/Formulas/
    mov [lg_ps_mode], al              ; Values/Formats/Notes are LG_PS_ALL..
    SHOUT lg_docmd_paste               ; LG_PS_NOTE in that order, on purpose
    jmp .out
.dosavefmt:
    mov si, lg_s_ext_sylk             ; 0 SYLK / 1 CSV / 2 Text (81.75)
    mov ax, [lg_fdlg_sel]
    or ax, ax
    jz .fmtset
    mov si, lg_s_ext_csv
    cmp ax, 1
    je .fmtset
    mov si, lg_s_ext_txt
.fmtset:
    call lg_setext
    mov byte [lg_savepend], 1         ; the file dialog cannot open until
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
; lg_fdlg_close
; -----------------------------------------------------------------------------
lg_fdlg_close:
    push ax
    push bx
    mov bx, [lg_fdlg_win]
    or bx, bx
    jz .out
    mov word [lg_fdlg_win], 0
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
; a dispatch on it, the same way lg_fdlg_* already serves five radio-list
; kinds rather than being copied five times.
;
; This is what the text widget was for. Row Height... and Column Width... have
; been a THREE-PRESET RADIO PICK since stage 1.8 purely because no free-text
; entry existed at the app level - lg_m_format's own comment says so. They are
; now real numeric entry, which is what Excel 2.1d has.
; =============================================================================
LG_ID_GOTO   equ 0                   ; Formula > Goto...
LG_ID_ROWH   equ 1                   ; Format > Row Height...
LG_ID_COLW   equ 2                   ; Format > Column Width...
LG_ID_DEFN   equ 3                   ; Formula > Define Name...
LG_ID_FIND   equ 4                   ; Formula > Find...
LG_ID_SORT   equ 5                   ; Data > Sort... (stage 4.5): the KEY.
                                     ; Excel 2.1's Sort dialog takes its keys
                                     ; as cell references typed into fields,
                                     ; which is exactly what this engine is,
                                     ; and it is the only way to name a key
                                     ; that is not an edge of the selection
                                     ; (81.19 recorded that as a known limit;
                                     ; 81.27 is this)
LG_ID_RUN    equ 6                   ; Macro > Run... (81.63): where to start
LG_ID_INPUT  equ 7                   ; ...and INPUT(), a macro's own question
LG_ID_SERSTEP equ 8                  ; 81.72: Data ▸ Series...' step value,
LG_ID_RECNAME equ 9                  ; part two of two; 81.74: what to call
LG_ID_NKIND  equ 10                  ; the recording about to be made

LG_IDLG_W    equ 268
LG_IDLG_FX1  equ 8                   ; the field, content-relative
LG_IDLG_FY1  equ 28
LG_IDLG_FX2  equ 176
LG_IDLG_FY2  equ 46
LG_IDLG_BTX1 equ 186                 ; OK / Cancel, 64 wide - 'Cancel' needs
LG_IDLG_BTX2 equ 250                 ; 6 glyphs at the fixed 8px cell
LG_IDLG_OKY1 equ 26
LG_IDLG_OKY2 equ 46
LG_IDLG_CAY1 equ 54
LG_IDLG_CAY2 equ 74
LG_IDLG_H    equ LG_IDLG_CAY2 + LG_DLG_BMARG + TITLE_H + 1

lg_idlg_tpl:
    dw 0, 0, LG_IDLG_W, LG_IDLG_H
    dw lg_s_id_tgoto, lg_idlg_paint_r, lg_idlg_key_r, 0    ; W_ONCLICK: os88ui_btninit's
; The title above is only a PLACEHOLDER: lg_idlg_open overwrites
; [lg_idlg_tpl + WT_TITLE] with whichever of lg_s_id_t* the kind names, before
; OSAPI_WM_CREATE. WT_TITLE is a pointer TO the text, so the pointer has to go
; into the template itself - putting it in a cell and pointing the template at
; that cell makes the kernel letter the pointer's own two bytes and then run on
; into whatever follows, which is exactly what it did.
lg_id_titles:  dw lg_s_id_tgoto, lg_s_id_trowh, lg_s_id_tcolw, lg_s_id_tdefn, lg_s_id_tfind
               dw lg_s_id_tsort, lg_s_id_trun, lg_s_id_tinput, lg_s_id_tser
               dw lg_s_id_trec
lg_id_prompts: dw lg_s_id_pgoto, lg_s_id_prowh, lg_s_id_pcolw, lg_s_id_pdefn, lg_s_id_pfind
               dw lg_s_id_psort, lg_s_id_pgoto, lg_macro_msg, lg_s_id_pser
               dw lg_s_id_prec
lg_s_id_trec:  db 'Record Macro', 0
lg_s_id_prec:  db 'Name:', 0
lg_s_id_tser:  db 'Series', 0
lg_s_id_pser:  db 'Step value:', 0
lg_s_id_tgoto: db 'Goto', 0
lg_s_id_trowh: db 'Row Height', 0
lg_s_id_tcolw: db 'Column Width', 0
lg_s_id_tdefn: db 'Define Name', 0
lg_s_id_tfind: db 'Find', 0
lg_s_id_tsort: db 'Sort', 0
lg_s_id_trun:  db 'Run', 0
lg_s_id_tinput: db 'Input', 0
lg_s_id_pgoto: db 'Reference:', 0
lg_s_id_prowh: db 'Row height:', 0
lg_s_id_pcolw: db 'Column width:', 0
lg_s_id_pdefn: db 'Name:', 0
lg_s_id_pfind: db 'Find what:', 0
lg_s_id_psort: db '1st Key:', 0     ; Excel 2.1's own label for the field
lg_s_idlg_ok:  db 'OK', 0
lg_s_idlg_can: db 'Cancel', 0
section LG_MODSEC                      ; 81.74.2: the one-line input dialog, CHART.OVL

; -----------------------------------------------------------------------------
; lg_idlg_open - in: AL = LG_ID_*. Preloads the field with the CURRENT value
; (the selection's reference, or the live row height / column width) so the
; dialog opens showing what it is about to change, and Enter alone is a no-op
; rather than a surprise.
; -----------------------------------------------------------------------------
lg_idlg_open:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    cmp word [lg_idlg_win], 0
    jne .out
    cmp al, LG_ID_NKIND
    jae .out
    mov [lg_idlg_kind], al
    xor ah, ah
    mov bx, ax
    shl bx, 1                          ; word index into the two tables
    mov ax, [lg_id_titles + bx]
    mov [lg_idlg_tpl + WT_TITLE], ax
    mov byte [lg_idlg_buf], 0
    cmp byte [lg_idlg_kind], LG_ID_DEFN ; key you get by pressing Enter
    jae .prenone                       ; Define Name and Find open EMPTY: there
    mov ax, [lg_selcol]                ; the SELECTED column's own width, in
    SHOUT lg_colwidth                   ; characters, matching what OK reads
    SHOUT lg_itoa
.precopy:
    mov di, lg_idlg_buf
    mov si, lg_numbuf
    SHOUT lg_strcpy_to_di
    jmp .haveinit
.pregoto:
    mov di, lg_idlg_buf                ; the selection, as 'A1'
    mov ax, [lg_selcol]
    SHOUT lg_colname
    mov si, lg_colbuf
    SHOUT lg_strcpy_to_di
    mov ax, [lg_selrow]
    inc ax
    SHOUT lg_itoa
    mov si, lg_numbuf
    SHOUT lg_strcpy_to_di
.prenone:
.haveinit:
    mov si, lg_idlg_line
    mov word [si + LN_BUF], lg_idlg_buf
    mov word [si + LN_MAX], LG_EDITMAX
    mov byte [si + LN_FOCUS], 1
    mov di, lg_idlg_buf
    SHOUT os88line_set                  ; sets LEN/CAR/VIEW from the content
    call OSAPI_VIDEO
    sub ax, LG_IDLG_W
    sar ax, 1
    mov [lg_idlg_tpl + WT_X], ax
    sub bx, LG_IDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8
.placed:
    mov [lg_idlg_tpl + WT_Y], bx
    mov si, lg_idlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [lg_idlg_win], bx
    push ax                            ; **THE GESTURE'S THREE SLOTS** (SPEC.md
    push bx                            ; 20.5.1.3): the buttons fire on the
    push si                            ; RELEASE, and the library takes the
    push di                            ; press first
    push dx
    mov ax, bx
    mov bx, lg_idlg_btrec
    call lg_btunlink                   ; off the list first: a re-open would
    mov si, lg_idlg_onup                ; otherwise link the record to itself
    mov di, lg_idlg_ondrag
    mov dx, lg_idlg_click_r             ; our own click work (rows / field)
    call os88ui_btninit
    pop dx
    pop di
    pop si
    pop bx
    pop ax
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
; lg_idlg_paint - SI = the dialog window
; -----------------------------------------------------------------------------
lg_idlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call OSAPI_WM_CONTENT
    mov [lg_idlg_ox], ax
    mov [lg_idlg_oy], dx
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov bl, [lg_idlg_kind]             ; the prompt for this kind
    xor bh, bh
    shl bx, 1
    mov si, [lg_id_prompts + bx]
    mov cx, [lg_idlg_ox]
    add cx, LG_IDLG_FX1
    mov dx, [lg_idlg_oy]
    add dx, 8
    call OSAPI_FONT_STR_XPARENT

    mov si, lg_idlg_line               ; the field's rect from the LIVE origin
    mov ax, [lg_idlg_ox]               ; every paint - the window moves
    add ax, LG_IDLG_FX1
    mov [si + LN_X1], ax
    mov ax, [lg_idlg_ox]
    add ax, LG_IDLG_FX2
    mov [si + LN_X2], ax
    mov ax, [lg_idlg_oy]
    add ax, LG_IDLG_FY1
    mov [si + LN_Y1], ax
    mov ax, [lg_idlg_oy]
    add ax, LG_IDLG_FY2
    mov [si + LN_Y2], ax
    SHOUT os88line_draw

    mov ax, [lg_idlg_ox]               ; OK
    add ax, LG_IDLG_BTX1
    mov [lg_idlg_rect], ax
    mov ax, [lg_idlg_oy]
    add ax, LG_IDLG_OKY1
    mov [lg_idlg_rect+2], ax
    mov ax, [lg_idlg_ox]
    add ax, LG_IDLG_BTX2
    mov [lg_idlg_rect+4], ax
    mov ax, [lg_idlg_oy]
    add ax, LG_IDLG_OKY2
    mov [lg_idlg_rect+6], ax
    mov ax, [lg_idlg_rect]             ; Cancel: OK's x, two new y's
    mov [lg_idlg_rect+8], ax
    mov ax, [lg_idlg_rect+4]
    mov [lg_idlg_rect+12], ax
    mov ax, [lg_idlg_oy]
    add ax, LG_IDLG_CAY1
    mov [lg_idlg_rect+10], ax
    mov ax, [lg_idlg_oy]
    add ax, LG_IDLG_CAY2
    mov [lg_idlg_rect+14], ax
    mov word [lg_idlg_btrec+OS88UI_BT_RECTS], lg_idlg_rect
    mov word [lg_idlg_btrec+OS88UI_BT_LABELS], lg_dlg_blidlg
    mov word [lg_idlg_btrec+OS88UI_BT_FLAGS], lg_dlg_bflags
    mov word [lg_idlg_btrec+OS88UI_BT_N], 2
    mov bx, lg_idlg_btrec
    mov al, 1
    SHOUT os88ui_btn                    ; OK
    mov al, 2
    SHOUT os88ui_btn                    ; ...and Cancel

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_idlg_onkey - Enter is OK and Escape is Cancel, which is what a one-field
; dialog should do; os88line_key deliberately does NOT consume Enter (its own
; header says so) precisely so the caller can use it for this.
; -----------------------------------------------------------------------------
lg_idlg_onkey:
    push ax
    push si
    cmp al, 27
    je .cancel
    cmp al, 0x0D
    je .accept
    mov si, lg_idlg_line
    SHOUT os88line_key
    jc .out
    mov si, [lg_idlg_win]
    call lg_idlg_paint
    jmp .out
.accept:
    call lg_idlg_apply
    call lg_idlg_close
    jmp .out
.cancel:
    call lg_idlg_close
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_idlg_onclick - CX,DX = the click, screen-absolute
; -----------------------------------------------------------------------------
lg_idlg_onclick:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, lg_idlg_line               ; the field's rect is already
    SHOUT os88line_click                ; screen-absolute from the last paint
    jc .out                            ; not the field: OK/Cancel are the
.redraw:                               ; library's press, fired in lg_idlg_onup
    mov si, [lg_idlg_win]
    call lg_idlg_paint
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_idlg_onup / lg_idlg_ondrag - the release and the tracking edge (13.7/13.8.2)
; -----------------------------------------------------------------------------
lg_idlg_onup:
    push ax
    push bx
    push si
    push di
    mov bx, lg_idlg_btrec
    call os88ui_btnup                  ; AX = what FIRED, 0 = cancelled
    or ax, ax
    jz .uout
    cmp al, 1
    jne .ucancel
    call lg_idlg_apply
.ucancel:
    call lg_idlg_close
.uout:
    pop di
    pop si
    pop bx
    pop ax
    ret

lg_idlg_ondrag:
    push ax
    push bx
    mov bx, lg_idlg_btrec
    call os88ui_btndrag
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_idlg_apply - dispatch on the kind. A value this cannot make sense of is
; REFUSED SILENTLY and the old one kept, rather than being coerced to zero:
; a column of width 0 is invisible and a Goto to a reference that does not
; parse has nowhere to go, so doing nothing is the honest answer.
; -----------------------------------------------------------------------------
lg_idlg_apply:
    push ax
    push bx
    push cx
    push dx
    push si
    cmp byte [lg_idlg_kind], LG_ID_ROWH
    je .rowh
    mov si, lg_idlg_buf                ; the column width
    SHOUT lg_pnum_at
    jc .out                            ; not a number at all
    or ax, ax                          ; 81.73: ZERO HIDES IT, which is how
    jz .cwhide                         ; Excel hides a column and why this
    cmp ax, LG_CW_MINCH                ; COLUMN WIDTH IS IN CHARACTERS, which
    jb .out                            ; is Excel's own unit for it - the
    cmp ax, LG_CW_MAXCH                ; pixel width is a consequence, not the
    ja .out                            ; thing the user types
    ; THE SELECTED COLUMNS, each - Excel's Column Width (81.56). It set the
    ; one width the whole sheet had. The standard width is stored as 0, so a
    ; column set back to it costs a file nothing.
    mov cl, al
    cmp ax, [lg_defch]
    jne .cwset
    xor cl, cl
    jmp short .cwset
.cwhide:
    mov cl, LG_CW_HIDDEN               ; ...and a nonzero width typed over a
.cwset:                                ; selection that SPANS a hidden column
                                        ; unhides it, which is Excel's own way
                                        ; back and needs no second command:
                                        ; the loop below walks real columns
    mov ax, [lg_selcol]
    mov bx, [lg_selcol2]
    cmp ax, bx
    jbe .cwl
    xchg ax, bx
.cwl:
    SHOUT lg_colw_set
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
; step of 0.25 are both ordinary, and lg_pnum_at answers integers only -
; which is what the three numeric kinds above it want and this one does not.
.redraw:
    SHOUT lg_geom                       ; the cell size may have changed, so the
    mov si, [lg_ownwin]                ; visible row/column counts must be
    SHOUT lg_repaint                    ; recomputed before anything is drawn
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_idlg_close
; -----------------------------------------------------------------------------
lg_idlg_close:
    push ax
    push bx
    mov bx, [lg_idlg_win]
    or bx, bx
    jz .out
    mov word [lg_idlg_win], 0
    call OSAPI_WM_DESTROY               ; see lg_fdlg_close on why not CLOSE
.out:
    pop bx
    pop ax
    ret

section .text


lg_fdlg_open_r:
    jmp lg_fdlg_open
lg_fdlg_paint_r:
    jmp lg_fdlg_paint
lg_fdlg_click_r:
    jmp lg_fdlg_onclick
lg_fdlg_close_r:
    jmp lg_fdlg_close
lg_idlg_open_r:
    jmp lg_idlg_open
lg_idlg_paint_r:
    jmp lg_idlg_paint
lg_idlg_key_r:
    jmp lg_idlg_onkey
lg_idlg_click_r:
    jmp lg_idlg_onclick


; -----------------------------------------------------------------------------
; lg_pnum_at - read an unsigned decimal from the NUL string at SI.
; out: CF=0 and AX = the value; CF=1 if there was no digit at all or it ran
; past 65535. Leading blanks are skipped; anything after the digits is
; ignored, so '12 wide' reads as 12.
; -----------------------------------------------------------------------------
lg_pnum_at:
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

lg_dlg:
    push bx
    push si
    push di
    mov bx, si
    mov di, lg_ondlg
    mov si, lg_name
    call OSAPI_FILE_DLG
    pop di
    pop si
    pop bx
    ret

; -----------------------------------------------------------------------------
; lg_ondlg - the file dialog's completion proc (SPEC.md 38.6)
; in:  AL=mode, SI=our window ptr, DI=chosen name (ES=KERNEL_SEG); UI task,
;      gfx lock HELD, dialog already destroyed - we owe the repaint
; -----------------------------------------------------------------------------
lg_ondlg:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bl, al
    mov cx, si                       ; CX = our window ptr (SI about to move)
    mov si, di
    mov di, lg_name
    mov dx, LG_NAMEMAX               ; the count lives in DX - the loop body
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
    call lg_dowrite
    jmp short .draw
.load:
    call lg_doread
.draw:
    call lg_repaint
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_new - File > New: clear the sheet and the name, reselect A1
; -----------------------------------------------------------------------------
lg_new:
    push ax
    push cx
    push dx
    push si
    push di
    mov dx, si                       ; DX = window ptr, stashed
    mov si, lg_defname
    mov di, lg_name
    call lg_strcpy
    mov si, dx                       ; SI = window ptr, restored
    mov word [lg_ncells], 0
    mov word [lg_txtlen], 0
    SHOUT lg_colw_clear                ; ...and every column's width (81.56)
                                     ; into the next document and go on
                                     ; pointing at cells no longer there
                                     ; an OFFSET into the arena reset above,
                                     ; and would read new text through it
    mov word [lg_cursheet], 0
    mov cx, LG_SHEETS * 6            ; 6 words per sheet: sel/row/scl/scr,
                                      ; and 81.70's own fcl/frw
    mov di, lg_selsave
    xor ax, ax
.clrsave:
    mov [di], ax
    add di, 2
    loop .clrsave
    mov word [lg_selcol], 0
    mov word [lg_selrow], 0
    mov word [lg_scrollcol], 0
    mov word [lg_scrollrow], 0
    mov word [lg_freezecol], 0         ; 81.70: a new document is unfrozen,
    mov word [lg_freezerow], 0         ; like every other view setting here
    call lg_frzmark                    ; ...and the item says so again
    mov byte [lg_editing], 0
    mov word [lg_msg], 0
    call lg_repaint
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_switchsheet - in: AX = target sheet index (0..LG_SHEETS-1); saves the
; outgoing sheet's selection/scroll into its slot and restores the
; incoming sheet's own (all-zero the first time it's ever visited)
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; lg_sheetmark - point every Sheets item at its plain string, then the CURRENT
; one at its marked twin. Called at startup and after every switch, so the mark
; is derived from lg_cursheet rather than tracked alongside it.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; lg_frzmark - point Options' Freeze Panes item at whichever of its two
; labels the CURRENT state wants (81.70), derived rather than tracked - the
; same shape lg_sheetmark below uses for the Sheets menu's own tick, and the
; reason a sheet switch or a new document cannot leave "Unfreeze Panes"
; standing over a sheet that is not frozen.
; -----------------------------------------------------------------------------
lg_frzmark:
    push ax
    mov ax, [lg_freezecol]
    or ax, [lg_freezerow]
    jnz .on
    mov word [lg_i_options+8], lg_it_frz_off
    pop ax
    ret
.on:
    mov word [lg_i_options+8], lg_it_frz_on
    pop ax
    ret



; =============================================================================
; File I/O: SYLK write and read, over the sparse array directly
; =============================================================================

; -----------------------------------------------------------------------------
; lg_dowrite - write the sheet to [lg_name], format chosen by its extension
; (SPEC-free scope decision, this project's own: ".DIF" writes DIF,
; everything else writes SYLK, matching stage 1.0's default).
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; lg_sheets_used - out: AX = how many of the LG_SHEETS grids hold at least one
; cell, and BX = a bitmap of which. One walk of the array, not four.
; -----------------------------------------------------------------------------
section LG_MODSEC                      ; 82.16.9

; -----------------------------------------------------------------------------
; lg_dowrite - pick the writer from the file name's extension.
;
; AND SAY SO WHEN A SAVE CANNOT CARRY EVERYTHING. SYLK and DIF have no
; multi-sheet concept at all - SYLK has no notion of a sheet and DIF is one
; table - so a workbook with data on more than one of them loses the rest, and
; used to lose it in silence. It says so in the status bar now. BIFF is the one
; format here that CAN carry them, and does (81.10.5).
; -----------------------------------------------------------------------------
lgm_dowrite:
    push si
    push di
    mov si, lg_name
    mov di, lg_s_ext_csv
    SHOUT lg_nameends
    pop di
    pop si
    jc .csv
    push si
    push di
    mov si, lg_name
    mov di, lg_s_ext_txt
    SHOUT lg_nameends
    pop di
    pop si
    jc .txt
    call lg_dowrite_sylk
    jmp .warn
.csv:
    call lg_dowrite_csv
    jmp .warn
.txt:
    call lg_dowrite_txt
    jmp .warn
.warn:
    push ax
    push bx
    cmp word [lg_msg], lg_m_saved     ; only upgrade a plain success: a failed
    jne .warned                       ; write's "Err N" (or a truncated save's
                                      ; message) must not be replaced by a
                                      ; string that begins with "Saved"
.warned:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_wr_colw - SYLK's F;W<first> <last> <width> for every column of the
; current sheet that is not the standard width, at ES:DI (81.56)
; -----------------------------------------------------------------------------
lg_wr_colw:
    push ax
    push bx
    push si
    xor bx, bx
.l:
    mov ax, bx
    SHOUT lg_colwidth
    cmp ax, [lg_defch]
    je .n
    push ax
    mov si, lg_s_sylk_fw
    call lg_stgput
    mov ax, bx
    inc ax
    SHOUT lg_itoa
    mov si, lg_numbuf
    call lg_stgput
    mov al, ' '
    call lg_stgputb
    mov si, lg_numbuf
    call lg_stgput
    mov al, ' '
    call lg_stgputb
    pop ax
    SHOUT lg_itoa
    mov si, lg_numbuf
    call lg_stgput
    mov si, lg_s_crlf
    call lg_stgput
.n:
    inc bx
    cmp bx, 256
    jb .l
    pop si
    pop bx
    pop ax
    ret


; -----------------------------------------------------------------------------
; lg_dowrite_sylk - write the sheet to [lg_name] as SYLK. Walks the sorted
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
lg_dowrite_sylk:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [lg_stgseg]
    xor di, di
    mov si, lg_s_id
    call lg_stgput
    call lg_wr_colw                   ; 81.56: F;W for each column's width
                                       ; reader that is not this app can find
                                       ; the ranges too (81.29.1)

    mov byte [lg_trunc], 0
    mov word [lg_wrow], 0            ; reused here as the record index
.rec:
    mov bx, [lg_wrow]
    cmp bx, [lg_ncells]
    jae .footer
    cmp byte [lg_trunc], 0
    jne .footer
    mov ax, di
    add ax, 200                      ; worst case a LABEL's C line: the head
                                      ; ("C;X256;Y16384;K"), the quoted text
                                      ; with every embedded quote DOUBLED
                                      ; (2 + 2*LG_EDITMAX), CRLF, plus its
                                      ; F line ("F;X256;Y16384;F$0R;K\r\n");
                                      ; the ;E formula case is smaller
    cmp ax, LG_STAGE_MAX
    jbe .room
    mov byte [lg_trunc], 1
    jmp .footer
.room:
    mov ax, bx
    mov cx, LG_C_SZ
    mul cx
    mov si, ax                        ; SI = this record's offset in cellseg
    push es
    mov es, [lg_cellseg]
    mov ax, [es:si]
    SHOUT lg_unpackrow                 ; -> ax=real row, bx=this record's
                                       ; sheet (see the stage 2.0 comment
                                       ; above the cell record layout)
    cmp bx, [lg_cursheet]
    jne .recskip                      ; a save only ever writes the CURRENT
                                       ; sheet - the array may hold other
                                       ; sheets' records too, interleaved
    mov [lg_wrec_row], ax
    mov ax, [es:si+2]
    mov [lg_wrec_col], ax
    mov word [lg_wrec_foff], 0xFFFF   ; ...and this cell's formula, if it has
    test byte [es:si+4], 1            ; one: SYLK carries the EXPRESSION in a
    jz .noformula_w                   ; ;E field beside the cached ;K value,
    mov ax, [es:si+LG_C_FOFF]         ; which is what makes a saved sheet a
    mov [lg_wrec_foff], ax            ; spreadsheet rather than a table of
.noformula_w:                         ; numbers
    SHOUT lg_cellval_to_acc_si         ; bank the whole value: the row and
    push si                           ; column are formatted through lg_numbuf
    push di                           ; before it is wanted, so it cannot be
    mov si, lg_acc                    ; turned into text here
    mov di, lg_wrec_dval
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
    mov ax, [es:si+LG_C_VAL]
    mov [lg_wrec_val], ax
    mov al, [es:si+5]
    mov [lg_wrec_fmt], al
    mov al, [es:si+LG_C_AUX]
    mov [lg_wrec_aux], al
    mov al, [es:si+LG_C_TYPE]         ; stage 4.5: and the tag, because a LABEL
    mov [lg_wrec_type], al            ; goes out as a QUOTED K field rather
    mov ax, [es:si+LG_C_FOFF]         ; than as a number, and its characters
    mov [lg_wrec_toff], ax            ; come from the same arena a formula's do
    test byte [es:si+4], 1            ; A FORMULA THAT RETURNED TEXT keeps its
    jz .toffok1                          ; result in LG_C_VAL, because FOFF is
    cmp byte [es:si+LG_C_TYPE], LG_T_TEXT  ; already holding the formula's own
    jne .toffok1                         ; text (81.22.1) - so the label this
    mov ax, [es:si+LG_C_VAL]          ; writer emits is the RESULT, not the
    mov [lg_wrec_toff], ax            ; expression that produced it
.toffok1:
    pop es                            ; ES = stgseg again

    mov si, lg_s_c
    call lg_stgput
    mov ax, [lg_wrec_col]
    inc ax
    SHOUT lg_itoa
    mov si, lg_numbuf
    call lg_stgput
    mov si, lg_s_y
    call lg_stgput
    mov ax, [lg_wrec_row]
    inc ax
    SHOUT lg_itoa
    mov si, lg_numbuf
    call lg_stgput
    cmp word [lg_wrec_foff], 0xFFFF   ; ";E<expr>" comes BEFORE ";K", the
    je .noexpr                        ; order a real file from the period uses
    push si
    push di
    mov ax, [lg_wrec_col]             ; every relative offset is measured from
    mov [lg_rc_ccol], ax              ; the cell being written
    mov ax, [lg_wrec_row]
    mov [lg_rc_crow], ax
    push es
    mov es, [lg_txtseg]               ; copy the formula text out of the arena
    mov si, [lg_wrec_foff]            ; into DS, where the converter reads
    mov di, lg_rwsrc
    mov cx, LG_EDITMAX
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
    mov si, lg_rwsrc
    call lg_formula_to_r1c1
    pop di
    pop si
    mov si, lg_s_e
    call lg_stgput
    mov si, lg_rwdst                  ; ...with every ';' DOUBLED, as the K
.edbl:                                ; field's are: a string constant can
    mov al, [si]                      ; hold one, and a single one ends the
    or al, al                         ; field there, in a file that parses
    jz .noexpr
    inc si
    cmp al, ';'
    jne .edbl1
    call lg_stgputb
.edbl1:
    call lg_stgputb
    jmp short .edbl
.noexpr:
    mov si, lg_s_k
    call lg_stgput
    cmp byte [lg_wrec_type], LG_T_TEXT
    je .ktext
    cmp byte [lg_wrec_type], LG_T_BOOL ; a LOGICAL is QUOTED, Walden's rule:
    je .kbool                          ; "Logical values TRUE and FALSE must
                                       ; also be quoted" (81.51)
    cmp byte [lg_wrec_type], LG_T_ERR ; ...and an ERROR is its NAME, bare. The
    je .kerr                          ; leading '#' is what tells it from a
    push si                           ; SYLK's K field IS a decimal literal,
    push di                           ; so the full value goes out, not a
    mov si, lg_wrec_dval              ; truncation of it
    SHOUT fx_unpack_a
    mov di, lg_numbuf
    mov ax, 10
    SHOUT fx_ftoa
    pop di
    pop si
    mov si, lg_numbuf
    call lg_stgput
    jmp .kdone
.kerr:
    ; number, on both sides - no number starts with one, and SYLK has no type
    ; field to consult. Writing the value UNDERNEATH an error instead (a zero)
    ; is what this did, and it turned #DIV/0! into a perfectly ordinary 0 on
    ; the next load.
    push ax
    mov al, [lg_curaux]               ; lg_errname names the CURRENT cell, and
    push ax                           ; a save is not a paint - bank what the
    mov al, [lg_wrec_aux]             ; painter left there
    mov [lg_curaux], al
    SHOUT lg_errname                   ; -> lg_numbuf
    pop ax
    mov [lg_curaux], al
    pop ax
    mov si, lg_numbuf
    call lg_stgput
    jmp .kdone
.kbool:
    mov al, 34
    call lg_stgputb
    mov ax, [lg_wrec_dval]
    SHOUT lg_boolname
    mov si, lg_numbuf
    call lg_stgput
    mov al, 34
    call lg_stgputb
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
    call lg_stgputb
    mov si, [lg_wrec_toff]
.kt:
    push es
    mov es, [lg_txtseg]
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
    call lg_stgputb                   ; doubled: a quote or a semicolon
.kt1:
    call lg_stgputb
    jmp .kt
.ktend:
    mov al, 34
    call lg_stgputb
.kdone:
    mov si, lg_s_crlf
    call lg_stgput

    mov al, [lg_wrec_fmt]
    and al, (LG_FMT_ALIGN_MASK | LG_FMT_NUM_MASK)
    jz .noformat                      ; bold/underline alone don't get an F
                                       ; record - real SYLK has no code for
                                       ; either, see lg_parsefrec's comment
    mov si, lg_s_sylk_fx               ; "F;X"
    call lg_stgput
    mov ax, [lg_wrec_col]
    inc ax
    SHOUT lg_itoa
    mov si, lg_numbuf
    call lg_stgput
    mov si, lg_s_y
    call lg_stgput
    mov ax, [lg_wrec_row]
    inc ax
    SHOUT lg_itoa
    mov si, lg_numbuf
    call lg_stgput
    mov si, lg_s_sylk_ff                ; ";F"
    call lg_stgput
    mov bl, [lg_wrec_fmt]
    and bl, LG_FMT_NUM_MASK
    mov cl, LG_FMT_NUM_SHIFT
    shr bl, cl
    mov al, '$'
    cmp bl, LG_NF_CURRENCY               ; the only one of the three SYLK can
    je .c1cur                            ; say: c1 is 0/C/E/F/G/$/* and has no
    mov al, 'G'                          ; code for "text", so a TEXT cell
    mov ah, '0'                          ; writes as General and its LEFT
    jmp short .c1ok                      ; alignment in c2 carries what it can
.c1cur:
    mov ah, '2'                          ; ...and Currency says TWO places,
.c1ok:                                   ; which is what it actually shows
    call lg_stgputb                      ; c1
    mov al, ah
    call lg_stgputb                      ; n, the decimal count. It was always
                                         ; '0' under a comment saying "this
                                         ; app's values are whole numbers",
                                         ; true before 81.75's fixed point
    mov al, [lg_wrec_fmt]
    and al, LG_FMT_ALIGN_MASK
    mov cl, LG_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, LG_FMT_ALIGN_LEFT
    je .c2l
    cmp al, LG_FMT_ALIGN_CENTER
    je .c2c
    cmp al, LG_FMT_ALIGN_RIGHT
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
    call lg_stgputb                      ; c2
    mov si, lg_s_crlf
    call lg_stgput
.noformat:
    jmp .recnext
.recskip:
    pop es
.recnext:
    mov ax, [lg_wrow]
    inc ax
    mov [lg_wrow], ax
    jmp .rec
.footer:
    mov si, lg_s_end
    call lg_stgput
    mov [lg_stagelen], di

    mov ax, [lg_stgseg]
    mov es, ax
    xor bx, bx
    mov cx, [lg_stagelen]
    xor dx, dx
    mov si, lg_name
    call OSAPI_FILE_WRITE
    jc .werr
    mov word [lg_msg], lg_m_saved
    cmp byte [lg_trunc], 0            ; cells dropped for room must not be
    je .wdone                         ; reported as a plain success
    mov word [lg_msg], lg_m_trunc
    jmp .wdone
.werr:
    call lg_setferr
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
; lg_stgput - append DS:SI (NUL-terminated) to ES:DI, advancing DI. ES must
; already be the staging segment (the caller's job); no NUL is written to
; the destination, since the staging buffer is a raw byte stream whose
; total length is tracked separately, not a re-readable C string.
; -----------------------------------------------------------------------------
lg_stgput:
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
; lg_doread - read [lg_name], format chosen by its extension (see lg_dowrite)
; -----------------------------------------------------------------------------
lgm_doread:
    push si
    push di
    mov si, lg_name
    mov di, lg_s_ext_csv
    SHOUT lg_nameends
    pop di
    pop si
    jc .csv
    push si
    push di
    mov si, lg_name
    mov di, lg_s_ext_txt
    SHOUT lg_nameends
    pop di
    pop si
    jc .txt
    jmp lg_doread_sylk
.csv:
    jmp lg_doread_csv
.txt:
    jmp lg_doread_txt

; -----------------------------------------------------------------------------
; lg_doread_sylk - read [lg_name] as SYLK, replacing the sheet
; -----------------------------------------------------------------------------
lg_doread_sylk:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [lg_stgseg]
    xor bx, bx
    mov cx, LG_STAGE_MAX
    xor dx, dx
    mov si, lg_name
    call OSAPI_FILE_READ              ; out: DX:AX = bytes read, or CF=1
    jc .rerr

    mov word [lg_ncells], 0
    mov word [lg_txtlen], 0           ; "replacing the sheet" means the old
    mov word [lg_nbord], 0            ; document's arena text, borders and
    mov word [lg_nnote], 0            ; notes too, not just its cells
    SHOUT lg_colw_clear                ; ...and every column's width (81.56)
    mov cx, ax                        ; a file this small never exceeds 64KB
    xor si, si
    call lg_parseslk
    mov word [lg_msg], lg_m_loaded
    jmp .out
.rerr:
    call lg_setferr
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
; write walks the sheet's USED BOUNDING BOX (lg_difbbox), not the full
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
; lg_nameends - in: SI=name (NUL-terminated), DI=suffix (NUL-terminated);
; out: CF=1 if name ends with suffix (case-sensitive: 8.3 names arrive
; already uppercase from the kernel, and so do the suffixes this file
; compares against)
; -----------------------------------------------------------------------------
section .text
lg_nameends:
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
; lg_difbbox - the sheet's used bounding box (0,0)-(lg_bbcol,lg_bbrow),
; both 0 for an empty sheet. lg_bbrow is free (the array is row-sorted, so
; it is just the last record's row); lg_bbcol needs a scan.
; -----------------------------------------------------------------------------
section LG_MODSEC                      ; 82.16.9
lgm_difbbox:
    push ax
    push bx
    push cx
    push si
    push es
    mov word [lg_bbrow], 0
    mov word [lg_bbcol], 0
    cmp word [lg_ncells], 0
    je .out
    mov es, [lg_cellseg]
    xor cx, cx
.scan:
    cmp cx, [lg_ncells]
    jae .out
    mov ax, cx
    mov bx, LG_C_SZ
    mul bx
    mov si, ax                        ; si = this record's byte offset
    mov ax, [es:si]                   ; packed row/sheet (stage 2.0)
    SHOUT lg_unpackrow                 ; -> ax=real row, bx=sheet
    cmp bx, [lg_cursheet]
    jne .next                         ; a sheet's records aren't
                                       ; necessarily contiguous from index 0,
                                       ; so this scans every record rather
                                       ; than assuming the last one is ours
    cmp ax, [lg_bbrow]
    jbe .rowok
    mov [lg_bbrow], ax
.rowok:
    mov ax, [es:si+2]                 ; this record's col
    cmp ax, [lg_bbcol]
    jbe .next
    mov [lg_bbcol], ax
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
; lg_stgputb - append raw byte AL to ES:DI, advancing DI by 1. ES must
; already be the staging segment (the caller's job, as with lg_stgput).
; Used for a BIFF length-prefix byte (lg_biffw only writes whole words) and
; for a SYLK F record's single-character format codes.
; -----------------------------------------------------------------------------
lg_stgputb:
    mov [es:di], al
    inc di
    ret


section .text

; -----------------------------------------------------------------------------
; lg_biff_numfmt_from_id - in: AL = a real BIFF built-in number-format id;
; out: AL = this app's LG_FMT_NUM_* code (General for anything that isn't
; one of the four ids lg_biff_numfmt_tab itself ever writes - a custom
; FORMAT record's id, or a built-in this app doesn't have an equivalent
; for, both just degrade to General rather than guessed at)
; -----------------------------------------------------------------------------
section LG_MODSEC                      ; 82.16.9
; lg_cwbyte - AX = a width in characters from a file -> CL = what the width
; table keeps: clamped to what the Column Width dialog allows, and 0 for the
; standard width, so a file that states it costs the table nothing (81.56)
lg_cwbyte:
    cmp ax, LG_CW_MINCH
    jae .a
    mov ax, LG_CW_MINCH
.a:
    cmp ax, LG_CW_MAXCH
    jbe .b
    mov ax, LG_CW_MAXCH
.b:
    mov cl, al
    cmp ax, [lg_defch]
    jne .c
    xor cl, cl
.c:
    ret


; -----------------------------------------------------------------------------
; lg_parseslk - walk every line of a buffer, applying each 'C' record found
; in: SI = buffer start (offset in ES), CX = length; ES = the buffer's
; segment (the caller's job, e.g. lg_doread sets it to lg_stgseg)
; -----------------------------------------------------------------------------
lg_parseslk:
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
    call lg_parsecrec                ; in: SI=tokens start, BX=line end
    pop si
    jmp .advance
.notc:
    cmp byte [es:si], 'F'
    jne .advance
    push si
    add si, 2
    call lg_parsefrec                ; in: SI=tokens start, BX=line end
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
; lg_parsenrec - one 'NN' record: NN;N<name>;E<R1C1>[:<R1C1>]
; in: SI = start of tokens (right after "NN;"), BX = line end (exclusive);
; ES = the buffer's segment, same as lg_parseslk's caller set
;
; This is the other half of lg_wr_names, and it was missing. Sheet wrote these
; records so CHART could find a named range (82.15) and never read one itself,
; so a name survived being saved and did not survive being loaded - the file
; was right and the app forgot. Fields are taken in any order, like the 'C'
; record's, because a SYLK writer is not obliged to emit them in ours.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; lg_parsecrec - the fields of one 'C' record, order-independent
; in: SI = start of tokens (right after "C;"), BX = line end (exclusive);
; ES = the buffer's segment, same as lg_parseslk's caller set
; -----------------------------------------------------------------------------
lg_parsecrec:
    push ax
    push bx
    push si
    mov word [LG_TCOL], 0
    mov word [LG_TROW], 0
    mov word [LG_TVAL], 0
    mov byte [LG_THASE], 0
    mov byte [LG_TISTXT], 0
    mov byte [LG_TISERR], 0
    mov word [LG_TDVAL], 0
    mov word [LG_TDVAL+2], 0
    mov word [LG_TDVAL+4], 0
    mov word [LG_TDVAL+6], 0
    mov byte [LG_THAVE], 0
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
    SHOUT lg_pint
    mov [LG_TCOL], ax
    jmp .tok
.isy:
    inc si
    SHOUT lg_pint
    mov [LG_TROW], ax
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
    mov di, lg_rwsrc                  ; lg_rwsrc, NOT LG_TEXPR - the same
    mov cx, LG_EDITMAX                ; correction .kerr below already carries,
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
    mov byte [LG_TISTXT], 1
    mov byte [LG_THAVE], 1
    jmp .tok
.kerr:
    push di                           ; the name goes into lg_rwsrc, NOT into
    mov di, lg_rwsrc                  ; LG_TEXPR: a FORMULA cell writes both
    mov cx, LG_EDITMAX                ; ;E and ;K, ;E comes first, and parsing
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
    mov si, lg_rwsrc
    call lg_errcode                   ; -> AL, 0 for a spelling we do not know
    pop si
    mov [LG_TISERR], al
    mov byte [LG_THAVE], 1
    jmp .tok
.knum:
    call lg_esatof                    ; a full decimal, not an integer
    push ax
    push si
    push di
    mov si, lg_acc
    mov di, LG_TDVAL
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
    mov byte [LG_THAVE], 1
    jmp .tok
.ise:
    inc si
    push di                           ; the expression, copied out of the
    mov di, LG_TEXPR                  ; staging segment into DS so the R1C1
    mov cx, LG_EDITMAX                ; converter can read it
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
    mov byte [LG_THASE], 1
    jmp .tok
.apply:
    cmp byte [LG_THAVE], 0
    je .out
    mov ax, [LG_TCOL]
    cmp ax, 1
    jb .out
    cmp ax, LG_COLS
    ja .out
    mov cx, [LG_TROW]
    cmp cx, 1
    jb .out
    cmp cx, LG_ROWS
    ja .out
    dec ax
    dec cx
    mov bx, cx
    cmp byte [LG_THASE], 0            ; a ;E field wins over ;K: the value is
    je .notformula_c                  ; only the cached result of it, and
    push ax                           ; storing that instead would flatten the
    push bx                           ; formula exactly as this used to
    push si
    push di
    mov [lg_rc_ccol], ax
    mov [lg_rc_crow], bx
    mov si, LG_TEXPR
    call lg_formula_from_r1c1
    pop di
    pop si
    pop bx
    pop ax
    mov si, lg_rwdst                  ; AFTER the pops: setting SI before them
    SHOUT lg_setformula                ; put the saved value straight back over
                                      ; it, and lg_setformula stored whatever
                                      ; the staging pointer happened to be
    jmp .out
.notformula_c:
    cmp byte [LG_TISERR], 0
    je .noterr_c
    mov dl, [LG_TISERR]
    SHOUT lg_seterr
    jmp .out
.noterr_c:
    cmp byte [LG_TISTXT], 0
    je .plainval_c
    push si
    mov si, lg_rwsrc                  ; where .isk's quoted ;K now lands
    SHOUT lg_setlabel                 ; "TRUE" quoted is the LOGICAL: Walden
    pop si                            ; quotes both, so the spelling decides,
    jmp .out                          ; as it does when one is typed (81.51)
.plainval_c:
    push si
    push di
    mov si, LG_TDVAL
    mov di, lg_acc
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
    SHOUT lg_setvald
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_parsefrec - the fields of an "F" (formatting) record, stage 1.6's real
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
lg_parsefrec:
    push ax
    push bx
    push cx
    push si
    push di                           ; lg_findcell below is called for its
                                       ; side effect on DI, but lg_parseslk's
                                       ; caller keeps its own buffer-end in
                                       ; DI live across this whole call - it
                                       ; must come back unchanged
    mov word [LG_TCOL], 0
    mov word [LG_TROW], 0
    mov byte [LG_TALIGN], 0
    mov byte [LG_TNUMFMT], 0
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
    SHOUT lg_pint
    mov [LG_TCOL], ax
    jmp .tok
.isy:
    inc si
    SHOUT lg_pint
    mov [LG_TROW], ax
    jmp .tok
.isk:                                  ; ';K' is consumed and DROPPED - there is
    inc si                             ; no Comma format among 81.75's three,
    jmp .tok                           ; and Currency separates its own
                                       ; thousands anyway
.isw:                                  ; ;W<first> <last> <width>: column
    inc si                             ; widths, Walden's F-record field (7)
    SHOUT lg_pint                      ; (81.56). 1-based, spaces between
    push ax
    inc si
    SHOUT lg_pint
    push ax
    inc si
    SHOUT lg_pint
    call lg_cwbyte                     ; CL = what the table keeps
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
    SHOUT lg_colw_set
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
    call lg_sylk_numfmt_from_c1
    mov [LG_TNUMFMT], al
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
    call lg_sylk_align_from_c2
    mov [LG_TALIGN], al
    inc si
    jmp .tok
.apply:
    mov ax, [LG_TCOL]
    cmp ax, 1
    jb .out
    cmp ax, LG_COLS
    ja .out
    mov cx, [LG_TROW]
    cmp cx, 1
    jb .out
    cmp cx, LG_ROWS
    ja .out
    dec ax
    dec cx
    mov bx, cx
    SHOUT lg_findcell
    jnc .out                          ; no prior C record for this cell:
                                       ; nothing to attach the format to
    mov al, [LG_TNUMFMT]              ; ';K' (thousands separators) is READ and
                                       ; DROPPED: it used to promote a General
                                       ; cell to this app's Comma format, and
                                       ; there is no Comma format any more
                                       ; (81.75's three). Currency already
                                       ; separates its thousands, and turning
                                       ; a ';K' into one would put a '$' on a
                                       ; cell whose author never asked for a
                                       ; currency
    mov cl, LG_FMT_NUM_SHIFT
    shl al, cl
    mov ah, [LG_TALIGN]
    mov cl, LG_FMT_ALIGN_SHIFT
    shl ah, cl
    or al, ah
    push es
    mov es, [lg_cellseg]
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
; lg_sylk_numfmt_from_c1 - in: AL = an F record's c1 formatting-code char;
; out: AL = this app's LG_FMT_NUM_* code. Real SYLK's c1 codes are
; 0/C/E/F/G/$/* (default/continuous/scientific/fixed/general/currency/
; bargraph) - only '$' has an equivalent here; everything else (including
; the codes this app never writes, like scientific or bargraph) falls back
; to General, which is the honest answer since this app has no comparable
; format for them either.
; -----------------------------------------------------------------------------
lg_sylk_numfmt_from_c1:
    cmp al, '$'
    je .cur
    xor al, al
    ret
.cur:
    mov al, LG_NF_CURRENCY
    ret

; -----------------------------------------------------------------------------
; lg_sylk_align_from_c2 - in: AL = an F record's c2 alignment-code char
; ('0' default, 'C' center, 'G' general, 'L' left, 'R' right); out: AL =
; this app's LG_FMT_ALIGN_* code
; -----------------------------------------------------------------------------
lg_sylk_align_from_c2:
    cmp al, 'L'
    je .left
    cmp al, 'C'
    je .center
    cmp al, 'R'
    je .right
    xor al, al
    ret
.left:
    mov al, LG_FMT_ALIGN_LEFT
    ret
.center:
    mov al, LG_FMT_ALIGN_CENTER
    ret
.right:
    mov al, LG_FMT_ALIGN_RIGHT
    ret

; -----------------------------------------------------------------------------
; lg_pint - parse a signed decimal integer
; in: ES:SI=ptr, BX=limit (exclusive, an offset); also stops at NUL
; out: AX=value, SI=advanced; BX preserved; ES must be set by the caller
; -----------------------------------------------------------------------------
section .text
lg_pint:
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
; lg_setferr - build "Err N" from a FERR_* code and point lg_msg at it
; in: AX = FERR_* (CF was set on the API call that produced it)
; -----------------------------------------------------------------------------
section LG_MODSEC                      ; 82.16.9
lg_setferr:
    push di
    push si
    mov di, lg_errbuf
    mov si, lg_s_errpfx
    SHOUT lg_strcpy_to_di              ; DI advances past "Err " to the new NUL
    SHOUT lg_itoa                      ; AX (the FERR_* code) -> lg_numbuf;
                                       ; preserves DI
    mov si, lg_numbuf
    SHOUT lg_strcpy_to_di
    mov word [lg_msg], lg_errbuf
    pop si
    pop di
    ret

; =============================================================================
; Cell storage - a sorted array of (row, col, flags, format, value,
; formula_off, pass) records in the claimed lg_cellseg, searched with a
; binary search and kept sorted by shifting on insert/remove. 12 bytes/rec:
;   +0 row (word) - stage 2.0: PACKED, not a plain row. Bits 0-13 are the
;   real row (0..16383, LG_ROW_MASK); bits 14-15 are the sheet index
;   (0..LG_SHEETS-1). Sorting and searching a plain 16-bit compare on this
;   word therefore sorts every sheet's records into one contiguous run,
;   ordered first by sheet and then by row within it, with NO change to the
;   comparison logic itself - only the few places that construct or take
;   apart the word (lg_findcell packing it from [lg_cursheet], lg_unpackrow
;   splitting it back out for the SYLK/DIF/BIFF writers, which must skip
;   every sheet but the one being saved) know this isn't just a row.
;   +2 col (word)  +4 flags (byte)  +5 format (byte, the
;   LG_FMT_* bits, stage 1.6 - this byte was unused padding before)
;   +6 value (word)  +8 formula_off (word, 0xFFFF=none)  +10 pass (word)
; Only three routines (lg_findcell/lg_addcell/lg_removecell) know this
; layout and the shifting; everything else goes through lg_getcell2/
; lg_setvald/lg_clearcell.
; =============================================================================

; -----------------------------------------------------------------------------
; lg_unpackrow - in: AX = a cell record's packed row/sheet word; out: AX =
; the real row (0..16383), BX = the sheet index it belongs to
; -----------------------------------------------------------------------------
section .text
lg_unpackrow:
    push cx
    mov bx, ax
    mov cl, LG_ROW_BITS
    shr bx, cl
    and ax, LG_ROW_MASK
    pop cx
    ret

; -----------------------------------------------------------------------------
; lg_findcell - binary search for (col, row)
; in: AX=col, BX=row
; out: CF=1 found, DI=byte offset of the record
;      CF=0 not found, DI=byte offset where it would be inserted
; -----------------------------------------------------------------------------
lg_findcell:
    push ax
    push bx
    push cx
    push dx
    push si
    mov [lg_fcol], ax
    mov ax, [lg_cursheet]              ; the stored "row" word is really a
    mov cl, LG_ROW_BITS                ; packed (sheet<<LG_ROW_BITS | row) -
    shl ax, cl                         ; see the stage 2.0 comment above the
    or ax, bx                          ; cell record layout - so every
    mov [lg_frow], ax                  ; existing caller of this proc (all
                                        ; of them pass a plain 0..16383 row)
                                        ; keeps working unchanged, searching
                                        ; only the CURRENT sheet's records
    xor cx, cx                        ; CX = lo
    mov dx, [lg_ncells]                ; DX = hi
.loop:
    cmp cx, dx
    jae .notfound
    mov si, dx
    sub si, cx
    shr si, 1
    add si, cx                        ; SI = mid
    mov ax, si
    mov bx, LG_C_SZ
    push dx                           ; MUL clobbers DX (the high word of
    mul bx                            ; the product) - DX is also this
    pop dx                            ; loop's search bound, so it must
    mov di, ax                        ; survive every iteration, not just
                                       ; the one that happens to find a match
                                       ; on its first probe
    push es
    mov es, [lg_cellseg]
    mov ax, [es:di]                   ; candidate row
    mov bx, [es:di+2]                 ; candidate col
    pop es
    cmp ax, [lg_frow]
    jl .lower
    jg .higher
    cmp bx, [lg_fcol]
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
    mov bx, LG_C_SZ
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
; lg_addcell - find or create the record for (col, row)
; in: AX=col, BX=row
; out: CF=0, DI=byte offset of the record (existing or new, zeroed if new)
;      CF=1 the table is full - no new record could be created
; -----------------------------------------------------------------------------
lg_addcell:
    push ax
    push bx
    push cx
    push dx
    push si
    mov byte [lg_chartdirty], 1        ; whoever asked is about to write this
                                        ; record - lg_repaint's chart tail
                                        ; reads the byte instead of rescanning
                                        ; the column on every repaint
    call lg_findcell
    jc .found
    cmp word [lg_ncells], LG_CELL_CAP
    jae .full
    push di                            ; insertion offset, kept across the
                                        ; shift below
    mov ax, [lg_ncells]
    mov bx, LG_C_SZ
    mul bx                             ; AX = current end-of-array offset
    mov cx, ax
    sub cx, di                         ; CX = bytes to shift up (may be 0)
    push ds
    push es
    mov dx, [lg_cellseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, ax
    dec si
    mov di, si
    add di, LG_C_SZ
    std
    rep movsb
    cld
.noshift:
    pop es
    pop ds
    pop di                             ; DI = insertion offset, restored
    inc word [lg_ncells]
    push es
    mov es, [lg_cellseg]
    mov ax, [lg_frow]
    mov [es:di], ax
    mov ax, [lg_fcol]
    mov [es:di+2], ax
    mov byte [es:di+4], 0
    mov byte [es:di+5], 0
    mov byte [es:di+LG_C_TYPE], LG_T_NUM
    mov byte [es:di+LG_C_AUX], 0
    mov word [es:di+LG_C_VAL], 0      ; ALL EIGHT value bytes, not just the low
    mov word [es:di+LG_C_VAL+2], 0    ; word the integer model uses today. The
                                      ; record above it left here - harmless
                                      ; while only the low word is read, and a
                                      ; genuinely nasty surprise the moment the
                                      ; full double goes live
    mov word [es:di+LG_C_FOFF], 0xFFFF
    mov word [es:di+LG_C_PASS], 0
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
; lg_removecell - in: AX=col, BX=row; removes the record if present
; -----------------------------------------------------------------------------
lg_removecell:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov byte [lg_chartdirty], 1        ; lg_addcell's reason
    call lg_findcell
    jnc .out
    mov ax, [lg_ncells]
    mov bx, LG_C_SZ
    mul bx                             ; AX = end offset (before shrink)
    mov cx, ax
    sub cx, di
    sub cx, LG_C_SZ                    ; CX = bytes after this record
    push ds
    push es
    mov dx, [lg_cellseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, di
    add si, LG_C_SZ
    cld
    rep movsb
.noshift:
    pop es
    pop ds
    dec word [lg_ncells]
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
; Border... and its check-box dialog engine (the only lg_bdlg_* caller),
; Format > Cell Protection..., Options > Protect Document, and every number
; format past the four the format byte itself can name.
; =============================================================================

; -----------------------------------------------------------------------------
; lg_rowcol_op - Insert or delete a whole row or column on the CURRENT
; sheet only. in: AL = 0 insert row / 1 delete row / 2 insert column /
; 3 delete column; BX = the row or column index the operation pivots on
; (the selected cell's own row/col - Edit menu Insert.../Delete... has no
; other way to name one: a pivot is a single index, and a selection that
; spans several rows does not name one).
;
; The cell array is sorted by (sheet, row) then col (see the stage 2.0
; comment above lg_findcell) - shifting a COLUMN can reorder cells WITHIN
; a row relative to their row-mates, which the sorted array's own binary
; search depends on getting right. Rather than hand-roll an in-place
; resort, this stages every record's (sheet, row, col, flags, format,
; value, formula_off) into lg_stgseg with the shift already applied (or
; marked dropped, if inserting pushes a row/col past the edge of the
; grid, or if it sits exactly on a deleted row/col), empties the whole
; array, then re-inserts every staged record through lg_addcell (which
; already keeps the array sorted on every insert, so re-insertion order
; doesn't matter). Formula TEXT is untouched - only the cell record's own
; formula_off is carried over as-is, so an existing formula's cell
; references are NOT relatively adjusted by this operation (same scope
; reasoning as lg_docmd_fillright/lg_docmd_sortcol); its cached value is
; simply left to go stale, since lg_addcell's own default pass=0 on the
; fresh record forces a re-evaluation on the next paint regardless.
; -----------------------------------------------------------------------------

; =============================================================================
; lg_rowcol_reidx and its helpers - stage 2.x: after lg_rowcol_op has
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
; run it through lg_formula_reidx (a character scanner - not a full
; parse/reserialize - that recognizes exactly the same token shapes the
; real formula grammar does: an optional "SheetN!" prefix, then 1-7
; letters immediately followed by digits is a cell reference; anything
; inside a double-quoted string, per ALERT's own argument, is copied
; byte-for-byte and never scanned), and if the text actually changed,
; appends the new text to the pool (formula text is append-only - see
; lg_setformula's own header comment - so an edit here is "append new,
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

; lg_isletter_at - in: SI; out: CF=1 if [SI] is A-Z or a-z (SI untouched)
lg_isletter_at:
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

; lg_rw_emit - in: AL = one byte; appends it to lg_rwdst at [lg_rw_di],
; clipping (silently dropping the byte) rather than overrunning the
; buffer - same "clip, don't refuse" policy ALERT's own message copy uses.
;
; The clip is at LG_EDITMAX, NOT at lg_rwdst's own LG_RW_CAP size: every
; consumer of a rewritten formula assumes formula text fits the same
; LG_EDITMAX+1 = 64 bytes a typed formula does - lg_eval_cell's own
; per-recursion-level lg_fbuf slot, lg_beginedit's lg_editbuf,
; lg_docmd_copy's lg_clipbuf, and lg_drawbar's lg_tbuf+16 span are all
; exactly that size. A shift CAN legitimately grow text (row 9 -> 10,
; column Z -> AA), so the extra LG_RW_CAP slack is real working room; but
; letting the RESULT exceed LG_EDITMAX would overrun all four of those
; downstream buffers (lg_setformula/lg_txt_append only bound against the
; whole pool, not against 64), so growth past the cap is dropped here at
; the single choke point every rewriter shares rather than re-checked at
; each of the five call sites.
lg_rw_emit:
    push bx
    push di
    mov bx, [lg_rw_di]
    cmp bx, LG_EDITMAX
    jae .full
    mov di, lg_rwdst
    add di, bx
    mov [di], al
    inc bx
    mov [lg_rw_di], bx
.full:
    pop di
    pop bx
    ret




; -----------------------------------------------------------------------------
; lg_rw_emitref - put the literal "#REF!" in a rewritten formula, in place of
; a reference whose cell is gone. It reads the SAME string lg_errname prints,
; so the text a Delete writes is exactly the text lg_perrlit reads back.
; -----------------------------------------------------------------------------
lg_rw_emitref:
    push ax
    push bx
    mov bx, lg_s_err_ref
.l:
    mov al, [bx]
    or al, al
    jz .out
    call lg_rw_emit
    inc bx
    jmp .l
.out:
    pop bx
    pop ax
    ret

; lg_reidx_cellpart - in: SI at a cell reference's first letter (the
; caller has already confirmed one is there via lg_isletter_at), DL = 1
; adjust this reference (it is known to name the sheet being shifted) or
; 0 leave it exactly as written; out: SI advanced past the whole
; reference (letters and, if any followed, digits) and the reference (or
; the bare word, if a letter run here turns out NOT to be followed by a
; digit - a function name, not a cell reference) emitted to lg_rwdst
; either verbatim or adjusted

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
; Both directions reuse lg_formula_reidx's scanner shape: walk the text, copy
; everything that is not a reference verbatim, and transform the references.
; A quoted string is passed through untouched, as it is there.
;
; THE CROSS-SHEET PREFIX IS AN EXTENSION. SYLK has no notion of a second sheet
; - it is a single-grid format - so "Sheet2!" is written through verbatim. It
; round-trips within this app and means nothing to anything else, which is the
; honest position: the alternative is silently dropping the reference.
; =============================================================================

; lg_emit_num - AX as signed decimal, into lg_rwdst via lg_rw_emit
section LG_MODSEC                      ; 82.16.9
lg_emit_num:
    push ax
    push bx
    SHOUT lg_itoa
    mov bx, lg_numbuf
.e:
    mov al, [bx]
    or al, al
    jz .o
    SHOUT lg_rw_emit
    inc bx
    jmp .e
.o:
    pop bx
    pop ax
    ret

; lg_emit_rc - one R or C part. in: AL = 'R' or 'C', BX = the value,
; CL = 0 relative (bracketed offset, omitted entirely when zero) or 1 absolute
; (a bare 1-based index).
lg_emit_rc:
    push ax
    push bx
    SHOUT lg_rw_emit                   ; the letter itself
    or cl, cl
    jnz .abs
    or bx, bx
    jz .out                           ; a zero offset is written as nothing:
    mov al, '['                       ; "RC" means "this row, this column"
    SHOUT lg_rw_emit
    mov ax, bx
    call lg_emit_num
    mov al, ']'
    SHOUT lg_rw_emit
    jmp .out
.abs:
    mov ax, bx
    inc ax                            ; absolute parts are 1-based
    call lg_emit_num
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_formula_to_r1c1 - in: SI = A1-form formula text (no leading '='),
; [lg_rc_ccol]/[lg_rc_crow] = the cell that owns it.
; out: lg_rwdst holds the R1C1 form, [lg_rw_di] its length.
; -----------------------------------------------------------------------------
lg_formula_to_r1c1:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [lg_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    SHOUT lg_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    SHOUT lg_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    SHOUT lg_isletter_at
    jnc .literal
    mov [lg_rw_ostart], si
    SHOUT lg_psheetpfx
    jnc .noxsheet
    mov si, [lg_rw_ostart]            ; the prefix goes through verbatim
    mov bx, 7
.pfx:
    mov al, [si]
    SHOUT lg_rw_emit
    inc si
    dec bx
    jnz .pfx
    mov [lg_rw_ostart], si
.noxsheet:
    call lg_reidx_cellpart_probe      ; is this really a reference?
    jc .isref
    mov si, [lg_rw_ostart]            ; no: a function name or a bare word
.word:
    SHOUT lg_isletter_at
    jnc .loop
    mov al, [si]
    SHOUT lg_rw_emit
    inc si
    jmp .word
.isref:
    mov al, 'R'                       ; ...the row part
    mov bx, [lg_rw_refrow]
    mov cl, [lg_rw_absr]
    or cl, cl
    jnz .rowabs
    sub bx, [lg_rc_crow]              ; relative: an offset from this cell
.rowabs:
    call lg_emit_rc
    mov al, 'C'                       ; ...and the column part
    mov bx, [lg_rw_refcol]
    mov cl, [lg_rw_absc]
    or cl, cl
    jnz .colabs
    sub bx, [lg_rc_ccol]
.colabs:
    call lg_emit_rc
    jmp .loop
.literal:
    mov al, [si]
    SHOUT lg_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [lg_rw_di]
    mov byte [lg_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; lg_reidx_cellpart_probe - SI at a possible reference. Fills lg_rw_refcol/
; refrow/absc/absr and returns CF=1 with SI past it. CF=0 means the letters
; were NOT followed by a row number (a function name, say) - SI is left where
; the scan stopped, and the caller rewinds it from lg_rw_ostart, which is the
; same contract lg_reidx_cellpart works to.
lg_reidx_cellpart_probe:
    push ax
    push cx
    push di
    mov di, lg_ident
    xor cx, cx
    mov byte [lg_rw_absc], 0
    mov byte [lg_rw_absr], 0
    cmp byte [si], '$'
    jne .nc
    mov byte [lg_rw_absc], 1
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
    mov byte [lg_rw_absr], 1
    inc si
.nr:
    mov al, [si]
    cmp al, '0'
    jb .no
    cmp al, '9'
    ja .no
    SHOUT lg_identcol
    mov [lg_rw_refcol], ax
    push bx
    mov bx, si
    add bx, LG_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    SHOUT lg_pint
    pop es
    pop bx
    dec ax
    mov [lg_rw_refrow], ax
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
; lg_formula_from_r1c1 - in: SI = R1C1-form text, [lg_rc_ccol]/[lg_rc_crow] =
; the cell that owns it. out: lg_rwdst holds the A1 form, NUL-terminated.
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
lg_formula_from_r1c1:
    push ax
    push bx
    push cx
    push dx
    push si
    mov dx, si                        ; DX = the text's start, for the check
    mov word [lg_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    SHOUT lg_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    SHOUT lg_rw_emit
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
    call lg_rcident
    jc .literal
.rstart:
    mov [lg_rw_ostart], si
    inc si
    call lg_read_rc                   ; -> BX = value, CL = 1 if absolute
    jc .notref
    mov [lg_rw_refrow], bx
    mov [lg_rw_absr], cl
    mov al, [si]
    and al, 0xDF
    cmp al, 'C'
    jne .notref
    inc si
    call lg_read_rc
    jc .notref
    mov al, [si]                      ; ...and ending one: RCOST is a name,
    cmp al, '('                       ; RC( a function
    je .notref
    call lg_rcident
    jc .notref
    mov [lg_rw_refcol], bx
    mov [lg_rw_absc], cl
    ; --- emit it as A1 ---
    cmp byte [lg_rw_absc], 0
    je .colrel
    mov al, '$'
    SHOUT lg_rw_emit
    jmp .colemit
.colrel:
    mov ax, [lg_rw_refcol]
    add ax, [lg_rc_ccol]
    mov [lg_rw_refcol], ax
.colemit:
    mov ax, [lg_rw_refcol]
    SHOUT lg_colname
    mov bx, lg_colbuf
.cl:
    mov al, [bx]
    or al, al
    jz .rowpart
    SHOUT lg_rw_emit
    inc bx
    jmp .cl
.rowpart:
    cmp byte [lg_rw_absr], 0
    je .rowrel
    mov al, '$'
    SHOUT lg_rw_emit
    jmp .rowemit
.rowrel:
    mov ax, [lg_rw_refrow]
    add ax, [lg_rc_crow]
    mov [lg_rw_refrow], ax
.rowemit:
    mov ax, [lg_rw_refrow]
    inc ax                            ; back to the 1-based display row
    call lg_emit_num
    jmp .loop
.notref:
    mov si, [lg_rw_ostart]            ; not a reference after all: the 'R' and
    mov al, [si]                      ; whatever follows go through as text
    SHOUT lg_rw_emit
    inc si
    jmp .loop
.literal:
    mov al, [si]
    SHOUT lg_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [lg_rw_di]
    mov byte [lg_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; lg_rcident - CF=1 when AL can be part of a word: a letter, a digit, '.' or
; '_' (81.62)
lg_rcident:
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

; lg_read_rc - SI just past an 'R' or 'C'. out: BX = the value (a signed offset
; when relative, a 0-based index when absolute), CL = 1 if absolute, SI
; advanced. CF=1 if what follows is neither a bracket nor a digit.
lg_read_rc:
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
    call lg_read_int
    dec bx                            ; absolute parts are 1-based on the wire
    jmp .ok
.rel:
    inc si
    call lg_read_int                  ; the bracketed offset, sign and all
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

; lg_read_int - a signed decimal at SI into BX; SI advanced. Used only by the
; R1C1 reader, where the number is known to be short.
lg_read_int:
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

; lg_formula_reidx - in: SI = source formula text (DS-resident, NUL-
; terminated, no leading '='); [lg_rw_op]/[lg_rw_pivot]/[lg_rw_tsheet]/
; [lg_rw_home] already set by the caller (lg_rowcol_reidx). Out:
; lg_rwdst holds the rewritten, NUL-terminated text, [lg_rw_di] = its
; length. See the section header comment above for the token rules.
section .text

; lg_rowcol_reidx - the driver: walk every cell, and for each formula
; cell, run its text through lg_formula_reidx and repoint its
; formula_off if the text actually changed. [lg_rc_op]/[lg_rc_idx] are
; still exactly what lg_rowcol_op's caller passed (untouched since
; entry); [lg_cursheet] has just been restored to the sheet this whole
; operation acted on.

; =============================================================================
; Copy/Paste relative-reference adjustment (stage 2.x, per direct user
; report). lg_docmd_copy already remembers WHERE it copied from
; (lg_clip_col/lg_clip_row/lg_clip_valid, set below); lg_docmd_paste uses
; that plus its own destination (lg_selcol/lg_selrow) to compute a
; constant (col, row) delta and runs the copied formula's text through
; lg_formula_copyshift before handing it to lg_commit - the same "copy a
; formula, keep the cell it landed in" behavior every other spreadsheet's
; own default (non-absolute) reference already has.
;
; This reuses lg_rowcol_reidx's own low-level pieces (lg_isletter_at,
; lg_rw_emit, lg_rwsrc/lg_rwdst/lg_rw_di, lg_psheetpfx/lg_identcol/
; lg_colname/lg_pint/lg_itoa) but is otherwise a SEPARATE top-level scan,
; not a generalization of lg_formula_reidx: an Insert/Delete Row/Column
; shift only ever touches ONE axis (row XOR column) and only for
; references at or past a pivot; a copy/paste shift touches BOTH axes
; unconditionally by a fixed delta (pasting diagonally moves a reference
; diagonally too) and has no pivot or target-sheet concept at all - every
; reference in the formula, bare or "SheetN!"-prefixed alike, shifts by
; the exact same delta, matching real Excel's own relative-reference
; behavor when copying between sheets (the sheet name itself never
; changes, only the cell part does).
;
; lg_clip_valid is this instance's own memory of "the last thing *I*
; copied, and from where" - the real clipboard (OSAPI_CLIP_PUT/GET) is
; plain bytes with no provenance, so if something else overwrites it
; between the Copy and the Paste (a different app, or a different Sheet
; instance), a resulting paste here would only misfire if that unrelated
; text ALSO happens to start with '=' - accepted as a known, low-
; probability edge case rather than something worth adding real
; clipboard versioning for.
; =============================================================================

; lg_copy_shift - in: AX = a reference's original 0-based index, BX =
; the signed delta (lg_cp_coldelta or lg_cp_rowdelta), CX = that axis's
; cap (LG_COLS or LG_ROWS); out: AX = adjusted index, clamped to
; [0, CX-1] rather than allowed to go negative or off the grid - this
; project has no error-value concept anywhere (RK's unsupported subtype
; and division by zero both degrade the same "closest sane fallback,
; never crash" way)
lg_copy_shift:
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

; lg_copy_cellpart - in: SI at a cell reference's first letter (the
; caller has already confirmed one is there via lg_isletter_at); out: SI
; advanced past the whole reference (letters and, if any followed,
; digits), and the reference emitted to lg_rwdst with BOTH its column
; and row shifted by [lg_cp_coldelta]/[lg_cp_rowdelta] - or, if this
; letter run turns out not to be followed by a digit (a function name,
; not a cell reference), the bare word emitted verbatim instead
lg_copy_cellpart:
    push ax
    push bx
    push cx
    push di
    mov [lg_cp_ostart], si
    mov byte [lg_cp_absc], 0           ; stage 3.0e: see lg_rw_absc
    mov byte [lg_cp_absr], 0
    mov byte [lg_cp_dead], 0           ; ...and stage 4.5: whether the shift
    cmp byte [si], '$'                 ; took this reference off the sheet.
    jne .nocoldollar                   ; The DECISION is deferred to the emit
    mov byte [lg_cp_absc], 1           ; below, because SI still has to be
    inc si                             ; advanced past the whole reference
                                       ; either way
.nocoldollar:
    mov di, lg_ident
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
    mov [lg_cp_lettersend], si
    cmp byte [si], '$'
    jne .norowdollar
    mov byte [lg_cp_absr], 1
    inc si
.norowdollar:
    mov al, [si]
    cmp al, '0'
    jb .notref
    cmp al, '9'
    ja .notref
    call lg_identcol                   ; ax = 0-based col (from lg_ident)
    cmp byte [lg_cp_absc], 0           ; a pinned column does not follow the
    jne .colpinned                     ; paste's own displacement
    mov bx, [lg_cp_coldelta]
    mov cx, LG_COLS
    call lg_copy_shift
    jnc .colpinned
    mov byte [lg_cp_dead], 1
.colpinned:
    mov [lg_cp_refcol], ax
    mov bx, si
    add bx, LG_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call lg_pint                       ; ax = 1-based row text; si advances
    pop es
    dec ax                             ; ax = 0-based row
    cmp byte [lg_cp_absr], 0
    jne .rowpinned
    mov bx, [lg_cp_rowdelta]
    mov cx, LG_ROWS
    call lg_copy_shift
    jnc .rowpinned
    mov byte [lg_cp_dead], 1
.rowpinned:
    mov [lg_cp_refrow], ax
    mov [lg_cp_refend], si
    cmp byte [lg_cp_dead], 0
    je .cpalive
    call lg_rw_emitref
    jmp .out
.cpalive:
    cmp byte [lg_cp_absc], 0           ; both halves are REGENERATED below, so
    je .cpnocoldollar                  ; both markers have to be re-emitted
    mov al, '$'
    call lg_rw_emit
.cpnocoldollar:
    mov ax, [lg_cp_refcol]
    call lg_colname
    mov bx, lg_colbuf
.colemit:
    mov al, [bx]
    or al, al
    jz .rowdigits
    call lg_rw_emit
    inc bx
    jmp .colemit
.rowdigits:
    cmp byte [lg_cp_absr], 0
    je .cpnorowdollar
    mov al, '$'
    call lg_rw_emit
.cpnorowdollar:
    mov ax, [lg_cp_refrow]
    inc ax                             ; back to 1-based display text
    call lg_itoa
    mov bx, lg_numbuf
.rowdigemit:
    mov al, [bx]
    or al, al
    jz .out
    call lg_rw_emit
    inc bx
    jmp .rowdigemit
.notref:
    mov bx, [lg_cp_ostart]
.wcopy:
    cmp bx, si
    jae .out
    mov al, [bx]
    call lg_rw_emit
    inc bx
    jmp .wcopy
.out:
    pop di
    pop cx
    pop bx
    pop ax
    ret

; lg_formula_copyshift - in: SI = source formula text (DS-resident, NUL-
; terminated, no leading '='); [lg_cp_coldelta]/[lg_cp_rowdelta] already
; set by the caller (lg_docmd_paste). Out: lg_rwdst holds the shifted,
; NUL-terminated text, [lg_rw_di] = its length. Same token-recognition
; and quoted-string-is-verbatim rules as lg_formula_reidx (see that
; proc's own header comment for why a character scan, not a re-parse, is
; both sufficient and safe here).
lg_formula_copyshift:
    push ax
    push bx
    push si
    mov word [lg_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    call lg_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    call lg_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    call lg_isletter_at
    jnc .literal
    mov [lg_cp_ostart], si
    call lg_psheetpfx
    jnc .noxsheet
    call lg_isletter_at
    jc .pfxisref
    mov si, [lg_cp_ostart]             ; "SheetN!" not actually followed by
    mov bx, 7                          ; a reference: emit the 7 prefix
.pfxverb:                              ; bytes VERBATIM rather than letting
    mov al, [si]                       ; them be silently deleted (see the
    call lg_rw_emit                    ; matching fix in lg_formula_reidx)
    inc si
    dec bx
    jnz .pfxverb
    jmp .loop
.pfxisref:
    mov si, [lg_cp_ostart]
    mov bx, 7                          ; "SHEET" + one digit + "!" always
.copypfx:
    mov al, [si]
    call lg_rw_emit
    inc si
    dec bx
    jnz .copypfx
    call lg_copy_cellpart              ; the sheet name itself never
    jmp .loop                          ; shifts - only the cell part does
.noxsheet:
    call lg_copy_cellpart
    jmp .loop
.literal:
    mov al, [si]
    call lg_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [lg_rw_di]
    mov byte [lg_rwdst + bx], 0
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_getcell2 - in: AX=col, BX=row; out: CF=1 occupied + DX=value, CF=0 empty.
; Also always sets [lg_curfmt] to the cell's format byte (0 if empty) -
; a side channel the drawing code reads, since none of this proc's other
; callers (SYLK/DIF/BIFF export, range folding) care about it.
; -----------------------------------------------------------------------------
lg_getcell2:
    push ax
    push bx
    push di
    call lg_findcell
    jnc .empty
    push es
    mov es, [lg_cellseg]
    mov al, [es:di+5]
    mov [lg_curfmt], al
    mov al, [es:di+LG_C_TYPE]         ; stage 4.5: and the tag, so a caller can
    mov [lg_curtype], al              ; tell a label from the zero it would
    mov al, [es:di+LG_C_AUX]          ; the error code travels with the tag,
    mov [lg_curaux], al               ; so the painter can name it
    cmp byte [lg_curtype], LG_T_TEXT   ; ...and a LABEL loads its characters
    jne .nottext                       ; into lg_sacc, so a formula that names
    push ax                            ; one has something to work WITH rather
    call lg_txtslot                    ; than the zero underneath it (81.22)
    call lg_str_load
    pop ax
.nottext:
    mov ax, [es:di+LG_C_FOFF]         ; otherwise read as this cell's value
    mov [lg_curtoff], ax
    test byte [es:di+4], 1            ; HASFORMULA. An ERROR tag raises
    jz .plain                         ; lg_evalerr only AFTER this split
                                      ; (81.20): a formula cell's stored tag
                                      ; may predate the fix that unbreaks it,
                                      ; and raising from it here survived the
                                      ; clean re-evaluation below and wrote
                                      ; the old error back for the whole pass
    pop es
    ; BANK THIS CELL'S OWN IDENTITY ACROSS THE EVALUATION. lg_eval_cell
    ; recurses back through lg_getcell2 for every cell the formula names, and
    ; each of those overwrites every one of these - so a formula rendered with
    ; the FORMAT of the last cell it referenced, and, worse, with that cell's
    ; TYPE and text offset: `=A2+0` where A2 holds a label drew the label.
    ; The cell showed something that was not its value, and said nothing.
    ; Only the FORMAT is banked here - the one thing an evaluation cannot
    ; change. The type, the error code and the text offset all come back from
    ; lg_eval_cell's own writeback, because a text result's offset is its
    ; RESULT slot and not the formula text the banked copy would restore
    ; (81.22.1).
    mov al, [lg_curfmt]
    mov bx, [lg_curtoff]
    push ax
    push bx
    call lg_eval_cell                 ; leaves the full result in lg_acc, and
    pop bx                            ; DX as its truncated form
    pop ax
    mov [lg_curfmt], al
    cmp byte [lg_curtype], LG_T_TEXT   ; A TEXT RESULT KEEPS THE OFFSET THE
    je .offkept                        ; WRITEBACK PUBLISHED: it is the RESULT
    mov [lg_curtoff], bx               ; slot, and the banked one is the
.offkept:                              ; formula's own source text, which the
                                       ; cell would then draw instead (81.22.1).
                                       ; lg_curtype/lg_curaux are not banked at
                                       ; all: the evaluation decides them and
                                       ; publishes them at its writeback
    cmp byte [lg_curtype], LG_T_ERR   ; ...and an ERROR spreads: anything built
    jne .fresh                        ; on a broken cell is broken too - raised
    mov al, [lg_curaux]               ; from what the writeback (or a cache
    mov [lg_evalerr], al              ; hit's current tag) JUST published,
.fresh:                               ; never from the pre-evaluation one
    stc
    jmp .out
.plain:
    cmp byte [lg_curtype], LG_T_ERR   ; a formula-less error cell (lg_seterr,
    jne .pnum                         ; the BIFF reader) has no evaluation to
    mov al, [lg_curaux]               ; republish its tag, so the stored one
    mov [lg_evalerr], al              ; is current and spreads as before
.pnum:
    push si                           ; stage 4.0: the stored value is a full
    push cx                           ; double, so it comes out into lg_acc.
    mov si, lg_acc                    ; DX stays the truncated integer for the
    mov cx, 4                         ; callers that still want one.
.pcopy:
    mov ax, [es:di+LG_C_VAL]
    mov [si], ax
    add di, 2
    add si, 2
    dec cx
    jnz .pcopy
    pop cx
    pop si
    pop es
    call lg_acc_toint
    mov dx, ax
    stc
    jmp .out
.empty:
    mov byte [lg_curfmt], 0
    mov byte [lg_curtype], LG_T_BLANK
    push ax                           ; an empty cell is a zero value, and
    xor ax, ax                        ; lg_acc must say so rather than keeping
    call lg_acc_int                   ; whatever the last cell left there
    pop ax
    clc
.out:
    pop di
    pop bx
    pop ax
    ret

; =============================================================================
; The value accumulator (stage 4.0). The evaluator's working value is a double
; in lg_acc, not an integer in AX - a double does not fit a register, so it
; lives in memory and the machine stack carries a binary operator's left
; operand across the parse of its right.
;
; The INTEGER entry points below are kept as converting wrappers rather than
; being deleted. Roughly forty callers pass values as words - file readers,
; the chart scan, sort, fill, the macro engine - and converting them all in
; one change would have made a fault impossible to localise. They convert at
; the boundary and are correct for any value an integer can hold.
; =============================================================================

; lg_acc_store - pack the fp A accumulator into lg_acc
lg_acc_store:
    push di
    mov di, lg_acc
    call fx_pack_a
    pop di
    ret

; lg_acc_load_a - unpack lg_acc into fp A
lg_acc_load_a:
    push si
    mov si, lg_acc
    call fx_unpack_a
    pop si
    ret

; lg_acc_load_b - unpack lg_acc into fp B
lg_acc_load_b:
    push si
    mov si, lg_acc
    call fx_unpack_b
    pop si
    ret

; lg_acc_int - AX (signed) -> lg_acc
lg_acc_int:
    call fx_i2a
    call lg_acc_store
    ret

; lg_acc_toint - lg_acc -> AX (signed, truncated); CF=1 if it did not fit
lg_acc_toint:
    call lg_acc_load_a
    call fx_a2i
    ret

; lg_vpush - bank lg_acc on the machine stack. CLOBBERS AX (the return address
; goes through it), which is safe because the evaluator's value now lives in
; lg_acc rather than in a register.
lg_vpush:
    ; STKBALANCE-NET: +2 - 81.75: TWO WORDS now, not four; banks lg_acc on the CALLER's stack for a binary operator; lg_binop_pre takes it off
    pop ax
    push word [lg_acc+2]
    push word [lg_acc]
    push ax
    ret

; lg_binop_pre - recover a banked left operand into fp A and load lg_acc, the
; right operand, into fp B. Pairs with exactly one lg_vpush.
lg_binop_pre:
    ; STKBALANCE-NET: -2 - the other half of lg_vpush - one call each, always paired
    pop ax
    pop word [lg_lhs]
    pop word [lg_lhs+2]
    push ax
; lg_binop_ld - fp A = the banked left operand, fp B = lg_acc: lg_binop_pre's
; half that touches no stack, which CHART.OVL's copy calls back to (81.62)
lg_binop_ld:
    push si
    mov si, lg_lhs
    call fx_unpack_a
    pop si
    call lg_acc_load_b
    ret

; -----------------------------------------------------------------------------
; lg_setvald - in: AX=col, BX=row; the value is lg_acc. Out: CF=1 when
; refused (cell table full) - the cell keeps what it had.
; -----------------------------------------------------------------------------
lg_setvald:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    call lg_addcell
    jc .dfull
    push es
    mov es, [lg_cellseg]
    mov byte [es:di+4], 0             ; a plain value has no formula
    mov byte [es:di+LG_C_TYPE], LG_T_NUM
    mov si, lg_acc                    ; all EIGHT bytes of it
    mov cx, 4
.dcopy:
    mov ax, [si]
    mov [es:di+LG_C_VAL], ax
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
; lg_seterr - in: AX=col, BX=row, DL=an LG_ERR_* code (1..7). The cell
; becomes an ERROR VALUE with a zero underneath it, which is exactly what a
; file carrying one means. Used by the file readers, and (81.61) by Fill
; Right/Down, which is why it is RESIDENT: Fill turned an error constant into
; 0, and the readers reach it through a vector now.
; -----------------------------------------------------------------------------
section .text
lg_seterr:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    mov cl, dl                        ; the code, across lg_setvald
    push cx
    push ax                           ; the column, across lg_acc_int
    xor ax, ax
    call lg_acc_int
    pop ax
    call lg_setvald                    ; creates the record, tagged LG_T_NUM
    pop cx
    jc .out                            ; refused: CF=1 says so (81.61)
    call lg_findcell                   ; ...and now say what it really is
    jnc .out
    push es
    mov es, [lg_cellseg]
    mov byte [es:di+LG_C_TYPE], LG_T_ERR
    mov [es:di+LG_C_AUX], cl
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
; lg_fsep - CF=1 when AL is a byte a space beside it can never matter to: an
; operator, a parenthesis, the argument comma, the range colon, or 0 (the
; start or the end of the text). For lg_setformula's space squeeze.
; -----------------------------------------------------------------------------
lg_fsep:
    push bx
    mov bx, lg_fseps
.lp:
    cmp al, [bx]
    je .yes
    inc bx
    cmp bx, lg_fseps_end
    jb .lp
    pop bx
    clc
    ret
.yes:
    pop bx
    stc
    ret

lg_fseps:     db 0, '+-*/^&=<>(),:'
lg_fseps_end:

; -----------------------------------------------------------------------------
; THE LOGICAL VALUE (81.51). A logical is the double 1.0 or 0.0 tagged
; LG_T_BOOL, so everything that only wants a number - arithmetic, IF's test,
; a chart - reads it unchanged, and only what SHOWS a value, STORES one or
; FOLDS a reference has to know it is there.
;
; lg_boolname - AX nonzero -> "TRUE", else "FALSE", into lg_numbuf. Bit 15 is
; ignored, so the top word of either double does as well as an integer.
; -----------------------------------------------------------------------------
lg_boolname:
    push ax
    push si
    push di
    mov si, lg_f_true
    and ax, 0x7FFF
    jnz .t
    mov si, lg_f_false
.t:
    mov di, lg_numbuf
    call lg_strcpy
    pop di
    pop si
    pop ax
    ret

; lg_boolword - CF=1 when the text at DS:SI is TRUE or FALSE, in any case and
; with nothing either side of it, and AX = 1 or 0 then.
lg_boolword:
    push di
    mov di, lg_f_true
    call lg_wordeq
    mov ax, 1                         ; MOV leaves CF as lg_wordeq set it
    jc .out
    mov di, lg_f_false
    call lg_wordeq
    mov ax, 0
.out:
    pop di
    ret

; lg_errword - CF=1 when the text at DS:SI is one of the seven error values,
; in any case and with nothing either side, and AX = its ERROR.TYPE then
lg_errword:
    push bx
    push di
    xor bx, bx
.l:
    cmp bx, 14
    jae .no
    mov di, [lg_errtab + bx]
    call lg_wordeq
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

lg_wordeq:                            ; DS:SI in any case against DS:DI, upper
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

; lg_setbool - in: AX=col, BX=row, DL = the value (nonzero is TRUE). A logical
; CONSTANT: lg_setvald's record, retagged - lg_seterr's shape. Out: CF=1 when
; refused (the cell table is full) and the cell keeps what it had.
lg_setbool:
    push ax
    push di
    push es
    push ax
    xor ax, ax
    or dl, dl
    jz .v
    inc ax
.v:
    call lg_acc_int
    pop ax
    call lg_setvald
    jc .out
    call lg_findcell
    mov es, [lg_cellseg]
    mov byte [es:di+LG_C_TYPE], LG_T_BOOL
    clc
.out:
    pop es
    pop di
    pop ax
    ret

; lg_setlabel - lg_settext for text as a PERSON would have typed it: TRUE and
; FALSE are the logical, the way Excel reads that entry, and anything else is
; a label. Typing, SYLK's quoted K and a CSV field come through here; BIFF
; and DIF have a type of their own to say which it is, and do not.
lg_setlabel:
    push dx
    push ax
    call lg_boolword
    mov dx, ax
    pop ax
    jnc .text
    call lg_setbool
    pop dx
    ret
.text:
    call lg_settext
    pop dx
    ret

; lg_fnlogical - CF=1 when the function [lg_pfid] answers TRUE or FALSE:
; NOT, AND, OR, TRUE, FALSE, the IS family and EXACT
lg_fnlogical:
    push ax
    push bx
    mov ax, [lg_pfid]
    or ah, ah
    jnz .no
    mov bx, lg_fnlog
.l:
    cmp al, [bx]
    je .yes
    inc bx
    cmp bx, lg_fnlog_end
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

lg_fnlog:     db 6, 8, 9, 20, 21, 25, 26, 27, 28, 29, 30, 31, 32, 48, 107
lg_fnlog_end:

; -----------------------------------------------------------------------------
; lg_setformula - in: AX=col, BX=row, SI=formula text (DS-resident,
; NUL-terminated, NOT including the leading '='). Out: CF=1 when refused
; (arena or cell table full) - the cell keeps what it had (lg_settext's
; contract, which this is a near-twin of).
; -----------------------------------------------------------------------------
lg_setformula:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [lg_fcol], ax
    mov [lg_frow], bx
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
    mov ax, [lg_txtlen]
    add ax, cx
    inc ax                            ; +1 for the NUL this stores too
    cmp ax, LG_TXT_CAP
    ja .noroom
    mov es, [lg_txtseg]
    mov di, [lg_txtlen]
    mov [lg_newoff], di               ; where THIS formula starts
    ; SPACES ARE DROPPED ON THE WAY IN (81.50), as Excel 2.1 drops them: its
    ; BIFF2 has no token to keep one in (tAttrSpace is BIFF3 on), so =1 + 2
    ; comes back =1+2. The evaluator does not step over a space between
    ; tokens, and never did - =1 + 2 used to answer 1. One space survives,
    ; where it stands between two OPERANDS (=1+2 3), because that is not a
    ; spacing but a mistake, and lg_eval_cell makes it #VALUE! rather than
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
    call lg_fsep
    jc .copy                          ; after an operator or '(': dropped
    mov al, [si]
    call lg_fsep
    jc .copy                          ; before one, or at the end: dropped
    mov al, ' '                       ; between two operands: ONE kept
.put:
    stosb
    mov dh, al
    or al, al
    jnz .copy
    mov [lg_txtlen], di
    mov ax, [lg_fcol]
    mov bx, [lg_frow]
    call lg_addcell
    jc .noroom
    push es
    mov es, [lg_cellseg]
    mov byte [es:di+4], 1             ; HASFORMULA
    mov byte [es:di+LG_C_TYPE], LG_T_NUM   ; stage 4.5: and RETAG it. Typing a
                                      ; formula over a label reuses that
                                      ; label's record, and without this the
                                      ; TEXT tag survived and the cell drew
                                      ; its old text forever while quietly
                                      ; computing the right answer underneath
    mov ax, [lg_newoff]
    mov [es:di+LG_C_FOFF], ax
    mov word [es:di+LG_C_PASS], 0xFFFF       ; a pass stamp lg_pass can never equal,
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
; lg_pexpr and friends compute; this walks the same grammar and emits. Two
; parsers can drift - but this one only ever has to answer "can I express
; this", and when it cannot the writer falls back to a path that was already
; correct. A shared parser with an emit flag would have put a second set of
; states inside the routine every cell value already depends on.
; =============================================================================
LG_PTG_ADD     equ 0x03                 ; the operator tokens (excelfileformat 3.5.7)
LG_PTG_SUB     equ 0x04
LG_PTG_MUL     equ 0x05
LG_PTG_DIV     equ 0x06
LG_PTG_POWER   equ 0x07
LG_PTG_LT      equ 0x09
LG_PTG_LE      equ 0x0A
LG_PTG_EQ      equ 0x0B
LG_PTG_GE      equ 0x0C
LG_PTG_GT      equ 0x0D
LG_PTG_NE      equ 0x0E
LG_PTG_UMINUS  equ 0x13
LG_PTG_PAREN   equ 0x15
LG_PTG_CONCAT  equ 0x08               ; 81.61: '&', a string constant and an
LG_PTG_STR     equ 0x17               ; error constant - cch byte, then bytes
LG_PTG_ERR     equ 0x1C               ; one byte, BIFF's own error code
LG_PTG_INT     equ 0x1E                 ; + a 16-bit unsigned
LG_PTG_NUM     equ 0x1F                 ; + an IEEE double
LG_PTG_FUNCV   equ 0x41                 ; tFuncV / tFuncVarV (3.7.1, 3.7.2).
LG_PTG_FUNCVARV equ 0x42                ; VALUE class throughout, like the refs
                                         ; below: a cell formula's result is a
                                         ; value, whatever the function's own
                                         ; default return class is
LG_PTG_REFV    equ 0x44                 ; value class: 3.3.4's transformation
LG_PTG_AREAV   equ 0x45                 ; turns the default R class into V inside
                                      ; an ordinary cell formula
LG_RPN_MAX   equ 96                   ; a token array longer than this is
                                      ; refused rather than truncated

; THE CONSTANTS ABOVE STAY IN BOTH ARMS and the code below does not. They are
; `equ`s and emit nothing, and LG_RPN_MAX still SIZES a bss slot further down
; (lg_rpn_buf, which lg_rwsrc is chained off) - so gating it out makes the
; whole bss chain non-constant and the two OS88_BSS assertions fail with
; "non-constant argument supplied to TIMES", which names neither the flag nor
; the symbol. PLAN's own bss ladder is 81.75's later stage; until it lands,
; PLAN reserves this buffer and never fills it.

; -----------------------------------------------------------------------------
; lg_settext - stage 4.5: store TEXT in a cell.
; in: AX = col, BX = row, SI = the NUL-terminated text
;
; Deliberately a near-twin of lg_setformula above rather than a shared routine
; the two both call. They agree on the arena copy and disagree on every flag
; that follows it, and a merged version would have been a copy of the first
; half wrapped in a parameter deciding the second - which is the same amount
; of code with a branch through the middle of it.
;
; THE TEXT LIVES IN THE FORMULA ARENA, at LG_C_FOFF, and the two never collide
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
; lg_sort_permcol).
; -----------------------------------------------------------------------------
section .text
lg_settext:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [lg_fcol], ax
    mov [lg_frow], bx
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
    mov ax, [lg_txtlen]
    add ax, cx
    inc ax                            ; +1 for the NUL
    cmp ax, LG_TXT_CAP
    ja .noroom
    mov es, [lg_txtseg]
    mov di, [lg_txtlen]
    mov [lg_newoff], di
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    mov [lg_txtlen], di
    mov ax, [lg_fcol]
    mov bx, [lg_frow]
    call lg_addcell
    jc .noroom
    push es
    mov es, [lg_cellseg]
    mov byte [es:di+4], 0             ; NOT a formula: the tag is what says
    mov byte [es:di+LG_C_TYPE], LG_T_TEXT
    mov byte [es:di+LG_C_AUX], 0
    mov ax, [lg_newoff]
    mov [es:di+LG_C_FOFF], ax
    mov word [es:di+LG_C_PASS], 0
    xor ax, ax                        ; and a numeric value of zero, so every
    mov [es:di+LG_C_VAL], ax          ; reader that has never heard of text
    mov [es:di+LG_C_VAL+2], ax        ; still gets a defined number out of it
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
; lg_eval_cell - evaluate a formula cell, with cycle detection and
; per-repaint memoization
; in: DI = record offset (a HASFORMULA record); ES = lg_cellseg
; out: DX = value; the record's cached value and pass stamp are updated
; -----------------------------------------------------------------------------
lg_eval_cell:
    push ax
    push bx
    push si
    push di
    push es
    mov es, [lg_cellseg]
    mov ax, [es:di+LG_C_PASS]                ; this cell's last-computed pass
    cmp ax, [lg_pass]
    jne .stale
    test byte [es:di+4], 2            ; EVALUATING - already mid-computation
    jnz .cycle                        ; means a cycle, not a cache hit
    call lg_cellval_to_acc            ; a cache hit is a full double now, not
    call lg_acc_toint                 ; a word; DX stays the truncated form
    mov dx, ax                        ; for the callers that still want one
    jmp .out
.stale:
    test byte [es:di+4], 2
    jnz .cycle
    or byte [es:di+4], 2              ; EVALUATING = 1
    push di                           ; this cell's record offset, kept on
                                       ; the stack (NOT a global) because
                                       ; evaluating this formula may recurse
                                       ; into lg_eval_cell again for a cell
                                       ; it references, and call/ret through
                                       ; lg_pexpr is stack-neutral either way
    push word [lg_evrow]              ; stage 3.0d: ROW()/COLUMN()'s context,
    push word [lg_evcol]              ; banked for the SAME reason and popped
    mov ax, [es:di]                   ; at .writeback. A referenced cell's own
    and ax, LG_ROW_MASK               ; formula must answer for ITSELF, so this
    mov [lg_evrow], ax                ; is per-frame, not set once
    mov ax, [es:di+2]
    mov [lg_evcol], ax
    mov ax, [es:di+LG_C_FOFF]                 ; formula_off
    mov si, ax
    mov es, [lg_txtseg]
    cmp word [lg_evaldepth], LG_EVAL_MAXDEPTH
    jae .toodeep
    cmp word [lg_evaldepth], 0        ; a FRESH evaluation starts clean; a
    jne .depthok                      ; nested one must not, or a referenced
    mov byte [lg_evalerr], 0          ; cell's error would be wiped on the way
    mov word [lg_sstk_sp], 0          ; back up. The string bank is reset with
.depthok:                             ; it, so an error path that returned
                                       ; early cannot leak a level into the
                                       ; next formula
    mov bx, [lg_evaldepth]
    inc word [lg_evaldepth]
    push bx                           ; this recursion level's buffer slot
    mov ax, LG_EDITMAX + 1
    mul bx
    add ax, lg_fbuf
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
    call lg_pcmp                      ; the result lands in lg_acc, and may
                                       ; have recursed to get there
    cmp byte [si], 0                  ; THE WHOLE FORMULA, OR IT IS NOT ONE
    je .whole                         ; (81.50). The parse used to stop quietly
    cmp byte [lg_evalerr], 0          ; at the first character it could not
    jne .whole                        ; use, so =1+2 3 answered 3 and =(1+2)3
    mov byte [lg_evalerr], LG_ERR_VALUE ; answered 3 - the "3.5kg" rule lg_commit
.whole:                               ; keeps for a number, and =1+'s rule
    pop bx                            ; for a formula that stops too soon
    dec word [lg_evaldepth]
    jmp .writeback
.toodeep:
    xor dx, dx
    push ax
    xor ax, ax
    call lg_acc_int                   ; too deep is a zero, in both forms
    pop ax
.writeback:
    pop word [lg_evcol]               ; stage 3.0d: ROW()/COLUMN() context,
    pop word [lg_evrow]               ; restored in the order it was pushed
    pop di                            ; this cell's record offset, restored
    mov es, [lg_cellseg]
    and byte [es:di+4], 0xFD          ; EVALUATING = 0 (HASFORMULA untouched)
    call lg_acc_toint                 ; DX = the truncated form, for callers
    mov dx, ax
    ; CACHING THE DOUBLE IS NOT THE FIRST THING ANY MORE, and it cannot be:
    ; lg_acc_to_cellval writes eight bytes over LG_C_VAL, and a TEXT result's
    ; slot offset lives in that same union (81.22.1). Doing it up front wiped
    ; the slot on every pass, so lg_str_store found VAL zero, allocated a fresh
    ; 65 bytes, and the arena was empty inside a hundred repaints - after which
    ; every text formula quietly fell back to the number underneath it, which
    ; is 0. Each branch below caches for itself, and the text one does not.
    mov al, [lg_evalerr]              ; the cell is stored by what it IS: an
    or al, al                         ; error, or a number again once whatever
    jz .notanerr                      ; broke it has been fixed
    call lg_acc_to_cellval
    mov byte [es:di+LG_C_TYPE], LG_T_ERR
    mov [es:di+LG_C_AUX], al
    mov byte [lg_curtype], LG_T_ERR   ; and PUBLISH it: the caller banked these
    mov [lg_curaux], al               ; two before the evaluation ran, so its
    jmp .errdone                      ; copy names the cell as it USED to be -
.notanerr:                            ; which paints #DIV/0! on a cell whose
    cmp byte [lg_curtype], LG_T_TEXT  ; stage 4.5: ...or the answer is a
    jne .notatext                     ; STRING, which LG_C_FOFF cannot hold
    call lg_str_store                 ; because the formula's own text is
    jc .notatext                      ; already there (81.22.1)
    mov byte [es:di+LG_C_TYPE], LG_T_TEXT
    mov byte [es:di+LG_C_AUX], 0
    mov ax, [es:di+LG_C_VAL]          ; the painter reads the RESULT, not the
    mov [lg_curtoff], ax              ; formula, so publish where it went
    jmp .errdone
.notatext:
    call lg_acc_to_cellval            ; cache the whole double
    mov ax, [es:di+LG_C_FOFF]         ; and a NUMERIC result publishes the
    mov [lg_curtoff], ax              ; formula's own text, which is what every
                                       ; reader of it has always expected
    mov al, LG_T_NUM                  ; ...or a LOGICAL one, the same double
    cmp byte [lg_curtype], LG_T_BOOL  ; with its own tag (81.51)
    jne .tagnum
    mov al, LG_T_BOOL
.tagnum:
    mov byte [es:di+LG_C_TYPE], al    ; divisor has since been fixed, and
    mov byte [es:di+LG_C_AUX], 0      ; #ERR on the one that is still broken
    mov [lg_curtype], al              ; (its code having been overwritten by
    mov byte [lg_curaux], 0           ; the last cell the formula referenced)
.errdone:
    mov ax, [lg_pass]
    mov [es:di+LG_C_PASS], ax
    jmp .out
.cycle:
    xor dx, dx
    push ax
    xor ax, ax
    call lg_acc_int                   ; a cycle is a zero, in both forms
    pop ax
.out:
    pop es
    pop di
    pop si
    pop bx
    pop ax
    ret

; =============================================================================
; Formula parser/evaluator - recursive descent over lg_fbuf (a DS-resident
; copy of the formula text; see lg_eval_cell). Grammar:
;   expr   := term (('+'|'-') term)*
;   term   := pow (('*'|'/') pow)*
;   pow    := factor ('^' pow)?            ; right-associative (stage 3.0d)
;   factor := '-' factor | '(' expr ')' | NUMBER | CELLREF | NAME '(' args ')'
;   args   := arg (',' arg)*
;   arg    := CELLREF ':' CELLREF | expr
; No whitespace skipping: lg_setformula drops every space on the way in
; except one between two operands, which is a mistake, and lg_eval_cell makes
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

; lg_pcmp / lg_pcmpcont - comparison level, the actual top of the grammar
; (lg_eval_cell enters here, not at lg_pexpr): '=' '<' '>' '<=' '>=' '<>'
; between two '&'-level operands, answering a LOGICAL (81.51) by Excel's
; ordering of types (81.53). LEFT-ASSOCIATIVE, as Excel's are: =1<2<3 is
; (1<2)<3, TRUE against 3, and a logical is above every number - FALSE. It
; stopped after one comparison, which since 81.50 left "<3" over, #VALUE!.
lg_pcmp:
    call lg_pconcat
lg_pcmpcont:
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
    ; text against text, case-insensitively (lg_lkstrcmp, the lookups' own);
    ; across types every number is below every text, below FALSE, below TRUE;
    ; a blank is 0 to a number, "" to a text and FALSE to a logical. BX, CX
    ; and DX are kept - CHOOSE counts in two of them across a whole argument.
.have:
    push bx
    push cx
    push dx
    mov al, [lg_curtype]              ; the LEFT operand's type, and its text
    cmp al, LG_T_TEXT                 ; banked where the right one's parse
    jne .nobank                       ; cannot reach it
    call lg_spush
    jnc .nobank
    mov al, LG_T_ERR                  ; the bank is full: #VALUE! is raised,
.nobank:                              ; and there is nothing to drop later
    push ax
    call lg_vpush
    call lg_pconcat                   ; the RIGHT at the '&' level: this was
    call lg_binop_pre                 ; lg_pexpr, so ="ab"="a"&"b" left the
    pop dx                            ; &"b" over. DH = outcomes, DL = left
    mov cl, [lg_curtype]              ; CL = the right's type
    mov bl, dl                        ; BL, CH: the types as COMPARED - a blank
    mov ch, cl                        ; takes the other side's
    cmp bl, LG_T_BLANK
    jne .lset
    mov bl, ch
.lset:
    cmp ch, LG_T_BLANK
    jne .rset
    mov ch, bl
.rset:
    mov al, bl
    call lg_cmprank
    mov ah, al
    mov al, ch
    call lg_cmprank                   ; AH = the left's rank, AL = the right's
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
    mov si, lg_snull                  ; a blank side is ""
    cmp dl, LG_T_TEXT
    jne .ltext
    xor ax, ax
    call lg_sslot                     ; SI = the banked left text
.ltext:
    mov di, lg_snull
    cmp cl, LG_T_TEXT
    jne .rtext
    mov di, lg_sacc
.rtext:
    call lg_lkstrcmp
    pop di
    pop si
.outcome:
    cmp dl, LG_T_TEXT
    jne .nodrop
    call lg_spop                      ; the left text's bank
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
    call lg_acc_int
    mov byte [lg_curtype], LG_T_BOOL  ; a COMPARISON answers a LOGICAL (81.51)
    pop dx
    pop cx
    pop bx
    jmp lg_pcmpcont                   ; ...and may be the left of another

; lg_cmprank - AL = a type -> AL = its rank for a comparison: 0 a number (or
; a blank that met one), 1 text, 2 a logical
lg_cmprank:
    cmp al, LG_T_TEXT
    je .t
    cmp al, LG_T_BOOL
    je .b
    xor al, al
    ret
.t:
    mov al, 1
    ret
.b:
    mov al, 2
    ret

; lg_pexpr / lg_pexprcont - additive level. lg_pexprcont is a real entry
; point of its own: lg_prange calls it to resume the +/- loop after folding
; a lone cell reference that turned out not to start a range.
lg_pexpr:
    call lg_pterm
lg_pexprcont:
    cmp byte [si], '+'
    je .add
    cmp byte [si], '-'
    je .sub
    ret
.add:
    call lg_chktext                   ; the LEFT operand, which lg_curtype
    inc si                            ; still describes
    call lg_vpush                     ; the left operand goes on the machine
    call lg_pterm                     ; stack: a double does not fit a register
    call lg_chktext                   ; ...and now the right
    call lg_binop_pre                 ; and the parse of the right may recurse
    call fx_add
    call lg_acc_store
    mov byte [lg_curtype], LG_T_NUM   ; stage 4.5: the RESULT of arithmetic is
    jmp lg_pexprcont                  ; a NUMBER whatever its operands were
                                       ; tagged. Nothing used to say so, so the
                                       ; tag left by the last cell an operand
                                       ; touched still stood - unobservable
                                       ; until lg_pargclass below made a
                                       ; mid-expression tag answerable
.sub:
    call lg_chktext
    inc si
    call lg_vpush
    call lg_pterm
    call lg_chktext
    call lg_binop_pre
    call fx_sub
    call lg_acc_store
    mov byte [lg_curtype], LG_T_NUM
    jmp lg_pexprcont

; -----------------------------------------------------------------------------
; lg_pconcat (stage 4.5) - the '&' level. Excel binds it LOOSER than '+' and
; TIGHTER than a comparison, so `="a"&"b"="ab"` compares two concatenations
; rather than concatenating a comparison (81.22.2).
;
; Either side may be a number - `=A1&"x"` with A1 holding 12 gives "12x", which
; is what every spreadsheet does - so a numeric operand is formatted into
; lg_sacc first. The left operand is banked in lg_sacc2 across the right one's
; parse, because parsing the right may recurse all the way back through here.
; -----------------------------------------------------------------------------
lg_pconcat:
    call lg_pexpr
lg_pconcatcont:
    cmp byte [si], '&'
    je .cat
    ret
.cat:
    inc si
    call lg_str_want                  ; the LEFT operand, as text, BANKED ON
    call lg_spush                     ; THE STRING STACK: the right one's parse
    sbb ax, ax                        ; can reach this routine again, and the
    push ax                           ; one global it was banked in was
    call lg_pexpr                     ; overwritten - ="a"&("b"&"c") was "bbc"
    call lg_str_want                  ; (81.53). AX = -1: the bank was full
    push si                           ; the RIGHT operand, as text, out of
    push di                           ; the way...
    mov si, lg_sacc
    mov di, lg_sacc2
    call lg_strcpy
    pop di
    pop si
    pop ax
    or ax, ax
    jnz .nobank                       ; #VALUE! is raised already
    call lg_srestore                  ; ...the left back into lg_sacc...
.nobank:
    push si
    push di
    mov si, lg_sacc2                  ; ...and the right appended
    call lg_str_cat
    pop di
    pop si
    mov byte [lg_curtype], LG_T_TEXT
    xor ax, ax
    call lg_acc_int
    jmp lg_pconcatcont

; -----------------------------------------------------------------------------
; lg_str_want - make lg_sacc hold the current result AS TEXT, whatever it is.
; A number is formatted the way the General format shows it, so `=1.5&"x"` is
; "1.5x" and not "1.500000x".
; -----------------------------------------------------------------------------
lg_str_want:
    cmp byte [lg_curtype], LG_T_TEXT
    je .done
    push ax
    push si
    push di
    cmp byte [lg_curtype], LG_T_BOOL  ; a LOGICAL is its name: ="x"&TRUE is
    jne .num                          ; "xTRUE", LEN(TRUE) is 4 (81.51)
    mov ax, [lg_acc]
    call lg_boolname
    jmp short .copy
.num:
    call lg_acc_load_a
    mov di, lg_numbuf
    mov ax, 10
    call fx_ftoa
.copy:
    mov si, lg_numbuf
    mov di, lg_sacc
    call lg_strcpy
    pop di
    pop si
    pop ax
.done:
    ret

; lg_pterm / lg_ptermcont - multiplicative level, same reasoning as above.
lg_pterm:
    call lg_ppow
lg_ptermcont:
    cmp byte [si], '*'
    je .mul
    cmp byte [si], '/'
    je .div
    ret
.mul:
    call lg_chktext
    inc si
    call lg_vpush
    call lg_ppow
    call lg_chktext
    call lg_binop_pre
    call fx_mul
    jnc .mulok                        ; past +-214,748.3647: #NUM!, which is
    mov byte [lg_evalerr], LG_ERR_NUM ; what Excel answers and what `^` and
.mulok:                               ; POWER() already answered - they test
                                       ; fx_pow's carry and this was the one
                                       ; arithmetic operator that tested
                                       ; nothing. The CLAMPED value is stored
                                       ; rather than zeroed: lg_evalerr makes
                                       ; the cell an error whatever is in it
    call lg_acc_store
    mov byte [lg_curtype], LG_T_NUM
    jmp lg_ptermcont
.div:
    call lg_chktext
    inc si
    call lg_vpush
    call lg_ppow
    call lg_chktext
    call lg_binop_pre
    call fx_div                       ; CF=1 means the divisor was zero
    jnc .divok
    mov byte [lg_evalerr], LG_ERR_DIV0
    xor ax, ax                        ; the value is still zero underneath -
    call lg_acc_int                   ; the flag is what the cell is stored by
    mov byte [lg_curtype], LG_T_NUM
    jmp lg_ptermcont
.divok:
    call lg_acc_store
    mov byte [lg_curtype], LG_T_NUM
    jmp lg_ptermcont

; lg_ppow (stage 3.0d) - the '^' level, between multiplication and the
; factors. RIGHT-associative, so 2^3^2 is 2^(3^2) = 512, which is what every
; spreadsheet does; the recursion below is what makes it so, where a loop like
; lg_ptermcont's would have made it left-associative.
;
; It binds TIGHTER than '*' and looser than unary minus, so -2^2 is -(2^2).
; That is Excel's own precedence and it surprises people, but matching it is
; the point.
;
; A negative exponent is a fraction and there is no fraction here, so it
; yields 0 - the same answer this evaluator already gives for division by
; zero, and for the same stated reason.
; lg_ppowcont is a real entry point of its own, like lg_ptermcont's: lg_prange
; calls it FIRST to resume a lone cell reference that turned out not to start
; a range - without it, `=SUM(A1^2)` left the '^' for lg_pfunc's argument loop,
; which can only stop at it.
lg_ppow:
    call lg_pfactor
lg_ppowcont:
    cmp byte [si], '^'
    jne .out
    call lg_chktext
    inc si
    call lg_pnest_enter               ; '^' recurses too (81.3)
    jc .nestfull
    call lg_vpush                     ; the BASE, banked
    call lg_ppow                      ; recurse: right-associative
    call lg_pnest_leave
    call lg_chktext
    mov byte [lg_curtype], LG_T_NUM
    call lg_acc_load_a                ; THE EXPONENT MAY BE FRACTIONAL NOW.
    call fx_a_to_b                    ; This banked it through lg_acc_toint
    pop word [lg_lhs]                 ; and multiplied the base by itself that
    pop word [lg_lhs+2]               ; many times, with a comment saying "a
    push si                           ; stopped being true at 84.10. 2^0.5 is
    mov si, lg_lhs                    ; 1.414 and not 1
    call fx_unpack_a
    pop si
    call fx_pow
    jnc .powok
    mov byte [lg_evalerr], LG_ERR_NUM ; a negative base to a fractional power
    call fx_azero                     ; has no real value
.powok:
    call lg_acc_store
.out:
    ret
.nestfull:
    push ax                           ; over the budget: the base is dropped,
    xor ax, ax                        ; and the #VALUE! lg_pnest_enter raised
    call lg_acc_int                   ; stands
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_pnest_enter / lg_pnest_leave - the parser's shared nesting budget (81.3).
; LG_EVAL_MAXDEPTH bounds cell-to-cell recursion, but nothing bounded a
; formula's OWN nesting: every '(', unary '-', '^' and nested call recurses
; the parser and banks bytes on task 0's 512-byte stack, and six
; memoization-cold cells chained that way could run SP off the stack's floor
; into .lowbss - silent corruption that fails later, somewhere unrelated.
; One counter charges every recursion point, with the cell depth folded in;
; over LG_PNEST_MAX the parse refuses with #VALUE! - the same refusal shape
; lg_eval_cell's .toodeep already has.
; out: CF=1 refused (lg_evalerr raised, NOTHING charged - do not leave),
;      CF=0 charged - pair with exactly one lg_pnest_leave
; -----------------------------------------------------------------------------
lg_pnest_enter:
    push ax
    mov ax, [lg_pnest]
    inc ax
    add ax, [lg_evaldepth]
    cmp ax, LG_PNEST_MAX
    ja .full
    inc word [lg_pnest]
    pop ax
    clc
    ret
.full:
    pop ax
    mov byte [lg_evalerr], LG_ERR_VALUE
    stc
    ret

lg_pnest_leave:
    dec word [lg_pnest]
    ret

; lg_pfactor - unary minus, parens, a number, or an identifier (cell
; reference or function call, lg_pident tells them apart)
lg_pfactor:
    cmp byte [si], '-'
    jne .notneg
    inc si
    call lg_pnest_enter               ; unary minus recurses (81.3)
    jc .nestfull
    call lg_pfactor
    call lg_pnest_leave
    call lg_chktext                   ; -"text" is arithmetic too
    call lg_acc_neg                   ; 81.75: two's complement, not a sign
    mov byte [lg_curtype], LG_T_NUM   ; bit. A NUMBER, as every operator's
    ret                               ; result is: -TRUE is -1, not a logical
                                      ; (81.51)
.notneg:
    cmp byte [si], '('
    jne .notparen
    inc si
    call lg_pnest_enter               ; ...and so does a parenthesis
    jc .nestfull
    call lg_pcmp
    call lg_pnest_leave
    cmp byte [si], ')'
    jne .out                          ; malformed; return whatever we have
    inc si
    ret
.nestfull:
    push ax                           ; over the budget: lg_pnest_enter has
    xor ax, ax                        ; raised #VALUE!, and the refusal
    call lg_acc_int                   ; answers zero underneath it
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
    jbe .ident                        ; evaluates to 0. lg_pident tolerating
    cmp al, 'a'                       ; '$' is necessary but not sufficient.
    jb .maybenum
    cmp al, 'z'
    ja .maybenum
.ident:
    call lg_pident
    ret
.maybenum:
    jmp .maybenum2
.strlit:
    inc si                            ; past the opening quote
    push cx
    push di
    mov di, lg_sacc
    mov cx, LG_STR_MAX
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
    mov byte [lg_curtype], LG_T_TEXT
    xor ax, ax                        ; the number underneath a string is zero,
    call lg_acc_int                   ; so a reader that wants one gets a
    ret                               ; defined answer
.errlit:
    call lg_perrlit
    ret
.maybenum2:
    mov byte [lg_curtype], LG_T_NUM   ; a LITERAL is a number - say so, or the
    call fx_atof                      ; tag left by the last cell referenced
    jnc .numok                        ; still stands and `=B4+1` is judged by
    mov byte [lg_evalerr], LG_ERR_VALUE ; B4's type twice over
    xor ax, ax                        ; nothing parseable at all: `=1+` used to
    call lg_acc_int                   ; read as 1, an answer to a formula the
    ret                               ; user never finished writing
.numok:
    call lg_acc_store
.out:
    ret

; -----------------------------------------------------------------------------
; lg_perrlit (stage 4.5) - SI is at a '#'. An error value written out in full
; is a LITERAL, as it is in Excel, and this file needs to read one for a
; reason of its own: Delete Row and Delete Column now write `#REF!` into every
; formula that named a deleted cell (81.26.1), so the parser has to be able to
; read back what the rewriter wrote. Typing `=#N/A` works for the same reason,
; which is also what Excel does.
;
; The names come from lg_errtab - the same table lg_errname prints and
; lg_errcode reads - so the spelling written and the spelling recognised
; cannot drift apart. No name is a prefix of another, so first match wins.
;
; out: the error raised in lg_evalerr, lg_acc zero, SI past the name. A '#'
; followed by something else is #NAME?, which is what an unknown word already
; gets, and SI steps over the '#' so the parse can still make progress.
; -----------------------------------------------------------------------------
lg_perrlit:
    push bx
    push cx
    push di
    xor cx, cx
.try:
    cmp cx, 7
    jae .unknown
    mov bx, cx
    shl bx, 1
    mov di, [lg_errtab + bx]
    call lg_matchat                   ; is that name a prefix of SI?
    jc .found
    inc cx
    jmp .try
.found:
    mov bx, cx
    shl bx, 1
    mov di, [lg_errtab + bx]
.skip:
    cmp byte [di], 0
    je .done
    inc di
    inc si
    jmp .skip
.done:
    inc cx                            ; the table is 0-based, the ERROR.TYPE
    mov [lg_evalerr], cl              ; codes are 1-based
    jmp .out
.unknown:
    mov byte [lg_evalerr], LG_ERR_NAME
    inc si
.out:
    mov byte [lg_curtype], LG_T_NUM
    xor ax, ax
    call lg_acc_int
    pop di
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; lg_psheetpfx - stage 2.0: does SI start a "SheetN!" cross-sheet prefix?
; Sheet names are the fixed "Sheet1".."SheetN" strings (see the Sheets menu
; comment), so this is a literal, case-insensitive match against "SHEET"
; plus a digit '1'..LG_SHEETS - not a general name lookup.
; in: SI; out: CF=1 and AX=0-based sheet index, SI advanced past the '!';
; CF=0 and SI unchanged otherwise
; -----------------------------------------------------------------------------
lg_psheetpfx:
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
    cmp al, '0' + LG_SHEETS
    ja .no
    sub al, '1'
    xor ah, ah
    mov cx, ax                        ; cx = sheet index 0..LG_SHEETS-1
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

; lg_pident - in: SI at an identifier's first letter
; out: AX = value (a cell's value, or a function call's result), SI advanced
lg_pident:
    push bx
    push cx
    push dx
    push di
    mov byte [lg_pxsheet], 0xFF
    call lg_psheetpfx
    jnc .noxsheet
    mov [lg_pxsheet], al
.noxsheet:
    cmp byte [si], '$'                ; stage 3.0e: skip an absolute marker
    jne .nocoldollar                  ; before the column letters
    inc si
.nocoldollar:
    mov di, lg_ident
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
    cmp cx, LG_NAME_MAX               ; a cell reference still cannot hold one
    jae .doneletters
    jmp .store                        ; ...and it does NOT go through the
                                       ; uppercase fold below: '.' AND 0xDF is
                                       ; 0x0E, which would have put a control
                                       ; character in the middle of the name
.isletter:
    cmp cx, LG_NAME_MAX               ; a DEFINED NAME can be this long, so the
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
    cmp cx, LG_NAME_MAX
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
    call lg_identcol                  ; lg_ident -> AX = 0-based column
    mov [lg_pcol], ax
    mov bx, si
    add bx, LG_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call lg_pint                      ; SI advances past the digits
    pop es
    dec ax                            ; AX = 0-based row
    mov bx, ax
    mov ax, [lg_pcol]
    cmp byte [lg_pxsheet], 0xFF
    je .samesheet
    mov cx, [lg_cursheet]              ; stage 2.0: a "SheetN!" prefix -
    push cx                            ; temporarily point lg_findcell (via
    mov cl, [lg_pxsheet]               ; lg_cursheet) at the target sheet
    xor ch, ch                         ; for this one lookup, then put it
    mov [lg_cursheet], cx              ; back - every OTHER caller of
    call lg_getcell2                   ; lg_getcell2/lg_findcell is none the
    pop cx                             ; wiser
    mov [lg_cursheet], cx
    jmp .havecell
.samesheet:
    call lg_getcell2
.havecell:
    jmp .out                          ; nothing to do: lg_getcell2 leaves the
                                      ; value in lg_acc, and leaves a ZERO
                                      ; there for a cell that does not exist -
                                      ; which is what both branches here used
                                      ; to arrange by hand
.isfunc:
    ; 81.75: an identifier that is not a call used to be looked up as a
    ; DEFINED NAME and resolved to its rectangle. There are none - the only
    ; thing that could make one was Formula > Define Name - so every
    ; identifier here is a function call or a misspelling, and lg_pfunc's
    ; own .noname already says which.
    call lg_pfunc
.out:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; lg_identcol - in: lg_ident = NUL-terminated uppercase letters (1-2 chars)
; out: AX = 0-based column index (the bijective base-26 lg_colname inverts)
lg_identcol:
    push bx
    push cx
    push si
    mov si, lg_ident
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

; lg_pcellref - a backtracking probe: does SI start a bare cell reference?
; in: SI; out: CF=1 yes (AX=col, BX=row, SI advanced past it),
;             CF=0 no (SI UNCHANGED - the caller falls back to lg_pexpr)
; Used only to tell a range's "A1:B5" apart from a plain expression that
; merely starts with a cell reference, like "A1+5".
lg_pcellref:
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
    mov di, lg_ident
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
    call lg_identcol
    mov cx, ax                        ; CX = col, held across lg_pint
    mov bx, si
    add bx, LG_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call lg_pint
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

; lg_prange - one comma-separated function argument: a range, or a single
; expression (which may itself start with, but not be, a cell reference -
; "A1" alone IS the range-shorthand for a single cell; "A1+5" is not a
; range at all). Folds into lg_pacc/lg_pcnt/lg_phave per lg_pfid.
lg_prange:
    push ax
    push bx
    ; 81.75: `=SUM(Sales)` folded a DEFINED NAME's block here. There are no
    ; defined names in this build, so a range argument is a reference or a
    ; plain expression and nothing else.
    call lg_pcellref
    jnc .plainexpr
    cmp byte [si], ':'
    jne .singlecell
    inc si
    mov [lg_r1col], ax
    mov [lg_r1row], bx
    call lg_pcellref
    jnc .out                          ; malformed range; contributes nothing
    mov [lg_r2col], ax
    mov [lg_r2row], bx
    call lg_normrange
.isect:
    cmp byte [si], ' '                ; stage 4.5: Excel's INTERSECTION
    jne .fold                         ; operator is a space, and an empty
    mov ax, si                        ; intersection is the one and only
    call lg_pintersect                ; thing that produces #NULL! (81.26.3)
    jc .out                           ; empty: there is nothing to fold
    cmp ax, si
    je .fold                          ; nothing consumed - the space was not
    jmp .isect                        ; an operator after all
.fold:
    call lg_foldrange
    jmp .out
.singlecell:
    call lg_getcell2                  ; the value lands in lg_acc either way -
.havev:                               ; getcell2 puts a zero there for a cell
    call lg_ppowcont                  ; that does not exist. Tightest binding
    call lg_ptermcont                 ; first: '^', then '*', then '+', then
    call lg_pexprcont                 ; '&', then the comparison (81.22.2)
    call lg_pconcatcont
    call lg_pcmpcont
    call lg_foldvalue
    jmp .out
.plainexpr:
    call lg_pcmp
    cmp byte [lg_curtype], LG_T_BOOL  ; SUM(TRUE,1) is 2: a logical TYPED as
    jne .pefold                       ; an argument is its number, and only
    mov byte [lg_curtype], LG_T_NUM   ; one read from a cell is stepped over
.pefold:                              ; (81.51)
    call lg_foldvalue
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_pnamerange - is the argument at SI a DEFINED NAME and nothing else?
;
; in:  SI at the start of an argument
; out: CF=1 - lg_r1col/row..lg_r2col/row hold the rectangle it names and SI is
;             past it; CF=0 - not a name, SI UNCHANGED.
;
; Strict about "nothing else" for the same reason lg_pargref is (81.23): a ','
; or the ')' has to follow, so `=SUM(Sales+1)` is an expression about Sales
; and not a fold over it. A name followed by '(' is a FUNCTION CALL - that is
; the only thing separating SUM from a cell called SUM - and is declined here
; so lg_pfunc still gets it.
;
; A one-cell name resolves to a 1x1 rectangle and folds to the same single
; value the expression path already gave it, so nothing that worked before
; takes a different route to a different answer.
; -----------------------------------------------------------------------------
lg_normrange:
    push ax
    push bx
    mov ax, [lg_r1col]
    mov bx, [lg_r2col]
    cmp ax, bx
    jle .colok
    xchg ax, bx
.colok:
    mov [lg_r1col], ax
    mov [lg_r2col], bx
    mov ax, [lg_r1row]
    mov bx, [lg_r2row]
    cmp ax, bx
    jle .rowok
    xchg ax, bx
.rowok:
    mov [lg_r1row], ax
    mov [lg_r2row], bx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
lg_pintersect:
    push ax
    push bx
    push si
.spaces:
    cmp byte [si], ' '
    jne .second
    inc si
    jmp .spaces
.second:
    call lg_pcellref
    jnc .nope
    mov [lg_ix1col], ax
    mov [lg_ix1row], bx
    mov [lg_ix2col], ax
    mov [lg_ix2row], bx
    cmp byte [si], ':'
    jne .haveit
    inc si
    call lg_pcellref
    jnc .nope
    mov [lg_ix2col], ax
    mov [lg_ix2row], bx
.haveit:
    mov ax, [lg_ix1col]               ; normalise the second rectangle too -
    mov bx, [lg_ix2col]               ; `B5:A1` names the same block as
    cmp ax, bx                        ; `A1:B5` and must intersect the same
    jle .c2ok
    xchg ax, bx
.c2ok:
    mov [lg_ix1col], ax
    mov [lg_ix2col], bx
    mov ax, [lg_ix1row]
    mov bx, [lg_ix2row]
    cmp ax, bx
    jle .r2ok
    xchg ax, bx
.r2ok:
    mov [lg_ix1row], ax
    mov [lg_ix2row], bx
    mov ax, [lg_ix1col]               ; the intersection is the later start
    cmp ax, [lg_r1col]                ; and the earlier end, on each axis
    jbe .e1
    mov [lg_r1col], ax
.e1:
    mov ax, [lg_ix2col]
    cmp ax, [lg_r2col]
    jae .e2
    mov [lg_r2col], ax
.e2:
    mov ax, [lg_ix1row]
    cmp ax, [lg_r1row]
    jbe .e3
    mov [lg_r1row], ax
.e3:
    mov ax, [lg_ix2row]
    cmp ax, [lg_r2row]
    jae .e4
    mov [lg_r2row], ax
.e4:
    mov ax, [lg_r1col]
    cmp ax, [lg_r2col]
    ja .empty
    mov ax, [lg_r1row]
    cmp ax, [lg_r2row]
    ja .empty
    add sp, 2                         ; discard the saved SI - keep advancing
    pop bx
    pop ax
    clc
    ret
.empty:
    mov byte [lg_evalerr], LG_ERR_NULL
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
; lg_foldrange - in: lg_r1col/row, lg_r2col/row (either corner order);
; folds every OCCUPIED cell in the rectangle via lg_foldvalue.
;
; It walks the RECORD ARRAY, not the rectangle (81.3): records are sorted by
; (packed row, col) - the stage 2.0 comment above lg_findcell - so ONE binary
; search finds the first corner and a forward scan visits exactly the records
; in the row span. Walking every coordinate was O(area x log n): the ordinary
; =SUM(A1:A16384) idiom was 16,384 searches inside the paint callback, seconds
; per repaint on the 8088 and invisible in an emulator (PERFORMANCE.md rule 6).
; The bound rides in SI and the cursor in DI because lg_getcell2 preserves
; both across the evaluation a formula cell runs; the end offset is a
; function of [lg_ncells] alone, the same for a nested fold, so lg_rrow can
; hold it.
; -----------------------------------------------------------------------------
lg_foldrange:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    call lg_normrange                  ; split out for lg_pintersect's sake
    mov ax, [lg_ncells]
    mov bx, LG_C_SZ
    mul bx
    mov [lg_rrow], ax                  ; end-of-array offset
    mov ax, [lg_cursheet]              ; the far corner, PACKED the way the
    mov cl, LG_ROW_BITS                ; records store a row (lg_findcell)
    shl ax, cl
    or ax, [lg_r2row]
    mov si, ax                         ; SI = the packed bound
    mov ax, [lg_r1col]
    mov bx, [lg_r1row]
    call lg_findcell                   ; found or not, DI = the first record
                                        ; at or after the near corner
.scan:
    cmp di, [lg_rrow]
    jae .done                          ; past the last record
    mov es, [lg_cellseg]               ; reloaded every pass: an evaluation
    mov ax, [es:di]                    ; below moves ES. AX = packed row
    cmp ax, si
    jg .done                           ; sorted (signed, as lg_findcell
    mov bx, [es:di+2]                  ; compares): past the last row is done
    cmp bx, [lg_r1col]
    jb .next
    cmp bx, [lg_r2col]
    ja .next
    and ax, LG_ROW_MASK                ; a hit: unpack the row and fold it
    xchg ax, bx                        ; AX = col, BX = row
    push word [lg_r1col]               ; A FORMULA CELL IN THE RANGE MAY FOLD A
    push word [lg_r2col]               ; RANGE OF ITS OWN, through these same
    call lg_getcell2                   ; two words: =SUM(D55:I55) over six
    pop word [lg_r2col]                ; column SUMs scanned D alone after the
    pop word [lg_r1col]                ; first one ran, and answered its total.
                                       ; Excel 2.1d's own EXPENSES.XLS found it
                                       ; (81.52). The row bound is in SI and
                                       ; lg_rrow cannot change; the lookups
                                       ; refuse the same shape instead (47)
    jnc .next                          ; tag, format and lg_acc, exactly as
                                       ; an operand's read loads them
    call lg_foldvalue                  ; lg_acc is the value; see lg_foldvalue
.next:
    add di, LG_C_SZ
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
; lg_foldvalue - fold the value in lg_acc into the running lg_pacc, per the
; function being parsed (lg_pfid).
;
; lg_pacc is EIGHT BYTES now, not a word: SUM over a column of decimals has to
; keep them. The incoming value arrives in lg_acc rather than in AX for the
; same reason, and both are packed doubles - fp A and B are scratch here and
; are reloaded on every fold, because the range walker between calls uses them
; itself.
; -----------------------------------------------------------------------------
lg_foldvalue:
    push ax
    push bx
    cmp byte [lg_curtype], LG_T_BOOL   ; A LOGICAL IN A REFERENCE is stepped
    jne .notbool                       ; over like a label - Excel's rule for
    cmp word [lg_pfid], 8              ; SUM and every numeric fold - except
    je .counted                        ; by AND and OR, which are about
    cmp word [lg_pfid], 9              ; nothing else. One typed as an argument
    je .counted                        ; counts: lg_prange makes it a number
    jmp short .astext                  ; before it gets here (81.51)
.notbool:
    cmp byte [lg_curtype], LG_T_TEXT   ; stage 4.5: a LABEL is not a number and
    jne .counted                       ; every numeric fold steps over it -
.astext:
    cmp word [lg_pfid], 11             ; SUM, MIN, MAX and PRODUCT because a
    jne .out                           ; label has no value, and AVERAGE for a
    inc word [lg_pcnt]                 ; second reason on top of that: it
    jmp .out                           ; divides by lg_pcnt, so counting a
                                       ; label would drag the mean toward zero
                                       ; without ever adding to the total.
                                       ; COUNTA (11) is the one that WANTS it,
                                       ; and this is the first release in
                                       ; which COUNT and COUNTA can disagree
                                       ; about anything at all.
.counted:
    inc word [lg_pcnt]
    mov bx, [lg_pfid]
    cmp bx, 0
    je .sum
    cmp bx, 1
    je .sum                           ; AVERAGE sums here; lg_funcfinish
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
    call lg_pacc_to_a                 ; the running sum, as SUM does...
    call lg_acc_load_b
    call fx_add
    call lg_pacc_from_a
    call lg_acc_load_a                ; ...and the sum of SQUARES beside it
    call lg_acc_load_b
    call fx_mul                       ; A = x * x
    call fx_a_to_b                    ; ...to B, so the running total can
    push si                           ; come into A
    mov si, lg_pacc2
    call fx_unpack_a
    pop si
    call fx_add
    push di
    mov di, lg_pacc2
    call fx_pack_a
    pop di
    jmp .out
.sum:
    call lg_pacc_to_a
    call lg_acc_load_b
    call fx_add
    call lg_pacc_from_a
    jmp .out
.product:
    call lg_pacc_to_a
    call lg_acc_load_b
    call fx_mul
    jnc .prodok                       ; ...and the fold that multiplies says
    mov byte [lg_evalerr], LG_ERR_NUM ; it too, so =PRODUCT(A1:A9) cannot
.prodok:                              ; answer a wrapped number either
    call lg_pacc_from_a
    jmp .out
.min:
    cmp word [lg_phave], 0
    jnz .mincmp
    call lg_acc_to_pacc
    mov word [lg_phave], 1
    jmp .out
.mincmp:
    call lg_acc_load_a                ; is the new value below the running one?
    call lg_pacc_to_b
    call fx_cmpab
    jge .out
    call lg_acc_to_pacc
    jmp .out
.max:
    cmp word [lg_phave], 0
    jnz .maxcmp
    call lg_acc_to_pacc
    mov word [lg_phave], 1
    jmp .out
.maxcmp:
    call lg_acc_load_a
    call lg_pacc_to_b
    call fx_cmpab
    jle .out
    call lg_acc_to_pacc
    jmp .out
.and:
    call lg_acc_iszero
    jnc .out                          ; nonzero folds in as true: no-op
    xor ax, ax                        ; any false value forces AND to false
    call lg_int_to_pacc
    jmp .out
.or:
    call lg_acc_iszero
    jc .out                           ; zero folds in as false: no-op
    mov ax, 1                         ; any true value forces OR to true
    call lg_int_to_pacc
.out:
    pop bx
    pop ax
    ret

; --- the small movers the fold above is written in terms of ------------------
lg_pacc_to_a:
    push si
    mov si, lg_pacc
    call fx_unpack_a
    pop si
    ret

lg_pacc_to_b:
    push si
    mov si, lg_pacc
    call fx_unpack_b
    pop si
    ret

lg_pacc_from_a:
    push di
    mov di, lg_pacc
    call fx_pack_a
    pop di
    ret

lg_acc_to_pacc:
    push ax
    push si
    push di
    mov si, lg_acc
    mov di, lg_pacc
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

; lg_int_to_pacc - AX (signed) -> lg_pacc
lg_int_to_pacc:
    call fx_i2a
    call lg_pacc_from_a
    ret

; lg_esatof - parse a decimal number from ES:SI into lg_acc, advancing SI past
; it. fx_atof reads DS:SI and the file staging buffer is in ES, so the token is
; copied across first - up to a ';' or the record's end. Without this, a SYLK
; K field would still be read by the integer parser and "3.5" would come back
; as 3, which is what the round trip actually did before this existed.
section LG_MODSEC                      ; 82.16.9
lg_esatof:
    push ax
    push cx
    push di
    mov di, lg_numbuf
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
    mov si, lg_numbuf
    SHOUT fx_atof
    pop si
    SHOUT lg_acc_store
    pop di
    pop cx
    pop ax
    ret

; The same three, for a record addressed through SI - the file writers, the
; chart scan and sort all walk the array with SI rather than DI.
section .text
lg_cellval_to_acc_si:
    push ax
    push cx
    push si
    push di
    mov di, lg_acc
    mov cx, 2                          ; 81.75: TWO words, not four
.s2a:
    mov ax, [es:si+LG_C_VAL]
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



; lg_cellnum - the value of the record at ES:DI, formatted into lg_numbuf as
; a decimal. What "read the word and lg_itoa it" used to do, except that the
; value is eight bytes now and its low word on its own is meaningless.
lg_cellnum:
    cmp byte [es:di+LG_C_TYPE], LG_T_ERR   ; ...and an ERROR its name (81.61):
    jne .noterr                           ; this wrote the zero underneath, so
    push ax                               ; a copied #N/A pasted as 0
    mov al, [lg_curaux]
    push ax
    mov al, [es:di+LG_C_AUX]
    mov [lg_curaux], al
    call lg_errname
    pop ax
    mov [lg_curaux], al
    pop ax
    ret
.noterr:
    cmp byte [es:di+LG_C_TYPE], LG_T_BOOL  ; a LOGICAL is its name here too -
    jne .num                              ; the formula bar, Copy and Paste
    push ax                               ; all read it through this (81.51)
    mov ax, [es:di+LG_C_VAL]
    call lg_boolname
    pop ax
    ret
.num:
    push ax
    push di
    call lg_cellval_to_acc
    call lg_acc_load_a
    mov di, lg_numbuf
    mov ax, 10
    call fx_ftoa
    pop di
    pop ax
    ret

; lg_cellval_to_acc / lg_acc_to_cellval - the eight value bytes of the record
; at ES:DI. DI is left where it started, which matters: every caller is still
; using it as the record's offset.
lg_cellval_to_acc:
    push ax
    push cx
    push si
    push di
    mov si, lg_acc
    mov cx, 4
.c2a:
    mov ax, [es:di+LG_C_VAL]
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

lg_acc_to_cellval:
    push ax
    push cx
    push si
    push di
    mov si, lg_acc
    mov cx, 2                          ; 81.75: TWO words, not four
.a2c:
    mov ax, [si]
    mov [es:di+LG_C_VAL], ax
    add di, 2
    add si, 2
    dec cx
    jnz .a2c
    pop di
    pop si
    pop cx
    pop ax
    ret

; lg_acc_neg - lg_acc = -lg_acc.  lg_acc_abs - lg_acc = |lg_acc|.
;
; 81.75: BOTH OF THESE USED TO BE ONE INSTRUCTION on the IEEE sign BIT -
; `xor byte [lg_acc+7], 0x80` and `and byte [lg_acc+7], 0x7F`. A packed
; double carries its sign in a bit, so negate and absolute-value were free
; and exact. Two's complement does not: clearing the top bit of a negative
; count gives a different number, not its magnitude. These are the two
; places that has to be spelled out, and the +7 is why a sweep that looked
; for +4 and +6 did not find them - `=-5` came out as 5.
; Every register preserved.
lg_acc_neg:
    push ax
    push dx
    mov ax, [lg_acc]
    mov dx, [lg_acc+2]
    not ax
    not dx
    add ax, 1
    adc dx, 0
    mov [lg_acc], ax
    mov [lg_acc+2], dx
    pop dx
    pop ax
    ret

lg_acc_abs:
    test byte [lg_acc+3], 0x80
    jz .out
    call lg_acc_neg
.out:
    ret

; lg_acc_iszero - CF=1 if lg_acc is zero. 81.75: a fixed-point zero is four
; zero bytes and there is no negative zero to mask off.
lg_acc_iszero:
    push ax
    push bx
    mov ax, [lg_acc]
    or ax, [lg_acc+2]
    pop bx
    pop ax
    jnz .no
    stc
    ret
.no:
    clc
    ret

; lg_funcfinish - the accumulated lg_pacc/lg_pcnt -> the function's result
lg_funcfinish:
    push bx
    mov bx, [lg_pfid]
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
                                       ; lg_pacc, which for a non-summing fold
                                       ; is always 0.
    cmp bx, 77
    jae .stat
    call lg_pacc_to_a                 ; SUM/MIN/MAX/PRODUCT (and unknown):
    call lg_acc_store                 ; whatever was folded, zero if nothing
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
    mov cx, [lg_pcnt]
    cmp bx, 78                        ; VARP and STDEVP divide by n...
    je .popn
    cmp bx, 80
    je .popn
    dec cx                            ; ...VAR and STDEV by n-1, and a single
.popn:                                ; value therefore has no sample variance
    or cx, cx
    jg .statok
    mov byte [lg_evalerr], LG_ERR_DIV0  ; #DIV/0! is Excel's own answer to
    xor ax, ax                        ; VAR of one number
    call lg_acc_int
    jmp .fout
.statok:
    push cx                           ; CX = the divisor, banked across the
    call lg_pacc_to_a                 ; arithmetic below
    call lg_pacc_to_b                 ; A = B = the sum
    call fx_mul                       ; A = sum * sum
    mov ax, [lg_pcnt]
    call fx_i2b
    call fx_div                       ; A = sum*sum/n
    call fx_a_to_b                    ; ...to B
    push si
    mov si, lg_pacc2                  ; A = the sum of squares
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
    call lg_acc_store                 ; lg_stbusy is not cleared here: lg_pfunc
    jmp .fout                         ; banks and restores it, so every exit
                                       ; path is covered and not just this one
.average:
    cmp word [lg_pcnt], 0
    jne .avgok
    xor ax, ax
    call lg_acc_int
    jmp .fout
.avgok:
    mov ax, [lg_pcnt]                 ; THE COUNT FIRST, THE SUM LAST, and the
    call fx_i2b                       ; order is the whole of this: fx_i2b is
    call lg_pacc_to_a                 ; `fx_i2a` + `fx_a_to_b`, so it goes
                                       ; THROUGH register A and overwrites it.
                                       ; Loaded the other way round, A held the
                                       ; count rather than the sum and every
                                       ; AVERAGE was n/n = 1 - AVERAGE(1..5)
                                       ; came back 1 while SUM/COUNT of the
                                       ; same range came back 3.
    call fx_div                       ; A REAL MEAN, not a truncated one:
                                       ; AVERAGE(1,2) is 1.5 where the integer
                                       ; evaluator gave 1
    call lg_acc_store
    jmp .fout
.count:
    mov ax, [lg_pcnt]
    call lg_acc_int
    jmp .fout
.fout:
.out:
    pop bx
    ret

; lg_pfunc - in: SI right after a function NAME (lg_ident holds it),
; expecting '(' next; out: AX=value, SI advanced past the closing ')'.
; Saves/restores lg_pfid/lg_pacc/lg_pcnt/lg_phave around itself, so a
; function call nested inside another's argument list (SUM(A1,MAX(B1:B9)))
; cannot corrupt the outer accumulator.
lg_pfunc:
    push bx
    push cx
    push dx
    push word [lg_pfid]
    push word [lg_pacc+2]             ; its low word handed the outer fold the
    push word [lg_pacc]               ; inner call's accumulator back
    push word [lg_pcnt]
    push word [lg_phave]
    push word [lg_stbusy]             ; BANKED, not cleared on the way out: an
                                       ; error path that never reached
                                       ; lg_funcfinish would otherwise leave a
                                       ; variance fold marked live for the
                                       ; rest of the session, and every VAR
                                       ; after it would refuse (81.34.1)
    xor dx, dx                        ; DX = result; 0 covers every bad exit
    mov word [lg_pfid], 0xFFFF        ; THIS call's id, for .done's logical
                                      ; test (81.51); banked above, so a nested
                                      ; call's cannot outlive it
    call lg_pnest_enter               ; a nested call is a recursion point too
    jc .popout                        ; (81.3); too deep answers 0 + #VALUE!
    cmp byte [si], '('
    je .paren
    call lg_funcid                    ; =TRUE WITHOUT BRACKETS is Excel's
    cmp al, 20                        ; logical constant, and was #NAME? here
    je .bare                          ; (81.51). lg_ident still holds the word
    cmp al, 21
    jne .noparen
.bare:
    xor ah, ah
    mov [lg_pfid], ax
    neg al
    add al, 21                        ; TRUE (20) is 1, FALSE (21) is 0
    mov dx, ax
    call lg_acc_int
    jmp .typed
.paren:                               ; a bare word that resolved to no defined
    inc si                            ; name is #NAME?, exactly as in Excel -
    call lg_funcid                    ; lg_pident only routes one here once
    xor ah, ah                        ; lg_name_lookup has already declined it
    mov [lg_pfid], ax
    cmp ax, 0xFF                      ; ...and so is a CALL to a function this
    je .noname                        ; app does not have. Reading either as a
    cmp ax, 5
    je .doif
    cmp ax, 24                        ; CHOOSE answers a VALUE, not an integer
    je .dochoose                      ; (81.49) - IF's route, not lg_pspecial's
    cmp ax, 6
    je .donot
    cmp ax, 7
    je .doabs
    cmp ax, 109                        ; RAND() is nullary like NOW()
    je .dorand
    cmp ax, 106                        ; NOW() is nullary and reads the BIOS
    je .donow                          ; clock - nothing else here does either
    cmp ax, LG_FID_MDETERM              ; 143+ are the ARRAY/MATRIX functions
    jae .domatrix                      ; (81.67) - ABOVE LG_FID_CELL's own id,
                                        ; so this test runs first
    cmp ax, LG_FID_CELL                ; 142 is CELL (81.66)
    je .docell
    cmp ax, LG_FID_DATABASE            ; 131+ are the DATABASE functions
    jae .dodatabase                    ; (81.65) - ABOVE LG_FID_MACRO's own
                                        ; range, so this test runs FIRST or
                                        ; the macro check below would catch
                                        ; them too
    cmp ax, LG_FID_MACRO               ; 111+ are the MACRO functions (81.63),
    jae .domacro                       ; which act only for the step engine
    cmp ax, 93                         ; 93+ are the FINANCIAL functions, on
    jae .dofin                         ; the same layer one level up
    cmp ax, 81                         ; 81+ are the LOGARITHMS and their
    jae .dotrans                       ; friends, on the transcendental layer
    cmp ax, 25                         ; 81.75: 25..80 are INFORMATION, TEXT,
    jae .noname                        ; DATE, LOOKUP and the VARIANCE folds,
                                       ; every one of them cut
    cmp ax, 12                         ; 12+ are stage 3.0d's special forms:
    jae .dospecial                     ; fixed arity, parsed by lg_pspecial,
                                       ; not folded over ranges
.fold:
    mov [lg_pfid], ax
    push ax
    xor ax, ax
    cmp word [lg_pfid], 8              ; AND folds by ANDing in each value, so
    je .accone                         ; it must start true (1), not the false
    cmp word [lg_pfid], 10             ; (0) every other fold starts at.
    jne .accset                        ; PRODUCT starts at 1 for the same
.accone:                               ; reason - a running product seeded with
    mov ax, 1                          ; 0 can only ever be 0
.accset:
    call lg_int_to_pacc
    pop ax
    mov word [lg_pcnt], 0
    mov word [lg_phave], 0
    mov word [lg_pacc2], 0             ; the sum of squares starts at zero for
    mov word [lg_pacc2+2], 0           ; every fold; only the variance ones
.args:
    call lg_prange
    cmp byte [si], ','
    jne .argsdone
    inc si
    jmp .args
.argsdone:
    cmp byte [si], ')'
    jne .badtail
    inc si
    call lg_funcfinish
    mov dx, ax
    jmp .typed                        ; a fold's answer is a NUMBER: this went
                                      ; to .done, which left the type of the
                                      ; LAST CELL FOLDED standing, so a SUM
                                      ; whose range ended on a label stored
                                      ; the label's text as its result (81.51)
.badtail:
    mov byte [lg_evalerr], LG_ERR_VALUE ; an argument tail this grammar cannot
    jmp .done                          ; parse (=SUM(A1:A9^2)) must ERR, not
                                       ; answer with a partial fold (81.20)
.doif:
    call lg_pif
    mov dx, ax
    jmp .done
.dochoose:
    call lg_pchoose
    mov dx, ax
    jmp .done                         ; NOT .typed: a chosen TEXT stays text
.donot:
    call lg_pnot
    mov dx, ax
    jmp .done
.doabs:
    call lg_pabs
    mov dx, ax
    jmp .done
.dorand:
    call lg_prand
    jmp .nullary
.donow:
    call lg_pnow
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
    call lg_pspecial
    mov dx, ax
    jmp .typed
.noname:                              ; zero is how a typo silently becomes an
    call lg_skipargs                  ; answer, and the whole point of an error
.noparen:                             ; value is that it cannot be mistaken for
    mov byte [lg_evalerr], LG_ERR_NAME  ; one. Only the CALL form has arguments
.typed:                               ; to step over - `=FOO+1` has none, and
                                       ; skipping there would eat the `+1`
    mov byte [lg_curtype], LG_T_NUM   ; a call's RESULT is a number whatever it
                                       ; folded over: without this the TEXT tag
                                       ; left by the last cell a range touched
                                       ; would make `=SUM(A1:A9)*2` a #VALUE!
.done:
    cmp byte [lg_curtype], LG_T_ERR   ; A FUNCTION THAT ANSWERS TRUE OR FALSE
    je .notlog                        ; says so in the type (81.51), whatever
    call lg_fnlogical                 ; its own routine left there - NOT
    jnc .notlog                       ; sets none at all
    mov byte [lg_curtype], LG_T_BOOL
.notlog:
    call lg_pnest_leave
.popout:
    pop word [lg_stbusy]
    pop word [lg_phave]
    pop word [lg_pcnt]
    pop word [lg_pacc]
    pop word [lg_pacc+2]
    pop word [lg_pfid]
    mov ax, dx
    pop dx
    pop cx
    pop bx
    ret

; =============================================================================
; lg_pspecial (stage 3.0d) - the fixed-arity functions, ids 12 and up. These
; do not fold over a range the way SUM does; each parses exactly the arguments
; it takes and computes a value.
;
; THIS BLOCK USED TO LIST ISBLANK, ISNUMBER, ISNA AND NA AS "DELIBERATELY
; ABSENT". ALL FOUR SHIP - ids 25, 26, 31 and 33, dispatched by lg_pinfo a
; thousand lines down, which reads its argument through lg_pargclass and so
; has the reference the comment said had already been folded away.
;
; The reasons given were true when they were written and expired twice over:
; the first version said "all of these need the value model Stage 4.0 brings",
; which 4.0 delivered; the rewrite said the argument is folded before the
; function sees it, which lg_pargclass fixed. Neither edit removed the entry.
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
; lg_parg - one argument, as an integer. The special forms below are integer
; functions by nature; a fractional MOD or FACT is not a thing they mean.
; Truncation is the same rule TRUNC itself uses, so INT(3.7) is 3.
lg_parg:
    call lg_pcmp
    call lg_acc_toint
    ret

lg_pspecial:
    push bx
    push cx
    push dx
    push di
    mov di, ax                        ; DI holds the id: every lg_pcmp below
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
    jmp .zeroout                      ; 24 CHOOSE is lg_pchoose's (81.49) and
                                      ; the dispatcher never sends it here

; ---- POWER(x, y), on doubles ------------------------------------------------
; It parsed both arguments as 16-BIT INTEGERS and multiplied with `imul` - a
; stage 3.0d routine that nothing upgraded when the value model became a
; double, so POWER(1.12, 6) truncated its base to 1 and answered 1. It went
; unnoticed because the only thing that exercised it was `^` on whole numbers,
; which agreed; MIRR asking for (1.12)^6 is what finally showed it.
.dpower:
    call lg_pcmp
    call lg_acc_load_a
    cmp byte [si], ','
    jne .powbad
    inc si
    push si
    mov si, lg_acc
    mov bx, lg_tr0
    call lg_trcopy                    ; the base, across the second parse
    pop si
    call lg_pcmp
    call lg_acc_load_b
    push si
    mov si, lg_tr0
    call fx_unpack_a
    pop si
    call fx_pow
    jnc .dstore
    mov byte [lg_evalerr], LG_ERR_NUM
    call fx_azero
    jmp .dstore
.powbad:
    mov byte [lg_evalerr], LG_ERR_VALUE
    call fx_azero
    jmp .dstore

; ---- INT / TRUNC / SQRT / ROUND, on doubles ---------------------------------
; INT FLOORS and TRUNC cuts toward zero, which differ for negatives: Excel's
; INT(-3.7) is -4 and TRUNC(-3.7) is -3. While every value was an integer the
; two were indistinguishable and both were the identity; they are not any more.
.dfloor:
    call lg_pcmp
    call lg_acc_load_a
    call fx_floor
    jmp .dstore
.dtrunc:
    call lg_pcmp
    call lg_acc_load_a
    call fx_trunc
    jmp .dstore
.dsqrt:
    call lg_pcmp
    test byte [lg_acc+3], 0x80        ; the sign bit of the packed double: a
    jz .sqrtok                        ; negative has no real square root, and
    mov byte [lg_evalerr], LG_ERR_NUM ; Excel says #NUM! rather than 0
.sqrtok:
    call lg_acc_load_a
    call fx_sqrt                      ; a REAL root: SQRT(2) is 1.414213562,
    jmp .dstore                       ; where the integer version gave 1
.dround:
    call lg_pcmp                      ; the value, banked across the second
    call lg_vpush                     ; argument's parse
    xor cx, cx
    cmp byte [si], ','
    jne .dround1                      ; ROUND(x) with no count means 0 places
    inc si
    call lg_parg                      ; the digit count IS a whole number
    mov cx, ax
.dround1:
    call lg_binop_pre                 ; A = the value again
    call fx_round
.dstore:
    call lg_acc_store
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
    mov ax, [lg_evrow]                ; ROW / COLUMN answer for the cell being
    cmp di, 22                        ; EVALUATED, not the one selected - a
    je .ctx1                          ; formula's own position is what Excel
    mov ax, [lg_evcol]                ; means by these
.ctx1:
    inc ax                            ; 1-based, as displayed
    jmp .close

; ---- the one- and two-argument forms ----------------------------------------
.arg1:
    call lg_parg                      ; every id from here takes a first value
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
    call lg_isqrt                     ; 17 SQRT
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
    mov byte [lg_evalerr], LG_ERR_NUM ; range a word can hold: #NUM! either
    jmp .zeroout                      ; way, which is what Excel reports

.two:
    cmp byte [si], ','
    jne .zeroout
    inc si
    push bx                           ; first argument, across the second parse
    call lg_parg
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
    call lg_acc_int                   ; these thirteen are integer functions by
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

; lg_isqrt - in: AX = n; out: AX = floor(sqrt(n)), 0 for n < 0.
; Successive odd numbers: 1+3+5+... = k^2, so subtracting them until AX runs
; out counts the root. At most 181 iterations for a signed word, and it needs
; no division at all.
lg_isqrt:
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
; above lg_pspecial listed ISBLANK, ISNUMBER and ISNA as deliberately absent -
; a version of any of them that returned a plausible constant would have been
; worse than its absence. These two routines are what ends that (81.23).
;
; lg_pargref - is the argument at SI a reference AND NOTHING ELSE? It is
; deliberately strict about "nothing else": ISNUMBER(A1+1) is a question about
; the sum, not about A1, so a reference only counts when the ',' or the ')'
; follows it immediately.
;
; in:  SI at the start of an argument
; out: CF=1 - lg_arg1col/lg_arg1row/lg_arg2col/lg_arg2row hold it (a single
;             cell puts the same cell in both corners), lg_refarea = 1 for an
;             A1:B9 form, and SI is past it
;
; THESE ARE NOT lg_r1col/lg_r2col, AND THE DISTINCTION IS NOT COSMETIC. Those
; four are lg_foldrange's loop bounds, read on EVERY iteration of its walk -
; so a cell inside the range that itself calls an information function used to
; overwrite the bounds mid-walk. `=SUM(A5:A9)` over a column of ISBLANK()
; formulas answered 1: A5's own argument reset the corners to A3, and the
; second iteration compared row 4 against row 2 and stopped. The right answer
; on the first cell and then nothing, with no error anywhere.
;
; The caller must still CONSUME these before evaluating anything, because a
; nested reference argument overwrites them in turn. lg_pargclass reads them
; into AX/BX on the line before its lg_getcell2 call for exactly that reason.
;      CF=0 - not a reference; SI is UNCHANGED, exactly as lg_pcellref leaves
;             it, and the caller parses an ordinary expression instead
; =============================================================================

section LG_MODSEC                      ; 81.62: lg_pargclass, ISxxx's classifier
; =============================================================================
; lg_pargclass - one argument, CLASSIFIED rather than folded.
;
; out: lg_argtype  = the LG_T_* the argument IS. LG_T_BLANK for a cell that
;                    does not exist, which is the distinction this whole
;                    routine exists to make
;      lg_argaux   = its error code, 0 when it is not an error
;      lg_argisref = 1 when the argument was a bare reference
;      lg_acc      = its value, for the callers that want the number too
;      SI past the argument
;
; THE ARGUMENT'S ERROR IS THIS FUNCTION'S ANSWER, NOT THE SHEET'S. lg_evalerr
; is banked across the argument and put back afterwards, so ISERROR(1/0) is
; TRUE rather than being a #DIV/0! itself - trapping the error is the entire
; point of asking. Every other caller in this file WANTS an argument's error
; to spread (that is what puts one #DIV/0! at the bottom of a column), which
; is why the banking lives here and not in lg_getcell2.
; =============================================================================

; =============================================================================
; THE FINANCIAL FAMILY IS CHART.OVL'S THIRD TENANT (SPEC.md 82.16.10): from
; here to lg_trcopy it is module code, bracketed where it stands the way the
; file formats were (82.16.9) - and since 81.62 lg_pargclass above and
; lg_ptrans below are in the same block. Every call out is SHOUT; the one way in is the
; resident stub lg_pfin, beside the other three. The three constants below
; stay in .text, because what reads them is resident fx_* code through DS.
; =============================================================================
section LG_MODSEC

section .text                       ; ...DATA, and the resident fx_* routines
                                    ; read it through DS (68.10 rule 2)
; 81.75: lg_c_r10 / lg_c_r01 / lg_c_eps and the five routines that stood here
; - lg_fntyv, lg_fnsetty, lg_fnfac, lg_pfargs - were the FINANCIAL family's
; shared half: the annuity factor, the type flag and the argument parser. The
; family went in Tier 1 and these stayed behind with no caller at all.

lg_trcopy:
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
; lg_pinfo - the INFORMATION functions, ids 25 and up. Every one of these is a
; question about what an argument IS rather than what it is worth, so each is
; one lg_pargclass call and a comparison.
;
; in: AX = the id, SI just past '('. out: AX = the value, SI past ')'.
; =============================================================================
; lg_lkstrcmp / lg_lkup - case-insensitive string compare, AX = -1/0/1.
; 81.75: these came out of the LOOKUP family with the rest of it and had to go
; straight back: the general comparison operator uses them whenever both sides
; of a `<` or `=` are text, which has nothing to do with lookups.
lg_lkstrcmp:
    push bx
    push cx
    push si
    push di
.c:
    mov al, [si]
    mov bl, [di]
    call lg_lkup
    xchg al, bl
    call lg_lkup
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

lg_lkup:
    cmp al, 'a'
    jb .out
    cmp al, 'z'
    ja .out
    sub al, 32
.out:
    ret

lg_ins_at:
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
; lg_group3 - thousands separators through lg_numbuf's INTEGER part, however
; many it takes.
;
; IT REPLACES lg_comma_ins, WHICH HAD SILENTLY BECOME WRONG. That routine's
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
lg_group3:
    push ax
    push bx
    push cx
    push si
    push di
    mov si, lg_numbuf
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
    call lg_ins_at
    jmp .loop
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret


section LG_MODSEC                      ; 81.62: a less-used function, CHART.OVL
; -----------------------------------------------------------------------------
; lg_dollar_ins - '$' in front of lg_numbuf's digits but AFTER a leading '-',
; so -123 in a currency format is "-$123" and not "$-123".
; -----------------------------------------------------------------------------
lg_dollar_ins:
    push ax
    push di
    mov di, lg_numbuf
    cmp byte [di], '-'
    jne .here
    inc di
.here:
    mov al, '$'
    SHOUT lg_ins_at
    pop di
    pop ax
    ret

section .text

section LG_MODSEC                      ; 81.62: a less-used function, CHART.OVL

section .text
; -----------------------------------------------------------------------------
; lg_matchat - in: SI, DI; out: CF=1 if the string at DI is a prefix of the
; one at SI. Both preserved.
;
; AN EMPTY NEEDLE NEVER MATCHES, deliberately: SUBSTITUTE walks the text one
; character at a time and advances by the needle's length on a hit, so an
; empty one that matched would advance by nothing and never terminate.
; -----------------------------------------------------------------------------
lg_matchat:
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

section LG_MODSEC                      ; 81.62: a less-used function, CHART.OVL


section .text
; =============================================================================
; THE STRING STACK (stage 4.5)
;
; A text function with more than one string argument has to hold the first one
; while the second is parsed - and parsing the second can reach any text
; function again, which writes lg_sacc. lg_sacc alone is therefore not enough,
; and neither is a second fixed buffer: `=FIND(A1, LEFT(A2,3))` would have the
; inner LEFT overwrite the outer FIND's banked needle.
;
; This is NOT the machine stack. SPEC.md 20.6 rule 6 gives a task 384 bytes
; and says in as many words: no deep recursion, no big stack buffers. Banking
; 65 bytes per argument per frame there, under six levels of lg_eval_cell
; recursion, is exactly the buffer that rule forbids. So the bank is bss, it
; is bounded at LG_SSTK_N levels, and running out is a #VALUE! rather than a
; silent overwrite.
; =============================================================================
; lg_smove - copy LG_STR_MAX+1 bytes SI -> DI, both DS-relative. Not `rep
; movsb`, because ES belongs to the cell segment through most of this file.
lg_smove:
    push ax
    push cx
    push si
    push di
    mov cx, LG_STR_MAX + 1
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

; lg_sslot - in: AX = depth from the TOP (0 = the string banked last)
; out: SI = its address. Reading past the bottom gives the EMPTY string, not
; whatever bss lies below it.
lg_sslot:
    push ax
    push dx
    mov si, lg_snull
    mov dx, [lg_sstk_sp]
    inc ax
    cmp ax, dx
    ja .out
    sub dx, ax
    mov ax, dx
    mov dx, LG_STR_MAX + 1
    mul dx
    add ax, lg_sstk
    mov si, ax
.out:
    pop dx
    pop ax
    ret

; lg_spush - bank lg_sacc. out: CF=1 the stack is full, and #VALUE! is raised
lg_spush:
    push ax
    push dx
    push si
    push di
    mov ax, [lg_sstk_sp]
    cmp ax, LG_SSTK_N
    jae .full
    inc word [lg_sstk_sp]
    mov dx, LG_STR_MAX + 1
    mul dx                            ; DX:AX, and LG_SSTK_N * 65 is far
    add ax, lg_sstk                   ; inside a segment, so DX is zero
    mov di, ax
    mov si, lg_sacc
    call lg_smove
    clc
    jmp .out
.full:
    mov byte [lg_evalerr], LG_ERR_VALUE
    stc
.out:
    pop di
    pop si
    pop dx
    pop ax
    ret

; lg_spop - drop the top bank
lg_spop:
    cmp word [lg_sstk_sp], 0
    je .out
    dec word [lg_sstk_sp]
.out:
    ret

; lg_srestore - put the top bank back in lg_sacc and drop it
lg_srestore:
    push ax
    push si
    push di
    xor ax, ax
    call lg_sslot
    mov di, lg_sacc
    call lg_smove
    call lg_spop
    pop di
    pop si
    pop ax
    ret


section LG_MODSEC                      ; 81.62: a less-used function, CHART.OVL

; lgm_vpush / lgm_binop_pre - lg_vpush and lg_binop_pre for the module (81.62).
; Those two move lg_acc on and off their CALLER's stack past their own return
; address, so behind a far call and a shim they would bank it on the shim's
; frame and retf into the value. The stack work has to happen here; the fp
; loading, which touches no stack, calls back as lg_binop_ld
lgm_vpush:
    ; STKBALANCE-NET: +2 - 81.75: TWO WORDS now, not four; banks lg_acc on the CALLER's stack for a binary operator; lgm_binop_pre takes it off
    pop ax
    push word [lg_acc+2]
    push word [lg_acc]
    push ax
    ret
lgm_binop_pre:
    ; STKBALANCE-NET: -4 - the other half of lgm_vpush - one call each, always paired
    pop ax
    pop word [lg_lhs]
    pop word [lg_lhs+2]
    push ax
    SHOUT lg_binop_ld
    ret


section .text


; -----------------------------------------------------------------------------
; lg_acc_fromudw - AX, an unsigned word, becomes lg_acc. fx_i2a is signed and
; would make 46265 negative.
; -----------------------------------------------------------------------------
lg_acc_fromudw:
    push ax
    mov [fx_q+0], ax
    mov word [fx_q+2], 0
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    call fx_u32_to_a
    call lg_acc_store
    pop ax
    ret

; lg_isleap - in: lg_dt_ly = the year; out: CF=1 if it is a leap year.
; The full rule, not "divisible by four": 1900 is not a leap year and 2000 is,
; and both are inside the range this app covers.
lg_isleap:
    push ax
    push bx
    push dx
    mov ax, [lg_dt_ly]
    mov bx, 400
    xor dx, dx
    div bx
    or dx, dx
    jz .yes                           ; a multiple of 400 always is
    mov ax, [lg_dt_ly]
    mov bx, 100
    xor dx, dx
    div bx
    or dx, dx
    jz .no                            ; a multiple of 100 (but not 400) is not
    mov ax, [lg_dt_ly]
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

; lg_yearlen - in: AX = year; out: AX = 365 or 366
lg_yearlen:
    mov [lg_dt_ly], ax
    call lg_isleap
    mov ax, 365
    jnc .out
    inc ax
.out:
    ret

; lg_monlen - in: AX = month 1..12, BX = year; out: AX = days in it
lg_monlen:
    push bx
    push si
    cmp ax, 1
    jb .bad
    cmp ax, 12
    ja .bad
    mov si, ax
    dec si
    mov [lg_dt_ly], bx
    xor bh, bh
    mov bl, [lg_dt_mlen + si]
    mov ax, bx
    cmp si, 1                         ; February
    jne .out
    call lg_isleap
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
; lg_ymd_to_ser - in: lg_dt_y/m/d; out: AX = the serial, CF=1 if the date is
; outside 1900-01-01 .. 2079-06-06 (what an unsigned word holds).
;
; The month is allowed to run outside 1..12 and the day outside a month's
; length, exactly as Excel's DATE() does: DATE(1990,13,1) is January 1991 and
; DATE(1990,1,32) is 1 February. Rolling the month first and then simply
; ADDING the days is what makes both fall out for free.
; -----------------------------------------------------------------------------
lg_ymd_to_ser:
    push bx
    push cx
    push dx
.mroll:
    mov ax, [lg_dt_m]
    cmp ax, 1
    jge .mrollhi
    add word [lg_dt_m], 12            ; month 0 is December of the year before
    dec word [lg_dt_y]
    jmp .mroll
.mrollhi:
    cmp ax, 12
    jle .mdone
    sub word [lg_dt_m], 12
    inc word [lg_dt_y]
    jmp .mroll
.mdone:
    mov ax, [lg_dt_y]
    cmp ax, 1900
    jb .bad
    cmp ax, 2080
    ja .bad
    xor cx, cx                        ; CX = whole days before this year
    mov word [lg_dt_ys], 1900
.yloop:
    mov ax, [lg_dt_ys]
    cmp ax, [lg_dt_y]
    jae .ydone
    call lg_yearlen
    add cx, ax
    inc word [lg_dt_ys]
    jmp .yloop
.ydone:
    mov word [lg_dt_ms], 1
.mloop:
    mov ax, [lg_dt_ms]
    cmp ax, [lg_dt_m]
    jae .mdone2
    mov bx, [lg_dt_y]
    call lg_monlen
    add cx, ax
    inc word [lg_dt_ms]
    jmp .mloop
.mdone2:
    add cx, [lg_dt_d]                 ; the day, which may itself overflow the
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
; lg_pnow - NOW(), id 106. The serial date plus the fraction of the day, which
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
; lg_prand - RAND(), id 109. A number in [0,1).
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
lg_prand:
    push bx
    push cx
    push dx
    cmp word [lg_rndhi], 0            ; unseeded? the very first RAND() of a
    jne .step                         ; session pays for the BIOS call
    cmp word [lg_rndlo], 0
    jne .step
    xor ah, ah
    int 0x1a                          ; CX:DX = ticks since midnight
    mov [lg_rndhi], cx
    mov [lg_rndlo], dx
    or dx, cx
    jnz .step
    mov word [lg_rndlo], 1            ; a clock reading exactly zero would
.step:                                ; leave the generator stuck at zero
    mov ax, [lg_rndlo]
    mov cx, 25173
    mul cx                            ; DX:AX = lo * 25173
    mov bx, dx                        ; BX = the carry into the high word
    push ax
    mov ax, [lg_rndhi]
    mul cx                            ; only the low half of this matters
    add ax, bx
    mov bx, ax                        ; BX = the new high word, pre-increment
    pop ax
    add ax, 13849
    adc bx, 0
    mov [lg_rndlo], ax
    mov [lg_rndhi], bx
    mov ax, 256                       ; /256 TWICE = /65536, which is what a
    call lg_acc_int                   ; 16-bit word cannot hold in one go.
    call lg_acc_load_b                ; THE DIVISOR IS BUILT FIRST, because
    mov ax, bx                        ; lg_acc_int goes through fx_i2a and
    call lg_acc_fromudw               ; lg_acc_fromudw through fx_u32_to_a -
    call lg_acc_load_a                ; BOTH WRITE A. Loading the value into A
    call fx_div                       ; and then building 256 overwrote it, and
    call fx_div                       ; RAND() answered a constant 256/256 = 1
    call lg_acc_store                 ; (81.42.1 again, verbatim). B is loaded
                                      ; once for both divides: fpx_div and
                                      ; fps_div stage from memory and write
                                      ; back A alone, so B survives one
    xor ax, ax                        ; LG_T_NUM
    inc ax
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; lg_bios_ymd - the calendar date from the BIOS into lg_dt_y/m/d.
; out: CF=1 if there is no usable clock. Every other register preserved.
;
; AH=04h answers CH/CL = century and year and DH/DL = month and day, all packed
; BCD. CX and DX are POISONED with 0xFFFF first and checked after, because a
; BIOS without the service can return CF clear having touched nothing - the
; sentinel is the only thing that catches that, and it is the check the kernel's
; own clk_rtc_read makes for the same reason.
; -----------------------------------------------------------------------------
lg_bios_ymd:
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
    call lg_bcd2bin
    jc .bad
    mov bl, al                        ; the century
    mov al, cl
    call lg_bcd2bin
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
    mov [lg_dt_y], ax
    mov al, dh
    call lg_bcd2bin
    jc .bad
    xor ah, ah
    or ax, ax
    jz .bad
    cmp ax, 12
    ja .bad
    mov [lg_dt_m], ax
    mov al, dl
    call lg_bcd2bin
    jc .bad
    xor ah, ah
    or ax, ax
    jz .bad
    cmp ax, 31
    ja .bad
    mov [lg_dt_d], ax
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

lg_pnow:
    push bx
    push cx
    push dx
    push si
    call lg_bios_ymd                  ; -> lg_dt_y/m/d, CF=1 if no clock
    jc .na
    call lg_ymd_to_ser                ; -> AX = the whole days
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
    call lg_bcd2bin
    jc .napop
    cmp al, 23
    ja .napop
    xor bh, bh
    mov bl, al                        ; BX = hours
    mov al, cl
    call lg_bcd2bin
    jc .napop
    cmp al, 59
    ja .napop
    push bx
    xor ah, ah
    mov cx, ax                        ; CX = minutes
    mov al, dh
    call lg_bcd2bin
    pop bx
    jc .napop
    cmp al, 59
    ja .napop
    xor ah, ah
    mov dx, ax                        ; DX = seconds
    call lg_hms_to_acc                ; lg_acc = the fraction of the day
    call lg_acc_load_b                ; ...into B, WHICH MUST COME FIRST:
    pop ax                            ; lg_acc_fromudw goes through fx_u32_to_a
    call lg_acc_fromudw               ; and CLOBBERS A, so a fraction parked
    call lg_acc_load_a                ; there is gone by the add. It answered
    call fx_add                       ; twice the serial, both operands being
                                      ; the day count (81.42.1)
    call lg_acc_store
    clc
    jmp .out
.napop:
    pop ax
.na:
    mov byte [lg_evalerr], LG_ERR_NA  ; no usable clock: #N/A, and ISNA can
    stc                               ; see it
.out:
    pop si
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; lg_bcd2bin - AL packed BCD -> AL binary. CF=1 if either nibble is not a
; decimal digit, which is how a clock that is not running is caught: it answers
; 0xFF or 0x99 rather than failing the call.
; -----------------------------------------------------------------------------
lg_bcd2bin:
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
; lg_pdate - the DATE and TIME functions, ids 58 and up.
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
lg_hms_to_acc:
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
    call lg_acc_store
    call lg_dt_86400_b
    call lg_acc_load_a
    call fx_div                       ; a fraction of one day
    call lg_acc_store
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; lg_dt_86400_b - B = 86400.0, the seconds in a day. Clobbers A.
lg_dt_86400_b:
    push ax
    mov word [fx_q+0], 86400 & 0xFFFF
    mov word [fx_q+2], 86400 >> 16
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    call fx_u32_to_a
    call fx_a_to_b
    pop ax
    ret


; lg_dt_tmp_store / lg_dt_tmp_load_b - park fp A in bss and bring it back as
; B. lg_vpush cannot be used here: it banks on the CALLER's stack and pairs
; with exactly one lg_binop_pre (81.25.3).


; lg_pif - IF(cond,then,else): the one function that does not fold - its
; branches are not even both evaluated the way a real spreadsheet expects
; only ONE side effect-free path to matter, but here both sides just get
; parsed unconditionally (the parse is what advances SI) and the condition
; alone picks which value survives. Parsing IS evaluation here, and it has
; one side effect since errors landed: a raise of the sticky lg_evalerr - so
; the raise of the branch the condition did NOT pick is banked and unraised
; (81.20), or =IF(B1=0,0,A1/B1) answered #DIV/0! for the case it guards.
; in: SI right after "IF("; out: AX=result, SI advanced past ')' if found
lg_pif:
    push bx
    push cx
    call lg_pcmp                      ; the condition, kept as a truth value
    call lg_acc_iszero                ; rather than as a number
    mov bx, 0
    jc .condfalse
    mov bx, 1
.condfalse:
    cmp byte [si], ','
    jne .bad
    inc si
    mov al, [lg_evalerr]              ; banked across the then-parse, and
    mov ah, [lg_macro_exec]           ; restored if then was NOT chosen - and
    push ax                           ; the branch the condition did NOT pick
    or bx, bx                         ; runs no MACRO command (81.63): parsed,
    jnz .thenrun                      ; as it has to be, but inert - or
    mov byte [lg_macro_exec], 0       ; IF(H7=3,BREAK()) broke at 1
.thenrun:
    call lg_pcmp                      ; the then-value, banked whole
    pop ax
    mov [lg_macro_exec], ah
    or bx, bx
    jnz .thenkept
    mov [lg_evalerr], al
.thenkept:
    call lg_vpush                     ; the then-VALUE...
    mov al, [lg_curtype]              ; ...AND WHAT KIND OF VALUE IT IS, which
    mov ah, [lg_curaux]               ; lg_vpush does not carry. Without this
    push ax                           ; the else-parse left ITS type behind, and
    cmp al, LG_T_TEXT                 ; a TEXT then-value's characters are not
    jne .nottext                      ; in lg_acc at all but in lg_sacc, which
    call lg_spush                     ; the else-parse overwrites: so
.nottext:                             ; =IF(A1>1,"big","small") answered
    cmp byte [si], ','                ; "small" for every A1 (81.10.10 found
    jne .badpop                       ; it). Banked on the string stack, the
    inc si                            ; way & banks its left operand
    mov al, [lg_evalerr]              ; ...and the same for the else-parse
    mov ah, [lg_macro_exec]
    push ax
    or bx, bx
    jz .elserun
    mov byte [lg_macro_exec], 0
.elserun:
    call lg_pcmp                      ; the else-value, left in lg_acc
    pop ax
    mov [lg_macro_exec], ah
    or bx, bx
    jz .elsekept
    mov [lg_evalerr], al
.elsekept:
    pop cx                            ; CL/CH: the then-value's type and aux
    or bx, bx
    jz .dropthen                      ; false: lg_acc already holds the else
    mov [lg_curtype], cl              ; true: the then-value back WHOLE - its
    mov [lg_curaux], ch               ; kind, and its four bytes restored as
    pop word [lg_acc]                 ; they were banked rather than through
    pop word [lg_acc+2]               ; the arithmetic layer, which a TEXT
    cmp cl, LG_T_TEXT
    jne .out
    call lg_srestore                  ; ...and its characters
    jmp .out
.dropthen:
    add sp, 4                         ; 81.75: FOUR, not eight - lg_vpush banks
                                      ; a fixed-point value now. The banked
                                      ; then-value is not wanted,
    cmp cl, LG_T_TEXT                 ; and nor are its characters: a bank
    jne .out                          ; left on the string stack would shift
    call lg_spop                      ; every string after it by one
    jmp .out
.badpop:
    add sp, 6                         ; 81.75: six - four of value and two of
                                      ; type. The banked value, and its type...
    cmp al, LG_T_TEXT                 ; (AL still is: nothing since has
    jne .bad                          ; touched it)
    call lg_spop                      ; ...and any characters
.bad:
    xor ax, ax
    call lg_acc_int
.out:
    cmp byte [si], ')'
    jne .noclose
    inc si
.noclose:
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; lg_pchoose - CHOOSE(index, v1, v2, ...) (SPEC.md 81.49)
; in: SI right after "CHOOSE("; out: the chosen value WHOLE - lg_acc,
; lg_curtype, and lg_sacc when it is text - and SI past ')'. AX is its
; truncation, for the callers that still want a word.
;
; IT WAS AN INTEGER FUNCTION: parsed in lg_pspecial beside MOD and FACT, every
; value taken through lg_parg as a word and the answer handed back through
; lg_acc_int. So =CHOOSE(2,1.5,2.5) answered 2, any fractional cell it picked
; lost its fraction, and a text value came back 0. Excel's CHOOSE returns the
; value it picked, whatever it is.
;
; THE CHOSEN VALUE IS NOT BANKED, because nothing is parsed after it: the
; values before it are parsed and dropped (their raise of the sticky error
; does not stand - 81.20), the chosen one is parsed and left where the parser
; put it, and the rest are STEPPED OVER by lg_skipargs, never evaluated -
; which is also Excel's behaviour, and why a #DIV/0! in an unchosen argument
; after the chosen one never mattered. An index outside 1..n is #VALUE!.
; -----------------------------------------------------------------------------
lg_pchoose:
    push bx
    push cx
    call lg_parg                      ; the 1-based index, truncated as Excel
    mov bx, ax                        ; truncates it
    xor cx, cx
.next:
    cmp byte [si], ','
    jne .short                        ; the list ran out first
    inc si
    inc cx
    cmp cx, bx
    je .chosen
    mov al, [lg_evalerr]              ; banked across an unchosen value, and
    mov ah, [lg_macro_exec]           ; put back after it - which runs no
    push ax                           ; macro command, as IF's does not (81.63)
    mov byte [lg_macro_exec], 0
    call lg_pcmp
    pop ax
    mov [lg_evalerr], al
    mov [lg_macro_exec], ah
    jmp .next
.chosen:
    call lg_pcmp                      ; its value, its type, its text - and its
    call lg_skipargs                  ; raise stands. The rest are stepped over
    xor ax, ax                        ; to the matching ')', and SI past it
    cmp byte [lg_curtype], LG_T_NUM
    jne .out
    call lg_acc_toint
    jmp .out
.short:
    mov byte [lg_evalerr], LG_ERR_VALUE
    xor ax, ax
    call lg_acc_int
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    pop cx
    pop bx
    ret

; lg_pnot - NOT(x): logical negation
; in: SI right after "NOT("; out: AX=1 or 0, SI advanced past ')' if found
lg_pnot:
    call lg_pcmp
    call lg_acc_iszero
    jc .true
    xor ax, ax
    call lg_acc_int
    jmp .close
.true:
    mov ax, 1
    call lg_acc_int
.close:
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    ret

; lg_pabs - ABS(x): absolute value
; in: SI right after "ABS("; out: AX=|x|, SI advanced past ')' if found
lg_pabs:
    call lg_pcmp
    call lg_acc_abs                   ; 81.75: two's complement (see there)
.close:
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    ret

; =============================================================================
; MACROS, the package's half (SPEC.md 81.63): the Run dialog, the door, and
; the two ways a paused run comes back. The engine and every macro function
; are CHART.OVL's - the module's own header, at lgm_pmacro, is the design.
; =============================================================================
LG_MACRO_MAXSTEPS equ 10000          ; a runaway loop ENDS rather than hangs:
                                     ; the system is cooperative and the step
                                     ; loop yields to nothing (81.8). It was
                                     ; 5000, before a macro could loop
LG_FID_MACRO   equ 111               ; the first macro function's id...
LG_FID_DATABASE equ 131              ; the first DATABASE function's id
                                     ; (81.65) - one past the last macro
                                     ; command (111 + 20)
LG_FID_CELL     equ 142              ; CELL's id (81.66) - one past the last
                                     ; DATABASE function (131 + 11)
LG_FID_MDETERM  equ 143              ; the first ARRAY/MATRIX function's id
                                     ; (81.67) - one past CELL
LG_FID_MINVERSE equ 144
LG_FID_MMULT    equ 145
LG_FID_TRANSPOSE equ 146
LG_FID_LINEST   equ 147
LG_FID_LOGEST   equ 148
LG_FID_TREND    equ 149
LG_FID_GROWTH   equ 150
LG_MF_ACTCELL  equ 14                ; ...and ACTIVE.CELL's, counted from it
LG_MC_NONE     equ 0                 ; what a step asked for (lg_macro_ctl):
LG_MC_GOTO     equ 1                 ; the next cell is [lg_macro_ncol/nrow]
LG_MC_STOP     equ 2                 ; RETURN, HALT, or a macro error
LG_MC_PAUSEN   equ 3                 ; ALERT: wait, then the next cell
LG_MC_PAUSEH   equ 4                 ; INPUT: wait, then THIS cell again
LG_MC_SKIP     equ 5                 ; on past the NEXT of the loop at ncol/nrow
LG_MW_START    equ 1                 ; what a resume means (lg_macro_wait)
LG_MW_ALERT    equ 2
LG_MW_INPUT    equ 3
LG_MLOOPS      equ 4                 ; FOR/WHILE frames, nested
LG_LF_KIND     equ 0                 ; a frame: 1 FOR / 2 WHILE,
LG_LF_COL      equ 1                 ; its own cell,
LG_LF_ROW      equ 3
LG_LF_CCOL     equ 5                 ; FOR's counter cell,
LG_LF_CROW     equ 7
LG_LF_END      equ 9                 ; its end and step, doubles
LG_LF_STEP     equ 17
LG_LF_SZ       equ 25
LG_MPROMPT     equ 30                ; INPUT's prompt, as the dialog shows it
LG_MSTMSG      equ 40                ; MESSAGE's text on the status bar
section LG_MODSEC                      ; 81.65: DAVERAGE...DVARP, CHART.OVL


section .text

; lg_funcid - in: lg_ident; out: AL = the function's id, or 0xFF unknown.
; TABLE-DRIVEN as of stage 3.0d: the id IS the entry's index in lg_functab, so
; adding a function is one string and one table word. It was an unrolled
; compare chain of five lines per function, which at ten functions was merely
; verbose and at twenty-five would have been a hundred lines of boilerplate
; with a hand-written id on each - exactly the shape that drifts.
lg_funcid:
    push bx
    push cx
    push si
    push di
    xor cx, cx
    mov bx, lg_functab
.loop:
    mov di, [bx]
    or di, di
    jz .unknown                       ; the table's 0 terminator
    mov si, lg_ident
    call lg_streq
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
; lg_chktext - the operand lg_curtype describes is TEXT, and something
; arithmetic is about to happen to it: raise #VALUE!. Excel's own answer, and
; the reason it is raised HERE rather than in lg_getcell2 is that a bare `=B4`
; must still SHOW the label, and SUM must still skip it - only an operator
; makes a label a mistake.
; -----------------------------------------------------------------------------
lg_chktext:
    cmp byte [lg_curtype], LG_T_TEXT
    jne .out
    mov byte [lg_evalerr], LG_ERR_VALUE
.out:
    ret

; -----------------------------------------------------------------------------
; lg_skipargs - SI is just past an unknown function's '('; leave it just past
; the matching ')'. Counting depth rather than scanning for the first ')' is
; what keeps `=FOO(SUM(A1:A2))` from leaving a stray parenthesis behind for
; the rest of the parse to trip over.
; -----------------------------------------------------------------------------
lg_skipargs:
    push cx
    mov cx, 1
.loop:
    mov al, [si]
    or al, al
    jz .out                           ; end of the formula: unbalanced, and
    inc si                            ; lg_paren_ok already refuses those at
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
    mov al, [si]                      ; rule lg_paren_ok already kept: counted,
    or al, al                         ; the ')' in =FOO("a)")+1 closed FOO
    jz .out                           ; early and left "+1 as the tail. A
    inc si                            ; doubled quote closes and reopens, which
    cmp al, '"'                       ; comes out right (81.49)
    jne .instr
    jmp .loop

; -----------------------------------------------------------------------------
; lg_str_load - in: AX = an offset in lg_txtseg; copies that NUL string into
; lg_sacc, clipped to LG_STR_MAX. Every register preserved.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; lg_txtslot - in: ES:DI = a cell record whose type is LG_T_TEXT
; out: AX = the arena offset its characters live at.
;
; A plain LABEL keeps them in LG_C_FOFF. A FORMULA whose result is text keeps
; LG_C_FOFF for its own SOURCE and the result in LG_C_VAL (81.22.1), so
; reading FOFF for both loads the formula's own text - which is what the cell
; would draw on a pass-cache hit, with no evaluation to correct it.
;
; It is a proc rather than four inline instructions because the caller needs
; it inside a push/pop pair, and a label there is a chunk boundary stkbalance
; walks into without the push - which reads as an unbalanced path.
; -----------------------------------------------------------------------------
lg_txtslot:
    mov ax, [es:di+LG_C_FOFF]
    test byte [es:di+4], 1            ; HASFORMULA
    jz .out
    mov ax, [es:di+LG_C_VAL]
.out:
    ret

lg_str_load:
    push ax
    push cx
    push si
    push di
    push es
    mov es, [lg_txtseg]
    mov si, ax
    mov di, lg_sacc
    mov cx, LG_STR_MAX
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
; lg_str_store - ES:DI = a cell record whose result is TEXT; put lg_sacc into
; that cell's result slot, claiming the slot on first use (81.22.1).
; out: CF=1 if the arena had no room, in which case the cell keeps whatever it
; had. Every register preserved.
; -----------------------------------------------------------------------------
lg_str_store:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    cmp byte [es:di+LG_C_TYPE], LG_T_TEXT  ; VAL IS ONLY A SLOT OFFSET IF THE
    jne .newslot                      ; CELL ALREADY HELD TEXT. On a formula
    mov ax, [es:di+LG_C_VAL]          ; that returned a number last time it is
    or ax, ax                         ; the low word of a DOUBLE, and treating
    jnz .haveslot                     ; that as an arena offset writes 64 bytes
.newslot:                             ; wherever the mantissa happens to point
    mov ax, [lg_txtlen]               ; claim one: LG_STR_MAX+1, once, for the
    mov bx, ax                        ; life of the cell - the arena never
    add bx, LG_STR_MAX + 1            ; frees, so a slot PER RECALCULATION
    cmp bx, LG_TXT_CAP                ; would empty it in seconds
    ja .noroom
    mov [lg_txtlen], bx
    mov [es:di+LG_C_VAL], ax          ; the union's first word IS the offset
    mov word [es:di+LG_C_VAL+2], 0
.haveslot:
    mov di, ax                        ; DI = the slot, ES = the arena
    mov es, [lg_txtseg]
    mov si, lg_sacc
    mov cx, LG_STR_MAX
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
; lg_str_cat - append the NUL string at SI to lg_sacc, clipped to LG_STR_MAX.
; -----------------------------------------------------------------------------
lg_str_cat:
    push ax
    push cx
    push si
    push di
    mov di, lg_sacc
    mov cx, LG_STR_MAX
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

; lg_streq - in: SI, DI (two NUL-terminated strings); out: CF=1 equal
lg_streq:
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
; lg_clearcell - in: AX=col, BX=row
; -----------------------------------------------------------------------------
lg_clearcell:
    call lg_removecell
    ret

; =============================================================================
; String / number utilities
; =============================================================================

; lg_colname - bijective base-26 column letters (0-based index in AX)
; out: lg_colbuf = NUL-terminated letters (up to 2 for a 256-column grid)
lg_colname:
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
    mov bx, lg_colbuf
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

; lg_itoa - signed AX to a NUL-terminated decimal string in lg_numbuf
lg_itoa:
    ; STKBALANCE-LOOP: one digit pushed a turn and the second loop pops them; the count is in CX
    push ax
    push bx
    push cx
    push dx
    push di
    mov di, lg_numbuf
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
; lg_mkblank - rebuild lg_blank (every empty cell's display text) as exactly
; [lg_cellch] spaces + NUL. Called once at startup and again whenever
; Format > Column Width... changes the preset - lg_blank can't be a fixed
; string once the cell width is a runtime value.
; -----------------------------------------------------------------------------
lg_mkblank:
    push ax
    push cx
    push di
    mov cx, [lg_cellch]
    mov di, lg_blank
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

; lg_rjust - right-justify lg_numbuf into a fixed LG_CELL_CH-wide lg_tbuf
lg_rjust:
    push ax
    push cx
    push si
    push di
    mov si, lg_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov di, lg_tbuf
    mov ax, [lg_cellch]
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
    mov si, lg_numbuf
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
; lg_ljust - left-justify lg_numbuf into a fixed LG_CELL_CH-wide lg_tbuf
; (padding trails, mirroring lg_rjust which pads first)
; -----------------------------------------------------------------------------
lg_ljust:
    push ax
    push cx
    push si
    push di
    mov si, lg_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov [lg_jlen], cx
    mov di, lg_tbuf
    mov si, lg_numbuf
.copy:
    jcxz .copydone
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .copy
.copydone:
    mov ax, [lg_cellch]
    sub ax, [lg_jlen]
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
; lg_cjust - center-justify lg_numbuf into a fixed LG_CELL_CH-wide lg_tbuf
; (the odd leftover space, if any, goes on the right)
; -----------------------------------------------------------------------------
lg_cjust:
    push ax
    push bx
    push cx
    push si
    push di
    mov si, lg_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov [lg_jlen], cx
    mov di, lg_tbuf
    mov ax, [lg_cellch]
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
    mov si, lg_numbuf
    mov cx, [lg_jlen]
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
    mov si, lg_numbuf
    mov cx, [lg_jlen]
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
; lg_justify - in: BL=format byte; dispatches to lg_ljust/lg_cjust/lg_rjust
; by the alignment bits (General and explicit Right both right-justify,
; since this app's cells are only ever numeric - matching how real Excel's
; own "General" alignment right-justifies a number)
; -----------------------------------------------------------------------------
lg_justify:
    push ax
    push cx
    mov al, bl                         ; 81.75: the TEXT number format is a
    and al, LG_FMT_NUM_MASK            ; left alignment and nothing else -
    mov cl, LG_FMT_NUM_SHIFT           ; which is what Excel's @ does to a
    shr al, cl                         ; cell that holds a number. An explicit
    cmp al, LG_NF_TEXT                 ; Alignment still wins, because it is
    jne .align                         ; tested after
    mov al, bl
    and al, LG_FMT_ALIGN_MASK
    jz .left                           ; General alignment: Text decides
.align:
    mov al, bl
    and al, LG_FMT_ALIGN_MASK
    mov cl, LG_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, LG_FMT_ALIGN_LEFT
    je .left
    cmp al, LG_FMT_ALIGN_CENTER
    je .center
    jmp .right
.left:
    call lg_ljust
    jmp .out
.center:
    call lg_cjust
    jmp .out
.right:
    call lg_rjust
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_justify_c - lg_justify for a LOGICAL or an ERROR value: General centres
; both (81.51). An explicit alignment means what it means for anything else.
; in: BL = the format byte
; -----------------------------------------------------------------------------
lg_justify_c:
    push ax
    push cx
    mov al, bl
    and al, LG_FMT_ALIGN_MASK
    mov cl, LG_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, LG_FMT_ALIGN_GENERAL
    jne .explicit
    call lg_cjust
    jmp short .out
.explicit:
    call lg_justify
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_justify_t - lg_justify for a LABEL rather than a number.
;
; The one difference, and it is Excel's: General aligns a number RIGHT and a
; label LEFT. An EXPLICIT alignment means the same thing for both, so this
; only intercepts General and hands everything else straight over.
; in: BL = the format byte
; -----------------------------------------------------------------------------
lg_justify_t:
    push ax
    push cx
    mov al, bl
    and al, LG_FMT_ALIGN_MASK
    mov cl, LG_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, LG_FMT_ALIGN_GENERAL
    jne .explicit
    call lg_ljust
    jmp .out
.explicit:
    call lg_justify
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_text_to_numbuf - copy the label at lg_curtoff (in lg_txtseg) into
; lg_numbuf, clipped to what the cell can show, so that the justifiers - which
; all read lg_numbuf and write lg_tbuf - need to know nothing about text.
;
; The label's OWN cell is clipped here; what runs on into the empty cells to
; its right, as Excel draws it, is theirs to draw (lg_spill, 81.54). That was
; thought to need a draw order - the neighbours' occupancy before this cell
; is drawn - and it does not: each cell draws only its own slice.
; -----------------------------------------------------------------------------
lg_text_to_numbuf:
    push ax
    push cx
    push si
    push di
    push es
    mov es, [lg_txtseg]
    mov si, [lg_curtoff]
    mov di, lg_numbuf
    mov cx, [lg_cellch]
    cmp cx, LG_NUMBUF_MAX             ; lg_numbuf is a fixed buffer and the
    jbe .cap                          ; cell width is a RUNTIME value now
    mov cx, LG_NUMBUF_MAX             ; (stage 3.0c's Column Width), so the
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
; lg_spill - does a LABEL to the left run on into this empty cell? (81.54)
; in: AX = col, BX = row, the cell known empty. out: CF=1 with lg_tbuf holding
; this cell's slice of it and [lg_curfmt] the label's format; CF=0 otherwise.
;
; Excel draws a label wider than its column across the EMPTY cells to its
; right and stops at the first that holds anything. So the one label that can
; reach this cell is the NEAREST cell to its left in the row - any further one
; is stopped by it - and that is the record just before this cell's insertion
; point, the table being sorted by (row, col): one search, the one
; lg_getcell2 has just made. Each cell draws its own slice and nothing else,
; so no draw order and no ranged repaint can undo another cell's. Only a
; label that is General or left-aligned: centred and right-aligned ones run
; the other way in Excel, and are still clipped here.
; -----------------------------------------------------------------------------
lg_spill:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    cmp byte [lg_showformulas], 0     ; formulas on show: a cell shows its
    jne .no                           ; formula, and nothing runs on
    or ax, ax
    jz .no                            ; column A has nothing to its left
    mov dx, ax                        ; DX = this column
    call lg_findcell                  ; not there: DI = where it would go
    jc .no
    or di, di
    jz .no
    sub di, LG_C_SZ                   ; the record before it...
    mov es, [lg_cellseg]
    mov ax, [lg_cursheet]
    mov cl, LG_ROW_BITS
    shl ax, cl
    or ax, bx
    cmp [es:di], ax                   ; ...in this row of this sheet
    jne .no
    cmp byte [es:di+LG_C_TYPE], LG_T_TEXT
    jne .no                           ; a label, or a formula's text result
    mov bl, [es:di+5]                 ; its format
    mov al, bl
    and al, LG_FMT_ALIGN_MASK
    mov cl, LG_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, LG_FMT_ALIGN_GENERAL
    je .left
    cmp al, LG_FMT_ALIGN_LEFT
    jne .no
.left:
    mov si, [es:di+LG_C_FOFF]         ; a label's own text...
    test byte [es:di+4], 1
    jz .haveoff
    mov si, [es:di+LG_C_VAL]          ; ...or a formula's RESULT (81.22.1)
.haveoff:
    push si
    mov si, [es:di+2]                 ; its characters before this cell: the
    xor cx, cx                        ; widths of the columns between, each
.wsum:                                ; its own (81.56) - scrolled out of
    cmp si, dx                        ; view or not
    jae .wdone
    mov ax, si
    call lg_colwidth
    add cx, ax
    inc si
    jmp short .wsum
.wdone:
    pop si
    mov es, [lg_txtseg]
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
    mov di, lg_numbuf
    mov cx, [lg_cellch]
    cmp cx, LG_NUMBUF_MAX
    jbe .copy
    mov cx, LG_NUMBUF_MAX
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
    call lg_ljust                     ; -> lg_tbuf, padded to the cell
    mov [lg_curfmt], bl               ; bold and underline are the label's
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
; lg_strlen - in: SI=NUL-terminated string; out: AX=length (SI preserved)
; -----------------------------------------------------------------------------
lg_strlen:
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
; lg_errname - the current cell's error, by name, into lg_numbuf. Excel's own
; spellings, because they are what a person recognises and what every book
; about spreadsheets prints. An unknown code cannot arise from this app's own
; evaluator, but a file could carry one, so it reads as #ERR rather than
; running off the end of the table.
; -----------------------------------------------------------------------------
lg_errname:
    push ax
    push bx
    push si
    push di
    mov al, [lg_curaux]
    or al, al
    jz .unknown
    cmp al, 7
    ja .unknown
    xor ah, ah
    dec ax
    shl ax, 1
    mov bx, ax
    mov si, [lg_errtab + bx]
    jmp .copy
.unknown:
    mov si, lg_s_err_unk
.copy:
    mov di, lg_numbuf
    call lg_strcpy
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_errcode - in: SI = a NUL-terminated error name; out: AL = its Excel
; ERROR.TYPE number, or 0 if this is not a spelling we write. The inverse of
; lg_errname, and it reads the SAME table, so the two cannot drift apart.
; -----------------------------------------------------------------------------
section LG_MODSEC                      ; 82.16.9
lg_errcode:
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
    mov di, [lg_errtab + bx]
    SHOUT lg_streq
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
lg_errtab:  dw lg_s_err_null, lg_s_err_div0, lg_s_err_value, lg_s_err_ref
            dw lg_s_err_name, lg_s_err_num, lg_s_err_na
lg_s_err_null:  db '#NULL!', 0
lg_s_err_div0:  db '#DIV/0!', 0
lg_s_err_value: db '#VALUE!', 0
lg_s_err_ref:   db '#REF!', 0
lg_s_err_name:  db '#NAME?', 0
lg_s_err_num:   db '#NUM!', 0
lg_s_err_na:    db '#N/A', 0
lg_s_err_unk:   db '#ERR', 0

; =============================================================================
; NUMBER FORMAT CODES (81.55) - Excel 2.1d's twenty-one built-ins, in its own
; order (which is the BIFF built-in id, and the position a BIFF2 cell names),
; and ONE engine that draws a value by any code: the grid through a cell's
; format, TEXT() through the code it is handed. It was two: lg_numfmt knew four
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
; lg_group3 and lg_dollar_ins already existed and do the decorating; they live
; up beside lg_ftoa's other helpers rather than in here, which is why they
; survived the interpreter going.
; =============================================================================

; -----------------------------------------------------------------------------
; lg_numfmt - in: lg_acc = the value, BL = the cell's format byte; writes the
; display text into lg_numbuf. BH is ignored and kept only so that the one
; caller needs no edit.
; -----------------------------------------------------------------------------
lg_numfmt:
    push ax
    push bx
    push cx
    push si
    push di
    mov al, bl
    and al, LG_FMT_NUM_MASK
    mov cl, LG_FMT_NUM_SHIFT
    shr al, cl
    mov di, lg_numbuf
    cmp al, LG_NF_CURRENCY
    je .currency
    call lg_acc_load_a                 ; NUMBER and TEXT are the same string:
    mov ax, 10                         ; General. They differ in ALIGNMENT,
    SHOUT fx_ftoa                      ; which lg_justify reads from the same
    jmp short .out                     ; byte
.currency:
    call lg_acc_load_a
    test byte [lg_acc+3], 0x80         ; the magnitude is what gets decorated;
    pushf                              ; the sign becomes parentheses
    call lg_acc_abs
    call lg_acc_load_a
    mov ax, 2                          ; exactly two places, as money is
    SHOUT fx_ftoa
    call lg_group3
    call lg_dollar_ins
    popf
    jz .out
    call lg_parens
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_parens - wrap lg_numbuf in '(' and ')', which is how Excel's Currency
; shows a negative. Every register preserved.
; -----------------------------------------------------------------------------
lg_parens:
    push ax
    push cx
    push si
    push di
    mov si, lg_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .have
    inc si
    inc cx
    jmp short .len
.have:
    cmp cx, LG_NUMBUF_MAX - 3          ; no room for both: leave it plain
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
    mov byte [lg_numbuf], '('
.out:
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; lg_drawunderline - in: CX=cell text x (left edge, as passed to
; OSAPI_FONT_RUN), DX=cell text y (top); reads lg_numbuf (the UNPADDED
; decorated text - not lg_tbuf, which carries alignment padding) and
; [lg_curfmt] to underline exactly the text's own extent, not the whole
; cell, positioned by the same alignment the text itself used.
; -----------------------------------------------------------------------------
lg_drawunderline:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [lg_ulx], cx
    mov [lg_uly], dx
    mov si, lg_numbuf
    call lg_strlen                    ; ax = text length (chars)
    mov bx, ax                        ; bx = length (chars)
    mov ax, [lg_cellch]
    sub ax, bx
    jns .padok
    xor ax, ax
.padok:                                ; ax = total pad chars
    mov dl, [lg_curfmt]
    and dl, LG_FMT_ALIGN_MASK
    mov cl, LG_FMT_ALIGN_SHIFT
    shr dl, cl                         ; dl = align code
    cmp dl, LG_FMT_ALIGN_LEFT
    je .lp0
    cmp dl, LG_FMT_ALIGN_CENTER
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
    mov ax, [lg_ulx]
    add ax, di                         ; ax = underline x1
    mov cx, ax
    add cx, bx
    dec cx                             ; cx = underline x2
    mov bx, [lg_uly]
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

; lg_strcpy - copy a NUL-terminated string, SI->DI, including the NUL
lg_strcpy:
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

; lg_strcpy_to_di - append a NUL-terminated string at the DI cursor,
; advancing DI to the new NUL (so successive calls concatenate)
lg_strcpy_to_di:
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
lg_tpl:
    dw 60, 40, 560, 380
    dw lg_ttl, lg_paint, lg_onkey, lg_onclick

; The EMPTY kernel menu set (SPEC.md 12.2), same idea as apps/word/word.asm's
; wd_menus0: zero real menus, but its AM_NAME still puts 'Plan' in the
; kernel bar. lg_mf_ret can never actually be called (there is nothing to
; pick) - it only satisfies the macro's layout.
    OS88_MENUSET lg_menus, lg_s_appname, lg_mf_ret
    OS88_MENUSET_END lg_menus
lg_mf_ret:
    ret

; lg_mtab - Sheet's own in-window menu bar (see the LG_MBAR_H section
; comment). Each entry: title string ptr, item string-ptr array, item
; count (word each, so 6 bytes/entry) - menu index 0..LG_MENU_N-1 is this
; array's own order, which lg_mfire's dispatch and lg_docmd_sortcol/
; lg_docmd_options/lg_docmd_help all key off directly.
; Stage 3.0b puts FORMULA at index 2, which is where Excel 2.1d has it -
; File Edit Formula Format Data Options Macro Window Help. Sheet's own
; multi-sheet menu stands in for Window and now sits where Window does, after
; Macro. Every index below 2 is unchanged and everything above it shifted, so
; lg_mfire's dispatch chain moved with it; nothing else in this file keys off a
; menu index (the macro language names commands, not menu positions), which is
; what made the renumber safe to do at all.
lg_mtab:
    dw lg_m_file,    lg_i_file,    4
    dw lg_m_edit,    lg_i_edit,    6
    dw lg_m_format,  lg_i_format,  4
    dw lg_m_options, lg_i_options, 4

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
lg_it_ref_a1:    db 'Reference: A1', 0     ; the same relabel-by-repointing
lg_it_ref_rc:    db 'Reference: R1C1', 0   ; the Options toggles use

; 81.75: the window title and the kernel menu bar's AM_NAME. The PACKAGE name
; in OS88_HEADER is PLAN; these two are what the user reads, so they have to
; agree with it - a window captioned "Sheet" launched from PLAN.O88 is two
; things answering to one name, which is the rule (73.12) this build exists
; to keep on the right side of.
lg_ttl:        db 'Ledger', 0
lg_s_appname:  db 'Ledger', 0
lg_m_file:     db 'File', 0
lg_i_file:     dw lg_it_new, lg_it_open, lg_it_save, lg_it_saveas
lg_it_new:     db 'New...', 0
lg_it_open:    db 'Open...', 0
lg_it_save:    db 'Save', 0
lg_it_saveas:  db 'Save As...', 0
lg_s_sheetpfx: db 'Sheet', 0
lg_s_protdoc:  db 'The document is protected.', 0

; Stage 1.8/2.x: matches real Excel 2.0/2.1's own Format menu shape
; (LIBRARY/documentation/screenshots/excel/menu_format.png) -
; Number.../Alignment.../Font... open
; dialogs (lg_docmd_format's AL 0/1/2 is lg_fdlg_open's own kind number, so
; this array's first 3 entries must stay in that order). Border... is real
; (lg_bdlg_*). Row Height.../Column Width... are real too and take A TYPED
; NUMBER: LG_ID_ROWH/LG_ID_COLW through lg_idlg_open, in CHARACTERS for the
; width because that is Excel's own unit, range-checked LG_CW_MINCH..MAXCH.
;
; This said "a 3-preset radio pick ... since this app has no text-input widget
; at the app level" until 2026-09-03, and stage 3.0c had replaced both halves
; of that long before: os88line.inc gave the app a text field and
; lg_docmd_format says so in its own comment two screens up ("a typed number
; now, not the 3-preset radio pick this had to be while no text field
; existed"). Read as current it understates the app by a whole feature, and it
; did - it is where the claim "Column Width is three presets" in an assessment
; of what SHEET still lacks came from.
;
; The other half - that it applied to the WHOLE sheet - went too: 81.56 made
; the widths per column and 81.60 the heights per row, the height in POINTS
; because that is Excel's unit for it. lg_gridhit walks both now.
lg_m_format:    db 'Format', 0
; LIBRARY/documentation/screenshots/excel/menu_format_full.png:
; Number/Alignment/Font/Border/CELL PROTECTION/Row Height/Column
; Width/Justify. Cell Protection sits between
; Border and Row Height, which is not where it would have been guessed.
lg_i_format:    dw lg_it_fnum, lg_it_falign, lg_it_ffont, lg_it_fcolw
lg_it_fnum:      db 'Number...', 0
lg_it_falign:    db 'Alignment...', 0
lg_it_ffont:     db 'Font...', 0
lg_it_fcolw:     db 'Column Width...', 0

; Stage 2.0: the Sheet menu switches which of this instance's LG_SHEETS
; grids is active (see the multi-sheet cell-record comment above
; lg_findcell for why this lives in one instance rather than several).
; Sheet names are the fixed strings below, not user-renameable in this
; stage - simpler, and a macro's "SheetN!" reference (see lg_pident) needs
; a name it can recognize regardless of what the user might have typed.
; ...and the same four with the mark, which lg_sheetmark repoints between.

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
; MENU_APPMAX=5 one; Sheet's own in-window bar (lg_mtab) has no such cap.
; LG_MENU_CHK is Sheet's own leading-byte convention beside the kernel's
; MENU_DIS: the item is drawn with a check in the left margin. It is 2 rather
; than 1 so the two can never be confused, and lg_mdrop_draw handles both.
lg_m_edit:     db 'Edit', 0
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
lg_i_edit:     dw lg_it_undo, lg_it_repeat, lg_it_cut, lg_it_copy, lg_it_paste, lg_it_clear
lg_it_undo:    db MENU_DIS, "Can't Undo", 0     ; REWRITTEN by lg_undo_label
               times 10 db 0                      ; (81.57): "Undo Paste Special"
                                                  ; and its NUL fit the slack
lg_it_repeat:  db MENU_DIS, "Can't Repeat", 0
lg_it_cut:     db 'Cut', 0
lg_it_copy:    db 'Copy', 0
lg_it_paste:   db 'Paste', 0
lg_it_clear:   db 'Clear...', 0


; Options - Display toggles (stage 2.x). Each item's own string SWAPS
; between an On/Off pair (same relabel-by-repointing idea MENU_DIS's own
; doc shows) rather than drawing a separate checkmark glyph.
lg_m_options:  db 'Options', 0
; Real Excel's Options menu puts Protect Document... between Display... and
; Calculation...
; (LIBRARY/documentation/screenshots/excel/menu_options_full.png). Gridlines
; and Formulas are items here where Excel keeps them inside Display... - that
; divergence is 81.31's, not this one's.
lg_i_options:  dw lg_it_grid_off, lg_it_form_off, lg_it_calc, lg_it_ref_a1
lg_it_grid_on:  db 'Gridlines: On', 0
lg_it_grid_off: db 'Gridlines: Off', 0
lg_it_form_on:  db 'Formulas: On', 0
lg_it_form_off: db 'Formulas: Off', 0
lg_it_calc:     db 'Calculation...', 0
lg_it_frz_off:  db 'Freeze Panes', 0     ; 81.70, relabelled like the three
lg_it_frz_on:   db 'Unfreeze Panes', 0   ; toggles above rather than ticked
lg_s_frz_at_a1: db 'Select below or right of the split first.', 0

; Help
; --- the About card's lines (SPEC.md 20.5.1) ----------------------------------
lg_ablines:
    dw lg_ab1, lg_ab2, lg_ab3, lg_ab4, 0
lg_ab1:        db 'Sheet for os8088', 0
lg_ab2:        db 'A spreadsheet in the shape of Excel 2.1d', 0
lg_ab3:        db 0
lg_ab4:        db 'Contributed by Koriban', 0

lg_defname:    db 'SHEET1.SLK', 0
lg_s_ready:    db 'Ready', 0
lg_s_badparen: db 'Unbalanced ( ) - kept as text.', 0
lg_s_num:      db 'NUM', 0
lg_s_calcind:  db 'CALCULATE', 0
lg_s_nw_sheet: db 'New worksheet.', 0
lg_s_nw_chart: db 'New sheet - Ledger has no charts.', 0
lg_s_nw_macro: db 'New sheet - Ledger has no macros.', 0
lg_s_calc_auto: db 'Calculation: Automatic', 0
lg_s_calc_man:  db 'Calculation: Manual - Calculate Now to recompute.', 0
lg_s_calc_now:  db 'Recalculated.', 0
lg_s_id:       db 'ID;PWXL;N;E', 13, 10, 0
lg_s_c:        db 'C;X', 0
lg_s_y:        db ';Y', 0
lg_s_e:        db ';E', 0                  ; the expression field (stage 4.x)
lg_s_k:        db ';K', 0                  ; also the "commas are set" flag
                                            ; on an F record (stage 1.6)
lg_s_sylk_fw:  db 'F;W', 0                 ; F;W<first> <last> <width> (81.56)
lg_s_sylk_fx:  db 'F;X', 0                 ; an F (formatting) record -
lg_s_sylk_ff:  db ';F', 0                  ; stage 1.6's real SYLK support
lg_s_crlf:     db 13, 10, 0
lg_s_end:      db 'E', 13, 10, 0
lg_m_saved:    db 'Saved', 0
lg_m_trunc:    db 'Saved - TRUNCATED; sheet too large for this format.', 0
lg_m_loaded:   db 'Loaded', 0
lg_f_sum:      db 'SUM', 0
lg_f_average:  db 'AVERAGE', 0
lg_f_min:      db 'MIN', 0
lg_f_max:      db 'MAX', 0
lg_f_count:    db 'COUNT', 0
lg_f_if:       db 'IF', 0
lg_f_not:      db 'NOT', 0
lg_f_abs:      db 'ABS', 0
lg_f_and:      db 'AND', 0
lg_f_or:       db 'OR', 0
; stage 3.0d. ORDER IS THE ID - lg_functab below indexes by position and
; lg_pfunc/lg_foldvalue/lg_pspecial switch on that number, so entries may be
; APPENDED but never reordered or removed.
lg_f_product:  db 'PRODUCT', 0
lg_f_counta:   db 'COUNTA', 0
lg_f_mod:      db 'MOD', 0
lg_f_int:      db 'INT', 0
lg_f_trunc:    db 'TRUNC', 0
lg_f_sign:     db 'SIGN', 0
lg_f_fact:     db 'FACT', 0
lg_f_sqrt:     db 'SQRT', 0
lg_f_power:    db 'POWER', 0
lg_f_round:    db 'ROUND', 0
lg_f_true:     db 'TRUE', 0
lg_f_false:    db 'FALSE', 0
lg_f_row:      db 'ROW', 0
lg_f_column:   db 'COLUMN', 0
lg_f_choose:   db 'CHOOSE', 0
; stage 4.5: the INFORMATION functions. Absent until now because an argument
; was folded to a value before the function saw it - see lg_pargclass.
lg_f_isblank:  db 'ISBLANK', 0
lg_f_isnumber: db 'ISNUMBER', 0
lg_f_istext:   db 'ISTEXT', 0
lg_f_islogicl: db 'ISLOGICAL', 0
lg_f_iserror:  db 'ISERROR', 0
lg_f_iserr:    db 'ISERR', 0
lg_f_isna:     db 'ISNA', 0
lg_f_isref:    db 'ISREF', 0
lg_f_na:       db 'NA', 0
lg_f_type:     db 'TYPE', 0
lg_f_n:        db 'N', 0
lg_f_errtype:  db 'ERROR.TYPE', 0     ; the only name here with a '.' in it,
                                       ; which is what lg_pident's .trydot is
                                       ; for
; stage 4.5: the TEXT functions - Excel 2.1's own category, less the seven
; that search and format
; stage 4.5: the DATE and TIME functions. NOW() is absent and lg_pdate's
; header says why - no kernel call publishes the calendar date.
lg_f_date:     db 'DATE', 0
lg_f_day:      db 'DAY', 0
lg_f_month:    db 'MONTH', 0
lg_f_year:     db 'YEAR', 0
lg_f_weekday:  db 'WEEKDAY', 0
lg_f_time:     db 'TIME', 0
lg_f_hour:     db 'HOUR', 0
lg_f_minute:   db 'MINUTE', 0
lg_f_second:   db 'SECOND', 0
lg_f_datevalue: db 'DATEVALUE', 0
lg_f_timevalue: db 'TIMEVALUE', 0
lg_f_now:      db 'NOW', 0
lg_f_isnontext: db 'ISNONTEXT', 0
lg_f_rand:     db 'RAND', 0
lg_f_indirect: db 'INDIRECT', 0
lg_f_rows:      db 'ROWS', 0
lg_f_columns:   db 'COLUMNS', 0
lg_f_areas:     db 'AREAS', 0
lg_f_index:     db 'INDEX', 0
lg_f_match:     db 'MATCH', 0
lg_f_vlookup:   db 'VLOOKUP', 0
lg_f_hlookup:   db 'HLOOKUP', 0
lg_f_lookup:    db 'LOOKUP', 0
lg_f_var:       db 'VAR', 0
lg_f_varp:      db 'VARP', 0
lg_f_stdev:     db 'STDEV', 0
lg_f_stdevp:    db 'STDEVP', 0
; 81.65: the DATABASE functions, in the same order lg_db_foldkind reads them
; 81.67: the ARRAY/MATRIX functions
lg_dt_mlen:    db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
lg_snull:      db 0                   ; lg_sslot's answer for a read below the
                                       ; bottom of the string stack

; lg_functab - the id is the INDEX. 0 terminates.
; 81.75: A NAME NOTHING CAN ANSWER POINTS AT AN EMPTY STRING. An id is this
; table's own index, so an entry cannot be removed without renumbering every
; family after it - but the NAME can go, and lg_funcid compares typed
; identifiers, which are never empty, so lg_fgone can never match. That is
; every name of the seven families whose bodies are cut, at the cost of one
; byte shared between them.
lg_fgone:     db 0
lg_functab:
    dw lg_f_sum, lg_f_average, lg_f_min, lg_f_max, lg_f_count
    dw lg_f_if, lg_f_not, lg_f_abs, lg_f_and, lg_f_or
    dw lg_f_product, lg_f_counta, lg_f_mod, lg_f_int, lg_f_trunc
    dw lg_f_sign, lg_f_fact, lg_f_sqrt, lg_f_power, lg_f_round
    dw lg_f_true, lg_f_false, lg_f_row, lg_f_column, lg_f_choose
    dw lg_f_isblank, lg_f_isnumber, lg_f_istext, lg_f_islogicl, lg_f_iserror
    dw lg_f_iserr, lg_f_isna, lg_f_isref, lg_f_na, lg_f_type
    dw lg_f_n, lg_f_errtype
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone
    dw lg_f_date, lg_f_day, lg_f_month, lg_f_year, lg_f_weekday
    dw lg_f_time, lg_f_hour, lg_f_minute, lg_f_second, lg_f_datevalue
    dw lg_f_timevalue
    dw lg_f_rows, lg_f_columns, lg_f_areas, lg_f_index
    dw lg_f_match, lg_f_vlookup, lg_f_hlookup, lg_f_lookup
    dw lg_f_var, lg_f_varp, lg_f_stdev, lg_f_stdevp
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone
    dw lg_fgone, lg_fgone
    dw lg_f_now                       ; 106 (81.42)
    dw lg_f_isnontext, lg_fgone, lg_f_rand   ; 107 108 109 (81.43)
    dw lg_f_indirect                  ; 110 (81.44)
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone ; 111- :
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone  ; the
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone     ; MACRO
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone     ; (81.63)
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone ; 131- :
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone, lg_fgone ; the
    dw lg_fgone                                                    ; DATABASE
                                                                      ; functions (81.65)
    dw lg_fgone                      ; 142 (81.66)
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone        ; 143- :
    dw lg_fgone, lg_fgone, lg_fgone, lg_fgone              ; ARRAY/
                                                                      ; MATRIX (81.67)
    dw 0
lg_functab_end:
; -----------------------------------------------------------------------------
; FOUR TABLES INDEXED BY THE SAME NUMBER, and nothing used to check they were
; the same length. lg_rpn_func indexes lg_rpn_fid and lg_rpn_fvar by the id
; lg_funcid returns, which is a position in lg_functab - so appending a
; function here and forgetting one of the other two reads whatever byte
; follows it and writes THAT as the BIFF function index. A wrong number in a
; saved file, no crash, no message. These four TIMES lines make it a build
; error instead, the same idiom OS88_BSS's literal uses; read the LINE NUMBER
; to see which table is short.
; -----------------------------------------------------------------------------
%define LG_NFUNCS ((lg_functab_end - lg_functab) / 2 - 1)
lg_s_errpfx:   db 'Err ', 0
section LG_MODSEC                      ; 82.16.9's tenant: CSV and TXT (81.40)

; =============================================================================
; CSV and TAB-DELIMITED TEXT (81.40).
;
; Excel 2.0's own open/save list (Reference Guide p.273) is .XLS/.XLC/.XLM/.XLW,
; .TXT, .CSV, .SLK, .WKS, .WK1, .DIF and .DBF - so these two are not an
; extension of the era's Excel, they are two of the nine it had and this app
; did not. They are ONE writer and ONE reader with a delimiter in [lg_sepch],
; because the only difference between them is that byte.
;
; QUOTING IS CSV'S, NOT DIF'S. A field carrying the delimiter, a quote, a CR
; or an LF is wrapped in quotes and its own quotes are doubled - the same rule
; SYLK uses for ';' (81.38.1) and the one that makes a field with a comma in it
; survive. DIF drops an embedded quote instead (see lg_dowrite_dif's .dt),
; which is right for DIF because DIF has no escape at all; CSV does.
; =============================================================================

section .text

section LG_MODSEC
lg_dowrite_csv:
    mov byte [lg_sepch], ','
    jmp lg_dowrite_sep
lg_dowrite_txt:
    mov byte [lg_sepch], 9
    jmp lg_dowrite_sep

lg_dowrite_sep:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    call lgm_difbbox                  ; the module's own copy (82.16.9)
    mov byte [lg_trunc], 0
    mov es, [lg_stgseg]
    xor di, di
    mov word [lg_wrow], 0
.rloop:
    mov ax, [lg_wrow]
    cmp ax, [lg_bbrow]
    ja .footer
    mov word [lg_wcol], 0
.cloop:
    mov ax, [lg_wcol]
    cmp ax, [lg_bbcol]
    ja .rnext
    mov ax, di
    add ax, LG_EDITMAX + 8            ; the widest a field can get: a label,
    cmp ax, LG_STAGE_MAX              ; its quotes, and the delimiter
    ja .truncf
    cmp word [lg_wcol], 0
    je .nosep
    mov al, [lg_sepch]
    call lg_stgputb
.nosep:
    mov ax, [lg_wcol]
    mov bx, [lg_wrow]
    SHOUT lg_getcell2
    jnc .cnext                        ; an empty cell is an EMPTY FIELD, not a
    cmp byte [lg_curtype], LG_T_TEXT  ; zero - the delimiters still count it
    je .ctext
    cmp byte [lg_curtype], LG_T_ERR
    je .cerr
    cmp byte [lg_curtype], LG_T_BOOL  ; a LOGICAL goes out as its name, which
    je .cbool                         ; is how it reads back in, too (81.51)
    push si
    push di
    mov si, lg_acc                    ; a FULL DECIMAL, the lesson
    SHOUT fx_unpack_a                 ; lg_dowrite_dif learned the hard way
    mov di, lg_numbuf
    mov ax, 10
    SHOUT fx_ftoa
    pop di
    pop si
    mov si, lg_numbuf
    call lg_stgput
    jmp .cnext
.cbool:
    mov ax, [lg_acc]
    SHOUT lg_boolname
    jmp short .cname
.cerr:
    SHOUT lg_errname                  ; -> lg_numbuf, the error's own spelling
.cname:
    mov si, lg_numbuf
    call lg_stgput
    jmp .cnext
.ctext:
    call lg_sep_needq
    jnc .ctplain
    mov al, 34
    call lg_stgputb
    mov si, [lg_curtoff]
.ctq:
    push es
    mov es, [lg_txtseg]
    mov al, [es:si]
    pop es
    or al, al
    jz .ctqend
    inc si
    cmp al, 34
    jne .ctq1
    call lg_stgputb                   ; an embedded quote is DOUBLED
.ctq1:
    call lg_stgputb
    jmp .ctq
.ctqend:
    mov al, 34
    call lg_stgputb
    jmp .cnext
.ctplain:
    mov si, [lg_curtoff]
.ctp:
    push es
    mov es, [lg_txtseg]
    mov al, [es:si]
    pop es
    or al, al
    jz .cnext
    inc si
    call lg_stgputb
    jmp .ctp
.cnext:
    inc word [lg_wcol]
    jmp .cloop
.rnext:
    mov si, lg_s_crlf
    call lg_stgput
    inc word [lg_wrow]
    jmp .rloop
.truncf:
    mov byte [lg_trunc], 1
.footer:
    mov [lg_stagelen], di
    mov ax, [lg_stgseg]
    mov es, ax
    xor bx, bx
    mov cx, [lg_stagelen]
    xor dx, dx
    mov si, lg_name
    call OSAPI_FILE_WRITE
    jc .werr
    mov word [lg_msg], lg_m_saved
    cmp byte [lg_trunc], 0
    je .wdone
    mov word [lg_msg], lg_m_trunc
    jmp .wdone
.werr:
    call lg_setferr                   ; module-local: 82.16.9 absorbed it
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
; lg_sep_needq - does the current cell's label need quoting? out: CF=1 if so.
; Preserves everything else.
; -----------------------------------------------------------------------------
lg_sep_needq:
    push ax
    push si
    push es
    mov si, [lg_curtoff]
    mov es, [lg_txtseg]
.l:
    mov al, [es:si]
    or al, al
    jz .no
    inc si
    cmp al, [lg_sepch]                ; [lg_sepch] is DS-relative and DS is
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
; lg_doread_csv / _txt - read [lg_name], replacing the sheet.
; -----------------------------------------------------------------------------
lg_doread_csv:
    mov byte [lg_sepch], ','
    jmp lg_doread_sep
lg_doread_txt:
    mov byte [lg_sepch], 9
    jmp lg_doread_sep

lg_doread_sep:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, [lg_stgseg]
    xor bx, bx
    mov cx, LG_STAGE_MAX
    xor dx, dx
    mov si, lg_name
    call OSAPI_FILE_READ
    jc .rerr
    mov word [lg_ncells], 0
    mov word [lg_txtlen], 0           ; "replacing the sheet", the same three
    mov word [lg_nbord], 0            ; lg_doread_dif clears
    mov word [lg_nnote], 0
    SHOUT lg_colw_clear                ; ...and every column's width (81.56)
    mov es, [lg_stgseg]
    mov [lg_sepend], ax               ; the end, for lg_sep_field
    xor si, si
    mov word [lg_wrow], 0
.rowloop:
    cmp si, [lg_sepend]
    jae .done
    cmp word [lg_wrow], LG_ROWS
    jae .done
    mov word [lg_wcol], 0
.fieldloop:
    call lg_sep_field                 ; -> lg_rwsrc; SI at the terminator
    call lg_sep_store
    inc word [lg_wcol]
    cmp si, [lg_sepend]
    jae .done
    mov al, [es:si]
    cmp al, [lg_sepch]
    jne .eol
    inc si                            ; past the delimiter
    mov ax, [lg_wcol]
    cmp ax, LG_COLS
    jae .eol                          ; past the last column: drop the rest
    jmp .fieldloop
.eol:
    cmp si, [lg_sepend]
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
    cmp si, [lg_sepend]
    jae .done
    mov al, [es:si]
    cmp al, 13
    je .eat
    cmp al, 10
    je .eat
    inc word [lg_wrow]
    jmp .rowloop
.done:
    mov word [lg_msg], lg_m_loaded
    jmp .rdone
.rerr:
    call lg_setferr                   ; module-local: 82.16.9 absorbed it
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
; lg_sep_field - one field at ES:SI into lg_rwsrc, NUL-terminated. SI is left
; AT the terminator (the delimiter, a CR/LF or [lg_sepend]) and never past it,
; so the caller decides what the terminator means.
; -----------------------------------------------------------------------------
lg_sep_field:
    push ax
    push cx
    push di
    mov di, lg_rwsrc
    mov cx, LG_EDITMAX
    cmp si, [lg_sepend]
    jae .end
    cmp byte [es:si], 34
    jne .plain
    inc si
.q:
    cmp si, [lg_sepend]
    jae .end
    mov al, [es:si]
    inc si
    cmp al, 34
    jne .qkeep
    cmp si, [lg_sepend]
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
    cmp si, [lg_sepend]
    jae .end
    mov al, [es:si]
    cmp al, [lg_sepch]
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
; lg_sep_store - lg_rwsrc into the cell at [lg_wcol],[lg_wrow].
;
; CSV HAS NO TYPE FIELD, so the field's own spelling decides. fx_atof reports
; CF=1 when there was no number there at all, and SI is left where it stopped -
; so "12abc" is TEXT rather than 12, which is the whole reason the position is
; checked and not just the carry.
; -----------------------------------------------------------------------------
lg_sep_store:
    push ax
    push bx
    push si
    cmp byte [lg_rwsrc], 0
    je .out                           ; an empty field leaves the cell blank
    mov si, lg_rwsrc
    SHOUT fx_atof
    jc .text
    cmp byte [si], 0
    jne .text
    SHOUT lg_acc_store
    mov ax, [lg_wcol]
    mov bx, [lg_wrow]
    SHOUT lg_setvald
    jmp .out
.text:
    mov ax, [lg_wcol]
    mov bx, [lg_wrow]
    mov si, lg_rwsrc
    SHOUT lg_setlabel                 ; a TRUE field is the logical, as Excel
.out:                                 ; reads one (81.51)
    pop si
    pop bx
    pop ax
    ret

section .text

lg_s_ext_sylk: db '.SLK', 0
lg_s_ext_csv:  db '.CSV', 0
lg_s_ext_txt:  db '.TXT', 0

; Stage 2.0's ALERT() needs a real message box; SPEC.md 75.3's os88ui_ask is
; the project's own answer to that (a kernel-resident version was tried and
; measured too costly for every app to pay for - see SPEC.md 75.3).
; Included here, above OS88_BSS, because the
; lg_macro_msg bss field below sizes itself from OS88UI_AMAX, which this
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
    OS88_BSS 3203                     ; 81.75, PLAN's own and already far from
                                       ; SHEET's: -191 for the ch_* working
                                       ; set, -568 for the vector table that a
                                       ; one-file build has no use for, -4
                                       ; because LG_MENU_N is 7 rather than 9
                                       ; (lg_mw is a word per menu, and both
                                       ; Macro and Data are gone), +2 for
                                       ; lg_planvec. The claim ladder will
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

lg_selcol     equ CH_BSS_END
lg_selrow     equ lg_selcol + 2
lg_scrollcol  equ lg_selrow + 2
lg_scrollrow  equ lg_scrollcol + 2
lg_editing    equ lg_scrollrow + 2
lg_editlen    equ lg_editing + 1
lg_editbuf    equ lg_editlen + 1            ; 64: LG_EDITMAX + NUL
lg_name       equ lg_editbuf + 64           ; 13: 8.3 name + NUL
lg_ox         equ lg_name + 13
lg_oy         equ lg_ox + 2
lg_cw         equ lg_oy + 2
lg_ch         equ lg_cw + 2
lg_vcols      equ lg_ch + 2
lg_vrows      equ lg_vcols + 2
lg_freezecol  equ lg_vrows + 2       ; word: Options > Freeze Panes (81.70) -
                                     ; columns 0..lg_freezecol-1 never scroll
lg_freezerow  equ lg_freezecol + 2   ; ...and rows 0..lg_freezerow-1. 0 means
                                     ; no freeze on that axis; lg_scrollcol/
                                     ; row can never fall below these once set
                                     ; scrolling phase's row offset (visible
                                     ; index minus lg_freezerow), named
                                     ; because every other register is
                                     ; already spoken for in that loop
; 81.73: a HIDDEN row or column takes no slot, so the visible slots stopped
; marching in step with the real indices and lg_geom records the mapping it
; actually built. Everything that used to compute it now reads these.
lg_vrc            equ lg_freezerow + 2   ; LG_MAXVC words: slot -> real column
lg_vrr        equ lg_vrc + LG_MAXVC * 2   ; LG_MAXVR words: slot -> real row
lg_geom_rc    equ lg_vrr + LG_MAXVR * 2   ; the walks' own real cursors...
lg_geom_rr    equ lg_geom_rc + 2
                                     ; began, which is what turns a real row
                                     ; into the key the table is streaming
lg_vcl_lo         equ lg_geom_rr + 2  ; lg_vclip's own four
lg_vcl_hi     equ lg_vcl_lo + 2
lg_vcl_a      equ lg_vcl_hi + 2
lg_vcl_b      equ lg_vcl_a + 2
; 81.74's own: the macro recorder. lg_rec_col/row/sheet is where the next
; macro formula goes - Set Recorder's corner, and the SHEET with it, because
; the recording lands on the macro sheet while the user works on theirs.
lg_wcol           equ lg_vcl_b + 2
lg_wrow       equ lg_wcol + 2
lg_selx1      equ lg_wrow + 2
lg_selx2      equ lg_selx1 + 2
lg_sely1      equ lg_selx2 + 2
lg_sely2      equ lg_sely1 + 2
lg_lx1        equ lg_sely2 + 2
lg_lx2        equ lg_lx1 + 2
lg_ly1        equ lg_lx2 + 2
lg_ly2        equ lg_ly1 + 2
lg_trunc      equ lg_ly2 + 2
LG_TCOL       equ lg_trunc + 1
LG_TROW       equ LG_TCOL + 2
LG_TVAL       equ LG_TROW + 2               ; the integer form, still used by
                                             ; the DIF and BIFF readers
LG_TDVAL      equ LG_TVAL + 2               ; 8: SYLK's, as a real double
LG_THASE      equ LG_TDVAL + 8              ; byte: this record had a ;E field
LG_TEXPR      equ LG_THASE + 1              ; LG_EDITMAX+1: its text
LG_TISTXT     equ LG_TEXPR + LG_EDITMAX + 1 ; byte: the ;K field was QUOTED,
                                             ; so LG_TEXPR holds a label
LG_TISERR     equ LG_TISTXT + 1             ; byte: ...or was an ERROR NAME,
LG_THAVE      equ LG_TISERR + 1             ; and which one
LG_TALIGN     equ LG_THAVE + 1             ; lg_parsefrec's own scratch -
LG_TNUMFMT    equ LG_TALIGN + 1            ; an "F" record's parsed
lg_stagelen   equ LG_TNUMFMT + 1
lg_tbuf       equ lg_stagelen + 2           ; 96: formula bar text (a formula
                                             ; can run to LG_EDITMAX chars)
lg_colbuf     equ lg_tbuf + 96              ; 4: up to 2 letters + NUL
lg_numbuf     equ lg_colbuf + 4             ; LG_NUMBUF_MAX+1: what all three
                                             ; justifiers read. Ten bytes held
                                             ; the widest DECORATED number
                                             ; ("$-32768", stage 1.6) and that
                                             ; was its whole job until stage
                                             ; 4.5 put LABELS through the same
                                             ; three routines - a label is as
                                             ; wide as the column, and a
                                             ; column runs to LG_CW_MAXCH
lg_msg        equ lg_numbuf + LG_NUMBUF_MAX + 1  ; 2: pointer to a status string
lg_errbuf     equ lg_msg + 2                ; 8: "Err " + up to 2 digits + NUL
lg_cellseg    equ lg_errbuf + 8
lg_txtseg     equ lg_cellseg + 2
lg_stgseg     equ lg_txtseg + 2
lg_bordseg    equ lg_stgseg + 2            ; stage 2.x: the border table's
                                             ; own claim, see LG_CLAIM_BORD_KB
lg_nbord      equ lg_bordseg + 2            ; word: records in lg_bordseg
lg_ncells     equ lg_nbord + 2
lg_txtlen     equ lg_ncells + 2
lg_fcol       equ lg_txtlen + 2             ; lg_findcell's search key stash
lg_frow       equ lg_fcol + 2
lg_wrec_row   equ lg_frow + 2               ; lg_dowrite's per-record stash
lg_wrec_col   equ lg_wrec_row + 2
lg_wrec_val   equ lg_wrec_col + 2
lg_wrec_fmt   equ lg_wrec_val + 2           ; SYLK's and BIFF's writers'
                                             ; stash of the record's format
                                             ; byte (DIF carries no format
                                             ; at all, see lg_dowrite_dif)
lg_newoff     equ lg_wrec_fmt + 1           ; lg_setformula's new text offset
lg_sacc       equ lg_newoff + 2             ; LG_STR_MAX+1: THE STRING HALF of
                                             ; the evaluator's result, the way
                                             ; lg_acc is the numeric half -
                                             ; lg_curtype says which is live
lg_sacc2      equ lg_sacc + LG_STR_MAX + 1  ; LG_STR_MAX+1: '&'s right operand,
                                             ; held while the left comes back off
                                             ; the string stack. It was TWO
                                             ; buffers, the left banked in the
                                             ; first - where a nested '&' in the
                                             ; right overwrote it (81.53)
lg_curaux     equ lg_sacc2 + LG_STR_MAX + 1  ; lg_getcell2's error code
lg_evalerr    equ lg_curaux + 2             ; byte: the error this evaluation
                                             ; ran into, 0 = none. STICKY for
                                             ; the whole of one top-level
                                             ; evaluation, which is what makes
                                             ; propagation free: no operator
                                             ; has to test it
lg_evaldepth  equ lg_evalerr + 2             ; lg_eval_cell's recursion depth
lg_pnest      equ lg_evaldepth + 2           ; live parser recursion points -
                                             ; lg_pnest_enter's counter (81.3),
                                             ; balanced so it needs no reset
lg_fbuf       equ lg_pnest + 2              ; LG_EVAL_MAXDEPTH * 64: one
                                             ; formula-text copy per
                                             ; recursion level (see
                                             ; lg_eval_cell), copied out of
                                             ; lg_txtseg so the parser never
                                             ; needs a segment override
lg_ident      equ lg_fbuf + (LG_EVAL_MAXDEPTH * 64) ; LG_NAME_MAX+1: a collected name/column
lg_pxsheet    equ lg_ident + LG_NAME_MAX + 1              ; stage 2.0: a "SheetN!" prefix
                                             ; lg_pident just consumed,
                                             ; 0xFF = none (see lg_psheetpfx)
lg_pcol       equ lg_pxsheet + 1              ; lg_pident's cell-ref column
lg_pfid       equ lg_pcol + 2               ; the function currently parsing:
                                             ; 0 SUM 1 AVERAGE 2 MIN 3 MAX
                                             ; 4 COUNT 0xFF unknown
lg_pacc       equ lg_pfid + 2               ; 8: the running sum / min / max /
                                             ; product, a packed double since
                                             ; stage 4.0 - SUM over a column of
                                             ; decimals has to keep them
lg_pcnt       equ lg_pacc + 8               ; cells folded so far
lg_phave      equ lg_pcnt + 2               ; MIN/MAX has a candidate yet
lg_r1col      equ lg_phave + 2              ; a range's two corners...
lg_r1row      equ lg_r1col + 2
lg_r2col      equ lg_r1row + 2
lg_r2row      equ lg_r2col + 2
lg_ix1col     equ lg_r2row + 2              ; lg_pintersect's SECOND rectangle
lg_ix1row     equ lg_ix1col + 2             ; - it cannot borrow lg_r1col,
lg_ix2col     equ lg_ix1row + 2             ; which is the running result it
lg_ix2row     equ lg_ix2col + 2             ; is reducing
lg_rrow       equ lg_ix2row + 2             ; ...and lg_foldrange's end-of-
                                             ; since the record-array walk)
lg_pass           equ lg_rrow + 2               ; recalculation pass counter
lg_bbrow      equ lg_pass + 2               ; lg_difbbox's used bounding box
lg_bbcol      equ lg_bbrow + 2
lg_curfmt     equ lg_bbcol + 2              ; lg_getcell2's format-byte output
lg_curtype    equ lg_curfmt + 1             ; ...and its LG_T_* tag, and where
lg_curtoff    equ lg_curtype + 1            ; a TEXT cell's characters live
lg_argtype    equ lg_curtoff + 2            ; stage 4.5: lg_pargclass's answer
lg_argaux     equ lg_argtype + 1            ; - what the argument IS, its error
lg_argisref   equ lg_argaux + 1             ; code, and whether it was a bare
lg_refarea    equ lg_argisref + 1           ; reference; lg_pargref's A1:B9 flag
lg_arg1col    equ lg_refarea + 1            ; ...and the reference itself, in
lg_arg1row    equ lg_arg1col + 2            ; FOUR WORDS OF ITS OWN. Sharing
lg_arg2col    equ lg_arg1row + 2            ; lg_r1col/lg_r2col with the range
lg_arg2row    equ lg_arg2col + 2            ; folder overwrote its loop bounds
                                             ; mid-walk - see lg_pargref
lg_sstk_sp    equ lg_arg2row + 2            ; the string stack's depth...
lg_sstk       equ lg_sstk_sp + 2            ; ...and LG_SSTK_N slots of
                                             ; LG_STR_MAX+1 bytes each
lg_fnd_hb     equ lg_sstk + LG_SSTK_N * (LG_STR_MAX + 1)  ; lg_strfind's two
lg_fnd_nd     equ lg_fnd_hb + 2             ; bases: the inner compare needs
                                             ; SI and DI and the outer scan a
                                             ; third pointer, and the 8086
                                             ; addresses memory through four
                                             ; registers of which one is BP
                                             ; In bss because nothing may sit
                                             ; on the stack between lg_vpush
                                             ; and lg_binop_pre
lg_dt_y           equ lg_fnd_nd + 2             ; stage 4.5: a broken-down date,
lg_dt_m       equ lg_dt_y + 2               ; shared by both directions of the
lg_dt_d       equ lg_dt_m + 2               ; serial conversion
lg_dt_ly      equ lg_dt_d + 2               ; lg_isleap's year
lg_dt_ys      equ lg_dt_ly + 2              ; lg_ymd_to_ser's two counters
lg_dt_ms      equ lg_dt_ys + 2
lg_dt_acc     equ lg_dt_ms + 2              ; lg_dt_parse3's running total
lg_dt_min     equ lg_dt_acc + 2             ; lg_dt_hms's minutes since midnight
lg_dt_tmp     equ lg_dt_min + 2             ; 8: one parked double
                                             ; parenthesises it afterwards, so
                                             ; the sign is banked here
lg_jlen           equ lg_dt_tmp + 8             ; lg_cjust's stashed text length
lg_ulx        equ lg_jlen + 2               ; lg_drawunderline's stashed
lg_uly        equ lg_ulx + 2                ; cell text origin (x, y)
                                             ; xf index stash
                                             ; new record's own index)
                                             ; tracked font's bold/underline
                                             ; bits
                                             ; each tracked XF's align|
                                             ; numfmt packed byte
                                             ; each tracked XF's font index
                                             ; each tracked XF's border and
                                             ; protection bits, in THIS app's
                                             ; LG_BORD_*/LG_PROT_* spelling
                                             ; rather than BIFF's (81.47)
                                             ; tracked XF's number format when
                                             ; the format byte cannot hold it -
                                             ; Excel's id plus one, or 0 (81.55)
                                             ; which is its format byte unless
                                             ; it also has a border record

lg_cursheet       equ lg_uly + 2           ; the sheet lg_findcell
                                             ; packs into every search (see
                                             ; the stage 2.0 cell-record
                                             ; comment above lg_findcell)
lg_selsave    equ lg_cursheet + 2           ; LG_SHEETS words each: the
lg_rowsave    equ lg_selsave + (LG_SHEETS*2) ; other 3 sheets' own
lg_sclsave    equ lg_rowsave + (LG_SHEETS*2) ; selection/scroll, saved and
lg_scrsave    equ lg_sclsave + (LG_SHEETS*2) ; restored by lg_switchsheet
lg_fclsave    equ lg_scrsave + (LG_SHEETS*2) ; ...and its FROZEN PANES
lg_frwsave    equ lg_fclsave + (LG_SHEETS*2) ; (81.70), which are per sheet
                                             ; in Excel as the scroll is here

lg_ownwin     equ lg_frwsave + (LG_SHEETS*2) ; our own window ptr, stashed
                                             ; once in lg_entry for
                                             ; os88ui_ask's sake
                                             ; against LG_MACRO_MAXSTEPS
                                             ; formula text, copied out of
                                             ; lg_txtseg the same way
                                             ; lg_eval_cell's lg_fbuf is
lg_macro_msg      equ lg_ownwin + 2 ; OS88UI_AMAX+1: ALERT's
                                             ; string-literal argument

lg_fdlg_win    equ lg_macro_msg + OS88UI_AMAX + 1 ; stage 1.8's Format
                                             ; dialogs: 0 = none, the gate
lg_fdlg_kind   equ lg_fdlg_win + 2          ; byte: 0 Number/1 Align/2 Font
lg_fdlg_sel    equ lg_fdlg_kind + 1         ; word: the selected radio 0-3
lg_fdlg_ox     equ lg_fdlg_sel + 2          ; this paint's content origin,
lg_fdlg_oy     equ lg_fdlg_ox + 2           ; stashed across widget calls
lg_fdlg_itemsptr equ lg_fdlg_oy + 2         ; this dialog's 4-item label
                                             ; array, for the row loop
lg_fdlg_rowidx equ lg_fdlg_itemsptr + 2     ; the row loop's own index
lg_fdlg_rowy   equ lg_fdlg_rowidx + 2       ; ...and that row's y
lg_fdlg_rect   equ lg_fdlg_rowy + 2         ; 8 words: TWO button rects,
                                             ; OK then Cancel - a group's
                                             ; rects must be contiguous
lg_fdlg_btrec  equ lg_fdlg_rect + 16        ; the standard button record
                                             ; (SPEC.md 20.5.1.3)
lg_fdlg_count  equ lg_fdlg_btrec + OS88UI_BT_SIZE         ; word: this kind's row count
                                             ; (4 for Number/Align/Font, 2
                                             ; for Insert/Delete's Row/
                                             ; Column pick) - see
                                             ; lg_fdlg_counts

; Edit menu (stage 2.x)
lg_clipbuf    equ lg_fdlg_count + 2         ; LG_EDITMAX+1: Copy/Cut build
                                             ; their clipboard text here;
                                             ; Paste goes straight into
                                             ; lg_editbuf instead (see
                                             ; lg_docmd_paste)
lg_rc_op      equ lg_clipbuf + LG_EDITMAX + 1 ; lg_rowcol_op's own working
lg_rc_idx     equ lg_rc_op + 1              ; state - see its header
lg_rc_stgcnt  equ lg_rc_idx + 2             ; comment for what each field
lg_rc_savedsheet equ lg_rc_stgcnt + 2       ; holds; kept here rather than
lg_rc_tsheet  equ lg_rc_savedsheet + 2      ; on the stack purely because
lg_rc_trow    equ lg_rc_tsheet + 2          ; there are enough of them
lg_rc_tcol    equ lg_rc_trow + 2            ; that stack-relative addressing
lg_rc_tflags  equ lg_rc_tcol + 2            ; would be more error-prone
lg_rc_tfmt    equ lg_rc_tflags + 1          ; than a few named bytes
lg_wrec_foff  equ lg_rc_tfmt + 1            ; word: the formula text offset of
                                             ; the cell being written, or FFFF
lg_wrec_dval  equ lg_wrec_foff + 2          ; 8: the SYLK writer's banked value
lg_wrec_type  equ lg_wrec_dval + 8          ; byte: LG_T_* of the cell being
lg_wrec_toff  equ lg_wrec_type + 1          ; written, where its label is, and
lg_wrec_aux       equ lg_wrec_toff + 2      ; byte: and, if it is an ERROR, which
lg_rc_tval        equ lg_wrec_aux + 1           ; 8: a whole double, not a word
lg_rc_tfml    equ lg_rc_tval + 8
lg_rc_ttype   equ lg_rc_tfml + 2            ; byte: LG_C_TYPE in transit
lg_rc_taux    equ lg_rc_ttype + 1           ; byte: ...and LG_C_AUX

                                             ; staged-pair count
                                             ; slots are staged so far
                                             ; row, stashed across the
                                             ; lg_getcell2 call below it
                                             ; whole double since stage 4.5
                                             ; formula cell just staged into
                                             ; against, both in DS because
                                             ; fx_unpack_* read DS:SI and the
                                             ; array lives in lg_stgseg
                                            ; keyed on, which since stage 4.5
                                            ; the dialog picks and which need
                                            ; not be the selection's anchor
lg_calcmanual     equ lg_rc_taux + 1        ; byte: Options > Calculation
lg_mchk         equ lg_calcmanual + 1       ; byte: this dropdown row is the
                                             ; checked one
lg_a1style      equ lg_mchk + 1             ; byte: 0 = A1, 1 = R1C1 - what
                                             ; the reference box and Goto show
lg_nm_tmp         equ lg_a1style + 1     ; word: lg_wr_r1c1 banks the column
                                             ; it is writing here, because the
                                             ; one it is GIVEN can come from a
                                             ; file buffer that the next read
                                             ; overwrites

; Sheet's own in-window menu bar (stage 2.x, see the LG_MBAR_H section
; comment) - lg_goy is the grid's own origin (raw [lg_oy] + LG_MBAR_H);
; everything from lg_mopen down is lg_mtrack/lg_mbar_*/lg_mdrop_*/
; lg_mitem_hit's shared working state.
lg_goy            equ lg_nm_tmp + 2
lg_mopen      equ lg_goy + 2               ; byte: open menu index, LG_M_NONE
lg_mhi        equ lg_mopen + 1             ; byte: hot item in the open
                                             ; dropdown, LG_M_NONE
lg_mrx1       equ lg_mhi + 1               ; the open dropdown's own rect
lg_mry1       equ lg_mrx1 + 2
lg_mrx2       equ lg_mry1 + 2
lg_mry2       equ lg_mrx2 + 2
lg_mbx1       equ lg_mry2 + 2              ; lg_mboxof's own output: one
lg_mbx2       equ lg_mbx1 + 2              ; menu title's screen box
lg_mw         equ lg_mbx2 + 2              ; LG_MENU_N words: each title's
                                             ; pixel width (lg_mtab_calc)
lg_mli        equ lg_mw + (LG_MENU_N*2)    ; generic loop-index scratch,
                                             ; shared by every lg_m* routine
                                             ; above (none of them nest)
lg_mto        equ lg_mli + 2               ; generic lg_mtab byte-offset
                                             ; scratch, same sharing rule
lg_mip        equ lg_mto + 2               ; the open menu's items array ptr
lg_mcnt       equ lg_mip + 2               ; the open menu's item count
lg_mmaxw      equ lg_mcnt + 2              ; lg_mdrop_geo's running max
                                             ; item-label width
lg_mry_row    equ lg_mmaxw + 2             ; lg_mdrop_draw's current row y

lg_gridlines     equ lg_mry_row + 2        ; byte: Options > Gridlines, 1=on
lg_showformulas  equ lg_gridlines + 1      ; byte: Options > Formulas, 1=on

; Border dialog (stage 2.x, lg_bdlg_*) - same "own scratch, not stack
; juggling" shape as lg_fdlg_*'s own bss block above
                                             ; LG_BDLG_B_* bits
                                             ; reused for OK then Cancel

; lg_drawborders' own scratch (stage 2.x) - the four edges' screen rect for
; whichever bordered cell it is currently drawing
                                             ; (not CX - see lg_drawborders)

; stage 2.x: runtime cell dimensions (Format > Column Width.../Row
; Height...) - see the LG_CW_*/LG_RH_* section comment above lg_entry
lg_cellw          equ lg_showformulas + 1              ; word: the drawn column's width, px
lg_cellh       equ lg_cellw + 2            ; word: the drawn row's height, px
lg_cellch      equ lg_cellh + 2            ; word: lg_cellw / 8, in chars
lg_blank       equ lg_cellch + 2           ; LG_CW_MAXCH+1: as many spaces as
                                             ; the WIDEST column the Column
                                             ; Width dialog will accept, plus
                                             ; the NUL (lg_mkblank). It was 11
                                             ; - LG_CW_WIDE/8 plus a NUL, right
                                             ; for the three presets it was
                                             ; written for and wrong the moment
                                             ; a numeric width could be typed:
                                             ; a width of 12 wrote 13 bytes and
                                             ; the two that fell off the end
                                             ; landed on lg_chartseg, one word
                                             ; further down. See 81.21

; Data > Chart Column... (stage 2.x) - a live second window; see the
; LG_CLAIM_CHART_KB comment above lg_entry for why it exists and the
; window-lifecycle note above lg_docmd_chart for why lg_chartwin, once
; set, is never zeroed again this session (only shown/hidden)
                                             ; window ptr, permanently valid
                                             ; is pinned to (frozen at open)
                                           ; column below (81.30)
                                             ; (frozen at open - re-run the
                                             ; menu item to retarget)
                                             ; 0 = nothing yet (Export checks
                                             ; this)
                                             ; name buffer (separate from
                                             ; lg_name, which is Sheet's own
                                             ; load/save filename)

; apps/os88chart.inc's own required scratch (see that file's header comment)
lg_rpn_buf        equ lg_blank + LG_CW_MAXCH + 1     ; LG_RPN_MAX: the token array
lg_rwsrc          equ lg_rpn_buf + LG_RPN_MAX             ; LG_EDITMAX+1: the formula
                                              ; text copied out for rewriting
lg_rwdst          equ lg_rwsrc + LG_EDITMAX + 1  ; LG_RW_CAP: the rewritten
                                              ; text being built
lg_rw_di          equ lg_rwdst + LG_RW_CAP   ; word: lg_rw_emit's own cursor
lg_rw_op          equ lg_rw_di + 2           ; byte: lg_rc_op, copied in
lg_rw_pivot       equ lg_rw_op + 1           ; word: lg_rc_idx, copied in
lg_rw_tsheet      equ lg_rw_pivot + 2        ; word: the sheet this whole
                                              ; operation is acting on
lg_rw_home        equ lg_rw_tsheet + 2       ; byte: 1 if the formula being
                                              ; rewritten right now lives on
                                              ; lg_rw_tsheet itself
lg_rw_adj         equ lg_rw_home + 1         ; byte: lg_reidx_cellpart's own
                                              ; "adjust this one" flag
lg_rw_ostart      equ lg_rw_adj + 1          ; word: the reference's own
                                              ; text start, for a verbatim copy
lg_rw_lettersend  equ lg_rw_ostart + 2       ; word: where its letters end
                                              ; (and its digits, if any, start)
lg_rw_refcol      equ lg_rw_lettersend + 2   ; word: the reference as parsed
lg_rw_refrow      equ lg_rw_refcol + 2
lg_rw_refend      equ lg_rw_refrow + 2       ; word: just past its digits
lg_rw_recdi       equ lg_rw_refend + 2       ; word: lg_rowcol_reidx's own
                                              ; current record offset

; Copy/Paste relative-reference adjustment (stage 2.x) - see the section
; comment above lg_copy_shift for what each of these holds
lg_clip_col       equ lg_rw_recdi + 2        ; word: lg_docmd_copy's own
lg_clip_row       equ lg_clip_col + 2        ; source cell
lg_clip_sheet     equ lg_clip_row + 2        ; word: and which sheet it was
lg_clip_valid     equ lg_clip_sheet + 2      ; byte: 1 once any Copy has
                                              ; run this session
lg_cp_coldelta    equ lg_clip_valid + 1      ; word: lg_docmd_paste's own
lg_cp_rowdelta    equ lg_cp_coldelta + 2     ; (dest - source) delta
lg_cp_ostart      equ lg_cp_rowdelta + 2     ; word: lg_copy_cellpart's own
                                              ; scratch - same shape as
                                              ; lg_rw_ostart/lettersend/
                                              ; refcol/refrow/refend above,
                                              ; just a separate copy since
                                              ; a row/col insert and a
                                              ; paste never run at once but
                                              ; sharing the same words
                                              ; would still be confusing
lg_cp_lettersend  equ lg_cp_ostart + 2
lg_cp_refcol      equ lg_cp_lettersend + 2
lg_cp_refrow      equ lg_cp_refcol + 2
lg_cp_refend      equ lg_cp_refrow + 2

; Stage 3.0a: multi-cell range selection. lg_selcol/lg_selrow keep their
; existing meaning as the ANCHOR (and, for every single-cell operation, still
; simply "the selected cell"); these two are the moving end of the block. A
; collapsed selection has extent == anchor, which is what lg_select sets, so
; every existing single-cell caller keeps working untouched.
lg_selcol2        equ lg_cp_refend + 2
lg_selrow2        equ lg_selcol2 + 2
lg_selc1          equ lg_selrow2 + 2   ; lg_selrect's normalized output -
lg_selc2          equ lg_selc1 + 2     ; c1<=c2, r1<=r2, so no consumer has
lg_selr1          equ lg_selc2 + 2     ; to care which corner was dragged
lg_selr2          equ lg_selr1 + 2     ; from
lg_sc_tcol        equ lg_selr2 + 2     ; lg_scrollto_t's target cell
lg_sc_trow        equ lg_sc_tcol + 2
lg_drag_col       equ lg_sc_trow + 2   ; the cell the drag handler last
lg_drag_row       equ lg_drag_col + 2  ; landed on - "redraw only on a
                                        ; change", per OSAPI_WM_ONDRAG's own
                                        ; warning that it fires per mouse
                                        ; packet and a repaint per packet is
                                        ; tens of ms on a 4.77MHz machine
lg_dragging       equ lg_drag_row + 2  ; byte: a press is armed on the grid
lg_selvc2         equ lg_dragging + 1  ; lg_drawsel's viewport-clamped
lg_selvr2         equ lg_selvc2 + 2    ; bottom-right, in window cells

; stage 3.0b: the formula bar's content box, as a real os88line field. Its
; rect is refreshed from the live geometry on every draw (the window moves and
; resizes), so only LN_BUF/LN_MAX are set once at entry.
lg_fline          equ lg_selvr2 + 2    ; OS88LINE_SZ bytes

; stage 3.0a+: the two scroll bars. Both use os88ui.inc's OWN seven-word block
; layout - x1,y1,x2,y2 (absolute, inclusive), total, fit, pos - so the vertical
; one is passed straight to os88ui_sbar/sbhit/sbgrab/sbtrack, and the private
; horizontal one below is a transposition of the same words rather than a
; different structure (see lg_hsb_* for why it is private and what it is
; staged to become).
lg_vsb            equ lg_fline + 20    ; 7 words
lg_hsb            equ lg_vsb + 14      ; 7 words
lg_sb_oldpos      equ lg_hsb + 14      ; word: the pos a scroll started from,
                                        ; for os88ui_sbmove's cheap redraw
lg_hsb_dragon     equ lg_sb_oldpos + 2 ; byte: 1 = a horizontal thumb drag is
                                        ; live (the vertical one's state is
                                        ; os88ui.inc's own static)
lg_hsb_dragoff    equ lg_hsb_dragon + 1 ; word: press x - thumb left
; lg_hsb_*'s own scratch. The rect is copied out of the block before ANY
; drawing, because the gfx primitives take AX/BX/CX/DX as their rect and BX is
; also the block pointer - holding both in BX is the clobber this codebase has
; hit three times already.
lg_hsb_x1         equ lg_hsb_dragoff + 2
lg_hsb_y1         equ lg_hsb_x1 + 2
lg_hsb_x2         equ lg_hsb_y1 + 2
lg_hsb_y2         equ lg_hsb_x2 + 2
lg_hsb_tl         equ lg_hsb_y2 + 2    ; the thumb's left
lg_hsb_tw         equ lg_hsb_tl + 2    ; ...and its width

; stage 3.0b: the note table's claim, and the Note... dialog's state. The
; EDIT BUFFER IS REAL BSS rather than a pointer into the arena, because the
; arena is append-only: the dialog edits a copy and only commits it on OK, so
; Cancel costs nothing and a refused commit leaves the old note intact.
lg_nnote          equ lg_hsb_tw + 2   ; word: records in it
                                       ; user can still move behind a
                                       ; non-modal dialog
                                       ; per button (os88ui_btn takes a
                                       ; POINTER to it)

; stage 3.0c: the generic one-line input dialog, shared by Goto..., Row
; Height... and Column Width... (see LG_ID_* for why one dialog serves three).
lg_idlg_win       equ lg_nnote + 2 ; word: 0 = none, the single-instance
lg_idlg_kind      equ lg_idlg_win + 2  ; byte: LG_ID_*                   gate
lg_idlg_buf       equ lg_idlg_kind + 1 ; LG_EDITMAX bytes: what is typed
lg_idlg_line      equ lg_idlg_buf + LG_EDITMAX   ; OS88LINE_SZ bytes
lg_idlg_ox        equ lg_idlg_line + 20
lg_idlg_oy        equ lg_idlg_ox + 2
lg_idlg_rect      equ lg_idlg_oy + 2   ; 8 words: OK's rect, then Cancel's
lg_idlg_btrec     equ lg_idlg_rect + 16 ; the standard button record

; stage 3.0e: absolute references. Each scanner records whether the reference
; it is looking at pinned its column and/or its row with '$', and its adjuster
; then declines to move the pinned half - that refusal is the whole feature.
lg_rw_absc        equ lg_idlg_btrec + OS88UI_BT_SIZE ; byte: Insert/Delete's scanner
lg_rw_absr        equ lg_rw_absc + 1
lg_cp_absc        equ lg_rw_absr + 1   ; byte: Copy/Paste + Fill's scanner
lg_cp_absr        equ lg_cp_absc + 1
lg_cp_dead        equ lg_cp_absr + 1   ; byte: the paste shift took this
                                       ; reference off the sheet (81.26.1)

; stage 3.0d: which cell the evaluator is CURRENTLY inside, for ROW()/COLUMN().
; Saved and restored around each lg_eval_cell so a formula reached through
; another cell's reference still answers for itself, not for whoever asked.
lg_rc_ccol        equ lg_cp_dead + 1   ; the cell that OWNS the formula being
lg_rc_crow        equ lg_rc_ccol + 2   ; converted to or from R1C1 - every
                                       ; relative offset is measured from it
lg_evrow          equ lg_rc_crow + 2   ; word: 0-based
lg_evcol          equ lg_evrow + 2     ; word: 0-based
; 81.75: the value accumulator the evaluator carries, and every scratch word
; apps/os88fix.inc's header says the caller owes it. FOUR BYTES, not eight -
; a hundredth-count, not a double - and the block that fed the IEEE mantissa,
; its sticky bit, the 128-bit product, the 80-bit coprocessor forms and the
; transcendental layer's four temporaries is gone with it: 170 bytes to 42.
lg_acc            equ lg_evcol + 2     ; 4: the expression's current value
lg_lhs            equ lg_acc + 4       ; 4: a binary operator's left operand,
                                       ; recovered from the stack
fx_a              equ lg_lhs + 4       ; 4: accumulator A
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
lg_pb_c0          equ fx_nn + 8        ; the paste block's landing
lg_pb_r0          equ lg_pb_c0 + 2     ; corner...
lg_pb_x           equ lg_pb_r0 + 2     ; ...the cell being written
lg_pb_y           equ lg_pb_x + 2
lg_pb_cur         equ lg_pb_y + 2      ; ...and where the reader is
lg_pb_len         equ lg_pb_cur + 2
lg_tabanchor      equ lg_pb_len + 2        ; word: 0 = no Tab run in progress,
                                       ; else the run's start column PLUS ONE
lg_fl_scol        equ lg_tabanchor + 2 ; lg_fill_copy's source cell...
lg_fl_dcol        equ lg_fl_scol + 2   ; ...and its destination
lg_needld         equ lg_fl_dcol + 2   ; byte: an ARG_FILE document is
                                       ; noted and not yet read
lg_argdir         equ lg_needld + 1    ; word: the directory it is in
lg_argdrv         equ lg_argdir + 2    ; byte: ...and that volume
lg_savepend       equ lg_argdrv + 1    ; byte: File Format's OK owes a Save As

; The damage-rect machinery (perf review): what a selection move or a scroll
; actually dirtied, so the hot paths stop paying the ~1s full repaint.
lg_commitdirty    equ lg_savepend + 1  ; byte: lg_commit stored something -
                                       ; lg_selpaint consumes it and pays the
                                       ; full repaint (dependent formulas)
lg_chartdirty     equ lg_commitdirty + 1 ; byte: a cell record changed since
                                       ; the chart last resynced (lg_repaint's
                                       ; tail reads it, lg_addcell/
                                       ; lg_removecell set it)
lg_oldc1          equ lg_chartdirty + 1 ; lg_selbank's bank of the ordered
lg_oldc2          equ lg_oldc1 + 2     ; rect a selection move started from...
lg_oldr1          equ lg_oldc2 + 2
lg_oldr2          equ lg_oldr1 + 2
lg_oldscol        equ lg_oldr2 + 2     ; ...and the scroll origin
lg_oldsrow        equ lg_oldscol + 2
lg_dmgc1          equ lg_oldsrow + 2   ; the range the ranged grid painters
lg_dmgc2          equ lg_dmgc1 + 2     ; draw (window-relative cells,
lg_dmgr1          equ lg_dmgc2 + 2     ; inclusive; lg_dmgfull = the whole
lg_dmgr2          equ lg_dmgr1 + 2     ; viewport)
lg_blitx1         equ lg_dmgr2 + 2     ; lg_scrollrow_blit's rect (also
lg_blitx2         equ lg_blitx1 + 2    ; lg_dmgdraw's band-fill x span)...
lg_blity1         equ lg_blitx2 + 2
lg_blity2         equ lg_blity1 + 2
lg_blitdel        equ lg_blity2 + 2    ; ...and its signed row delta
; --- the lookup search's banked state (SPEC.md 81.32) ------------------------
; THE SCAN CALLS lg_getcell2 PER CANDIDATE, and that recurses into a whole
; evaluation for any formula cell it lands on - which is exactly why 81.23's
; lg_arg1col/lg_arg1row are not lg_r1col/lg_r1row. Everything the scan needs
; across that call is banked here, out of the parser's reach.
                                       ; 65 bytes and the task stack is 384
                                       ; (20.6 rule 6), so banking it per
                                       ; nesting level is not available -
                                       ; a search reached from inside a
                                       ; searched range REFUSES instead (47),
                                       ; which is a stated limit rather than
                                       ; a silently wrong answer
                                       ; MATCH's match type
                                       ; lg_lk_idx - see lg_lkone
lg_pacc2          equ lg_blitdel + 2       ; 8: the SUM OF SQUARES, beside lg_pacc's
                                       ; sum, for the variance folds (81.34)
lg_tr0        equ lg_pacc2 + 8        ; 8 } two packed doubles that survive a
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
lg_stbusy         equ lg_tr0 + 8        ; byte: a variance fold is running. Only
                                       ; ONE can be, for lg_pacc2's sake - see
                                       ; 81.34.1
lg_rndlo      equ lg_stbusy + 2      ; RAND's 32-bit LCG state
lg_rndhi      equ lg_rndlo + 2
lg_ps_ownsheet    equ lg_rndhi + 2   ; word: 81.45.4's banked sheet
lg_ps_mode    equ lg_ps_ownsheet + 2  ; byte: which parts of a copied cell the
                                       ; paste in progress is for (81.45)
                                       ; a volatile function (81.44)
lg_sepch          equ lg_ps_mode + 2      ; byte: CSV/TXT's delimiter (81.40)
lg_sepend     equ lg_sepch + 2       ; word: the staging buffer's end
; 81.75: with the module resident, SHOUT is a near call and nothing reaches
; back through a vector - so the table is not merely unused, it is 568 bytes
; of bss that would be zeroed at every launch. The chain carries on from
; where it would have started.
lg_colwtab    equ lg_sepend + 2      ; 256: 81.56's column widths (81.75)
lg_v_end      equ lg_colwtab + 256

lg_abon           equ lg_v_end         ; byte: the About card is up (20.5.1)
                                       ; UPSTREAM added this against
                                       ; lg_blitdel, where this fork had
                                       ; already grown a chain - so it is
                                       ; re-anchored on the end of it
lg_nf_sec         equ lg_abon + 1       ; LG_STR_MAX+1: the format section
lg_nf_num         equ lg_nf_sec + LG_STR_MAX + 1 ; LG_NUMBUF_MAX+1: its number
lg_nf_cx          equ lg_nf_num + LG_NUMBUF_MAX + 1 ; word: decimals, zeros
lg_nf_fl          equ lg_nf_cx + 2       ; byte: grouping, percent, exponent
lg_nf_neg         equ lg_nf_fl + 1       ; byte: the mantissa was negative
lg_nf_wd          equ lg_nf_neg + 1      ; byte: weekday 0-6
lg_nf_h           equ lg_nf_wd + 1       ; byte: hour 0-23
lg_nf_mi          equ lg_nf_h + 1        ; byte: minute
lg_nf_s           equ lg_nf_mi + 1       ; byte: second
lg_nf_12          equ lg_nf_s + 1        ; byte: AM/PM in the code
lg_nf_lasth       equ lg_nf_12 + 1       ; byte: the last token was an h
lg_nf_rl          equ lg_nf_lasth + 1    ; byte: an m run's length
lg_nf_id          equ lg_nf_rl + 1       ; byte: the id lg_numfmt drew by
lg_nf_r1          equ lg_nf_id + 1       ; word: Format Number's top row
lg_nf_r2          equ lg_nf_r1 + 2       ; word: ...and bottom
lg_defch          equ lg_nf_r2 + 2       ; word: the standard column width
lg_vcw            equ lg_defch + 2       ; LG_MAXVC: the visible columns'
                                         ; widths, in characters (81.56)
lg_undoseg        equ lg_vcw + LG_MAXVC  ; word: Undo's claim, 0 when none (81.57)
lg_ud_busy        equ lg_undoseg + 2     ; byte: an undoable command is running
lg_ud_lab         equ lg_ud_busy + 1     ; byte: its label (LG_UL_*)
lg_ud_redo        equ lg_ud_lab + 1      ; byte: the snapshot is the REDO
lg_vrh            equ lg_ud_redo + 1     ; LG_MAXVR: the visible rows' heights,
                                         ; in pixels (81.60)
lg_gridw          equ lg_vrh + LG_MAXVR  ; word: the grid's width in pixels...
lg_gridh          equ lg_gridw + 2       ; word: ...and its height (lg_geom)
lg_rtoff          equ lg_gridh + 2       ; word: the drawn row's text offset
lg_macro_ctl      equ lg_rtoff + 2   ; byte: what the step asked (LG_MC_*)
lg_macro_ncol     equ lg_macro_ctl + 1   ; word: ...where to, for GOTO, NEXT,
lg_macro_exec     equ lg_macro_ncol + 2  ; byte: the step engine is evaluating
lg_macro_wait     equ lg_macro_exec + 1 ; byte: what a resume means (LG_MW_*)

; 81.65's own scratch: the database and criteria rectangles, kept apart from
; lg_arg1col/lg_arg2col (which a nested reference argument overwrites the
; instant the NEXT argument is parsed, lg_pargref's own header) and from
; lg_r1col/lg_r2col (lg_foldrange's own loop bounds) for the same reason -
; these stay live across the WHOLE scan, not just across one lg_pargref call.
                                       ; resolved once
                                       ; re-resolved per column per row
                                       ; testing (lg_dbrowmatch)
                                       ; across the database cell's own read
                                       ; (lg_dbtest)
                                       ; - re-entrancy is REFUSED, not guarded
                                       ; (see lgm_pdatabase's own header)
                                       ; it knows to clear it again

; 81.66's own scratch: CELL's parsed type_of_info and the (col,row) it is
; answering about, from an explicit reference or the current selection

; 81.67's own scratch: the array/matrix functions. lg_mx_r1/c1/r2/c2 is the
; first (or only) array argument's rectangle, lg_mx_r1b/c1b/r2b/c2b MMULT's
; second; lg_mx_rows/cols and lg_mx_rows2/cols2 their sizes, capped at
; LG_MX_N each way. lg_mx_buf is the shared elimination workspace -
; LG_MX_N rows by LG_MX_W (twice that) columns of packed doubles, wide
; enough to hold [A|I] for MINVERSE's Gauss-Jordan and MDETERM's plain
; triangulation alike, never both at once (lg_mx_busy). The regression
; family (LINEST/LOGEST/TREND/GROWTH) needs no matrix at all - just the
; four running sums a least-squares line is built from.
                                     ; refused, not guarded, lg_db_busy's
                                     ; own reason (81.65)
                                     ; explicitly FALSE

; the regression family's own scratch (LINEST/LOGEST/TREND/GROWTH). t1/t2 are
; a generic pair of packed-double temps - the CURRENT point's x and y while
; lg_mx_regsums is summing, then a subexpression each while lg_mx_fitline is
; solving for the line - never live at once, so one pair covers both, the
; way lg_mx_buf covers MDETERM's triangulation and MINVERSE's Gauss-Jordan
; without needing to be two buffers.
                                       ; `const` argument was FALSE
                                         ; rather than the default 1,2,3,...
                                          ; given explicitly
                                         ; summing (LOGEST/GROWTH fit
                                         ; ln(y) = ln(b) + x*ln(m))
                                     ; through AX/BX, since lg_mx_addr wants
                                     ; both at once and only has two input
                                     ; registers
                                     ; elimination workspace
; 81.71's own state: the Data menu's four database COMMANDS. lg_ex_* is the
; extract range, PINNED when Extract's dialog opens rather than read live at
; OK (81.6 - these dialogs are not modal, and the selection can move under
; one). lg_dfindmode is the Find/Exit Find relabel, and lg_dbc_res is how the
; module answers, since CF on that door already means "is there a module".
lg_planvec        equ lg_macro_wait + 1   ; 81.75: PLAN's ch_ovcall stages
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
                                              ; before them (lg_ser_next)

; Data ▸ Form (81.71.5) - the sixth dialog engine's own state. The rectangle
; is PINNED at open, like Extract's; lg_df_rec/fld/top are where the form is
; standing in it, and lg_df_sv* bank the real selection across the lg_commit
; that writes a field back (lg_commit's argument IS the selection).
lg_bss_end        equ lg_planvec + 2

; -----------------------------------------------------------------------------
; The bss size above is a PLAIN LITERAL and nothing in the toolchain checks it
; against the equ chain - setting it low is silent corruption of whatever the
; loader placed next, not a build error. It cannot simply be written as
; `OS88_BSS lg_bss_end - os88_image_end`: OS88_BSS_SIZE goes into the package
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
%define LG_BSS_NEED (lg_bss_end - os88_image_end)
    times (LG_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - LG_BSS_NEED) db 0
