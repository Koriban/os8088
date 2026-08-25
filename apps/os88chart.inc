; =============================================================================
; os8088 - apps/os88chart.inc
;
; The bar-chart rasterizer and BMP writer shared between apps/sheet/sheet.asm
; (its own live "Data > Chart Column..." window) and apps/chart/chart.asm (a
; standalone SYLK/DIF/BIFF chart viewer). Same idea as apps/os88ui.inc: get
; the scaling math and the BMP header bytes right once, and both callers
; benefit - get either wrong once, only one place to fix.
;
; THE ONE FACT THIS WHOLE FILE EXISTS BECAUSE OF: there is no pixel-readback
; API anywhere in this OS (checked every OSAPI_GFX_* define in os88api.inc).
; "Export the chart as a graphics file" therefore cannot mean "capture what
; got drawn" - it has to mean "draw into our OWN offscreen buffer, then both
; blit that buffer to the screen AND save that same buffer as a file."
;
; --- THE CHART BUFFER'S LAYOUT ----------------------------------------------
; One claimed segment, laid out like apps/paint/paint.asm's own DIB canvas
; (its pt_hdrtpl/pt_pal_rgb): a real 54-byte BMP file header, a 64-byte
; 16-color palette, then the pixel data. Unlike Paint's resizable canvas,
; this chart's size never changes, so the whole header AND palette are
; compile-time constants (ch_hdrtpl/ch_pal_bgra below) - nothing needs
; runtime patching.
;
;   offset 0          .. CH_HDRSZ-1     : the 118-byte header + palette
;   offset CH_PXOFF   .. CH_PXOFF+18999 : CH_H rows of CH_STRIDE packed 4bpp
;                                          bytes each (2px/byte, high nibble
;                                          left), drawn TOP-DOWN (row 0 = the
;                                          chart's own top - normal screen/
;                                          BLIT4 order).
;
; BMP wants pixel rows BOTTOM-UP on disk, the opposite of the buffer's own
; top-down order - and OSAPI_FILE_WRITE creates-or-REPLACES the WHOLE file
; on every call (confirmed: apps/os88api.inc's own comment says these two
; calls "move a WHOLE file"), so writing row-by-row in reverse order the way
; a first draft of this file tried would just overwrite itself down to the
; last row written. ch_bmp_write below instead STAGES a full, correctly-
; ordered copy (header + palette + bottom-up pixel rows) into a second,
; caller-supplied scratch segment, then does exactly one OSAPI_FILE_WRITE.
;
; --- WHAT THIS FILE NEEDS FROM YOU ------------------------------------------
; The CH_* geometry constants (CH_W/CH_H/CH_STRIDE/CH_HDRSZ/CH_PXOFF/
; CH_MAXBARS/CH_BARW/CH_GAP) are NOT declared here - equ constants can't be
; forward-referenced, and this file's CODE has to live at the end of your
; package (same fixed-offset reason os88ui.inc's own header gives), so your
; OWN code, earlier in the file, needs them to already exist. Declare them
; yourself, identically, near your other constants (apps/sheet/sheet.asm's
; own copy is the reference - CH_W=240, CH_H=160, CH_STRIDE=120, CH_HDRSZ=118,
; CH_PXOFF=CH_HDRSZ, CH_MAXBARS=40, CH_BARW=4, CH_GAP=2).
;
; You also need these bss words of your own, named exactly this (the same
; "the engine's own scratch, not stack juggling" idea sh_fdlg_*'s own bss
; block already uses in sheet.asm):
;   ch_max, ch_base, ch_arr, ch_cnt, ch_idx,
;   ch_bx1, ch_by1, ch_bx2, ch_by2, ch_srcseg, ch_stgseg
; (11 words, 22 bytes total)
;
; --- IN A PACKAGE ------------------------------------------------------------
; `%include "os88chart.inc"` AT THE END OF YOUR CODE, just before OS88_BSS -
; not up beside os88api.inc, for the same fixed-offset reason os88ui.inc's
; own header states (code between the header/icon and here breaks the icon
; macro's own offset assertion, and would move your entry point too).
; =============================================================================

; -----------------------------------------------------------------------------
; ch_hdrtpl - the constant 118-byte BMP header + 16-color palette (real
; BITMAPFILEHEADER + BITMAPINFOHEADER, byte-for-byte the same shape as
; apps/paint/paint.asm's own pt_hdrtpl/pt_pal_rgb) for a fixed CH_W x CH_H
; 4bpp image. Every field is a literal - this chart's size never changes,
; unlike Paint's own resizable canvas, so nothing here needs runtime
; patching. Copy this once into the front of your chart buffer (e.g. from
; your entry proc, right after claiming it) - ch_bmp_write just stages
; whatever is already sitting there, unmodified.
; -----------------------------------------------------------------------------
ch_hdrtpl:
    db 'BM'
    dd CH_HDRSZ + (CH_STRIDE * CH_H)   ; bfSize
    dw 0, 0                             ; bfReserved1/2
    dd CH_HDRSZ                         ; bfOffBits
    dd 40                               ; biSize: BITMAPINFOHEADER
    dd CH_W                             ; biWidth
    dd CH_H                             ; biHeight (positive = bottom-up)
    dw 1                                ; biPlanes
    dw 4                                ; biBitCount
    dd 0                                ; biCompression = BI_RGB
    dd CH_STRIDE * CH_H                 ; biSizeImage
    dd 0                                ; biXPelsPerMeter
    dd 0                                ; biYPelsPerMeter
    dd 16                               ; biClrUsed
    dd 0                                ; biClrImportant
ch_hdrtpl_end:
CH_HDRTPL_SZ equ ch_hdrtpl_end - ch_hdrtpl   ; = 54, asserted below

%if CH_HDRTPL_SZ != 54
    %error "ch_hdrtpl drifted from the real 54-byte BITMAPFILEHEADER+BITMAPINFOHEADER size"
%endif

; the same 16-entry EGA/VGA palette every OSAPI_SET_COLOR call in this OS
; already answers to (CBLACK..CWHITE), pre-converted to the file's own
; blue-green-red-reserved byte order (real BMP palette entries are stored
; backwards from apps/paint/paint.asm's own pt_pal_rgb, which keeps its
; table in plain RGB and converts at save time since it's reused for
; on-screen lookups too - this table has only one job, so it's written the
; file's own way directly)
ch_pal_bgra:
    db 0x00,0x00,0x00,0                 ; 0  black
    db 0xAA,0x00,0x00,0                 ; 1  blue
    db 0x00,0xAA,0x00,0                 ; 2  green
    db 0xAA,0xAA,0x00,0                 ; 3  cyan
    db 0x00,0x00,0xAA,0                 ; 4  red
    db 0xAA,0x00,0xAA,0                 ; 5  magenta
    db 0x00,0x55,0xAA,0                 ; 6  brown
    db 0xAA,0xAA,0xAA,0                 ; 7  light grey
    db 0x55,0x55,0x55,0                 ; 8  dark grey
    db 0xFF,0x55,0x55,0                 ; 9  light blue
    db 0x55,0xFF,0x55,0                 ; 10 light green
    db 0xFF,0xFF,0x55,0                 ; 11 light cyan
    db 0x55,0x55,0xFF,0                 ; 12 light red
    db 0xFF,0x55,0xFF,0                 ; 13 light magenta
    db 0x55,0xFF,0xFF,0                 ; 14 yellow
    db 0xFF,0xFF,0xFF,0                 ; 15 white
ch_pal_bgra_end:
%if (ch_pal_bgra_end - ch_pal_bgra) != 64
    %error "ch_pal_bgra drifted from the real 16x4-byte BMP palette size"
%endif

; -----------------------------------------------------------------------------
; ch_setpixel - in: ES=buffer segment, AX=x (0..CH_W-1), BX=y (0..CH_H-1),
; DL=color (0-15). Preserves DX; clobbers CL. Bounds are the CALLER's to
; enforce - this writes wherever it is told (ch_fillrect clips, ch_pie_plot
; range-checks).
; -----------------------------------------------------------------------------
ch_setpixel:
    push ax
    push bx
    push si
    mov si, ax                         ; si = x, for the odd/even test below
    shr ax, 1                          ; ax = x / 2 (byte index within row)
    push ax
    mov ax, bx                         ; ax = y
    mov bx, ax
    mov cl, 7                          ; y * CH_STRIDE, AS SHIFTS. It was
    shl ax, cl                         ; `mul bx`, and MUL WRITES DX:AX - so
    mov cl, 3                          ; this routine destroyed the colour it
    shl bx, cl                         ; was passed in DL, three instructions
    sub ax, bx                         ; before reading it, and every pixel
                                       ; came out colour 0. Nothing noticed for
                                       ; as long as the only thing this package
                                       ; drew was black bars; the pie is the
                                       ; first caller to ask for a colour.
                                       ; CH_STRIDE is 120 = 128 - 8, so the
                                       ; shifts are also FASTER than the
                                       ; multiply they replace, on the machine
                                       ; this targets.
    pop bx                             ; bx = x / 2
    add ax, bx
    add ax, CH_PXOFF
    mov bx, ax                         ; bx = byte offset within the buffer
    test si, 1
    jnz .odd
    mov al, [es:bx]
    and al, 0x0F
    mov ah, dl
    mov cl, 4
    shl ah, cl
    or al, ah
    mov [es:bx], al
    jmp .out
.odd:
    mov al, [es:bx]
    and al, 0xF0
    mov ah, dl
    and ah, 0x0F
    or al, ah
    mov [es:bx], al
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ch_fillrect - in: ES=buffer segment, [ch_bx1]/[ch_by1]/[ch_bx2]/[ch_by2] =
; the rect (inclusive, x1<=x2, y1<=y2), DL=color (0-15). A private helper.
; Every coordinate comes through the ch_b{x,y}{1,2} scratch words rather
; than registers, since ch_bars_draw already needs several registers for
; its own per-bar bookkeeping and this is called once per bar, not once
; per pixel, so the extra memory traffic costs nothing that matters.
; Preserves ax-dx and si (needed - ch_bars_draw calls this mid-loop with
; live state in them); clobbers di.
; -----------------------------------------------------------------------------
ch_fillrect:
    push ax
    push bx
    push cx
    push dx
    push si
    ; THE COLOUR STAYS IN DL, and there is a story in that. This banked it in
    ; AH and reloaded DL from there before each ch_setpixel - a workaround for
    ; ch_setpixel eating DL (82.6.3). The workaround HAD THE SAME BUG: `mov ax,
    ; [ch_bx1]` at the top of the row loop below overwrites AH with the high
    ; byte of an x coordinate, which is 0 for every x this canvas has, so the
    ; colour was gone by the first pixel of the first row. Two routines, one
    ; register-half clobber each, and neither could be seen for as long as the
    ; only colour anything asked for was 0. ch_setpixel preserves DX now, so
    ; the bank is not merely fixed but unnecessary.
    mov si, [ch_by1]
    mov cx, [ch_by2]                   ; CLIP to the canvas. ch_setpixel does
    cmp cx, CH_H                       ; no bounds checking of its own, so an
    jb .yok                            ; unclipped rect writes outside the
    mov cx, CH_H - 1                   ; pixel area: a full-height NEGATIVE
.yok:                                  ; bar puts by2 at ch_base+span =
    mov [ch_by2], cx                   ; 80+80 = 160, one row past the last
    mov cx, [ch_bx2]                   ; valid row 159, silently corrupting
    cmp cx, CH_W                       ; the bytes just past the buffer's own
    jb .xok                            ; pixel region. Clipping here rather
    mov cx, CH_W - 1                   ; than at each caller keeps every
.xok:                                  ; future caller safe too.
    mov [ch_bx2], cx
.row:
    cmp si, [ch_by2]
    jg .done
    mov ax, [ch_bx1]
.col:
    cmp ax, [ch_bx2]
    jg .nextrow
    push ax
    mov bx, si
    call ch_setpixel
    pop ax
    inc ax
    jmp .col
.nextrow:
    inc si
    jmp .row
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ch_bars_draw - in: ES = target buffer segment (its header/palette are
; assumed already in place - see ch_hdrtpl above - only the pixel area is
; touched here), DX = the array's own segment, SI = offset of the first of
; CX signed 16-bit values within DX. Clears the pixel area to white, draws
; a black zero-axis line and one bar per value. Values may be negative
; (this app's cells are signed 16-bit) - the axis sits at the bottom when
; every value is >= 0 (maximizing chart height for the common case), or at
; the vertical middle the moment any value is negative, and each bar
; extends up or down from it accordingly, scaled by the single largest
; abs() value in the set. Clobbers ax-dx, si, di; does not preserve ES.
; PRESERVES DS - deliberately never touches it (see the DS-switch note
; below). CX is capped by the caller at CH_MAXBARS - this routine trusts
; that and does not re-check it.
;
; DS is left alone on purpose: this routine's own "locals" (the array's own
; start, the count, the running max, the axis row, the current bar index)
; live in the ch_* scratch words, which are the CALLER's bss, addressed
; through the default (untouched) DS - not in a register held across the
; ch_fillrect calls in between (a register-only first draft of this got the
; bar loop's own index silently corrupted by ch_fillrect's internal use of
; the very registers it was being kept in). An earlier draft went further
; and pointed DS at the array's own segment for the whole call so a plain
; `lodsw` could read it - which meant every one of these very same ch_*
; reads/writes silently landed in the ARRAY's segment instead of the
; caller's own, working only by luck (the array is tiny compared to the
; caller's bss offset, so nothing collided) until the same mistake in
; ch_bmp_write below hung the entire system by writing 19KB into a garbage
; ES. Fixed by keeping DS as the caller's own throughout and swapping ES
; instead - between the array's segment (for `es lodsw`, an explicit
; override, since default lodsw always reads DS) and the buffer's segment
; (for the clear and every ch_fillrect/ch_setpixel call, which both assume
; ES is already the buffer) - both borrowed into ch_srcseg/ch_stgseg,
; ch_bmp_write's own two words, since the two routines are never active at
; once.
; -----------------------------------------------------------------------------
; -----------------------------------------------------------------------------
; ch_prep (stage 3.0f) - the setup every chart type needs, lifted out of
; ch_bars_draw so the gallery below does not have four copies of it.
; in:  ES = buffer segment, DX = array segment, SI = array offset, CX = count
; out: ch_cnt/ch_arr/ch_srcseg/ch_stgseg filled, the pixel area cleared to
;      white, ch_max = the largest abs() value (never 0), ch_neg = 1 if any
;      value is negative. ES = the BUFFER on return. CF=1 means there is
;      nothing to draw and the caller should return immediately.
;
; ch_neg is a separate word rather than ch_base doing double duty as it used
; to: the axis row is type-dependent now - a column chart wants a horizontal
; axis, a bar chart a vertical one, a pie none at all - so "was anything
; negative" has to outlive the choice.
; -----------------------------------------------------------------------------
ch_prep:
    mov [ch_cnt], cx
    mov [ch_arr], si
    mov [ch_srcseg], dx                 ; the array's own segment
    mov [ch_stgseg], es                 ; the buffer's own segment

    mov di, CH_PXOFF                    ; clear the pixel area to white
    mov ax, CH_STRIDE * CH_H
    mov cx, ax
    mov al, 0xFF
    cld
    rep stosb

    mov cx, [ch_cnt]
    or cx, cx
    jz .empty

    mov si, [ch_arr]                    ; largest abs(), and any negative?
    mov es, [ch_srcseg]
    mov word [ch_max], 0
    mov word [ch_neg], 0
    mov dx, cx
.scan:
    or dx, dx
    jz .scandone
    es lodsw
    or ax, ax
    jns .pos
    mov word [ch_neg], 1
    neg ax
.pos:
    cmp ax, [ch_max]
    jbe .scannext
    mov [ch_max], ax
.scannext:
    dec dx
    jmp .scan
.scandone:
    cmp word [ch_max], 0
    jnz .havemax
    mov word [ch_max], 1                ; every value was 0: avoid a divide by
.havemax:                               ; zero and draw flat at the axis
    mov es, [ch_stgseg]                 ; ES = the buffer, which is what every
    clc                                 ; drawing routine below assumes
    ret
.empty:
    mov es, [ch_stgseg]
    stc
    ret

ch_bars_draw:
    call ch_prep
    jc .nodata

    cmp word [ch_neg], 0
    je .axisbottom
    mov word [ch_base], CH_H / 2
    jmp .axisdone
.axisbottom:
    mov word [ch_base], CH_H - 1
.axisdone:
    ; the axis line itself (ES is already the buffer, from ch_prep)
    mov word [ch_bx1], 0
    mov word [ch_bx2], CH_W - 1
    mov ax, [ch_base]
    mov [ch_by1], ax
    mov [ch_by2], ax
    mov dl, CH_C_AXIS
    call ch_fillrect

    ; pass 2: one bar per value
    mov si, [ch_arr]
    mov word [ch_idx], 0
.bar:
    mov ax, [ch_idx]
    cmp ax, [ch_cnt]
    jae .out
    mov es, [ch_srcseg]
    es lodsw                              ; ax = this value; si advances
    xor di, di                            ; di = 0/1: was the value negative?
    mov bx, ax
    or bx, bx
    jns .barpos
    mov di, 1
    neg bx
.barpos:
    ; bar length (px) = abs(value) * span / ch_max, where span is however
    ; much room the axis placement above left (CH_H-1 or CH_H/2) - the
    ; product fits in 32 bits (abs<=32767, span<=159) and the quotient
    ; can never exceed span, since ch_max >= abs(value) for every entry
    mov ax, bx
    mul word [ch_base]
    div word [ch_max]
    mov bx, ax                           ; bx = bar length in pixels
    mov ax, [ch_idx]
    mov cx, CH_BARW + CH_GAP
    mul cx
    mov es, [ch_stgseg]                  ; back to the buffer for the fillrect
    mov [ch_bx1], ax
    add ax, CH_BARW - 1
    mov [ch_bx2], ax
    or di, di                            ; di still holds the sign, saved
    jnz .barneg                          ; above before es/mul/div clobbered
                                          ; the value itself
    mov ax, [ch_base]
    sub ax, bx
    mov [ch_by1], ax
    mov ax, [ch_base]
    mov [ch_by2], ax
    jmp .barrect
.barneg:
    mov ax, [ch_base]
    mov [ch_by1], ax
    mov ax, [ch_base]
    add ax, bx
    mov [ch_by2], ax
.barrect:
    mov dl, CH_C_SERIES
    call ch_fillrect
    mov ax, [ch_idx]
    inc ax
    mov [ch_idx], ax
    jmp .bar
.out:
.nodata:
    ret

; =============================================================================
; The gallery (stage 3.0f) - Excel 2.1d's chart types that a SINGLE SERIES of
; signed integers can express. Every one of them shares ch_prep's setup, so
; what differs below is only where the axis goes and what is drawn between the
; points.
;
; Scatter and Combination are absent because they need TWO series, which needs
; the range selection to hand this file more than one column - not a drawing
; problem, a data-model one.
;
; ch_type selects; ch_draw dispatches. ch_bars_draw stays as its own entry
; point because Sheet and chart.asm both already call it by that name and a
; column chart is still the default.
; =============================================================================

; ch_getval - in: AX = index; out: AX = that value. ES is left as the BUFFER,
; which is what every drawing routine here assumes; the array's own segment is
; borrowed and given back inside.
ch_getval:
    push bx
    push si
    mov si, [ch_arr]
    shl ax, 1
    add si, ax
    mov es, [ch_srcseg]
    mov ax, [es:si]
    mov es, [ch_stgseg]
    pop si
    pop bx
    ret

; ch_xfor - in: AX = index; out: AX = the x pixel for it. Points are spread
; across the full width, so two points sit at the extreme ends and a single
; point sits in the middle rather than hard against the left edge.
ch_xfor:
    push bx
    push dx
    mov bx, [ch_cnt]
    dec bx
    or bx, bx
    jz .single
    mov dx, CH_W - 1
    mul dx
    div bx
    jmp .out
.single:
    mov ax, (CH_W - 1) / 2
.out:
    pop dx
    pop bx
    ret

; ch_yfor - in: AX = a signed value; out: AX = its y row, measured from
; ch_base exactly the way ch_bars_draw measures a bar's length.
ch_yfor:
    push bx
    push cx
    push dx
    xor cx, cx                          ; cx = 1 if the value was negative
    mov bx, ax
    or bx, bx
    jns .pos
    mov cx, 1
    neg bx
.pos:
    mov ax, bx
    mul word [ch_base]
    div word [ch_max]                   ; ax = the offset from the axis
    mov bx, [ch_base]
    or cx, cx
    jnz .below
    sub bx, ax
    jmp .out
.below:
    add bx, ax
    cmp bx, CH_H - 1
    jbe .out
    mov bx, CH_H - 1
.out:
    mov ax, bx
    pop dx
    pop cx
    pop bx
    ret

; ch_vline - a one-pixel column from y=BX to y=CX at x=AX, in colour DL.
; Ordering is fixed here so callers need not sort their endpoints.
ch_vline:
    push ax
    push bx
    push cx
    cmp bx, cx
    jbe .ordered
    xchg bx, cx
.ordered:
    mov [ch_bx1], ax
    mov [ch_bx2], ax
    mov [ch_by1], bx
    mov [ch_by2], cx
    call ch_fillrect
    pop cx
    pop bx
    pop ax
    ret

; ch_axis_h - the horizontal zero axis, and ch_base set for it.
ch_axis_h:
    cmp word [ch_neg], 0
    je .bottom
    mov word [ch_base], CH_H / 2
    jmp .draw
.bottom:
    mov word [ch_base], CH_H - 1
.draw:
    mov word [ch_bx1], 0
    mov word [ch_bx2], CH_W - 1
    mov ax, [ch_base]
    mov [ch_by1], ax
    mov [ch_by2], ax
    mov dl, CH_C_AXIS
    call ch_fillrect
    ret

; -----------------------------------------------------------------------------
; ch_line_draw - CH_T_LINE. A polyline through the points, plus a tick at each
; one so a single-point series still shows something.
; -----------------------------------------------------------------------------
ch_line_draw:
    call ch_prep
    jc .out
    call ch_axis_h
    mov word [ch_idx], 0
.seg:
    mov ax, [ch_idx]
    inc ax
    cmp ax, [ch_cnt]
    jae .points
    mov ax, [ch_idx]                    ; this point
    call ch_xfor
    mov [ch_lx0], ax
    mov ax, [ch_idx]
    call ch_getval
    call ch_yfor
    mov [ch_ly0], ax
    mov ax, [ch_idx]                    ; the next one
    inc ax
    call ch_xfor
    mov [ch_lx1], ax
    mov ax, [ch_idx]
    inc ax
    call ch_getval
    call ch_yfor
    mov [ch_ly1], ax
    call ch_seg_draw
    inc word [ch_idx]
    jmp .seg
.points:
    mov word [ch_idx], 0
.pt:
    mov ax, [ch_idx]
    cmp ax, [ch_cnt]
    jae .out
    call ch_xfor
    mov bx, ax
    mov ax, [ch_idx]
    call ch_getval
    call ch_yfor
    mov cx, ax                          ; cx = y
    mov [ch_bx1], bx
    mov [ch_bx2], bx
    mov [ch_by1], cx
    mov [ch_by2], cx
    mov dl, CH_C_SERIES
    call ch_fillrect
    inc word [ch_idx]
    jmp .pt
.out:
    ret

; -----------------------------------------------------------------------------
; ch_seg_draw - one line segment, ch_lx0/ch_ly0 to ch_lx1/ch_ly1, in black.
;
; NOT Bresenham: the x span is always non-negative and non-zero here (points
; are laid out left to right), so stepping x by one and interpolating y is
; both simpler and exactly what the area chart below needs as well. One
; division per column, which at 240 columns is nothing.
; -----------------------------------------------------------------------------
ch_seg_draw:
    push ax
    push bx
    push cx
    push dx
    mov ax, [ch_lx0]
    mov [ch_lcx], ax
.col:
    mov ax, [ch_lcx]
    cmp ax, [ch_lx1]
    ja .out
    call ch_interp_y                    ; ax = the interpolated y
    mov bx, ax
    mov cx, ax
    mov ax, [ch_lcx]
    mov dl, CH_C_SERIES
    call ch_vline                       ; a single pixel; a segment steeper
                                        ; than 1:1 would show gaps, which
                                        ; ch_area_draw's fill hides and a
                                        ; plain line accepts
    inc word [ch_lcx]
    jmp .col
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ch_interp_y - out: AX = y at x = [ch_lcx], linear between the two endpoints.
ch_interp_y:
    push bx
    push cx
    push dx
    mov ax, [ch_lx1]
    sub ax, [ch_lx0]
    mov cx, ax                          ; cx = the x span
    or cx, cx
    jz .flat
    mov ax, [ch_lcx]
    sub ax, [ch_lx0]                    ; ax = how far along
    mov bx, [ch_ly1]
    sub bx, [ch_ly0]                    ; bx = the y delta, SIGNED
    jns .up
    neg bx
    mul bx
    div cx
    mov bx, [ch_ly0]
    sub bx, ax
    jmp .done
.up:
    mul bx
    div cx
    mov bx, [ch_ly0]
    add bx, ax
.done:
    mov ax, bx
    jmp .out
.flat:
    mov ax, [ch_ly0]
.out:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; ch_area_draw - CH_T_AREA. The line chart, filled down to the axis: each
; column is a vertical run from the interpolated y to ch_base, so the fill and
; the outline are the same arithmetic and cannot disagree.
; -----------------------------------------------------------------------------
ch_area_draw:
    call ch_prep
    jc .out
    call ch_axis_h
    mov word [ch_idx], 0
.seg:
    mov ax, [ch_idx]
    inc ax
    cmp ax, [ch_cnt]
    jae .single
    mov ax, [ch_idx]
    call ch_xfor
    mov [ch_lx0], ax
    mov ax, [ch_idx]
    call ch_getval
    call ch_yfor
    mov [ch_ly0], ax
    mov ax, [ch_idx]
    inc ax
    call ch_xfor
    mov [ch_lx1], ax
    mov ax, [ch_idx]
    inc ax
    call ch_getval
    call ch_yfor
    mov [ch_ly1], ax
    mov ax, [ch_lx0]
    mov [ch_lcx], ax
.col:
    mov ax, [ch_lcx]
    cmp ax, [ch_lx1]
    ja .segdone
    call ch_interp_y
    mov bx, ax
    mov cx, [ch_base]
    mov ax, [ch_lcx]
    mov dl, CH_C_SERIES
    call ch_vline
    inc word [ch_lcx]
    jmp .col
.segdone:
    inc word [ch_idx]
    jmp .seg
.single:
    cmp word [ch_cnt], 1                ; one point has no segment at all, so
    jne .out                            ; draw its column directly
    xor ax, ax
    call ch_getval
    call ch_yfor
    mov bx, ax
    mov cx, [ch_base]
    mov ax, (CH_W - 1) / 2
    mov dl, CH_C_SERIES
    call ch_vline
.out:
    ret

; -----------------------------------------------------------------------------
; ch_hbar_draw - CH_T_BAR. Excel's "Bar" is the horizontal one; the vertical
; one it calls "Column". A transpose of ch_bars_draw: the axis is a COLUMN and
; each value runs left to right from it.
; -----------------------------------------------------------------------------
ch_hbar_draw:
    call ch_prep
    jc .out
    cmp word [ch_neg], 0                ; the axis is vertical here, so ch_base
    je .axisleft                        ; is an x, not a y
    mov word [ch_base], CH_W / 2
    jmp .axisdraw
.axisleft:
    mov word [ch_base], 0
.axisdraw:
    mov ax, [ch_base]
    mov [ch_bx1], ax
    mov [ch_bx2], ax
    mov word [ch_by1], 0
    mov word [ch_by2], CH_H - 1
    mov dl, CH_C_AXIS
    call ch_fillrect
    mov word [ch_idx], 0
.bar:
    mov ax, [ch_idx]
    cmp ax, [ch_cnt]
    jae .out
    call ch_getval                      ; ax = the value
    xor di, di
    mov bx, ax
    or bx, bx
    jns .pos
    mov di, 1
    neg bx
.pos:
    mov ax, bx                          ; length, against the WIDTH this time
    mov bx, CH_W - 1
    cmp word [ch_neg], 0
    je .havespan
    mov bx, CH_W / 2
.havespan:
    mul bx
    div word [ch_max]
    mov bx, ax                          ; bx = bar length in pixels
    mov ax, [ch_idx]                    ; its row band
    mov cx, CH_BARW + CH_GAP
    mul cx
    mov [ch_by1], ax
    add ax, CH_BARW - 1
    mov [ch_by2], ax
    or di, di
    jnz .neg
    mov ax, [ch_base]
    mov [ch_bx1], ax
    add ax, bx
    cmp ax, CH_W - 1
    jbe .setx2
    mov ax, CH_W - 1
.setx2:
    mov [ch_bx2], ax
    jmp .rect
.neg:
    mov ax, [ch_base]
    mov [ch_bx2], ax
    mov ax, [ch_base]
    sub ax, bx
    jns .setx1
    xor ax, ax
.setx1:
    mov [ch_bx1], ax
.rect:
    mov dl, CH_C_SERIES
    call ch_fillrect
    inc word [ch_idx]
    jmp .bar
.out:
    ret

; -----------------------------------------------------------------------------
; ch_draw - in: the same arguments ch_bars_draw takes, plus [ch_type].
; An unknown type falls back to the column chart rather than drawing nothing.
; -----------------------------------------------------------------------------
ch_draw:
    cmp word [ch_type], CH_T_BAR
    je .bar
    cmp word [ch_type], CH_T_LINE
    je .line
    cmp word [ch_type], CH_T_AREA
    je .area
    cmp word [ch_type], CH_T_PIE
    je .pie
    call ch_bars_draw
    ret
.pie:
    call ch_pie_draw
    ret
.bar:
    call ch_hbar_draw
    ret
.line:
    call ch_line_draw
    ret
.area:
    call ch_area_draw
    ret

; =============================================================================
; CH_T_PIE - the one Excel gallery type that is not a rectangle.
;
; NO TRIGONOMETRY EXISTS ANYWHERE IN THIS TREE, which is the whole reason this
; type waited. It gets a table instead: a quarter sine at HALF-DEGREE
; resolution, host-computed so it is exact rather than accumulated, in Q8 -
; sin*256, which is the largest scale where r*sin still fits a signed word for
; every radius this canvas can hold, so each coordinate costs ONE imul and no
; 32-bit shifting.
;
; Half a degree rather than one is not fussiness. The fill is drawn as radii
; swept from the centre, and the gap between two adjacent radii at the rim is
; r*step: at r=70 a one-degree step leaves 1.2px of white between them, and a
; half-degree step leaves 0.6px, which rounds shut. Sweeping radii rather than
; scanning the bounding box also avoids deciding which wedge each pixel is in,
; a question that costs two cross products per pixel and answers itself here.
;
; SLICES ARE COLOURED, one of the sixteen per slice - os8088 is 16-colour
; EGA/VGA, and only the UI chrome is black on white. THEY ARE ALSO HATCHED,
; which is what Excel 2.1 did and for the reason it did it: the same OS runs on
; Hercules and on CGA in two colours, where every slice would otherwise round
; to one solid shape. The hatch is the fallback, not the mechanism, and it
; costs a test rather than a second pass - a clear bit in the pattern simply
; leaves the white ch_prep already put there.
;
; (The first working version of this drew a solid black disc, and the display
; was NOT the reason - ch_setpixel was destroying the colour it was handed. It
; is worth saying plainly, because "correct but unshowable" and "broken" look
; identical on screen and it took a BMP export to tell them apart.)
;
; Negative values are drawn by their MAGNITUDE, which is what Excel does: a
; pie shows composition, and a negative share of a whole is not a thing a
; circle can express. The alternative - refusing to draw - is worse, because
; the sheet is usually right and one stray sign is not worth a blank chart.
; =============================================================================
; --- the two pens every non-pie type draws with ------------------------------
; The data was drawn in BLACK, all of it, in every chart type - and not as a
; choice: ch_setpixel destroyed the colour it was handed (82.6.3), so black was
; the only thing this package could produce and nobody had reason to notice.
; os8088 is SIXTEEN-COLOUR EGA/VGA; the UI chrome is drawn black on white
; because that is what chrome should be, not because the palette stops there.
;
; One colour for the whole series, which is what Excel 2.1 does with a single
; series - the PIE is the exception, and cycles per slice, because there each
; wedge is a different category rather than another point in one.
CH_C_SERIES equ CBLUE                ; Excel 2.1's own first-series colour
CH_C_AXIS   equ CBLACK               ; axes, ticks, outlines and separators

CH_PIE_CX  equ CH_W / 2
CH_PIE_CY  equ CH_H / 2
CH_PIE_R   equ (CH_H / 2) - 12       ; the canvas is wider than it is tall, so
                                     ; the HEIGHT is what bounds the radius
CH_PIE_STEPS equ 720                 ; half-degrees in a full turn

; sin(i * 0.5 degrees) * 256, i = 0..180. Host-computed.
ch_sintab:
    dw 0, 2, 4, 7, 9, 11, 13, 16, 18, 20
    dw 22, 25, 27, 29, 31, 33, 36, 38, 40, 42
    dw 44, 47, 49, 51, 53, 55, 58, 60, 62, 64
    dw 66, 68, 71, 73, 75, 77, 79, 81, 83, 85
    dw 88, 90, 92, 94, 96, 98, 100, 102, 104, 106
    dw 108, 110, 112, 114, 116, 118, 120, 122, 124, 126
    dw 128, 130, 132, 134, 136, 138, 139, 141, 143, 145
    dw 147, 149, 150, 152, 154, 156, 158, 159, 161, 163
    dw 165, 166, 168, 170, 171, 173, 175, 176, 178, 179
    dw 181, 183, 184, 186, 187, 189, 190, 192, 193, 195
    dw 196, 198, 199, 200, 202, 203, 204, 206, 207, 208
    dw 210, 211, 212, 213, 215, 216, 217, 218, 219, 221
    dw 222, 223, 224, 225, 226, 227, 228, 229, 230, 231
    dw 232, 233, 234, 235, 236, 237, 237, 238, 239, 240
    dw 241, 241, 242, 243, 243, 244, 245, 245, 246, 247
    dw 247, 248, 248, 249, 249, 250, 250, 251, 251, 252
    dw 252, 252, 253, 253, 254, 254, 254, 254, 255, 255
    dw 255, 255, 255, 256, 256, 256, 256, 256, 256, 256
    dw 256

; -----------------------------------------------------------------------------
; ch_sin - in: AX = angle in half-degrees, 0..719; out: AX = sin * 256, signed
; -----------------------------------------------------------------------------
ch_sin:
    push bx
    push cx
    push dx
    xor dx, dx
    mov cx, 180
    div cx                            ; ax = quadrant 0..3, dx = index 0..179
    mov bx, dx
    test al, 1                        ; quadrants 1 and 3 read the table
    jz .direct                        ; BACKWARDS: sin(90+x) = sin(90-x)
    mov bx, 180
    sub bx, dx
.direct:
    shl bx, 1
    push ax
    mov ax, [ch_sintab + bx]
    mov cx, ax
    pop ax
    cmp al, 2                         ; quadrants 2 and 3 are negative
    jb .pos
    neg cx
.pos:
    mov ax, cx
    pop dx
    pop cx
    pop bx
    ret

; ch_cos - the same table, a quarter turn along
ch_cos:
    push bx
    add ax, 180
    cmp ax, CH_PIE_STEPS
    jb .nowrap
    sub ax, CH_PIE_STEPS
.nowrap:
    call ch_sin
    pop bx
    ret

; -----------------------------------------------------------------------------
; ch_arcpt - in: AX = angle in half-degrees; out: AX = x, BX = y on the rim.
; Y is SUBTRACTED because the buffer is top-down, so a positive sine has to
; move up the screen rather than down it.
; -----------------------------------------------------------------------------
ch_arcpt:
    push cx
    push dx
    push ax
    call ch_cos
    mov cx, CH_PIE_R
    imul cx                           ; signed: AX = r*cos, DX its sign only
    add ax, 128                       ; round to NEAREST - a bare SAR rounds
    mov cl, 8                         ; toward minus infinity, which biases
    sar ax, cl                        ; every left-hand and upper point outward
    add ax, CH_PIE_CX                 ; and cost 0.7px of radius accuracy
    mov [ch_pie_px], ax
    pop ax
    push ax
    call ch_sin
    mov cx, CH_PIE_R
    imul cx
    add ax, 128
    mov cl, 8
    sar ax, cl
    neg ax
    add ax, CH_PIE_CY
    mov [ch_pie_py], ax
    pop ax
    mov ax, [ch_pie_px]
    mov bx, [ch_pie_py]
    pop dx
    pop cx
    ret

; -----------------------------------------------------------------------------
; ch_ray - a line from the pie's centre to (AX, BX) in colour DL. Bresenham,
; integer, no division - the same shape ch_seg_draw uses, kept separate
; because that one interpolates a data series and this one does not.
; -----------------------------------------------------------------------------
ch_ray:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [ch_pie_pen], dl              ; banked once: see ch_pie_plot
    mov [ch_pie_ex], ax
    mov [ch_pie_ey], bx
    mov word [ch_pie_x], CH_PIE_CX
    mov word [ch_pie_y], CH_PIE_CY
    mov ax, [ch_pie_ex]               ; dx = |ex - cx|, sx = its sign
    sub ax, CH_PIE_CX
    mov word [ch_pie_sx], 1
    or ax, ax
    jge .dxpos
    neg ax
    mov word [ch_pie_sx], -1
.dxpos:
    mov [ch_pie_dx], ax
    mov ax, [ch_pie_ey]
    sub ax, CH_PIE_CY
    mov word [ch_pie_sy], 1
    or ax, ax
    jge .dypos
    neg ax
    mov word [ch_pie_sy], -1
.dypos:
    mov [ch_pie_dy], ax
    mov ax, [ch_pie_dx]               ; err = dx - dy
    sub ax, [ch_pie_dy]
    mov [ch_pie_err], ax
.step:
    mov ax, [ch_pie_x]
    mov bx, [ch_pie_y]
    call ch_pie_plot
    cmp byte [ch_pie_thick], 0        ; A FILL RAY PAINTS THREE PIXELS, not one,
    je .thin                          ; and that is not decoration - it is what
    mov ax, [ch_pie_x]                ; makes the fill solid. Two Bresenham rays
    inc ax                            ; from a common origin can differ by two
    mov bx, [ch_pie_y]                ; pixels in one step, so a swept fan of
    call ch_pie_plot                  ; them leaves scattered holes: 452 of them
    mov ax, [ch_pie_x]                ; inside this circle, measured. Painting
    mov bx, [ch_pie_y]                ; the pixel right of and below each one
    inc bx                            ; closes every last one, at a cost of four
    call ch_pie_plot                  ; pixels spilled past the rim - which the
.thin:                                ; black rim is drawn over afterwards.
    mov ax, [ch_pie_x]
    cmp ax, [ch_pie_ex]
    jne .go
    mov ax, [ch_pie_y]
    cmp ax, [ch_pie_ey]
    je .done
.go:
    mov ax, [ch_pie_err]              ; e2 = 2*err, and BOTH comparisons below
    add ax, ax                        ; are SIGNED - err runs negative, and an
    mov [ch_pie_e2], ax               ; unsigned test reads that as enormous
    mov bx, [ch_pie_dy]
    neg bx
    cmp ax, bx                        ; e2 > -dy: step in x
    jle .noxstep
    mov ax, [ch_pie_err]
    sub ax, [ch_pie_dy]
    mov [ch_pie_err], ax
    mov ax, [ch_pie_x]
    add ax, [ch_pie_sx]
    mov [ch_pie_x], ax
.noxstep:
    mov ax, [ch_pie_e2]
    cmp ax, [ch_pie_dx]               ; e2 < dx: step in y
    jge .noystep
    mov ax, [ch_pie_err]
    add ax, [ch_pie_dx]
    mov [ch_pie_err], ax
    mov ax, [ch_pie_y]
    add ax, [ch_pie_sy]
    mov [ch_pie_y], ax
.noystep:
    jmp .step
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ch_pie_plot - one pixel, in [ch_pie_pen], with the canvas bounds enforced.
;
; TWO REASONS THE COLOUR COMES FROM MEMORY rather than from DL, which is what
; ch_setpixel actually reads. ch_setpixel does `mul bx` to find the row, and
; MUL WRITES DX - so the colour survives exactly one pixel and every one after
; it is drawn in whatever the high word of y*CH_STRIDE was, which is zero, which
; is black. That is why the first pie drawn here was a solid black disc.
; ch_fillrect has always known this: it stashes the colour in AH and reloads DL
; before each call. It is the reason ch_setpixel's own header says it is a
; private helper of ch_fillrect and not meant to be called directly - so a
; second caller has to bring its own answer, and this is it.
;
; And ch_setpixel does no bounds checking at all (ch_fillrect's comment says
; what that costs), which a radius rounded outward by half a pixel reaches.
; -----------------------------------------------------------------------------
; The eight fills, as 4x4 bit masks - one nibble per row, bit 0 leftmost. A set
; bit paints, a clear one leaves the white ch_prep already put there, so a
; patterned fill costs a test rather than a second colour.
ch_pie_pattab:
    db 0x0F, 0x0F, 0x0F, 0x0F         ; 0 solid
    db 0x05, 0x0A, 0x05, 0x0A         ; 1 50% checker
    db 0x0F, 0x00, 0x0F, 0x00         ; 2 horizontal bands
    db 0x05, 0x05, 0x05, 0x05         ; 3 vertical lines
    db 0x01, 0x02, 0x04, 0x08         ; 4 diagonal
    db 0x0D, 0x07, 0x0D, 0x07         ; 5 75%
    db 0x01, 0x00, 0x04, 0x00         ; 6 12.5% dots
    db 0x09, 0x06, 0x09, 0x06         ; 7 basket

ch_pie_plot:
    cmp ax, 0
    jl .out
    cmp ax, CH_W
    jge .out
    cmp bx, 0
    jl .out
    cmp bx, CH_H
    jge .out
    cmp byte [ch_pie_pat], 0xFF       ; 0xFF = solid: the rim and the slice
    je .paint                         ; separators, which are one pixel wide
    push ax                           ; and must not be dotted
    push bx
    push cx
    push si
    mov si, bx
    and si, 3                         ; the pattern row
    push ax
    mov al, [ch_pie_pat]
    xor ah, ah
    mov cl, 2
    shl ax, cl                        ; four bytes per pattern
    add si, ax
    pop ax
    mov ch, [ch_pie_pattab + si]
    and ax, 3                         ; the pattern column
    mov cl, al
    shr ch, cl
    test ch, 1
    pop si
    pop cx
    pop bx
    pop ax
    jz .out                           ; a clear bit leaves the background
.paint:
    push dx
    mov dl, [ch_pie_pen]
    call ch_setpixel
    pop dx
.out:
    ret

; -----------------------------------------------------------------------------
; ch_pie_draw - CH_T_PIE
; -----------------------------------------------------------------------------
ch_pie_draw:
    call ch_prep
    jc .nodata

    ; --- the total, as a 32-bit sum scaled down until it fits a word --------
    ; A slice's angle is value*720/total and both halves of that have to fit
    ; the 8086's own 32-by-16 divide. Forty values of up to 32767 reach 1.3M,
    ; so the sum is accumulated wide and then shifted - dropping low bits
    ; costs nothing here, since the answer is one of 720 half-degrees.
    mov word [ch_pie_tlo], 0
    mov word [ch_pie_thi], 0
    mov si, [ch_arr]
    push es
    mov es, [ch_srcseg]
    mov cx, [ch_cnt]
.sum:
    jcxz .summed
    es lodsw
    or ax, ax
    jns .sumpos
    neg ax                            ; magnitude: see the header
.sumpos:
    add [ch_pie_tlo], ax
    adc word [ch_pie_thi], 0
    dec cx
    jmp .sum
.summed:
    pop es
    mov word [ch_pie_shift], 0
.narrow:
    cmp word [ch_pie_thi], 0
    jne .doshift
    cmp word [ch_pie_tlo], 32768
    jb .narrowed
.doshift:
    shr word [ch_pie_thi], 1
    rcr word [ch_pie_tlo], 1
    inc word [ch_pie_shift]
    jmp .narrow
.narrowed:
    cmp word [ch_pie_tlo], 0
    jne .havetotal
    mov word [ch_pie_tlo], 1          ; every value was zero: one empty slice
.havetotal:

    ; --- the slices --------------------------------------------------------
    mov word [ch_pie_a0], 0
    mov word [ch_idx], 0
.slice:
    mov ax, [ch_idx]
    cmp ax, [ch_cnt]
    jae .rim
    push es                           ; this slice's magnitude, scaled the
    mov es, [ch_srcseg]               ; same way the total was
    mov si, [ch_arr]
    shl ax, 1
    add si, ax
    mov ax, [es:si]
    pop es
    or ax, ax
    jns .vpos
    neg ax
.vpos:
    mov cx, [ch_pie_shift]
    jcxz .scaled
.shiftv:
    shr ax, 1
    loop .shiftv
.scaled:
    mov dx, CH_PIE_STEPS              ; span = v * 720 / total
    mul dx
    div word [ch_pie_tlo]
    mov [ch_pie_span], ax

    mov ax, [ch_idx]                  ; colour 1..14, skipping black and white
    xor dx, dx
    mov cx, 14
    div cx
    mov ax, dx
    inc ax
    mov [ch_pie_col], ax
    mov ax, [ch_idx]                  ; ...and one of the eight hatches, which
    and ax, 7                         ; is what actually distinguishes them on
    mov [ch_pie_pat], al              ; a two-colour display

    mov ax, [ch_pie_a0]               ; sweep this slice's radii
    mov [ch_pie_a], ax
.sweep:
    mov ax, [ch_pie_a]
    mov bx, [ch_pie_a0]
    sub ax, bx
    cmp ax, [ch_pie_span]
    jae .slicedone
    mov ax, [ch_pie_a]
    cmp ax, CH_PIE_STEPS
    jb .nowrap
    sub ax, CH_PIE_STEPS
.nowrap:
    call ch_arcpt
    mov dx, [ch_pie_col]
    mov byte [ch_pie_thick], 1
    call ch_ray
    inc word [ch_pie_a]
    jmp .sweep
.slicedone:
    mov ax, [ch_pie_a0]               ; the boundary radius, in black, so two
    cmp ax, CH_PIE_STEPS              ; adjacent slices of a similar colour
    jb .bnowrap                       ; still read as two
    sub ax, CH_PIE_STEPS
.bnowrap:
    call ch_arcpt
    xor dx, dx
    mov byte [ch_pie_thick], 0        ; the separator stays one pixel wide
    mov byte [ch_pie_pat], 0xFF       ; ...and solid
    call ch_ray
    mov ax, [ch_pie_a0]
    add ax, [ch_pie_span]
    mov [ch_pie_a0], ax
    inc word [ch_idx]
    jmp .slice
.rim:
    mov word [ch_pie_a], 0            ; and the circle itself
.rimloop:
    mov ax, [ch_pie_a]
    cmp ax, CH_PIE_STEPS
    jae .nodata
    call ch_arcpt
    mov byte [ch_pie_pen], 0
    mov byte [ch_pie_pat], 0xFF
    call ch_pie_plot
    inc word [ch_pie_a]
    jmp .rimloop
.nodata:
    ret

; -----------------------------------------------------------------------------
; ch_bmp_write - in: ES=source chart buffer segment (header/palette/pixels
; already in place, top-down), BX=a SEPARATE scratch segment of at least
; CH_HDRSZ+CH_STRIDE*CH_H (19318) bytes (Sheet's own sh_stgseg, or
; chart.asm's own equivalent staging claim - anything not currently needed
; for something else), DS:SI=NUL 8.3 filename (untouched throughout - fed
; straight to OSAPI_FILE_WRITE exactly as received).
;
; out: CF=1 on failure (matches OSAPI_FILE_WRITE's own convention). Stages
; a full, correctly-ordered copy (header+palette verbatim, then all CH_H
; pixel rows in REVERSE order - the buffer is top-down for ch_bars_draw/
; BLIT4's sake, but BMP wants bottom-up on disk) into the scratch segment,
; then issues exactly one OSAPI_FILE_WRITE - it "creates or REPLACES" the
; WHOLE file every call (confirmed in os88api.inc), so unlike Sheet's own
; SYLK/DIF/BIFF writers - which build their own output as they go, all in
; one pass, then write it once - this cannot be split into one write per
; row the way an earlier draft of this routine assumed.
; -----------------------------------------------------------------------------
ch_bmp_write:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    mov [ch_srcseg], es
    mov [ch_stgseg], bx

    mov ax, [ch_srcseg]                 ; read BOTH before switching DS below -
    mov dx, [ch_stgseg]                 ; see [[os8088-ds-switch-before-read-hang]]:
    mov ds, ax                          ; a bss read after DS already points at
    mov es, dx                          ; another segment silently misreads
    xor si, si
    xor di, di
    mov cx, CH_HDRSZ
    cld
    rep movsb                           ; header+palette, verbatim

    mov ax, CH_H - 1                    ; the buffer's LAST row is BMP's
                                         ; FIRST on-disk row
.rowcopy:
    cmp ax, 0
    jl .rowsdone
    push ax
    mov bx, CH_STRIDE
    mul bx
    add ax, CH_PXOFF
    mov si, ax                          ; si = this row's offset in ds (src)
    mov cx, CH_STRIDE
    rep movsb                           ; di (staging, es) advances on its own
    pop ax
    dec ax
    jmp .rowcopy
.rowsdone:
    pop es                              ; caller's original es back
    pop ds                              ; caller's original ds back
    pop di                              ; caller's original di back
    pop si                              ; caller's original si back - THE
                                         ; FILENAME, valid again now that ds
                                         ; is restored too. An earlier draft
                                         ; popped ds/es here but left si
                                         ; (clobbered by the row-copy loop
                                         ; above, which reuses it as each
                                         ; row's own source offset) restored
                                         ; only AFTER the write already ran -
                                         ; the write itself used whatever
                                         ; pixel-row offset si last held, not
                                         ; the filename. Same shape of
                                         ; mistake as
                                         ; [[os8088-ds-switch-before-read-hang]]:
                                         ; a register/segment quietly means
                                         ; something else by the time it's
                                         ; actually used.
    push es                             ; stash the caller's real es across
    mov es, [ch_stgseg]                 ; the write - ES:BX = the staged
    xor bx, bx                          ; bytes to write
    mov cx, CH_HDRSZ + (CH_STRIDE * CH_H)   ; 19318, fits one word
    xor dx, dx
    call OSAPI_FILE_WRITE
    pop es                              ; caller's real es, restored
    pop dx
    pop cx
    pop bx
    pop ax
    ret
