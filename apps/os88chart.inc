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
; DL=color (0-15). A private helper for ch_fillrect, not meant to be
; called directly.
; -----------------------------------------------------------------------------
ch_setpixel:
    push ax
    push bx
    push si
    mov si, ax                         ; si = x, for the odd/even test below
    shr ax, 1                          ; ax = x / 2 (byte index within row)
    push ax
    mov ax, bx                         ; ax = y
    mov bx, CH_STRIDE
    mul bx                             ; dx:ax = y * CH_STRIDE (fits in ax)
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
    mov ah, dl                         ; stash the color - dl is reused below
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
    mov dl, ah
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
    mov dl, 0
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
    mov dl, 0
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
    mov dl, 0
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
    mov dl, 0
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
    mov dl, 0
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
    mov dl, 0
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
    mov dl, 0
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
    mov dl, 0
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
    mov dl, 0
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
    call ch_bars_draw
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
