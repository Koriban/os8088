; =============================================================================
; os8088 - apps/chart/chart.asm
;
; CHART, a standalone bar-chart viewer: File > Open... reads a real SYLK,
; DIF or BIFF file (dispatched by its extension, exactly like Sheet's own
; sh_doread) and renders the FIRST NUMERIC COLUMN it finds as a bar chart;
; File > Export as BMP... saves the rendered chart as a real graphics file
; for use in other software. Launch is via the standard Open dialog, not
; double-click file association - there is no cross-app spawn API anywhere
; in this OS (confirmed by an exhaustive apps/os88api.inc search), so
; association would only add complexity to a launch path that still
; requires going through the Locator either way.
;
; Deliberately does NOT reuse Sheet's own SYLK/DIF/BIFF reader code
; (apps/sheet/sheet.asm's sh_doread_sylk/sh_doread_dif/sh_doread_biff):
; this app reads files it did NOT write, so a reader that (like Sheet's
; own DIF reader) assumes its own writer's exact fixed shape would be
; unsafe here. The one exception is ct_rkdec below, a verbatim duplicate
; of sheet.asm's sh_rkdec - a tiny, fully self-contained 4-byte-value
; decode with no dependency on anything else in that file, so duplicating
; it exactly is cheap and safe where reusing a whole reader would not be.
;
; Rendering and BMP export are shared with Sheet's own live "Data > Chart
; Column..." window via apps/os88chart.inc (ch_bars_draw/ch_bmp_write) -
; see that file's own header for the offscreen-buffer design this is
; built on (there is no pixel-readback API in this OS, so both the
; on-screen chart and the exported file come from one rasterized buffer).
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'CHART', ct_entry

; --- shared chart geometry constants (see apps/os88chart.inc's own header -
; equ constants can't be forward-referenced, and that file's CODE has to
; live at the end of this package, so these are duplicated here exactly as
; apps/sheet/sheet.asm's own copy is - the reference for every field) -------
CH_W       equ 240
CH_H       equ 160
CH_STRIDE  equ 120                  ; CH_W / 2 (4bpp, 2px/byte)
CH_HDRSZ   equ 118                  ; 54-byte BMP header + 64-byte palette
CH_PXOFF   equ CH_HDRSZ             ; pixel data starts right after
CH_MAXBARS equ 40                   ; CH_W / (4px bar + 2px gap), no partial
                                     ; column at the edge
CH_T_COLUMN equ 0                   ; stage 3.0f: the gallery. Excel calls the
CH_T_BAR    equ 1                   ; vertical one Column and the horizontal
CH_T_LINE   equ 2                   ; one Bar, and this follows that naming
CH_T_AREA   equ 3                   ; rather than the intuitive-but-wrong one
CH_T_PIE    equ 4                   ; stage 3.0f, and the last of the four
                                    ; Excel types this app can draw: Scatter
                                    ; and Combination need TWO series, which
                                    ; is a data-model problem rather than a
                                    ; drawing one
CH_BARW    equ 4
CH_GAP     equ 2

CT_CLAIM_CHART_KB equ 19            ; the offscreen 4bpp canvas (19200 bytes
                                     ; needed -> 19KB claimed, 256B slack)
CT_CLAIM_STG_KB   equ 32            ; file-read staging AND BMP-export
                                     ; staging - sequential uses, never
                                     ; concurrent, the same reuse Sheet's own
                                     ; sh_stgseg already makes between its
                                     ; file I/O and (via sh_docmd_chartexport)
                                     ; its own chart export
CT_NAMEMAX equ 12                   ; 8.3 name, no NUL
CT_WIN_W   equ 260                  ; a little margin around the CH_W x
CT_WIN_H   equ 200                  ; CH_H canvas
; The temp arrays hold the KEPT SERIES, not the scanned candidates - see
; ct_record for why that distinction was a silent data-loss bug. They are
; therefore sized by CH_MAXBARS, the most that can ever be drawn, rather than
; by a separate and much larger scan cap (CT_TCAP, 256, now retired: it cost
; ~1.3KB of bss to hold cells that were going to be discarded anyway).

FDLG_OPEN equ 0
FDLG_SAVE equ 1

; -----------------------------------------------------------------------------
; ct_entry - package entry point (SPEC.md 20.2). Claims run here (the one
; place a package has no window yet), the constant BMP header+palette are
; copied into the chart buffer once (see os88chart.inc's own ch_hdrtpl
; comment: "copy this once ... ch_bmp_write just stages whatever is
; already sitting there"), then the window and its File menu are created.
; -----------------------------------------------------------------------------
ct_entry:
    push ax
    push cx
    push dx
    push si
    push di
    push es
    mov ax, CT_CLAIM_CHART_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [ct_chartseg], dx
    mov ax, CT_CLAIM_STG_KB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [ct_stgseg], dx
    mov word [ct_valcnt], 0
    mov byte [ct_name], 0
    mov es, [ct_chartseg]               ; copy the constant 118-byte BMP
    mov si, ch_hdrtpl                   ; header+palette into the buffer
    xor di, di                          ; once, here - ch_bmp_write only
    mov cx, CH_HDRSZ                    ; ever stages whatever's already
    cld                                 ; sitting there, never rebuilds it
    rep movsb
    mov si, ct_tpl
    call OSAPI_WM_CREATE                ; BX = window ptr, CF on table full
    jc .fail
    mov si, ct_menus
    call OSAPI_MENU_SET                 ; preserves CF (SPEC.md 20.3)
    jmp .out
.fail:
    stc
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_paint - W_PAINT: one OSAPI_GFX_BLIT4 of the already-rasterized buffer,
; nothing else. In: SI = window ptr; caller holds the gfx lock.
; -----------------------------------------------------------------------------
ct_paint:
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
    mov bx, dx                          ; bx=y for BLIT4 below
    mov es, [ct_chartseg]
    mov si, CH_PXOFF
    mov bp, CH_STRIDE
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

; -----------------------------------------------------------------------------
; ct_render - rasterize ct_vals[0..ct_valcnt) into ct_chartseg via
; apps/os88chart.inc's ch_bars_draw. The value array lives in THIS
; PACKAGE's own bss - a single-segment package (SPEC.md 20.1) runs with
; DS already pointed at that segment, so ch_bars_draw's own DX=array
; segment parameter is just DS itself, no cross-segment juggling needed
; (unlike Sheet, which stages the array in a separately claimed segment).
; -----------------------------------------------------------------------------
ct_render:
    push ax
    push cx
    push dx
    push si
    push es
    mov cx, [ct_valcnt]
    mov es, [ct_chartseg]
    mov dx, ds
    mov si, ct_vals
    call ch_draw                        ; stage 3.0f: the type comes from
                                        ; [ch_type], which the Gallery menu
                                        ; sets; ch_draw falls back to the
                                        ; column chart for an unknown one
    pop es
    pop si
    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_oncmd - the File menu (AL = item index: 0 Open..., 1 Export as
; BMP...); SI = the owning window, gfx lock already held (SPEC.md 12.2)
; -----------------------------------------------------------------------------
ct_oncmd:
    or ah, ah                           ; AH = the menu, AL = the item
    jnz .gallery
    or al, al
    jnz .export
    push bx
    push si
    push di
    mov bx, si
    mov di, ct_ondlg
    xor si, si                          ; no default name for Open
    mov al, FDLG_OPEN
    call OSAPI_FILE_DLG
    pop di
    pop si
    pop bx
    ret
.export:
    cmp word [ct_valcnt], 0
    jne .havedata
    push si
    mov si, ct_s_noexp
    call ct_toast
    pop si
    ret
.havedata:
    push bx
    push si
    push di
    mov bx, si
    mov di, ct_expdlg
    mov si, ct_s_chartbmp
    mov al, FDLG_SAVE
    call OSAPI_FILE_DLG
    pop di
    pop si
    pop bx
    ret
; --- Gallery: pick a type and redraw what is already loaded -------------------
; The item index maps to CH_T_* through this table rather than by arithmetic,
; because the menu is in Excel's alphabetical order (Area, Bar, Column, Line)
; and CH_T_* is in the order the drawing code was written.
.gallery:
    push bx
    push si
    xor bh, bh
    mov bl, al
    shl bl, 1
    mov ax, [ct_gal_map + bx]
    mov [ch_type], ax
    cmp word [ct_valcnt], 0
    je .galout                          ; nothing loaded: the type is still
    call ct_render                      ; remembered for the next Open
    call ct_paint
.galout:
    pop si
    pop bx
    ret

; -----------------------------------------------------------------------------
; ct_toast - in: SI = NUL message; shows it as a menu-bar toast for the
; default ~3s (SPEC.md 59). Preserves all registers except flags.
; -----------------------------------------------------------------------------
ct_toast:
    push ax
    push cx
    push es
    push ds
    pop es                              ; the kernel COPIES it (SPEC.md 59.3)
    xor cx, cx
    call OSAPI_TOAST
    pop es
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_ondlg - the Open dialog's completion proc (SPEC.md 38.6). In: AL=mode
; (always 0, Open), SI=our window ptr, DI=chosen name (ES=KERNEL_SEG); UI
; task, gfx lock HELD, dialog already destroyed - we owe the repaint.
; Dispatches by extension into one of the three independent readers, then
; renders and blits whatever was found (zero values renders an empty white
; canvas, same as Sheet's own chart window with nothing charted yet).
; -----------------------------------------------------------------------------
ct_ondlg:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si                          ; bx = our window ptr, stashed
    mov si, di
    mov di, ct_name
    mov ax, CT_NAMEMAX
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
    mov si, ct_name
    mov di, ct_s_ext_dif
    call ct_nameends
    jc .dif
    mov si, ct_name
    mov di, ct_s_ext_biff
    call ct_nameends
    jc .biff
    jmp .sylk
.dif:
    call ct_load_common
    jc .rerr
    call ct_read_dif
    jmp .loaded
.biff:
    call ct_load_common
    jc .rerr
    call ct_read_biff
    jmp .loaded
.sylk:
    call ct_load_common
    jc .rerr
    call ct_read_sylk
.loaded:
    call ct_render
    mov si, bx
    call ct_paint
    cmp word [ct_valcnt], 0
    jne .out
    mov si, ct_s_noval
    call ct_toast
    jmp .out
.rerr:
    mov si, ct_s_readerr
    call ct_toast
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_load_common - read [ct_name] whole into [ct_stgseg]; out: CF=0 and
; ES=[ct_stgseg]/CX=bytes read (ready for a reader to walk), or CF=1 on a
; file error. Clobbers ax, bx, dx, si.
; -----------------------------------------------------------------------------
ct_load_common:
    push ax
    push bx
    push dx
    push si
    mov es, [ct_stgseg]
    xor bx, bx
    mov cx, CT_CLAIM_STG_KB * 1024
    xor dx, dx
    mov si, ct_name
    call OSAPI_FILE_READ                ; out: DX:AX = bytes read, or CF=1
    jc .out
    mov cx, ax                          ; a file this small never exceeds 64KB
    clc
.out:
    pop si
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_expdlg - the Export dialog's completion proc: writes the current
; chart buffer via apps/os88chart.inc's ch_bmp_write.
; -----------------------------------------------------------------------------
ct_expdlg:
    push ax
    push bx
    push si
    push di
    mov si, di
    mov di, ct_name
    mov ax, CT_NAMEMAX
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
    mov es, [ct_chartseg]
    mov bx, [ct_stgseg]
    mov si, ct_name
    call ch_bmp_write
    jnc .ok
    mov si, ct_s_experr
    call ct_toast
    jmp .out
.ok:
    mov si, ct_s_exported
    call ct_toast
.out:
    pop di
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_nameends - in: SI=name (NUL-terminated), DI=suffix (NUL-terminated);
; out: CF=1 if name ends with suffix (case-sensitive: 8.3 names arrive
; already uppercase from the kernel, and so do the suffixes this file
; compares against)
; -----------------------------------------------------------------------------
ct_nameends:
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
    push cx
    xor cx, cx
    mov bx, di
.suflen:
    cmp byte [bx], 0
    je .havesuflen
    inc bx
    inc cx
    jmp .suflen
.havesuflen:
    pop bx                              ; bx = strlen(name), cx = strlen(sfx)
    cmp cx, bx
    ja .no
    mov ax, si
    add ax, bx
    sub ax, cx
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
; ct_pint - parse a signed decimal integer
; in: ES:SI=ptr, BX=limit (exclusive, an offset); also stops at NUL
; out: AX=value, SI=advanced; BX preserved; ES must be set by the caller
; -----------------------------------------------------------------------------
ct_pint:
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
; ct_finalize - given ct_trow/ct_tcol/ct_tval (ct_tcnt entries, any file
; order, any columns), find the LOWEST column among them, keep only the
; entries at that column, sort those by row ascending, and set
; ct_vals/ct_valcnt (capped at CH_MAXBARS) - the shared last step for all
; three readers below.
; -----------------------------------------------------------------------------
; ct_record - offer one cell to the series (the CT_TCAP fix)
; in:  AX = col, BX = row, DX = value. All registers preserved.
;
; THE CAP USED TO BOUND THE SCAN, AND THAT LOST DATA SILENTLY. Each reader
; collected every numeric cell it met into ct_trow/ct_tcol/ct_tval, stopped at
; CT_TCAP of them, and only then did ct_finalize pick the lowest column and
; filter to it. On a wide sheet the temp arrays filled with OTHER columns'
; cells, so two things went wrong at once and neither announced itself: the
; tail of the chosen column was never read, and - worse - ct_mincol was derived
; from a truncated sample, so a lower column appearing later in the file was
; never seen and THE WRONG COLUMN WAS CHARTED. Both produced a plausible chart.
;
; So the filter runs as the file is read instead. The lowest column seen so far
; is the series; a cell BELOW it restarts the collection, a cell IN it is
; appended, a cell ABOVE it is dropped. One pass still, no second read, and the
; cap now bounds the KEPT SERIES rather than the scanned candidates - which is
; why it is CH_MAXBARS here and not CT_TCAP.
; -----------------------------------------------------------------------------
ct_record:
    push ax
    push bx
    push cx
    push si
    cmp word [ct_tcnt], 0
    je .newcol                        ; nothing yet: this cell defines it
    cmp ax, [ct_mincol]
    ja .out                           ; a higher column is not the series
    je .append
.newcol:                              ; a LOWER column supersedes everything
    mov [ct_mincol], ax               ; collected so far
    mov word [ct_tcnt], 0
.append:
    mov cx, [ct_tcnt]
    cmp cx, CH_MAXBARS
    jae .out                          ; the series is full; a longer column is
                                       ; truncated, which ct_finalize's own
                                       ; CH_MAXBARS limit already implied
    mov si, cx
    shl si, 1
    mov [ct_tcol + si], ax
    mov [ct_trow + si], bx
    mov [ct_tval + si], dx
    inc word [ct_tcnt]
.out:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
ct_finalize:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [ct_valcnt], 0
    cmp word [ct_tcnt], 0
    je .done
                                        ; ct_mincol is ALREADY the lowest
                                        ; column and every collected cell is
                                        ; already in it - ct_record maintained
                                        ; both as the file was read, so the
                                        ; scan that used to derive it here is
                                        ; gone. The column test below is kept
                                        ; as a cheap invariant check rather
                                        ; than as a filter that still does
                                        ; work.
    xor cx, cx
.collect:
    cmp cx, [ct_tcnt]
    jae .sortit
    mov ax, [ct_valcnt]
    cmp ax, CH_MAXBARS
    jae .sortit
    mov si, cx
    shl si, 1
    mov bx, [ct_tcol + si]
    cmp bx, [ct_mincol]
    jne .cnext
    mov dx, [ct_trow + si]
    mov bx, [ct_tval + si]
    mov ax, [ct_valcnt]
    mov si, ax
    shl si, 1
    mov [ct_vrow + si], dx
    mov [ct_vals + si], bx
    inc word [ct_valcnt]
.cnext:
    inc cx
    jmp .collect
.sortit:                                ; insertion sort, ct_vrow/ct_vals
    mov cx, 1                           ; together, ascending by row - at
.outer:                                 ; most CH_MAXBARS=40 items, so an
    cmp cx, [ct_valcnt]                 ; O(n^2) sort costs nothing that
    jae .done                           ; matters here
    mov si, cx
    shl si, 1
.inner:
    or si, si
    jz .outernext
    mov ax, [ct_vrow + si]
    mov bx, [ct_vrow + si - 2]
    cmp ax, bx
    jae .outernext
    xchg ax, bx
    mov [ct_vrow + si], ax
    mov [ct_vrow + si - 2], bx
    mov ax, [ct_vals + si]
    mov bx, [ct_vals + si - 2]
    xchg ax, bx
    mov [ct_vals + si], ax
    mov [ct_vals + si - 2], bx
    sub si, 2
    jmp .inner
.outernext:
    inc cx
    jmp .outer
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_rkdec - a verbatim duplicate of apps/sheet/sheet.asm's own sh_rkdec:
; small and fully self-contained (no dependency on anything else in that
; file), so duplicating it exactly here is safe where reusing a whole
; reader would not be (see this file's own header comment).
; in: DX:AX = a packed RK value (AX low word, DX high word); out: CF=0 and
; AX=the signed 16-bit value if it's the "integer, not multiplied"
; subtype this project's own writer emits, else CF=1 (out of this
; subset's scope - skip the cell rather than guess at a float or *100
; value)
; -----------------------------------------------------------------------------
ct_rkdec:
    test al, 0x01
    jnz .unsupported
    test al, 0x02
    jz .unsupported
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
; ct_read_biff - in: ES=[ct_stgseg], CX=byte length already read there.
; Walks real [opcode:word][length:word] BIFF record headers; on an RK cell
; record (0x027E: row,col,xf,rk_lo,rk_hi, 10 bytes) decodes the value via
; ct_rkdec and records (row,col,value) for ct_finalize, capped at
; ct_record, which keeps only the lowest column. Stops at EOF (0x000A) or
; a truncated trailing record.
; -----------------------------------------------------------------------------
ct_read_biff:
    push ax
    push bx
    push dx
    push si
    mov word [ct_tcnt], 0
    xor si, si
.rechdr:
    mov ax, si
    add ax, 4
    cmp ax, cx
    ja .done
    mov ax, [es:si]                     ; opcode
    mov dx, [es:si+2]                   ; length
    add si, 4
    cmp ax, 0x000A                      ; EOF
    je .done
    cmp ax, 0x027E                      ; RK cell record
    jne .skip
    push dx                             ; length, saved across the decode
    mov ax, si
    add ax, dx
    cmp ax, cx
    ja .toolong
    push word [es:si]                   ; row
    push word [es:si+2]                 ; col
    mov ax, [es:si+6]                   ; rk lo
    mov dx, [es:si+8]                   ; rk hi
    call ct_rkdec                       ; -> CF=1 unsupported, else AX=value
    jc .rkskip
    mov dx, ax                          ; dx = value
    pop ax                              ; ax = col
    pop bx                              ; bx = row
    call ct_record
    jmp .rkdone
.rkskip:
    pop dx                              ; discard col
    pop dx                              ; discard row
.rkdone:
    pop dx                              ; length, restored
    jmp .skip
.toolong:
    pop dx                              ; length, restored (discard)
    jmp .done
.skip:
    add si, dx
    jmp .rechdr
.done:
    pop si
    pop dx
    pop bx
    pop ax
    call ct_finalize
    ret

; -----------------------------------------------------------------------------
; ct_read_sylk - in: ES=[ct_stgseg], CX=byte length already read there.
; Line-oriented: any line shaped "C;<tokens>" is a candidate cell record.
; Tokens are order-independent, ';'-separated, 1-based X (col)/Y (row)/K
; (value) - real SYLK's own C-record grammar. Only a line carrying an
; explicit K is recorded (an omitted X or Y is treated as invalid, not
; "sticky" from a prior line - the same simplification Sheet's own
; sh_parsecrec makes). Records (row,col,value) for ct_finalize, capped at
; ct_record, which keeps only the lowest column.
; -----------------------------------------------------------------------------
ct_read_sylk:
    push ax
    push bx
    push dx
    push si
    push di
    mov word [ct_tcnt], 0
    mov di, cx                          ; di = end offset
    xor si, si
.lineloop:
    cmp si, di
    jae .done
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
    cmp byte [es:si], 'C'
    jne .advance
    cmp byte [es:si+1], ';'
    jne .advance
    push si
    add si, 2
    call ct_parse_c                     ; in: si=tokens start, bx=line end
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
.done:
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    call ct_finalize
    ret

; -----------------------------------------------------------------------------
; ct_parse_c - the fields of one 'C' record; in: SI=tokens start (right
; after "C;"), BX=line end (exclusive); ES=[ct_stgseg], same buffer
; ct_read_sylk is walking
; -----------------------------------------------------------------------------
ct_parse_c:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [ct_pcol], 0
    mov word [ct_prow], 0
    mov word [ct_pval], 0
    mov byte [ct_phave], 0
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
    call ct_pint
    mov [ct_pcol], ax
    jmp .tok
.isy:
    inc si
    call ct_pint
    mov [ct_prow], ax
    jmp .tok
.isk:
    inc si
    call ct_pint
    mov [ct_pval], ax
    mov byte [ct_phave], 1
    jmp .tok
.apply:
    cmp byte [ct_phave], 0
    je .out
    mov ax, [ct_pcol]
    cmp ax, 1
    jb .out
    mov cx, [ct_prow]
    cmp cx, 1
    jb .out
    dec ax                              ; 1-based -> 0-based
    dec cx
    mov bx, cx                          ; bx = row, ax = col
    mov dx, [ct_pval]
    call ct_record
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_difskipline - advance SI past the rest of the current line and every
; trailing CR/LF (DI = end offset, module-scoped like ct_read_dif's own)
; -----------------------------------------------------------------------------
ct_difskipline:
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
; ct_is_bot_line - in: SI=line start, DI=end (exclusive); out: CF=1 if the
; line at SI is exactly "BOT" (the real DIF row marker), else CF=0. Does
; not advance SI.
; -----------------------------------------------------------------------------
ct_is_bot_line:
    push ax
    push bx
    mov bx, si
    add bx, 3
    cmp bx, di
    ja .no
    cmp byte [es:si], 'B'
    jne .no
    cmp byte [es:si+1], 'O'
    jne .no
    cmp byte [es:si+2], 'T'
    jne .no
    cmp bx, di
    jae .yes
    mov al, [es:bx]
    cmp al, 13
    je .yes
    cmp al, 10
    je .yes
    jmp .no
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; ct_read_dif - in: ES=[ct_stgseg], CX=byte length already read there.
; Skips the header STRUCTURALLY - unlike Sheet's own closed-loop DIF
; reader, which safely assumes its own writer's fixed 12-line header, this
; reads files it did not write, so it scans line by line for the first
; line that is exactly "BOT" (the real DIF row marker) rather than
; assuming any particular header length. From there, walks rows exactly
; like the grammar this project's own writer emits (each row: "-1,0" then
; "BOT"; each cell: "0,<value>" then "V", or anything else, meaning
; NA/blank). Offers (row,col,value) to ct_record, which keeps the lowest
; column and caps the series at CH_MAXBARS.
; -----------------------------------------------------------------------------
ct_read_dif:
    push ax
    push bx
    push dx
    push si
    push di
    mov word [ct_tcnt], 0
    mov di, cx                          ; di = end offset
    xor si, si
.hdrscan:
    cmp si, di
    jae .done                           ; no BOT anywhere: no data
    call ct_is_bot_line
    jc .foundbot
    call ct_difskipline
    jmp .hdrscan
.foundbot:
    call ct_difskipline                 ; consume the first row's BOT line
    mov word [ct_wrow], 0
    mov word [ct_wcol], 0
    jmp .cellloop
.rowloop:
    cmp si, di
    jae .done
    call ct_difskipline                 ; the "-1,0" line
    cmp si, di
    jae .done
    mov al, [es:si]
    cmp al, 'E'                         ; EOD
    je .done
    call ct_difskipline                 ; the "BOT" line
    mov ax, [ct_wrow]
    inc ax
    mov [ct_wrow], ax
    mov word [ct_wcol], 0
.cellloop:
    cmp si, di
    jae .done
    mov al, [es:si]
    cmp al, '-'
    je .rowloop                         ; the next row's "-1,0"
    cmp al, '0'
    jne .skipunknown                    ; type 1 (string/NA) or unknown
    add si, 2                           ; past "0,"
    mov bx, di
    call ct_pint                        ; -> ax=value, si past the digits
    mov [ct_pval], ax
    call ct_difskipline                 ; finish the "0,<value>" line
    cmp si, di
    jae .cellnext
    cmp byte [es:si], 'V'               ; the real DIF value-indicator
    jne .notvalid
    mov bx, [ct_wrow]
    mov ax, [ct_wcol]
    mov dx, [ct_pval]
    call ct_record
.notvalid:
    call ct_difskipline                 ; the indicator line
    jmp .cellnext
.skipunknown:
    call ct_difskipline
    cmp si, di
    jae .cellnext
    call ct_difskipline                 ; every cell is exactly two lines
.cellnext:
    mov ax, [ct_wcol]
    inc ax
    mov [ct_wcol], ax
    jmp .cellloop
.done:
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    call ct_finalize
    ret

; --- window template (SPEC.md 11: 16 bytes, 8 words) ---------------------------
ct_tpl:
    dw 0, 0, CT_WIN_W, CT_WIN_H
    dw ct_s_title, ct_paint, 0, 0       ; no onkey/onclick - pure display

; --- the app menu set (SPEC.md 12.2) -------------------------------------------
    OS88_MENUSET ct_menus, ct_name_app, ct_oncmd
        OS88_MENU ct_m_file, ct_i_file, 2
        OS88_MENU ct_m_gallery, ct_i_gallery, 5
    OS88_MENUSET_END ct_menus

ct_name_app: db 'Chart', 0
ct_m_file:   db 'File', 0
ct_i_file:   dw ct_it_open, ct_it_exp
ct_it_open:  db 'Open...', 0
ct_it_exp:   db 'Export as BMP...', 0

; Excel 2.1d's Gallery menu is Area/Bar/Column/Line/Pie/Scatter/Combination.
; These FIVE are the ones a single series can express - Pie joined them once
; os88chart.inc got its own sine table (82.6). Scatter and Combination need
; TWO series, which is a data-model problem rather than a drawing one, and
; they stay out rather than appear and disappoint. THE ORDER MATCHES
; ct_gal_map below, which is indexed by the item number - keep them in step.
ct_m_gallery: db 'Gallery', 0
ct_i_gallery: dw ct_it_area, ct_it_bar, ct_it_col, ct_it_line, ct_it_pie
ct_it_area:   db 'Area', 0
ct_it_bar:    db 'Bar', 0
ct_it_col:    db 'Column', 0
ct_it_line:   db 'Line', 0
ct_it_pie:    db 'Pie', 0

ct_gal_map:    dw CH_T_AREA, CH_T_BAR, CH_T_COLUMN, CH_T_LINE, CH_T_PIE
ct_s_title:    db 'Chart', 0
ct_s_chartbmp: db 'CHART.BMP', 0
ct_s_noexp:    db 'No chart to export.', 0
ct_s_experr:   db 'Chart export failed.', 0
ct_s_exported: db 'Chart exported.', 0
ct_s_readerr:  db 'Could not read that file.', 0
ct_s_noval:    db 'No numeric data found.', 0
ct_s_ext_dif:  db '.DIF', 0
ct_s_ext_biff: db '.BIF', 0

; stage: shared rasterizer + BMP writer - see that file's own header
; comment for the CH_* constants and ch_* bss words it requires, both
; declared above. Included here, just before OS88_BSS, for the same
; fixed-offset reason its own header states: code between the header and
; here would break the icon macro's fixed-offset assertion (this package
; has no icon, but the same %include-at-the-end rule still applies) and
; would move the entry point.
%include "os88chart.inc"

; =============================================================================
; bss (loader-zeroed, SPEC.md 21 step 5)
; =============================================================================
    OS88_BSS 511
    OS88_IMAGE_END

ct_chartseg equ os88_image_end + 0  ; word: the offscreen canvas claim
ct_stgseg   equ ct_chartseg + 2     ; word: file-read/BMP-export staging
ct_name     equ ct_stgseg + 2       ; 13: the opened/exported file's 8.3 name
ct_valcnt   equ ct_name + 13        ; word: values currently charted
ct_vals     equ ct_valcnt + 2       ; CH_MAXBARS words: the charted values
ct_vrow     equ ct_vals + CH_MAXBARS*2   ; CH_MAXBARS words: scratch rows,
                                          ; paired with ct_vals during
                                          ; ct_finalize's sort, unused after
ct_mincol   equ ct_vrow + CH_MAXBARS*2   ; word: ct_finalize's own scratch
ct_tcnt     equ ct_mincol + 2       ; word: how many candidates are in
                                     ; ct_trow/ct_tcol/ct_tval right now
ct_trow     equ ct_tcnt + 2         ; CH_MAXBARS words: the series' rows
ct_tcol     equ ct_trow + CH_MAXBARS*2  ; ...their columns (all equal)
ct_tval     equ ct_tcol + CH_MAXBARS*2  ; ...and their values
ct_pcol     equ ct_tval + CH_MAXBARS*2  ; word: ct_parse_c's own scratch
ct_prow     equ ct_pcol + 2         ; word: ct_parse_c's own scratch
ct_pval     equ ct_prow + 2         ; word: shared scratch (ct_parse_c AND
                                     ; ct_read_dif's own per-cell value -
                                     ; never live across both at once)
ct_phave    equ ct_pval + 2         ; byte: ct_parse_c's own scratch
ct_wrow     equ ct_phave + 1        ; word: ct_read_dif's own row counter
ct_wcol     equ ct_wrow + 2         ; word: ct_read_dif's own col counter

; --- apps/os88chart.inc's own required scratch (see its header comment) -------
ch_max      equ ct_wcol + 2
ch_base     equ ch_max + 2
ch_arr      equ ch_base + 2
ch_cnt      equ ch_arr + 2
ch_idx      equ ch_cnt + 2
ch_bx1      equ ch_idx + 2
ch_by1      equ ch_bx1 + 2
ch_bx2      equ ch_by1 + 2
ch_by2      equ ch_bx2 + 2
ch_srcseg   equ ch_by2 + 2
ch_stgseg   equ ch_srcseg + 2
ch_neg      equ ch_stgseg + 2     ; stage 3.0f: 1 = some value is
                                       ; negative. Its own word now: the axis
                                       ; row is type-dependent, so ch_base
                                       ; cannot carry this as well.
ch_type     equ ch_neg + 2       ; CH_T_* - which chart to draw
ch_lx0      equ ch_type + 2      ; the current segment's endpoints and
ch_ly0      equ ch_lx0 + 2       ; the column being interpolated -
ch_lx1      equ ch_ly0 + 2       ; CALLER bss like every other ch_*
ch_ly1      equ ch_lx1 + 2       ; word, for the same DS reason
ch_lcx      equ ch_ly1 + 2
ch_pie_px      equ ch_lcx + 2       ; --- stage 3.0f: the pie ---
ch_pie_py      equ ch_pie_px + 2
ch_pie_ex      equ ch_pie_py + 2    ; ch_ray's endpoint and its Bresenham
ch_pie_ey      equ ch_pie_ex + 2    ; state - in bss for the same DS reason
ch_pie_x       equ ch_pie_ey + 2    ; every other ch_* word is
ch_pie_y       equ ch_pie_x + 2
ch_pie_dx      equ ch_pie_y + 2
ch_pie_dy      equ ch_pie_dx + 2
ch_pie_sx      equ ch_pie_dy + 2
ch_pie_sy      equ ch_pie_sx + 2
ch_pie_err     equ ch_pie_sy + 2
ch_pie_e2      equ ch_pie_err + 2
ch_pie_tlo     equ ch_pie_e2 + 2    ; the 32-bit total and how far it was
ch_pie_thi     equ ch_pie_tlo + 2   ; shifted to fit a word
ch_pie_shift   equ ch_pie_thi + 2
ch_pie_a0      equ ch_pie_shift + 2 ; this slice's first half-degree...
ch_pie_span    equ ch_pie_a0 + 2    ; ...how many it covers...
ch_pie_a       equ ch_pie_span + 2  ; ...and the sweep's current one
ch_pie_col     equ ch_pie_a + 2
ch_pie_thick   equ ch_pie_col + 2    ; byte: this ray fills, so it is 3px
ch_pie_pen     equ ch_pie_thick + 1  ; byte: the colour ch_setpixel keeps
ch_pie_pat     equ ch_pie_pen + 1    ; byte: this slice's hatch, FF = solid
ct_bss_end  equ ch_pie_pat + 1

; -----------------------------------------------------------------------------
; The bss size above is a PLAIN LITERAL that nothing cross-checks, and setting
; it low is silent corruption of whatever the loader placed next rather than a
; build error. It cannot be written as an expression: OS88_BSS_SIZE goes into
; the package header's dw at a FIXED OFFSET (SPEC.md 20.2), so it must be known
; on pass 1, and a forward reference to a label defined down here makes NASM
; size instructions differently per pass.
;
; So it stays a literal and this asserts it. A mismatch drives one of the two
; TIMES counts negative, which -w+error turns into a build failure naming the
; exact shortfall; both are zero when the literal is right, so nothing is
; emitted. READ THE LINE NUMBER, not just the sign - the two report the same
; shortfall with opposite signs, so which one fired is what says whether the
; literal is too small or too large.
; -----------------------------------------------------------------------------
%define CT_BSS_NEED (ct_bss_end - os88_image_end)
    times (CT_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - CT_BSS_NEED) db 0
