; =============================================================================
; os8088 - apps/sheet/sheet.asm
;
; SHEET - a spreadsheet to complement Word. This file is stage 1.2 of the
; project roadmap, built in three pieces within this same revision:
;   (a) the 256x16384 grid and the sparse cell storage it requires (THIS
;       PASS), plus visible gridlines;
;   (b) formulas - arithmetic, cell references, SUM/AVERAGE/MIN/MAX/COUNT
;       over ranges (NEXT PASS, not in this file yet);
;   (c) an expanded file format alongside SYLK (AFTER THAT).
; Prefix sh_.
;
; WHY STORAGE HAD TO CHANGE. Stage 1.0's grid was 64x64 - 4096 cells - kept
; as a flat 512-byte occupancy bitmap plus a 4096-word value array, both
; package bss. 256x16384 is 4,194,304 possible cells: a dense bitmap alone
; would be 512KB, dwarfing the package's entire 60KB image+bss budget
; (SPEC.md 20) before a single value is stored. Real sheets are sparse -
; a handful to a few hundred occupied cells out of millions possible - so
; storage becomes an array of (row, col, value) records, kept SORTED by
; (row, col) and searched with a binary search, living in memory the
; package's own segment cannot hold: a claim from the heap (SPEC.md 50.3,
; OSAPI_MEM_CLAIM), taken once from the entry proc before the window
; exists, exactly as the SDK describes it - "a canvas, a sound clip, a
; decoder's tables". The claim is a full 64KB-addressable segment of its
; own; a 12-byte record and a 16KB claim cap the sheet at 1365 distinct
; cells, comfortably past anything hand-entered in this environment. Two
; more claims hold the formula text (arena, append-only) and the file I/O
; staging buffer - both would have blown the package's own budget too.
;
; sh_findcell binary-searches the sorted array; sh_addcell/sh_removecell
; keep it sorted by shifting the tail up or down one record's worth of
; bytes around the insertion or removal point. This trades an O(n) insert
; for an O(log n) lookup, which is the right trade for a grid that is
; painted far more often than it is edited.
;
; LAYOUT, SELECTION, EDITING, DRAWING MODEL: unchanged from stage 1.0
; (see git history / the stage 1.0 header) except:
;   - the selected cell's row is now a WORD (0..16383) everywhere, since it
;     no longer fits a byte;
;   - the row header is wider (5 digits) and the default window is a
;     little roomier;
;   - the grid now draws visible cell-boundary lines (OSAPI_GFX_FILL
;     degenerate 1px rectangles) OVER the cell text, because
;     OSAPI_FONT_RUN's opaque erase is exactly one cell wide and would
;     otherwise paint over a line drawn first;
;   - entering a number now requires the WHOLE edit buffer to parse as one
;     signed integer (stage 1.0 silently accepted a typed '.' that its
;     parser then ignored - a latent bug this stage removes along with
;     the character itself, since nothing here does fractional values).
;
; STORAGE MODEL CAVEATS, STATED RATHER THAN HIDDEN: no bounds check against
; 16-bit signed overflow on entry (a value or SUM large enough to wrap does
; so silently, exactly as plain 8086 ADD/MUL would); the formula text arena
; (once formulas land) is append-only and never reclaims a superseded
; formula's old bytes; SYLK is still this project's own honest subset, not
; certified Microsoft interchange - both stage 1.0 tradeoffs, both still
; true here.
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'SHEET', sh_entry, 1

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

; =============================================================================
; Geometry / grid / storage constants
; =============================================================================
SH_COLS      equ 256                ; the roadmap's stage 1.2 ceiling
SH_ROWS      equ 16384
; stage 2.x: Format > Column Width.../Row Height... make these RUNTIME
; values (sh_cellw/sh_cellh/sh_cellch bss words, set from one of these
; presets) rather than compile-time constants - every site below that used
; to read the equ now reads the bss word instead. The three presets below
; are what Column Width.../Row Height... offered while this app had no
; text-input widget of its own; stage 3.0c gave it one (sh_idlg_*, over
; os88line.inc), so both dialogs are REAL NUMERIC ENTRY now and these are
; only the startup defaults. Widths
; must stay multiples of 8 - sh_blank and every OSAPI_FONT_RUN cell text
; is built one glyph (8px) at a time, so a non-multiple would leave a
; fractional glyph column with nothing sensible to draw there.
SH_CW_NARROW equ 40                 ; 5 chars
SH_CW_NORMAL equ 56                 ; 7 chars - the original fixed default
SH_CW_WIDE   equ 80                 ; 10 chars
SH_RH_SHORT  equ 11
SH_RH_NORMAL equ 14                 ; the original fixed default
SH_RH_TALL   equ 18
; stage 3.0c: the bounds real numeric entry has to enforce, now that Row
; Height.../Column Width... take a typed number instead of a 3-way radio.
; Width is in CHARACTERS (Excel's own unit); height is in pixels.
SH_CW_MINCH  equ 1
SH_CW_MAXCH  equ 40                 ; 320px - wider than the window, but the
                                    ; renderer clips and the user asked
SH_RH_MIN    equ 8                  ; one glyph cell: below this no text fits
SH_RH_MAX    equ 48
SH_RH_W      equ 40                 ; row-header column, 5 digits at 8px
SH_CH_H      equ 14
SH_FB_H      equ 16
SH_REF_W     equ 64                 ; stage 2.x: the formula bar's own
                                     ; reference box width - wide enough
                                     ; for the longest possible reference
                                     ; text (a 2-letter column + a 5-digit
                                     ; row, SH_COLS=256/SH_ROWS=16384's own
                                     ; worst case) plus a little padding
; Mirrors of os88ui.inc's own scroll-bar constants. Duplicated here for the
; same reason the CH_* chart constants are (see their comment below): that file
; is %included at the END of this one, so its equs are FORWARD references, and
; a forward-referenced value used as an IMMEDIATE makes NASM size the
; instruction differently on each pass - `cmp cx, imm8` vs `cmp cx, imm16` -
; which fails the assembly outright with "label changed during code
; generation". Values must track os88ui.inc's; they are part of the block
; contract sh_hsb_* is written to be promoted into.
SH_SB_NONE   equ 0
SH_SB_UP     equ 1                  ; the LEFT arrow on a horizontal bar
SH_SB_DOWN   equ 2                  ; ...and the RIGHT one
SH_SB_PGUP   equ 3
SH_SB_PGDN   equ 4
SH_SB_THUMB  equ 5
SH_SB_MINH   equ 8                  ; the shortest thumb that is still a thumb
SH_SB_CELL   equ 10                 ; the arrow cell's depth

SH_VSB_W     equ 14                 ; stage 3.0a+: the vertical scroll bar's
                                     ; width. 14 is what both kernel callers
                                     ; use and what os88ui.inc's arrow glyph
                                     ; is drawn for (5 rows, widths 1..9)
SH_HSB_H     equ 14                 ; ...and the horizontal bar's height, the
                                     ; same cell so the two agree at the
                                     ; corner where they meet
SH_SB_H      equ 16                 ; stage 2.x: the status bar strip at
                                     ; the very bottom of the window,
                                     ; same height as the formula bar for
                                     ; visual symmetry
SH_EDITMAX   equ 63                 ; room for a formula, not just a number
SH_NAMEMAX   equ 12
SH_RW_CAP    equ 80                  ; stage 2.x: sh_formula_reidx's own
                                     ; output cap - a shifted reference can
                                     ; grow by a digit or two (row 9->10,
                                     ; col Z->AA), so a little more than
                                     ; SH_EDITMAX+1

SH_CLAIM_CELLS_KB equ 32            ; -> SH_CELL_CAP records of SH_C_SZ.
                                    ; Doubled with the widening: 20 bytes in
                                    ; 16KB would have DROPPED capacity to 819,
                                    ; and 32KB takes it up to 1638 instead
SH_CLAIM_TXT_KB   equ 8             ; formula text arena (used from the next
                                     ; pass on; claimed now so entry needs no
                                     ; second edit)
SH_CLAIM_STG_KB   equ 32            ; file I/O staging
; sh_docmd_sortcol's own layout within sh_stgseg (stage 2.x: formula cells
; now participate in the sort too, so alongside the original rows[]/
; values[] arrays it also needs a source-index permutation, an
; is-this-a-formula flag, and staged formula text for each one - see the
; section comment above sh_docmd_sortcol for the full design)
SH_SORT_VALS_OFF  equ 4096           ; word/entry (unchanged from before)
SH_SORT_ORIG_OFF  equ 8192           ; word/entry: origidx[] (which
                                     ; pre-sort entry ended up here)
SH_SORT_ISF_OFF   equ 12288         ; byte/entry: 1 if that entry is a
                                     ; formula cell
SH_SORT_FIDX_OFF  equ 16384         ; word/entry: which SH_SORT_FTXT_OFF
                                     ; slot holds that formula's own text
                                     ; (only meaningful when ISF is set)
SH_SORT_FTXT_OFF  equ 20480         ; SH_SORT_FCAP slots of 64 bytes each,
                                     ; ending at 20480+180*64=32000, safely
                                     ; inside the 32KB claim
SH_SORT_FCAP      equ 180           ; max formula cells one sort can carry
                                     ; through - far more than any real
                                     ; column needs; a cell beyond this cap
                                     ; is simply excluded from the sort
                                     ; entirely (same "clip, don't crash"
                                     ; policy used throughout this file)
SH_CLAIM_NOTE_KB  equ 4             ; stage 3.0b: the note table - SH_NOTE_CAP
                                    ; records of SH_NOTE_REC. The note TEXT is
                                    ; not in here; it goes in the formula
                                    ; arena, for the reason sh_nt_findcell's
                                    ; header gives.
SH_CLAIM_BORD_KB  equ 4             ; stage 2.x: the border table (below) -
                                     ; a separate claim rather than growing
                                     ; every cell record, since almost no
                                     ; cell ever has a border and this app
                                     ; already has 3 claims plus its own
                                     ; region (MEM_OWNER_MAX=8, room to spare)
SH_CLAIM_CHART_KB equ 19            ; stage 2.x: the live Chart Column window's
                                     ; offscreen 4bpp canvas - 240x160px, 120
                                     ; bytes/row (already a multiple of 4, so
                                     ; the BMP export below needs no row
                                     ; padding logic) = 19200 bytes -> 19KB.
                                     ; This is Sheet's 5th claim (own region +
                                     ; cellseg/txtseg/stgseg/bordseg), so 6/8
                                     ; of MEM_OWNER_MAX - still room to spare.
                                     ; No pixel-readback API exists anywhere in
                                     ; this OS (checked every OSAPI_GFX_*), so
                                     ; this buffer - not the screen - is the
                                     ; one thing both the on-screen chart (one
                                     ; OSAPI_GFX_BLIT4 of it) and the exported
                                     ; .BMP (one OSAPI_FILE_WRITE of it, same
                                     ; bytes) are drawn from.
; =============================================================================
; THE CELL RECORD (stage 4.0). Every offset below is named, and every stride
; goes through SH_C_SZ, because this layout has now moved once and the plan's
; own risk list puts "a missed stride site" first: it reads a MISALIGNED
; record and hands back a plausible wrong number, with no crash to notice.
; Naming them makes the next move a four-line edit instead of an 87-site
; audit.
;
; +0 and +2 and +4 and +5 are shared in shape with the border and note tables
; (sh_bt_* / sh_nt_*), which is why those four are deliberately NOT renamed
; here - a rename would have had to reach into two other tables to stay
; honest, and they have their own strides.
; =============================================================================
SH_C_ROW     equ 0                  ; word: packed row | sheet
SH_C_COL     equ 2                  ; word
SH_C_FLAGS   equ 4                  ; byte: bit0 HASFORMULA, bit1 EVALUATING
SH_C_FMT     equ 5                  ; byte: SH_FMT_*, and the BIFF XF index
SH_C_TYPE    equ 6                  ; byte: SH_T_* - reserved by stage 4.0's
SH_C_AUX     equ 7                  ; byte: ...error code, likewise reserved.
                                    ; THE TAG IS ITS OWN BYTE AND NOT SPARE
                                    ; BITS OF SH_C_FMT: that byte's numeric
                                    ; value IS the XF index the BIFF writer
                                    ; emits, so borrowing bits 6-7 would
                                    ; silently change every XF in every file
                                    ; this app has ever written.
SH_C_VAL     equ 8                  ; 8 bytes: an IEEE-754 double. Still
                                    ; written and read as a WORD in the low
                                    ; half for now - the widening and the
                                    ; switch to real doubles are separate
                                    ; steps on purpose, so that a fault in
                                    ; either one is unambiguous.
SH_C_FOFF    equ 16                 ; word: formula text offset in sh_txtseg
SH_C_PASS    equ 18                 ; word: the repaint pass that cached VAL
; The value tags stage 4.0 reserves. Numbered so that BLANK is 0 and a
; zeroed record is therefore a blank one.
SH_T_BLANK   equ 0
SH_T_NUM     equ 1
SH_T_TEXT    equ 2
SH_T_BOOL    equ 3
SH_T_ERR     equ 4

SH_C_SZ      equ 20                 ; ...and an EVEN stride, so the array
                                    ; shuffle can move words rather than bytes

; sh_rowcol_op stages every record through sh_stgseg while it shifts a row or
; column, and THAT record kept its original 12-byte shape - it is a transient
; copy, not storage, and nothing about it needs to grow. Named for exactly the
; reason above: the two layouts look alike and one was silently edited into
; the other.
SH_S_SHEET   equ 0
SH_S_ROW     equ 2
SH_S_COL     equ 4
SH_S_FLAGS   equ 6
SH_S_FMT     equ 7
SH_S_VAL     equ 8                  ; 8 bytes since stage 4.0: this record
                                    ; CARRIES a cell's value across a row or
                                    ; column shift, so it had to grow with the
                                    ; cell record or every decimal in the
                                    ; sheet would have been truncated to the
                                    ; low half of its own double - silently,
                                    ; on an Insert Row
SH_S_FML     equ 16
SH_S_SZ      equ 18

SH_CELL_CAP  equ 1638               ; floor(SH_CLAIM_CELLS_KB*1024 / SH_C_SZ)
SH_TXT_CAP   equ 8192               ; SH_CLAIM_TXT_KB in bytes
SH_STAGE_MAX equ 32768
SH_BORD_CAP  equ 819                ; floor(4096 / 5)
SH_NOTE_REC  equ 6                  ; stage 3.0b: the note table's record -
                                    ; packed row/sheet, col, and the note
                                    ; text's offset in the SHARED formula
                                    ; arena (see sh_nt_findcell's header)
SH_NOTE_CAP  equ 682                ; floor(4096 / SH_NOTE_REC)
SH_NOTEMAX   equ 240                ; the longest note the dialog will take,
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
CH_W       equ 240
CH_H       equ 160
CH_STRIDE  equ 120                  ; CH_W / 2 (4bpp, 2px/byte)
CH_HDRSZ   equ 118                  ; 54-byte BMP header + 64-byte palette
CH_PXOFF   equ CH_HDRSZ             ; pixel data starts right after
CH_MAXBARS equ 40                   ; CH_W / (4px bar + 2px gap), no partial
                                     ; column at the right edge
CH_T_COLUMN equ 0                   ; stage 3.0f: the gallery. Excel calls the
CH_T_BAR    equ 1                   ; vertical one Column and the horizontal
CH_T_LINE   equ 2                   ; one Bar, and this follows that naming
CH_T_AREA   equ 3                   ; rather than the intuitive-but-wrong one
CH_BARW    equ 4
CH_GAP     equ 2
SH_CHARTWIN_W equ 260                ; a little margin around the CH_W x
SH_CHARTWIN_H equ 200                ; CH_H canvas - real size comes back
                                      ; from OSAPI_WM_CONTENT either way
SH_EVAL_MAXDEPTH equ 6               ; a formula referencing a formula
                                      ; referencing a formula...; each level
                                      ; gets its own text buffer (below) so a
                                      ; nested evaluation cannot overwrite
                                      ; the text an outer one is still
                                      ; parsing. Beyond this many levels a
                                      ; reference just reads as 0 - the same
                                      ; honest simplification as every other
                                      ; unbounded case here.

; --- stage 1.6: per-cell text formatting -----------------------------------
; Packed into the cell record's byte at +5 (previously unused padding, see
; the record layout comment above sh_findcell): bit0 bold, bit1 underline,
; bits3-2 alignment, bits5-4 number format. Bits6-7 are unused. This exact
; 6-bit space is also, not coincidentally, this app's BIFF XF index on disk
; (sh_dowrite_biff) - see the comment there for why that pairing is safe.
SH_FMT_BOLD          equ 0x01
SH_FMT_UNDER         equ 0x02
SH_FMT_BU_CLR        equ 0xFC        ; ~(SH_FMT_BOLD|SH_FMT_UNDER) & 0xFF -
                                      ; stage 1.8's Font dialog clears bits
                                      ; 0-1 in one mask, not two XORs
SH_FMT_ALIGN_MASK    equ 0x0C
SH_FMT_ALIGN_CLR     equ 0xF3        ; ~SH_FMT_ALIGN_MASK & 0xFF
SH_FMT_ALIGN_SHIFT   equ 2
SH_FMT_ALIGN_GENERAL equ 0           ; General: right, same as this app's
                                      ; only-ever-numeric default
SH_FMT_ALIGN_LEFT    equ 1
SH_FMT_ALIGN_CENTER  equ 2
SH_FMT_ALIGN_RIGHT   equ 3
SH_FMT_NUM_MASK      equ 0x30
SH_FMT_NUM_CLR       equ 0xCF        ; ~SH_FMT_NUM_MASK & 0xFF
SH_FMT_NUM_SHIFT     equ 4
SH_FMT_NUM_GENERAL   equ 0
SH_FMT_NUM_CURRENCY  equ 1
SH_FMT_NUM_COMMA     equ 2
SH_FMT_NUM_PERCENT   equ 3

; --- stage 2.x: cell borders (Format > Border..., its own sh_bordseg claim
; and sh_bt_* table - see the SH_CLAIM_BORD_KB comment above for why this
; isn't just more bits in the format byte) ----------------------------------
SH_BORD_LEFT   equ 0x01
SH_BORD_RIGHT  equ 0x02
SH_BORD_TOP    equ 0x04
SH_BORD_BOTTOM equ 0x08
SH_BORD_SHADE  equ 0x10
SH_BORD_EDGES  equ 0x0F             ; Left|Right|Top|Bottom together

; sh_doread_biff's FONT/XF tracking tables (a real file might reference more
; than this app itself ever writes - beyond the cap, a cell just reads back
; as unformatted rather than growing these tables without bound)
SH_BIFF_FONT_CAP equ 32
SH_BIFF_XF_CAP   equ 64

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
; would run out fast). SH_ROWS needs exactly 14 bits (0..16383), leaving
; exactly 2 spare bits in that word for a sheet index - hence exactly
; SH_SHEETS=4, not a rounder number chosen for its own sake.
SH_SHEETS    equ 4
SH_ROW_BITS  equ 14                  ; row occupies bits 0-13
SH_ROW_MASK  equ 0x3FFF

; --- stage 2.x: Sheet's own in-window menu bar -----------------------------
; MENU_APPMAX is five (apps/os88api.inc) and real Excel 2.1's bar is eight
; real menus (File/Edit/Format/Data/Options/Macro/Help, plus this app's own
; Sheets switcher, which has no real-Excel equivalent since Excel used
; separate windows per sheet rather than one packed instance - see the
; stage 2.0 comment above). Word.O88 hit the exact same ceiling and answered
; it the same way (see apps/word/word.asm's "Word chrome" section, SPEC.md
; 68.2): draw the bar and its dropdowns IN THE WINDOW instead of asking the
; kernel for one, and register only the kernel's minimum single-item
; placeholder (sh_mf_ret below) so the bar still gets an app-name pulldown.
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
SH_MBAR_H    equ 14                  ; the in-window menu bar strip
SH_MI_H      equ 12                  ; a dropdown item's row height
SH_MPAD      equ 8                   ; left/right pixel pad per title/item
SH_MENU_N    equ 9                   ; File,Edit,Formula,Format,Data,Options,
                                      ; Macro,Sheets,Help - Excel 2.1d's own
                                      ; bar order (see sh_mtab). NOTE this
                                      ; also sizes sh_mw in the bss chain, so
                                      ; changing it moves OS88_BSS too.
SH_M_NONE    equ 0xFF

; =============================================================================
; sh_entry - package entry point (SPEC.md 20.2). Claims run here, and only
; here (SPEC.md 50.3): this is the one place a package has no window yet
; and is sizing itself. A claim failure aborts the launch (CF=1) rather
; than opening a sheet that cannot hold anything - the kernel tears down
; whatever we did claim either way (no teardown hook owed).
; =============================================================================
sh_entry:
    push ax
    push dx
    push si
    push di
    call fp_init                      ; before the first claim, because every
                                      ; other thing here can fail and be
                                      ; recovered from and this one decides
                                      ; which arithmetic the session gets
    mov ax, SH_CLAIM_CELLS_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [sh_cellseg], dx
    mov ax, SH_CLAIM_TXT_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [sh_txtseg], dx
    mov ax, SH_CLAIM_STG_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [sh_stgseg], dx
    mov ax, SH_CLAIM_BORD_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [sh_bordseg], dx
    mov word [sh_nbord], 0
    mov ax, SH_CLAIM_NOTE_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [sh_noteseg], dx
    mov word [sh_nnote], 0
    mov ax, SH_CLAIM_CHART_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [sh_chartseg], dx
    mov word [sh_chartwin], 0
    mov word [sh_chart_cnt], 0
    mov word [ch_type], CH_T_COLUMN
    push si
    push di
    push cx
    push es
    mov es, dx                          ; copy the constant 118-byte BMP
    mov si, ch_hdrtpl                   ; header+palette into the buffer once
    xor di, di                          ; here - ch_bmp_write only ever stages
    mov cx, CH_HDRSZ                    ; whatever is already sitting there,
    cld                                 ; it never rebuilds it (see
    rep movsb                           ; os88chart.inc's own header comment)
    pop es
    pop cx
    pop di
    pop si
    mov word [sh_ncells], 0
    mov word [sh_txtlen], 0
    mov si, sh_tpl
    call OSAPI_WM_CREATE
    jc .fail
    mov [sh_ownwin], bx               ; stage 2.0: os88ui_ask needs our own
                                       ; window ptr, and it's asked for from
                                       ; sh_macro_eval, which has no window
                                       ; ptr of its own to hand it - Sheet
                                       ; only ever has the one window, so
                                       ; capturing it once here is safe
    mov byte [sh_mopen], SH_M_NONE    ; stage 2.x: Sheet's own menu bar -
    mov byte [sh_mhi], SH_M_NONE      ; see the SH_MBAR_H section comment
    mov byte [sh_gridlines], 1
    mov byte [sh_showformulas], 0
    mov word [sh_i_options], sh_it_grid_on   ; match sh_i_options's own
                                              ; label to the actual default
                                              ; (sh_it_form_off already does,
                                              ; since Formulas defaults off)
    mov word [sh_cellw], SH_CW_NORMAL        ; stage 2.x: runtime cell size
    mov word [sh_cellh], SH_RH_NORMAL        ; defaults - see the SH_CW_*/
    mov word [sh_cellch], SH_CW_NORMAL / 8   ; SH_RH_* section comment
    call sh_mkblank
    call sh_mtab_calc

    ; stage 3.0a: drag-to-select. BX is still the window OSAPI_WM_CREATE just
    ; answered. CF=1 means kern_small, which carries the slot and not the body
    ; (os88api.inc: "TEST CF AND HAVE A SECOND PATH") - there is simply no
    ; tracking on that machine, and shift+click and shift+arrows, which need
    ; no kernel support at all, remain the way to build a range there.
    mov ax, sh_ondrag
    call OSAPI_WM_ONDRAG

    ; The RELEASE edge, which a thumb drag needs to let go on (13.10.5). Same
    ; kern_small caveat as the drag edge above: refused there, and a bar that
    ; cannot be dragged never needs dropping.
    mov ax, sh_onmouseup
    call OSAPI_WM_ONMOUSEUP

    ; stage 3.0b: the formula bar's content box. Only the buffer binding is
    ; set once - the rect is refreshed per draw by sh_flrect, since the window
    ; moves and resizes and a stale rect would draw and hit-test in the wrong
    ; place.
    mov word [sh_fline + LN_BUF], sh_editbuf
    mov word [sh_fline + LN_MAX], SH_EDITMAX + 1

    ; Arm the key-state map now rather than on the user's first shift+click.
    ; kbd_down arms itself on the first ASK and its first answer is always
    ; "up" (kernel/mouse.inc's own note), so without this the very first
    ; shift+click of a session would read as an unshifted one.
    mov al, 0x2A
    call OSAPI_KEY_DOWN

    mov si, sh_menus
    call OSAPI_MENU_SET
    mov si, sh_defname
    mov di, sh_name
    call sh_strcpy
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
; sh_geom - in: BX = window ptr
; out: [sh_ox]/[sh_oy] content origin, [sh_cw]/[sh_ch] content size,
;      [sh_vcols]/[sh_vrows] grid cells that fit given the current scroll;
;      all registers preserved
; -----------------------------------------------------------------------------
sh_geom:
    push ax
    push cx
    push dx
    call OSAPI_WM_CONTENT
    mov [sh_ox], ax
    mov [sh_oy], dx
    add dx, SH_MBAR_H                  ; sh_goy: where the formula bar and
    mov [sh_goy], dx                   ; everything below it actually starts,
                                        ; now that the menu bar (SH_MBAR_H
                                        ; section comment) sits above them -
                                        ; sh_oy itself stays the RAW content
                                        ; origin, since sh_mbar_draw needs
                                        ; that one, not the shifted one
    call OSAPI_WM_GEOM
    mov [sh_cw], cx
    mov [sh_ch], dx

    mov ax, cx
    sub ax, SH_RH_W + SH_VSB_W         ; the vertical bar owns a strip at the
    jns .cw_ok                          ; right, so the grid is that much
    xor ax, ax                          ; narrower
.cw_ok:
    xor dx, dx
    mov cx, [sh_cellw]
    div cx
    mov cx, SH_COLS
    sub cx, [sh_scrollcol]
    cmp ax, cx
    jbe .cset
    mov ax, cx
.cset:
    mov [sh_vcols], ax

    mov ax, [sh_ch]
    sub ax, SH_MBAR_H + SH_FB_H + SH_CH_H + SH_SB_H + SH_HSB_H
    jns .chh_ok                         ; ...and the horizontal bar a strip
    xor ax, ax                          ; above the status bar
.chh_ok:
    xor dx, dx
    mov cx, [sh_cellh]
    div cx
    mov cx, SH_ROWS
    sub cx, [sh_scrollrow]
    cmp ax, cx
    jbe .rset
    mov ax, cx
.rset:
    mov [sh_vrows], ax

    pop dx
    pop cx
    pop ax
    ret

; =============================================================================
; Callbacks
; =============================================================================

sh_paint:
    push bx
    mov bx, si
    call sh_geom
    call sh_drawall
    pop bx
    ret

sh_repaint:
    push ax
    push bx
    push cx
    push dx
    mov bx, si
    call sh_geom
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [sh_ox]
    mov bx, [sh_oy]
    mov cx, [sh_ox]
    add cx, [sh_cw]
    dec cx
    mov dx, [sh_oy]
    add dx, [sh_ch]
    dec dx
    call OSAPI_GFX_FILL
    call sh_drawall
    cmp word [sh_chartwin], 0           ; stage 2.x: keep the live Chart Column
    je .nochart                         ; window in sync with every data-
    push bx                            ; changing command that already routes
    mov bx, [sh_chartwin]              ; through sh_repaint - skip the redraw
    call OSAPI_WM_OBSCURED              ; entirely while nobody can see it
    jc .chartobscured                   ; (also covers "hidden via its own
    call sh_chart_scan                  ; close box", which only hides it -
    call sh_chart_render                ; see sh_docmd_chart's window-lifecycle
    mov si, [sh_chartwin]               ; comment). sh_chart_render only
    call sh_chart_paint                 ; re-rasterizes whatever is already
                                         ; staged - sh_chart_scan is what
                                         ; actually re-reads the charted
                                         ; column's current values first.
.chartobscured:
    pop bx
.nochart:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_onclick - W_ONCLICK: CX=x, DX=y (screen), SI=window; gfx lock held
; -----------------------------------------------------------------------------
sh_onclick:
    push ax
    push bx
    push cx
    push dx
    cmp word [sh_fdlg_win], 0
    je .nofdlg
    call sh_fdlg_close                 ; stage 1.8: a Format dialog isn't
                                        ; kernel-modal (no fdlg_grab/fdlg_top
                                        ; machinery outside the kernel - see
                                        ; the section comment above
                                        ; sh_fdlg_open), so a click that
                                        ; reaches the main grid at all means
                                        ; the dialog visually lost focus;
                                        ; treat it as Cancel rather than
                                        ; leave sh_fdlg_win stuck non-zero,
                                        ; which would gate every future
                                        ; Format menu command shut for good
.nofdlg:
    cmp word [sh_bdlg_win], 0          ; same non-modal gate-lock risk, same
    je .nobdlg                         ; recovery, for the Border dialog
    call sh_bdlg_close
.nobdlg:
    mov word [sh_msg], 0
    mov byte [sh_dragging], 0          ; stage 3.0a: a gesture is only a grid
                                        ; drag if it STARTS on the grid - the
                                        ; menu-bar path below never arms it
    mov bx, si
    call sh_geom
    call sh_mbar_hit                   ; stage 2.x: Sheet's own in-window
    cmp al, SH_M_NONE                  ; menu bar (see the SH_MBAR_H section
    je .notmenu                        ; comment) claims a click on its strip
    call sh_mtrack                     ; before anything below ever sees it -
    jmp .out                           ; AL=menu index (from sh_mbar_hit),
                                        ; SI=window (still this callback's own
                                        ; untouched SI)
.notmenu:
    call sh_sbclick                    ; stage 3.0a+: the two scroll bars get
    jc .out                            ; the click before the grid does
    call sh_gridhit                    ; CX=x, DX=y -> CF=1 + AX=col, BX=row
    jnc .out
    call sh_shiftdown                  ; stage 3.0a: shift+click extends the
    jc .extend                         ; range from the existing anchor
    call sh_select                     ; plain click: collapse and move
    mov byte [sh_dragging], 1          ; ...and arm the drag from here
    push ax
    mov ax, [sh_selcol]
    mov [sh_drag_col], ax
    mov ax, [sh_selrow]
    mov [sh_drag_row], ax
    pop ax
    jmp .out
.extend:
    call sh_select_to
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_select - commit any pending edit, move the selection, scroll to show
; it, and repaint. AX = new column, BX = new row. SI must be the window
; ptr; not touched here so it stays that way for sh_repaint.
; -----------------------------------------------------------------------------
sh_select:
    push ax
    push bx
    call sh_commit
    mov [sh_selcol], ax
    mov [sh_selrow], bx
    mov [sh_selcol2], ax               ; stage 3.0a: a plain select COLLAPSES
    mov [sh_selrow2], bx               ; the range - anchor and extent become
                                        ; the same cell, which is exactly the
                                        ; old single-cell behaviour every
                                        ; existing caller still expects
    call sh_scrollto
    call sh_repaint
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_select_to - stage 3.0a: move only the EXTENT of the range, leaving the
; anchor where it is. AX = column, BX = row. Used by shift+click, shift+arrows
; and the drag handler. SI must be the window ptr (sh_repaint's contract).
;
; Deliberately does NOT call sh_commit: extending a selection is not a
; different-cell move, and committing here would end an in-progress edit
; halfway through a drag.
; -----------------------------------------------------------------------------
sh_select_to:
    push ax
    push bx
    cmp ax, SH_COLS
    jb .colok
    mov ax, SH_COLS - 1
.colok:
    cmp bx, SH_ROWS
    jb .rowok
    mov bx, SH_ROWS - 1
.rowok:
    mov [sh_selcol2], ax
    mov [sh_selrow2], bx
    call sh_scrollto2
    call sh_repaint
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_gridhit - stage 3.0a: which cell is this screen point on?
; in:  CX = x, DX = y (screen coords, W_ONCLICK/W_ONDRAG's own)
; out: CF=1 and AX = column, BX = row (both absolute, scroll-adjusted);
;      CF=0 if the point is not over a grid cell. CX/DX restored.
;
; Lifted verbatim out of sh_onclick so the drag handler hit-tests exactly the
; same way a click does - two copies of this arithmetic would drift the first
; time the header or menu-bar height changed.
; -----------------------------------------------------------------------------
sh_gridhit:
    push cx
    push dx
    mov ax, cx
    sub ax, [sh_ox]
    sub ax, SH_RH_W
    js .no
    mov bx, dx
    sub bx, [sh_goy]                   ; grid origin, NOT raw content origin -
    sub bx, SH_FB_H + SH_CH_H          ; the menu bar strip sits above it
    js .no
    xor dx, dx
    mov cx, [sh_cellw]
    div cx
    cmp ax, [sh_vcols]
    jae .no
    add ax, [sh_scrollcol]
    mov [sh_wcol], ax
    mov ax, bx
    xor dx, dx
    mov cx, [sh_cellh]
    div cx
    cmp ax, [sh_vrows]
    jae .no
    add ax, [sh_scrollrow]
    mov bx, ax
    mov ax, [sh_wcol]
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
; sh_flkey - stage 3.0b: hand one keystroke to the formula bar's field, then
; resync this app's own sh_editlen from the field's LN_LEN so sh_commit and
; every other existing reader keeps working unchanged.
; in: AL = ascii, AH = scan, SI = the window (this callback's own).
; -----------------------------------------------------------------------------
sh_flkey:
    push ax
    push si
    call sh_flrect                     ; the box may have moved since the last
                                        ; draw - os88line hit-tests and draws
                                        ; from the same four words
    mov si, sh_fline
    call os88line_key
    mov ax, [si + LN_LEN]
    mov [sh_editlen], al               ; LN_LEN is a word and SH_EDITMAX is
                                        ; 63, so the low byte is the whole of
                                        ; it - but keep them in step, because
                                        ; sh_commit still reads sh_editlen
    pop si
    pop ax
    call sh_repaint
    ret

; -----------------------------------------------------------------------------
; sh_flsync - stage 3.0b: the buffer was filled by someone other than the
; field (F2's seed-from-cell, or a Paste). Recompute the field's own length
; from the NUL and park the caret at the end, which is where a just-loaded
; value should leave it. Preserves everything.
; -----------------------------------------------------------------------------
sh_flsync:
    push ax
    push cx
    push si
    xor cx, cx
    mov si, sh_editbuf
.cnt:
    cmp byte [si], 0
    je .done
    cmp cx, SH_EDITMAX                 ; never trust an unterminated buffer
    jae .done
    inc si
    inc cx
    jmp .cnt
.done:
    mov [sh_editlen], cl
    mov si, sh_fline
    mov [si + LN_LEN], cx
    mov [si + LN_CAR], cx              ; caret at the end
    mov word [si + LN_VIEW], 0
    mov byte [si + LN_FOCUS], 1
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_editstart - stage 3.0b: begin a fresh, EMPTY edit (the first character
; typed into a cell). Resets both this app's own edit state and the field's.
; -----------------------------------------------------------------------------
sh_editstart:
    push si
    mov byte [sh_editing], 1
    mov byte [sh_editlen], 0
    mov byte [sh_editbuf], 0
    mov si, sh_fline
    mov word [si + LN_LEN], 0
    mov word [si + LN_CAR], 0
    mov word [si + LN_VIEW], 0
    mov byte [si + LN_FOCUS], 1
    pop si
    ret

; -----------------------------------------------------------------------------
; sh_arrowsrc - stage 3.0a: where does an arrow key start counting from?
; out: AX = column, BX = row - the ANCHOR normally, the EXTENT while shift is
; held, which is what makes shift+arrow grow the block from the end the user
; last moved rather than snapping it back to the anchor.
; -----------------------------------------------------------------------------
sh_arrowsrc:
    call sh_shiftdown
    jc .ext
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    ret
.ext:
    mov ax, [sh_selcol2]
    mov bx, [sh_selrow2]
    ret

; -----------------------------------------------------------------------------
; sh_shiftdown - out: CF=1 if either shift key is held. Preserves everything.
; 0x2A/0x36 are the set-1 make codes; kbd_down's map is 128 bits wide, one per
; make code, so it answers for any key and not just the named KSC_* few.
; -----------------------------------------------------------------------------
sh_shiftdown:
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
; sh_ondrag - W_ONDRAG (SPEC.md 13.8.2): the pointer moved while our press was
; armed. CX = x, DX = y, SI = window; UI task, gfx lock held.
;
; REDRAWS ONLY ON A CHANGE, which the slot's own doc insists on: it fires per
; mouse packet, and a repaint per packet is tens of milliseconds each on a
; 4.77MHz machine. [sh_drag_col]/[sh_drag_row] hold the cell we last extended
; to, so sliding within one cell costs a hit-test and nothing else.
; -----------------------------------------------------------------------------
sh_ondrag:
    push ax
    push bx
    push cx
    push dx
    push si
    ; stage 3.0a+: a live scroll-thumb drag owns the gesture before the grid
    ; selection does.
    call sh_sbsync
    call os88ui_sbdragging
    jc .novthumb
    mov bx, sh_vsb
    call os88ui_sbtrack                ; DX = the pointer's y
    jc .out                            ; nothing owed (no move, or the rate)
    call sh_setscrollrow
    jmp .out
.novthumb:
    cmp byte [sh_hsb_dragon], 0
    je .nohthumb
    mov bx, sh_hsb
    call sh_hsb_track                  ; CX = the pointer's x
    jc .out
    call sh_setscrollcol
    jmp .out
.nohthumb:
    cmp byte [sh_dragging], 0
    je .out                            ; this gesture did not start on the grid
    call sh_gridhit
    jnc .out                           ; slid off the grid: leave the range as
                                        ; it was rather than clamping wildly
    cmp ax, [sh_drag_col]
    jne .moved
    cmp bx, [sh_drag_row]
    je .out                            ; same cell as last packet - nothing
.moved:
    mov [sh_drag_col], ax
    mov [sh_drag_row], bx
    mov si, [sh_ownwin]                ; sh_repaint's SI contract
    call sh_select_to
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_selrect - stage 3.0a: normalize the anchor/extent pair into an ordered
; rect. Out: [sh_selc1] <= [sh_selc2], [sh_selr1] <= [sh_selr2]. Every range
; consumer reads these rather than comparing the raw pair itself, so "which
; corner did the user start from" is answered in exactly one place.
; -----------------------------------------------------------------------------
sh_selrect:
    push ax
    push bx
    mov ax, [sh_selcol]
    mov bx, [sh_selcol2]
    cmp ax, bx
    jbe .cols_ok
    xchg ax, bx
.cols_ok:
    mov [sh_selc1], ax
    mov [sh_selc2], bx
    mov ax, [sh_selrow]
    mov bx, [sh_selrow2]
    cmp ax, bx
    jbe .rows_ok
    xchg ax, bx
.rows_ok:
    mov [sh_selr1], ax
    mov [sh_selr2], bx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_selsingle - out: CF=1 if the selection is a single cell (anchor==extent).
; The gate every command that has no range semantics yet uses.
; -----------------------------------------------------------------------------
sh_selsingle:
    push ax
    mov ax, [sh_selcol]
    cmp ax, [sh_selcol2]
    jne .no
    mov ax, [sh_selrow]
    cmp ax, [sh_selrow2]
    jne .no
    stc
    jmp .out
.no:
    clc
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_scrollto - move the scroll origin the least amount that brings the
; current selection into the viewport described by [sh_vcols]/[sh_vrows]
; -----------------------------------------------------------------------------
sh_scrollto:
    push ax
    mov ax, [sh_selcol]
    mov [sh_sc_tcol], ax
    mov ax, [sh_selrow]
    mov [sh_sc_trow], ax
    pop ax
    jmp sh_scrollto_t

; stage 3.0a: the same scroll, aimed at the range's moving END instead of its
; anchor - what a drag or a shift+arrow needs, since it is the extent that
; walks off-screen, not the anchor.
sh_scrollto2:
    push ax
    mov ax, [sh_selcol2]
    mov [sh_sc_tcol], ax
    mov ax, [sh_selrow2]
    mov [sh_sc_trow], ax
    pop ax
    jmp sh_scrollto_t

; the core: bring [sh_sc_tcol]/[sh_sc_trow] into the viewport, moving the
; scroll origin the least amount that does it
sh_scrollto_t:
    push ax
    push bx
    mov ax, [sh_sc_tcol]
    mov bx, [sh_scrollcol]
    cmp ax, bx
    jae .cfwd
    mov [sh_scrollcol], ax
    jmp short .rows
.cfwd:
    add bx, [sh_vcols]
    cmp bx, 0
    je .rows
    dec bx
    cmp ax, bx
    jbe .rows
    sub ax, [sh_vcols]
    inc ax
    mov [sh_scrollcol], ax
.rows:
    mov ax, [sh_sc_trow]
    mov bx, [sh_scrollrow]
    cmp ax, bx
    jae .rfwd
    mov [sh_scrollrow], ax
    jmp short .out
.rfwd:
    add bx, [sh_vrows]
    cmp bx, 0
    je .out
    dec bx
    cmp ax, bx
    jbe .out
    sub ax, [sh_vrows]
    inc ax
    mov [sh_scrollrow], ax
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_onkey - W_ONKEY: AL=ascii (0 for a navigation key), AH=scan, SI=window
; -----------------------------------------------------------------------------
sh_onkey:
    push ax
    push bx
    push cx
    push dx
    cmp word [sh_fdlg_win], 0
    je .nofdlg
    call sh_fdlg_close                 ; see sh_onclick's own copy of this
                                        ; guard for why
.nofdlg:
    cmp word [sh_bdlg_win], 0
    je .nobdlg
    call sh_bdlg_close
.nobdlg:
    mov word [sh_msg], 0
    mov bx, si
    call sh_geom
    or al, al
    jz .navkey
    ; stage 3.0a: a shift+arrow arrives WITH an ASCII byte. The arrow and the
    ; keypad digit share one scancode - 0x4D is both Right and KP-6, the E0
    ; prefix naming no key of its own (kernel/mouse.inc's own note) - so the
    ; kernel's shifted translation hands us '6'. Without this test, holding
    ; shift and pressing an arrow would TYPE A DIGIT into the cell instead of
    ; extending the selection, which is exactly what it did before this check.
    call sh_shiftdown
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
    cmp byte [sh_editing], 0
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
    call sh_flkey
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
    cmp byte [sh_editing], 0
    je .out
    mov byte [sh_editing], 0
    call sh_repaint
    jmp .out
.notesc:
    cmp al, 13                       ; Enter: commit, move down
    jne .nottab
    call sh_commit
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    inc bx
    cmp bx, SH_ROWS
    jb .entergo
    mov bx, SH_ROWS - 1
.entergo:
    call sh_select
    jmp .out
.nottab:
    cmp al, 9                        ; Tab: commit, move right
    jne .notbs
    call sh_commit
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    inc ax
    cmp ax, SH_COLS
    jb .tabgo
    mov ax, SH_COLS - 1
.tabgo:
    call sh_select
    jmp .out
.notbs:
    cmp al, 8                        ; Backspace: the field owns it now, so it
    jne .notdigit                    ; deletes AT THE CARET rather than only
    cmp byte [sh_editing], 0         ; ever chopping the last character
    je .out
    call sh_flkey
    jmp .out
.notdigit:
    ; the formula charset: '=' starts a formula, digits/'-' a plain number
    ; (unchanged from before), and once editing, letters (cell refs and
    ; function names), +-*/(),: and now <>  (comparisons, stage 1.4), and
    ; now ! and " (cross-sheet references and ALERT's string literal), .
    ; (stage 2.0's SET.VALUE, the one macro keyword with a dot in its name -
    ; not a decimal point; this project's cells are still whole numbers,
    ; never fractional), and now '$' (stage 3.0e absolute references), and
    ; space (only meaningful inside an ALERT string
    ; literal, but the charset gate has no notion of "inside a string" - a
    ; bare space elsewhere in a formula is simply malformed, same as any
    ; other out-of-place character already tolerated here) on top of that.
    cmp al, ' '
    je .accept
    cmp al, '='
    je .accept
    cmp al, '-'
    je .accept
    cmp al, '+'
    je .accept
    cmp al, '*'
    je .accept
    cmp al, '/'
    je .accept
    cmp al, '('
    je .accept
    cmp al, ')'
    je .accept
    cmp al, ','
    je .accept
    cmp al, ':'
    je .accept
    cmp al, '<'
    je .accept
    cmp al, '>'
    je .accept
    cmp al, '!'
    je .accept
    cmp al, '"'
    je .accept
    cmp al, '.'
    je .accept
    cmp al, '$'                      ; stage 3.0e: absolute references. This
    je .accept                       ; gate is why the parser accepting '$'
                                     ; was not enough on its own - without
                                     ; this the character never reaches it
    cmp al, '^'                      ; stage 3.0d: the power operator, and the
    je .accept                       ; same trap
    cmp al, '0'
    jb .notletter
    cmp al, '9'
    jbe .accept
.notletter:
    cmp al, 'A'
    jb .out
    cmp al, 'Z'
    jbe .accept
    cmp al, 'a'
    jb .out
    cmp al, 'z'
    ja .out
.accept:
    cmp byte [sh_editing], 0
    jnz .append
    call sh_editstart                ; first character into an empty cell
.append:
    call sh_flkey                    ; the field inserts AT THE CARET and
    jmp .out                         ; bounds itself against LN_MAX
; stage 3.0a: an arrow moves the ANCHOR (collapsing the range) normally, or
; walks the EXTENT when shift is held. Both halves share one source-load and
; one dispatch rather than four near-copies of each.
.left:
    call sh_arrowsrc
    or ax, ax
    jz .out
    dec ax
    jmp .arrowgo
.right:
    call sh_arrowsrc
    cmp ax, SH_COLS - 1
    jae .out
    inc ax
    jmp .arrowgo
.up:
    call sh_arrowsrc
    or bx, bx
    jz .out
    dec bx
    jmp .arrowgo
.down:
    call sh_arrowsrc
    cmp bx, SH_ROWS - 1
    jae .out
    inc bx
.arrowgo:
    call sh_shiftdown
    jc .arrowext
    call sh_select
    jmp .out
.arrowext:
    call sh_select_to
    jmp .out
.pgup:
    mov bx, [sh_selrow]
    mov ax, [sh_vrows]
    cmp bx, ax
    jae .pgup_sub
    xor bx, bx
    jmp .pgup_go
.pgup_sub:
    sub bx, ax
.pgup_go:
    mov ax, [sh_selcol]
    call sh_select
    jmp .out
.pgdn:
    mov bx, [sh_selrow]
    add bx, [sh_vrows]
    cmp bx, SH_ROWS - 1
    jbe .pgdn_go
    mov bx, SH_ROWS - 1
.pgdn_go:
    mov ax, [sh_selcol]
    call sh_select
    jmp .out
.home:
    xor ax, ax
    mov bx, [sh_selrow]
    call sh_select
    jmp .out
.f2:
    call sh_beginedit
    jmp .out
.delcell:
    mov byte [sh_editing], 0
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_clearcell
    call sh_repaint
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_beginedit - F2: seed the edit buffer from the selected cell's current
; value (blank if the cell is empty) and enter edit mode. SI must be the
; window ptr for sh_repaint.
; -----------------------------------------------------------------------------
sh_beginedit:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov dx, si                        ; DX = window ptr, stashed (SI is used
                                       ; as scratch throughout this function)
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_findcell
    jnc .blank
    push es
    mov es, [sh_cellseg]
    test byte [es:di+4], 1
    jz .plainval
    mov ax, [es:di+SH_C_FOFF]                 ; formula_off
    pop es
    mov byte [sh_editbuf], '='
    mov di, sh_editbuf + 1
    mov si, ax
    push es
    mov es, [sh_txtseg]
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
    call sh_cellnum                   ; the value as decimal text
    pop es
    mov si, sh_numbuf
    mov di, sh_editbuf
    call sh_strcpy
.havelen:
    xor cx, cx
    mov si, sh_editbuf
.cnt:
    cmp byte [si], 0
    je .setlen
    inc si
    inc cx
    jmp .cnt
.setlen:
    mov [sh_editlen], cl
    jmp .go
.blank:
    mov byte [sh_editbuf], 0
    mov byte [sh_editlen], 0
.go:
    mov byte [sh_editing], 1
    call sh_flsync                    ; stage 3.0b: the field's own length,
                                       ; caret and scroll must match the
                                       ; buffer we just seeded, or the caret
                                       ; draws somewhere the text is not
    mov si, dx                        ; SI = window ptr, restored
    call sh_repaint
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_commit - if a cell is being edited, parse the buffer and store it (an
; empty buffer, or one that doesn't parse as a single signed integer,
; clears the cell instead); either way stop editing. SI is not touched.
; -----------------------------------------------------------------------------
sh_commit:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    cmp byte [sh_editing], 0
    je .out
    mov byte [sh_editing], 0
    cmp byte [sh_editlen], 0
    jne .have
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_clearcell
    jmp .out
.have:
    cmp byte [sh_editbuf], '='
    jne .numeric
    mov si, sh_editbuf
    inc si                            ; past the '='
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_setformula
    jmp .out
.numeric:
    mov si, sh_editbuf                ; stage 4.0: a full decimal, not a signed
    call fp_atof                      ; integer. "3.5", "-0.25" and "1e3" are
    jc .invalid                       ; all values now; anything fp_atof does
    mov al, [si]                      ; not consume entirely is still refused,
    or al, al                         ; which is what keeps a typo from
    jnz .invalid                      ; silently becoming a number
    call sh_acc_store
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_setvald
    jmp .out
.invalid:
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_clearcell
.out:
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

sh_drawall:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    inc word [sh_pass]                ; one recalculation pass per full
                                       ; repaint; sh_eval_cell's memoization
                                       ; keys off this
    call sh_mbar_draw
    call sh_drawbar
    call sh_drawstatus
    call sh_sbsync                    ; stage 3.0a+: both scroll bars, from
    mov bx, sh_vsb                    ; the live geometry and scroll position
    call os88ui_sbar
    mov bx, sh_hsb
    call sh_hsb_draw
    call sh_drawcolhdrs
    call sh_drawrowhdrs
    call sh_drawgrid
    call sh_drawlines
    call sh_drawborders
    call sh_drawsel
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawbar - the formula bar (stage 2.x: real Excel's own two-box look -
; a fixed-width reference box on the left, a boxed content area on the
; right showing the selected cell's current value/formula, or the live
; edit buffer while typing). Status messages have their own bar now
; (sh_drawstatus) - this one only ever shows the reference and the
; content, matching real Excel's own division of labor between the two.
; -----------------------------------------------------------------------------
; =============================================================================
; The two scroll bars (stage 3.0a+)
;
; The VERTICAL one is os88ui.inc's shared element, used exactly as files.inc
; and fdlg.inc use it. The HORIZONTAL one is sh_hsb_* below - private to this
; app for now, but written to os88ui.inc's own conventions (same seven-word
; block, same OS88UI_SB* part codes, same "geometry not policy" split) so that
; promoting it into the shared file after Sheet 2.0 is a rename rather than a
; redesign. os88ui.inc has no horizontal bar today: its arrow cells are
; derived as y1+10/y2-10 and os88ui_sbtrack deliberately takes DX and not CX
; (SPEC.md 13.10.5.2, "x is never read"), so the axis is structural.
;
; SCROLL EXTENT. `total` is not SH_ROWS/SH_COLS - a bar over 16384 rows would
; have a one-pixel thumb that says nothing. It is the USED extent plus one
; screen, so the thumb is proportional to the sheet a person actually has, and
; it collapses to "no thumb" when everything already fits (os88ui_sbthumb
; answers CF=1 for that case on its own).
; =============================================================================

; -----------------------------------------------------------------------------
; sh_sbsync - refill both blocks from the live geometry and scroll position.
; Called before every draw and every hit-test, for sh_flrect's reason: the
; window moves and resizes, and a painter and a hit-tester reading different
; rects is the one bug this element is designed to make impossible.
; -----------------------------------------------------------------------------
sh_sbsync:
    push ax
    push bx
    push cx
    push dx
    call sh_difbbox                    ; -> [sh_bbcol]/[sh_bbrow], the used
                                        ; bounding box (walks only OCCUPIED
                                        ; cells, not the whole grid)

    ; --- vertical: the strip at the right of the grid area
    mov ax, [sh_ox]
    add ax, [sh_cw]
    sub ax, SH_VSB_W
    mov [sh_vsb + 0], ax               ; x1
    mov ax, [sh_ox]
    add ax, [sh_cw]
    dec ax
    mov [sh_vsb + 4], ax               ; x2
    mov ax, [sh_goy]
    add ax, SH_FB_H + SH_CH_H
    mov [sh_vsb + 2], ax               ; y1 - the top of the grid proper
    mov ax, [sh_oy]
    add ax, [sh_ch]
    sub ax, SH_SB_H + SH_HSB_H
    dec ax
    mov [sh_vsb + 6], ax               ; y2 - just above the horizontal bar
    mov ax, [sh_bbrow]
    inc ax                             ; the USED extent, not SH_ROWS - a bar
    cmp ax, [sh_vrows]                 ; over 16384 rows has a one-pixel thumb
    jae .vtot                          ; that says nothing. Floored at `fit`,
    mov ax, [sh_vrows]                 ; so an empty sheet has total == fit and
.vtot:                                 ; correctly shows no thumb at all.
    mov [sh_vsb + 8], ax               ; total
    mov ax, [sh_vrows]
    mov [sh_vsb + 10], ax              ; fit
    mov ax, [sh_scrollrow]
    mov [sh_vsb + 12], ax              ; pos

    ; --- horizontal: the strip below the grid, left of the vertical bar
    mov ax, [sh_ox]
    add ax, SH_RH_W
    mov [sh_hsb + 0], ax               ; x1
    mov ax, [sh_ox]
    add ax, [sh_cw]
    sub ax, SH_VSB_W
    dec ax
    mov [sh_hsb + 4], ax               ; x2 - stops at the vertical bar
    mov ax, [sh_oy]
    add ax, [sh_ch]
    sub ax, SH_SB_H + SH_HSB_H
    mov [sh_hsb + 2], ax               ; y1
    mov ax, [sh_oy]
    add ax, [sh_ch]
    sub ax, SH_SB_H
    dec ax
    mov [sh_hsb + 6], ax               ; y2
    mov ax, [sh_bbcol]
    inc ax
    cmp ax, [sh_vcols]
    jae .htot
    mov ax, [sh_vcols]
.htot:
    mov [sh_hsb + 8], ax               ; total
    mov ax, [sh_vcols]
    mov [sh_hsb + 10], ax              ; fit
    mov ax, [sh_scrollcol]
    mov [sh_hsb + 12], ax              ; pos

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; sh_hsb_* - A HORIZONTAL SCROLL BAR, staged for os88ui.inc
;
; os88ui.inc's bar is structurally vertical and says so: its arrow cells are
; y1+10 and y2-10, and os88ui_sbtrack takes DX and refuses CX on purpose
; (SPEC.md 13.10.5.2). This is that element transposed, and NOTHING about it
; is Sheet-specific:
;
;   * the same seven-word block (x1,y1,x2,y2,total,fit,pos), so a promoted
;     version needs no caller to change its .bss;
;   * the same part codes - SH_SB_UP/SBDOWN mean LEFT/RIGHT here, which is
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
; sh_hsb_* - A HORIZONTAL SCROLL BAR, staged for os88ui.inc
;
; os88ui.inc's bar is structurally vertical and says so: its arrow cells are
; y1+10 and y2-10, and os88ui_sbtrack takes DX and refuses CX on purpose
; (SPEC.md 13.10.5.2, "x is never read"). This is that element transposed, and
; nothing about it is Sheet-specific:
;
;   * the same seven-word block (x1,y1,x2,y2,total,fit,pos), so a promoted
;     version needs no caller to change its .bss;
;   * the same part codes - SH_SB_UP/SBDOWN read as LEFT/RIGHT here, which
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
; sh_hsb_load - copy the block's rect into scratch. in: BX = the block.
; Preserves everything. Every drawing routine calls this FIRST and then never
; dereferences BX again, which is what keeps the block pointer and the gfx
; rect from fighting over the same register.
; -----------------------------------------------------------------------------
sh_hsb_load:
    push ax
    mov ax, [bx + 0]
    mov [sh_hsb_x1], ax
    mov ax, [bx + 2]
    mov [sh_hsb_y1], ax
    mov ax, [bx + 4]
    mov [sh_hsb_x2], ax
    mov ax, [bx + 6]
    mov [sh_hsb_y2], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_hsb_thumb - the thumb's geometry (os88ui_sbthumb, transposed)
; in:  BX = the block
; out: CF=1 = there is no thumb; else CF=0 and [sh_hsb_tl]/[sh_hsb_tw] hold
;      its left and width, absolute. Every register preserved.
; -----------------------------------------------------------------------------
sh_hsb_thumb:
    push ax
    push cx
    push dx
    push si
    mov cx, [bx + 4]
    sub cx, [bx + 0]
    sub cx, (SH_SB_CELL + 1) * 2    ; cx = the track's width
    cmp cx, SH_SB_MINH
    jb .none
    mov ax, [bx + 10]                  ; fit
    or ax, ax
    jz .none
    cmp ax, [bx + 8]                   ; fit >= total: everything fits
    jae .none
    xor dx, dx
    mul cx                             ; dx:ax = fit * track
    div word [bx + 8]                  ; / total
    cmp ax, SH_SB_MINH
    jae .wok
    mov ax, SH_SB_MINH
.wok:
    mov si, ax                         ; si = the thumb's width
    mov ax, [bx + 12]                  ; pos
    xor dx, dx
    mul cx                             ; dx:ax = pos * track
    div word [bx + 8]                  ; / total
    add ax, [bx + 0]
    add ax, SH_SB_CELL + 1          ; ax = the thumb's left
    ; Clamp the tail inside the track: pos == total-fit can overshoot by a
    ; pixel once both divisions have truncated.
    mov dx, [bx + 4]
    sub dx, SH_SB_CELL + 1          ; dx = the track's last column
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
    mov [sh_hsb_tl], ax
    mov [sh_hsb_tw], si
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
; sh_hsb_draw - the whole bar. in: BX = the block; gfx lock held.
; Preserves everything; leaves the pen BLACK, as os88ui_sbar does.
; -----------------------------------------------------------------------------
sh_hsb_draw:
    push ax
    push bx
    push cx
    push dx
    call sh_hsb_load

    mov al, CWHITE                     ; the arrow cells are plain white...
    call OSAPI_SET_COLOR
    mov ax, [sh_hsb_x1]
    mov bx, [sh_hsb_y1]
    mov cx, [sh_hsb_x2]
    mov dx, [sh_hsb_y2]
    call OSAPI_GFX_FILL
    mov ax, [sh_hsb_x1]                ; ...and the TRACK between them is the
    add ax, SH_SB_CELL + 1             ; grey dither, which is what the thumb
    mov cx, [sh_hsb_x2]                ; reads as a knob against
    sub cx, SH_SB_CELL + 1
    mov bx, [sh_hsb_y1]
    inc bx
    mov dx, [sh_hsb_y2]
    dec dx
    cmp ax, cx
    jg .notrack
    call OSAPI_GFX_FILL_GRAY
.notrack:

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [sh_hsb_x1]                ; the outline
    mov bx, [sh_hsb_y1]
    mov cx, [sh_hsb_x2]
    mov dx, [sh_hsb_y2]
    call OSAPI_GFX_FRAME

    mov ax, [sh_hsb_x1]                ; the two arrow-cell rules
    add ax, SH_SB_CELL
    mov bx, [sh_hsb_y1]
    mov dx, [sh_hsb_y2]
    call OSAPI_GFX_VLINE
    mov ax, [sh_hsb_x2]
    sub ax, SH_SB_CELL
    mov bx, [sh_hsb_y1]
    mov dx, [sh_hsb_y2]
    call OSAPI_GFX_VLINE

    pop dx
    pop cx
    pop bx
    pop ax
    call sh_hsb_arrows
    call sh_hsb_thdraw
    ret

; -----------------------------------------------------------------------------
; sh_hsb_arrows - the two triangles. os88ui.inc's vertical arrow is 5 rows of
; widths 1..9; this is that rotated, so 5 columns of growing height.
; in: BX = the block (already loaded into scratch by the caller).
; -----------------------------------------------------------------------------
sh_hsb_arrows:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, [sh_hsb_y1]
    add si, [sh_hsb_y2]
    shr si, 1                          ; si = the cells' vertical centre

    ; The tips point OUTWARD - `<` on the left cell and `>` on the right, not
    ; `>` and `<`. Each arrow starts one pixel in from its OUTER edge, where
    ; the tip belongs, and widens INWARD.
    mov di, [sh_hsb_x1]                ; LEFT arrow: tip at the outer edge...
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

    mov di, [sh_hsb_x2]                ; RIGHT arrow: tip at ITS outer edge,
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
; sh_hsb_thdraw - just the thumb. in: BX = the block; gfx lock held.
; -----------------------------------------------------------------------------
sh_hsb_thdraw:
    push ax
    push bx
    push cx
    push dx
    call sh_hsb_thumb
    jc .out
    ; The same two-part thumb os88ui_sbthdraw draws, transposed: a BLACK
    ; frame with a WHITE interior inside it - not a solid block, which is what
    ; makes it read as a knob against the dithered track rather than as a bar.
    mov ax, [sh_hsb_tl]
    mov cx, ax
    add cx, [sh_hsb_tw]
    dec cx
    mov bx, [sh_hsb_y1]
    add bx, 2
    mov dx, [sh_hsb_y2]
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
; sh_hsb_hit - which part is this point on? (os88ui_sbhit, transposed)
; in:  BX = the block, CX = x, DX = y (both ABSOLUTE)
; out: AL = OS88UI_SB*; AH clobbered, everything else preserved.
; -----------------------------------------------------------------------------
sh_hsb_hit:
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
    add ax, SH_SB_CELL
    cmp cx, ax
    jbe .up                            ; the LEFT arrow cell
    mov ax, [bx + 4]
    sub ax, SH_SB_CELL
    cmp cx, ax
    jae .down                          ; the RIGHT arrow cell
    call sh_hsb_thumb
    jc .pgdn                           ; no thumb: the track is all page-fwd
    mov ax, [sh_hsb_tl]
    cmp cx, ax
    jb .pgup
    add ax, [sh_hsb_tw]
    cmp cx, ax
    jae .pgdn
    mov al, SH_SB_THUMB
    jmp .out
.up:
    mov al, SH_SB_UP
    jmp .out
.down:
    mov al, SH_SB_DOWN
    jmp .out
.pgup:
    mov al, SH_SB_PGUP
    jmp .out
.pgdn:
    mov al, SH_SB_PGDN
    jmp .out
.none:
    mov al, SH_SB_NONE
.out:
    pop dx
    pop cx
    ret

; -----------------------------------------------------------------------------
; sh_hsb_grab / sh_hsb_track / sh_hsb_drop - the thumb drag, the same three
; edges os88ui.inc's own uses (13.10.5), with the anchor banked as
; press_x - thumb_left so the thumb does not jump under the hand.
; -----------------------------------------------------------------------------
sh_hsb_grab:
    push ax
    call sh_hsb_thumb
    jc .no
    mov ax, cx
    sub ax, [sh_hsb_tl]
    mov [sh_hsb_dragoff], ax
    mov byte [sh_hsb_dragon], 1
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret

; in: BX = the block, CX = the pointer's x (ABSOLUTE). y is never read, which
; is 13.10.5.2's rule with the axes swapped.
; out: CF=0 and AX = the pos the view is owed; CF=1 = nothing is owed.
sh_hsb_track:
    cmp byte [sh_hsb_dragon], 0
    je .no
    push cx
    push dx
    push si
    mov ax, cx
    sub ax, [sh_hsb_dragoff]           ; ax = where the thumb's left wants to be
    mov si, [bx + 0]
    add si, SH_SB_CELL + 1          ; si = the track's left
    sub ax, si
    jns .pos
    xor ax, ax                         ; clamped at the near end
.pos:
    mov cx, [bx + 4]
    sub cx, [bx + 0]
    sub cx, (SH_SB_CELL + 1) * 2    ; cx = the track's width
    or cx, cx
    jz .nopop
    xor dx, dx
    mul word [bx + 8]                  ; offset * total
    div cx                             ; / track -> the pos it maps to
    mov cx, [bx + 8]
    sub cx, [bx + 10]                  ; the last legal pos = total - fit
    jbe .zero
    cmp ax, cx
    jbe .done
    mov ax, cx
    jmp .done
.zero:
    xor ax, ax
.done:
    cmp ax, [bx + 12]                  ; 13.10.5.3's quantisation: a move too
    je .nopop                          ; small to change a row owes nothing
    pop si
    pop dx
    pop cx
    clc
    ret
.nopop:
    pop si
    pop dx
    pop cx
.no:
    stc
    ret

sh_hsb_drop:
    mov byte [sh_hsb_dragon], 0
    ret

; -----------------------------------------------------------------------------
; sh_onmouseup - W_ONMOUSEUP: the press was released. Ends a thumb drag and,
; for the vertical bar's rate-0 grab, commits the pos the hand ended on -
; which is what "the view follows only on release" means (13.10.5.4).
; -----------------------------------------------------------------------------
sh_onmouseup:
    push ax
    push bx
    push si
    call os88ui_sbdragging
    jc .noV
    call os88ui_sbdrop                 ; the view already followed during the
    jmp .out                           ; drag (the rate above), so releasing
.noV:                                  ; only has to let go
    cmp byte [sh_hsb_dragon], 0
    je .out
    call sh_hsb_drop
.out:
    mov byte [sh_dragging], 0
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_sbclick - stage 3.0a+: a press landed somewhere. If it was on either
; scroll bar, act on it and answer CF=1 ("mine"); otherwise CF=0 and the grid
; gets it. in: CX = x, DX = y (absolute), SI = the window.
;
; This is the POLICY half that os88ui.inc deliberately leaves to the caller
; (13.10.1): the element says which part was hit, and what a part MEANS to a
; sheet - one row, one screen, or take the thumb - is decided here.
; -----------------------------------------------------------------------------
sh_sbclick:
    push ax
    push bx
    push di
    call sh_sbsync

    mov bx, sh_vsb                     ; --- the vertical bar
    call os88ui_sbhit
    cmp al, SH_SB_NONE
    je .tryh
    xor ah, ah                         ; stash the part in DI: the very next
    mov di, ax                         ; instruction writes the whole of AX,
    mov ax, [sh_scrollrow]             ; so stashing it in AH (as this did)
    mov [sh_sb_oldpos], ax             ; destroyed it and every compare below
    cmp di, SH_SB_UP                   ; fell through to the thumb branch
                                        ; - which is why an arrow click did
                                        ; nothing at all
    je .vup
    cmp di, SH_SB_DOWN
    je .vdn
    cmp di, SH_SB_PGUP
    je .vpgup
    cmp di, SH_SB_PGDN
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
    mov ax, [sh_scrollrow]
    or ax, ax
    jz .mine
    dec ax
    jmp .vset
.vdn:
    mov ax, [sh_scrollrow]
    inc ax
    jmp .vset
.vpgup:
    mov ax, [sh_scrollrow]
    sub ax, [sh_vrows]
    jns .vset
    xor ax, ax
    jmp .vset
.vpgdn:
    mov ax, [sh_scrollrow]
    add ax, [sh_vrows]
.vset:
    call sh_setscrollrow
    jmp .mine

.tryh:
    mov bx, sh_hsb                     ; --- the horizontal bar
    call sh_hsb_hit
    cmp al, SH_SB_NONE
    je .notmine
    xor ah, ah                         ; same AX-clobber trap as the vertical
    mov di, ax                         ; branch above
    mov ax, [sh_scrollcol]
    mov [sh_sb_oldpos], ax
    cmp di, SH_SB_UP
    je .hlf
    cmp di, SH_SB_DOWN
    je .hrt
    cmp di, SH_SB_PGUP
    je .hpgup
    cmp di, SH_SB_PGDN
    je .hpgdn
    call sh_hsb_grab                   ; SB_THUMB
    jmp .mine
.hlf:
    mov ax, [sh_scrollcol]
    or ax, ax
    jz .mine
    dec ax
    jmp .hset
.hrt:
    mov ax, [sh_scrollcol]
    inc ax
    jmp .hset
.hpgup:
    mov ax, [sh_scrollcol]
    sub ax, [sh_vcols]
    jns .hset
    xor ax, ax
    jmp .hset
.hpgdn:
    mov ax, [sh_scrollcol]
    add ax, [sh_vcols]
.hset:
    call sh_setscrollcol
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
; sh_setscrollrow / sh_setscrollcol - move the view to AX, clamped to the
; scrollable extent, and repaint if it actually moved. SI = the window.
; -----------------------------------------------------------------------------
sh_setscrollrow:
    push ax
    push bx
    push cx
    mov cx, [sh_vsb + 8]               ; total
    sub cx, [sh_vsb + 10]              ; ...minus fit = the last legal pos
    jns .rok
    xor cx, cx
.rok:
    cmp ax, cx
    jbe .rset
    mov ax, cx
.rset:
    cmp ax, [sh_scrollrow]
    je .rout                           ; no movement: draw nothing
    mov [sh_scrollrow], ax
    call sh_repaint
.rout:
    pop cx
    pop bx
    pop ax
    ret

sh_setscrollcol:
    push ax
    push bx
    push cx
    mov cx, [sh_hsb + 8]
    sub cx, [sh_hsb + 10]
    jns .cok
    xor cx, cx
.cok:
    cmp ax, cx
    jbe .cset
    mov ax, cx
.cset:
    cmp ax, [sh_scrollcol]
    je .cout
    mov [sh_scrollcol], ax
    call sh_repaint
.cout:
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_flrect - stage 3.0b: point the formula bar's line block at the content
; box's CURRENT screen rect. Called before every draw and every hit-test
; rather than once at startup, because the window moves and resizes and
; os88line reads the same four words for both drawing and clicking - a stale
; rect would put the caret somewhere the box no longer is. These are exactly
; the coordinates sh_drawbar frames the content box with, so the field's own
; frame lands on top of the same pixels.
; -----------------------------------------------------------------------------
sh_flrect:
    push ax
    mov ax, [sh_ox]
    add ax, SH_REF_W
    mov [sh_fline + LN_X1], ax
    mov ax, [sh_goy]
    mov [sh_fline + LN_Y1], ax
    mov ax, [sh_ox]
    add ax, [sh_cw]
    dec ax
    mov [sh_fline + LN_X2], ax
    mov ax, [sh_goy]
    add ax, SH_FB_H - 1
    mov [sh_fline + LN_Y2], ax
    pop ax
    ret

sh_drawbar:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov al, CBLACK
    call OSAPI_SET_COLOR

    ; --- reference box outline: (ox, goy) to (ox+SH_REF_W-1, goy+SH_FB_H-1) ---
    mov ax, [sh_ox]
    mov bx, ax
    add bx, SH_REF_W - 1
    mov dx, [sh_goy]
    call OSAPI_GFX_HLINE
    add dx, SH_FB_H - 1
    call OSAPI_GFX_HLINE
    mov ax, [sh_ox]
    mov bx, [sh_goy]
    mov dx, [sh_goy]
    add dx, SH_FB_H - 1
    call OSAPI_GFX_VLINE
    mov ax, [sh_ox]
    add ax, SH_REF_W - 1
    call OSAPI_GFX_VLINE               ; also the content box's own left edge

    ; --- content box outline: (ox+SH_REF_W, goy) to (ox+cw-1, goy+SH_FB_H-1) ---
    mov ax, [sh_ox]
    add ax, SH_REF_W
    mov bx, [sh_ox]
    add bx, [sh_cw]
    dec bx
    mov dx, [sh_goy]
    call OSAPI_GFX_HLINE
    add dx, SH_FB_H - 1
    call OSAPI_GFX_HLINE
    mov ax, [sh_ox]
    add ax, [sh_cw]
    dec ax
    mov bx, [sh_goy]
    mov dx, [sh_goy]
    add dx, SH_FB_H - 1
    call OSAPI_GFX_VLINE

    ; --- reference text, into sh_tbuf ---
    mov di, sh_tbuf
    mov ax, [sh_selcol]
    call sh_colname
    mov si, sh_colbuf
    call sh_strcpy_to_di
    mov ax, [sh_selrow]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_strcpy_to_di
    mov cx, [sh_ox]
    add cx, 4
    mov dx, [sh_goy]
    add dx, 4
    mov si, sh_tbuf
    call OSAPI_FONT_STR

    ; --- while EDITING, the content box is a real text field: os88line owns
    ; the box, the text, the caret and the horizontal scroll, so this path
    ; hands it over entirely rather than drawing a string itself.
    cmp byte [sh_editing], 0
    je .static
    call sh_flrect
    mov si, sh_fline
    call os88line_draw
    jmp .done

.static:
    ; --- not editing: the cell's current value/formula, as static text, into
    ; sh_tbuf+16 (past the reference text's own small span, so the two never
    ; overlap in the same shared buffer) ---
    mov di, sh_tbuf + 16
    push di                            ; sh_findcell's own DI output would
                                        ; otherwise clobber our cursor
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_findcell
    jnc .empty2
    push es
    mov es, [sh_cellseg]
    test byte [es:di+4], 1
    jz .plainval2
    mov ax, [es:di+SH_C_FOFF]                 ; formula_off
    pop es
    pop di                             ; DI = content cursor, restored
    mov byte [di], '='
    inc di
    mov si, ax
    push es
    mov es, [sh_txtseg]
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
    call sh_cellnum                    ; sh_numbuf already holds the decimal
    pop es                             ; text; sh_itoa would overwrite it with
    pop di                             ; the low word's worth
    mov si, sh_numbuf
    call sh_strcpy_to_di
    jmp .draw
.empty2:
    pop di                             ; DI = content cursor, restored
    mov byte [di], 0
.draw:
    mov cx, [sh_ox]
    add cx, SH_REF_W + 4
    mov dx, [sh_goy]
    add dx, 4
    mov si, sh_tbuf + 16
    call OSAPI_FONT_STR
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawstatus - the status bar: a single divider line above a strip at
; the very bottom of the content area, showing [sh_msg] if a command just
; set one, else the idle "Ready" real Excel's own status bar shows.
; -----------------------------------------------------------------------------
sh_drawstatus:
    push ax
    push bx
    push cx
    push dx
    push si

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [sh_ox]
    mov bx, ax
    add bx, [sh_cw]
    dec bx
    mov dx, [sh_oy]
    add dx, [sh_ch]
    sub dx, SH_SB_H
    call OSAPI_GFX_HLINE

    mov si, [sh_msg]
    or si, si
    jnz .havemsg
    mov si, sh_s_ready
.havemsg:
    mov cx, [sh_ox]
    add cx, 4
    mov dx, [sh_oy]
    add dx, [sh_ch]
    sub dx, SH_SB_H
    add dx, 4
    call OSAPI_FONT_STR

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawcolhdrs - the column letters, centred in each visible column's band
; -----------------------------------------------------------------------------
sh_drawcolhdrs:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov word [sh_wcol], 0
.col:
    mov bx, [sh_wcol]
    cmp bx, [sh_vcols]
    jae .out
    mov ax, bx
    add ax, [sh_scrollcol]
    call sh_colname
    mov ax, bx
    mov dx, [sh_cellw]
    mul dx
    add ax, [sh_ox]
    add ax, SH_RH_W
    mov cx, ax
    mov si, sh_colbuf
    call OSAPI_FONT_WIDTH
    mov dx, [sh_cellw]
    sub dx, ax
    shr dx, 1
    add cx, dx
    mov dx, [sh_goy]
    add dx, SH_FB_H
    mov si, sh_colbuf
    call OSAPI_FONT_STR
    mov bx, [sh_wcol]
    inc bx
    mov [sh_wcol], bx
    jmp .col
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawrowhdrs - the row numbers, right-aligned in SH_RH_W
; -----------------------------------------------------------------------------
sh_drawrowhdrs:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov word [sh_wrow], 0
.row:
    mov bx, [sh_wrow]
    cmp bx, [sh_vrows]
    jae .out
    mov ax, bx
    add ax, [sh_scrollrow]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call OSAPI_FONT_WIDTH
    mov cx, SH_RH_W - 4
    sub cx, ax
    add cx, [sh_ox]
    mov ax, bx
    mov dx, [sh_cellh]
    mul dx
    add ax, [sh_goy]
    add ax, SH_FB_H + SH_CH_H
    mov dx, ax
    mov si, sh_numbuf
    call OSAPI_FONT_STR
    mov bx, [sh_wrow]
    inc bx
    mov [sh_wrow], bx
    jmp .row
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawgrid - every visible cell as one fixed-width OSAPI_FONT_RUN,
; number-formatted and justified per its own SH_FMT_* bits (stage 1.6),
; all spaces for empty. Sparse lookup: no bitmap.
; -----------------------------------------------------------------------------
sh_drawgrid:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [sh_wrow], 0
.row:
    mov ax, [sh_wrow]
    cmp ax, [sh_vrows]
    jae .out
    mov word [sh_wcol], 0
.col:
    mov ax, [sh_wcol]
    cmp ax, [sh_vcols]
    jae .rownext
    mov ax, [sh_wcol]
    add ax, [sh_scrollcol]
    mov bx, [sh_wrow]
    add bx, [sh_scrollrow]
    call sh_getcell2
    jc .have
    mov si, sh_blank
    jmp .got
.have:
    cmp byte [sh_showformulas], 0      ; stage 2.x Options > Formulas: On -
    je .valpath                        ; show the formula TEXT, not its
                                        ; value, matching real Excel's
                                        ; Display dialog's "Formulas" box.
                                        ; AX/BX are still this cell's own
                                        ; col/row (sh_getcell2 preserves
                                        ; both), so re-finding it costs
                                        ; nothing extra to set up.
    call sh_findcell
    jnc .valpath                       ; can't happen (getcell2 said
                                        ; occupied) - stay safe regardless
    push es
    mov es, [sh_cellseg]
    test byte [es:di+4], 1             ; HASFORMULA
    jz .noformula3
    mov ax, [es:di+SH_C_FOFF]                  ; formula_off
    pop es
    mov byte [sh_tbuf], '='
    mov di, sh_tbuf + 1
    mov si, ax
    push es
    mov es, [sh_txtseg]
.fcopy:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .fcopy
    pop es
    mov cx, di
    sub cx, sh_tbuf
    dec cx                             ; cx = chars written, excluding NUL
    cmp cx, [sh_cellch]
    jbe .fpad
    mov bx, [sh_cellch]
    mov byte [sh_tbuf + bx], 0         ; longer than a cell: truncate
    jmp .fshow
.fpad:
    mov ax, [sh_cellch]
    sub ax, cx
    jz .fshow
    mov cx, ax
.fploop:
    mov byte [di], ' '
    inc di
    loop .fploop
    mov byte [di], 0
.fshow:
    mov si, sh_tbuf
    jmp .got
.noformula3:
    pop es
.valpath:
    mov ax, dx
    mov bl, [sh_curfmt]
    call sh_numfmt
    call sh_justify
    mov si, sh_tbuf
.got:
    mov ax, [sh_wcol]
    mov dx, [sh_cellw]
    mul dx
    add ax, [sh_ox]
    add ax, SH_RH_W
    mov cx, ax
    mov ax, [sh_wrow]
    mov dx, [sh_cellh]
    mul dx
    add ax, [sh_goy]
    add ax, SH_FB_H + SH_CH_H
    mov dx, ax
    ; stage 2.x: a Shaded cell (Format > Border..., real Excel's own Shade
    ; checkbox) needs the grey dither drawn FIRST and the text drawn
    ; TRANSPARENT over it - OSAPI_FONT_RUN's opaque erase-then-letter would
    ; otherwise wipe the dither right back out on every single repaint
    push cx
    push dx
    mov ax, [sh_wcol]
    add ax, [sh_scrollcol]
    mov bx, [sh_wrow]
    add bx, [sh_scrollrow]
    call sh_bt_get                     ; al = this cell's border byte
    pop dx
    pop cx
    test al, SH_BORD_SHADE
    jz .noshade
    push cx
    push dx
    mov ax, cx
    mov bx, dx
    add cx, [sh_cellw]
    dec cx
    add dx, [sh_cellh]
    dec dx
    call OSAPI_GFX_FILL_GRAY
    pop dx
    pop cx
    mov al, CBLACK
    call OSAPI_SET_COLOR
    call OSAPI_FONT_STR
    jmp .aftertext
.noshade:
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_RUN
.aftertext:
    test byte [sh_curfmt], SH_FMT_BOLD
    jz .nobold
    push cx
    push dx
    inc cx
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_STR                ; a 1px-right overprint - the same
                                        ; double-strike trick texpad uses
                                        ; for bold on this same 8x8 font
    pop dx
    pop cx
.nobold:
    test byte [sh_curfmt], SH_FMT_UNDER
    jz .nounder
    call sh_drawunderline
.nounder:
    mov ax, [sh_wcol]
    inc ax
    mov [sh_wcol], ax
    jmp .col
.rownext:
    mov ax, [sh_wrow]
    inc ax
    mov [sh_wrow], ax
    jmp .row
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawlines - visible cell-boundary lines, vcols+1 vertical and vrows+1
; horizontal, each a degenerate (1px) OSAPI_GFX_FILL rectangle. Drawn AFTER
; sh_drawgrid: OSAPI_FONT_RUN's opaque erase is exactly one cell wide and
; would otherwise paint back over a line drawn first.
; -----------------------------------------------------------------------------
sh_drawlines:
    push ax
    push bx
    push cx
    push dx
    cmp byte [sh_gridlines], 0         ; stage 2.x Options > Gridlines: Off
    je .out                            ; skips this whole pass, same as real
                                        ; Excel's Display dialog
    mov al, CBLACK
    call OSAPI_SET_COLOR

    mov ax, [sh_goy]
    add ax, SH_FB_H + SH_CH_H
    mov [sh_ly1], ax
    mov bx, [sh_vrows]
    mov dx, [sh_cellh]
    mov ax, bx
    mul dx
    add ax, [sh_ly1]
    dec ax
    mov [sh_ly2], ax

    mov ax, [sh_ox]
    add ax, SH_RH_W
    mov [sh_lx1], ax
    mov bx, [sh_vcols]
    mov dx, [sh_cellw]
    mov ax, bx
    mul dx
    add ax, [sh_lx1]
    dec ax
    mov [sh_lx2], ax

    mov word [sh_wcol], 0
.vline:
    mov ax, [sh_wcol]
    cmp ax, [sh_vcols]
    ja .vdone
    mov dx, [sh_cellw]
    mul dx
    add ax, [sh_lx1]
    mov cx, ax
    mov bx, [sh_ly1]
    mov dx, [sh_ly2]
    call OSAPI_GFX_FILL
    mov ax, [sh_wcol]
    inc ax
    mov [sh_wcol], ax
    jmp .vline
.vdone:
    mov word [sh_wrow], 0
.hline:
    mov ax, [sh_wrow]
    cmp ax, [sh_vrows]
    ja .hdone
    mov dx, [sh_cellh]
    mul dx
    add ax, [sh_ly1]
    mov bx, ax
    mov dx, ax
    mov ax, [sh_lx1]
    mov cx, [sh_lx2]
    call OSAPI_GFX_FILL
    mov ax, [sh_wrow]
    inc ax
    mov [sh_wrow], ax
    jmp .hline
.hdone:
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawborders - the four directional edges (Left/Right/Top/Bottom) of
; every bordered cell (sh_bordseg) on the current sheet, within the visible
; scroll window. Shade is drawn from INSIDE sh_drawgrid instead, since it
; has to happen BEFORE that cell's own opaque text run, not after (see the
; comment there) - this routine only ever draws the four edge lines.
; Sparse walk of sh_bordseg (typically tiny - almost no cell has a border)
; rather than a per-cell probe, the same style sh_docmd_sortcol/
; sh_rowcol_op already walk-and-filter the main cell array with. Drawn
; AFTER sh_drawgrid for the same reason sh_drawlines already is:
; OSAPI_FONT_RUN's opaque erase is exactly one cell wide and would
; otherwise paint back over an edge drawn first.
; -----------------------------------------------------------------------------
sh_drawborders:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov word [sh_bti], 0               ; the scan index lives in bss, not
                                        ; CX - OSAPI_GFX_FILL below takes CX
                                        ; as one of its own four params, so
                                        ; a register loop counter would get
                                        ; clobbered by the very first edge
                                        ; it draws (caught in review)
.scan:
    mov cx, [sh_bti]
    cmp cx, [sh_nbord]
    jae .done
    mov ax, cx
    mov bx, 5
    mul bx
    mov si, ax
    mov es, [sh_bordseg]
    mov ax, [es:si]                   ; packed row/sheet
    call sh_unpackrow                 ; ax=row, bx=sheet
    cmp bx, [sh_cursheet]
    jne .next
    mov dx, [es:si+2]                 ; col
    mov bx, dx
    sub bx, [sh_scrollcol]
    js .next
    cmp bx, [sh_vcols]
    jae .next
    mov [sh_wcol], bx
    mov bx, ax
    sub bx, [sh_scrollrow]
    js .next
    cmp bx, [sh_vrows]
    jae .next
    mov [sh_wrow], bx
    mov al, [es:si+4]
    mov [sh_bdrawflags], al
    mov ax, [sh_wcol]
    mov bx, [sh_cellw]
    mul bx
    add ax, [sh_ox]
    add ax, SH_RH_W
    mov [sh_bx1], ax
    add ax, [sh_cellw]
    dec ax
    mov [sh_bx2], ax
    mov ax, [sh_wrow]
    mov bx, [sh_cellh]
    mul bx
    add ax, [sh_goy]
    add ax, SH_FB_H + SH_CH_H
    mov [sh_by1], ax
    add ax, [sh_cellh]
    dec ax
    mov [sh_by2], ax
    test byte [sh_bdrawflags], SH_BORD_LEFT
    jz .noleft
    mov ax, [sh_bx1]
    mov bx, [sh_by1]
    mov cx, [sh_bx1]
    mov dx, [sh_by2]
    call OSAPI_GFX_FILL
.noleft:
    test byte [sh_bdrawflags], SH_BORD_RIGHT
    jz .noright
    mov ax, [sh_bx2]
    mov bx, [sh_by1]
    mov cx, [sh_bx2]
    mov dx, [sh_by2]
    call OSAPI_GFX_FILL
.noright:
    test byte [sh_bdrawflags], SH_BORD_TOP
    jz .notop
    mov ax, [sh_bx1]
    mov bx, [sh_by1]
    mov cx, [sh_bx2]
    mov dx, [sh_by1]
    call OSAPI_GFX_FILL
.notop:
    test byte [sh_bdrawflags], SH_BORD_BOTTOM
    jz .nobottom
    mov ax, [sh_bx1]
    mov bx, [sh_by2]
    mov cx, [sh_bx2]
    mov dx, [sh_by2]
    call OSAPI_GFX_FILL
.nobottom:
.next:
    mov ax, [sh_bti]
    inc ax
    mov [sh_bti], ax
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
; sh_drawsel - a black frame around the selected cell, if it is on screen
; -----------------------------------------------------------------------------
sh_drawsel:
    push ax
    push bx
    push cx
    push dx
    call sh_selrect                    ; stage 3.0a: -> sh_selc1..sh_selr2,
                                        ; already ordered

    ; --- clip the block's own cell rect to the visible viewport. Each edge is
    ; clamped rather than the whole block rejected, so a selection that runs
    ; off the screen still draws the part that shows (Excel's own behaviour,
    ; and what a drag past the edge needs).
    mov ax, [sh_selc2]                 ; wholly left of the viewport?
    cmp ax, [sh_scrollcol]
    jb .out
    mov ax, [sh_selr2]                 ; wholly above it?
    cmp ax, [sh_scrollrow]
    jb .out

    mov ax, [sh_selc1]                 ; left edge, clamped to the origin
    cmp ax, [sh_scrollcol]
    jae .c1ok
    mov ax, [sh_scrollcol]
.c1ok:
    sub ax, [sh_scrollcol]
    cmp ax, [sh_vcols]
    jae .out                           ; starts past the right edge
    mov [sh_wcol], ax

    mov ax, [sh_selr1]                 ; top edge, clamped
    cmp ax, [sh_scrollrow]
    jae .r1ok
    mov ax, [sh_scrollrow]
.r1ok:
    sub ax, [sh_scrollrow]
    cmp ax, [sh_vrows]
    jae .out
    mov [sh_wrow], ax

    mov ax, [sh_selc2]                 ; right edge, clamped to the last
    sub ax, [sh_scrollcol]             ; visible column
    cmp ax, [sh_vcols]
    jb .c2ok
    mov ax, [sh_vcols]
    dec ax
.c2ok:
    mov [sh_selvc2], ax

    mov ax, [sh_selr2]                 ; bottom edge, clamped
    sub ax, [sh_scrollrow]
    cmp ax, [sh_vrows]
    jb .r2ok
    mov ax, [sh_vrows]
    dec ax
.r2ok:
    mov [sh_selvr2], ax

    ; --- cell coords -> pixels
    mov ax, [sh_wcol]
    mov dx, [sh_cellw]
    mul dx
    add ax, [sh_ox]
    add ax, SH_RH_W
    mov [sh_selx1], ax

    mov ax, [sh_selvc2]
    inc ax                             ; one past the last column...
    mov dx, [sh_cellw]
    mul dx
    add ax, [sh_ox]
    add ax, SH_RH_W
    dec ax                             ; ...minus a pixel = its right edge
    mov [sh_selx2], ax

    mov ax, [sh_wrow]
    mov dx, [sh_cellh]
    mul dx
    add ax, [sh_goy]
    add ax, SH_FB_H + SH_CH_H
    mov [sh_sely1], ax

    mov ax, [sh_selvr2]
    inc ax
    mov dx, [sh_cellh]
    mul dx
    add ax, [sh_goy]
    add ax, SH_FB_H + SH_CH_H
    dec ax
    mov [sh_sely2], ax

    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [sh_selx1]
    mov bx, [sh_sely1]
    mov cx, [sh_selx2]
    mov dx, [sh_sely2]
    call OSAPI_GFX_FRAME
    call sh_selsingle                  ; a single cell keeps the plain 1px
    jc .out                            ; frame it has always had; a real
                                        ; RANGE gets a second, inset frame so
                                        ; it reads as a block rather than as
                                        ; one very large cell (this OS has no
                                        ; wide-pen primitive, and XOR fill
                                        ; over the text would be worse - see
                                        ; os88ui_btn's own note on XOR)
    mov ax, [sh_selx1]
    inc ax
    mov bx, [sh_sely1]
    inc bx
    mov cx, [sh_selx2]
    dec cx
    mov dx, [sh_sely2]
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
; Sheet's own in-window menu bar (see the SH_MBAR_H section comment for why
; this exists instead of OS88_MENUSET): File > New / Open... / Save / Save
; As..., Edit > Cut/Copy/Paste/..., Format > dialogs, Data > Sort Column,
; Sheets > switch, Options > Display toggles, Macro > Run, Help > About.
; =============================================================================

; -----------------------------------------------------------------------------
; sh_mtab_calc - measure each menu title's pixel width once (sh_mw), so
; sh_mboxof never has to call OSAPI_FONT_WIDTH itself on every click/paint.
; Called once from sh_entry - the titles are fixed strings, so this never
; needs to run again.
; -----------------------------------------------------------------------------
sh_mtab_calc:
    push ax
    push bx
    push cx
    push si
    push di
    xor cx, cx
.loop:
    cmp cx, SH_MENU_N
    jae .done
    mov ax, cx
    mov bx, 6
    mul bx
    mov bx, ax
    mov si, [sh_mtab + bx]
    call OSAPI_FONT_WIDTH
    mov di, cx
    shl di, 1
    mov [sh_mw + di], ax
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
; sh_mboxof - AL = menu index -> sh_mbx1/sh_mbx2 (screen-absolute box
; bounds, using the raw [sh_ox]/[sh_oy], not the grid-shifted [sh_goy]).
; preserves everything
; -----------------------------------------------------------------------------
sh_mboxof:
    push ax
    push bx
    push cx
    push dx
    push di
    mov cl, al
    xor ch, ch
    mov dx, [sh_ox]
    xor bx, bx
.loop:
    cmp bx, cx
    jae .found
    mov di, bx
    shl di, 1
    mov ax, [sh_mw + di]
    add ax, SH_MPAD*2
    add dx, ax
    inc bx
    jmp .loop
.found:
    mov [sh_mbx1], dx
    mov di, bx
    shl di, 1
    mov ax, [sh_mw + di]
    add ax, SH_MPAD*2
    add dx, ax
    dec dx
    mov [sh_mbx2], dx
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_mbar_draw - the whole menu bar strip: white ground, black rule under
; it, every title (inverted if it is [sh_mopen]). Monochrome-safe black/
; white/invert, matching every other Sheet dialog in this app, rather than
; real Excel 2.1's cyan bar (VM_screenshots/excel_main.png) - this OS
; supports 1bpp Hercules/CGA-mono adapters Sheet's own chrome has stayed
; safe for since stage 1.8, and introducing a new color here would be the
; first thing in this app to depend on one existing at all.
; -----------------------------------------------------------------------------
sh_mbar_draw:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [sh_ox]
    mov bx, [sh_oy]
    mov cx, [sh_ox]
    add cx, [sh_cw]
    dec cx
    mov dx, [sh_oy]
    add dx, SH_MBAR_H - 1
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [sh_ox]
    mov bx, [sh_ox]
    add bx, [sh_cw]
    dec bx
    mov dx, [sh_oy]
    add dx, SH_MBAR_H - 1
    call OSAPI_GFX_HLINE
    mov word [sh_mli], 0
    mov word [sh_mto], 0
.loop:
    mov ax, [sh_mli]
    cmp ax, SH_MENU_N
    jae .done
    mov al, [sh_mli]
    call sh_mboxof
    mov al, [sh_mli]
    cmp al, [sh_mopen]
    jne .normal
    mov ax, [sh_mbx1]
    mov bx, [sh_oy]
    mov cx, [sh_mbx2]
    mov dx, [sh_oy]
    add dx, SH_MBAR_H - 1
    call OSAPI_GFX_FILL
    mov al, CWHITE
    call OSAPI_SET_COLOR
    jmp .drawtitle
.normal:
    mov al, CBLACK
    call OSAPI_SET_COLOR
.drawtitle:
    mov bx, [sh_mto]
    mov si, [sh_mtab + bx]
    mov cx, [sh_mbx1]
    add cx, SH_MPAD
    mov dx, [sh_oy]
    add dx, 3
    call OSAPI_FONT_STR
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [sh_mto]
    add ax, 6
    mov [sh_mto], ax
    mov ax, [sh_mli]
    inc ax
    mov [sh_mli], ax
    jmp .loop
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_mbar_hit - CX,DX (screen-absolute) -> AL = menu index or SH_M_NONE
; -----------------------------------------------------------------------------
sh_mbar_hit:
    push bx
    push cx
    push dx
    mov ax, [sh_oy]
    cmp dx, ax
    jb .no
    add ax, SH_MBAR_H - 1
    cmp dx, ax
    ja .no
    mov word [sh_mli], 0
.loop:
    mov ax, [sh_mli]
    cmp ax, SH_MENU_N
    jae .no
    mov al, [sh_mli]
    call sh_mboxof
    cmp cx, [sh_mbx1]
    jb .next
    cmp cx, [sh_mbx2]
    ja .next
    mov ax, [sh_mli]
    jmp .out
.next:
    mov ax, [sh_mli]
    inc ax
    mov [sh_mli], ax
    jmp .loop
.no:
    mov ax, SH_M_NONE
.out:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; sh_mdrop_geo - compute the open menu's ([sh_mopen]) dropdown rect into
; sh_mrx1/mry1/mrx2/mry2, and stash its items ptr/count into sh_mip/
; sh_mcnt for sh_mdrop_draw and sh_mitem_hit to share. Width is the widest
; item label (skipping a leading MENU_DIS byte when measuring); height is
; item_count*SH_MI_H plus a little top/bottom padding. No sliding-under-
; the-screen-edge case (unlike word.asm's wd_mgeo) - Sheet's own dropdowns
; are short enough that this has never yet needed one.
; -----------------------------------------------------------------------------
sh_mdrop_geo:
    push ax
    push bx
    push cx
    push si
    mov al, [sh_mopen]
    call sh_mboxof
    mov ax, [sh_mbx1]
    mov [sh_mrx1], ax
    mov ax, [sh_oy]
    add ax, SH_MBAR_H
    mov [sh_mry1], ax

    mov bl, [sh_mopen]
    xor bh, bh
    mov ax, bx
    mov cx, 6
    mul cx
    mov bx, ax
    mov si, [sh_mtab + bx + 2]
    mov [sh_mip], si
    mov ax, [sh_mtab + bx + 4]
    mov [sh_mcnt], ax

    mov word [sh_mmaxw], 0
    mov word [sh_mli], 0
.wloop:
    mov ax, [sh_mli]
    cmp ax, [sh_mcnt]
    jae .wdone
    mov bx, [sh_mli]
    shl bx, 1
    mov si, [sh_mip]
    add si, bx
    mov si, [si]
    mov al, [si]
    cmp al, MENU_DIS
    jne .measure
    inc si
.measure:
    call OSAPI_FONT_WIDTH
    cmp ax, [sh_mmaxw]
    jbe .wnext
    mov [sh_mmaxw], ax
.wnext:
    mov ax, [sh_mli]
    inc ax
    mov [sh_mli], ax
    jmp .wloop
.wdone:
    mov ax, [sh_mmaxw]
    add ax, SH_MPAD*2
    mov bx, [sh_mrx1]
    add bx, ax
    dec bx
    mov [sh_mrx2], bx

    mov ax, [sh_mcnt]
    mov cx, SH_MI_H
    mul cx
    add ax, 4
    add ax, [sh_mry1]
    dec ax
    mov [sh_mry2], ax

    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_mdrop_draw - paint the open dropdown from sh_mrx1/y1/x2/y2 + sh_mip/
; sh_mcnt (sh_mdrop_geo must already have run). White panel, black frame,
; one row per item at SH_MI_H apart: disabled items (MENU_DIS) drawn under
; OSAPI_GFX_PEN's disabled (grey) pen; the hot item ([sh_mhi]) drawn
; inverted. Redraws the WHOLE panel on every highlight change rather than
; word.asm's per-row XOR - Sheet's dropdowns are short lists, so this is
; cheap enough not to need that finer granularity.
; -----------------------------------------------------------------------------
sh_mdrop_draw:
    push ax
    push bx
    push cx
    push dx
    push si
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [sh_mrx1]
    mov bx, [sh_mry1]
    mov cx, [sh_mrx2]
    mov dx, [sh_mry2]
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [sh_mrx1]
    mov bx, [sh_mry1]
    mov cx, [sh_mrx2]
    mov dx, [sh_mry2]
    call OSAPI_GFX_FRAME
    mov word [sh_mli], 0
.loop:
    mov ax, [sh_mli]
    cmp ax, [sh_mcnt]
    jae .done
    mov cx, SH_MI_H
    mul cx
    add ax, [sh_mry1]
    add ax, 2
    mov [sh_mry_row], ax
    mov bx, [sh_mip]
    mov cx, [sh_mli]
    shl cx, 1
    add bx, cx
    mov si, [bx]
    mov al, [si]
    cmp al, MENU_DIS
    jne .live
    inc si
    stc
    call OSAPI_GFX_PEN
    jmp .drawtext
.live:
    mov ax, [sh_mli]
    cmp al, [sh_mhi]
    jne .plain
    mov ax, [sh_mrx1]
    inc ax
    mov bx, [sh_mry_row]
    mov cx, [sh_mrx2]
    dec cx
    mov dx, [sh_mry_row]
    add dx, SH_MI_H - 1
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
    mov cx, [sh_mrx1]
    add cx, SH_MPAD
    mov dx, [sh_mry_row]
    call OSAPI_FONT_STR
    mov ax, [sh_mli]
    inc ax
    mov [sh_mli], ax
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
; sh_mitem_hit - CX,DX (screen-absolute) -> AL = item index, or SH_M_NONE
; if outside the panel, on a separator gap, or on a disabled (MENU_DIS)
; item - a disabled row cannot become the hot item at all, which is what
; lets sh_mdrop_draw assume a highlighted row is always live.
; -----------------------------------------------------------------------------
sh_mitem_hit:
    push bx
    push si
    cmp cx, [sh_mrx1]
    jb .no
    cmp cx, [sh_mrx2]
    ja .no
    cmp dx, [sh_mry1]
    jb .no
    cmp dx, [sh_mry2]
    ja .no
    mov ax, dx
    sub ax, [sh_mry1]
    sub ax, 2
    js .no
    push dx
    xor dx, dx
    mov bx, SH_MI_H
    div bx
    pop dx
    cmp ax, [sh_mcnt]
    jae .no
    mov bx, [sh_mip]
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
    mov ax, SH_M_NONE
.out:
    pop si
    pop bx
    ret

; -----------------------------------------------------------------------------
; sh_mclose - close the open dropdown and repaint what it covered. Always a
; full sh_repaint (menu bar included, since sh_drawall draws it first) -
; Sheet's own grid redraw is cheap, unlike word.asm's wd_mrepair, which
; repaints piecewise specifically to avoid a full-document reflow.
; -----------------------------------------------------------------------------
sh_mclose:
    push ax
    push si
    mov byte [sh_mopen], SH_M_NONE
    mov byte [sh_mhi], SH_M_NONE
    mov si, [sh_ownwin]
    call sh_repaint
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_mtrack - the press-drag-release gesture (word.asm's wd_mtrack pattern:
; a tight OSAPI_MOUSE poll with an unlock/yield/relock between reads, never
; W_ONDRAG - see the SH_MBAR_H section comment for why). in: AL = menu
; index to open, SI = window ptr (this callback's own, untouched SI - see
; sh_onclick); called with the gfx lock already held, exactly the state
; the unlock/relock pair expects.
; -----------------------------------------------------------------------------
sh_mtrack:
    push ax
    push bx
    push si
    mov [sh_mopen], al
    mov byte [sh_mhi], SH_M_NONE
    call sh_mdrop_geo
    call sh_mbar_draw
    call sh_mdrop_draw
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
    call sh_mitem_hit
    cmp al, [sh_mhi]
    je .loop
    mov [sh_mhi], al
    call sh_mdrop_draw
    jmp .loop
.release:
    call sh_mitem_hit
    cmp al, SH_M_NONE
    je .closeonly
    mov ah, [sh_mopen]
    push ax
    call sh_mclose
    pop ax
    call sh_mfire
    jmp .out
.closeonly:
    call sh_mclose
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_mfire - AH = menu index, AL = item index -> dispatch. Sets SI to
; [sh_ownwin] unconditionally before calling anything: this runs from
; sh_mtrack's own polling loop, not a kernel AM_ONCMD callback, so nothing
; here can assume SI already IS the window the way sh_oncmd's old kernel-
; supplied SI always was.
; -----------------------------------------------------------------------------
sh_mfire:
    push ax
    push si
    mov si, [sh_ownwin]
    cmp ah, 0
    je .file
    cmp ah, 1
    je .edit
    cmp ah, 2
    je .formula
    cmp ah, 3
    je .format
    cmp ah, 4
    je .data
    cmp ah, 5
    je .options
    cmp ah, 6
    je .macro
    cmp ah, 7
    je .sheets
    cmp ah, 8
    je .help
    jmp .out
.formula:
    or al, al
    jnz .fgoto
    call sh_ndlg_open
    jmp .out
.fgoto:
    mov al, SH_ID_GOTO
    call sh_idlg_open
    jmp .out
.file:
    or al, al
    jnz .fopen
    call sh_new
    jmp .out
.fopen:
    cmp al, 1
    jne .fsave
    mov al, FDLG_OPEN
    call sh_dlg
    jmp .out
.fsave:
    cmp al, 2
    jne .fsaveas
    call sh_dowrite
    mov si, [sh_ownwin]
    call sh_repaint
    jmp .out
.fsaveas:
    cmp al, 3                          ; 3 is Save As...; 4 is Print..., which
    jne .fprint                        ; used to be this label's fall-through
    mov al, FDLG_SAVE
    call sh_dlg
    jmp .out
.fprint:
    mov word [sh_msg], sh_s_noprint
    mov si, [sh_ownwin]
    call sh_repaint
    jmp .out
.edit:
    call sh_docmd_edit
    jmp .out
.format:
    call sh_docmd_format
    jmp .out
.data:
    or al, al                          ; AL was ignored here before Chart
    jnz .data1                         ; Column.../Export were added - Data
                                        ; had exactly one item (Sort Column)
                                        ; so every click ran it regardless.
                                        ; Now a real dispatch, matching the
                                        ; or al,al chains above.
    call sh_docmd_sortcol
    jmp .out
.data1:
    cmp al, 1
    jne .data2
    call sh_docmd_chart
    jmp .out
.data2:
    call sh_docmd_chartexport
    jmp .out
.sheets:
    xor ah, ah                        ; al = item index = target sheet 0..3
    call sh_switchsheet
    jmp .out
.options:
    call sh_docmd_options
    jmp .out
.macro:
    call sh_macro_run
    jmp .out
.help:
    call sh_docmd_help
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_docmd_options - AL = 0 Gridlines / 1 Formulas: flip the flag, re-point
; the item's own string to the matching On/Off label (the same relabel-by-
; repointing idea documented above MENU_DIS in apps/os88api.inc, applied to
; sh_i_options directly rather than through the kernel), repaint.
; -----------------------------------------------------------------------------
sh_docmd_options:
    push si
    or al, al
    jnz .formulas
    xor byte [sh_gridlines], 1
    cmp byte [sh_gridlines], 0
    je .goff
    mov word [sh_i_options], sh_it_grid_on
    jmp .repaint
.goff:
    mov word [sh_i_options], sh_it_grid_off
    jmp .repaint
.formulas:
    xor byte [sh_showformulas], 1
    cmp byte [sh_showformulas], 0
    je .foff
    mov word [sh_i_options+2], sh_it_form_on
    jmp .repaint
.foff:
    mov word [sh_i_options+2], sh_it_form_off
.repaint:
    mov si, [sh_ownwin]
    call sh_repaint
    pop si
    ret

; -----------------------------------------------------------------------------
; sh_docmd_help - the only Help item, About Sheet...
; -----------------------------------------------------------------------------
sh_docmd_help:
    mov al, OS88UI_AOK
    mov bx, [sh_ownwin]
    mov si, sh_s_about
    mov di, sh_help_ack
    call os88ui_ask
    ret
sh_help_ack:
    ret

; -----------------------------------------------------------------------------
; sh_docmd_format - Format menu item AL opens the matching dialog (stage
; 1.8: real Excel's own Format menu is dialog-per-verb - Number.../
; Alignment.../Font... - not a flat immediate-apply list, per the reference
; screenshots at VM_screenshots/dialog_{number,alignment,font}.png; Sheet's
; menu now matches that shape, see the item table below). AL is 0 Number,
; 1 Alignment, 2 Font - the same order sh_fdlg_open expects.
; -----------------------------------------------------------------------------
; sh_docmd_format - Format menu item AL: 0 Number/1 Alignment/2 Font map
; straight onto sh_fdlg_open's own kind numbers. 3 Border opens the
; separate sh_bdlg_* checkbox dialog. 4 Row Height/5 Column Width do NOT
; map straight through - sh_fdlg_open's kinds 3/4 are already Insert/
; Delete (borrowed by the Edit menu), so they're remapped here to kinds
; 6/5 respectively.
sh_docmd_format:
    cmp al, 3
    jne .notborder
    call sh_bdlg_open
    ret
.notborder:
    cmp al, 4
    jne .notrowh
    mov al, SH_ID_ROWH                 ; stage 3.0c: a typed number now, not
    call sh_idlg_open                  ; the 3-preset radio pick this had to
    ret                                ; be while no text field existed
.notrowh:
    cmp al, 5
    jne .notcolw
    mov al, SH_ID_COLW
    call sh_idlg_open
    ret
.notcolw:
    call sh_fdlg_open
    ret

; -----------------------------------------------------------------------------
; sh_docmd_edit - Edit menu item AL. 0 is "Can't Undo" (MENU_DIS - the
; kernel never sends a click for a disabled item, so index 0 is dead here,
; not a bug). 1 Cut, 2 Copy, 3 Paste use the real system clipboard
; (OSAPI_CLIP_*). 4 Clear. 5 Delete... / 6 Insert... both open the
; Row/Column picker (sh_fdlg_* kinds 4 and 3 - see the dialog engine's own
; comment for why one engine now serves 5 kinds). 7 Fill Right / 8 Fill
; Down and 9 Sort Column are deliberately scoped down from real Excel: no
; range selection exists in this app (W_ONDRAG is missing on one of the
; two kernel variants and W_ONCLICK carries no Shift state, so a real
; rectangular selection was ruled out) - fill acts on just the one
; adjacent cell, and sort acts on the whole of the selected column.
; -----------------------------------------------------------------------------
sh_docmd_edit:
    cmp al, 1
    je .cut
    cmp al, 2
    je .copy
    cmp al, 3
    je .paste
    cmp al, 4
    je .clear
    cmp al, 5
    je .delete
    cmp al, 6
    je .insert
    cmp al, 7
    je .fillright
    cmp al, 8
    je .filldown
    cmp al, 9
    je .sort
    ret
.cut:
    call sh_docmd_cut
    ret
.copy:
    call sh_docmd_copy
    ret
.paste:
    call sh_docmd_paste
    ret
.clear:
    call sh_docmd_clear
    ret
.delete:
    mov al, 4
    call sh_fdlg_open
    ret
.insert:
    mov al, 3
    call sh_fdlg_open
    ret
.fillright:
    call sh_docmd_fillright
    ret
.filldown:
    call sh_docmd_filldown
    ret
.sort:
    call sh_docmd_sortcol
    ret

; -----------------------------------------------------------------------------
; sh_docmd_copy - builds the selected cell's text (a formula's own source
; text with its '=' restored, or a plain value's decimal text - the same
; two cases sh_beginedit already knows how to build, just targeting
; sh_clipbuf instead of sh_editbuf) and hands it to the real clipboard. An
; empty cell empties the clipboard instead (CX=0 is documented as not an
; error).
; -----------------------------------------------------------------------------
sh_docmd_copy:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    mov [sh_clip_col], ax              ; stage 2.x: remember where this
    mov [sh_clip_row], bx              ; copy came from, so a later Paste
    mov byte [sh_clip_valid], 1        ; can adjust relative references -
                                        ; see the section comment above
                                        ; sh_copy_shift
    call sh_findcell
    jnc .empty
    push es
    mov es, [sh_cellseg]
    test byte [es:di+4], 1
    jz .plainval
    mov ax, [es:di+SH_C_FOFF]                 ; formula_off
    pop es
    mov byte [sh_clipbuf], '='
    mov di, sh_clipbuf + 1
    mov si, ax
    push es
    mov es, [sh_txtseg]
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
    mov ax, [es:di+SH_C_VAL]
    pop es
    call sh_itoa
    mov si, sh_numbuf
    mov di, sh_clipbuf
    call sh_strcpy
.havelen:
    xor cx, cx
    mov si, sh_clipbuf
.cnt:
    cmp byte [si], 0
    je .putclip
    inc si
    inc cx
    jmp .cnt
.putclip:
    mov ax, ds
    mov es, ax
    mov si, sh_clipbuf
    call OSAPI_CLIP_PUT
    jmp .out
.empty:
    mov ax, ds
    mov es, ax
    mov si, sh_clipbuf
    xor cx, cx
    call OSAPI_CLIP_PUT
.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; sh_docmd_cut - Copy, then Clear
sh_docmd_cut:
    call sh_docmd_copy
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_clearcell
    mov si, [sh_ownwin]
    call sh_repaint
    ret

; sh_docmd_clear
sh_docmd_clear:
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_clearcell
    mov si, [sh_ownwin]
    call sh_repaint
    ret

; -----------------------------------------------------------------------------
; sh_docmd_paste - reads the system clipboard straight into sh_editbuf
; (capped to SH_EDITMAX, same as anything a keyboard could ever produce
; there); if this instance's own last Copy captured a formula AND a
; source cell (sh_clip_valid), and the destination differs from it,
; shifts every reference in the pasted formula by the (col, row) delta
; between them (sh_formula_copyshift) - real Excel's own default
; relative-reference behavior - before calling sh_commit to reuse its
; existing value/formula parsing exactly as if this (possibly rewritten)
; text had been typed. An empty clipboard is a no-op.
; -----------------------------------------------------------------------------
sh_docmd_paste:
    push ax
    push bx
    push cx
    push si
    push di
    push es
    call OSAPI_CLIP_SIZE
    jc .out
    cmp ax, SH_EDITMAX
    jbe .fits
    mov ax, SH_EDITMAX
.fits:
    mov cx, ax
    mov ax, ds
    mov es, ax
    mov di, sh_editbuf
    call OSAPI_CLIP_GET
    mov bx, cx
    mov byte [sh_editbuf + bx], 0
    cmp byte [sh_clip_valid], 0
    je .noshift
    cmp byte [sh_editbuf], '='
    jne .noshift
    mov ax, [sh_selcol]
    sub ax, [sh_clip_col]
    mov [sh_cp_coldelta], ax
    mov bx, [sh_selrow]
    sub bx, [sh_clip_row]
    mov [sh_cp_rowdelta], bx
    or ax, bx
    jz .noshift                        ; pasting to the very cell copied
                                        ; from - nothing to adjust
    mov si, sh_editbuf
    inc si                             ; past the '='
    mov di, sh_rwsrc
.copyin:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov si, sh_rwsrc
    call sh_formula_copyshift
    mov byte [sh_editbuf], '='
    mov si, sh_rwdst
    mov di, sh_editbuf + 1
    mov cx, SH_EDITMAX - 1             ; room left in sh_editbuf after the
                                        ; '=' - a shifted reference can
                                        ; grow a digit or two, so clip
                                        ; rather than overrun
.copyout:
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
.noshift:
    xor cx, cx
    mov si, sh_editbuf
.lenloop:
    cmp byte [si], 0
    je .havenewlen
    inc si
    inc cx
    jmp .lenloop
.havenewlen:
    mov [sh_editlen], cl
    mov byte [sh_editing], 1
    call sh_commit
    mov si, [sh_ownwin]
    call sh_repaint
.out:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_docmd_fillright / sh_docmd_filldown - copy the selected cell into the
; next cell over. Stage 2.x: a formula source now has its own text copied
; (via sh_formula_copyshift, the same relative-reference shift Copy/Paste
; uses) with a (+1,0) or (0,+1) delta, matching real Excel's own Fill
; Right/Down behavior; a plain value is still just copied as its current
; value (sh_getcell2/sh_setval, unchanged from before this fix).
; -----------------------------------------------------------------------------
sh_docmd_fillright:
    push ax
    push bx
    push dx
    push si
    push di
    push es
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_findcell
    jnc .out                           ; empty source: nothing to fill
    mov ax, [sh_selcol]
    inc ax
    cmp ax, SH_COLS
    jae .out
    mov es, [sh_cellseg]
    test byte [es:di+4], 1             ; HASFORMULA
    jz .plain
    mov ax, [es:di+SH_C_FOFF]                  ; formula_off
    mov si, ax
    mov es, [sh_txtseg]
    mov di, sh_rwsrc
.copyin:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov word [sh_cp_coldelta], 1
    mov word [sh_cp_rowdelta], 0
    mov si, sh_rwsrc
    call sh_formula_copyshift
    mov ax, [sh_selcol]
    inc ax
    mov bx, [sh_selrow]
    mov si, sh_rwdst
    call sh_setformula
    jmp .done
.plain:
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_getcell2
    mov ax, [sh_selcol]
    inc ax
    mov bx, [sh_selrow]
    call sh_setval
.done:
    mov si, [sh_ownwin]
    call sh_repaint
.out:
    pop es
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    ret

sh_docmd_filldown:
    push ax
    push bx
    push dx
    push si
    push di
    push es
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_findcell
    jnc .out                           ; empty source: nothing to fill
    mov bx, [sh_selrow]
    inc bx
    cmp bx, SH_ROWS
    jae .out
    mov es, [sh_cellseg]
    test byte [es:di+4], 1             ; HASFORMULA
    jz .plain
    mov ax, [es:di+SH_C_FOFF]                  ; formula_off
    mov si, ax
    mov es, [sh_txtseg]
    mov di, sh_rwsrc
.copyin:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov word [sh_cp_coldelta], 0
    mov word [sh_cp_rowdelta], 1
    mov si, sh_rwsrc
    call sh_formula_copyshift
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    inc bx
    mov si, sh_rwdst
    call sh_setformula
    jmp .done
.plain:
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_getcell2
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    inc bx
    call sh_setval
.done:
    mov si, [sh_ownwin]
    call sh_repaint
.out:
    pop es
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_docmd_sortcol - sorts the selected column's occupied cells (on the
; current sheet) ascending by value; empty rows are left exactly where
; they are, so occupied cells are compacted toward the top the same way
; the original plain-values-only sort already did. Stage 2.x: a formula
; cell now sorts right alongside plain values (by its CURRENT evaluated
; value, via sh_getcell2, so staleness is never an issue) and, if the
; sort actually moves it to a different row, its own text is rewritten
; with sh_formula_copyshift (a (0, row-delta) shift, the same machinery
; Copy/Paste and Fill Down use) so its references still mean what they
; looked like they meant - matching real Excel's own behavior, where
; sorting a range that contains formulas carries their relative
; references along with them. Previously formula cells were excluded
; from the sort entirely (skipped, left in their original row) purely
; because this reference-adjustment capability did not exist yet.
;
; Method: one linear pass over the cell array collects this column's
; occupied cells into sh_stgseg - rows[] at offset 0, values[] at
; SH_SORT_VALS_OFF (both well under its 32KB claim: SH_CELL_CAP=1365
; entries needs at most 2730 bytes each), plus origidx[]/isformula[]/
; fidx[]/staged-formula-text (SH_SORT_ORIG_OFF/SH_SORT_ISF_OFF/
; SH_SORT_FIDX_OFF/SH_SORT_FTXT_OFF - see their own equ comments). Because
; the cell array is sorted by row within a sheet (the stage 2.0 comment
; above sh_findcell), rows[] comes out already ascending for free -
; sorting is really just "which ORIGINAL entry's data ends up at which
; ascending row", so values[] and origidx[] are insertion-sorted together
; (a parallel permutation, not just a value sort) and then written back:
; a plain value straight via sh_setval as before; a formula, only if it
; actually changed row, via sh_formula_copyshift + sh_setformula using
; that specific cell's own (target row - its original row) delta - each
; moved formula can have a DIFFERENT delta, since a sort is an arbitrary
; reordering, not a uniform shift like Insert/Delete Row or Copy/Paste.
; There is no range selection (see the W_ONDRAG scope note on
; sh_docmd_edit), so this always acts on the whole column.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; sh_chart_scan - (re)collect [sh_chart_sheet]/[sh_chart_col]'s plain-value
; cells into sh_stgseg/sh_chart_cnt, capped at CH_MAXBARS (same shape as
; sh_docmd_sortcol's own scan). Does NOT touch sh_chart_sheet/sh_chart_col
; themselves - sh_docmd_chart freezes those from the current selection
; before calling this; the live-update hook in sh_repaint calls this
; against whatever was already frozen, so every edit to the charted column
; is reflected without retargeting the chart to wherever the selection
; happens to be at the time.
; -----------------------------------------------------------------------------
sh_chart_scan:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov word [sh_chart_cnt], 0
    xor cx, cx
.scan:
    mov ax, [sh_chart_cnt]
    cmp ax, CH_MAXBARS
    jae .scandone
    cmp cx, [sh_ncells]
    jae .scandone
    mov ax, cx
    mov bx, SH_C_SZ
    mul bx
    mov si, ax
    mov es, [sh_cellseg]
    mov ax, [es:si]
    call sh_unpackrow                  ; ax=row, bx=sheet
    cmp bx, [sh_chart_sheet]
    jne .next
    mov dx, [es:si+2]                  ; col
    cmp dx, [sh_chart_col]
    jne .next
    test byte [es:si+4], 1             ; HASFORMULA: chart its CURRENT value
    jz .plainval                       ; (sh_getcell2 evaluates transparently
    mov bx, ax                         ; and is never stale) rather than
                                        ; skipping it - a column of formulas
                                        ; used to chart as completely empty.
                                        ; AX still holds this record's row
                                        ; from sh_unpackrow above.
    mov ax, [sh_chart_col]
    push cx                            ; CX is this scan's own index and
    push si                            ; sh_getcell2 does not preserve it -
    call sh_getcell2                   ; see the matching note in
    pop si                             ; sh_docmd_sortcol.
    pop cx
    jmp .havevalue
.plainval:
    call sh_cellint_si                 ; the chart plots whole numbers, so the
    mov dx, ax                         ; value is truncated here rather than
.havevalue:                            ; read as the low half of its double
    mov bx, [sh_chart_cnt]
    shl bx, 1
    mov di, bx
    mov es, [sh_stgseg]
    mov [es:di], dx
    inc word [sh_chart_cnt]
.next:
    inc cx
    jmp .scan
.scandone:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_docmd_chart - Data > Chart Column...: freeze the current sheet/column,
; scan its plain values via sh_chart_scan, then create-or-show the chart
; window and draw it.
;
; The window, once created, is NEVER destroyed by this app again - only
; shown/hidden. Traced directly against the kernel (kernel/instance.inc's
; app_close_win): clicking a non-primary window's own close box only calls
; wm_hide, not a real destroy - the record stays valid, just invisible,
; until the whole instance tears down (wm_destroy_seg cleans it up then,
; automatically). Re-creating a fresh window on every "Chart Column..."
; click would leak one of the system's MAX_WIN=12 window slots per click;
; treating a second click as "just show it again" does not.
; -----------------------------------------------------------------------------
sh_docmd_chart:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov ax, [sh_cursheet]
    mov [sh_chart_sheet], ax
    mov ax, [sh_selcol]
    mov [sh_chart_col], ax
    call sh_chart_scan
    cmp word [sh_chartwin], 0
    jne .haswin
    mov si, sh_chart_tpl
    call OSAPI_WM_CREATE
    jc .out                            ; refused: silently give up, same
                                        ; scope limit sh_fdlg_open's own
                                        ; "already open, stay safe" has
    mov [sh_chartwin], bx
.haswin:
    mov bx, [sh_chartwin]
    call OSAPI_WM_SHOW
    call sh_chart_render
    mov si, [sh_chartwin]
    call sh_chart_paint
    mov word [sh_msg], sh_s_charted
    mov si, [sh_ownwin]                ; repaint OUR OWN window too - this
    call sh_repaint                    ; only ever painted the chart window
                                        ; above, so the status bar's own
                                        ; "Charted." message was set but
                                        ; never actually shown until now
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; sh_chart_render - rasterize the currently-staged values (sh_stgseg
; offset 0, count sh_chart_cnt) into the chart's own offscreen buffer
; (sh_chartseg), via apps/os88chart.inc's ch_bars_draw. DS is never
; touched - ch_bars_draw takes the array's segment as an explicit
; parameter (DX) and swaps ES internally instead of borrowing DS, so this
; caller's own bss stays reachable via the normal, unchanged DS throughout
; (see ch_bars_draw's own header comment for why that matters).
sh_chart_render:
    push ax
    push cx
    push dx
    push si
    push es
    mov cx, [sh_chart_cnt]
    mov es, [sh_chartseg]
    mov dx, [sh_stgseg]
    xor si, si
    call ch_draw                        ; stage 3.0f: the gallery. Sheet has no
                                        ; Gallery menu of its own yet, so
                                        ; [ch_type] stays CH_T_COLUMN - but
                                        ; going through the dispatcher now
                                        ; means the two apps cannot drift into
                                        ; drawing the same data differently
    pop es
    pop si
    pop dx
    pop cx
    pop ax
    ret

; sh_chart_paint - the chart window's own W_PAINT callback (SI=window);
; one OSAPI_GFX_BLIT4 of the already-rasterized buffer, nothing else
sh_chart_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push es
    mov bx, si
    call OSAPI_WM_CONTENT               ; ax=content x, dx=content y
    mov [ch_bx1], ax                    ; borrow this scratch - safe here,
    mov [ch_by1], dx                    ; ch_bars_draw already finished by
                                         ; the time sh_chart_paint ever runs
    mov es, [sh_chartseg]
    mov si, CH_PXOFF
    mov bp, CH_STRIDE
    mov ax, [ch_bx1]
    mov bx, [ch_by1]
    mov cx, CH_W
    mov dx, CH_H
    call OSAPI_GFX_BLIT4
    pop es
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

sh_chart_tpl:
    dw 0, 0, SH_CHARTWIN_W, SH_CHARTWIN_H
    dw sh_s_chart_title, sh_chart_paint, 0, 0
sh_s_chart_title: db 'Chart', 0
sh_s_charted:      db 'Charted.', 0

; sh_docmd_chartexport - Data > Export Chart as BMP...: a no-op
; informational message if there's nothing charted yet (same "still runs,
; OK is just a no-op" idiom used throughout this file), else the standard
; Save dialog, writing the chart's own offscreen buffer via
; apps/os88chart.inc's ch_bmp_write once a name is chosen.
sh_docmd_chartexport:
    push ax
    push bx
    push si
    push di
    cmp word [sh_chartwin], 0
    je .nothing
    cmp word [sh_chart_cnt], 0
    je .nothing
    mov al, FDLG_SAVE
    mov bx, [sh_ownwin]
    mov di, sh_chartexp_ondlg
    mov si, sh_s_chartbmp
    call OSAPI_FILE_DLG
    jmp .out
.nothing:
    mov word [sh_msg], sh_s_nochart
.out:
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_chartexp_ondlg - the Export Chart dialog's completion proc (SPEC.md
; 38.6, same shape as sh_ondlg but writing the chart buffer, not the sheet,
; and never reading back - Export is always a Save). In: AL=mode
; (unused), SI=our window ptr, DI=chosen name (ES=KERNEL_SEG); UI task,
; gfx lock HELD, dialog already destroyed - we owe the repaint.
; -----------------------------------------------------------------------------
sh_chartexp_ondlg:
    push ax
    push bx
    push si
    push di
    mov si, di
    mov di, sh_chart_name
    mov ax, SH_NAMEMAX
.copy:
    mov al, [es:si]
    mov [di], al
    or al, al
    jz .copied
    inc si
    inc di
    dec ax
    jnz .copy
    mov byte [di], 0
.copied:
    mov es, [sh_chartseg]
    mov bx, [sh_stgseg]
    mov si, sh_chart_name
    call ch_bmp_write
    jnc .ok
    mov word [sh_msg], sh_s_experr
    jmp .draw
.ok:
    mov word [sh_msg], sh_s_exported
.draw:
    mov si, [sh_ownwin]
    call sh_repaint
    pop di
    pop si
    pop bx
    pop ax
    ret

sh_s_chartbmp: db 'CHART.BMP', 0
sh_s_nochart:  db 'No chart to export.', 0
sh_s_experr:   db 'Chart export failed.', 0
sh_s_exported: db 'Chart exported.', 0

sh_docmd_sortcol:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov word [sh_sort_cnt], 0
    mov word [sh_sort_fcnt], 0
    xor cx, cx
.scan:
    cmp cx, [sh_ncells]
    jae .scandone
    mov ax, cx
    mov bx, SH_C_SZ
    mul bx
    mov si, ax
    mov es, [sh_cellseg]
    mov ax, [es:si]
    call sh_unpackrow                 ; ax=row, bx=sheet
    cmp bx, [sh_cursheet]
    jne .next
    mov dx, [es:si+2]                 ; col
    cmp dx, [sh_selcol]
    jne .next
    mov [sh_sort_row], ax             ; ax = row, stashed (0-based)
    test byte [es:si+4], 1            ; HASFORMULA
    jz .isplainval
    cmp word [sh_sort_fcnt], SH_SORT_FCAP
    jae .next                         ; too many formulas to carry through
                                       ; this sort: exclude this one
                                       ; entirely (see SH_SORT_FCAP's own
                                       ; comment)
    mov ax, dx                        ; col (== sh_selcol, just compared)
    mov bx, [sh_sort_row]
    push cx                           ; CX is this scan's own cell index and
                                       ; sh_getcell2 does NOT preserve it: for
                                       ; a formula cell it reaches sh_eval_cell
                                       ; -> sh_pcmp -> sh_pterm's own `.div`,
                                       ; which does `mov cx, ax` to hold the
                                       ; divisor. Without this save, sorting a
                                       ; column containing any formula that
                                       ; uses '/' restarts or skips the scan
                                       ; from an arbitrary index, silently
                                       ; duplicating or dropping cells.
    push si
    call sh_getcell2                  ; -> dx = its CURRENT value (never
    pop si                            ; stale - see this proc's own header)
    pop cx
    mov [sh_sort_val], dx
    mov es, [sh_cellseg]
    mov ax, [es:si+SH_C_FOFF]         ; formula_off
    mov si, ax
    mov es, [sh_txtseg]
    mov di, sh_rwsrc
.copyin:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov ax, [sh_sort_fcnt]
    mov [sh_sort_fslot], ax
    mov bx, 64
    mul bx
    add ax, SH_SORT_FTXT_OFF
    mov di, ax
    mov es, [sh_stgseg]
    mov si, sh_rwsrc
.copyout:
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    or al, al
    jnz .copyout
    inc word [sh_sort_fcnt]
    mov al, 1                         ; isformula flag
    jmp .stage
.isplainval:
    mov dx, [es:si+SH_S_VAL]                 ; plain value
    mov [sh_sort_val], dx
    xor al, al                        ; isformula flag
.stage:
    mov bx, [sh_sort_cnt]
    mov es, [sh_stgseg]
    mov di, bx
    shl di, 1
    mov dx, [sh_sort_row]
    mov [es:di], dx                   ; rows[cnt] = row
    mov di, bx
    shl di, 1
    add di, SH_SORT_VALS_OFF
    mov dx, [sh_sort_val]
    mov [es:di], dx                   ; values[cnt] = value
    mov di, bx
    shl di, 1
    add di, SH_SORT_ORIG_OFF
    mov [es:di], bx                   ; origidx[cnt] = cnt (pre-sort)
    mov di, bx
    add di, SH_SORT_ISF_OFF
    mov [es:di], al                   ; isformula[cnt]
    or al, al
    jz .noformidx
    mov di, bx
    shl di, 1
    add di, SH_SORT_FIDX_OFF
    mov dx, [sh_sort_fslot]
    mov [es:di], dx                   ; fidx[cnt] = its own text slot
.noformidx:
    inc word [sh_sort_cnt]
.next:
    inc cx
    jmp .scan
.scandone:
    mov cx, [sh_sort_cnt]
    cmp cx, 2
    jb .sortdone
    mov es, [sh_stgseg]
    mov bx, 1
.outer:
    cmp bx, cx
    jae .sortdone
    mov si, bx
    shl si, 1
    add si, SH_SORT_VALS_OFF
    mov dx, [es:si]                   ; dx = key = values[bx]
    mov si, bx
    shl si, 1
    add si, SH_SORT_ORIG_OFF
    mov ax, [es:si]                   ; ax = key's own origidx
    mov [sh_sort_keyval], dx
    mov [sh_sort_keyorig], ax
    mov di, bx
.inner:
    or di, di
    jz .insert
    mov si, di
    dec si
    shl si, 1
    add si, SH_SORT_VALS_OFF
    mov ax, [es:si]                   ; values[j-1]
    cmp ax, [sh_sort_keyval]
    jle .insert
    mov si, di
    dec si
    shl si, 1
    add si, SH_SORT_VALS_OFF
    mov ax, [es:si]
    mov si, di
    shl si, 1
    add si, SH_SORT_VALS_OFF
    mov [es:si], ax                   ; values[j] = values[j-1]
    mov si, di
    dec si
    shl si, 1
    add si, SH_SORT_ORIG_OFF
    mov ax, [es:si]
    mov si, di
    shl si, 1
    add si, SH_SORT_ORIG_OFF
    mov [es:si], ax                   ; origidx[j] = origidx[j-1]
    dec di
    jmp .inner
.insert:
    mov si, di
    shl si, 1
    add si, SH_SORT_VALS_OFF
    mov ax, [sh_sort_keyval]
    mov [es:si], ax
    mov si, di
    shl si, 1
    add si, SH_SORT_ORIG_OFF
    mov ax, [sh_sort_keyorig]
    mov [es:si], ax
    inc bx
    jmp .outer
.sortdone:
    xor cx, cx
.wb:
    cmp cx, [sh_sort_cnt]
    jae .wbdone
    mov es, [sh_stgseg]
    mov si, cx
    shl si, 1
    mov ax, [es:si]                   ; target_row = rows[cx] (unchanged -
    mov [sh_sort_trow], ax            ; the occupied rows themselves never
                                       ; move, only which VALUE/FORMULA
                                       ; sits in each one does)
    mov si, cx
    shl si, 1
    add si, SH_SORT_ORIG_OFF
    mov ax, [es:si]                   ; src = origidx[cx]
    mov [sh_sort_src], ax
    mov si, ax
    add si, SH_SORT_ISF_OFF
    mov al, [es:si]
    or al, al
    jz .wbplain
    mov si, [sh_sort_src]
    shl si, 1
    mov ax, [es:si]                   ; src_row = rows[src]
    mov bx, [sh_sort_trow]
    sub bx, ax                        ; row delta = target - src
    jz .wbnext                        ; unchanged position: already
                                       ; correct, nothing to rewrite
    mov [sh_cp_rowdelta], bx
    mov word [sh_cp_coldelta], 0
    mov si, [sh_sort_src]
    shl si, 1
    add si, SH_SORT_FIDX_OFF
    mov ax, [es:si]                   ; this formula's own text-slot index
    mov bx, 64
    mul bx
    add ax, SH_SORT_FTXT_OFF
    mov si, ax
    mov di, sh_rwsrc
.wbcopyin:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .wbcopyin
    push cx
    mov si, sh_rwsrc
    call sh_formula_copyshift
    mov ax, [sh_selcol]
    mov bx, [sh_sort_trow]
    mov si, sh_rwdst
    call sh_setformula
    pop cx
    jmp .wbnext
.wbplain:
    mov si, cx
    shl si, 1
    add si, SH_SORT_VALS_OFF
    mov dx, [es:si]                   ; sorted value at this position
    push cx
    mov ax, [sh_selcol]
    mov bx, [sh_sort_trow]
    call sh_setval
    pop cx
.wbnext:
    inc cx
    jmp .wb
.wbdone:
    mov si, [sh_ownwin]
    call sh_repaint
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; Format dialogs (stage 1.8). Real Excel's Number/Alignment/Font dialogs
; each boil down to "pick one of a short list, then OK/Cancel" for what
; this app actually supports (Number's real dialog is a much longer
; scrollable list of format-code strings, VM_screenshots/dialog_number.png -
; Sheet only ever has 4 number formats, so a plain 4-item radio list stands
; in for it, same shape as the real Alignment and Font dialogs). All three
; are really the SAME dialog (a title, 4 radio rows, OK/Cancel) with
; different labels and a different 2-bit field of the format byte to read
; and write - see sh_fdlg_kind - which is why one implementation serves
; all three rather than three near-copies.
;
; Built directly on apps/os88ui.inc's primitives (os88ui_glyph for the
; radio dots, os88ui_btn for OK/Cancel) rather than os88ui_ask, which only
; ever offers a message and a button row - there is no generic
; "N controls" dialog builder in this codebase (apps/word/word.asm rolled
; its own, ~900 lines, for a dozen much bigger dialogs; three small
; identical-shaped ones don't need that). Only one can be open at a time
; (sh_fdlg_win is the gate, same single-instance idea as os88ui_awin, just
; simpler: this dialog doesn't need "refuse and raise" since the menu
; command that opens it can't fire again while it's up).
;
; Radio index 0-3 in each dialog is deliberately identical to that
; category's own SH_FMT_* encoding (SH_FMT_ALIGN_LEFT=1, SH_FMT_NUM_COMMA=2,
; etc, and Font's 0=Normal/1=Bold/2=Underline/3=Bold+Underline is just
; SH_FMT_BOLD|SH_FMT_UNDER's own bit pattern) - so applying a choice is a
; plain mask-and-OR, no translation table needed anywhere.
; =============================================================================
SH_FDLG_W      equ 170
SH_FDLG_H      equ 116
SH_FDLG_ROWTOP equ 12
SH_FDLG_ROWH   equ 16
SH_FDLG_NITEMS equ 4

sh_fdlg_tpl:
    dw 0, 0, SH_FDLG_W, SH_FDLG_H
    dw 0, sh_fdlg_paint, 0, sh_fdlg_onclick

; Stage 2.x's Edit menu Insert.../Delete... reuse this same engine as kinds
; 3 and 4 - just a 2-item Row/Column pick instead of a 4-item format
; radio, and a different [sh_fdlg_count] (see sh_fdlg_open) since these
; two kinds don't have 4 rows to show. sh_fdlg_apply branches to
; sh_rowcol_op for these two kinds instead of writing a format bit.
; Kinds 5/6 (Column Width.../Row Height...) are a third borrowing: a
; 3-item preset pick instead of a per-cell format bit, applied to the
; whole sheet's runtime sh_cellw/sh_cellh (see the section comment above
; sh_entry for why these are presets rather than real Excel's free-text
; entry).
sh_fdlg_titles: dw sh_s_fd_num, sh_s_fd_align, sh_s_fd_font, sh_s_fd_insert, sh_s_fd_delete, sh_s_fd_colw, sh_s_fd_rowh
sh_s_fd_num:    db 'Format Number', 0
sh_s_fd_align:  db 'Alignment', 0
sh_s_fd_font:   db 'Font', 0
sh_s_fd_insert: db 'Insert', 0
sh_s_fd_delete: db 'Delete', 0
sh_s_fd_colw:   db 'Column Width', 0
sh_s_fd_rowh:   db 'Row Height', 0

sh_fdlg_items:  dw sh_fd_i_num, sh_fd_i_align, sh_fd_i_font, sh_fd_i_rowcol, sh_fd_i_rowcol, sh_fd_i_colw, sh_fd_i_rowh
sh_fd_i_num:    dw sh_fd_numgen, sh_fd_numcur, sh_fd_numcomma, sh_fd_numpct
sh_fd_numgen:   db 'General', 0
sh_fd_numcur:   db 'Currency', 0
sh_fd_numcomma: db 'Comma', 0
sh_fd_numpct:   db 'Percent', 0
sh_fd_i_align:  dw sh_fd_agen, sh_fd_aleft, sh_fd_acenter, sh_fd_aright
sh_fd_agen:     db 'General', 0
sh_fd_aleft:    db 'Left', 0
sh_fd_acenter:  db 'Center', 0
sh_fd_aright:   db 'Right', 0
sh_fd_i_font:   dw sh_fd_fnorm, sh_fd_fbold, sh_fd_funder, sh_fd_fboth
sh_fd_fnorm:    db 'Normal', 0
sh_fd_fbold:    db 'Bold', 0
sh_fd_funder:   db 'Underline', 0
sh_fd_fboth:    db 'Bold, Underline', 0
sh_fd_i_rowcol: dw sh_fd_rcrow, sh_fd_rccol
sh_fd_rcrow:    db 'Row', 0
sh_fd_rccol:    db 'Column', 0
sh_fd_i_colw:   dw sh_fd_cwnarrow, sh_fd_cwnormal, sh_fd_cwwide
sh_fd_cwnarrow: db 'Narrow', 0
sh_fd_cwnormal: db 'Normal', 0
sh_fd_cwwide:   db 'Wide', 0
sh_fd_i_rowh:   dw sh_fd_rhshort, sh_fd_rhnormal, sh_fd_rhtall
sh_fd_rhshort:  db 'Short', 0
sh_fd_rhnormal: db 'Normal', 0
sh_fd_rhtall:   db 'Tall', 0

sh_s_fd_ok:     db 'OK', 0
sh_s_fd_cancel: db 'Cancel', 0

; per-kind row count (0 Number/1 Align/2 Font = 4 rows, 3 Insert/4 Delete
; = 2 rows, 5 Column Width/6 Row Height = 3 rows) - sh_fdlg_open copies the
; matching entry into [sh_fdlg_count], which sh_fdlg_paint/sh_fdlg_onclick
; loop and hit-test against instead of the fixed SH_FDLG_NITEMS.
sh_fdlg_counts: dw 4, 4, 4, 2, 2, 3, 3

; -----------------------------------------------------------------------------
; sh_fdlg_open - in: AL = 0 Number / 1 Alignment / 2 Font. Preselects the
; radio matching the selected cell's current format (0/General if the cell
; has no record yet - the dialog still opens; OK on a still-empty cell is a
; no-op, same scope limit the old flat menu already had).
; -----------------------------------------------------------------------------
sh_fdlg_open:
    push ax
    push bx
    push cx
    push si
    push di
    cmp word [sh_fdlg_win], 0
    jne .out                          ; already open (can't happen via the
                                       ; menu, which is inert while a dialog
                                       ; owns input focus, but stay safe)
    mov [sh_fdlg_kind], al
    mov word [sh_fdlg_sel], 0
    mov bl, al
    xor bh, bh
    shl bx, 1
    mov cx, [sh_fdlg_counts + bx]
    mov [sh_fdlg_count], cx
    cmp al, 5
    jae .prefillsize                  ; Column Width/Row Height (kinds
                                       ; 5/6): preselect from the CURRENT
                                       ; sh_cellw/sh_cellh, not a cell
    cmp al, 3
    jae .noprefill                    ; Insert/Delete (kinds 3/4): no
                                       ; "current" selection to preselect,
                                       ; just default to row 0 ("Row")
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_findcell
    jnc .noprefill
    push es
    mov es, [sh_cellseg]
    mov al, [es:di+5]
    pop es
    mov ah, 0
    cmp byte [sh_fdlg_kind], 0
    je .pfnum
    cmp byte [sh_fdlg_kind], 1
    je .pfalign
    and al, 0x03                      ; Font: bits0-1 directly
    jmp .havesel
.pfnum:
    and al, SH_FMT_NUM_MASK
    mov cl, SH_FMT_NUM_SHIFT
    shr al, cl
    jmp .havesel
.pfalign:
    and al, SH_FMT_ALIGN_MASK
    mov cl, SH_FMT_ALIGN_SHIFT
    shr al, cl
.havesel:
    mov [sh_fdlg_sel], ax
    jmp .noprefill
.prefillsize:
    cmp al, 5
    jne .prefillrowh
    mov ax, [sh_cellw]
    cmp ax, SH_CW_NARROW
    jne .cwn2
    mov word [sh_fdlg_sel], 0
    jmp .noprefill
.cwn2:
    cmp ax, SH_CW_WIDE
    jne .cwn3
    mov word [sh_fdlg_sel], 2
    jmp .noprefill
.cwn3:
    mov word [sh_fdlg_sel], 1          ; Normal, or any non-preset value
    jmp .noprefill
.prefillrowh:
    mov ax, [sh_cellh]
    cmp ax, SH_RH_SHORT
    jne .rhn2
    mov word [sh_fdlg_sel], 0
    jmp .noprefill
.rhn2:
    cmp ax, SH_RH_TALL
    jne .rhn3
    mov word [sh_fdlg_sel], 2
    jmp .noprefill
.rhn3:
    mov word [sh_fdlg_sel], 1
.noprefill:
    mov bl, [sh_fdlg_kind]
    xor bh, bh
    shl bx, 1
    mov ax, [sh_fdlg_titles + bx]
    mov [sh_fdlg_tpl + WT_TITLE], ax
    call OSAPI_VIDEO                  ; centre on the LIVE screen, the same
    sub ax, SH_FDLG_W                 ; way os88ui_ask does (apps/os88ui.inc)
    sar ax, 1
    mov [sh_fdlg_tpl + WT_X], ax
    sub bx, SH_FDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8                ; never under the menu bar
.placed:
    mov [sh_fdlg_tpl + WT_Y], bx
    mov si, sh_fdlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [sh_fdlg_win], bx
    call OSAPI_WM_SHOW
.out:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_fdlg_paint - SI = the dialog window. Uses bss scratch (sh_fdlg_ox/oy/
; itemsptr/rowidx/rowy) rather than stack juggling to hold state across the
; os88ui_glyph/OSAPI_FONT_RUN calls, since both take CX/DX as their own
; position input - a register-only approach would need constant reshuffling
; for no real benefit here (this paints at most once per click).
; -----------------------------------------------------------------------------
sh_fdlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si                         ; OSAPI_WM_CONTENT wants BX=window
    call OSAPI_WM_CONTENT              ; -> ax=content x, dx=content y
    mov [sh_fdlg_ox], ax
    mov [sh_fdlg_oy], dx
    mov bl, [sh_fdlg_kind]
    xor bh, bh
    shl bx, 1
    mov si, [sh_fdlg_items + bx]       ; the window's own title bar already
    mov [sh_fdlg_itemsptr], si         ; names the dialog (sh_fdlg_open set
                                        ; WT_TITLE) - no need to repeat it as
                                        ; content
    mov word [sh_fdlg_rowidx], 0
.rowloop:
    mov cx, [sh_fdlg_rowidx]
    cmp cx, [sh_fdlg_count]
    jae .rowsdone
    mov ax, cx
    mov bx, SH_FDLG_ROWH
    mul bx
    add ax, SH_FDLG_ROWTOP
    add ax, [sh_fdlg_oy]
    mov [sh_fdlg_rowy], ax
    mov ax, [sh_fdlg_sel]
    cmp ax, [sh_fdlg_rowidx]
    mov al, OS88UI_GRADIO
    jne .goff
    or al, OS88UI_GON
.goff:
    mov ah, 0
    mov cx, [sh_fdlg_ox]
    add cx, 8
    mov dx, [sh_fdlg_rowy]
    call os88ui_glyph                  ; preserves all registers (its own doc)
    mov si, [sh_fdlg_itemsptr]
    mov bx, [sh_fdlg_rowidx]
    shl bx, 1
    add si, bx
    mov si, [si]                       ; si = this row's label string
    mov cx, [sh_fdlg_ox]
    add cx, 24
    mov dx, [sh_fdlg_rowy]
    add dx, 2
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_RUN
    mov ax, [sh_fdlg_rowidx]
    inc ax
    mov [sh_fdlg_rowidx], ax
    jmp .rowloop
.rowsdone:
    mov ax, [sh_fdlg_ox]
    add ax, 8
    mov [sh_fdlg_rect], ax
    mov ax, [sh_fdlg_oy]
    add ax, 86
    mov [sh_fdlg_rect+2], ax
    mov ax, [sh_fdlg_ox]
    add ax, 62
    mov [sh_fdlg_rect+4], ax
    mov ax, [sh_fdlg_oy]
    add ax, 102
    mov [sh_fdlg_rect+6], ax
    mov bx, sh_fdlg_rect
    mov si, sh_s_fd_ok
    mov di, OS88UI_DEF
    call os88ui_btn
    mov ax, [sh_fdlg_ox]
    add ax, 96
    mov [sh_fdlg_rect], ax
    mov ax, [sh_fdlg_oy]
    add ax, 86
    mov [sh_fdlg_rect+2], ax
    mov ax, [sh_fdlg_ox]
    add ax, 150
    mov [sh_fdlg_rect+4], ax
    mov ax, [sh_fdlg_oy]
    add ax, 102
    mov [sh_fdlg_rect+6], ax
    mov bx, sh_fdlg_rect
    mov si, sh_s_fd_cancel
    xor di, di
    call os88ui_btn
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_fdlg_onclick - in: CX=x, DX=y (screen-absolute, same convention as
; sh_onclick), SI=the dialog window
; -----------------------------------------------------------------------------
sh_fdlg_onclick:
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
    cmp bx, 86
    jb .checkcancel
    cmp bx, 102
    ja .checkcancel
    jmp .doOK
.checkcancel:
    cmp cx, 96
    jb .checkrows
    cmp cx, 150
    ja .checkrows
    cmp bx, 86
    jb .checkrows
    cmp bx, 102
    ja .checkrows
    jmp .doCancel
.checkrows:
    cmp cx, 8
    jb .out
    cmp bx, SH_FDLG_ROWTOP
    jb .out
    mov ax, bx
    sub ax, SH_FDLG_ROWTOP
    xor dx, dx
    mov si, SH_FDLG_ROWH
    div si                             ; ax = row index
    cmp ax, [sh_fdlg_count]
    jae .out
    mov [sh_fdlg_sel], ax
    mov si, [sh_fdlg_win]
    call sh_fdlg_paint
    jmp .out
.doOK:
    call sh_fdlg_apply
    call sh_fdlg_close
    jmp .out
.doCancel:
    call sh_fdlg_close
.out:
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_fdlg_apply - kinds 0-2 (Number/Alignment/Font): write [sh_fdlg_sel]
; into the selected cell's format byte, in the field [sh_fdlg_kind] names -
; a no-op if the cell has no record (see sh_fdlg_open's own comment on
; that scope limit). Kinds 3-4 (Insert/Delete): [sh_fdlg_sel] is 0 Row / 1
; Column, so hand off to sh_rowcol_op with the selected cell's own row or
; column as the pivot index - these have no "cell must have a record"
; limit, since they act on the grid's structure, not a cell's content.
; -----------------------------------------------------------------------------
sh_fdlg_apply:
    push ax
    push bx
    push cx
    push di
    push es
    cmp byte [sh_fdlg_kind], 5
    je .colwidth
    cmp byte [sh_fdlg_kind], 6
    je .rowheight
    cmp byte [sh_fdlg_kind], 3
    je .insertrc
    cmp byte [sh_fdlg_kind], 4
    je .deleterc
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_findcell
    jnc .out
    mov es, [sh_cellseg]
    mov bl, [es:di+5]
    mov al, [sh_fdlg_sel]
    cmp byte [sh_fdlg_kind], 0
    je .num
    cmp byte [sh_fdlg_kind], 1
    je .align
    and bl, SH_FMT_BU_CLR              ; Font: bits0-1 directly
    or bl, al
    jmp .apply
.num:
    and bl, SH_FMT_NUM_CLR
    mov cl, SH_FMT_NUM_SHIFT
    shl al, cl
    or bl, al
    jmp .apply
.align:
    and bl, SH_FMT_ALIGN_CLR
    mov cl, SH_FMT_ALIGN_SHIFT
    shl al, cl
    or bl, al
.apply:
    mov [es:di+5], bl
    call sh_repaint
    jmp .out
.colwidth:
    mov ax, [sh_fdlg_sel]
    or ax, ax
    jnz .cwnotnarrow
    mov word [sh_cellw], SH_CW_NARROW
    jmp .cwdone
.cwnotnarrow:
    cmp ax, 2
    jne .cwnormal
    mov word [sh_cellw], SH_CW_WIDE
    jmp .cwdone
.cwnormal:
    mov word [sh_cellw], SH_CW_NORMAL
.cwdone:
    mov ax, [sh_cellw]
    mov cl, 3
    shr ax, cl
    mov [sh_cellch], ax
    call sh_mkblank
    mov si, [sh_ownwin]
    call sh_repaint
    jmp .out
.rowheight:
    mov ax, [sh_fdlg_sel]
    or ax, ax
    jnz .rhnotshort
    mov word [sh_cellh], SH_RH_SHORT
    jmp .rhdone
.rhnotshort:
    cmp ax, 2
    jne .rhnormal
    mov word [sh_cellh], SH_RH_TALL
    jmp .rhdone
.rhnormal:
    mov word [sh_cellh], SH_RH_NORMAL
.rhdone:
    mov si, [sh_ownwin]
    call sh_repaint
    jmp .out
.insertrc:
    cmp word [sh_fdlg_sel], 0
    jne .inscol
    mov al, 0                          ; op 0 = insert row
    mov bx, [sh_selrow]
    jmp .rcgo
.inscol:
    mov al, 2                          ; op 2 = insert column
    mov bx, [sh_selcol]
    jmp .rcgo
.deleterc:
    cmp word [sh_fdlg_sel], 0
    jne .delcol
    mov al, 1                          ; op 1 = delete row
    mov bx, [sh_selrow]
    jmp .rcgo
.delcol:
    mov al, 3                          ; op 3 = delete column
    mov bx, [sh_selcol]
.rcgo:
    call sh_rowcol_op
    mov si, [sh_ownwin]
    call sh_repaint
.out:
    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_fdlg_close
; -----------------------------------------------------------------------------
sh_fdlg_close:
    push ax
    push bx
    mov bx, [sh_fdlg_win]
    or bx, bx
    jz .out
    mov word [sh_fdlg_win], 0
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
; Border dialog (stage 2.x). Real Excel 2.1's Format > Border... is a
; "Border" GROUP BOX holding six independent CHECKBOXES (Outline/Left/
; Right/Top/Bottom/Shade) with OK/Cancel standing beside it, not below it
; (VM_screenshots/dialog_border.png) - a materially different shape from
; Number/Alignment/Font's single-choice radio lists, so it gets its own
; small engine rather than being forced into sh_fdlg_*'s. "Outline" is
; UI-only: checking it sets all four edges at once and unchecking it clears
; all four, matching real Excel's own behavior - there is no stored
; "outline" bit separate from the four edges themselves, so re-opening the
; dialog on a cell that has all four set shows Outline checked too, purely
; because sh_bdlg_open recomputes it from them.
; =============================================================================
SH_BDLG_W      equ 190
SH_BDLG_H      equ 150
SH_BDLG_GX1    equ 10                ; the "Border" group box, inset from
SH_BDLG_GY1    equ 12                ; the dialog's own content origin
SH_BDLG_GX2    equ 104
SH_BDLG_GY2    equ 132
SH_BDLG_ROWTOP equ 26                ; first checkbox row, and OK/Cancel
SH_BDLG_ROWH   equ 18                ; both measured from the SAME origin
SH_BDLG_NITEMS equ 6

SH_BDLG_B_OUTLINE equ 0x01           ; the dialog's own 6-bit UI state -
SH_BDLG_B_LEFT    equ 0x02           ; bits 1-4 line up with SH_BORD_LEFT..
SH_BDLG_B_RIGHT   equ 0x04           ; SH_BORD_BOTTOM shifted up by one (to
SH_BDLG_B_TOP     equ 0x08           ; make room for Outline at bit 0) and
SH_BDLG_B_BOTTOM  equ 0x10           ; bit 5 lines up with SH_BORD_SHADE the
SH_BDLG_B_SHADE   equ 0x20           ; same way - see sh_bdlg_open/_apply

sh_bdlg_tpl:
    dw 0, 0, SH_BDLG_W, SH_BDLG_H
    dw sh_s_bdlg_title, sh_bdlg_paint, 0, sh_bdlg_onclick

sh_s_bdlg_title: db 'Border', 0
sh_bdlg_items: dw sh_bdlg_i0, sh_bdlg_i1, sh_bdlg_i2, sh_bdlg_i3, sh_bdlg_i4, sh_bdlg_i5
sh_bdlg_i0:    db 'Outline', 0
sh_bdlg_i1:    db 'Left', 0
sh_bdlg_i2:    db 'Right', 0
sh_bdlg_i3:    db 'Top', 0
sh_bdlg_i4:    db 'Bottom', 0
sh_bdlg_i5:    db 'Shade', 0

; -----------------------------------------------------------------------------
; sh_bdlg_open - preselect from the selected cell's stored border byte
; (sh_bt_get); a cell with no border record at all reads back as 0, same
; "dialog still opens, OK on it is just a no-op" scope as sh_fdlg_open's.
; -----------------------------------------------------------------------------
sh_bdlg_open:
    push ax
    push bx
    push si
    cmp word [sh_bdlg_win], 0
    jne .out
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_bt_get                     ; al = stored border byte
    mov ah, al
    and ah, 0x1F
    mov bl, ah
    shl bl, 1                          ; bl = sel bits 1-5 (L,R,T,Bot,Shade)
    and ah, SH_BORD_EDGES
    cmp ah, SH_BORD_EDGES
    jne .noout
    or bl, SH_BDLG_B_OUTLINE
.noout:
    mov [sh_bdlg_sel], bl
    call OSAPI_VIDEO
    sub ax, SH_BDLG_W
    sar ax, 1
    mov [sh_bdlg_tpl + WT_X], ax
    sub bx, SH_BDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8
.placed:
    mov [sh_bdlg_tpl + WT_Y], bx
    mov si, sh_bdlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [sh_bdlg_win], bx
    call OSAPI_WM_SHOW
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_bdlg_paint - SI = the dialog window
; -----------------------------------------------------------------------------
sh_bdlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call OSAPI_WM_CONTENT
    mov [sh_bdlg_ox], ax
    mov [sh_bdlg_oy], dx
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov ax, [sh_bdlg_ox]
    add ax, SH_BDLG_GX1
    mov bx, [sh_bdlg_oy]
    add bx, SH_BDLG_GY1
    mov cx, [sh_bdlg_ox]
    add cx, SH_BDLG_GX2
    mov dx, [sh_bdlg_oy]
    add dx, SH_BDLG_GY2
    call OSAPI_GFX_FRAME                ; the group box itself
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [sh_bdlg_ox]
    add ax, SH_BDLG_GX1 + 6
    mov bx, [sh_bdlg_oy]
    add bx, SH_BDLG_GY1 - 3
    mov cx, ax
    add cx, 40
    mov dx, bx
    add dx, 7
    call OSAPI_GFX_FILL                 ; erase the frame line behind the
                                         ; label, so it "breaks" the box top
                                         ; the way a real GUI group box does
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov cx, [sh_bdlg_ox]
    add cx, SH_BDLG_GX1 + 8
    mov dx, [sh_bdlg_oy]
    add dx, SH_BDLG_GY1 - 4
    mov si, sh_s_bdlg_title
    call OSAPI_FONT_STR
    mov word [sh_bdlg_ri], 0
.rowloop:
    mov ax, [sh_bdlg_ri]
    cmp ax, SH_BDLG_NITEMS
    jae .rowsdone
    mov bx, SH_BDLG_ROWH
    mul bx
    add ax, SH_BDLG_ROWTOP
    add ax, [sh_bdlg_oy]
    mov [sh_bdlg_ry], ax
    mov al, OS88UI_GCHECK
    mov bh, 1
    mov cl, byte [sh_bdlg_ri]
    shl bh, cl
    test bh, [sh_bdlg_sel]
    jz .off
    or al, OS88UI_GON
.off:
    mov ah, 0
    mov cx, [sh_bdlg_ox]
    add cx, SH_BDLG_GX1 + 8
    mov dx, [sh_bdlg_ry]
    call os88ui_glyph
    mov bx, [sh_bdlg_ri]
    shl bx, 1
    mov si, [sh_bdlg_items + bx]
    mov cx, [sh_bdlg_ox]
    add cx, SH_BDLG_GX1 + 24
    mov dx, [sh_bdlg_ry]
    add dx, 2
    mov al, CBLACK
    mov ah, CWHITE
    call OSAPI_FONT_RUN
    mov ax, [sh_bdlg_ri]
    inc ax
    mov [sh_bdlg_ri], ax
    jmp .rowloop
.rowsdone:
    mov ax, [sh_bdlg_ox]
    add ax, SH_BDLG_GX2 + 10
    mov [sh_bdlg_rect], ax
    mov ax, [sh_bdlg_oy]
    add ax, 20
    mov [sh_bdlg_rect+2], ax
    mov ax, [sh_bdlg_ox]
    add ax, SH_BDLG_W - 10
    mov [sh_bdlg_rect+4], ax
    mov ax, [sh_bdlg_oy]
    add ax, 40
    mov [sh_bdlg_rect+6], ax
    mov bx, sh_bdlg_rect
    mov si, sh_s_fd_ok
    mov di, OS88UI_DEF
    call os88ui_btn
    mov ax, [sh_bdlg_oy]
    add ax, 50
    mov [sh_bdlg_rect+2], ax
    mov ax, [sh_bdlg_oy]
    add ax, 70
    mov [sh_bdlg_rect+6], ax
    mov bx, sh_bdlg_rect
    mov si, sh_s_fd_cancel
    xor di, di
    call os88ui_btn
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_bdlg_onclick - in: CX=x, DX=y (screen-absolute), SI=the dialog window
; -----------------------------------------------------------------------------
sh_bdlg_onclick:
    push ax
    push bx
    push si
    push di
    push cx
    push dx
    mov bx, si
    call OSAPI_WM_CONTENT
    pop bx
    sub bx, dx                          ; bx = click y, content-relative
    pop cx
    sub cx, ax                          ; cx = click x, content-relative
    cmp cx, SH_BDLG_GX2 + 10
    jb .checkrows
    cmp cx, SH_BDLG_W - 10
    ja .checkrows
    cmp bx, 20
    jb .checkrows
    cmp bx, 40
    jle .doOK
    cmp bx, 50
    jb .checkrows
    cmp bx, 70
    jle .doCancel
.checkrows:
    cmp cx, SH_BDLG_GX1 + 8
    jb .out
    cmp bx, SH_BDLG_ROWTOP
    jb .out
    mov ax, bx
    sub ax, SH_BDLG_ROWTOP
    xor dx, dx
    mov si, SH_BDLG_ROWH
    div si
    cmp ax, SH_BDLG_NITEMS
    jae .out
    mov cl, al
    mov bh, 1
    shl bh, cl
    xor [sh_bdlg_sel], bh
    cmp al, 0
    je .wasoutline
    mov al, [sh_bdlg_sel]
    and al, 0x1E
    cmp al, 0x1E
    jne .clroutline
    or byte [sh_bdlg_sel], SH_BDLG_B_OUTLINE
    jmp .redraw
.clroutline:
    and byte [sh_bdlg_sel], ~SH_BDLG_B_OUTLINE & 0xFF
    jmp .redraw
.wasoutline:
    test byte [sh_bdlg_sel], SH_BDLG_B_OUTLINE
    jz .outoff
    or byte [sh_bdlg_sel], 0x1E
    jmp .redraw
.outoff:
    and byte [sh_bdlg_sel], ~0x1E & 0xFF
.redraw:
    mov si, [sh_bdlg_win]
    call sh_bdlg_paint
    jmp .out
.doOK:
    call sh_bdlg_apply
    call sh_bdlg_close
    jmp .out
.doCancel:
    call sh_bdlg_close
.out:
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_bdlg_apply - write sh_bdlg_sel's edges/shade (bits 1-5) into the
; border table: a record if any bit is set, no record (removed if one
; existed) if the cell ends up with no border at all.
; -----------------------------------------------------------------------------
sh_bdlg_apply:
    push ax
    push bx
    push dx
    mov al, [sh_bdlg_sel]
    shr al, 1
    and al, 0x1F
    mov dl, al
    or dl, dl
    jz .clearit
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_bt_addcell
    jc .out                             ; table full: silent no-op, same
                                         ; scope limit as the main array's
    push es
    mov es, [sh_bordseg]
    mov [es:di+4], dl
    pop es
    jmp .out
.clearit:
    mov ax, [sh_selcol]
    mov bx, [sh_selrow]
    call sh_bt_removecell
.out:
    mov si, [sh_ownwin]
    call sh_repaint
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_bdlg_close
; -----------------------------------------------------------------------------
sh_bdlg_close:
    push ax
    push bx
    mov bx, [sh_bdlg_win]
    or bx, bx
    jz .out
    mov word [sh_bdlg_win], 0
    call OSAPI_WM_DESTROY               ; see sh_fdlg_close on why not CLOSE
.out:
    pop bx
    pop ax
    ret

; =============================================================================
; The ONE-LINE INPUT DIALOG (stage 3.0c) - a prompt, an os88line field, OK and
; Cancel. Four menu items want exactly this and differ only in their prompt and
; in what OK does with the string, so it is written once with a KIND byte and
; a dispatch on it, the same way sh_fdlg_* already serves five radio-list
; kinds rather than being copied five times.
;
; This is what the text widget was for. Row Height... and Column Width... have
; been a THREE-PRESET RADIO PICK since stage 1.8 purely because no free-text
; entry existed at the app level - sh_m_format's own comment says so. They are
; now real numeric entry, which is what Excel 2.1d has.
; =============================================================================
SH_ID_GOTO   equ 0                   ; Formula > Goto...
SH_ID_ROWH   equ 1                   ; Format > Row Height...
SH_ID_COLW   equ 2                   ; Format > Column Width...
SH_ID_NKIND  equ 3

SH_IDLG_W    equ 268
SH_IDLG_H    equ 104
SH_IDLG_FX1  equ 8                   ; the field, content-relative
SH_IDLG_FY1  equ 28
SH_IDLG_FX2  equ 176
SH_IDLG_FY2  equ 46
SH_IDLG_BTX1 equ 186                 ; OK / Cancel, 64 wide - 'Cancel' needs
SH_IDLG_BTX2 equ 250                 ; 6 glyphs at the fixed 8px cell
SH_IDLG_OKY1 equ 26
SH_IDLG_OKY2 equ 46
SH_IDLG_CAY1 equ 54
SH_IDLG_CAY2 equ 74

sh_idlg_tpl:
    dw 0, 0, SH_IDLG_W, SH_IDLG_H
    dw sh_s_id_tgoto, sh_idlg_paint, sh_idlg_onkey, sh_idlg_onclick
; The title above is only a PLACEHOLDER: sh_idlg_open overwrites
; [sh_idlg_tpl + WT_TITLE] with whichever of sh_s_id_t* the kind names, before
; OSAPI_WM_CREATE. WT_TITLE is a pointer TO the text, so the pointer has to go
; into the template itself - putting it in a cell and pointing the template at
; that cell makes the kernel letter the pointer's own two bytes and then run on
; into whatever follows, which is exactly what it did.
sh_id_titles:  dw sh_s_id_tgoto, sh_s_id_trowh, sh_s_id_tcolw
sh_id_prompts: dw sh_s_id_pgoto, sh_s_id_prowh, sh_s_id_pcolw
sh_s_id_tgoto: db 'Goto', 0
sh_s_id_trowh: db 'Row Height', 0
sh_s_id_tcolw: db 'Column Width', 0
sh_s_id_pgoto: db 'Reference:', 0
sh_s_id_prowh: db 'Row height:', 0
sh_s_id_pcolw: db 'Column width:', 0
sh_s_idlg_ok:  db 'OK', 0
sh_s_idlg_can: db 'Cancel', 0

; -----------------------------------------------------------------------------
; sh_idlg_open - in: AL = SH_ID_*. Preloads the field with the CURRENT value
; (the selection's reference, or the live row height / column width) so the
; dialog opens showing what it is about to change, and Enter alone is a no-op
; rather than a surprise.
; -----------------------------------------------------------------------------
sh_idlg_open:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    cmp word [sh_idlg_win], 0
    jne .out
    cmp al, SH_ID_NKIND
    jae .out
    mov [sh_idlg_kind], al
    xor ah, ah
    mov bx, ax
    shl bx, 1                          ; word index into the two tables
    mov ax, [sh_id_titles + bx]
    mov [sh_idlg_tpl + WT_TITLE], ax
    mov byte [sh_idlg_buf], 0
    cmp byte [sh_idlg_kind], SH_ID_GOTO
    je .pregoto
    cmp byte [sh_idlg_kind], SH_ID_ROWH
    je .prerowh
    mov ax, [sh_cellch]                ; characters, matching what OK reads
    jmp .prenum
.prerowh:
    mov ax, [sh_cellh]
.prenum:
    call sh_itoa
    mov di, sh_idlg_buf
    mov si, sh_numbuf
    call sh_strcpy_to_di
    jmp .haveinit
.pregoto:
    mov di, sh_idlg_buf                ; the selection, as 'A1'
    mov ax, [sh_selcol]
    call sh_colname
    mov si, sh_colbuf
    call sh_strcpy_to_di
    mov ax, [sh_selrow]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_strcpy_to_di
.haveinit:
    mov si, sh_idlg_line
    mov word [si + LN_BUF], sh_idlg_buf
    mov word [si + LN_MAX], SH_EDITMAX
    mov byte [si + LN_FOCUS], 1
    mov di, sh_idlg_buf
    call os88line_set                  ; sets LEN/CAR/VIEW from the content
    call OSAPI_VIDEO
    sub ax, SH_IDLG_W
    sar ax, 1
    mov [sh_idlg_tpl + WT_X], ax
    sub bx, SH_IDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8
.placed:
    mov [sh_idlg_tpl + WT_Y], bx
    mov si, sh_idlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [sh_idlg_win], bx
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
; sh_idlg_paint - SI = the dialog window
; -----------------------------------------------------------------------------
sh_idlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call OSAPI_WM_CONTENT
    mov [sh_idlg_ox], ax
    mov [sh_idlg_oy], dx
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov bl, [sh_idlg_kind]             ; the prompt for this kind
    xor bh, bh
    shl bx, 1
    mov si, [sh_id_prompts + bx]
    mov cx, [sh_idlg_ox]
    add cx, SH_IDLG_FX1
    mov dx, [sh_idlg_oy]
    add dx, 8
    call OSAPI_FONT_STR

    mov si, sh_idlg_line               ; the field's rect from the LIVE origin
    mov ax, [sh_idlg_ox]               ; every paint - the window moves
    add ax, SH_IDLG_FX1
    mov [si + LN_X1], ax
    mov ax, [sh_idlg_ox]
    add ax, SH_IDLG_FX2
    mov [si + LN_X2], ax
    mov ax, [sh_idlg_oy]
    add ax, SH_IDLG_FY1
    mov [si + LN_Y1], ax
    mov ax, [sh_idlg_oy]
    add ax, SH_IDLG_FY2
    mov [si + LN_Y2], ax
    call os88line_draw

    mov ax, [sh_idlg_ox]               ; OK
    add ax, SH_IDLG_BTX1
    mov [sh_idlg_rect], ax
    mov ax, [sh_idlg_oy]
    add ax, SH_IDLG_OKY1
    mov [sh_idlg_rect+2], ax
    mov ax, [sh_idlg_ox]
    add ax, SH_IDLG_BTX2
    mov [sh_idlg_rect+4], ax
    mov ax, [sh_idlg_oy]
    add ax, SH_IDLG_OKY2
    mov [sh_idlg_rect+6], ax
    mov bx, sh_idlg_rect
    mov si, sh_s_idlg_ok
    mov di, OS88UI_DEF
    call os88ui_btn
    mov ax, [sh_idlg_oy]               ; Cancel - same x, two new y's
    add ax, SH_IDLG_CAY1
    mov [sh_idlg_rect+2], ax
    mov ax, [sh_idlg_oy]
    add ax, SH_IDLG_CAY2
    mov [sh_idlg_rect+6], ax
    mov bx, sh_idlg_rect
    mov si, sh_s_idlg_can
    xor di, di
    call os88ui_btn

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_idlg_onkey - Enter is OK and Escape is Cancel, which is what a one-field
; dialog should do; os88line_key deliberately does NOT consume Enter (its own
; header says so) precisely so the caller can use it for this.
; -----------------------------------------------------------------------------
sh_idlg_onkey:
    push ax
    push si
    cmp al, 27
    je .cancel
    cmp al, 0x0D
    je .accept
    mov si, sh_idlg_line
    call os88line_key
    jc .out
    mov si, [sh_idlg_win]
    call sh_idlg_paint
    jmp .out
.accept:
    call sh_idlg_apply
    call sh_idlg_close
    jmp .out
.cancel:
    call sh_idlg_close
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_idlg_onclick - CX,DX = the click, screen-absolute
; -----------------------------------------------------------------------------
sh_idlg_onclick:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, sh_idlg_line               ; the field's rect is already
    call os88line_click                ; screen-absolute from the last paint
    jnc .redraw
    mov bx, [sh_idlg_win]
    push cx
    push dx
    call OSAPI_WM_CONTENT
    pop dx
    pop cx
    sub cx, ax
    sub dx, [sh_idlg_oy]
    cmp cx, SH_IDLG_BTX1
    jb .out
    cmp cx, SH_IDLG_BTX2
    ja .out
    cmp dx, SH_IDLG_OKY1
    jb .out
    cmp dx, SH_IDLG_OKY2
    jle .doOK
    cmp dx, SH_IDLG_CAY1
    jb .out
    cmp dx, SH_IDLG_CAY2
    jle .doCancel
    jmp .out
.redraw:
    mov si, [sh_idlg_win]
    call sh_idlg_paint
    jmp .out
.doOK:
    call sh_idlg_apply
    call sh_idlg_close
    jmp .out
.doCancel:
    call sh_idlg_close
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_idlg_apply - dispatch on the kind. A value this cannot make sense of is
; REFUSED SILENTLY and the old one kept, rather than being coerced to zero:
; a column of width 0 is invisible and a Goto to a reference that does not
; parse has nowhere to go, so doing nothing is the honest answer.
; -----------------------------------------------------------------------------
sh_idlg_apply:
    push ax
    push bx
    push cx
    push dx
    push si
    cmp byte [sh_idlg_kind], SH_ID_GOTO
    je .goto
    mov si, sh_idlg_buf                ; the two numeric kinds
    call sh_pnum_at
    jc .out                            ; not a number at all
    cmp byte [sh_idlg_kind], SH_ID_ROWH
    je .rowh
    cmp ax, SH_CW_MINCH                ; COLUMN WIDTH IS IN CHARACTERS, which
    jb .out                            ; is Excel's own unit for it - the
    cmp ax, SH_CW_MAXCH                ; pixel width is a consequence, not the
    ja .out                            ; thing the user types
    mov [sh_cellch], ax
    mov cl, 3
    shl ax, cl
    mov [sh_cellw], ax
    call sh_mkblank                    ; the blank-cell fill string is sized
    jmp .redraw                        ; from the width, so it must follow it
.rowh:
    cmp ax, SH_RH_MIN
    jb .out
    cmp ax, SH_RH_MAX
    ja .out
    mov [sh_cellh], ax
    jmp .redraw
.goto:
    mov si, sh_idlg_buf
    call sh_upcase_at                  ; 'a1' and 'A1' both work, as in Excel
    mov si, sh_idlg_buf
    call sh_pcellref                   ; CF=1 = AX col, BX row
    jnc .out
    cmp ax, SH_COLS
    jae .out
    cmp bx, SH_ROWS
    jae .out
    mov si, [sh_ownwin]                ; sh_select's own contract: SI must be
    call sh_select                     ; the window and it leaves it alone so
    call sh_scrollto                   ; sh_repaint below still has it
.redraw:
    call sh_geom                       ; the cell size may have changed, so the
    mov si, [sh_ownwin]                ; visible row/column counts must be
    call sh_repaint                    ; recomputed before anything is drawn
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_idlg_close
; -----------------------------------------------------------------------------
sh_idlg_close:
    push ax
    push bx
    mov bx, [sh_idlg_win]
    or bx, bx
    jz .out
    mov word [sh_idlg_win], 0
    call OSAPI_WM_DESTROY               ; see sh_fdlg_close on why not CLOSE
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_upcase_at - uppercase the NUL string at SI in place. Preserves all.
; -----------------------------------------------------------------------------
sh_upcase_at:
    push ax
    push si
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, 'a'
    jb .next
    cmp al, 'z'
    ja .next
    sub al, 32
    mov [si], al
.next:
    inc si
    jmp .loop
.done:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_pnum_at - read an unsigned decimal from the NUL string at SI.
; out: CF=0 and AX = the value; CF=1 if there was no digit at all or it ran
; past 65535. Leading blanks are skipped; anything after the digits is
; ignored, so '12 wide' reads as 12.
; -----------------------------------------------------------------------------
sh_pnum_at:
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
; Formula > Note... (stage 3.0b) - Excel 2.1's cell notes, and the FIRST
; consumer of apps/os88text.inc. Everything above this point that takes typed
; input takes it one character at a time into a fixed field; this is the first
; place in Sheet where a user can type a paragraph.
;
; It edits sh_notetext, a bss COPY, and only writes through to the note table
; on OK - so Cancel is free and a commit refused for want of arena space leaves
; the old note exactly as it was, rather than half-replacing it.
;
; It also remembers the cell it was opened on (sh_notecol/sh_noterow) instead
; of reading the live selection at OK time. This dialog is NON-MODAL like every
; other one here, so the user can move the selection while it is open; writing
; to whatever happens to be selected on OK would attach the note to the wrong
; cell, which is exactly the kind of quiet wrongness that is hard to notice.
; =============================================================================
SH_NDLG_W    equ 300
SH_NDLG_H    equ 138
SH_NDLG_BX1  equ 8                   ; the text box, content-relative
SH_NDLG_BY1  equ 24
SH_NDLG_BX2  equ 214
SH_NDLG_BY2  equ 112                 ; -> 24 columns x 10 rows = 240 cells,
                                     ; which is what SH_NOTEMAX is sized from
SH_NDLG_BTX1 equ 222                 ; OK / Cancel, both 64 wide -
                                     ; 'Cancel' is 6 glyphs at the fixed 8px
                                     ; cell, so a narrower button clips its
                                     ; own label (it did, at 34)
SH_NDLG_BTX2 equ 286
SH_NDLG_OKY1 equ 24
SH_NDLG_OKY2 equ 44
SH_NDLG_CAY1 equ 52
SH_NDLG_CAY2 equ 72

sh_ndlg_tpl:
    dw 0, 0, SH_NDLG_W, SH_NDLG_H
    dw sh_s_ndlg_title, sh_ndlg_paint, sh_ndlg_onkey, sh_ndlg_onclick

sh_s_ndlg_title: db 'Note', 0
sh_s_ndlg_cell:  db 'Cell:', 0
sh_s_ndlg_ok:    db 'OK', 0
sh_s_ndlg_can:   db 'Cancel', 0

; -----------------------------------------------------------------------------
; sh_ndlg_open - load the selected cell's note into the edit buffer and put
; the dialog up. Same single-instance gate as sh_bdlg_open.
; -----------------------------------------------------------------------------
sh_ndlg_open:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    cmp byte [sh_noteopen], 0
    jne .out
    mov ax, [sh_selcol]                ; pin the cell NOW - see this section's
    mov [sh_notecol], ax               ; header on why not at OK time
    mov bx, [sh_selrow]
    mov [sh_noterow], bx
    mov byte [sh_notetext], 0          ; no note = an empty box, not stale text
    call sh_nt_get
    jnc .nonote
    mov si, ax                         ; ax = the text's offset in the arena
    call sh_note_load
.nonote:
    mov si, sh_notebox                 ; the field, over the buffer
    mov word [si + TX_BUF], sh_notetext
    mov word [si + TX_MAX], SH_NOTEMAX
    mov word [si + TX_TOP], 0
    mov byte [si + TX_FOCUS], 1
    mov di, sh_notetext
    call os88text_set                  ; sets LEN/CAR from the buffer's content
    call OSAPI_VIDEO
    sub ax, SH_NDLG_W
    sar ax, 1
    mov [sh_ndlg_tpl + WT_X], ax
    sub bx, SH_NDLG_H
    sar bx, 1
    cmp bx, MBAR_H + 8
    jge .placed
    mov bx, MBAR_H + 8
.placed:
    mov [sh_ndlg_tpl + WT_Y], bx
    mov si, sh_ndlg_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [sh_ndlg_win], bx
    mov byte [sh_noteopen], 1
    call OSAPI_WM_SHOW
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
; sh_note_load - copy the NUL string at [sh_txtseg]:SI into sh_notetext,
; clipped to SH_NOTEMAX-1. in: SI = the arena offset. Preserves everything.
;
; A byte-at-a-time copy through ES rather than a rep movsb, so DS is never
; changed at all - the alternative wants DS pointing at the claim, and every
; sh_* symbol in this file is DS-relative.
; -----------------------------------------------------------------------------
sh_note_load:
    push ax
    push cx
    push si
    push di
    push es
    mov es, [sh_txtseg]
    mov di, sh_notetext
    mov cx, SH_NOTEMAX - 1
.copy:
    jcxz .done
    mov al, [es:si]
    or al, al
    jz .done
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .copy
.done:
    mov byte [di], 0
    pop es
    pop di
    pop si
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_ndlg_paint - SI = the dialog window
; -----------------------------------------------------------------------------
sh_ndlg_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call OSAPI_WM_CONTENT               ; ax,dx = the content origin
    mov [sh_ndlg_ox], ax
    mov [sh_ndlg_oy], dx

    mov cx, ax                          ; the 'Cell:' label and the reference
    add cx, SH_NDLG_BX1
    mov dx, [sh_ndlg_oy]
    add dx, 6
    mov al, CBLACK
    call OSAPI_SET_COLOR
    mov si, sh_s_ndlg_cell
    call OSAPI_FONT_STR
    mov di, sh_tbuf                     ; the reference, built the same way the
    mov ax, [sh_notecol]                ; formula bar's own name box builds it
    call sh_colname
    mov si, sh_colbuf
    call sh_strcpy_to_di
    mov ax, [sh_noterow]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_strcpy_to_di
    mov cx, [sh_ndlg_ox]
    add cx, SH_NDLG_BX1 + 48
    mov dx, [sh_ndlg_oy]
    add dx, 6
    mov si, sh_tbuf
    call OSAPI_FONT_STR

    mov si, sh_notebox                  ; the field's rect is refreshed from
    mov ax, [sh_ndlg_ox]                ; the LIVE content origin every paint,
    add ax, SH_NDLG_BX1                 ; because the window moves - the same
    mov [si + TX_X1], ax                ; painter/hit-tester drift the scroll
    mov ax, [sh_ndlg_ox]                ; bars already had to solve
    add ax, SH_NDLG_BX2
    mov [si + TX_X2], ax
    mov ax, [sh_ndlg_oy]
    add ax, SH_NDLG_BY1
    mov [si + TX_Y1], ax
    mov ax, [sh_ndlg_oy]
    add ax, SH_NDLG_BY2
    mov [si + TX_Y2], ax
    call os88text_draw

    mov ax, [sh_ndlg_ox]                ; OK - os88ui_btn takes BX = a POINTER
    add ax, SH_NDLG_BTX1                ; to the rect, not the rect in
    mov [sh_ndlg_rect], ax              ; AX/BX/CX/DX
    mov ax, [sh_ndlg_oy]
    add ax, SH_NDLG_OKY1
    mov [sh_ndlg_rect+2], ax
    mov ax, [sh_ndlg_ox]
    add ax, SH_NDLG_BTX2
    mov [sh_ndlg_rect+4], ax
    mov ax, [sh_ndlg_oy]
    add ax, SH_NDLG_OKY2
    mov [sh_ndlg_rect+6], ax
    mov bx, sh_ndlg_rect
    mov si, sh_s_ndlg_ok
    mov di, OS88UI_DEF
    call os88ui_btn
    mov ax, [sh_ndlg_oy]                ; Cancel - same x, two new y's
    add ax, SH_NDLG_CAY1
    mov [sh_ndlg_rect+2], ax
    mov ax, [sh_ndlg_oy]
    add ax, SH_NDLG_CAY2
    mov [sh_ndlg_rect+6], ax
    mov bx, sh_ndlg_rect
    mov si, sh_s_ndlg_can
    xor di, di
    call os88ui_btn

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_ndlg_onkey - AL = ascii, AH = scan code. The field gets first refusal;
; Escape is the only key this dialog claims for itself.
; -----------------------------------------------------------------------------
sh_ndlg_onkey:
    push ax
    push si
    cmp al, 27
    je .cancel
    mov si, sh_notebox
    call os88text_key
    jc .out                             ; the field did not want it
    mov si, [sh_ndlg_win]
    call sh_ndlg_paint
    jmp .out
.cancel:
    call sh_ndlg_close
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_ndlg_onclick - CX,DX = the click, screen-absolute
; -----------------------------------------------------------------------------
sh_ndlg_onclick:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, sh_notebox                  ; the field first: its own rect is
    call os88text_click                 ; already screen-absolute from the
    jnc .redraw                         ; last paint, so no conversion here
    mov bx, [sh_ndlg_win]
    push cx
    push dx
    call OSAPI_WM_CONTENT
    pop dx
    pop cx
    sub cx, ax                          ; cx,dx = content-relative
    sub dx, [sh_ndlg_oy]
    cmp cx, SH_NDLG_BTX1
    jb .out
    cmp cx, SH_NDLG_BTX2
    ja .out
    cmp dx, SH_NDLG_OKY1
    jb .out
    cmp dx, SH_NDLG_OKY2
    jle .doOK
    cmp dx, SH_NDLG_CAY1
    jb .out
    cmp dx, SH_NDLG_CAY2
    jle .doCancel
    jmp .out
.redraw:
    mov si, [sh_ndlg_win]
    call sh_ndlg_paint
    jmp .out
.doOK:
    call sh_ndlg_apply
    call sh_ndlg_close
    jmp .out
.doCancel:
    call sh_ndlg_close
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_ndlg_apply - commit the edit buffer to the cell the dialog was opened on.
; An empty buffer removes the note (sh_nt_set's own rule), which is how this
; dialog clears one - Excel 2.1's Note dialog has no separate Delete either.
; -----------------------------------------------------------------------------
sh_ndlg_apply:
    push ax
    push bx
    push si
    mov ax, [sh_notecol]
    mov bx, [sh_noterow]
    mov si, sh_notetext
    call sh_nt_set                      ; CF=1 = table or arena full. Silent,
                                        ; the same scope limit sh_bdlg_apply
                                        ; documents for a full border table.
    mov si, [sh_ownwin]
    call sh_repaint
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_ndlg_close
; -----------------------------------------------------------------------------
sh_ndlg_close:
    push ax
    push bx
    mov bx, [sh_ndlg_win]
    or bx, bx
    jz .out
    mov word [sh_ndlg_win], 0
    mov byte [sh_noteopen], 0
    call OSAPI_WM_DESTROY               ; see sh_fdlg_close on why not CLOSE
.out:
    pop bx
    pop ax
    ret

sh_dlg:
    push bx
    push si
    push di
    mov bx, si
    mov di, sh_ondlg
    mov si, sh_name
    call OSAPI_FILE_DLG
    pop di
    pop si
    pop bx
    ret

; -----------------------------------------------------------------------------
; sh_ondlg - the file dialog's completion proc (SPEC.md 38.6)
; in:  AL=mode, SI=our window ptr, DI=chosen name (ES=KERNEL_SEG); UI task,
;      gfx lock HELD, dialog already destroyed - we owe the repaint
; -----------------------------------------------------------------------------
sh_ondlg:
    push ax
    push bx
    push cx
    push si
    push di
    mov bl, al
    mov cx, si                       ; CX = our window ptr (SI about to move)
    mov si, di
    mov di, sh_name
    mov ax, SH_NAMEMAX
.copy:
    mov al, [es:si]
    mov [di], al
    or al, al
    jz .copied
    inc si
    inc di
    dec ax
    jnz .copy
    mov byte [di], 0
.copied:
    mov si, cx                       ; SI = our window again
    or bl, bl
    jz .load
    call sh_dowrite
    jmp short .draw
.load:
    call sh_doread
.draw:
    call sh_repaint
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_new - File > New: clear the sheet and the name, reselect A1
; -----------------------------------------------------------------------------
sh_new:
    push ax
    push cx
    push dx
    push si
    push di
    mov dx, si                       ; DX = window ptr, stashed
    mov si, sh_defname
    mov di, sh_name
    call sh_strcpy
    mov si, dx                       ; SI = window ptr, restored
    mov word [sh_ncells], 0
    mov word [sh_txtlen], 0
    mov word [sh_cursheet], 0
    mov cx, SH_SHEETS * 4            ; 4 words per sheet: sel/row/scl/scr
    mov di, sh_selsave
    xor ax, ax
.clrsave:
    mov [di], ax
    add di, 2
    loop .clrsave
    mov word [sh_selcol], 0
    mov word [sh_selrow], 0
    mov word [sh_scrollcol], 0
    mov word [sh_scrollrow], 0
    mov byte [sh_editing], 0
    mov word [sh_msg], 0
    call sh_repaint
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_switchsheet - in: AX = target sheet index (0..SH_SHEETS-1); saves the
; outgoing sheet's selection/scroll into its slot and restores the
; incoming sheet's own (all-zero the first time it's ever visited)
; -----------------------------------------------------------------------------
sh_switchsheet:
    push ax
    push bx
    push cx
    mov cx, ax                       ; cx = target sheet, preserved across
                                      ; the save step below
    cmp cx, [sh_cursheet]
    je .out
    mov bx, [sh_cursheet]
    shl bx, 1
    mov ax, [sh_selcol]
    mov [sh_selsave+bx], ax
    mov ax, [sh_selrow]
    mov [sh_rowsave+bx], ax
    mov ax, [sh_scrollcol]
    mov [sh_sclsave+bx], ax
    mov ax, [sh_scrollrow]
    mov [sh_scrsave+bx], ax
    mov [sh_cursheet], cx
    mov bx, cx
    shl bx, 1
    mov ax, [sh_selsave+bx]
    mov [sh_selcol], ax
    mov ax, [sh_rowsave+bx]
    mov [sh_selrow], ax
    mov ax, [sh_sclsave+bx]
    mov [sh_scrollcol], ax
    mov ax, [sh_scrsave+bx]
    mov [sh_scrollrow], ax
    call sh_repaint
.out:
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; File I/O: SYLK write and read, over the sparse array directly
; =============================================================================

; -----------------------------------------------------------------------------
; sh_dowrite - write the sheet to [sh_name], format chosen by its extension
; (SPEC-free scope decision, this project's own: ".DIF" writes DIF,
; everything else writes SYLK, matching stage 1.0's default).
; -----------------------------------------------------------------------------
sh_dowrite:
    push si
    push di
    mov si, sh_name
    mov di, sh_s_ext_dif
    call sh_nameends
    pop di
    pop si
    jc .dif
    push si
    push di
    mov si, sh_name
    mov di, sh_s_ext_biff
    call sh_nameends
    pop di
    pop si
    jc .biff
    jmp sh_dowrite_sylk
.dif:
    jmp sh_dowrite_dif
.biff:
    jmp sh_dowrite_biff

; -----------------------------------------------------------------------------
; sh_dowrite_sylk - write the sheet to [sh_name] as SYLK. Walks the sorted
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
sh_dowrite_sylk:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [sh_stgseg]
    xor di, di
    mov si, sh_s_id
    call sh_stgput

    mov byte [sh_trunc], 0
    mov word [sh_wrow], 0            ; reused here as the record index
.rec:
    mov bx, [sh_wrow]
    cmp bx, [sh_ncells]
    jae .footer
    cmp byte [sh_trunc], 0
    jne .footer
    mov ax, di
    add ax, 56                       ; worst case a C line ("C;X256;Y16384;
                                      ; K-32768\r\n") plus its F line
                                      ; ("F;X256;Y16384;F$0R;K\r\n")
    cmp ax, SH_STAGE_MAX
    jbe .room
    mov byte [sh_trunc], 1
    jmp .footer
.room:
    mov ax, bx
    mov cx, SH_C_SZ
    mul cx
    mov si, ax                        ; SI = this record's offset in cellseg
    push es
    mov es, [sh_cellseg]
    mov ax, [es:si]
    call sh_unpackrow                 ; -> ax=real row, bx=this record's
                                       ; sheet (see the stage 2.0 comment
                                       ; above the cell record layout)
    cmp bx, [sh_cursheet]
    jne .recskip                      ; a save only ever writes the CURRENT
                                       ; sheet - the array may hold other
                                       ; sheets' records too, interleaved
    mov [sh_wrec_row], ax
    mov ax, [es:si+2]
    mov [sh_wrec_col], ax
    mov word [sh_wrec_foff], 0xFFFF   ; ...and this cell's formula, if it has
    test byte [es:si+4], 1            ; one: SYLK carries the EXPRESSION in a
    jz .noformula_w                   ; ;E field beside the cached ;K value,
    mov ax, [es:si+SH_C_FOFF]         ; which is what makes a saved sheet a
    mov [sh_wrec_foff], ax            ; spreadsheet rather than a table of
.noformula_w:                         ; numbers
    call sh_cellval_to_acc_si         ; bank the whole value: the row and
    push si                           ; column are formatted through sh_numbuf
    push di                           ; before it is wanted, so it cannot be
    mov si, sh_acc                    ; turned into text here
    mov di, sh_wrec_dval
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
    mov ax, [es:si+SH_C_VAL]
    mov [sh_wrec_val], ax
    mov al, [es:si+5]
    mov [sh_wrec_fmt], al
    pop es                            ; ES = stgseg again

    mov si, sh_s_c
    call sh_stgput
    mov ax, [sh_wrec_col]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_stgput
    mov si, sh_s_y
    call sh_stgput
    mov ax, [sh_wrec_row]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_stgput
    cmp word [sh_wrec_foff], 0xFFFF   ; ";E<expr>" comes BEFORE ";K", the
    je .noexpr                        ; order a real file from the period uses
    push si
    push di
    mov ax, [sh_wrec_col]             ; every relative offset is measured from
    mov [sh_rc_ccol], ax              ; the cell being written
    mov ax, [sh_wrec_row]
    mov [sh_rc_crow], ax
    push es
    mov es, [sh_txtseg]               ; copy the formula text out of the arena
    mov si, [sh_wrec_foff]            ; into DS, where the converter reads
    mov di, sh_rwsrc
    mov cx, SH_EDITMAX
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
    mov si, sh_rwsrc
    call sh_formula_to_r1c1
    pop di
    pop si
    mov si, sh_s_e
    call sh_stgput
    mov si, sh_rwdst
    call sh_stgput
.noexpr:
    mov si, sh_s_k
    call sh_stgput
    push si                           ; SYLK's K field IS a decimal literal,
    push di                           ; so the full value goes out, not a
    mov si, sh_wrec_dval              ; truncation of it
    call fp_unpack_a
    mov di, sh_numbuf
    mov ax, 10
    call fp_ftoa
    pop di
    pop si
    mov si, sh_numbuf
    call sh_stgput
    mov si, sh_s_crlf
    call sh_stgput

    mov al, [sh_wrec_fmt]
    and al, (SH_FMT_ALIGN_MASK | SH_FMT_NUM_MASK)
    jz .noformat                      ; bold/underline alone don't get an F
                                       ; record - real SYLK has no code for
                                       ; either, see sh_parsefrec's comment
    mov si, sh_s_sylk_fx               ; "F;X"
    call sh_stgput
    mov ax, [sh_wrec_col]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_stgput
    mov si, sh_s_y
    call sh_stgput
    mov ax, [sh_wrec_row]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_stgput
    mov si, sh_s_sylk_ff                ; ";F"
    call sh_stgput
    mov bl, [sh_wrec_fmt]
    and bl, SH_FMT_NUM_MASK
    mov cl, SH_FMT_NUM_SHIFT
    shr bl, cl
    mov al, '$'
    cmp bl, SH_FMT_NUM_CURRENCY
    je .c1ok
    mov al, 'G'
.c1ok:
    call sh_stgputb                      ; c1
    mov al, '0'
    call sh_stgputb                      ; n (digit count - always 0, this
                                         ; app's values are whole numbers)
    mov al, [sh_wrec_fmt]
    and al, SH_FMT_ALIGN_MASK
    mov cl, SH_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, SH_FMT_ALIGN_LEFT
    je .c2l
    cmp al, SH_FMT_ALIGN_CENTER
    je .c2c
    cmp al, SH_FMT_ALIGN_RIGHT
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
    call sh_stgputb                      ; c2
    cmp bl, SH_FMT_NUM_COMMA
    jne .nok
    mov si, sh_s_k
    call sh_stgput                      ; ";K"
.nok:
    mov si, sh_s_crlf
    call sh_stgput
.noformat:
    jmp .recnext
.recskip:
    pop es
.recnext:
    mov ax, [sh_wrow]
    inc ax
    mov [sh_wrow], ax
    jmp .rec
.footer:
    mov si, sh_s_end
    call sh_stgput
    mov [sh_stagelen], di

    mov ax, [sh_stgseg]
    mov es, ax
    xor bx, bx
    mov cx, [sh_stagelen]
    xor dx, dx
    mov si, sh_name
    call OSAPI_FILE_WRITE
    jc .werr
    mov word [sh_msg], sh_m_saved
    jmp .wdone
.werr:
    call sh_setferr
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
; sh_stgput - append DS:SI (NUL-terminated) to ES:DI, advancing DI. ES must
; already be the staging segment (the caller's job); no NUL is written to
; the destination, since the staging buffer is a raw byte stream whose
; total length is tracked separately, not a re-readable C string.
; -----------------------------------------------------------------------------
sh_stgput:
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
; sh_doread - read [sh_name], format chosen by its extension (see sh_dowrite)
; -----------------------------------------------------------------------------
sh_doread:
    push si
    push di
    mov si, sh_name
    mov di, sh_s_ext_dif
    call sh_nameends
    pop di
    pop si
    jc .dif
    push si
    push di
    mov si, sh_name
    mov di, sh_s_ext_biff
    call sh_nameends
    pop di
    pop si
    jc .biff
    jmp sh_doread_sylk
.dif:
    jmp sh_doread_dif
.biff:
    jmp sh_doread_biff

; -----------------------------------------------------------------------------
; sh_doread_sylk - read [sh_name] as SYLK, replacing the sheet
; -----------------------------------------------------------------------------
sh_doread_sylk:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [sh_stgseg]
    xor bx, bx
    mov cx, SH_STAGE_MAX
    xor dx, dx
    mov si, sh_name
    call OSAPI_FILE_READ              ; out: DX:AX = bytes read, or CF=1
    jc .rerr

    mov word [sh_ncells], 0
    mov cx, ax                        ; a file this small never exceeds 64KB
    xor si, si
    call sh_parseslk
    mov word [sh_msg], sh_m_loaded
    jmp .out
.rerr:
    call sh_setferr
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
; write walks the sheet's USED BOUNDING BOX (sh_difbbox), not the full
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
; rule. On read, an indicator other than V (a foreign file's NA, ERROR,
; TRUE, or FALSE) just means "leave this cell blank", the same as this
; app's own concept of empty. Like SYLK, only the cached VALUE is carried -
; a formula's source text is not, and per the user's explicit direction
; this stage does NOT extend DIF with any per-cell formatting: real DIF
; has no such concept (unlike real SYLK, which has actual P/font records -
; see the SYLK section below), so this format only ever carries values.
; =============================================================================

; -----------------------------------------------------------------------------
; sh_nameends - in: SI=name (NUL-terminated), DI=suffix (NUL-terminated);
; out: CF=1 if name ends with suffix (case-sensitive: 8.3 names arrive
; already uppercase from the kernel, and so do the suffixes this file
; compares against)
; -----------------------------------------------------------------------------
sh_nameends:
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
; sh_difbbox - the sheet's used bounding box (0,0)-(sh_bbcol,sh_bbrow),
; both 0 for an empty sheet. sh_bbrow is free (the array is row-sorted, so
; it is just the last record's row); sh_bbcol needs a scan.
; -----------------------------------------------------------------------------
sh_difbbox:
    push ax
    push bx
    push cx
    push si
    push es
    mov word [sh_bbrow], 0
    mov word [sh_bbcol], 0
    cmp word [sh_ncells], 0
    je .out
    mov es, [sh_cellseg]
    xor cx, cx
.scan:
    cmp cx, [sh_ncells]
    jae .out
    mov ax, cx
    mov bx, SH_C_SZ
    mul bx
    mov si, ax                        ; si = this record's byte offset
    mov ax, [es:si]                   ; packed row/sheet (stage 2.0)
    call sh_unpackrow                 ; -> ax=real row, bx=sheet
    cmp bx, [sh_cursheet]
    jne .next                         ; a sheet's records aren't
                                       ; necessarily contiguous from index 0,
                                       ; so this scans every record rather
                                       ; than assuming the last one is ours
    cmp ax, [sh_bbrow]
    jbe .rowok
    mov [sh_bbrow], ax
.rowok:
    mov ax, [es:si+2]                 ; this record's col
    cmp ax, [sh_bbcol]
    jbe .next
    mov [sh_bbcol], ax
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
; sh_dowrite_dif - write the sheet to [sh_name] as DIF
; -----------------------------------------------------------------------------
sh_dowrite_dif:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    call sh_difbbox
    mov es, [sh_stgseg]
    xor di, di
    mov si, sh_s_dif_hdr1
    call sh_stgput
    mov ax, [sh_bbcol]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_stgput
    mov si, sh_s_dif_hdr2
    call sh_stgput
    mov ax, [sh_bbrow]
    inc ax
    call sh_itoa
    mov si, sh_numbuf
    call sh_stgput
    mov si, sh_s_dif_hdr3
    call sh_stgput

    mov word [sh_wrow], 0
.rloop:
    mov ax, [sh_wrow]
    cmp ax, [sh_bbrow]
    ja .footer
    mov ax, di
    add ax, 16
    cmp ax, SH_STAGE_MAX
    ja .footer                        ; truncate - documented, same spirit
                                       ; as the SYLK writer's own room check
    mov si, sh_s_dif_bot
    call sh_stgput
    mov word [sh_wcol], 0
.cloop:
    mov ax, [sh_wcol]
    cmp ax, [sh_bbcol]
    ja .rnext
    mov ax, di
    add ax, 16                        ; worst case "0,-32768\r\nV\r\n"
    cmp ax, SH_STAGE_MAX
    ja .footer
    mov ax, [sh_wcol]
    mov bx, [sh_wrow]
    call sh_getcell2
    jnc .na
    mov si, sh_s_dif_zc
    call sh_stgput
    mov ax, dx
    call sh_itoa
    mov si, sh_numbuf
    call sh_stgput
    mov si, sh_s_crlf
    call sh_stgput
    mov si, sh_s_dif_v
    call sh_stgput
    jmp .cnext
.na:
    mov si, sh_s_dif_na0
    call sh_stgput
.cnext:
    mov ax, [sh_wcol]
    inc ax
    mov [sh_wcol], ax
    jmp .cloop
.rnext:
    mov ax, [sh_wrow]
    inc ax
    mov [sh_wrow], ax
    jmp .rloop
.footer:
    mov si, sh_s_dif_eod
    call sh_stgput
    mov [sh_stagelen], di

    mov ax, [sh_stgseg]
    mov es, ax
    xor bx, bx
    mov cx, [sh_stagelen]
    xor dx, dx
    mov si, sh_name
    call OSAPI_FILE_WRITE
    jc .werr
    mov word [sh_msg], sh_m_saved
    jmp .wdone
.werr:
    call sh_setferr
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
; sh_difskipline - in: ES:SI, DI=end (exclusive); out: SI advanced past the
; next CR/LF run (any mix of the two, so both conventions read correctly)
; -----------------------------------------------------------------------------
sh_difskipline:
    push ax
.scan:
    cmp si, di
    jae .out
    mov al, [es:si]
    inc si
    cmp al, 13
    je .eat
    cmp al, 10
    je .eat
    jmp .scan
.eat:
    cmp si, di
    jae .out
    mov al, [es:si]
    cmp al, 13
    je .eat2
    cmp al, 10
    je .eat2
    jmp .out
.eat2:
    inc si
    jmp .eat
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_doread_dif - read [sh_name] as DIF, replacing the sheet. Skips the
; fixed 12-line header (this project's own writer always emits exactly
; that many), then reads row markers ("-1,0"/"BOT" or the closing "EOD")
; and, within a row, cell records ("0,<value>" or "1,0"/"NA").
; -----------------------------------------------------------------------------
sh_doread_dif:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [sh_stgseg]
    xor bx, bx
    mov cx, SH_STAGE_MAX
    xor dx, dx
    mov si, sh_name
    call OSAPI_FILE_READ               ; out: DX:AX = bytes read, or CF=1
    jc .rerr

    mov word [sh_ncells], 0
    mov es, [sh_stgseg]
    mov di, ax                         ; DI = end (bytes read)
    xor si, si
    mov cx, 12                         ; the header is always 12 lines
.skiphdr:
    call sh_difskipline
    loop .skiphdr
    mov word [sh_wrow], 0xFFFF         ; becomes 0 at the first BOT
.rowloop:
    cmp si, di
    jae .done
    call sh_difskipline                ; the "-1,0" line
    cmp si, di
    jae .done
    mov al, [es:si]
    cmp al, 'E'
    je .done                           ; EOD
    call sh_difskipline                ; the "BOT" line
    mov ax, [sh_wrow]
    inc ax
    mov [sh_wrow], ax
    mov word [sh_wcol], 0
.cellloop:
    cmp si, di
    jae .done
    mov al, [es:si]
    cmp al, '-'
    je .rowloop                        ; the next row's "-1,0"
    cmp al, '0'
    jne .skipunknown                   ; this app never writes anything
                                        ; else here (type 1/STRING, say) -
                                        ; skip defensively rather than
                                        ; misread a foreign file's line
    add si, 2                          ; past "0,"
    mov bx, di
    call sh_pint                       ; -> AX=value, SI past the digits
    mov [sh_wrec_val], ax
    call sh_difskipline                ; finish the "0,<value>" line
    cmp si, di
    jae .cellnext
    cmp byte [es:si], 'V'              ; the real DIF value-indicator: V
    jne .notvalid                      ; (valid) is the only one this app
                                        ; ever writes; NA/ERROR/TRUE/FALSE
                                        ; from a foreign file all just mean
                                        ; "leave this cell blank" here
    mov ax, [sh_wcol]
    mov bx, [sh_wrow]
    mov dx, [sh_wrec_val]
    call sh_setval
.notvalid:
    call sh_difskipline                ; the indicator line
    jmp .cellnext
.skipunknown:
    call sh_difskipline
.cellnext:
    mov ax, [sh_wcol]
    inc ax
    mov [sh_wcol], ax
    jmp .cellloop
.done:
    mov word [sh_msg], sh_m_loaded
    jmp .out
.rerr:
    call sh_setferr
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
; File I/O: BIFF write and read - stage 1.4's "BIFF3/4 support". Frames
; records the real way (BOF/EOF opcodes, a real per-cell record type), but
; the BOF payload's exact byte-level convention beyond the opcode and the
; dt field is genuine best-effort (documented, not certified) - the same
; honesty this project already applies to SYLK/DIF. The one point that IS
; deliberately spec-correct, because it is load-bearing for round-tripping
; negative numbers through a real reader: cell values are written as RK
; records (opcode 0x027E, real BIFF3+), not the older INTEGER record
; (0x0202) - INTEGER's 16-bit value field is UNSIGNED (0..65535 only), so
; it cannot hold this app's negative cells at all, whereas RK's 4-byte
; packed value has a signed-30-bit-integer subtype that fits this app's
; signed 16-bit cells with room to spare and needs no IEEE-754 float
; encoding. On read, only that same subtype is understood - a foreign RK
; using the "multiplied by 100" or plain-float subtype, or a NUMBER
; (0x0203) float record, is out of this subset's scope and is skipped,
; leaving that cell blank, rather than guessed at.
; Like SYLK, this is sparse (one record per occupied cell, walking the
; sorted array directly), not dense like DIF, since a binary record already
; carries its own row/col and needs no bounding box. Like both SYLK and
; DIF, only the cached VALUE survives a round trip - a formula's source
; text is not persisted.
;
; Stage 1.6's bold/underline/alignment/number-format DOES persist here,
; and unlike SYLK/DIF's own invented extensions, this one uses real BIFF3/4
; structure: 4 FONT records (opcode 0x0231) for the 4 bold/underline
; combinations, 64 XF records (opcode 0x0443) - one per possible SH_FMT_*
; byte value - and each cell's RK record points at its XF by index. That
; 1:1 pairing between our format byte and the BIFF ixfe is deliberate: it
; means neither side needs a lookup table to go from "this cell's 6
; format bits" to "this cell's XF index" or back, at the cost of always
; writing all 64 XFs whether or not the sheet uses every combination (at
; most 64*16 + 4*15 bytes - a fixed, small overhead). No FORMAT records are
; written at all: General/Currency/Comma/Percent all land on real BIFF
; built-in number-format ids (0/5/3/9), each already a 0-decimal-place
; form - the only kind this app's whole-number cells ever need.
; =============================================================================

; -----------------------------------------------------------------------------
; sh_biffw - append raw word AX to ES:DI (little-endian, matching BIFF and
; this CPU), advancing DI by 2. ES must already be the staging segment.
; -----------------------------------------------------------------------------
sh_biffw:
    mov [es:di], ax
    add di, 2
    ret

; -----------------------------------------------------------------------------
; sh_stgputb - append raw byte AL to ES:DI, advancing DI by 1. ES must
; already be the staging segment (the caller's job, as with sh_stgput).
; Used for a BIFF length-prefix byte (sh_biffw only writes whole words) and
; for a SYLK F record's single-character format codes.
; -----------------------------------------------------------------------------
sh_stgputb:
    mov [es:di], al
    inc di
    ret

; -----------------------------------------------------------------------------
; sh_rkenc - in: AX = signed 16-bit cell value; out: DX:AX = that value
; packed as an RK "signed 30-bit integer, not multiplied by 100" (bit1=1,
; bit0=0 of the low word) - AX is the low word of the 4-byte RK value, DX
; the high word, matching write order (low word first, then high).
; -----------------------------------------------------------------------------
sh_rkenc:
    push cx
    cwd                    ; DX:AX = AX sign-extended to 32 bits
    mov cx, 2
.shl:
    shl ax, 1
    rcl dx, 1
    loop .shl
    or ax, 0x0002
    pop cx
    ret

; -----------------------------------------------------------------------------
; sh_rkdec_d - in: DX:AX = a packed RK value; out: sh_acc = it, as a double.
;
; ALL FOUR SUBTYPES, where sh_rkdec below handles only the one an integer
; could represent. The other three - divided by 100, and the float form that
; is the TOP 32 BITS of an IEEE-754 double with the low 32 zero - are exactly
; the ones a 16-bit integer had to refuse, and refusing them meant silently
; dropping cells from any file Excel itself had written.
;
;   bit0 = 1: the value is 100x what was meant
;   bit1 = 1: integer form, a signed 30-bit value in the top 30 bits
;   bit1 = 0: float form, the top 32 bits of a double
; -----------------------------------------------------------------------------
sh_rkdec_d:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, ax                        ; bl bit0/bit1 = the subtype flags
    test al, 0x02
    jz .float
    mov cx, 2                         ; integer form: an arithmetic shift, so
.shr:                                 ; a negative value stays negative
    sar dx, 1
    rcr ax, 1
    loop .shr
    push bx
    call fp_i32_to_a                  ; DX:AX (signed 32) -> A
    pop bx
    jmp .div100
.float:
    and ax, 0xFFFC                    ; the two flag bits are not mantissa
    mov word [sh_acc], 0              ; the low 32 bits of the double are zero
    mov word [sh_acc+2], 0            ; by construction in this form
    mov [sh_acc+4], ax
    mov [sh_acc+6], dx
    push bx
    call sh_acc_load_a
    pop bx
.div100:
    test bl, 0x01
    jz .out
    mov ax, 100                       ; bit0: it was scaled up by a hundred
    call fp_i2b
    call fp_div
.out:
    call sh_acc_store
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; sh_i32_to_a - DX:AX, a SIGNED 32-bit integer, becomes A.
fp_i32_to_a:
    push ax
    push bx
    push cx
    push di
    mov byte [fp_as], 0
    or dx, dx
    jns .abs
    mov byte [fp_as], 1
    neg dx                            ; the 32-bit negate idiom
    neg ax
    sbb dx, 0
.abs:
    mov [fp_am0], ax
    mov [fp_am1], dx
    mov word [fp_am2], 0
    mov word [fp_am3], 0
    mov word [fp_ae], 0
    mov bx, fp_am0
    mov di, fp_ae
    call fp_norm
    pop di
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_rkdec - in: DX:AX = a packed RK value (AX low word, DX high word); out:
; CF=0 and AX=the signed 16-bit value if it's the "integer, not multiplied"
; subtype this project writes, else CF=1 (out of this subset's scope - the
; caller should skip the cell rather than guess at a float or *100 value)
; -----------------------------------------------------------------------------
sh_rkdec:
    test al, 0x01
    jnz .unsupported        ; multiplied by 100
    test al, 0x02
    jz .unsupported         ; plain IEEE-754 float form, top 32 bits only
    push cx
    mov cx, 2
.shr:
    sar dx, 1
    rcr ax, 1
    loop .shr
    pop cx
    clc
    ret
.unsupported:
    stc
    ret

; -----------------------------------------------------------------------------
; sh_biff_numfmt_from_id - in: AL = a real BIFF built-in number-format id;
; out: AL = this app's SH_FMT_NUM_* code (General for anything that isn't
; one of the four ids sh_biff_numfmt_tab itself ever writes - a custom
; FORMAT record's id, or a built-in this app doesn't have an equivalent
; for, both just degrade to General rather than guessed at)
; -----------------------------------------------------------------------------
sh_biff_numfmt_from_id:
    cmp al, 0x05
    je .cur
    cmp al, 0x03
    je .comma
    cmp al, 0x09
    je .pct
    xor al, al
    ret
.cur:
    mov al, SH_FMT_NUM_CURRENCY
    ret
.comma:
    mov al, SH_FMT_NUM_COMMA
    ret
.pct:
    mov al, SH_FMT_NUM_PERCENT
    ret

; -----------------------------------------------------------------------------
; sh_biff_applyfmt - in: sh_wrec_col/sh_wrec_row (the cell just written by
; sh_setval), sh_wrec_xf (its BIFF ixfe); combines sh_xf_fmt/sh_xf_font (if
; the xf index is one this reader tracked) with sh_font_tab (if that xf's
; font index is one it tracked) into this app's own format byte, and
; writes it to the cell. A cell whose xf or font fell outside the tracked
; caps is left at format 0 (General, unformatted) rather than guessed at.
; -----------------------------------------------------------------------------
sh_biff_applyfmt:
    push ax
    push bx
    push cx
    push di
    push es
    mov bx, [sh_wrec_xf]
    cmp bx, SH_BIFF_XF_CAP
    jae .out
    mov di, sh_xf_fmt
    add di, bx
    mov al, [di]                       ; al = align|numfmt packed byte
    mov di, sh_xf_font
    add di, bx
    mov cl, [di]                       ; cl = this xf's font index
    xor ch, ch
    cmp cx, SH_BIFF_FONT_CAP
    jae .noboldunder
    mov di, sh_font_tab
    add di, cx
    or al, [di]                        ; fold in bold/underline
.noboldunder:
    mov cl, al                         ; stash the finished byte in cl
                                        ; across the cell lookup below
    mov ax, [sh_wrec_col]
    mov bx, [sh_wrec_row]
    call sh_findcell
    jnc .out
    mov es, [sh_cellseg]
    mov [es:di+5], cl
.out:
    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_dowrite_biff - write the sheet to [sh_name] as BIFF. Walks the sorted
; cell array directly, same shape as sh_dowrite_sylk.
; -----------------------------------------------------------------------------
sh_dowrite_biff:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [sh_stgseg]
    xor di, di

    mov ax, 0x0209                   ; BOF (BIFF3). NOT BIFF4, deliberately:
                                      ; a reader is BACKWARD compatible and
                                      ; not forward compatible, so Excel 4 and
                                      ; everything after it read a BIFF3 file
                                      ; happily, while a program that knows
                                      ; only BIFF3 cannot read a BIFF4 one -
                                      ; it does not even recognise the BOF.
                                      ; Emitting the older stream is therefore
                                      ; strictly the wider audience, and costs
                                      ; nothing: every record this writer uses
                                      ; exists in BIFF3.
    call sh_biffw
    mov ax, 6
    call sh_biffw
    mov ax, 0x0300                   ; vers = BIFF3, matching the BOF above
    call sh_biffw
    mov ax, 0x0010                   ; dt = worksheet
    call sh_biffw
    xor ax, ax                       ; BIFF3's BOF carries two more bytes,
    call sh_biffw                    ; documented as "not used" - BIFF2's
                                      ; record is the four-byte one, and a
                                      ; reader that trusts the length would
                                      ; desynchronise on the short form

    ; 4 FONT records (indices 0-3: normal, bold, underline, bold+underline)
    ; and 64 XF records (indices 0-63) - one per possible SH_FMT_* byte
    ; value, so a cell's own format byte IS its BIFF ixfe with no lookup
    ; table needed on either side. See the section comment above for why
    ; this pairing is safe and the honesty scope around it.
    mov word [sh_wrow], 0            ; reused as the font index, 0..3
.fontloop:
    mov ax, [sh_wrow]
    cmp ax, 4
    jae .fontsdone
    mov ax, 0x0231                   ; FONT (BIFF3/4)
    call sh_biffw
    mov ax, 11                       ; height+options+palette(6) + len(1) +
    call sh_biffw                    ; "Helv"(4)
    mov ax, 200                      ; height: 10pt in twips
    call sh_biffw
    mov bx, [sh_wrow]
    xor ax, ax
    test bl, 1
    jz .nobold_f
    or ax, 0x0001                    ; bit0: bold
.nobold_f:
    test bl, 2
    jz .nounder_f
    or ax, 0x0004                    ; bit2: underlined
.nounder_f:
    call sh_biffw
    xor ax, ax                       ; palette index (default)
    call sh_biffw
    mov al, 4
    call sh_stgputb                   ; name length prefix
    mov si, sh_s_biff_fontname
    call sh_stgput                   ; the raw bytes, no NUL (BIFF strings
                                      ; are length-prefixed, not C strings)
    mov ax, [sh_wrow]
    inc ax
    mov [sh_wrow], ax
    jmp .fontloop
.fontsdone:
    mov word [sh_wrow], 0            ; reused as the XF index, 0..63
.xfloop:
    mov si, [sh_wrow]
    cmp si, 64
    jae .xfsdone
    mov ax, 0x0243                   ; XF (BIFF3). Same twelve bytes as the
                                      ; BIFF4 record in the fields this uses -
                                      ; font index, format index, attributes,
                                      ; alignment, area, border - which is why
                                      ; the body below did not have to change
                                      ; with the opcode. BIFF4's additions to
                                      ; that record (orientation, notably) sit
                                      ; in bits this never sets.
    call sh_biffw
    mov ax, 12
    call sh_biffw
    mov ax, si
    and ax, 3                        ; al = font index (bits0-1 of the
                                      ; format byte: bold, underline)
    mov bx, si
    mov cl, 4
    shr bx, cl
    and bx, 3                        ; bx = our number-format code
    mov ah, [sh_biff_numfmt_tab + bx] ; ah = real BIFF built-in format id
    call sh_biffw                    ; offset0-1: font idx, format idx
    mov ax, 0xFC00                   ; BIFF3 offset2 = XF_TYPE_PROT (0: a
    call sh_biffw                    ; cell XF, unlocked, not hidden), and
                                      ; offset3 = XF_USED_ATTRIB (FCH:
                                      ; override every inherited attribute,
                                      ; since no style XFs are written).
                                      ; BIFF4 puts those in DIFFERENT places -
                                      ; a word at 2, and a byte at 5 - which
                                      ; is why the body had to change with the
                                      ; opcode after all.
    mov ax, si
    mov cl, 2
    shr ax, cl
    and ax, 3                        ; al = align code (bits2-3 of the
                                      ; format byte) - matches XF_HOR_ALIGN
                                      ; 0-3 (General/Left/Center/Right)
                                      ; directly, no translation needed
    xor ah, ah                       ; BIFF3 offset4 is a WORD: alignment in
    or ax, 0xFFF0                    ; bits 2-0, and the parent style XF index
    call sh_biffw                    ; in bits 15-4. FFFH is the documented
                                      ; "no parent", which is the honest value
                                      ; when no style XF exists to point at.
    xor ax, ax                       ; XF_AREA_34: no fill
    call sh_biffw
    xor ax, ax                       ; XF_BORDER_34 low word: no borders
    call sh_biffw
    xor ax, ax                       ; XF_BORDER_34 high word
    call sh_biffw
    mov ax, si
    inc ax
    mov [sh_wrow], ax
    jmp .xfloop
.xfsdone:

    mov byte [sh_trunc], 0
    mov word [sh_wrow], 0            ; reused here as the record index
.rec:
    mov bx, [sh_wrow]
    cmp bx, [sh_ncells]
    jae .footer
    cmp byte [sh_trunc], 0
    jne .footer
    mov ax, di
    add ax, 14                       ; opcode+len(4) + row+col+xf+rk(10)
    cmp ax, SH_STAGE_MAX
    jbe .room
    mov byte [sh_trunc], 1
    jmp .footer
.room:
    mov ax, bx
    mov cx, SH_C_SZ
    mul cx
    mov si, ax                        ; SI = this record's offset in cellseg
    push es
    mov es, [sh_cellseg]
    mov ax, [es:si]
    call sh_unpackrow                 ; -> ax=real row, bx=this record's
                                       ; sheet (stage 2.0)
    cmp bx, [sh_cursheet]
    jne .recskip                      ; a save only ever writes the CURRENT
                                       ; sheet - see sh_dowrite_sylk's own
                                       ; copy of this same filter
    mov [sh_wrec_row], ax
    mov ax, [es:si+2]
    mov [sh_wrec_col], ax
    call sh_cellval_to_acc_si         ; the whole value, banked - the choice
    push si                           ; of record below needs all eight bytes
    push di
    mov si, sh_acc
    mov di, sh_wrec_dval
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
    mov al, [es:si+5]
    mov [sh_wrec_fmt], al
    pop es                            ; ES = stgseg again

    ; --- which record? -------------------------------------------------------
    ; AN EXACT IN-RANGE INTEGER STILL GOES OUT AS RK, byte for byte as before,
    ; so every file this app has already written is unchanged and a reader that
    ; only knows the old subtype still reads those cells. Anything else - a
    ; fraction, or a magnitude past a signed word - needs the NUMBER record,
    ; which carries the IEEE-754 double verbatim.
    push si
    mov si, sh_wrec_dval
    call fp_unpack_a
    pop si
    call fp_a2i                       ; CF=1: no signed word can hold it
    jc .asnumber
    mov [sh_wrec_val], ax
    call fp_i2a                       ; round-trip it and see if anything was
    push si                           ; lost - 3.5 truncates to 3, and 3 is
    mov si, sh_wrec_dval              ; not the value we were asked to write
    call fp_unpack_b
    pop si
    call fp_cmpab
    jne .asnumber

    mov ax, 0x027E                    ; RK cell record
    call sh_biffw
    mov ax, 10
    call sh_biffw
    mov ax, [sh_wrec_row]
    call sh_biffw
    mov ax, [sh_wrec_col]
    call sh_biffw
    xor ah, ah
    mov al, [sh_wrec_fmt]              ; xf = the format byte itself
    call sh_biffw
    mov ax, [sh_wrec_val]
    call sh_rkenc                     ; -> DX:AX = packed RK value
    call sh_biffw                     ; low word
    mov ax, dx
    call sh_biffw                     ; high word
    jmp .recnext
.asnumber:
    mov ax, 0x0203                    ; NUMBER: row, col, xf, then an 8-byte
    call sh_biffw                     ; IEEE-754 double, little-endian - the
    mov ax, 14                        ; same layout the working form packs to,
    call sh_biffw                     ; so it goes out with no conversion
    mov ax, [sh_wrec_row]
    call sh_biffw
    mov ax, [sh_wrec_col]
    call sh_biffw
    xor ah, ah
    mov al, [sh_wrec_fmt]
    call sh_biffw
    mov ax, [sh_wrec_dval]
    call sh_biffw
    mov ax, [sh_wrec_dval+2]
    call sh_biffw
    mov ax, [sh_wrec_dval+4]
    call sh_biffw
    mov ax, [sh_wrec_dval+6]
    call sh_biffw
    jmp .recnext
.recskip:
    pop es
.recnext:
    mov ax, [sh_wrow]
    inc ax
    mov [sh_wrow], ax
    jmp .rec
.footer:
    mov ax, 0x000A                    ; EOF
    call sh_biffw
    xor ax, ax
    call sh_biffw
    mov [sh_stagelen], di

    mov ax, [sh_stgseg]
    mov es, ax
    xor bx, bx
    mov cx, [sh_stagelen]
    xor dx, dx
    mov si, sh_name
    call OSAPI_FILE_WRITE
    jc .werr
    mov word [sh_msg], sh_m_saved
    jmp .wdone
.werr:
    call sh_setferr
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
; sh_doread_biff - read [sh_name] as BIFF, replacing the sheet. Skips the
; BOF record (and every other record type this subset doesn't know, by its
; length - so a real file's extra records, e.g. a workbook-globals BOF,
; FONT, or FORMAT record, are tolerated rather than misparsed), then
; applies every RK cell record found whose value is this subset's
; understood subtype, until EOF or the buffer end (a truncated/foreign
; file).
; -----------------------------------------------------------------------------
sh_doread_biff:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, [sh_stgseg]
    xor bx, bx
    mov cx, SH_STAGE_MAX
    xor dx, dx
    mov si, sh_name
    call OSAPI_FILE_READ               ; out: AX = bytes read, or CF=1
    jc .rerr

    mov word [sh_ncells], 0
    mov word [sh_biff_nfont], 0
    mov word [sh_biff_nxf], 0
    mov cx, ax                         ; CX = end offset (bytes read)
    xor si, si
.rechdr:
    mov ax, si
    add ax, 4                          ; a record header is 4 bytes; EOF's
    cmp ax, cx                         ; is the shortest whole record, so
    ja .done                           ; anything less can't be one
    mov ax, [es:si]                    ; opcode
    mov dx, [es:si+2]                  ; length
    add si, 4                          ; SI = this record's data start
    cmp ax, 0x000A                     ; EOF
    je .done
    cmp ax, 0x0231                     ; FONT
    je .isfont
    cmp ax, 0x0243                     ; XF (BIFF3) - what this app writes
    je .isxf                           ; now, and what a real Excel 3 file
    cmp ax, 0x0443                     ; carries. BIFF4's is accepted too, so
    je .isxf                           ; files written before the switch still
                                        ; read back with their formats, as do
                                        ; real Excel 4 files. BIFF5-8's XF
                                        ; (0x00E0) has a different layout and
                                        ; is skipped generically below, so
                                        ; those cells read back unformatted
                                        ; rather than misformatted.
    cmp ax, 0x027E                     ; RK cell record
    je .isrk
    cmp ax, 0x0203                     ; NUMBER: a whole IEEE-754 double, and
    je .isnum                          ; the only way a fraction can travel
    jmp .skip
.isfont:
    mov bx, [sh_biff_nfont]
    cmp bx, SH_BIFF_FONT_CAP
    jae .fontcounted                   ; too many fonts to track: this one
                                        ; (and any cell using it) just
                                        ; reads back as not bold/underlined
    mov ax, si
    add ax, 4                          ; need at least height+options here
    cmp ax, cx
    ja .fontcounted
    mov al, [es:si+2]                  ; BIFF options byte: bit0 bold,
    mov ah, 0                          ; bit2 underline (BIFF3/4 layout)
    test al, 0x01
    jz .fnb
    or ah, SH_FMT_BOLD
.fnb:
    test al, 0x04
    jz .fnu
    or ah, SH_FMT_UNDER
.fnu:
    mov di, sh_font_tab
    add di, bx
    mov [di], ah
.fontcounted:
    inc word [sh_biff_nfont]
    jmp .skip
.isxf:
    mov bx, [sh_biff_nxf]
    cmp bx, SH_BIFF_XF_CAP
    jae .xfcounted                     ; too many XFs to track: a cell
                                        ; using one just reads back General
    mov ax, si
    add ax, 12                         ; need the full BIFF4 XF body
    cmp ax, cx
    ja .xfcounted
    mov al, [es:si]                    ; font index (offset0, low byte of
    mov di, sh_xf_font                 ; the font/format word)
    add di, bx
    mov [di], al
    mov al, [es:si+4]                  ; align/wrap/vertalign/orient byte
    and al, 0x07                       ; the full 3-bit XF_HOR_ALIGN field
    cmp al, 3
    jbe .alignok
    xor al, al                         ; Filled/Justified/CenterAcrossSel:
                                        ; out of this subset's scope
.alignok:
    push cx                            ; CX IS THE FILE'S END OFFSET here, and
    mov cl, SH_FMT_ALIGN_SHIFT         ; `mov cl` destroys its low byte. With
    shl al, cl                         ; 64 XF records to read, the walk then
    pop cx                             ; ran off a length of ~1028 instead of
    mov ah, al                         ; 1160 and stopped BEFORE the first cell
    mov al, [es:si+1]                  ; record - so every BIFF file this app
    call sh_biff_numfmt_from_id        ; wrote read back as "Loaded" and empty.
    push cx
    mov cl, SH_FMT_NUM_SHIFT
    shl al, cl
    pop cx
    or al, ah                          ; al = align|numfmt packed byte
    mov di, sh_xf_fmt
    add di, bx
    mov [di], al
.xfcounted:
    inc word [sh_biff_nxf]
    jmp .skip
.isrk:
    push dx                            ; length, saved across sh_setval
                                        ; (which itself preserves DX, but
                                        ; only around the value it was
                                        ; passed - not a second use)
    mov ax, si
    add ax, dx
    cmp ax, cx
    ja .toolong                        ; truncated record: stop, don't read
    mov ax, [es:si]                    ; row
    mov [sh_wrec_row], ax
    mov ax, [es:si+2]                  ; col
    mov [sh_wrec_col], ax
    mov ax, [es:si+4]                  ; xf index
    mov [sh_wrec_xf], ax
    mov ax, [es:si+6]                  ; rk value low word
    mov dx, [es:si+8]                  ; rk value high word
    push es                            ; sh_rkdec_d works in sh_acc, which is
    call sh_rkdec_d                    ; ours, not the staging segment's
    pop es
    mov ax, [sh_wrec_col]
    mov bx, [sh_wrec_row]
    call sh_setvald
    call sh_biff_applyfmt              ; uses sh_wrec_col/row/xf; looks up
                                        ; the format and writes it to the
                                        ; cell record sh_setval just made
.rkdone:
    pop dx
    jmp .skip
.isnum:
    push dx
    mov ax, si
    add ax, dx
    cmp ax, cx
    ja .toolong
    mov ax, [es:si]                    ; row
    mov [sh_wrec_row], ax
    mov ax, [es:si+2]                  ; col
    mov [sh_wrec_col], ax
    mov ax, [es:si+4]                  ; xf index
    mov [sh_wrec_xf], ax
    mov ax, [es:si+6]                  ; the eight value bytes, verbatim
    mov [sh_acc], ax
    mov ax, [es:si+8]
    mov [sh_acc+2], ax
    mov ax, [es:si+10]
    mov [sh_acc+4], ax
    mov ax, [es:si+12]
    mov [sh_acc+6], ax
    push es
    mov ax, [sh_wrec_col]
    mov bx, [sh_wrec_row]
    call sh_setvald
    call sh_biff_applyfmt
    pop es
    pop dx
    jmp .skip
.toolong:
    pop dx
    jmp .done
.skip:
    add si, dx
    jmp .rechdr
.done:
    mov word [sh_msg], sh_m_loaded
    jmp .out
.rerr:
    call sh_setferr
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
; sh_parseslk - walk every line of a buffer, applying each 'C' record found
; in: SI = buffer start (offset in ES), CX = length; ES = the buffer's
; segment (the caller's job, e.g. sh_doread sets it to sh_stgseg)
; -----------------------------------------------------------------------------
sh_parseslk:
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
    cmp ax, 2
    jb .advance
    cmp byte [es:si+1], ';'
    jne .advance
    cmp byte [es:si], 'C'
    jne .notc
    push si
    add si, 2
    call sh_parsecrec                ; in: SI=tokens start, BX=line end
    pop si
    jmp .advance
.notc:
    cmp byte [es:si], 'F'
    jne .advance
    push si
    add si, 2
    call sh_parsefrec                ; in: SI=tokens start, BX=line end
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
; sh_parsecrec - the fields of one 'C' record, order-independent
; in: SI = start of tokens (right after "C;"), BX = line end (exclusive);
; ES = the buffer's segment, same as sh_parseslk's caller set
; -----------------------------------------------------------------------------
sh_parsecrec:
    push ax
    push bx
    push si
    mov word [SH_TCOL], 0
    mov word [SH_TROW], 0
    mov word [SH_TVAL], 0
    mov byte [SH_THASE], 0
    mov word [SH_TDVAL], 0
    mov word [SH_TDVAL+2], 0
    mov word [SH_TDVAL+4], 0
    mov word [SH_TDVAL+6], 0
    mov byte [SH_THAVE], 0
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
    call sh_pint
    mov [SH_TCOL], ax
    jmp .tok
.isy:
    inc si
    call sh_pint
    mov [SH_TROW], ax
    jmp .tok
.isk:
    inc si
    call sh_esatof                    ; a full decimal, not an integer
    push ax
    push si
    push di
    mov si, sh_acc
    mov di, SH_TDVAL
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
    mov byte [SH_THAVE], 1
    jmp .tok
.ise:
    inc si
    push di                           ; the expression, copied out of the
    mov di, SH_TEXPR                  ; staging segment into DS so the R1C1
    mov cx, SH_EDITMAX                ; converter can read it
.ecpy:
    jcxz .ecpyd
    cmp si, bx
    jae .ecpyd
    mov al, [es:si]
    cmp al, ';'
    je .ecpyd
    cmp al, 13
    je .ecpyd
    cmp al, 10
    je .ecpyd
    mov [di], al
    inc di
    inc si
    dec cx
    jmp .ecpy
.ecpyd:
    mov byte [di], 0
    pop di
    mov byte [SH_THASE], 1
    jmp .tok
.apply:
    cmp byte [SH_THAVE], 0
    je .out
    mov ax, [SH_TCOL]
    cmp ax, 1
    jb .out
    cmp ax, SH_COLS
    ja .out
    mov cx, [SH_TROW]
    cmp cx, 1
    jb .out
    cmp cx, SH_ROWS
    ja .out
    dec ax
    dec cx
    mov bx, cx
    cmp byte [SH_THASE], 0            ; a ;E field wins over ;K: the value is
    je .plainval_c                    ; only the cached result of it, and
    push ax                           ; storing that instead would flatten the
    push bx                           ; formula exactly as this used to
    push si
    push di
    mov [sh_rc_ccol], ax
    mov [sh_rc_crow], bx
    mov si, SH_TEXPR
    call sh_formula_from_r1c1
    pop di
    pop si
    pop bx
    pop ax
    mov si, sh_rwdst                  ; AFTER the pops: setting SI before them
    call sh_setformula                ; put the saved value straight back over
                                      ; it, and sh_setformula stored whatever
                                      ; the staging pointer happened to be
    jmp .out
.plainval_c:
    push si
    push di
    mov si, SH_TDVAL
    mov di, sh_acc
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
    call sh_setvald
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_parsefrec - the fields of an "F" (formatting) record, stage 1.6's real
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
sh_parsefrec:
    push ax
    push bx
    push cx
    push si
    push di                           ; sh_findcell below is called for its
                                       ; side effect on DI, but sh_parseslk's
                                       ; caller keeps its own buffer-end in
                                       ; DI live across this whole call - it
                                       ; must come back unchanged
    mov word [SH_TCOL], 0
    mov word [SH_TROW], 0
    mov byte [SH_TALIGN], 0
    mov byte [SH_TNUMFMT], 0
    mov byte [SH_TCOMMA], 0
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
    call sh_pint
    mov [SH_TCOL], ax
    jmp .tok
.isy:
    inc si
    call sh_pint
    mov [SH_TROW], ax
    jmp .tok
.isk:
    inc si
    mov byte [SH_TCOMMA], 1
    jmp .tok
.isf:                                  ; ;F<c1>[space]<digits>[space]<c2> -
                                        ; one field, not semicolon-delimited
                                        ; internally, so it's parsed as its
                                        ; own little grammar before control
                                        ; returns to the outer ;-scan loop
    inc si
    cmp si, bx
    jae .tok
    mov al, [es:si]
    call sh_sylk_numfmt_from_c1
    mov [SH_TNUMFMT], al
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
    call sh_sylk_align_from_c2
    mov [SH_TALIGN], al
    inc si
    jmp .tok
.apply:
    mov ax, [SH_TCOL]
    cmp ax, 1
    jb .out
    cmp ax, SH_COLS
    ja .out
    mov cx, [SH_TROW]
    cmp cx, 1
    jb .out
    cmp cx, SH_ROWS
    ja .out
    dec ax
    dec cx
    mov bx, cx
    call sh_findcell
    jnc .out                          ; no prior C record for this cell:
                                       ; nothing to attach the format to
    mov al, [SH_TNUMFMT]
    cmp byte [SH_TCOMMA], 0
    je .noupgrade
    or al, al
    jnz .noupgrade                    ; ;K only promotes a still-General
                                       ; code to Comma - an explicit c1 of
                                       ; '$' (Currency) wins if both appear
    mov al, SH_FMT_NUM_COMMA
.noupgrade:
    mov cl, SH_FMT_NUM_SHIFT
    shl al, cl
    mov ah, [SH_TALIGN]
    mov cl, SH_FMT_ALIGN_SHIFT
    shl ah, cl
    or al, ah
    push es
    mov es, [sh_cellseg]
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
; sh_sylk_numfmt_from_c1 - in: AL = an F record's c1 formatting-code char;
; out: AL = this app's SH_FMT_NUM_* code. Real SYLK's c1 codes are
; 0/C/E/F/G/$/* (default/continuous/scientific/fixed/general/currency/
; bargraph) - only '$' has an equivalent here; everything else (including
; the codes this app never writes, like scientific or bargraph) falls back
; to General, which is the honest answer since this app has no comparable
; format for them either.
; -----------------------------------------------------------------------------
sh_sylk_numfmt_from_c1:
    cmp al, '$'
    je .cur
    xor al, al
    ret
.cur:
    mov al, SH_FMT_NUM_CURRENCY
    ret

; -----------------------------------------------------------------------------
; sh_sylk_align_from_c2 - in: AL = an F record's c2 alignment-code char
; ('0' default, 'C' center, 'G' general, 'L' left, 'R' right); out: AL =
; this app's SH_FMT_ALIGN_* code
; -----------------------------------------------------------------------------
sh_sylk_align_from_c2:
    cmp al, 'L'
    je .left
    cmp al, 'C'
    je .center
    cmp al, 'R'
    je .right
    xor al, al
    ret
.left:
    mov al, SH_FMT_ALIGN_LEFT
    ret
.center:
    mov al, SH_FMT_ALIGN_CENTER
    ret
.right:
    mov al, SH_FMT_ALIGN_RIGHT
    ret

; -----------------------------------------------------------------------------
; sh_pint - parse a signed decimal integer
; in: ES:SI=ptr, BX=limit (exclusive, an offset); also stops at NUL
; out: AX=value, SI=advanced; BX preserved; ES must be set by the caller
; -----------------------------------------------------------------------------
sh_pint:
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
; sh_setferr - build "Err N" from a FERR_* code and point sh_msg at it
; in: AX = FERR_* (CF was set on the API call that produced it)
; -----------------------------------------------------------------------------
sh_setferr:
    push di
    push si
    mov di, sh_errbuf
    mov si, sh_s_errpfx
    call sh_strcpy_to_di              ; DI advances past "Err " to the new NUL
    call sh_itoa                      ; AX (the FERR_* code) -> sh_numbuf;
                                       ; preserves DI
    mov si, sh_numbuf
    call sh_strcpy_to_di
    mov word [sh_msg], sh_errbuf
    pop si
    pop di
    ret

; =============================================================================
; Cell storage - a sorted array of (row, col, flags, format, value,
; formula_off, pass) records in the claimed sh_cellseg, searched with a
; binary search and kept sorted by shifting on insert/remove. 12 bytes/rec:
;   +0 row (word) - stage 2.0: PACKED, not a plain row. Bits 0-13 are the
;   real row (0..16383, SH_ROW_MASK); bits 14-15 are the sheet index
;   (0..SH_SHEETS-1). Sorting and searching a plain 16-bit compare on this
;   word therefore sorts every sheet's records into one contiguous run,
;   ordered first by sheet and then by row within it, with NO change to the
;   comparison logic itself - only the few places that construct or take
;   apart the word (sh_findcell packing it from [sh_cursheet], sh_unpackrow
;   splitting it back out for the SYLK/DIF/BIFF writers, which must skip
;   every sheet but the one being saved) know this isn't just a row.
;   +2 col (word)  +4 flags (byte)  +5 format (byte, the
;   SH_FMT_* bits, stage 1.6 - this byte was unused padding before)
;   +6 value (word)  +8 formula_off (word, 0xFFFF=none)  +10 pass (word)
; Only three routines (sh_findcell/sh_addcell/sh_removecell) know this
; layout and the shifting; everything else goes through sh_getcell2/
; sh_setval/sh_clearcell.
; =============================================================================

; -----------------------------------------------------------------------------
; sh_unpackrow - in: AX = a cell record's packed row/sheet word; out: AX =
; the real row (0..16383), BX = the sheet index it belongs to
; -----------------------------------------------------------------------------
sh_unpackrow:
    push cx
    mov bx, ax
    mov cl, SH_ROW_BITS
    shr bx, cl
    and ax, SH_ROW_MASK
    pop cx
    ret

; -----------------------------------------------------------------------------
; sh_findcell - binary search for (col, row)
; in: AX=col, BX=row
; out: CF=1 found, DI=byte offset of the record
;      CF=0 not found, DI=byte offset where it would be inserted
; -----------------------------------------------------------------------------
sh_findcell:
    push ax
    push bx
    push cx
    push dx
    push si
    mov [sh_fcol], ax
    mov ax, [sh_cursheet]              ; the stored "row" word is really a
    mov cl, SH_ROW_BITS                ; packed (sheet<<SH_ROW_BITS | row) -
    shl ax, cl                         ; see the stage 2.0 comment above the
    or ax, bx                          ; cell record layout - so every
    mov [sh_frow], ax                  ; existing caller of this proc (all
                                        ; of them pass a plain 0..16383 row)
                                        ; keeps working unchanged, searching
                                        ; only the CURRENT sheet's records
    xor cx, cx                        ; CX = lo
    mov dx, [sh_ncells]                ; DX = hi
.loop:
    cmp cx, dx
    jae .notfound
    mov si, dx
    sub si, cx
    shr si, 1
    add si, cx                        ; SI = mid
    mov ax, si
    mov bx, SH_C_SZ
    push dx                           ; MUL clobbers DX (the high word of
    mul bx                            ; the product) - DX is also this
    pop dx                            ; loop's search bound, so it must
    mov di, ax                        ; survive every iteration, not just
                                       ; the one that happens to find a match
                                       ; on its first probe
    push es
    mov es, [sh_cellseg]
    mov ax, [es:di]                   ; candidate row
    mov bx, [es:di+2]                 ; candidate col
    pop es
    cmp ax, [sh_frow]
    jl .lower
    jg .higher
    cmp bx, [sh_fcol]
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
    mov bx, SH_C_SZ
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
; sh_addcell - find or create the record for (col, row)
; in: AX=col, BX=row
; out: CF=0, DI=byte offset of the record (existing or new, zeroed if new)
;      CF=1 the table is full - no new record could be created
; -----------------------------------------------------------------------------
sh_addcell:
    push ax
    push bx
    push cx
    push dx
    push si
    call sh_findcell
    jc .found
    cmp word [sh_ncells], SH_CELL_CAP
    jae .full
    push di                            ; insertion offset, kept across the
                                        ; shift below
    mov ax, [sh_ncells]
    mov bx, SH_C_SZ
    mul bx                             ; AX = current end-of-array offset
    mov cx, ax
    sub cx, di                         ; CX = bytes to shift up (may be 0)
    push ds
    push es
    mov dx, [sh_cellseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, ax
    dec si
    mov di, si
    add di, SH_C_SZ
    std
    rep movsb
    cld
.noshift:
    pop es
    pop ds
    pop di                             ; DI = insertion offset, restored
    inc word [sh_ncells]
    push es
    mov es, [sh_cellseg]
    mov ax, [sh_frow]
    mov [es:di], ax
    mov ax, [sh_fcol]
    mov [es:di+2], ax
    mov byte [es:di+4], 0
    mov byte [es:di+5], 0
    mov byte [es:di+SH_C_TYPE], SH_T_NUM
    mov byte [es:di+SH_C_AUX], 0
    mov word [es:di+SH_C_VAL], 0      ; ALL EIGHT value bytes, not just the low
    mov word [es:di+SH_C_VAL+2], 0    ; word the integer model uses today. The
    mov word [es:di+SH_C_VAL+4], 0    ; array is shuffled with a byte move, so
    mov word [es:di+SH_C_VAL+6], 0    ; a "new" record inherits whatever the
                                      ; record above it left here - harmless
                                      ; while only the low word is read, and a
                                      ; genuinely nasty surprise the moment the
                                      ; full double goes live
    mov word [es:di+SH_C_FOFF], 0xFFFF
    mov word [es:di+SH_C_PASS], 0
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
; sh_removecell - in: AX=col, BX=row; removes the record if present
; -----------------------------------------------------------------------------
sh_removecell:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    call sh_findcell
    jnc .out
    mov ax, [sh_ncells]
    mov bx, SH_C_SZ
    mul bx                             ; AX = end offset (before shrink)
    mov cx, ax
    sub cx, di
    sub cx, 12                         ; CX = bytes after this record
    push ds
    push es
    mov dx, [sh_cellseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, di
    add si, SH_C_SZ
    cld
    rep movsb
.noshift:
    pop es
    pop ds
    dec word [sh_ncells]
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; Border table (stage 2.x, sh_bordseg claim) - a SEPARATE sparse sorted
; array, same shape and packing convention as the main cell array above
; (sh_findcell's own stage 2.0 comment on the packed row/sheet word applies
; here unchanged) but only 5 bytes/record: +0 packed row/sheet (word)
; +2 col (word) +4 border byte (SH_BORD_* bits). Almost no cell ever has a
; border, so a cell simply has NO record here at all until Format >
; Border... sets one of its bits, and loses its record again the moment
; every bit clears (sh_bt_removecell) - the same "no record = default"
; philosophy the main array already uses for value 0 vs formatted-and-0.
; =============================================================================

; sh_bt_findcell - binary search for (col,row); in AX=col,BX=row;
; out CF=1 found DI=offset, CF=0 not found DI=insertion offset
sh_bt_findcell:
    push ax
    push bx
    push cx
    push dx
    push si
    mov [sh_fcol], ax
    mov ax, [sh_cursheet]
    mov cl, SH_ROW_BITS
    shl ax, cl
    or ax, bx
    mov [sh_frow], ax
    xor cx, cx
    mov dx, [sh_nbord]
.loop:
    cmp cx, dx
    jae .notfound
    mov si, dx
    sub si, cx
    shr si, 1
    add si, cx
    mov ax, si
    mov bx, 5
    push dx
    mul bx
    pop dx
    mov di, ax
    push es
    mov es, [sh_bordseg]
    mov ax, [es:di]
    mov bx, [es:di+2]
    pop es
    cmp ax, [sh_frow]
    jl .lower
    jg .higher
    cmp bx, [sh_fcol]
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
    mov bx, 5
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

; sh_bt_addcell - find or create (col,row); in AX=col,BX=row;
; out CF=0 DI=offset (zeroed border byte if new), CF=1 table full
sh_bt_addcell:
    push ax
    push bx
    push cx
    push dx
    push si
    call sh_bt_findcell
    jc .found
    cmp word [sh_nbord], SH_BORD_CAP
    jae .full
    push di
    mov ax, [sh_nbord]
    mov bx, 5
    mul bx
    mov cx, ax
    sub cx, di
    push ds
    push es
    mov dx, [sh_bordseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, ax
    dec si
    mov di, si
    add di, 5
    std
    rep movsb
    cld
.noshift:
    pop es
    pop ds
    pop di
    inc word [sh_nbord]
    push es
    mov es, [sh_bordseg]
    mov ax, [sh_frow]
    mov [es:di], ax
    mov ax, [sh_fcol]
    mov [es:di+2], ax
    mov byte [es:di+4], 0
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

; sh_bt_removecell - in: AX=col, BX=row
sh_bt_removecell:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    call sh_bt_findcell
    jnc .out
    mov ax, [sh_nbord]
    mov bx, 5
    mul bx
    mov cx, ax
    sub cx, di
    sub cx, 5
    push ds
    push es
    mov dx, [sh_bordseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, di
    add si, 5
    cld
    rep movsb
.noshift:
    pop es
    pop ds
    dec word [sh_nbord]
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; sh_bt_get - in: AX=col, BX=row; out: AL = border byte (0 if no record)
sh_bt_get:
    push bx
    push di
    push es
    call sh_bt_findcell
    jnc .none
    mov es, [sh_bordseg]
    mov al, [es:di+4]
    jmp .out
.none:
    xor al, al
.out:
    pop es
    pop di
    pop bx
    ret

; =============================================================================
; Note table (stage 3.0b, sh_noteseg claim) - Excel 2.1's cell notes, reached
; from Formula > Note... A THIRD sparse sorted array, the same shape as the
; border table above and searched the same way, but 6 bytes/record: +0 packed
; row/sheet (word) +2 col (word) +4 the note text's offset in sh_txtseg
; (word).
;
; THE TEXT LIVES IN THE EXISTING FORMULA ARENA, not in this claim. A note is
; text of unknown length and sh_txt_append already appends exactly that, so this
; table stores an offset into it just as a cell record stores formula_off.
; That arena is APPEND-ONLY and never compacted, so re-editing a note leaks
; its old copy - which is precisely what re-editing a formula has always done,
; so the behaviour is at least consistent, and 8KB is a lot of notes. When the
; arena fills, sh_txt_append returns CF=1 and the edit is refused rather than
; half-applied.
;
; This is Sheet's 7th claim of MEM_OWNER_MAX's 8 (own region + cellseg/txtseg/
; stgseg/bordseg/chartseg/noteseg), so there is exactly one left.
; =============================================================================

; sh_nt_findcell - binary search for (col,row); in AX=col,BX=row;
; out CF=1 found DI=offset, CF=0 not found DI=insertion offset
sh_nt_findcell:
    push ax
    push bx
    push cx
    push dx
    push si
    mov [sh_fcol], ax
    mov ax, [sh_cursheet]
    mov cl, SH_ROW_BITS
    shl ax, cl
    or ax, bx
    mov [sh_frow], ax
    xor cx, cx
    mov dx, [sh_nnote]
.loop:
    cmp cx, dx
    jae .notfound
    mov si, dx
    sub si, cx
    shr si, 1
    add si, cx
    mov ax, si
    mov bx, SH_NOTE_REC
    push dx
    mul bx
    pop dx
    mov di, ax
    push es
    mov es, [sh_noteseg]
    mov ax, [es:di]
    mov bx, [es:di+2]
    pop es
    cmp ax, [sh_frow]
    jl .lower
    jg .higher
    cmp bx, [sh_fcol]
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
    mov bx, SH_NOTE_REC
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

; sh_nt_addcell - find or create (col,row); in AX=col,BX=row;
; out CF=0 DI=offset (zeroed text offset if new), CF=1 table full
sh_nt_addcell:
    push ax
    push bx
    push cx
    push dx
    push si
    call sh_nt_findcell
    jc .found
    cmp word [sh_nnote], SH_NOTE_CAP
    jae .full
    push di
    mov ax, [sh_nnote]
    mov bx, SH_NOTE_REC
    mul bx
    mov cx, ax
    sub cx, di
    push ds
    push es
    mov dx, [sh_noteseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, ax
    dec si
    mov di, si
    add di, SH_NOTE_REC
    std
    rep movsb
    cld
.noshift:
    pop es
    pop ds
    pop di
    inc word [sh_nnote]
    push es
    mov es, [sh_noteseg]
    mov ax, [sh_frow]
    mov [es:di], ax
    mov ax, [sh_fcol]
    mov [es:di+2], ax
    mov word [es:di+4], 0
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

; sh_nt_removecell - in: AX=col, BX=row. Deleting a note orphans its text in
; the arena; see this table's header on why that is the existing behaviour.
sh_nt_removecell:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    call sh_nt_findcell
    jnc .out
    mov ax, [sh_nnote]
    mov bx, SH_NOTE_REC
    mul bx
    mov cx, ax
    sub cx, di
    sub cx, SH_NOTE_REC
    push ds
    push es
    mov dx, [sh_noteseg]
    mov ds, dx
    mov es, dx
    jcxz .noshift
    mov si, di
    add si, SH_NOTE_REC
    cld
    rep movsb
.noshift:
    pop es
    pop ds
    dec word [sh_nnote]
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; sh_nt_get - in: AX=col, BX=row; out: CF=1 and AX = the note text's offset
; in sh_txtseg; CF=0 and AX undefined if this cell has no note.
sh_nt_get:
    push bx
    push di
    push es
    call sh_nt_findcell
    jnc .none
    mov es, [sh_noteseg]
    mov ax, [es:di+4]
    pop es
    pop di
    pop bx
    stc
    ret
.none:
    pop es
    pop di
    pop bx
    clc
    ret

; sh_nt_set - attach the NUL string at DS:SI to (col,row).
; in: AX=col, BX=row, SI=the text. out: CF=1 = refused (table or arena full).
; An EMPTY string removes the note instead, which is how the dialog's OK
; button clears one - Excel's own Note dialog has no separate Delete.
sh_nt_set:
    push ax
    push bx
    push dx
    push di
    cmp byte [si], 0
    je .clear
    push ax
    push bx
    call sh_txt_append                  ; arena first: if IT has no room the
    jc .fail2                           ; table must not gain a record
    mov dx, ax                          ; dx = the text's arena offset
    pop bx
    pop ax
    call sh_nt_addcell
    jc .fail
    push es
    mov es, [sh_noteseg]
    mov [es:di+4], dx
    pop es
    clc
    jmp .out
.clear:
    call sh_nt_removecell
    clc
    jmp .out
.fail2:
    pop bx
    pop ax
.fail:
    stc
.out:
    pop di
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_rowcol_op - Insert or delete a whole row or column on the CURRENT
; sheet only. in: AL = 0 insert row / 1 delete row / 2 insert column /
; 3 delete column; BX = the row or column index the operation pivots on
; (the selected cell's own row/col - Edit menu Insert.../Delete... has no
; other way to name one, since there is no range selection - see the
; W_ONDRAG scope note above sh_docmd_edit).
;
; The cell array is sorted by (sheet, row) then col (see the stage 2.0
; comment above sh_findcell) - shifting a COLUMN can reorder cells WITHIN
; a row relative to their row-mates, which the sorted array's own binary
; search depends on getting right. Rather than hand-roll an in-place
; resort, this stages every record's (sheet, row, col, flags, format,
; value, formula_off) into sh_stgseg with the shift already applied (or
; marked dropped, if inserting pushes a row/col past the edge of the
; grid, or if it sits exactly on a deleted row/col), empties the whole
; array, then re-inserts every staged record through sh_addcell (which
; already keeps the array sorted on every insert, so re-insertion order
; doesn't matter). Formula TEXT is untouched - only the cell record's own
; formula_off is carried over as-is, so an existing formula's cell
; references are NOT relatively adjusted by this operation (same scope
; reasoning as sh_docmd_fillright/sh_docmd_sortcol); its cached value is
; simply left to go stale, since sh_addcell's own default pass=0 on the
; fresh record forces a re-evaluation on the next paint regardless.
; -----------------------------------------------------------------------------
sh_rowcol_op:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [sh_rc_op], al
    mov [sh_rc_idx], bx
    mov word [sh_rc_stgcnt], 0
    mov ax, [sh_cursheet]
    mov [sh_rc_savedsheet], ax
    xor cx, cx
.scan:
    cmp cx, [sh_ncells]
    jae .scandone
    mov ax, cx
    mov bx, SH_C_SZ
    mul bx
    mov si, ax
    mov es, [sh_cellseg]
    mov ax, [es:si]
    call sh_unpackrow                 ; ax=row, bx=sheet
    mov [sh_rc_trow], ax
    mov [sh_rc_tsheet], bx
    mov ax, [es:si+2]
    mov [sh_rc_tcol], ax
    mov al, [es:si+4]
    mov [sh_rc_tflags], al
    mov al, [es:si+5]
    mov [sh_rc_tfmt], al
    push di
    push cx
    mov di, sh_rc_tval
    mov cx, 4
.rcget:
    mov ax, [es:si+SH_C_VAL]
    mov [di], ax
    add si, 2
    add di, 2
    dec cx
    jnz .rcget
    sub si, 8
    pop cx
    pop di
    mov ax, [es:si+SH_C_FOFF]
    mov [sh_rc_tfml], ax
    mov ax, [sh_rc_tsheet]
    cmp ax, [sh_rc_savedsheet]
    jne .stage                        ; a different sheet: carried unchanged
    mov al, [sh_rc_op]
    cmp al, 0
    je .insrow
    cmp al, 1
    je .delrow
    cmp al, 2
    je .inscol
    jmp .delcol
.insrow:
    mov ax, [sh_rc_trow]
    cmp ax, [sh_rc_idx]
    jb .stage
    inc ax
    cmp ax, SH_ROWS
    jae .next                         ; pushed off the bottom: dropped
    mov [sh_rc_trow], ax
    jmp .stage
.delrow:
    mov ax, [sh_rc_trow]
    cmp ax, [sh_rc_idx]
    jb .stage
    je .next                          ; exactly the deleted row: dropped
    dec ax
    mov [sh_rc_trow], ax
    jmp .stage
.inscol:
    mov ax, [sh_rc_tcol]
    cmp ax, [sh_rc_idx]
    jb .stage
    inc ax
    cmp ax, SH_COLS
    jae .next
    mov [sh_rc_tcol], ax
    jmp .stage
.delcol:
    mov ax, [sh_rc_tcol]
    cmp ax, [sh_rc_idx]
    jb .stage
    je .next
    dec ax
    mov [sh_rc_tcol], ax
.stage:
    mov ax, [sh_rc_stgcnt]
    mov bx, SH_C_SZ
    mul bx
    mov di, ax
    mov es, [sh_stgseg]
    mov ax, [sh_rc_tsheet]
    mov [es:di], ax
    mov ax, [sh_rc_trow]
    mov [es:di+2], ax
    mov ax, [sh_rc_tcol]
    mov [es:di+4], ax
    mov al, [sh_rc_tflags]
    mov [es:di+SH_S_FLAGS], al        ; THE STAGING RECORD IS NOT THE CELL
    mov al, [sh_rc_tfmt]              ; RECORD. It is its own 12-byte layout in
    mov [es:di+SH_S_FMT], al          ; sh_stgseg and it did NOT widen with the
    mov ax, [sh_rc_tval]              ; cell array - which is precisely why
    mov [es:di+SH_S_VAL], ax          ; both are named now: converting this
    mov ax, [sh_rc_tfml]              ; block to the cell offsets by mistake
    mov [es:di+SH_S_FML], ax          ; was silent, and staged garbage
    inc word [sh_rc_stgcnt]
.next:
    inc cx
    jmp .scan
.scandone:
    mov word [sh_ncells], 0
    xor cx, cx
.reins:
    cmp cx, [sh_rc_stgcnt]
    jae .reinsdone
    mov ax, cx
    mov bx, SH_C_SZ
    mul bx
    mov si, ax
    mov es, [sh_stgseg]
    mov ax, [es:si]
    mov [sh_cursheet], ax             ; impersonate this record's own sheet
                                       ; so sh_addcell's sh_findcell packs
                                       ; it correctly (stage 2.0 comment
                                       ; above sh_findcell)
    mov ax, [es:si+2]
    mov [sh_rc_trow], ax
    mov ax, [es:si+4]
    mov [sh_rc_tcol], ax
    mov al, [es:si+SH_S_FLAGS]
    mov [sh_rc_tflags], al
    mov al, [es:si+SH_S_FMT]
    mov [sh_rc_tfmt], al
    push di
    push cx
    mov di, sh_rc_tval
    mov cx, 4
.rstval:
    mov ax, [es:si+SH_S_VAL]
    mov [di], ax
    add si, 2
    add di, 2
    dec cx
    jnz .rstval
    sub si, 8
    pop cx
    pop di
    mov ax, [es:si+SH_S_FML]
    mov [sh_rc_tfml], ax
    mov ax, [sh_rc_tcol]
    mov bx, [sh_rc_trow]
    call sh_addcell
    jc .reinsnext                     ; array full - can't happen (we only
                                       ; ever re-insert as many records as
                                       ; we removed minus drops), stay safe
    mov es, [sh_cellseg]
    mov al, [sh_rc_tflags]
    mov [es:di+4], al
    mov al, [sh_rc_tfmt]
    mov [es:di+5], al
    push si
    push cx
    mov si, sh_rc_tval
    mov cx, 4
.rcput:
    mov ax, [si]
    mov [es:di+SH_C_VAL], ax
    add si, 2
    add di, 2
    dec cx
    jnz .rcput
    sub di, 8
    pop cx
    pop si
    mov ax, [sh_rc_tfml]
    mov [es:di+SH_C_FOFF], ax
.reinsnext:
    inc cx
    jmp .reins
.reinsdone:
    mov ax, [sh_rc_savedsheet]
    mov [sh_cursheet], ax
    call sh_rowcol_reidx               ; stage 2.x: fix up every formula's
                                        ; own cell references for this same
                                        ; shift - see its own header comment
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; sh_rowcol_reidx and its helpers - stage 2.x: after sh_rowcol_op has
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
; run it through sh_formula_reidx (a character scanner - not a full
; parse/reserialize - that recognizes exactly the same token shapes the
; real formula grammar does: an optional "SheetN!" prefix, then 1-7
; letters immediately followed by digits is a cell reference; anything
; inside a double-quoted string, per ALERT's own argument, is copied
; byte-for-byte and never scanned), and if the text actually changed,
; appends the new text to the pool (formula text is append-only - see
; sh_setformula's own header comment - so an edit here is "append new,
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

; sh_isletter_at - in: SI; out: CF=1 if [SI] is A-Z or a-z (SI untouched)
sh_isletter_at:
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

; sh_rw_emit - in: AL = one byte; appends it to sh_rwdst at [sh_rw_di],
; clipping (silently dropping the byte) rather than overrunning the
; buffer - same "clip, don't refuse" policy ALERT's own message copy uses.
;
; The clip is at SH_EDITMAX, NOT at sh_rwdst's own SH_RW_CAP size: every
; consumer of a rewritten formula assumes formula text fits the same
; SH_EDITMAX+1 = 64 bytes a typed formula does - sh_eval_cell's own
; per-recursion-level sh_fbuf slot, sh_beginedit's sh_editbuf,
; sh_docmd_copy's sh_clipbuf, and sh_drawbar's sh_tbuf+16 span are all
; exactly that size. A shift CAN legitimately grow text (row 9 -> 10,
; column Z -> AA), so the extra SH_RW_CAP slack is real working room; but
; letting the RESULT exceed SH_EDITMAX would overrun all four of those
; downstream buffers (sh_setformula/sh_txt_append only bound against the
; whole pool, not against 64), so growth past the cap is dropped here at
; the single choke point every rewriter shares rather than re-checked at
; each of the five call sites.
sh_rw_emit:
    push bx
    push di
    mov bx, [sh_rw_di]
    cmp bx, SH_EDITMAX
    jae .full
    mov di, sh_rwdst
    add di, bx
    mov [di], al
    inc bx
    mov [sh_rw_di], bx
.full:
    pop di
    pop bx
    ret

; sh_txt_append - in: DS:SI = NUL-terminated text (no leading '=');
; out: CF=0 and AX = its new offset in the text pool, or CF=1 if there is
; no room (the pool is left unchanged either way)
sh_txt_append:
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
    mov ax, [sh_txtlen]
    add ax, cx
    inc ax
    cmp ax, SH_TXT_CAP
    ja .noroom
    mov es, [sh_txtseg]
    mov di, [sh_txtlen]
    mov ax, di
    push ax
.copy:
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    or al, al
    jnz .copy
    mov [sh_txtlen], di
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

; sh_reidx_shift - in: AX = a reference's original 0-based row or col,
; BX = the pivot, [sh_rw_op] = sh_rowcol_op's own AL (0 ins-row/1 del-row/
; 2 ins-col/3 del-col); out: AX = the adjusted index
sh_reidx_shift:
    push cx
    push dx
    mov dl, [sh_rw_op]
    test dl, 1
    jnz .delete
    cmp ax, bx
    jb .out
    inc ax
    mov cx, SH_ROWS                    ; clamp at the grid edge rather than
    cmp dl, 2                          ; letting an insert push a reference
    jb .havecap                        ; past it - a row 16384 reference
    mov cx, SH_COLS                    ; shifted down would otherwise be
.havecap:                              ; written as "A16385", which
    cmp ax, cx                         ; sh_pident then resolves wrongly.
    jb .out                            ; (The cell it names is genuinely
    mov ax, cx                         ; gone; naming the last real row is
    dec ax                             ; the same "closest sane fallback"
    jmp .out                           ; the delete branch below already
.delete:                               ; uses for a reference ON the pivot.)
    cmp ax, bx
    jbe .out                           ; < pivot: untouched; == pivot:
                                        ; clamped (see the header comment)
    dec ax
.out:
    pop dx
    pop cx
    ret

; sh_reidx_apply - in: [sh_rw_refcol]/[sh_rw_refrow] = the reference as
; parsed, [sh_rw_ostart]/[sh_rw_lettersend]/[sh_rw_refend] = its own text
; spans, [sh_rw_op]/[sh_rw_pivot] = the shift; emits the adjusted
; reference (only the axis [sh_rw_op] actually operates on is
; recomputed - the other axis's ORIGINAL text is copied verbatim, so a
; row-only shift never touches a column's own case/spelling)
sh_reidx_apply:
    push ax
    push bx
    mov al, [sh_rw_op]
    cmp al, 2
    jae .colop
    mov ax, [sh_rw_refrow]             ; INSERT/DELETE SHIFTS AN ABSOLUTE
    mov bx, [sh_rw_pivot]              ; REFERENCE TOO, and that is not an
    call sh_reidx_shift                ; oversight. '$' means "do not adjust
    mov [sh_rw_refrow], ax             ; when this formula is COPIED"; it does
.rowletcopy:                           ; not mean "keep pointing at row 1 no
                                       ; matter what". Inserting a row above
                                       ; physically moves the referenced cell
                                       ; down, so every reference to it must
                                       ; follow or it silently starts naming
                                       ; different data - '$A$1' becomes
                                       ; '$A$2', exactly as Excel does. The
                                       ; markers are preserved below; only the
                                       ; index moves.
    mov bx, [sh_rw_ostart]             ; ostart is before any '$', so this
.rowletloop:                           ; copy carries the column's marker
    cmp bx, [sh_rw_lettersend]
    jae .rowdigits
    mov al, [bx]
    call sh_rw_emit
    inc bx
    jmp .rowletloop
.rowdigits:
    cmp byte [sh_rw_absr], 0           ; put the row's own '$' back
    je .rownodollar
    mov al, '$'
    call sh_rw_emit
.rownodollar:
    mov ax, [sh_rw_refrow]
    inc ax                             ; back to 1-based display text
    call sh_itoa
    mov bx, sh_numbuf
.rowdigemit:
    mov al, [bx]
    or al, al
    jz .out
    call sh_rw_emit
    inc bx
    jmp .rowdigemit
.colop:
    mov ax, [sh_rw_refcol]             ; same rule for a column insert/delete
    mov bx, [sh_rw_pivot]              ; as for a row - see .rowletcopy above
    call sh_reidx_shift
    mov [sh_rw_refcol], ax
.colemitstart:
    cmp byte [sh_rw_absc], 0           ; the letters are REGENERATED here, so
    je .colnodollar                    ; the marker has to be re-emitted
    mov al, '$'
    call sh_rw_emit
.colnodollar:
    mov ax, [sh_rw_refcol]
    call sh_colname
    mov bx, sh_colbuf
.colemit:
    mov al, [bx]
    or al, al
    jz .coldigits
    call sh_rw_emit
    inc bx
    jmp .colemit
.coldigits:
    mov bx, [sh_rw_lettersend]
.coldigcopy:
    cmp bx, [sh_rw_refend]
    jae .out
    mov al, [bx]
    call sh_rw_emit
    inc bx
    jmp .coldigcopy
.out:
    pop bx
    pop ax
    ret

; sh_reidx_cellpart - in: SI at a cell reference's first letter (the
; caller has already confirmed one is there via sh_isletter_at), DL = 1
; adjust this reference (it is known to name the sheet being shifted) or
; 0 leave it exactly as written; out: SI advanced past the whole
; reference (letters and, if any followed, digits) and the reference (or
; the bare word, if a letter run here turns out NOT to be followed by a
; digit - a function name, not a cell reference) emitted to sh_rwdst
; either verbatim or adjusted
sh_reidx_cellpart:
    push ax
    push bx
    push cx
    push dx
    push di
    mov [sh_rw_adj], dl
    mov [sh_rw_ostart], si
    mov byte [sh_rw_absc], 0           ; stage 3.0e: '$' before the letters
    mov byte [sh_rw_absr], 0           ; pins the COLUMN, '$' before the
    cmp byte [si], '$'                 ; digits pins the ROW
    jne .nocoldollar
    mov byte [sh_rw_absc], 1
    inc si
.nocoldollar:
    mov di, sh_ident
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
    mov [sh_rw_lettersend], si
    cmp byte [si], '$'
    jne .norowdollar
    mov byte [sh_rw_absr], 1
    inc si
.norowdollar:
    mov al, [si]
    cmp al, '0'
    jb .notref
    cmp al, '9'
    ja .notref
    call sh_identcol                   ; ax = 0-based col (from sh_ident)
    mov [sh_rw_refcol], ax
    mov bx, si
    add bx, SH_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call sh_pint                       ; ax = 1-based row text; si advances
    pop es
    dec ax                             ; ax = 0-based row
    mov [sh_rw_refrow], ax
    mov [sh_rw_refend], si
    cmp byte [sh_rw_adj], 0
    je .verbatim
    call sh_reidx_apply
    jmp .out
.verbatim:
    mov bx, [sh_rw_ostart]
.vcopy:
    cmp bx, si
    jae .out
    mov al, [bx]
    call sh_rw_emit
    inc bx
    jmp .vcopy
.notref:
    mov bx, [sh_rw_ostart]
.wcopy:
    cmp bx, si
    jae .out
    mov al, [bx]
    call sh_rw_emit
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
; Both directions reuse sh_formula_reidx's scanner shape: walk the text, copy
; everything that is not a reference verbatim, and transform the references.
; A quoted string is passed through untouched, as it is there.
;
; THE CROSS-SHEET PREFIX IS AN EXTENSION. SYLK has no notion of a second sheet
; - it is a single-grid format - so "Sheet2!" is written through verbatim. It
; round-trips within this app and means nothing to anything else, which is the
; honest position: the alternative is silently dropping the reference.
; =============================================================================

; sh_emit_num - AX as signed decimal, into sh_rwdst via sh_rw_emit
sh_emit_num:
    push ax
    push bx
    call sh_itoa
    mov bx, sh_numbuf
.e:
    mov al, [bx]
    or al, al
    jz .o
    call sh_rw_emit
    inc bx
    jmp .e
.o:
    pop bx
    pop ax
    ret

; sh_emit_rc - one R or C part. in: AL = 'R' or 'C', BX = the value,
; CL = 0 relative (bracketed offset, omitted entirely when zero) or 1 absolute
; (a bare 1-based index).
sh_emit_rc:
    push ax
    push bx
    call sh_rw_emit                   ; the letter itself
    or cl, cl
    jnz .abs
    or bx, bx
    jz .out                           ; a zero offset is written as nothing:
    mov al, '['                       ; "RC" means "this row, this column"
    call sh_rw_emit
    mov ax, bx
    call sh_emit_num
    mov al, ']'
    call sh_rw_emit
    jmp .out
.abs:
    mov ax, bx
    inc ax                            ; absolute parts are 1-based
    call sh_emit_num
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_formula_to_r1c1 - in: SI = A1-form formula text (no leading '='),
; [sh_rc_ccol]/[sh_rc_crow] = the cell that owns it.
; out: sh_rwdst holds the R1C1 form, [sh_rw_di] its length.
; -----------------------------------------------------------------------------
sh_formula_to_r1c1:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [sh_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    call sh_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    call sh_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    call sh_isletter_at
    jnc .literal
    mov [sh_rw_ostart], si
    call sh_psheetpfx
    jnc .noxsheet
    mov si, [sh_rw_ostart]            ; the prefix goes through verbatim
    mov bx, 7
.pfx:
    mov al, [si]
    call sh_rw_emit
    inc si
    dec bx
    jnz .pfx
    mov [sh_rw_ostart], si
.noxsheet:
    call sh_reidx_cellpart_probe      ; is this really a reference?
    jc .isref
    mov si, [sh_rw_ostart]            ; no: a function name or a bare word
.word:
    call sh_isletter_at
    jnc .loop
    mov al, [si]
    call sh_rw_emit
    inc si
    jmp .word
.isref:
    mov al, 'R'                       ; ...the row part
    mov bx, [sh_rw_refrow]
    mov cl, [sh_rw_absr]
    or cl, cl
    jnz .rowabs
    sub bx, [sh_rc_crow]              ; relative: an offset from this cell
.rowabs:
    call sh_emit_rc
    mov al, 'C'                       ; ...and the column part
    mov bx, [sh_rw_refcol]
    mov cl, [sh_rw_absc]
    or cl, cl
    jnz .colabs
    sub bx, [sh_rc_ccol]
.colabs:
    call sh_emit_rc
    jmp .loop
.literal:
    mov al, [si]
    call sh_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [sh_rw_di]
    mov byte [sh_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; sh_reidx_cellpart_probe - SI at a possible reference. Fills sh_rw_refcol/
; refrow/absc/absr and returns CF=1 with SI past it. CF=0 means the letters
; were NOT followed by a row number (a function name, say) - SI is left where
; the scan stopped, and the caller rewinds it from sh_rw_ostart, which is the
; same contract sh_reidx_cellpart works to.
sh_reidx_cellpart_probe:
    push ax
    push cx
    push di
    mov di, sh_ident
    xor cx, cx
    mov byte [sh_rw_absc], 0
    mov byte [sh_rw_absr], 0
    cmp byte [si], '$'
    jne .nc
    mov byte [sh_rw_absc], 1
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
    mov byte [sh_rw_absr], 1
    inc si
.nr:
    mov al, [si]
    cmp al, '0'
    jb .no
    cmp al, '9'
    ja .no
    call sh_identcol
    mov [sh_rw_refcol], ax
    push bx
    mov bx, si
    add bx, SH_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call sh_pint
    pop es
    pop bx
    dec ax
    mov [sh_rw_refrow], ax
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
; sh_formula_from_r1c1 - in: SI = R1C1-form text, [sh_rc_ccol]/[sh_rc_crow] =
; the cell that owns it. out: sh_rwdst holds the A1 form, NUL-terminated.
;
; The inverse of the above. A reference starts at an 'R' that is followed by
; '[', a digit, '-' or 'C' - which is what tells "R[-1]C" apart from a function
; name beginning with R, and the reason this looks one character further ahead
; than the A1 scanner needs to.
; -----------------------------------------------------------------------------
sh_formula_from_r1c1:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [sh_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    call sh_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    call sh_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    mov al, [si]
    and al, 0xDF
    cmp al, 'R'
    jne .literal
    mov [sh_rw_ostart], si
    inc si
    call sh_read_rc                   ; -> BX = value, CL = 1 if absolute
    jc .notref
    mov [sh_rw_refrow], bx
    mov [sh_rw_absr], cl
    mov al, [si]
    and al, 0xDF
    cmp al, 'C'
    jne .notref
    inc si
    call sh_read_rc
    jc .notref
    mov [sh_rw_refcol], bx
    mov [sh_rw_absc], cl
    ; --- emit it as A1 ---
    cmp byte [sh_rw_absc], 0
    je .colrel
    mov al, '$'
    call sh_rw_emit
    jmp .colemit
.colrel:
    mov ax, [sh_rw_refcol]
    add ax, [sh_rc_ccol]
    mov [sh_rw_refcol], ax
.colemit:
    mov ax, [sh_rw_refcol]
    call sh_colname
    mov bx, sh_colbuf
.cl:
    mov al, [bx]
    or al, al
    jz .rowpart
    call sh_rw_emit
    inc bx
    jmp .cl
.rowpart:
    cmp byte [sh_rw_absr], 0
    je .rowrel
    mov al, '$'
    call sh_rw_emit
    jmp .rowemit
.rowrel:
    mov ax, [sh_rw_refrow]
    add ax, [sh_rc_crow]
    mov [sh_rw_refrow], ax
.rowemit:
    mov ax, [sh_rw_refrow]
    inc ax                            ; back to the 1-based display row
    call sh_emit_num
    jmp .loop
.notref:
    mov si, [sh_rw_ostart]            ; not a reference after all: the 'R' and
    mov al, [si]                      ; whatever follows go through as text
    call sh_rw_emit
    inc si
    jmp .loop
.literal:
    mov al, [si]
    call sh_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [sh_rw_di]
    mov byte [sh_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; sh_read_rc - SI just past an 'R' or 'C'. out: BX = the value (a signed offset
; when relative, a 0-based index when absolute), CL = 1 if absolute, SI
; advanced. CF=1 if what follows is neither a bracket nor a digit.
sh_read_rc:
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
    call sh_read_int
    dec bx                            ; absolute parts are 1-based on the wire
    jmp .ok
.rel:
    inc si
    call sh_read_int                  ; the bracketed offset, sign and all
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

; sh_read_int - a signed decimal at SI into BX; SI advanced. Used only by the
; R1C1 reader, where the number is known to be short.
sh_read_int:
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

; sh_formula_reidx - in: SI = source formula text (DS-resident, NUL-
; terminated, no leading '='); [sh_rw_op]/[sh_rw_pivot]/[sh_rw_tsheet]/
; [sh_rw_home] already set by the caller (sh_rowcol_reidx). Out:
; sh_rwdst holds the rewritten, NUL-terminated text, [sh_rw_di] = its
; length. See the section header comment above for the token rules.
sh_formula_reidx:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [sh_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    call sh_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    call sh_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    call sh_isletter_at
    jnc .literal
    mov [sh_rw_ostart], si
    call sh_psheetpfx
    jnc .noxsheet
    mov cx, ax                         ; cx = the sheet the prefix names
    call sh_isletter_at
    jc .pfxisref
    mov si, [sh_rw_ostart]             ; "SheetN!" not actually followed by
    mov bx, 7                          ; a reference: emit the 7 prefix
.pfxverb:                              ; bytes VERBATIM and carry on.
    mov al, [si]                       ; sh_psheetpfx has already advanced
    call sh_rw_emit                    ; SI past them, so just jumping back
    inc si                             ; to .loop (as this did before) threw
    dec bx                             ; them away - silently deleting the
    jnz .pfxverb                       ; "SHEET2!" from the rewritten text
    jmp .loop
.pfxisref:
    mov si, [sh_rw_ostart]
    mov bx, 7                          ; "SHEET" + one digit + "!" always
.copypfx:
    mov al, [si]
    call sh_rw_emit
    inc si
    dec bx
    jnz .copypfx
    cmp cx, [sh_rw_tsheet]
    jne .pfxnoadj
    mov dl, 1
    jmp .pfxgo
.pfxnoadj:
    mov dl, 0
.pfxgo:
    call sh_reidx_cellpart
    jmp .loop
.noxsheet:
    mov dl, [sh_rw_home]
    call sh_reidx_cellpart
    jmp .loop
.literal:
    mov al, [si]
    call sh_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [sh_rw_di]
    mov byte [sh_rwdst + bx], 0
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; sh_rowcol_reidx - the driver: walk every cell, and for each formula
; cell, run its text through sh_formula_reidx and repoint its
; formula_off if the text actually changed. [sh_rc_op]/[sh_rc_idx] are
; still exactly what sh_rowcol_op's caller passed (untouched since
; entry); [sh_cursheet] has just been restored to the sheet this whole
; operation acted on.
sh_rowcol_reidx:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov ax, [sh_cursheet]
    mov [sh_rw_tsheet], ax
    mov al, [sh_rc_op]
    mov [sh_rw_op], al
    mov ax, [sh_rc_idx]
    mov [sh_rw_pivot], ax
    xor cx, cx
.scan:
    cmp cx, [sh_ncells]
    jae .done
    mov ax, cx
    mov bx, SH_C_SZ
    mul bx
    mov [sh_rw_recdi], ax
    mov si, ax
    mov es, [sh_cellseg]
    test byte [es:si+4], 1             ; HASFORMULA
    jz .next
    mov ax, [es:si]
    call sh_unpackrow                  ; bx = this record's own sheet
    mov byte [sh_rw_home], 0
    cmp bx, [sh_rw_tsheet]
    jne .gothome
    mov byte [sh_rw_home], 1
.gothome:
    mov si, [sh_rw_recdi]
    mov ax, [es:si+SH_C_FOFF]          ; formula_off
    mov si, ax
    mov es, [sh_txtseg]
    mov di, sh_rwsrc
.copyin:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    mov si, sh_rwsrc
    call sh_formula_reidx
    mov si, sh_rwsrc
    mov di, sh_rwdst
    call sh_streq                      ; CF=1 if identical
    jc .next                           ; unchanged: nothing to do
    mov si, sh_rwdst
    call sh_txt_append
    jc .next                           ; no room left: leave the stale
                                        ; (still valid, just unshifted)
                                        ; text in place rather than losing
                                        ; the formula entirely
    mov es, [sh_cellseg]
    mov di, [sh_rw_recdi]
    mov [es:di+SH_C_FOFF], ax
    mov word [es:di+SH_C_PASS], 0xFFFF        ; force re-evaluation
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
; report). sh_docmd_copy already remembers WHERE it copied from
; (sh_clip_col/sh_clip_row/sh_clip_valid, set below); sh_docmd_paste uses
; that plus its own destination (sh_selcol/sh_selrow) to compute a
; constant (col, row) delta and runs the copied formula's text through
; sh_formula_copyshift before handing it to sh_commit - the same "copy a
; formula, keep the cell it landed in" behavior every other spreadsheet's
; own default (non-absolute) reference already has.
;
; This reuses sh_rowcol_reidx's own low-level pieces (sh_isletter_at,
; sh_rw_emit, sh_rwsrc/sh_rwdst/sh_rw_di, sh_psheetpfx/sh_identcol/
; sh_colname/sh_pint/sh_itoa) but is otherwise a SEPARATE top-level scan,
; not a generalization of sh_formula_reidx: an Insert/Delete Row/Column
; shift only ever touches ONE axis (row XOR column) and only for
; references at or past a pivot; a copy/paste shift touches BOTH axes
; unconditionally by a fixed delta (pasting diagonally moves a reference
; diagonally too) and has no pivot or target-sheet concept at all - every
; reference in the formula, bare or "SheetN!"-prefixed alike, shifts by
; the exact same delta, matching real Excel's own relative-reference
; behavor when copying between sheets (the sheet name itself never
; changes, only the cell part does).
;
; sh_clip_valid is this instance's own memory of "the last thing *I*
; copied, and from where" - the real clipboard (OSAPI_CLIP_PUT/GET) is
; plain bytes with no provenance, so if something else overwrites it
; between the Copy and the Paste (a different app, or a different Sheet
; instance), a resulting paste here would only misfire if that unrelated
; text ALSO happens to start with '=' - accepted as a known, low-
; probability edge case rather than something worth adding real
; clipboard versioning for.
; =============================================================================

; sh_copy_shift - in: AX = a reference's original 0-based index, BX =
; the signed delta (sh_cp_coldelta or sh_cp_rowdelta), CX = that axis's
; cap (SH_COLS or SH_ROWS); out: AX = adjusted index, clamped to
; [0, CX-1] rather than allowed to go negative or off the grid - this
; project has no error-value concept anywhere (RK's unsupported subtype
; and division by zero both degrade the same "closest sane fallback,
; never crash" way)
sh_copy_shift:
    add ax, bx
    jns .nonneg
    xor ax, ax
    jmp .out
.nonneg:
    cmp ax, cx
    jb .out
    mov ax, cx
    dec ax
.out:
    ret

; sh_copy_cellpart - in: SI at a cell reference's first letter (the
; caller has already confirmed one is there via sh_isletter_at); out: SI
; advanced past the whole reference (letters and, if any followed,
; digits), and the reference emitted to sh_rwdst with BOTH its column
; and row shifted by [sh_cp_coldelta]/[sh_cp_rowdelta] - or, if this
; letter run turns out not to be followed by a digit (a function name,
; not a cell reference), the bare word emitted verbatim instead
sh_copy_cellpart:
    push ax
    push bx
    push cx
    push di
    mov [sh_cp_ostart], si
    mov byte [sh_cp_absc], 0           ; stage 3.0e: see sh_rw_absc
    mov byte [sh_cp_absr], 0
    cmp byte [si], '$'
    jne .nocoldollar
    mov byte [sh_cp_absc], 1
    inc si
.nocoldollar:
    mov di, sh_ident
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
    mov [sh_cp_lettersend], si
    cmp byte [si], '$'
    jne .norowdollar
    mov byte [sh_cp_absr], 1
    inc si
.norowdollar:
    mov al, [si]
    cmp al, '0'
    jb .notref
    cmp al, '9'
    ja .notref
    call sh_identcol                   ; ax = 0-based col (from sh_ident)
    cmp byte [sh_cp_absc], 0           ; a pinned column does not follow the
    jne .colpinned                     ; paste's own displacement
    mov bx, [sh_cp_coldelta]
    mov cx, SH_COLS
    call sh_copy_shift
.colpinned:
    mov [sh_cp_refcol], ax
    mov bx, si
    add bx, SH_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call sh_pint                       ; ax = 1-based row text; si advances
    pop es
    dec ax                             ; ax = 0-based row
    cmp byte [sh_cp_absr], 0
    jne .rowpinned
    mov bx, [sh_cp_rowdelta]
    mov cx, SH_ROWS
    call sh_copy_shift
.rowpinned:
    mov [sh_cp_refrow], ax
    mov [sh_cp_refend], si
    cmp byte [sh_cp_absc], 0           ; both halves are REGENERATED below, so
    je .cpnocoldollar                  ; both markers have to be re-emitted
    mov al, '$'
    call sh_rw_emit
.cpnocoldollar:
    mov ax, [sh_cp_refcol]
    call sh_colname
    mov bx, sh_colbuf
.colemit:
    mov al, [bx]
    or al, al
    jz .rowdigits
    call sh_rw_emit
    inc bx
    jmp .colemit
.rowdigits:
    cmp byte [sh_cp_absr], 0
    je .cpnorowdollar
    mov al, '$'
    call sh_rw_emit
.cpnorowdollar:
    mov ax, [sh_cp_refrow]
    inc ax                             ; back to 1-based display text
    call sh_itoa
    mov bx, sh_numbuf
.rowdigemit:
    mov al, [bx]
    or al, al
    jz .out
    call sh_rw_emit
    inc bx
    jmp .rowdigemit
.notref:
    mov bx, [sh_cp_ostart]
.wcopy:
    cmp bx, si
    jae .out
    mov al, [bx]
    call sh_rw_emit
    inc bx
    jmp .wcopy
.out:
    pop di
    pop cx
    pop bx
    pop ax
    ret

; sh_formula_copyshift - in: SI = source formula text (DS-resident, NUL-
; terminated, no leading '='); [sh_cp_coldelta]/[sh_cp_rowdelta] already
; set by the caller (sh_docmd_paste). Out: sh_rwdst holds the shifted,
; NUL-terminated text, [sh_rw_di] = its length. Same token-recognition
; and quoted-string-is-verbatim rules as sh_formula_reidx (see that
; proc's own header comment for why a character scan, not a re-parse, is
; both sufficient and safe here).
sh_formula_copyshift:
    push ax
    push bx
    push si
    mov word [sh_rw_di], 0
.loop:
    mov al, [si]
    or al, al
    jz .done
    cmp al, '"'
    jne .tryref
    call sh_rw_emit
    inc si
.instr:
    mov al, [si]
    or al, al
    jz .done
    call sh_rw_emit
    inc si
    cmp al, '"'
    jne .instr
    jmp .loop
.tryref:
    call sh_isletter_at
    jnc .literal
    mov [sh_cp_ostart], si
    call sh_psheetpfx
    jnc .noxsheet
    call sh_isletter_at
    jc .pfxisref
    mov si, [sh_cp_ostart]             ; "SheetN!" not actually followed by
    mov bx, 7                          ; a reference: emit the 7 prefix
.pfxverb:                              ; bytes VERBATIM rather than letting
    mov al, [si]                       ; them be silently deleted (see the
    call sh_rw_emit                    ; matching fix in sh_formula_reidx)
    inc si
    dec bx
    jnz .pfxverb
    jmp .loop
.pfxisref:
    mov si, [sh_cp_ostart]
    mov bx, 7                          ; "SHEET" + one digit + "!" always
.copypfx:
    mov al, [si]
    call sh_rw_emit
    inc si
    dec bx
    jnz .copypfx
    call sh_copy_cellpart              ; the sheet name itself never
    jmp .loop                          ; shifts - only the cell part does
.noxsheet:
    call sh_copy_cellpart
    jmp .loop
.literal:
    mov al, [si]
    call sh_rw_emit
    inc si
    jmp .loop
.done:
    mov bx, [sh_rw_di]
    mov byte [sh_rwdst + bx], 0
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_getcell2 - in: AX=col, BX=row; out: CF=1 occupied + DX=value, CF=0 empty.
; Also always sets [sh_curfmt] to the cell's format byte (0 if empty) -
; a side channel the drawing code reads, since none of this proc's other
; callers (SYLK/DIF/BIFF export, range folding) care about it.
; -----------------------------------------------------------------------------
sh_getcell2:
    push ax
    push bx
    push di
    call sh_findcell
    jnc .empty
    push es
    mov es, [sh_cellseg]
    mov al, [es:di+5]
    mov [sh_curfmt], al
    test byte [es:di+4], 1            ; HASFORMULA
    jz .plain
    pop es
    call sh_eval_cell                 ; leaves the full result in sh_acc, and
    stc                               ; DX as its truncated form
    jmp .out
.plain:
    push si                           ; stage 4.0: the stored value is a full
    push cx                           ; double, so it comes out into sh_acc.
    mov si, sh_acc                    ; DX stays the truncated integer for the
    mov cx, 4                         ; callers that still want one.
.pcopy:
    mov ax, [es:di+SH_C_VAL]
    mov [si], ax
    add di, 2
    add si, 2
    dec cx
    jnz .pcopy
    pop cx
    pop si
    pop es
    call sh_acc_toint
    mov dx, ax
    stc
    jmp .out
.empty:
    mov byte [sh_curfmt], 0
    push ax                           ; an empty cell is a zero value, and
    xor ax, ax                        ; sh_acc must say so rather than keeping
    call sh_acc_int                   ; whatever the last cell left there
    pop ax
    clc
.out:
    pop di
    pop bx
    pop ax
    ret

; =============================================================================
; The value accumulator (stage 4.0). The evaluator's working value is a double
; in sh_acc, not an integer in AX - a double does not fit a register, so it
; lives in memory and the machine stack carries a binary operator's left
; operand across the parse of its right.
;
; The INTEGER entry points below are kept as converting wrappers rather than
; being deleted. Roughly forty callers pass values as words - file readers,
; the chart scan, sort, fill, the macro engine - and converting them all in
; one change would have made a fault impossible to localise. They convert at
; the boundary and are correct for any value an integer can hold.
; =============================================================================

; sh_acc_store - pack the fp A accumulator into sh_acc
sh_acc_store:
    push di
    mov di, sh_acc
    call fp_pack_a
    pop di
    ret

; sh_acc_load_a - unpack sh_acc into fp A
sh_acc_load_a:
    push si
    mov si, sh_acc
    call fp_unpack_a
    pop si
    ret

; sh_acc_load_b - unpack sh_acc into fp B
sh_acc_load_b:
    push si
    mov si, sh_acc
    call fp_unpack_b
    pop si
    ret

; sh_acc_int - AX (signed) -> sh_acc
sh_acc_int:
    call fp_i2a
    call sh_acc_store
    ret

; sh_acc_toint - sh_acc -> AX (signed, truncated); CF=1 if it did not fit
sh_acc_toint:
    call sh_acc_load_a
    call fp_a2i
    ret

; sh_vpush - bank sh_acc on the machine stack. CLOBBERS AX (the return address
; goes through it), which is safe because the evaluator's value now lives in
; sh_acc rather than in a register.
sh_vpush:
    pop ax
    push word [sh_acc+6]
    push word [sh_acc+4]
    push word [sh_acc+2]
    push word [sh_acc]
    push ax
    ret

; sh_binop_pre - recover a banked left operand into fp A and load sh_acc, the
; right operand, into fp B. Pairs with exactly one sh_vpush.
sh_binop_pre:
    pop ax
    pop word [sh_lhs]
    pop word [sh_lhs+2]
    pop word [sh_lhs+4]
    pop word [sh_lhs+6]
    push ax
    push si
    mov si, sh_lhs
    call fp_unpack_a
    pop si
    call sh_acc_load_b
    ret

; -----------------------------------------------------------------------------
; sh_setvald - in: AX=col, BX=row; the value is sh_acc.
; -----------------------------------------------------------------------------
sh_setvald:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    call sh_addcell
    jc .dfull
    push es
    mov es, [sh_cellseg]
    mov byte [es:di+4], 0             ; a plain value has no formula
    mov byte [es:di+SH_C_TYPE], SH_T_NUM
    mov si, sh_acc                    ; all EIGHT bytes of it
    mov cx, 4
.dcopy:
    mov ax, [si]
    mov [es:di+SH_C_VAL], ax
    add si, 2
    add di, 2
    dec cx
    jnz .dcopy
    pop es
.dfull:
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_setval - in: AX=col, BX=row, DX=value. The integer wrapper (see above).
; -----------------------------------------------------------------------------
sh_setval:
    push ax
    push bx
    push dx
    push di
    push ax                           ; the column, across the conversion -
    mov ax, dx                        ; fp_i2a takes its integer in AX
    call sh_acc_int
    pop ax
    call sh_setvald
    pop di
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_setformula - in: AX=col, BX=row, SI=formula text (DS-resident,
; NUL-terminated, NOT including the leading '=')
; -----------------------------------------------------------------------------
sh_setformula:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [sh_fcol], ax
    mov [sh_frow], bx
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
    mov ax, [sh_txtlen]
    add ax, cx
    inc ax                            ; +1 for the NUL this stores too
    cmp ax, SH_TXT_CAP
    ja .noroom
    mov es, [sh_txtseg]
    mov di, [sh_txtlen]
    mov [sh_newoff], di               ; where THIS formula starts
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    mov [sh_txtlen], di
    mov ax, [sh_fcol]
    mov bx, [sh_frow]
    call sh_addcell
    jc .noroom
    push es
    mov es, [sh_cellseg]
    mov byte [es:di+4], 1             ; HASFORMULA
    mov ax, [sh_newoff]
    mov [es:di+SH_C_FOFF], ax
    mov word [es:di+SH_C_PASS], 0xFFFF       ; a pass stamp sh_pass can never equal,
                                       ; forcing at least one real evaluation
    pop es
.noroom:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_eval_cell - evaluate a formula cell, with cycle detection and
; per-repaint memoization
; in: DI = record offset (a HASFORMULA record); ES = sh_cellseg
; out: DX = value; the record's cached value and pass stamp are updated
; -----------------------------------------------------------------------------
sh_eval_cell:
    push ax
    push bx
    push si
    push di
    push es
    mov es, [sh_cellseg]
    mov ax, [es:di+SH_C_PASS]                ; this cell's last-computed pass
    cmp ax, [sh_pass]
    jne .stale
    test byte [es:di+4], 2            ; EVALUATING - already mid-computation
    jnz .cycle                        ; means a cycle, not a cache hit
    call sh_cellval_to_acc            ; a cache hit is a full double now, not
    call sh_acc_toint                 ; a word; DX stays the truncated form
    mov dx, ax                        ; for the callers that still want one
    jmp .out
.stale:
    test byte [es:di+4], 2
    jnz .cycle
    or byte [es:di+4], 2              ; EVALUATING = 1
    push di                           ; this cell's record offset, kept on
                                       ; the stack (NOT a global) because
                                       ; evaluating this formula may recurse
                                       ; into sh_eval_cell again for a cell
                                       ; it references, and call/ret through
                                       ; sh_pexpr is stack-neutral either way
    push word [sh_evrow]              ; stage 3.0d: ROW()/COLUMN()'s context,
    push word [sh_evcol]              ; banked for the SAME reason and popped
    mov ax, [es:di]                   ; at .writeback. A referenced cell's own
    and ax, SH_ROW_MASK               ; formula must answer for ITSELF, so this
    mov [sh_evrow], ax                ; is per-frame, not set once
    mov ax, [es:di+2]
    mov [sh_evcol], ax
    mov ax, [es:di+SH_C_FOFF]                 ; formula_off
    mov si, ax
    mov es, [sh_txtseg]
    cmp word [sh_evaldepth], SH_EVAL_MAXDEPTH
    jae .toodeep
    mov bx, [sh_evaldepth]
    inc word [sh_evaldepth]
    push bx                           ; this recursion level's buffer slot
    mov ax, SH_EDITMAX + 1
    mul bx
    add ax, sh_fbuf
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
    call sh_pcmp                      ; the result lands in sh_acc, and may
    pop bx                            ; have recursed to get there
    dec word [sh_evaldepth]
    jmp .writeback
.toodeep:
    xor dx, dx
    push ax
    xor ax, ax
    call sh_acc_int                   ; too deep is a zero, in both forms
    pop ax
.writeback:
    pop word [sh_evcol]               ; stage 3.0d: ROW()/COLUMN() context,
    pop word [sh_evrow]               ; restored in the order it was pushed
    pop di                            ; this cell's record offset, restored
    mov es, [sh_cellseg]
    and byte [es:di+4], 0xFD          ; EVALUATING = 0 (HASFORMULA untouched)
    call sh_acc_to_cellval            ; cache the whole double
    call sh_acc_toint
    mov dx, ax
    mov ax, [sh_pass]
    mov [es:di+SH_C_PASS], ax
    jmp .out
.cycle:
    xor dx, dx
    push ax
    xor ax, ax
    call sh_acc_int                   ; a cycle is a zero, in both forms
    pop ax
.out:
    pop es
    pop di
    pop si
    pop bx
    pop ax
    ret

; =============================================================================
; Formula parser/evaluator - recursive descent over sh_fbuf (a DS-resident
; copy of the formula text; see sh_eval_cell). Grammar:
;   expr   := term (('+'|'-') term)*
;   term   := pow (('*'|'/') pow)*
;   pow    := factor ('^' pow)?            ; right-associative (stage 3.0d)
;   factor := '-' factor | '(' expr ')' | NUMBER | CELLREF | NAME '(' args ')'
;   args   := arg (',' arg)*
;   arg    := CELLREF ':' CELLREF | expr
; No spaces (the editor never lets one through), so no whitespace skipping.
; Every value is a 16-bit signed integer; division truncates toward zero
; (IDIV) and division by zero yields 0 rather than faulting - a stated
; simplification, not an oversight, matching this project's "no formulas,
; no formatting" -> "formulas, still no formatting" progression: nothing
; here produces or accepts a fraction. SUM/AVERAGE/MIN/MAX/COUNT are "the
; most common formulas" the roadmap asks for first; comparisons, IF() and
; the rest are later-stage work.
; =============================================================================

; sh_pcmp / sh_pcmpcont - comparison level, the actual top of the grammar
; (sh_eval_cell enters here, not at sh_pexpr): one optional
; '=' '<' '>' '<=' '>=' '<>' against an additive expression, producing 1
; (true) or 0 (false). Not chained - "A1<B1<C1" parses the same as most
; spreadsheets treat it, as one comparison ("A1<B1") followed by a second
; expression ("<C1") that the caller's own grammar level decides what to
; do with, which in practice just stops parsing there - matching this
; project's general rule of degrading a malformed tail rather than
; raising an error nothing here has a channel to report through.
sh_pcmp:
    call sh_pexpr
sh_pcmpcont:
    cmp byte [si], '='
    je .eq
    cmp byte [si], '<'
    je .lt_le_ne
    cmp byte [si], '>'
    je .gt_ge
    ret
.eq:
    inc si
    call sh_vpush
    call sh_pexpr
    call sh_binop_pre
    call fp_cmpab                     ; AX = -1/0/1 with the flags to match,
    je .true                          ; so the six tests below read exactly as
    jmp .false                        ; the integer CMPs they replace
.lt_le_ne:
    inc si
    cmp byte [si], '='
    je .le
    cmp byte [si], '>'
    je .ne
    call sh_vpush
    call sh_pexpr
    call sh_binop_pre
    call fp_cmpab
    jl .true
    jmp .false
.le:
    inc si
    call sh_vpush
    call sh_pexpr
    call sh_binop_pre
    call fp_cmpab
    jle .true
    jmp .false
.ne:
    inc si
    call sh_vpush
    call sh_pexpr
    call sh_binop_pre
    call fp_cmpab
    jne .true
    jmp .false
.gt_ge:
    inc si
    cmp byte [si], '='
    je .ge
    call sh_vpush
    call sh_pexpr
    call sh_binop_pre
    call fp_cmpab
    jg .true
    jmp .false
.ge:
    inc si
    call sh_vpush
    call sh_pexpr
    call sh_binop_pre
    call fp_cmpab
    jge .true
    jmp .false
.true:
    mov ax, 1
    call sh_acc_int
    ret
.false:
    xor ax, ax
    call sh_acc_int
    ret

; sh_pexpr / sh_pexprcont - additive level. sh_pexprcont is a real entry
; point of its own: sh_prange calls it to resume the +/- loop after folding
; a lone cell reference that turned out not to start a range.
sh_pexpr:
    call sh_pterm
sh_pexprcont:
    cmp byte [si], '+'
    je .add
    cmp byte [si], '-'
    je .sub
    ret
.add:
    inc si
    call sh_vpush                     ; the left operand goes on the machine
    call sh_pterm                     ; stack: a double does not fit a register
    call sh_binop_pre                 ; and the parse of the right may recurse
    call fp_add
    call sh_acc_store
    jmp sh_pexprcont
.sub:
    inc si
    call sh_vpush
    call sh_pterm
    call sh_binop_pre
    call fp_sub
    call sh_acc_store
    jmp sh_pexprcont

; sh_pterm / sh_ptermcont - multiplicative level, same reasoning as above.
sh_pterm:
    call sh_ppow
sh_ptermcont:
    cmp byte [si], '*'
    je .mul
    cmp byte [si], '/'
    je .div
    ret
.mul:
    inc si
    call sh_vpush
    call sh_ppow
    call sh_binop_pre
    call fp_mul
    call sh_acc_store
    jmp sh_ptermcont
.div:
    inc si
    call sh_vpush
    call sh_ppow
    call sh_binop_pre
    call fp_div                       ; CF=1 means the divisor was zero. The
    jnc .divok                        ; standing policy here is still 0 rather
    xor ax, ax                        ; than an error value: #DIV/0! needs the
    call sh_acc_int                   ; error TYPE the record now has room for
    jmp sh_ptermcont                  ; but nothing yet reads
.divok:
    call sh_acc_store
    jmp sh_ptermcont

; sh_ppow (stage 3.0d) - the '^' level, between multiplication and the
; factors. RIGHT-associative, so 2^3^2 is 2^(3^2) = 512, which is what every
; spreadsheet does; the recursion below is what makes it so, where a loop like
; sh_ptermcont's would have made it left-associative.
;
; It binds TIGHTER than '*' and looser than unary minus, so -2^2 is -(2^2).
; That is Excel's own precedence and it surprises people, but matching it is
; the point.
;
; A negative exponent is a fraction and there is no fraction here, so it
; yields 0 - the same answer this evaluator already gives for division by
; zero, and for the same stated reason.
sh_ppow:
    call sh_pfactor
    cmp byte [si], '^'
    jne .out
    inc si
    call sh_vpush                     ; the BASE, banked
    call sh_ppow                      ; recurse: right-associative
    call sh_acc_toint                 ; the exponent is still a whole number -
    mov cx, ax                        ; a fractional power needs logarithms,
    pop word [sh_lhs]                 ; which this file does not have
    pop word [sh_lhs+2]
    pop word [sh_lhs+4]
    pop word [sh_lhs+6]
    mov ax, 1                         ; the running product starts at one
    call sh_acc_int
    or cx, cx
    js .zero                          ; a negative exponent is a fraction
    jz .out                           ; anything^0 = 1
.loop:
    push cx
    push si
    mov si, sh_lhs                    ; B = the base, reloaded each time -
    call fp_unpack_b                  ; fp_mul consumes it
    pop si
    call sh_acc_load_a
    call fp_mul
    call sh_acc_store
    pop cx
    dec cx
    jnz .loop
    jmp .out
.zero:
    xor ax, ax
    call sh_acc_int
.out:
    ret

; sh_pfactor - unary minus, parens, a number, or an identifier (cell
; reference or function call, sh_pident tells them apart)
sh_pfactor:
    cmp byte [si], '-'
    jne .notneg
    inc si
    call sh_pfactor
    xor byte [sh_acc+7], 0x80         ; negate by flipping the sign BIT of the
    ret                               ; packed double - cheaper than unpacking
                                      ; and, unlike `neg`, exact for every
                                      ; value including zero
.notneg:
    cmp byte [si], '('
    jne .notparen
    inc si
    call sh_pcmp
    cmp byte [si], ')'
    jne .out                          ; malformed; return whatever we have
    inc si
    ret
.notparen:
    mov al, [si]
    cmp al, '$'                       ; stage 3.0e: '$A$1' is an IDENTIFIER,
    je .ident                         ; and this router decides that on the
    cmp al, 'A'                       ; FIRST character - without this line a
    jb .maybenum                      ; leading '$' falls through to the
    cmp al, 'Z'                       ; number path and the whole reference
    jbe .ident                        ; evaluates to 0. sh_pident tolerating
    cmp al, 'a'                       ; '$' is necessary but not sufficient.
    jb .maybenum
    cmp al, 'z'
    ja .maybenum
.ident:
    call sh_pident
    ret
.maybenum:
    call fp_atof                      ; a literal is a full decimal now: 3.5
    jnc .numok                        ; and 1e3 are values, not the leading
    xor ax, ax                        ; digit of one. Nothing parseable here
    call sh_acc_int                   ; is a zero, which is what the integer
    ret                               ; path did too.
.numok:
    call sh_acc_store
.out:
    ret

; -----------------------------------------------------------------------------
; sh_psheetpfx - stage 2.0: does SI start a "SheetN!" cross-sheet prefix?
; Sheet names are the fixed "Sheet1".."SheetN" strings (see the Sheets menu
; comment), so this is a literal, case-insensitive match against "SHEET"
; plus a digit '1'..SH_SHEETS - not a general name lookup.
; in: SI; out: CF=1 and AX=0-based sheet index, SI advanced past the '!';
; CF=0 and SI unchanged otherwise
; -----------------------------------------------------------------------------
sh_psheetpfx:
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
    cmp al, '0' + SH_SHEETS
    ja .no
    sub al, '1'
    xor ah, ah
    mov cx, ax                        ; cx = sheet index 0..SH_SHEETS-1
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

; sh_pident - in: SI at an identifier's first letter
; out: AX = value (a cell's value, or a function call's result), SI advanced
sh_pident:
    push bx
    push cx
    push dx
    push di
    mov byte [sh_pxsheet], 0xFF
    call sh_psheetpfx
    jnc .noxsheet
    mov [sh_pxsheet], al
.noxsheet:
    cmp byte [si], '$'                ; stage 3.0e: skip an absolute marker
    jne .nocoldollar                  ; before the column letters
    inc si
.nocoldollar:
    mov di, sh_ident
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
    cmp cx, 7
    jae .doneletters                  ; safety cap; no valid token is longer
    and al, 0xDF                      ; normalize to uppercase
    mov [di], al
    inc di
    inc cx
    inc si
    jmp .collect
.doneletters:
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
    call sh_identcol                  ; sh_ident -> AX = 0-based column
    mov [sh_pcol], ax
    mov bx, si
    add bx, SH_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call sh_pint                      ; SI advances past the digits
    pop es
    dec ax                            ; AX = 0-based row
    mov bx, ax
    mov ax, [sh_pcol]
    cmp byte [sh_pxsheet], 0xFF
    je .samesheet
    mov cx, [sh_cursheet]              ; stage 2.0: a "SheetN!" prefix -
    push cx                            ; temporarily point sh_findcell (via
    mov cl, [sh_pxsheet]               ; sh_cursheet) at the target sheet
    xor ch, ch                         ; for this one lookup, then put it
    mov [sh_cursheet], cx              ; back - every OTHER caller of
    call sh_getcell2                   ; sh_getcell2/sh_findcell is none the
    pop cx                             ; wiser
    mov [sh_cursheet], cx
    jmp .havecell
.samesheet:
    call sh_getcell2
.havecell:
    jmp .out                          ; nothing to do: sh_getcell2 leaves the
                                      ; value in sh_acc, and leaves a ZERO
                                      ; there for a cell that does not exist -
                                      ; which is what both branches here used
                                      ; to arrange by hand
.isfunc:
    call sh_pfunc
.out:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; sh_identcol - in: sh_ident = NUL-terminated uppercase letters (1-2 chars)
; out: AX = 0-based column index (the bijective base-26 sh_colname inverts)
sh_identcol:
    push bx
    push cx
    push si
    mov si, sh_ident
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

; sh_pcellref - a backtracking probe: does SI start a bare cell reference?
; in: SI; out: CF=1 yes (AX=col, BX=row, SI advanced past it),
;             CF=0 no (SI UNCHANGED - the caller falls back to sh_pexpr)
; Used only to tell a range's "A1:B5" apart from a plain expression that
; merely starts with a cell reference, like "A1+5".
sh_pcellref:
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
    mov di, sh_ident
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
    call sh_identcol
    mov cx, ax                        ; CX = col, held across sh_pint
    mov bx, si
    add bx, SH_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call sh_pint
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

; sh_prange - one comma-separated function argument: a range, or a single
; expression (which may itself start with, but not be, a cell reference -
; "A1" alone IS the range-shorthand for a single cell; "A1+5" is not a
; range at all). Folds into sh_pacc/sh_pcnt/sh_phave per sh_pfid.
sh_prange:
    push ax
    push bx
    call sh_pcellref
    jnc .plainexpr
    cmp byte [si], ':'
    jne .singlecell
    inc si
    mov [sh_r1col], ax
    mov [sh_r1row], bx
    call sh_pcellref
    jnc .out                          ; malformed range; contributes nothing
    mov [sh_r2col], ax
    mov [sh_r2row], bx
    call sh_foldrange
    jmp .out
.singlecell:
    call sh_getcell2                  ; the value lands in sh_acc either way -
.havev:                               ; getcell2 puts a zero there for a cell
    call sh_ptermcont                 ; that does not exist
    call sh_pexprcont
    call sh_pcmpcont
    call sh_foldvalue
    jmp .out
.plainexpr:
    call sh_pcmp
    call sh_foldvalue
.out:
    pop bx
    pop ax
    ret

; sh_foldrange - in: sh_r1col/row, sh_r2col/row (either corner order);
; folds every OCCUPIED cell in the rectangle via sh_foldvalue
sh_foldrange:
    push ax
    push bx
    mov ax, [sh_r1col]
    mov bx, [sh_r2col]
    cmp ax, bx
    jle .colok
    xchg ax, bx
.colok:
    mov [sh_r1col], ax
    mov [sh_r2col], bx
    mov ax, [sh_r1row]
    mov bx, [sh_r2row]
    cmp ax, bx
    jle .rowok
    xchg ax, bx
.rowok:
    mov [sh_r1row], ax
    mov [sh_r2row], bx

    mov ax, [sh_r1row]
    mov [sh_rrow], ax
.rloop:
    mov ax, [sh_rrow]
    cmp ax, [sh_r2row]
    ja .done
    mov ax, [sh_r1col]
    mov [sh_rcol], ax
.cloop:
    mov ax, [sh_rcol]
    cmp ax, [sh_r2col]
    ja .rnext
    mov bx, [sh_rrow]
    call sh_getcell2
    jnc .skip
    call sh_foldvalue                 ; sh_acc is the value; see sh_foldvalue
.skip:
    mov ax, [sh_rcol]
    inc ax
    mov [sh_rcol], ax
    jmp .cloop
.rnext:
    mov ax, [sh_rrow]
    inc ax
    mov [sh_rrow], ax
    jmp .rloop
.done:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_foldvalue - fold the value in sh_acc into the running sh_pacc, per the
; function being parsed (sh_pfid).
;
; sh_pacc is EIGHT BYTES now, not a word: SUM over a column of decimals has to
; keep them. The incoming value arrives in sh_acc rather than in AX for the
; same reason, and both are packed doubles - fp A and B are scratch here and
; are reloaded on every fold, because the range walker between calls uses them
; itself.
; -----------------------------------------------------------------------------
sh_foldvalue:
    push ax
    push bx
    inc word [sh_pcnt]
    mov bx, [sh_pfid]
    cmp bx, 0
    je .sum
    cmp bx, 1
    je .sum                           ; AVERAGE sums here; sh_funcfinish
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
    jmp .out                          ; COUNT (4), COUNTA (11) or unknown:
                                       ; pcnt alone is enough
.sum:
    call sh_pacc_to_a
    call sh_acc_load_b
    call fp_add
    call sh_pacc_from_a
    jmp .out
.product:
    call sh_pacc_to_a
    call sh_acc_load_b
    call fp_mul
    call sh_pacc_from_a
    jmp .out
.min:
    cmp word [sh_phave], 0
    jnz .mincmp
    call sh_acc_to_pacc
    mov word [sh_phave], 1
    jmp .out
.mincmp:
    call sh_acc_load_a                ; is the new value below the running one?
    call sh_pacc_to_b
    call fp_cmpab
    jge .out
    call sh_acc_to_pacc
    jmp .out
.max:
    cmp word [sh_phave], 0
    jnz .maxcmp
    call sh_acc_to_pacc
    mov word [sh_phave], 1
    jmp .out
.maxcmp:
    call sh_acc_load_a
    call sh_pacc_to_b
    call fp_cmpab
    jle .out
    call sh_acc_to_pacc
    jmp .out
.and:
    call sh_acc_iszero
    jnc .out                          ; nonzero folds in as true: no-op
    xor ax, ax                        ; any false value forces AND to false
    call sh_int_to_pacc
    jmp .out
.or:
    call sh_acc_iszero
    jc .out                           ; zero folds in as false: no-op
    mov ax, 1                         ; any true value forces OR to true
    call sh_int_to_pacc
.out:
    pop bx
    pop ax
    ret

; --- the small movers the fold above is written in terms of ------------------
sh_pacc_to_a:
    push si
    mov si, sh_pacc
    call fp_unpack_a
    pop si
    ret

sh_pacc_to_b:
    push si
    mov si, sh_pacc
    call fp_unpack_b
    pop si
    ret

sh_pacc_from_a:
    push di
    mov di, sh_pacc
    call fp_pack_a
    pop di
    ret

sh_acc_to_pacc:
    push ax
    push si
    push di
    mov si, sh_acc
    mov di, sh_pacc
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

; sh_int_to_pacc - AX (signed) -> sh_pacc
sh_int_to_pacc:
    call fp_i2a
    call sh_pacc_from_a
    ret

; sh_esatof - parse a decimal number from ES:SI into sh_acc, advancing SI past
; it. fp_atof reads DS:SI and the file staging buffer is in ES, so the token is
; copied across first - up to a ';' or the record's end. Without this, a SYLK
; K field would still be read by the integer parser and "3.5" would come back
; as 3, which is what the round trip actually did before this existed.
sh_esatof:
    push ax
    push cx
    push di
    mov di, sh_numbuf
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
    mov si, sh_numbuf
    call fp_atof
    pop si
    call sh_acc_store
    pop di
    pop cx
    pop ax
    ret

; The same three, for a record addressed through SI - the file writers, the
; chart scan and sort all walk the array with SI rather than DI.
sh_cellval_to_acc_si:
    push ax
    push cx
    push si
    push di
    mov di, sh_acc
    mov cx, 4
.s2a:
    mov ax, [es:si+SH_C_VAL]
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

; sh_cellnum_si - ...formatted into sh_numbuf
sh_cellnum_si:
    push ax
    push di
    call sh_cellval_to_acc_si
    call sh_acc_load_a
    mov di, sh_numbuf
    mov ax, 10
    call fp_ftoa
    pop di
    pop ax
    ret

; sh_cellint_si - ...truncated to a signed word in AX
sh_cellint_si:
    call sh_cellval_to_acc_si
    call sh_acc_toint
    ret

; sh_cellnum - the value of the record at ES:DI, formatted into sh_numbuf as
; a decimal. What "read the word and sh_itoa it" used to do, except that the
; value is eight bytes now and its low word on its own is meaningless.
sh_cellnum:
    push ax
    push di
    call sh_cellval_to_acc
    call sh_acc_load_a
    mov di, sh_numbuf
    mov ax, 10
    call fp_ftoa
    pop di
    pop ax
    ret

; sh_cellval_to_acc / sh_acc_to_cellval - the eight value bytes of the record
; at ES:DI. DI is left where it started, which matters: every caller is still
; using it as the record's offset.
sh_cellval_to_acc:
    push ax
    push cx
    push si
    push di
    mov si, sh_acc
    mov cx, 4
.c2a:
    mov ax, [es:di+SH_C_VAL]
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

sh_acc_to_cellval:
    push ax
    push cx
    push si
    push di
    mov si, sh_acc
    mov cx, 4
.a2c:
    mov ax, [si]
    mov [es:di+SH_C_VAL], ax
    add di, 2
    add si, 2
    dec cx
    jnz .a2c
    pop di
    pop si
    pop cx
    pop ax
    ret

; sh_acc_iszero - CF=1 if sh_acc is zero. The exponent and mantissa are all
; that matter; a negative zero is still zero, so the sign byte is masked off.
sh_acc_iszero:
    push ax
    push bx
    mov ax, [sh_acc]
    or ax, [sh_acc+2]
    or ax, [sh_acc+4]
    mov bx, [sh_acc+6]
    and bx, 0x7FFF
    or ax, bx
    pop bx
    pop ax
    jnz .no
    stc
    ret
.no:
    clc
    ret

; sh_funcfinish - the accumulated sh_pacc/sh_pcnt -> the function's result
sh_funcfinish:
    push bx
    mov bx, [sh_pfid]
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
                                       ; sh_pacc, which for a non-summing fold
                                       ; is always 0.
    call sh_pacc_to_a                 ; SUM/MIN/MAX/PRODUCT (and unknown):
    call sh_acc_store                 ; whatever was folded, zero if nothing
    jmp .fout
.average:
    cmp word [sh_pcnt], 0
    jne .avgok
    xor ax, ax
    call sh_acc_int
    jmp .fout
.avgok:
    call sh_pacc_to_a                 ; A REAL MEAN NOW, not a truncated one:
    mov ax, [sh_pcnt]                 ; AVERAGE(1,2) is 1.5 where the integer
    call fp_i2b                       ; evaluator gave 1
    call fp_div
    call sh_acc_store
    jmp .fout
.count:
    mov ax, [sh_pcnt]
    call sh_acc_int
    jmp .fout
.fout:
.out:
    pop bx
    ret

; sh_pfunc - in: SI right after a function NAME (sh_ident holds it),
; expecting '(' next; out: AX=value, SI advanced past the closing ')'.
; Saves/restores sh_pfid/sh_pacc/sh_pcnt/sh_phave around itself, so a
; function call nested inside another's argument list (SUM(A1,MAX(B1:B9)))
; cannot corrupt the outer accumulator.
sh_pfunc:
    push bx
    push cx
    push dx
    push word [sh_pfid]
    push word [sh_pacc]
    push word [sh_pcnt]
    push word [sh_phave]
    xor dx, dx                        ; DX = result; 0 covers every bad exit
    cmp byte [si], '('
    jne .done
    inc si
    call sh_funcid
    xor ah, ah
    cmp ax, 5
    je .doif
    cmp ax, 6
    je .donot
    cmp ax, 7
    je .doabs
    cmp ax, 12                         ; 12+ are stage 3.0d's special forms:
    jae .dospecial                     ; fixed arity, parsed by sh_pspecial,
                                       ; not folded over ranges
    mov [sh_pfid], ax
    push ax
    xor ax, ax
    cmp word [sh_pfid], 8              ; AND folds by ANDing in each value, so
    je .accone                         ; it must start true (1), not the false
    cmp word [sh_pfid], 10             ; (0) every other fold starts at.
    jne .accset                        ; PRODUCT starts at 1 for the same
.accone:                               ; reason - a running product seeded with
    mov ax, 1                          ; 0 can only ever be 0
.accset:
    call sh_int_to_pacc
    pop ax
    mov word [sh_pcnt], 0
    mov word [sh_phave], 0
.args:
    call sh_prange
    cmp byte [si], ','
    jne .argsdone
    inc si
    jmp .args
.argsdone:
    cmp byte [si], ')'
    jne .done
    inc si
    call sh_funcfinish
    mov dx, ax
    jmp .done
.doif:
    call sh_pif
    mov dx, ax
    jmp .done
.donot:
    call sh_pnot
    mov dx, ax
    jmp .done
.doabs:
    call sh_pabs
    mov dx, ax
    jmp .done
.dospecial:
    call sh_pspecial
    mov dx, ax
.done:
    pop word [sh_phave]
    pop word [sh_pcnt]
    pop word [sh_pacc]
    pop word [sh_pfid]
    mov ax, dx
    pop dx
    pop cx
    pop bx
    ret

; =============================================================================
; sh_pspecial (stage 3.0d) - the fixed-arity functions, ids 12 and up. These
; do not fold over a range the way SUM does; each parses exactly the arguments
; it takes and computes a value.
;
; WHAT IS DELIBERATELY ABSENT, and why - every one of these needs the value
; model Stage 4.0 brings, and a version that merely returns a plausible number
; would be worse than its absence:
;   ISBLANK  an empty cell already evaluates to 0, indistinguishable from a
;            cell holding 0, so this cannot be answered without reference-typed
;            arguments
;   ISNUMBER every value here IS a number, so it would be a constant TRUE
;   ISNA/NA  there is no error type to return or test for
;   SQRT/PI/the trig and financial families all need fractions
; SQRT is present only because floor(sqrt(n)) is a genuine integer answer.
;
; in: AX = the id, SI just past '('. out: AX = the value, SI past ')'.
; =============================================================================
; sh_parg - one argument, as an integer. The special forms below are integer
; functions by nature; a fractional MOD or FACT is not a thing they mean.
; Truncation is the same rule TRUNC itself uses, so INT(3.7) is 3.
sh_parg:
    call sh_pcmp
    call sh_acc_toint
    ret

sh_pspecial:
    push bx
    push cx
    push dx
    push di
    mov di, ax                        ; DI holds the id: every sh_pcmp below
                                      ; clobbers AX/BX/CX/DX
    cmp di, 13                        ; the four that are REAL functions of a
    je .dfloor                        ; real number now that cells hold one -
    cmp di, 14                        ; everything else here is a function of
    je .dtrunc                        ; whole numbers by nature and stays
    cmp di, 17                        ; integer (see .close)
    je .dsqrt
    cmp di, 19
    je .dround
    cmp di, 20
    jb .arg1                          ; 12..18 take one or two arguments
    cmp di, 23
    jbe .noargs                       ; 20..23 take none
    jmp .choose                       ; 24 CHOOSE takes a list

; ---- INT / TRUNC / SQRT / ROUND, on doubles ---------------------------------
; INT FLOORS and TRUNC cuts toward zero, which differ for negatives: Excel's
; INT(-3.7) is -4 and TRUNC(-3.7) is -3. While every value was an integer the
; two were indistinguishable and both were the identity; they are not any more.
.dfloor:
    call sh_pcmp
    call sh_acc_load_a
    call fp_floor
    jmp .dstore
.dtrunc:
    call sh_pcmp
    call sh_acc_load_a
    call fp_trunc
    jmp .dstore
.dsqrt:
    call sh_pcmp
    call sh_acc_load_a
    call fp_sqrt                      ; a REAL root: SQRT(2) is 1.414213562,
    jmp .dstore                       ; where the integer version gave 1
.dround:
    call sh_pcmp                      ; the value, banked across the second
    call sh_vpush                     ; argument's parse
    xor cx, cx
    cmp byte [si], ','
    jne .dround1                      ; ROUND(x) with no count means 0 places
    inc si
    call sh_parg                      ; the digit count IS a whole number
    mov cx, ax
.dround1:
    call sh_binop_pre                 ; A = the value again
    call fp_round
.dstore:
    call sh_acc_store
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
    mov ax, [sh_evrow]                ; ROW / COLUMN answer for the cell being
    cmp di, 22                        ; EVALUATED, not the one selected - a
    je .ctx1                          ; formula's own position is what Excel
    mov ax, [sh_evcol]                ; means by these
.ctx1:
    inc ax                            ; 1-based, as displayed
    jmp .close

; ---- the one- and two-argument forms ----------------------------------------
.arg1:
    call sh_parg                      ; every id from here takes a first value
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
    call sh_isqrt                     ; 17 SQRT
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
    js .zeroout                       ; negative has no factorial here
    cmp ax, 7
    ja .zeroout                       ; 8! = 40320 does not fit a signed word,
    mov cx, ax                        ; so refuse rather than hand back a
    mov ax, 1                         ; wrapped number that looks like an answer
    or cx, cx
    jz .close                         ; 0! = 1
.factloop:
    imul cx
    dec cx
    jnz .factloop
    jmp .close

.two:
    cmp byte [si], ','
    jne .zeroout
    inc si
    push bx                           ; first argument, across the second parse
    call sh_parg
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

; ---- CHOOSE(index, v1, v2, ...) ---------------------------------------------
; Every argument is parsed whether or not it is the chosen one - parsing has
; no side effects to avoid, and stopping early would leave SI mid-expression
; with no way to find the closing paren. Same reasoning as sh_pif's.
.choose:
    call sh_parg                      ; the 1-based index
    mov bx, ax
    xor cx, cx                        ; CX = how many values seen
    xor dx, dx                        ; DX = the one that matched
.chloop:
    cmp byte [si], ','
    jne .chdone
    inc si
    call sh_parg
    inc cx
    cmp cx, bx
    jne .chloop
    mov dx, ax
    jmp .chloop
.chdone:
    mov ax, dx
    jmp .close

.zeroout:
    xor ax, ax
.close:
    call sh_acc_int                   ; these thirteen are integer functions by
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

; sh_isqrt - in: AX = n; out: AX = floor(sqrt(n)), 0 for n < 0.
; Successive odd numbers: 1+3+5+... = k^2, so subtracting them until AX runs
; out counts the root. At most 181 iterations for a signed word, and it needs
; no division at all.
sh_isqrt:
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

; sh_pif - IF(cond,then,else): the one function that does not fold - its
; branches are not even both evaluated the way a real spreadsheet expects
; only ONE side effect-free path to matter, but here both sides just get
; parsed unconditionally (parsing has no side effects to avoid) and the
; condition alone picks which value survives.
; in: SI right after "IF("; out: AX=result, SI advanced past ')' if found
sh_pif:
    push bx
    push cx
    call sh_pcmp                      ; the condition, kept as a truth value
    call sh_acc_iszero                ; rather than as a number
    mov bx, 0
    jc .condfalse
    mov bx, 1
.condfalse:
    cmp byte [si], ','
    jne .bad
    inc si
    call sh_pcmp                      ; the then-value, banked whole
    call sh_vpush
    cmp byte [si], ','
    jne .badpop
    inc si
    call sh_pcmp                      ; the else-value, left in sh_acc
    or bx, bx
    jz .dropthen                      ; false: sh_acc already holds the else
    call sh_binop_pre                 ; true: recover the then-value from the
    call sh_acc_store                 ; stack (it lands in fp A) and keep it
    jmp .out
.dropthen:
    add sp, 8                         ; the banked then-value is not wanted
    jmp .out
.badpop:
    add sp, 8
.bad:
    xor ax, ax
    call sh_acc_int
.out:
    cmp byte [si], ')'
    jne .noclose
    inc si
.noclose:
    pop cx
    pop bx
    ret

; sh_pnot - NOT(x): logical negation
; in: SI right after "NOT("; out: AX=1 or 0, SI advanced past ')' if found
sh_pnot:
    call sh_pcmp
    call sh_acc_iszero
    jc .true
    xor ax, ax
    call sh_acc_int
    jmp .close
.true:
    mov ax, 1
    call sh_acc_int
.close:
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    ret

; sh_pabs - ABS(x): absolute value
; in: SI right after "ABS("; out: AX=|x|, SI advanced past ')' if found
sh_pabs:
    call sh_pcmp
    and byte [sh_acc+7], 0x7F         ; clear the sign bit: |x| for a packed
.close:                               ; double is one AND, and it is exact
    cmp byte [si], ')'
    jne .out
    inc si
.out:
    ret

; =============================================================================
; Macro engine (stage 2.0). A macro is an ordinary column of formula cells,
; on whatever sheet is active when Macro > Run is chosen, starting at the
; currently selected cell - real Excel lets you type or pick a starting
; reference in a Run dialog, but this OS has no generic text-prompt
; primitive (only a FILE picker, OSAPI_FILE_DLG) and building one is its
; own project, so "select the cell, then Run" is this stage's honest
; substitute. Execution proceeds down the column exactly like real Excel's
; own macro sheets, one cell at a time, until RETURN(), an empty cell, or
; the step cap below.
;
; Five function names are recognized as ACTIONS, not value-returning
; formulas, when they appear as the WHOLE of a macro cell's formula (never
; nested inside a larger expression - each cell is one instruction, again
; matching real Excel's macro-sheet model):
;   RETURN()              stop the macro
;   GOTO(ref)             jump execution to another cell on the SAME sheet
;   SET.VALUE(ref, expr)  write expr's value into another cell
;   SELECT(ref)           move the selection (and repaint, so it's visible)
;   ALERT("text")         show a real message box (SPEC.md 75.3's
;                         os88ui_ask, %included at the end of this file) and
;                         PAUSE until it's dismissed - os88ui_ask answers
;                         through a callback, not a return value, so the
;                         macro's "next step" is recorded before raising it
;                         and execution resumes from sh_macro_onalert
; A cell whose formula is anything else is evaluated normally (the full
; expression grammar, unchanged) and its value is discarded - a true no-op
; step, exactly as it would be on a real Excel macro sheet.
;
; A macro command's cell-reference arguments (GOTO/SET.VALUE/SELECT) are a
; bare "A1"-style reference only - no cross-sheet "SheetN!" prefix, unlike
; ordinary formulas (see sh_psheetpfx above). Keeping macro execution
; entirely on one sheet avoids the added complexity of switching sh_cursheet
; (and everything that implies for mid-macro repaints) partway through a
; run.
;
; SH_MACRO_MAXSTEPS exists because this is a COOPERATIVE system (SPEC.md's
; own repeated point) - sh_macro_step's GOTO loop below runs flat out with
; nothing to yield to, so a macro that GOTOs in a cycle would otherwise
; freeze the whole UI task forever, not just this window. Hitting the cap
; stops the macro and reports it, the same honest-failure posture as every
; other bound in this file, rather than let the machine hang.
; =============================================================================
SH_MACRO_MAXSTEPS equ 5000

sh_macro_kw_goto:     db 'GOTO', 0
sh_macro_kw_return:   db 'RETURN', 0
sh_macro_kw_setvalue: db 'SET.VALUE', 0
sh_macro_kw_select:   db 'SELECT', 0
sh_macro_kw_alert:    db 'ALERT', 0
sh_s_macrolimit: db 'Err: macro step limit', 0
sh_s_macrodone:  db 'Macro done', 0

; -----------------------------------------------------------------------------
; sh_pmacroref - a bare "A1"-style cell reference (no function names, no
; sheet prefix - see the section header above)
; in: SI; out: CF=1, AX=col, BX=row, SI advanced past it; CF=0 malformed
; -----------------------------------------------------------------------------
sh_pmacroref:
    push cx
    push dx
    push di
    mov di, sh_ident
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
    cmp cx, 2                          ; SH_COLS=256 never needs a 3rd letter
    jae .doneletters
    and al, 0xDF
    mov [di], al
    inc di
    inc cx
    inc si
    jmp .collect
.doneletters:
    mov byte [di], 0
    or cx, cx
    jz .bad
    mov al, [si]
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .bad
    call sh_identcol
    push ax                            ; col
    mov bx, si
    add bx, SH_EDITMAX + 1
    push es
    mov ax, ds
    mov es, ax
    call sh_pint
    pop es
    dec ax                             ; row
    mov bx, ax
    pop ax                             ; col
    cmp ax, SH_COLS
    jae .bad
    cmp bx, SH_ROWS
    jae .bad
    stc
    jmp .out
.bad:
    clc
.out:
    pop di
    pop dx
    pop cx
    ret

; -----------------------------------------------------------------------------
; sh_macro_kwtest - in: SI=text, CX=ptr to a NUL-terminated uppercase
; keyword; out: CF=1 and SI advanced past the keyword AND a following '(' -
; the '(' is required, so "GOTOX(" or "GOTO" alone don't match; CF=0
; otherwise (SI may be left partway advanced - callers always reset it)
; -----------------------------------------------------------------------------
sh_macro_kwtest:
    push ax
    push bx
    push di
    mov di, cx
.cmp:
    mov al, [di]
    or al, al
    jz .kwend
    mov bl, [si]
    cmp bl, 'a'
    jb .noupper
    cmp bl, 'z'
    ja .noupper
    and bl, 0xDF                       ; only a-z gets case-folded - a
                                        ; keyword like SET.VALUE has a '.'
                                        ; that this mask would corrupt
.noupper:
    cmp al, bl
    jne .no
    inc si
    inc di
    jmp .cmp
.kwend:
    cmp byte [si], '('
    jne .no
    inc si
    stc
    jmp .out
.no:
    clc
.out:
    pop di
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_macro_ident - in: SI; out: AX = 0 GOTO / 1 RETURN / 2 SET.VALUE /
; 3 SELECT / 4 ALERT / 0xFF none of these (SI restored); on a match SI is
; advanced past the keyword and its opening '('
; -----------------------------------------------------------------------------
sh_macro_ident:
    push bx
    push cx
    mov bx, si
    mov cx, sh_macro_kw_goto
    call sh_macro_kwtest
    jc .m0
    mov si, bx
    mov cx, sh_macro_kw_return
    call sh_macro_kwtest
    jc .m1
    mov si, bx
    mov cx, sh_macro_kw_setvalue
    call sh_macro_kwtest
    jc .m2
    mov si, bx
    mov cx, sh_macro_kw_select
    call sh_macro_kwtest
    jc .m3
    mov si, bx
    mov cx, sh_macro_kw_alert
    call sh_macro_kwtest
    jc .m4
    mov si, bx
    mov ax, 0xFF
    jmp .out
.m0:
    mov ax, 0
    jmp .out
.m1:
    mov ax, 1
    jmp .out
.m2:
    mov ax, 2
    jmp .out
.m3:
    mov ax, 3
    jmp .out
.m4:
    mov ax, 4
.out:
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; sh_macro_eval - execute ONE macro cell's formula as an instruction
; in: DI = the cell's record offset (caller has already checked HASFORMULA)
; out: AX = 0 advance / 1 goto (BX=col, CX=row) / 2 return / 3 alert raised
;      (the caller must stop stepping - sh_macro_onalert resumes it later)
; -----------------------------------------------------------------------------
sh_macro_eval:
    push si
    push dx
    push es
    mov es, [sh_cellseg]
    mov si, [es:di+SH_C_FOFF]                  ; formula text offset, in sh_txtseg
    mov es, [sh_txtseg]
    mov di, sh_macrobuf
.copyin:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    or al, al
    jnz .copyin
    pop es
    mov si, sh_macrobuf
    call sh_macro_ident
    cmp ax, 0
    je .doGOTO
    cmp ax, 1
    je .doRETURN
    cmp ax, 2
    je .doSETVALUE
    cmp ax, 3
    je .doSELECT
    cmp ax, 4
    je .doALERT
    mov si, sh_macrobuf                ; not a macro keyword: a plain
    call sh_pcmp                       ; formula step, evaluated for its
    xor ax, ax                         ; (nonexistent) side effect only
    jmp .out
.doGOTO:
    call sh_pmacroref
    jnc .noop
    mov cx, bx                         ; cx = row
    mov bx, ax                         ; bx = col
    mov ax, 1
    jmp .out
.doRETURN:
    mov ax, 2
    jmp .out
.doSETVALUE:
    call sh_pmacroref
    jnc .noop
    mov [sh_macro_tcol], ax
    mov [sh_macro_trow], bx
    cmp byte [si], ','
    jne .noop
    inc si
    call sh_pcmp
    mov dx, ax
    mov ax, [sh_macro_tcol]
    mov bx, [sh_macro_trow]
    call sh_setval
    xor ax, ax
    jmp .out
.doSELECT:
    call sh_pmacroref
    jnc .noop
    mov [sh_selcol], ax
    mov [sh_selrow], bx
    call sh_repaint
    xor ax, ax
    jmp .out
.doALERT:
    cmp byte [si], '"'
    jne .noop
    inc si
    mov di, sh_macro_msg
.alertcopy:
    mov al, [si]
    or al, al
    jz .alertdone                      ; unterminated string: stop at NUL
    cmp al, '"'
    je .alertdone
    mov dx, di
    sub dx, sh_macro_msg
    cmp dx, OS88UI_AMAX
    jae .alertdone                     ; clip, matching os88ui_ask's own
    mov [di], al                       ; clip-not-refuse policy
    inc di
    inc si
    jmp .alertcopy
.alertdone:
    mov byte [di], 0
    mov ax, [sh_macro_row]             ; advance to the next step BEFORE
    inc ax                             ; raising the alert, so its callback
    mov [sh_macro_row], ax             ; can just re-enter sh_macro_step
    mov al, OS88UI_AOK
    mov bx, [sh_ownwin]
    mov si, sh_macro_msg
    mov di, sh_macro_onalert
    call os88ui_ask
    mov ax, 3
    jmp .out
.noop:
    xor ax, ax
.out:
    pop dx
    pop si
    ret

; -----------------------------------------------------------------------------
; sh_macro_step - run macro steps starting at [sh_macro_col]/[sh_macro_row]
; until RETURN, an empty cell, an ALERT (which returns here having already
; arranged its own resumption), or the step cap
; -----------------------------------------------------------------------------
sh_macro_step:
    push ax
    push bx
    push cx
    push di
    push es
.next:
    mov ax, [sh_macro_steps]
    cmp ax, SH_MACRO_MAXSTEPS
    jae .limit
    inc ax
    mov [sh_macro_steps], ax
    mov ax, [sh_macro_col]
    mov bx, [sh_macro_row]
    call sh_findcell
    jnc .stop                          ; an empty cell: implicit RETURN
    mov es, [sh_cellseg]
    test byte [es:di+4], 1             ; HASFORMULA - a plain value cell is
    jz .advance                        ; a no-op step, just like a bare
                                        ; formula with no side effect
    call sh_macro_eval
    cmp ax, 0
    je .advance
    cmp ax, 1
    je .goto
    cmp ax, 2
    je .stop
    jmp .out                           ; 3: alert raised, stop stepping -
                                        ; sh_macro_onalert resumes us later
.goto:
    mov [sh_macro_col], bx
    mov [sh_macro_row], cx
    jmp .next
.advance:
    mov ax, [sh_macro_row]
    inc ax
    mov [sh_macro_row], ax
    jmp .next
.limit:
    mov word [sh_msg], sh_s_macrolimit
    jmp .stopdraw
.stop:
    mov word [sh_msg], sh_s_macrodone
.stopdraw:
    mov byte [sh_macro_running], 0
    call sh_repaint
.out:
    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_macro_onalert - os88ui_ask's completion proc (SPEC.md 75.3): AL=button
; or OS88UI_ACANCEL, SI=our window, gfx lock held, the alert already
; destroyed. Either way, resume - an OK and a Cancel mean the same thing
; here, since ALERT only ever offers the one OS88UI_AOK button.
; -----------------------------------------------------------------------------
sh_macro_onalert:
    call sh_macro_step
    ret

; -----------------------------------------------------------------------------
; sh_macro_run - Macro > Run: start executing at the currently selected
; cell, on the currently active sheet
; -----------------------------------------------------------------------------
sh_macro_run:
    cmp byte [sh_macro_running], 0
    jne .out                           ; already running (shouldn't happen -
                                        ; the menu command can't fire while
                                        ; an alert has this window's own
                                        ; event handling otherwise occupied,
                                        ; but a stray re-entry is a silent
                                        ; no-op rather than two interleaved
                                        ; macros stepping on each other)
    mov byte [sh_macro_running], 1
    mov word [sh_macro_steps], 0
    mov ax, [sh_selcol]
    mov [sh_macro_col], ax
    mov ax, [sh_selrow]
    mov [sh_macro_row], ax
    call sh_macro_step
.out:
    ret

; sh_funcid - in: sh_ident; out: AL = the function's id, or 0xFF unknown.
; TABLE-DRIVEN as of stage 3.0d: the id IS the entry's index in sh_functab, so
; adding a function is one string and one table word. It was an unrolled
; compare chain of five lines per function, which at ten functions was merely
; verbose and at twenty-five would have been a hundred lines of boilerplate
; with a hand-written id on each - exactly the shape that drifts.
sh_funcid:
    push bx
    push cx
    push si
    push di
    xor cx, cx
    mov bx, sh_functab
.loop:
    mov di, [bx]
    or di, di
    jz .unknown                       ; the table's 0 terminator
    mov si, sh_ident
    call sh_streq
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

; sh_streq - in: SI, DI (two NUL-terminated strings); out: CF=1 equal
sh_streq:
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
; sh_clearcell - in: AX=col, BX=row
; -----------------------------------------------------------------------------
sh_clearcell:
    call sh_removecell
    ret

; =============================================================================
; String / number utilities
; =============================================================================

; sh_colname - bijective base-26 column letters (0-based index in AX)
; out: sh_colbuf = NUL-terminated letters (up to 2 for a 256-column grid)
sh_colname:
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
    mov bx, sh_colbuf
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

; sh_itoa - signed AX to a NUL-terminated decimal string in sh_numbuf
sh_itoa:
    push ax
    push bx
    push cx
    push dx
    push di
    mov di, sh_numbuf
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
; sh_mkblank - rebuild sh_blank (every empty cell's display text) as exactly
; [sh_cellch] spaces + NUL. Called once at startup and again whenever
; Format > Column Width... changes the preset - sh_blank can't be a fixed
; string once the cell width is a runtime value.
; -----------------------------------------------------------------------------
sh_mkblank:
    push ax
    push cx
    push di
    mov cx, [sh_cellch]
    mov di, sh_blank
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

; sh_rjust - right-justify sh_numbuf into a fixed SH_CELL_CH-wide sh_tbuf
sh_rjust:
    push ax
    push cx
    push si
    push di
    mov si, sh_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov di, sh_tbuf
    mov ax, [sh_cellch]
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
    mov si, sh_numbuf
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
; sh_ljust - left-justify sh_numbuf into a fixed SH_CELL_CH-wide sh_tbuf
; (padding trails, mirroring sh_rjust which pads first)
; -----------------------------------------------------------------------------
sh_ljust:
    push ax
    push cx
    push si
    push di
    mov si, sh_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov [sh_jlen], cx
    mov di, sh_tbuf
    mov si, sh_numbuf
.copy:
    jcxz .copydone
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jmp .copy
.copydone:
    mov ax, [sh_cellch]
    sub ax, [sh_jlen]
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
; sh_cjust - center-justify sh_numbuf into a fixed SH_CELL_CH-wide sh_tbuf
; (the odd leftover space, if any, goes on the right)
; -----------------------------------------------------------------------------
sh_cjust:
    push ax
    push bx
    push cx
    push si
    push di
    mov si, sh_numbuf
    xor cx, cx
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc cx
    jmp .len
.havelen:
    mov [sh_jlen], cx
    mov di, sh_tbuf
    mov ax, [sh_cellch]
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
    mov si, sh_numbuf
    mov cx, [sh_jlen]
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
    mov si, sh_numbuf
    mov cx, [sh_jlen]
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
; sh_justify - in: BL=format byte; dispatches to sh_ljust/sh_cjust/sh_rjust
; by the alignment bits (General and explicit Right both right-justify,
; since this app's cells are only ever numeric - matching how real Excel's
; own "General" alignment right-justifies a number)
; -----------------------------------------------------------------------------
sh_justify:
    push ax
    push cx
    mov al, bl
    and al, SH_FMT_ALIGN_MASK
    mov cl, SH_FMT_ALIGN_SHIFT
    shr al, cl
    cmp al, SH_FMT_ALIGN_LEFT
    je .left
    cmp al, SH_FMT_ALIGN_CENTER
    je .center
    jmp .right
.left:
    call sh_ljust
    jmp .out
.center:
    call sh_cjust
    jmp .out
.right:
    call sh_rjust
.out:
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_strlen - in: SI=NUL-terminated string; out: AX=length (SI preserved)
; -----------------------------------------------------------------------------
sh_strlen:
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
; sh_curr_ins - insert '$' at the front of sh_numbuf, shifting the existing
; text (and its NUL) right by one byte
; -----------------------------------------------------------------------------
sh_curr_ins:
    push ax
    push si
    push di
    mov si, sh_numbuf
    xor ax, ax
.len:
    cmp byte [si], 0
    je .havelen
    inc si
    inc ax
    jmp .len
.havelen:                             ; si -> the NUL, ax = strlen (unused)
    mov di, si
    inc di
.shift:
    mov al, [si]
    mov [di], al
    cmp si, sh_numbuf
    je .done
    dec si
    dec di
    jmp .shift
.done:
    mov byte [sh_numbuf], '$'
    pop di
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_comma_ins - insert a thousands separator into sh_numbuf's digit run
; (a 16-bit value never needs more than one - max 5 digits), skipping any
; leading sign
; -----------------------------------------------------------------------------
sh_comma_ins:
    push ax
    push bx
    push cx
    push si
    push di
    mov si, sh_numbuf
    cmp byte [si], '-'
    jne .nosign
    inc si
.nosign:
    push si                           ; start of the digit run
    xor cx, cx
.dlen:
    cmp byte [si], 0
    je .havedlen
    inc si
    inc cx
    jmp .dlen
.havedlen:                            ; cx = digit count
    pop si                            ; si = start of digit run again
    cmp cx, 4
    jb .nocomma                       ; <=3 digits: no comma needed
    mov ax, cx
    sub ax, 3
    add ax, si
    mov di, ax                        ; di = insertion point (fixed)
    mov bx, si
.elen:
    cmp byte [bx], 0
    je .haveend
    inc bx
    jmp .elen
.haveend:                             ; bx -> the NUL
    mov si, bx
    inc bx                            ; bx = shift destination (one past)
.shift:
    mov al, [si]
    mov [bx], al
    cmp si, di
    je .placecomma
    dec si
    dec bx
    jmp .shift
.placecomma:
    mov byte [di], ','
.nocomma:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_pct_app - append '%' to sh_numbuf
; -----------------------------------------------------------------------------
sh_pct_app:
    push ax
    push si
    mov si, sh_numbuf
.f:
    cmp byte [si], 0
    je .got
    inc si
    jmp .f
.got:
    mov byte [si], '%'
    inc si
    mov byte [si], 0
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_numfmt - in: AX=value, BL=format byte; writes the decorated display
; text into sh_numbuf (General is exactly sh_itoa's plain decimal; Currency/
; Comma/Percent decorate it further). BL survives sh_itoa (which preserves
; the whole of BX across its own body) so the format nibble is still there
; to dispatch on afterward.
; -----------------------------------------------------------------------------
; stage 4.0: the value being formatted is the DOUBLE in sh_acc, not the
; integer in AX. Its one caller is sh_drawgrid, immediately after
; sh_getcell2, which leaves sh_acc set - so the grid shows 3.5 as "3.5"
; rather than as the 3 an integer cell could hold. The currency, comma and
; percent decorations below are unchanged: they work on the digit string,
; whatever produced it.
;
; Ten significant digits, which is what fits a cell and what Excel shows in a
; General column before it starts rounding to fit.
sh_numfmt:
    push ax
    push bx
    push cx
    push di
    mov bh, bl
    mov di, sh_numbuf
    call sh_acc_load_a                ; fp_ftoa formats the A accumulator, so
    mov ax, 10                        ; sh_acc has to be put there first
    call fp_ftoa
    pop di
    mov bl, bh
    and bl, SH_FMT_NUM_MASK
    mov cl, SH_FMT_NUM_SHIFT
    shr bl, cl
    cmp bl, SH_FMT_NUM_CURRENCY
    je .currency
    cmp bl, SH_FMT_NUM_COMMA
    je .comma
    cmp bl, SH_FMT_NUM_PERCENT
    je .percent
    jmp .out
.currency:
    call sh_curr_ins
    jmp .out
.comma:
    call sh_comma_ins
    jmp .out
.percent:
    call sh_pct_app
.out:
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; sh_drawunderline - in: CX=cell text x (left edge, as passed to
; OSAPI_FONT_RUN), DX=cell text y (top); reads sh_numbuf (the UNPADDED
; decorated text - not sh_tbuf, which carries alignment padding) and
; [sh_curfmt] to underline exactly the text's own extent, not the whole
; cell, positioned by the same alignment the text itself used.
; -----------------------------------------------------------------------------
sh_drawunderline:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [sh_ulx], cx
    mov [sh_uly], dx
    mov si, sh_numbuf
    call sh_strlen                    ; ax = text length (chars)
    mov bx, ax                        ; bx = length (chars)
    mov ax, [sh_cellch]
    sub ax, bx
    jns .padok
    xor ax, ax
.padok:                                ; ax = total pad chars
    mov dl, [sh_curfmt]
    and dl, SH_FMT_ALIGN_MASK
    mov cl, SH_FMT_ALIGN_SHIFT
    shr dl, cl                         ; dl = align code
    cmp dl, SH_FMT_ALIGN_LEFT
    je .lp0
    cmp dl, SH_FMT_ALIGN_CENTER
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
    mov ax, [sh_ulx]
    add ax, di                         ; ax = underline x1
    mov cx, ax
    add cx, bx
    dec cx                             ; cx = underline x2
    mov bx, [sh_uly]
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

; sh_strcpy - copy a NUL-terminated string, SI->DI, including the NUL
sh_strcpy:
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

; sh_strcpy_to_di - append a NUL-terminated string at the DI cursor,
; advancing DI to the new NUL (so successive calls concatenate)
sh_strcpy_to_di:
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
sh_tpl:
    dw 60, 40, 560, 380
    dw sh_ttl, sh_paint, sh_onkey, sh_onclick

; The EMPTY kernel menu set (SPEC.md 12.2), same idea as apps/word/word.asm's
; wd_menus0: zero real menus, but its AM_NAME still puts 'Sheet' in the
; kernel bar. sh_mf_ret can never actually be called (there is nothing to
; pick) - it only satisfies the macro's layout.
    OS88_MENUSET sh_menus, sh_s_appname, sh_mf_ret
    OS88_MENUSET_END sh_menus
sh_mf_ret:
    ret

; sh_mtab - Sheet's own in-window menu bar (see the SH_MBAR_H section
; comment). Each entry: title string ptr, item string-ptr array, item
; count (word each, so 6 bytes/entry) - menu index 0..SH_MENU_N-1 is this
; array's own order, which sh_mfire's dispatch and sh_docmd_sortcol/
; sh_docmd_options/sh_docmd_help all key off directly.
; Stage 3.0b puts FORMULA at index 2, which is where Excel 2.1d has it -
; File Edit Formula Format Data Options Macro Window Help. Sheet's own
; multi-sheet menu stands in for Window and now sits where Window does, after
; Macro. Every index below 2 is unchanged and everything above it shifted, so
; sh_mfire's dispatch chain moved with it; nothing else in this file keys off a
; menu index (the macro language names commands, not menu positions), which is
; what made the renumber safe to do at all.
sh_mtab:
    dw sh_m_file,    sh_i_file,    5
    dw sh_m_edit,    sh_i_edit,    9
    dw sh_m_formula, sh_i_formula, 2
    dw sh_m_format,  sh_i_format,  6
    dw sh_m_data,    sh_i_data,    3
    dw sh_m_options, sh_i_options, 2
    dw sh_m_macro,   sh_i_macro,   1
    dw sh_m_sheet,   sh_i_sheet,   SH_SHEETS
    dw sh_m_help,    sh_i_help,    1

; Excel 2.1d's Formula menu is Paste Name.../Paste Function.../Reference/
; Define Name.../Note.../Goto.../Find... - only Note... exists yet, and the
; rest arrive with the features behind them rather than as items that open
; nothing. A short menu that works beats a faithful one that does not.
sh_m_formula:    db 'Formula', 0
sh_i_formula:    dw sh_it_note, sh_it_goto
sh_it_note:      db 'Note...', 0
sh_it_goto:      db 'Goto...', 0

sh_ttl:        db 'Sheet', 0
sh_s_appname:  db 'Sheet', 0
sh_m_file:     db 'File', 0
sh_i_file:     dw sh_it_new, sh_it_open, sh_it_save, sh_it_saveas, sh_it_print
sh_it_new:     db 'New', 0
sh_it_open:    db 'Open...', 0
sh_it_save:    db 'Save', 0
sh_it_saveas:  db 'Save As...', 0
; Print... is DELIBERATELY A STUB: there is no print backend anywhere in this
; OS, so the item exists for menu fidelity and says so in the status bar
; rather than opening a dialog that could not do anything. Exit is absent on
; purpose too - the OS menu owns it.
sh_it_print:   db 'Print...', 0
sh_s_noprint:  db 'Printing is not supported.', 0

; Stage 1.8/2.x: matches real Excel 2.0/2.1's own Format menu shape
; (VM_screenshots/menu_format.png) - Number.../Alignment.../Font... open
; dialogs (sh_docmd_format's AL 0/1/2 is sh_fdlg_open's own kind number, so
; this array's first 3 entries must stay in that order). Border... is real
; (sh_bdlg_*). Row Height.../Column Width... are real too, as a 3-preset
; radio pick (sh_fdlg_open kinds 6/5 - see sh_docmd_format's own remap
; comment for why those two aren't 4/5 straight through) rather than real
; Excel's free-text numeric entry, since this app has no text-input widget
; at the app level - applies to the WHOLE sheet's runtime sh_cellw/
; sh_cellh, not per-row/per-column (the real per-row/per-column version
; would need every fixed-grid assumption in the renderer/hit-tester turned
; into a lookup, which stayed out of scope here).
sh_m_format:    db 'Format', 0
sh_i_format:    dw sh_it_fnum, sh_it_falign, sh_it_ffont, sh_it_fborder, sh_it_frowh, sh_it_fcolw
sh_it_fnum:      db 'Number...', 0
sh_it_falign:    db 'Alignment...', 0
sh_it_ffont:     db 'Font...', 0
sh_it_fborder:   db 'Border...', 0
sh_it_frowh:     db 'Row Height...', 0
sh_it_fcolw:     db 'Column Width...', 0

; Stage 2.0: the Sheet menu switches which of this instance's SH_SHEETS
; grids is active (see the multi-sheet cell-record comment above
; sh_findcell for why this lives in one instance rather than several).
; Sheet names are the fixed strings below, not user-renameable in this
; stage - simpler, and a macro's "SheetN!" reference (see sh_pident) needs
; a name it can recognize regardless of what the user might have typed.
sh_m_sheet:    db 'Sheets', 0
sh_i_sheet:    dw sh_it_sheet1, sh_it_sheet2, sh_it_sheet3, sh_it_sheet4
sh_it_sheet1:  db 'Sheet1', 0
sh_it_sheet2:  db 'Sheet2', 0
sh_it_sheet3:  db 'Sheet3', 0
sh_it_sheet4:  db 'Sheet4', 0

; Stage 2.0: no generic text-prompt dialog exists in this OS (only a FILE
; picker), so "Run" starts a macro at whatever cell is CURRENTLY SELECTED,
; rather than asking for a typed/picked starting reference - see the
; Macro engine section comment for the full reasoning.
sh_m_macro:    db 'Macro', 0
sh_i_macro:    dw sh_it_run
sh_it_run:     db 'Run', 0

; Edit - "Can't Undo" is a real Excel item with no real implementation
; behind it (no undo system exists) - shown disabled (MENU_DIS) rather than
; omitted, same honesty as Format's Border/Row Height/Column Width
; placeholders. Sort Column now lives in its own Data menu (below) - it
; only had to share Edit's list while the bar was the kernel's own
; MENU_APPMAX=5 one; Sheet's own in-window bar (sh_mtab) has no such cap.
sh_m_edit:     db 'Edit', 0
sh_i_edit:     dw sh_it_undo, sh_it_cut, sh_it_copy, sh_it_paste, sh_it_clear, sh_it_delete, sh_it_insert, sh_it_fillright, sh_it_filldown
sh_it_undo:    db MENU_DIS, "Can't Undo", 0
sh_it_cut:     db 'Cut', 0
sh_it_copy:    db 'Copy', 0
sh_it_paste:   db 'Paste', 0
sh_it_clear:   db 'Clear', 0
sh_it_delete:  db 'Delete...', 0
sh_it_insert:  db 'Insert...', 0
sh_it_fillright: db 'Fill Right', 0
sh_it_filldown:  db 'Fill Down', 0

; Data - real Excel 2.1 keeps Sort here, not in Edit. Chart Column.../Export
; Chart as BMP... are stage 2.x's own addition (no real-Excel Data menu
; equivalent - Excel's own charting is a whole separate document type) -
; see sh_docmd_chart's header comment for the design.
sh_m_data:     db 'Data', 0
sh_i_data:     dw sh_it_sort, sh_it_chart, sh_it_chartexp
sh_it_sort:    db 'Sort Column', 0
sh_it_chart:   db 'Chart Column...', 0
sh_it_chartexp: db 'Export Chart as BMP...', 0

; Options - Display toggles (stage 2.x). Each item's own string SWAPS
; between an On/Off pair (same relabel-by-repointing idea MENU_DIS's own
; doc shows) rather than drawing a separate checkmark glyph.
sh_m_options:  db 'Options', 0
sh_i_options:  dw sh_it_grid_off, sh_it_form_off
sh_it_grid_on:  db 'Gridlines: On', 0
sh_it_grid_off: db 'Gridlines: Off', 0
sh_it_form_on:  db 'Formulas: On', 0
sh_it_form_off: db 'Formulas: Off', 0

; Help
sh_m_help:     db 'Help', 0
sh_i_help:     dw sh_it_about
sh_it_about:   db 'About Sheet...', 0
sh_s_about:    db 'Sheet - a spreadsheet for os8088', 0

sh_defname:    db 'SHEET1.SLK', 0
sh_s_ready:    db 'Ready', 0
sh_s_id:       db 'ID;PWXL;N;E', 13, 10, 0
sh_s_c:        db 'C;X', 0
sh_s_y:        db ';Y', 0
sh_s_e:        db ';E', 0                  ; the expression field (stage 4.x)
sh_s_k:        db ';K', 0                  ; also the "commas are set" flag
                                            ; on an F record (stage 1.6)
sh_s_sylk_fx:  db 'F;X', 0                 ; an F (formatting) record -
sh_s_sylk_ff:  db ';F', 0                  ; stage 1.6's real SYLK support
sh_s_crlf:     db 13, 10, 0
sh_s_end:      db 'E', 13, 10, 0
sh_m_saved:    db 'Saved', 0
sh_m_loaded:   db 'Loaded', 0
sh_f_sum:      db 'SUM', 0
sh_f_average:  db 'AVERAGE', 0
sh_f_min:      db 'MIN', 0
sh_f_max:      db 'MAX', 0
sh_f_count:    db 'COUNT', 0
sh_f_if:       db 'IF', 0
sh_f_not:      db 'NOT', 0
sh_f_abs:      db 'ABS', 0
sh_f_and:      db 'AND', 0
sh_f_or:       db 'OR', 0
; stage 3.0d. ORDER IS THE ID - sh_functab below indexes by position and
; sh_pfunc/sh_foldvalue/sh_pspecial switch on that number, so entries may be
; APPENDED but never reordered or removed.
sh_f_product:  db 'PRODUCT', 0
sh_f_counta:   db 'COUNTA', 0
sh_f_mod:      db 'MOD', 0
sh_f_int:      db 'INT', 0
sh_f_trunc:    db 'TRUNC', 0
sh_f_sign:     db 'SIGN', 0
sh_f_fact:     db 'FACT', 0
sh_f_sqrt:     db 'SQRT', 0
sh_f_power:    db 'POWER', 0
sh_f_round:    db 'ROUND', 0
sh_f_true:     db 'TRUE', 0
sh_f_false:    db 'FALSE', 0
sh_f_row:      db 'ROW', 0
sh_f_column:   db 'COLUMN', 0
sh_f_choose:   db 'CHOOSE', 0

; sh_functab - the id is the INDEX. 0 terminates.
sh_functab:
    dw sh_f_sum, sh_f_average, sh_f_min, sh_f_max, sh_f_count
    dw sh_f_if, sh_f_not, sh_f_abs, sh_f_and, sh_f_or
    dw sh_f_product, sh_f_counta, sh_f_mod, sh_f_int, sh_f_trunc
    dw sh_f_sign, sh_f_fact, sh_f_sqrt, sh_f_power, sh_f_round
    dw sh_f_true, sh_f_false, sh_f_row, sh_f_column, sh_f_choose
    dw 0
sh_s_errpfx:   db 'Err ', 0
sh_s_ext_dif:  db '.DIF', 0
sh_s_ext_biff: db '.BIF', 0
sh_s_biff_fontname: db 'Helv', 0     ; Excel's own historical default face
; our number-format code (General/Currency/Comma/Percent) -> the real BIFF
; built-in format id, per the OpenOffice BIFF reference: 0=General,
; 5="$"#,##0 (currency, 0dp), 3=#,##0 (comma, 0dp), 9=0% (percent, 0dp) -
; all four are exactly the 0-decimal-place forms, matching this app's
; values always being whole numbers
sh_biff_numfmt_tab: db 0x00, 0x05, 0x03, 0x09
sh_s_dif_hdr1: db 'TABLE', 13, 10, '0,1', 13, 10, '""', 13, 10, 'VECTORS', 13, 10, '0,', 0
sh_s_dif_hdr2: db 13, 10, '""', 13, 10, 'TUPLES', 13, 10, '0,', 0
sh_s_dif_hdr3: db 13, 10, '""', 13, 10, 'DATA', 13, 10, '0,0', 13, 10, '""', 13, 10, 0
sh_s_dif_bot:  db '-1,0', 13, 10, 'BOT', 13, 10, 0
sh_s_dif_zc:   db '0,', 0
sh_s_dif_v:    db 'V', 13, 10, 0           ; the real DIF value-indicator
                                            ; for "this numeric data is
                                            ; valid" - NOT a comment string;
                                            ; a type-0 (numeric) data item
                                            ; has no third line at all
sh_s_dif_na0:  db '0,0', 13, 10, 'NA', 13, 10, 0  ; a numeric item (type 0)
                                            ; whose indicator is NA - NOT
                                            ; type 1 (that's DIF's STRING
                                            ; type, whose second line must
                                            ; be a quoted string, not a
                                            ; bare keyword)
sh_s_dif_eod:  db '-1,0', 13, 10, 'EOD', 13, 10, 0

; Stage 2.0's ALERT() needs a real message box; SPEC.md 75.3's os88ui_ask is
; the project's own answer to that (a kernel-resident version was tried and
; measured too costly for every app to pay for - see the section comment
; above sh_macro_kw_goto). Included here, above OS88_BSS, because the
; sh_macro_msg bss field below sizes itself from OS88UI_AMAX, which this
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
%include "os88ui.inc"

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
%include "os88fp.inc"

%include "os88chart.inc"

; =============================================================================
; bss (loader-zeroed, SPEC.md 21 step 5) - small now: the grid itself lives
; in claimed heap segments, not here.
; =============================================================================
    OS88_BSS 2206
    OS88_IMAGE_END

sh_selcol     equ os88_image_end + 0
sh_selrow     equ sh_selcol + 2
sh_scrollcol  equ sh_selrow + 2
sh_scrollrow  equ sh_scrollcol + 2
sh_editing    equ sh_scrollrow + 2
sh_editlen    equ sh_editing + 1
sh_editbuf    equ sh_editlen + 1            ; 64: SH_EDITMAX + NUL
sh_name       equ sh_editbuf + 64           ; 13: 8.3 name + NUL
sh_ox         equ sh_name + 13
sh_oy         equ sh_ox + 2
sh_cw         equ sh_oy + 2
sh_ch         equ sh_cw + 2
sh_vcols      equ sh_ch + 2
sh_vrows      equ sh_vcols + 2
sh_wcol       equ sh_vrows + 2
sh_wrow       equ sh_wcol + 2
sh_selx1      equ sh_wrow + 2
sh_selx2      equ sh_selx1 + 2
sh_sely1      equ sh_selx2 + 2
sh_sely2      equ sh_sely1 + 2
sh_lx1        equ sh_sely2 + 2
sh_lx2        equ sh_lx1 + 2
sh_ly1        equ sh_lx2 + 2
sh_ly2        equ sh_ly1 + 2
sh_trunc      equ sh_ly2 + 2
SH_TCOL       equ sh_trunc + 1
SH_TROW       equ SH_TCOL + 2
SH_TVAL       equ SH_TROW + 2               ; the integer form, still used by
                                             ; the DIF and BIFF readers
SH_TDVAL      equ SH_TVAL + 2               ; 8: SYLK's, as a real double
SH_THASE      equ SH_TDVAL + 8              ; byte: this record had a ;E field
SH_TEXPR      equ SH_THASE + 1              ; SH_EDITMAX+1: its text
SH_THAVE      equ SH_TEXPR + SH_EDITMAX + 1
SH_TALIGN     equ SH_THAVE + 1             ; sh_parsefrec's own scratch -
SH_TNUMFMT    equ SH_TALIGN + 1            ; an "F" record's parsed
SH_TCOMMA     equ SH_TNUMFMT + 1           ; alignment/number-format/;K
sh_stagelen   equ SH_TCOMMA + 1
sh_tbuf       equ sh_stagelen + 2           ; 96: formula bar text (a formula
                                             ; can run to SH_EDITMAX chars)
sh_colbuf     equ sh_tbuf + 96              ; 4: up to 2 letters + NUL
sh_numbuf     equ sh_colbuf + 4             ; 10: up to "$-32768" + NUL
                                             ; (stage 1.6's widest decoration)
sh_msg        equ sh_numbuf + 10            ; 2: pointer to a status string
sh_errbuf     equ sh_msg + 2                ; 8: "Err " + up to 2 digits + NUL
sh_cellseg    equ sh_errbuf + 8
sh_txtseg     equ sh_cellseg + 2
sh_stgseg     equ sh_txtseg + 2
sh_bordseg    equ sh_stgseg + 2            ; stage 2.x: the border table's
                                             ; own claim, see SH_CLAIM_BORD_KB
sh_nbord      equ sh_bordseg + 2            ; word: records in sh_bordseg
sh_ncells     equ sh_nbord + 2
sh_txtlen     equ sh_ncells + 2
sh_fcol       equ sh_txtlen + 2             ; sh_findcell's search key stash
sh_frow       equ sh_fcol + 2
sh_wrec_row   equ sh_frow + 2               ; sh_dowrite's per-record stash
sh_wrec_col   equ sh_wrec_row + 2
sh_wrec_val   equ sh_wrec_col + 2
sh_wrec_fmt   equ sh_wrec_val + 2           ; SYLK's and BIFF's writers'
                                             ; stash of the record's format
                                             ; byte (DIF carries no format
                                             ; at all, see sh_dowrite_dif)
sh_newoff     equ sh_wrec_fmt + 1           ; sh_setformula's new text offset
sh_evaldepth  equ sh_newoff + 2             ; sh_eval_cell's recursion depth
sh_fbuf       equ sh_evaldepth + 2          ; SH_EVAL_MAXDEPTH * 64: one
                                             ; formula-text copy per
                                             ; recursion level (see
                                             ; sh_eval_cell), copied out of
                                             ; sh_txtseg so the parser never
                                             ; needs a segment override
sh_ident      equ sh_fbuf + (SH_EVAL_MAXDEPTH * 64) ; 8: a collected name/column
sh_pxsheet    equ sh_ident + 8              ; stage 2.0: a "SheetN!" prefix
                                             ; sh_pident just consumed,
                                             ; 0xFF = none (see sh_psheetpfx)
sh_pcol       equ sh_pxsheet + 1              ; sh_pident's cell-ref column
sh_pfid       equ sh_pcol + 2               ; the function currently parsing:
                                             ; 0 SUM 1 AVERAGE 2 MIN 3 MAX
                                             ; 4 COUNT 0xFF unknown
sh_pacc       equ sh_pfid + 2               ; 8: the running sum / min / max /
                                             ; product, a packed double since
                                             ; stage 4.0 - SUM over a column of
                                             ; decimals has to keep them
sh_pcnt       equ sh_pacc + 8               ; cells folded so far
sh_phave      equ sh_pcnt + 2               ; MIN/MAX has a candidate yet
sh_r1col      equ sh_phave + 2              ; a range's two corners...
sh_r1row      equ sh_r1col + 2
sh_r2col      equ sh_r1row + 2
sh_r2row      equ sh_r2col + 2
sh_rrow       equ sh_r2row + 2              ; ...and sh_foldrange's own
sh_rcol       equ sh_rrow + 2               ; iteration cursor
sh_pass       equ sh_rcol + 2               ; recalculation pass counter
sh_bbrow      equ sh_pass + 2               ; sh_difbbox's used bounding box
sh_bbcol      equ sh_bbrow + 2
sh_curfmt     equ sh_bbcol + 2              ; sh_getcell2's format-byte output
sh_jlen       equ sh_curfmt + 1             ; sh_cjust's stashed text length
sh_ulx        equ sh_jlen + 2               ; sh_drawunderline's stashed
sh_uly        equ sh_ulx + 2                ; cell text origin (x, y)
sh_wrec_xf    equ sh_uly + 2                ; sh_doread_biff's per-record
                                             ; xf index stash
sh_biff_nfont equ sh_wrec_xf + 2            ; sh_doread_biff's FONT/XF
sh_biff_nxf   equ sh_biff_nfont + 2         ; record counters (also each
                                             ; new record's own index)
sh_font_tab   equ sh_biff_nxf + 2           ; SH_BIFF_FONT_CAP bytes: each
                                             ; tracked font's bold/underline
                                             ; bits
sh_xf_fmt     equ sh_font_tab + SH_BIFF_FONT_CAP  ; SH_BIFF_XF_CAP bytes:
                                             ; each tracked XF's align|
                                             ; numfmt packed byte
sh_xf_font    equ sh_xf_fmt + SH_BIFF_XF_CAP      ; SH_BIFF_XF_CAP bytes:
                                             ; each tracked XF's font index

sh_cursheet   equ sh_xf_font + SH_BIFF_XF_CAP      ; the sheet sh_findcell
                                             ; packs into every search (see
                                             ; the stage 2.0 cell-record
                                             ; comment above sh_findcell)
sh_selsave    equ sh_cursheet + 2           ; SH_SHEETS words each: the
sh_rowsave    equ sh_selsave + (SH_SHEETS*2) ; other 3 sheets' own
sh_sclsave    equ sh_rowsave + (SH_SHEETS*2) ; selection/scroll, saved and
sh_scrsave    equ sh_sclsave + (SH_SHEETS*2) ; restored by sh_switchsheet

sh_ownwin     equ sh_scrsave + (SH_SHEETS*2) ; our own window ptr, stashed
                                             ; once in sh_entry for
                                             ; os88ui_ask's sake
sh_macro_col  equ sh_ownwin + 2             ; the macro engine's current
sh_macro_row  equ sh_macro_col + 2          ; execution position
sh_macro_running equ sh_macro_row + 2       ; byte: a run is in progress
sh_macro_steps equ sh_macro_running + 1     ; word: this run's step count,
                                             ; against SH_MACRO_MAXSTEPS
sh_macro_tcol equ sh_macro_steps + 2        ; SET.VALUE's target cell,
sh_macro_trow equ sh_macro_tcol + 2         ; stashed across its sh_pcmp
sh_macrobuf   equ sh_macro_trow + 2         ; SH_EDITMAX+1: a macro step's
                                             ; formula text, copied out of
                                             ; sh_txtseg the same way
                                             ; sh_eval_cell's sh_fbuf is
sh_macro_msg  equ sh_macrobuf + SH_EDITMAX + 1 ; OS88UI_AMAX+1: ALERT's
                                             ; string-literal argument

sh_fdlg_win    equ sh_macro_msg + OS88UI_AMAX + 1 ; stage 1.8's Format
                                             ; dialogs: 0 = none, the gate
sh_fdlg_kind   equ sh_fdlg_win + 2          ; byte: 0 Number/1 Align/2 Font
sh_fdlg_sel    equ sh_fdlg_kind + 1         ; word: the selected radio 0-3
sh_fdlg_ox     equ sh_fdlg_sel + 2          ; this paint's content origin,
sh_fdlg_oy     equ sh_fdlg_ox + 2           ; stashed across widget calls
sh_fdlg_itemsptr equ sh_fdlg_oy + 2         ; this dialog's 4-item label
                                             ; array, for the row loop
sh_fdlg_rowidx equ sh_fdlg_itemsptr + 2     ; the row loop's own index
sh_fdlg_rowy   equ sh_fdlg_rowidx + 2       ; ...and that row's y
sh_fdlg_rect   equ sh_fdlg_rowy + 2         ; 4 words: one button rect,
                                             ; reused for OK then Cancel
sh_fdlg_count  equ sh_fdlg_rect + 8         ; word: this kind's row count
                                             ; (4 for Number/Align/Font, 2
                                             ; for Insert/Delete's Row/
                                             ; Column pick) - see
                                             ; sh_fdlg_counts

; Edit menu (stage 2.x)
sh_clipbuf    equ sh_fdlg_count + 2         ; SH_EDITMAX+1: Copy/Cut build
                                             ; their clipboard text here;
                                             ; Paste goes straight into
                                             ; sh_editbuf instead (see
                                             ; sh_docmd_paste)
sh_rc_op      equ sh_clipbuf + SH_EDITMAX + 1 ; sh_rowcol_op's own working
sh_rc_idx     equ sh_rc_op + 1              ; state - see its header
sh_rc_stgcnt  equ sh_rc_idx + 2             ; comment for what each field
sh_rc_savedsheet equ sh_rc_stgcnt + 2       ; holds; kept here rather than
sh_rc_tsheet  equ sh_rc_savedsheet + 2      ; on the stack purely because
sh_rc_trow    equ sh_rc_tsheet + 2          ; there are enough of them
sh_rc_tcol    equ sh_rc_trow + 2            ; that stack-relative addressing
sh_rc_tflags  equ sh_rc_tcol + 2            ; would be more error-prone
sh_rc_tfmt    equ sh_rc_tflags + 1          ; than a few named bytes
sh_wrec_foff  equ sh_rc_tfmt + 1            ; word: the formula text offset of
                                             ; the cell being written, or FFFF
sh_wrec_dval  equ sh_wrec_foff + 2          ; 8: the SYLK writer's banked value
sh_rc_tval    equ sh_wrec_dval + 8          ; 8: a whole double, not a word
sh_rc_tfml    equ sh_rc_tval + 8

sh_sort_cnt   equ sh_rc_tfml + 2            ; word: sh_docmd_sortcol's own
                                             ; staged-pair count
sh_sort_fcnt  equ sh_sort_cnt + 2           ; word: how many formula text
                                             ; slots are staged so far
sh_sort_row   equ sh_sort_fcnt + 2          ; word: the scan's own current
                                             ; row, stashed across the
                                             ; sh_getcell2 call below it
sh_sort_val   equ sh_sort_row + 2           ; word: that same cell's value
sh_sort_fslot equ sh_sort_val + 2           ; word: which text slot a
                                             ; formula cell just staged into
sh_sort_keyval  equ sh_sort_fslot + 2       ; word: the insertion sort's
sh_sort_keyorig equ sh_sort_keyval + 2      ; own (value, origidx) key pair
sh_sort_trow  equ sh_sort_keyorig + 2       ; word: the write-back loop's
sh_sort_src   equ sh_sort_trow + 2          ; own (target row, source idx)

; Sheet's own in-window menu bar (stage 2.x, see the SH_MBAR_H section
; comment) - sh_goy is the grid's own origin (raw [sh_oy] + SH_MBAR_H);
; everything from sh_mopen down is sh_mtrack/sh_mbar_*/sh_mdrop_*/
; sh_mitem_hit's shared working state.
sh_goy        equ sh_sort_src + 2
sh_mopen      equ sh_goy + 2               ; byte: open menu index, SH_M_NONE
sh_mhi        equ sh_mopen + 1             ; byte: hot item in the open
                                             ; dropdown, SH_M_NONE
sh_mrx1       equ sh_mhi + 1               ; the open dropdown's own rect
sh_mry1       equ sh_mrx1 + 2
sh_mrx2       equ sh_mry1 + 2
sh_mry2       equ sh_mrx2 + 2
sh_mbx1       equ sh_mry2 + 2              ; sh_mboxof's own output: one
sh_mbx2       equ sh_mbx1 + 2              ; menu title's screen box
sh_mw         equ sh_mbx2 + 2              ; SH_MENU_N words: each title's
                                             ; pixel width (sh_mtab_calc)
sh_mli        equ sh_mw + (SH_MENU_N*2)    ; generic loop-index scratch,
                                             ; shared by every sh_m* routine
                                             ; above (none of them nest)
sh_mto        equ sh_mli + 2               ; generic sh_mtab byte-offset
                                             ; scratch, same sharing rule
sh_mip        equ sh_mto + 2               ; the open menu's items array ptr
sh_mcnt       equ sh_mip + 2               ; the open menu's item count
sh_mmaxw      equ sh_mcnt + 2              ; sh_mdrop_geo's running max
                                             ; item-label width
sh_mry_row    equ sh_mmaxw + 2             ; sh_mdrop_draw's current row y

sh_gridlines     equ sh_mry_row + 2        ; byte: Options > Gridlines, 1=on
sh_showformulas  equ sh_gridlines + 1      ; byte: Options > Formulas, 1=on

; Border dialog (stage 2.x, sh_bdlg_*) - same "own scratch, not stack
; juggling" shape as sh_fdlg_*'s own bss block above
sh_bdlg_win    equ sh_showformulas + 1     ; word: 0 = none, the gate
sh_bdlg_sel    equ sh_bdlg_win + 2         ; byte: the 6 checkboxes' state,
                                             ; SH_BDLG_B_* bits
sh_bdlg_ox     equ sh_bdlg_sel + 1
sh_bdlg_oy     equ sh_bdlg_ox + 2
sh_bdlg_ri     equ sh_bdlg_oy + 2          ; the row loop's own index
sh_bdlg_ry     equ sh_bdlg_ri + 2          ; ...and that row's y
sh_bdlg_rect   equ sh_bdlg_ry + 2          ; 4 words: one button rect,
                                             ; reused for OK then Cancel

; sh_drawborders' own scratch (stage 2.x) - the four edges' screen rect for
; whichever bordered cell it is currently drawing
sh_bdrawflags  equ sh_bdlg_rect + 8        ; byte: that cell's border byte
sh_bx1         equ sh_bdrawflags + 1
sh_by1         equ sh_bx1 + 2
sh_bx2         equ sh_by1 + 2
sh_by2         equ sh_bx2 + 2
sh_bti         equ sh_by2 + 2              ; word: the scan loop's own index
                                             ; (not CX - see sh_drawborders)

; stage 2.x: runtime cell dimensions (Format > Column Width.../Row
; Height...) - see the SH_CW_*/SH_RH_* section comment above sh_entry
sh_cellw       equ sh_bti + 2              ; word: current column width, px
sh_cellh       equ sh_cellw + 2            ; word: current row height, px
sh_cellch      equ sh_cellh + 2            ; word: sh_cellw / 8, in chars
sh_blank       equ sh_cellch + 2           ; 11: up to SH_CW_WIDE/8 (10)
                                             ; spaces + NUL (sh_mkblank)

; Data > Chart Column... (stage 2.x) - a live second window; see the
; SH_CLAIM_CHART_KB comment above sh_entry for why it exists and the
; window-lifecycle note above sh_docmd_chart for why sh_chartwin, once
; set, is never zeroed again this session (only shown/hidden)
sh_chartseg    equ sh_blank + 11           ; word: the offscreen canvas claim
sh_chartwin    equ sh_chartseg + 2         ; word: 0 = never created; else its
                                             ; window ptr, permanently valid
sh_chart_sheet equ sh_chartwin + 2         ; word: which sheet the open chart
                                             ; is pinned to (frozen at open)
sh_chart_col   equ sh_chart_sheet + 2      ; word: which column is pinned
                                             ; (frozen at open - re-run the
                                             ; menu item to retarget)
sh_chart_cnt   equ sh_chart_col + 2        ; word: values currently plotted,
                                             ; 0 = nothing yet (Export checks
                                             ; this)
sh_chart_name  equ sh_chart_cnt + 2        ; 13: the exported .BMP's own 8.3
                                             ; name buffer (separate from
                                             ; sh_name, which is Sheet's own
                                             ; load/save filename)

; apps/os88chart.inc's own required scratch (see that file's header comment)
ch_max         equ sh_chart_name + 13
ch_base        equ ch_max + 2
ch_arr         equ ch_base + 2
ch_cnt         equ ch_arr + 2
ch_idx         equ ch_cnt + 2
ch_bx1         equ ch_idx + 2
ch_by1         equ ch_bx1 + 2
ch_bx2         equ ch_by1 + 2
ch_by2         equ ch_bx2 + 2
ch_srcseg      equ ch_by2 + 2
ch_stgseg      equ ch_srcseg + 2
ch_neg         equ ch_stgseg + 2     ; stage 3.0f: 1 = some value is
                                       ; negative. Its own word now: the axis
                                       ; row is type-dependent, so ch_base
                                       ; cannot carry this as well.
ch_type        equ ch_neg + 2       ; CH_T_* - which chart to draw
ch_lx0         equ ch_type + 2      ; the current segment's endpoints and
ch_ly0         equ ch_lx0 + 2       ; the column being interpolated -
ch_lx1         equ ch_ly0 + 2       ; CALLER bss like every other ch_*
ch_ly1         equ ch_lx1 + 2       ; word, for the same DS reason
ch_lcx         equ ch_ly1 + 2

; sh_rowcol_reidx and friends (stage 2.x) - see the section comment above
; sh_rowcol_reidx itself for what each of these holds
sh_rwsrc          equ ch_lcx + 2             ; SH_EDITMAX+1: the formula
                                              ; text copied out for rewriting
sh_rwdst          equ sh_rwsrc + SH_EDITMAX + 1  ; SH_RW_CAP: the rewritten
                                              ; text being built
sh_rw_di          equ sh_rwdst + SH_RW_CAP   ; word: sh_rw_emit's own cursor
sh_rw_op          equ sh_rw_di + 2           ; byte: sh_rc_op, copied in
sh_rw_pivot       equ sh_rw_op + 1           ; word: sh_rc_idx, copied in
sh_rw_tsheet      equ sh_rw_pivot + 2        ; word: the sheet this whole
                                              ; operation is acting on
sh_rw_home        equ sh_rw_tsheet + 2       ; byte: 1 if the formula being
                                              ; rewritten right now lives on
                                              ; sh_rw_tsheet itself
sh_rw_adj         equ sh_rw_home + 1         ; byte: sh_reidx_cellpart's own
                                              ; "adjust this one" flag
sh_rw_ostart      equ sh_rw_adj + 1          ; word: the reference's own
                                              ; text start, for a verbatim copy
sh_rw_lettersend  equ sh_rw_ostart + 2       ; word: where its letters end
                                              ; (and its digits, if any, start)
sh_rw_refcol      equ sh_rw_lettersend + 2   ; word: the reference as parsed
sh_rw_refrow      equ sh_rw_refcol + 2
sh_rw_refend      equ sh_rw_refrow + 2       ; word: just past its digits
sh_rw_recdi       equ sh_rw_refend + 2       ; word: sh_rowcol_reidx's own
                                              ; current record offset

; Copy/Paste relative-reference adjustment (stage 2.x) - see the section
; comment above sh_copy_shift for what each of these holds
sh_clip_col       equ sh_rw_recdi + 2        ; word: sh_docmd_copy's own
sh_clip_row       equ sh_clip_col + 2        ; source cell
sh_clip_valid     equ sh_clip_row + 2        ; byte: 1 once any Copy has
                                              ; run this session
sh_cp_coldelta    equ sh_clip_valid + 1      ; word: sh_docmd_paste's own
sh_cp_rowdelta    equ sh_cp_coldelta + 2     ; (dest - source) delta
sh_cp_ostart      equ sh_cp_rowdelta + 2     ; word: sh_copy_cellpart's own
                                              ; scratch - same shape as
                                              ; sh_rw_ostart/lettersend/
                                              ; refcol/refrow/refend above,
                                              ; just a separate copy since
                                              ; a row/col insert and a
                                              ; paste never run at once but
                                              ; sharing the same words
                                              ; would still be confusing
sh_cp_lettersend  equ sh_cp_ostart + 2
sh_cp_refcol      equ sh_cp_lettersend + 2
sh_cp_refrow      equ sh_cp_refcol + 2
sh_cp_refend      equ sh_cp_refrow + 2

; Stage 3.0a: multi-cell range selection. sh_selcol/sh_selrow keep their
; existing meaning as the ANCHOR (and, for every single-cell operation, still
; simply "the selected cell"); these two are the moving end of the block. A
; collapsed selection has extent == anchor, which is what sh_select sets, so
; every existing single-cell caller keeps working untouched.
sh_selcol2        equ sh_cp_refend + 2
sh_selrow2        equ sh_selcol2 + 2
sh_selc1          equ sh_selrow2 + 2   ; sh_selrect's normalized output -
sh_selc2          equ sh_selc1 + 2     ; c1<=c2, r1<=r2, so no consumer has
sh_selr1          equ sh_selc2 + 2     ; to care which corner was dragged
sh_selr2          equ sh_selr1 + 2     ; from
sh_sc_tcol        equ sh_selr2 + 2     ; sh_scrollto_t's target cell
sh_sc_trow        equ sh_sc_tcol + 2
sh_drag_col       equ sh_sc_trow + 2   ; the cell the drag handler last
sh_drag_row       equ sh_drag_col + 2  ; landed on - "redraw only on a
                                        ; change", per OSAPI_WM_ONDRAG's own
                                        ; warning that it fires per mouse
                                        ; packet and a repaint per packet is
                                        ; tens of ms on a 4.77MHz machine
sh_dragging       equ sh_drag_row + 2  ; byte: a press is armed on the grid
sh_selvc2         equ sh_dragging + 1  ; sh_drawsel's viewport-clamped
sh_selvr2         equ sh_selvc2 + 2    ; bottom-right, in window cells

; stage 3.0b: the formula bar's content box, as a real os88line field. Its
; rect is refreshed from the live geometry on every draw (the window moves and
; resizes), so only LN_BUF/LN_MAX are set once at entry.
sh_fline          equ sh_selvr2 + 2    ; OS88LINE_SZ bytes

; stage 3.0a+: the two scroll bars. Both use os88ui.inc's OWN seven-word block
; layout - x1,y1,x2,y2 (absolute, inclusive), total, fit, pos - so the vertical
; one is passed straight to os88ui_sbar/sbhit/sbgrab/sbtrack, and the private
; horizontal one below is a transposition of the same words rather than a
; different structure (see sh_hsb_* for why it is private and what it is
; staged to become).
sh_vsb            equ sh_fline + 20    ; 7 words
sh_hsb            equ sh_vsb + 14      ; 7 words
sh_sb_oldpos      equ sh_hsb + 14      ; word: the pos a scroll started from,
                                        ; for os88ui_sbmove's cheap redraw
sh_hsb_dragon     equ sh_sb_oldpos + 2 ; byte: 1 = a horizontal thumb drag is
                                        ; live (the vertical one's state is
                                        ; os88ui.inc's own static)
sh_hsb_dragoff    equ sh_hsb_dragon + 1 ; word: press x - thumb left
; sh_hsb_*'s own scratch. The rect is copied out of the block before ANY
; drawing, because the gfx primitives take AX/BX/CX/DX as their rect and BX is
; also the block pointer - holding both in BX is the clobber this codebase has
; hit three times already.
sh_hsb_x1         equ sh_hsb_dragoff + 2
sh_hsb_y1         equ sh_hsb_x1 + 2
sh_hsb_x2         equ sh_hsb_y1 + 2
sh_hsb_y2         equ sh_hsb_x2 + 2
sh_hsb_tl         equ sh_hsb_y2 + 2    ; the thumb's left
sh_hsb_tw         equ sh_hsb_tl + 2    ; ...and its width

; stage 3.0b: the note table's claim, and the Note... dialog's state. The
; EDIT BUFFER IS REAL BSS rather than a pointer into the arena, because the
; arena is append-only: the dialog edits a copy and only commits it on OK, so
; Cancel costs nothing and a refused commit leaves the old note intact.
sh_noteseg        equ sh_hsb_tw + 2    ; word: the note table's segment
sh_nnote          equ sh_noteseg + 2   ; word: records in it
sh_notetext       equ sh_nnote + 2     ; SH_NOTEMAX bytes: the edit buffer
sh_notebox        equ sh_notetext + SH_NOTEMAX  ; OS88TEXT_SZ bytes: the field
sh_noteopen       equ sh_notebox + 20  ; byte: 1 = the dialog is up
sh_notecol        equ sh_noteopen + 1  ; word: the cell it was opened on -
sh_noterow        equ sh_notecol + 2   ; NOT the live selection, which the
                                       ; user can still move behind a
                                       ; non-modal dialog
sh_ndlg_win       equ sh_noterow + 2   ; word: 0 = none, the same gate shape
sh_ndlg_ox        equ sh_ndlg_win + 2  ; as sh_bdlg_win
sh_ndlg_oy        equ sh_ndlg_ox + 2
sh_ndlg_rect      equ sh_ndlg_oy + 2   ; 4 words: one button rect, refilled
                                       ; per button (os88ui_btn takes a
                                       ; POINTER to it)

; stage 3.0c: the generic one-line input dialog, shared by Goto..., Row
; Height... and Column Width... (see SH_ID_* for why one dialog serves three).
sh_idlg_win       equ sh_ndlg_rect + 8 ; word: 0 = none, the single-instance
sh_idlg_kind      equ sh_idlg_win + 2  ; byte: SH_ID_*                   gate
sh_idlg_buf       equ sh_idlg_kind + 1 ; SH_EDITMAX bytes: what is typed
sh_idlg_line      equ sh_idlg_buf + SH_EDITMAX   ; OS88LINE_SZ bytes
sh_idlg_ox        equ sh_idlg_line + 20
sh_idlg_oy        equ sh_idlg_ox + 2
sh_idlg_rect      equ sh_idlg_oy + 2   ; 4 words: one button rect

; stage 3.0e: absolute references. Each scanner records whether the reference
; it is looking at pinned its column and/or its row with '$', and its adjuster
; then declines to move the pinned half - that refusal is the whole feature.
sh_rw_absc        equ sh_idlg_rect + 8 ; byte: Insert/Delete's scanner
sh_rw_absr        equ sh_rw_absc + 1
sh_cp_absc        equ sh_rw_absr + 1   ; byte: Copy/Paste + Fill's scanner
sh_cp_absr        equ sh_cp_absc + 1

; stage 3.0d: which cell the evaluator is CURRENTLY inside, for ROW()/COLUMN().
; Saved and restored around each sh_eval_cell so a formula reached through
; another cell's reference still answers for itself, not for whoever asked.
sh_rc_ccol        equ sh_cp_absr + 1   ; the cell that OWNS the formula being
sh_rc_crow        equ sh_rc_ccol + 2   ; converted to or from R1C1 - every
                                       ; relative offset is measured from it
sh_evrow          equ sh_rc_crow + 2   ; word: 0-based
sh_evcol          equ sh_evrow + 2     ; word: 0-based
; stage 4.0: the value accumulator the evaluator now carries, and every
; scratch word apps/os88fp.inc's header says the caller owes it.
sh_acc            equ sh_evcol + 2     ; 8: the expression's current value
sh_lhs            equ sh_acc + 8       ; 8: a binary operator's left operand,
                                       ; recovered from the stack
fp_as             equ sh_lhs + 8
fp_bs             equ fp_as + 1
fp_ae             equ fp_bs + 1
fp_be             equ fp_ae + 2
fp_am0            equ fp_be + 2
fp_am1            equ fp_am0 + 2
fp_am2            equ fp_am1 + 2
fp_am3            equ fp_am2 + 2
fp_bm0            equ fp_am3 + 2
fp_bm1            equ fp_bm0 + 2
fp_bm2            equ fp_bm1 + 2
fp_bm3            equ fp_bm2 + 2
fp_t0             equ fp_bm3 + 2
fp_t1             equ fp_t0 + 2
fp_t2             equ fp_t1 + 2
fp_t3             equ fp_t2 + 2
fp_p0             equ fp_t3 + 2        ; 8 words: the 128-bit product
fp_sticky         equ fp_p0 + 16
fp_tmp            equ fp_sticky + 2
fp_dig            equ fp_tmp + 2       ; 24: fp_ftoa's digit string
fp_d10            equ fp_dig + 24
fp_nd             equ fp_d10 + 2
fp_sgn            equ fp_nd + 2
fp_sq             equ fp_sgn + 2       ; 8: fp_sqrt's input, across iterations
fp_g              equ fp_sq + 8        ; 8: its running guess
fp_tv             equ fp_g + 8         ; 8: fp_floor's general temporary
fp_hw             equ fp_tv + 8        ; --- the coprocessor path ---
fp_x1             equ fp_hw + 1        ; 10: A in 80-bit form
fp_x2             equ fp_x1 + 10       ; 10: B
fp_sw             equ fp_x2 + 10       ; where the status word lands
sh_bss_end        equ fp_sw + 2

; -----------------------------------------------------------------------------
; The bss size above is a PLAIN LITERAL and nothing in the toolchain checks it
; against the equ chain - setting it low is silent corruption of whatever the
; loader placed next, not a build error. It cannot simply be written as
; `OS88_BSS sh_bss_end - os88_image_end`: OS88_BSS_SIZE goes into the package
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
%define SH_BSS_NEED (sh_bss_end - os88_image_end)
    times (SH_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - SH_BSS_NEED) db 0
