; =============================================================================
; os8088 - apps/word/wdrtf.inc
;
; RTF IN AND OUT (SPEC.md 68.8) - Word's other portable format, and the one
; that is pure text transform: Opus/RTFOUT.C writes it and Opus/RTFIN.C reads
; it, neither touching Windows. Both directions live here.
;
; The extension decides which format a save writes: a name ending .RTF gets
; this, everything else gets the Word file (SPEC.md 68.4). On the way in the
; CONTENT decides - a file beginning '{\rtf' is RTF whatever it is called -
; because a file that arrives from elsewhere may be named anything.
; =============================================================================

WD_RTFDEPTH  equ 16             ; group nesting. Word's own reader has a
                                ; limit too; past this the import stops with
                                ; a toast and keeps what it had
WD_RTFCW     equ 20             ; the longest control word this reads

; =============================================================================
; THE WRITER
; =============================================================================

; -----------------------------------------------------------------------------
; wd_rtfimg - assemble the RTF text into the staging claim
; in:  ES = the staging claim, DS = the package
; out: CF=0 and [wd_dend] = the byte count; CF=1 = it did not fit.
;      Clobbers AX BX CX DX SI DI.
; -----------------------------------------------------------------------------
wd_rtfimg:
    cld
    xor di, di
    mov byte [wd_rfull], 0
    mov si, wd_r_head
    call wd_res
    xor bx, bx                      ; BX = the character index
    mov byte [wd_rat], 0            ; the attributes currently OPEN
    mov byte [wd_rnew], 1           ; a paragraph is about to start
.step:
    cmp byte [wd_rnew], 0
    je .body
    mov byte [wd_rnew], 0
    call wd_rpap                    ; \pard plus this paragraph's own
    mov byte [wd_rat], 0            ; controls; \plain closed every run
.body:
    cmp bx, [wd_len]
    jae .tail
    push ds
    PKG_LDS wd_dseg
    mov al, [bx]
    pop ds
    cmp al, 13
    je .para
    cmp al, WD_PICCH                ; a picture is its own group and wears no
    je .pict                        ; character formatting (86.5)
    push ax
    push ds
    PKG_LDS wd_cseg
    mov al, [bx]
    pop ds
    call wd_rdress                  ; open/close what this character wears
    pop ax
    call wd_rch
    inc bx
    jmp short .step
.pict:
    call wd_rpict
    inc bx
    jmp short .step
.para:
    mov si, wd_r_par
    call wd_res
    inc bx
    mov byte [wd_rnew], 1
    jmp short .step
.tail:
    mov si, wd_r_par                ; the tail paragraph's own \par: a Word
    call wd_res                     ; file's text ends with a mark and so
    mov si, wd_r_tail               ; does RTF's (SPEC.md 68.4)
    call wd_res
    mov [wd_dend], di
    cmp byte [wd_rfull], 0
    jne .no
    clc
    ret
.no:
    stc
    ret

; =============================================================================
; wd_rpict - emit the picture the WD_PICCH at BX names, as an RTF \pict group
; in:  BX = the character index; ES = the staging claim, DS = the package
; out: preserves every register. A character naming no picture emits NOTHING,
;      which is the same thing the screen does with it (wd_rowhc).
;
; THIS IS THE ONE PLACE SCRIBE WRITES SOMETHING WORD DOES NOT, and RTF is the
; format where that is safe rather than reckless (SPEC.md 86.5). RTF is text
; and its own rule is that a reader skips a destination it does not know, so
; the worst a foreign reader can do with this group is drop it and keep the
; document. The same picture in a .DOC would be a binary field that a reader
; does not skip but BELIEVES.
;
; It is not an invented dialect either - every control word here is RTF's own:
;
;   \pict           the destination
;   \wbitmap 0      a Windows bitmap, bmType 0
;   \wbmplanes 1    ONE plane of...
;   \wbmbitspixel 4 ...4-bit pixels: os8088's packed 4bpp exactly, two to a
;                   byte with the high nibble leftmost, so a load is a copy
;                   and not a conversion
;   \wbmwidthbytes  the stride, carried and never recomputed - the lesson
;                   .PCX's BytesPerLine taught (SPEC.md 85)
;   \picw \pich     pixels
;   \picwgoal \pichgoal   twips, at 15 per pixel = 96dpi, the Windows
;                   logical inch. Display size, not storage size.
;
; NO PALETTE, AND THAT IS CORRECT RATHER THAN LAZY. A \wbitmap is a
; DEVICE-dependent bitmap: its indices mean whatever the device's colours are.
; os8088's sixteen are fixed (SPEC.md 6.3), so an index IS a colour here and a
; palette would be restating the device. \dibitmap is the device-INdependent
; form that carries one, and it costs a BITMAPINFO and a second layout for a
; picture that is always displayed on the machine that wrote it.
;
; THE DATA IS HEX, at two characters a byte. That is twice the size of RTF's
; \bin and it keeps SPEC.md 68.8's "pure text transform" property, which is
; worth more than the bytes: a \bin run can contain 0x7D and any reader that
; is not counting exactly right sees a group end in the middle of a picture.
; The cost is a real ceiling - the staging claim is WD_DOCCAP KB addressed by
; a 16-bit DI - so about 30KB of picture across a document. wd_re already
; stops on a full claim and wd_rtfimg already turns that into "it did not
; fit", so the limit refuses rather than truncates.
; =============================================================================
wd_rpict:
    push ax
    push bx
    push cx
    push dx
    push si
    push es
    push ds
    PKG_LDS wd_cseg            ; the CHP byte IS the picture index
    mov al, [bx]                    ; (SPEC.md 68.15)
    pop ds
    xor ah, ah
    call far [wd_v_picrec]; -> BX = the table slot
    jc .out                         ; names no picture: emit nothing
    mov ax, [bx]
    mov [wd_rpw], ax
    mov ax, [bx+2]
    mov [wd_rph], ax
    mov ax, [bx+4]
    mov [wd_rps], ax
    mov ax, [bx+6]
    mov [wd_rpg], ax
    or ax, ax                       ; a slot with no segment is a picture that
    jz .out                         ; was freed; it draws nothing either
    mov si, wd_r_pict               ; '{\pict\wbitmap0\wbmplanes1'
    call wd_res                     ; '\wbmbitspixel4\wbmwidthbytes'
    mov ax, [wd_rps]
    call wd_rnum
    mov si, wd_r_picw
    call wd_res
    mov ax, [wd_rpw]
    call wd_rnum
    mov si, wd_r_pich
    call wd_res
    mov ax, [wd_rph]
    call wd_rnum
    mov si, wd_r_picwg              ; the GOAL size, in twips at 96dpi. The
    call wd_res                     ; widest picture os88img.inc will decode
    mov ax, [wd_rpw]                ; is 1280, and 1280*15 = 19200, so this
    call wd_rtwip                   ; cannot overflow the word wd_rnum signs
    mov si, wd_r_pichg
    call wd_res
    mov ax, [wd_rph]
    call wd_rtwip
    mov word [wd_rpcol], 0
    mov dx, [wd_rph]                ; DX = rows left
.row:
    or dx, dx
    jz .fin
    mov cx, [wd_rps]                ; CX = bytes in this row
    mov bx, [wd_rph]                ; the source offset: (h - dx) * stride
    sub bx, dx
    mov ax, bx
    mul word [wd_rps]               ; DX is clobbered by mul, so it is banked
    mov si, ax                      ; ...and restored below
    mov dx, [wd_rph]
    sub dx, bx
    dec dx                          ; DX = rows left AFTER this one
.byte:
    push es
    mov es, [wd_rpg]                ; the picture is a THIRD segment: ES is
    mov al, [es:si]                 ; the staging claim everywhere else in
    pop es                          ; this file, so it is borrowed per byte
    call wd_rwhex
    inc si
    inc word [wd_rpcol]
    cmp word [wd_rpcol], 64         ; wrap the hex, so the file is readable
    jb .nowrap                      ; and no line is 17,000 characters long
    mov word [wd_rpcol], 0
    mov al, 13
    call wd_re
    mov al, 10
    call wd_re
.nowrap:
    loop .byte
    jmp short .row
.fin:
    mov al, '}'
    call wd_re
.out:
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_rtwip - emit AX pixels as twips (x15) followed by a space. Preserves all
; but flags. 15 twips is one pixel at the 96dpi Windows logical inch.
wd_rtwip:
    push ax
    push dx
    mov dx, 15
    mul dx                          ; DX:AX, and the high half is always 0
    call wd_rnum                    ; for a width os88img.inc would accept
    pop dx
    pop ax
    ret

; wd_rwhex - emit AL as two lowercase hex digits. Preserves all but flags.
wd_rwhex:
    push ax
    push cx
    mov ah, al
    mov cl, 4
    shr al, cl                      ; the HIGH nibble first, which is also the
    call wd_rwhex1                   ; leftmost pixel (SPEC.md 85)
    mov al, ah
    and al, 0x0F
    call wd_rwhex1
    pop cx
    pop ax
    ret

wd_rwhex1:
    push ax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .emit
    add al, 'a' - '0' - 10
.emit:
    call wd_re
    pop ax
    ret

; wd_rch - emit one document character, escaped. Preserves all but flags.
wd_rch:
    push ax
    push si
    cmp al, 9
    je .tab
    cmp al, '\'
    je .esc
    cmp al, '{'
    je .esc
    cmp al, '}'
    je .esc
    cmp al, 32
    jb .out
    cmp al, 126
    ja .out
    call wd_re
    jmp short .out
.esc:
    push ax
    mov al, '\'
    call wd_re
    pop ax
    call wd_re
    jmp short .out
.tab:
    mov si, wd_r_tab
    call wd_res
.out:
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_rdress - emit the controls that turn AL's attributes on and the ones
;             that turn the previous run's off
; in:  AL = the attribute byte this character wears
; out: [wd_rat] = AL; preserves all registers
; -----------------------------------------------------------------------------
wd_rdress:
    push ax
    push bx
    push cx
    push si
    mov cl, al
    mov ch, [wd_rat]
    cmp cl, ch
    je .out
    mov bl, cl
    xor bl, ch                      ; BL = what changed
    test bl, WDAT_BOLD
    jz .ni
    mov si, wd_r_b
    test cl, WDAT_BOLD
    jnz .b1
    mov si, wd_r_b0
.b1:
    call wd_res
.ni:
    test bl, WDAT_ITAL
    jz .ns
    mov si, wd_r_i
    test cl, WDAT_ITAL
    jnz .i1
    mov si, wd_r_i0
.i1:
    call wd_res
.ns:
    test bl, WDAT_SCAP
    jz .nh
    mov si, wd_r_sc
    test cl, WDAT_SCAP
    jnz .s1
    mov si, wd_r_sc0
.s1:
    call wd_res
.nh:
    test bl, WDAT_HID
    jz .nu
    mov si, wd_r_v
    test cl, WDAT_HID
    jnz .h1
    mov si, wd_r_v0
.h1:
    call wd_res
.nu:
    mov al, bl                      ; the three underlines are one state, so
    and al, WDAT_UL|WDAT_WUL|WDAT_DUL   ; any change closes and reopens
    jz .done
    mov si, wd_r_ul0
    call wd_res
    mov si, wd_r_ul
    test cl, WDAT_UL
    jnz .u1
    mov si, wd_r_ulw
    test cl, WDAT_WUL
    jnz .u1
    mov si, wd_r_uld
    test cl, WDAT_DUL
    jnz .u1
    jmp short .done
.u1:
    call wd_res
.done:
    mov [wd_rat], cl
.out:
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_rpap - emit \pard\plain and the controls of the paragraph starting at BX
; Preserves all registers.
; -----------------------------------------------------------------------------
wd_rpap:
    push ax
    push bx
    push cx
    push dx
    push si
    push ds
    mov si, wd_r_pard
    call wd_res
    call wd_rpapidx                 ; AL = the paragraph's dictionary index
    xor ah, ah
    mov si, ax
    shl si, 1
    shl si, 1
    PKG_LDS wd_pseg
    mov ax, [si]
    mov bx, [si+2]
    push cs
    pop ds
    mov [wd_rpp], ax                ; the four PAP bytes are BANKED, not held
    mov [wd_rpp+2], bx              ; in registers: SI is the string pointer
                                    ; every emit below needs
    mov al, [wd_rpp]
    and al, WDPA_ALIGN
    jz .nj                          ; left is \pard's own default
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov si, [cs:bx+wd_r_qtab]     ; (SPEC.md 86.8.2)
    call wd_res
.nj:
    mov al, [wd_rpp+1]              ; left indent
    or al, al
    jz .nl
    xor ah, ah
    call wd_dtwip
    push ax
    mov si, wd_r_li
    call wd_res
    pop ax
    call wd_rnum
.nl:
    mov al, [wd_rpp+2]              ; first-line indent, SIGNED
    or al, al
    jz .nf
    cbw
    call wd_dtwip
    push ax
    mov si, wd_r_fi
    call wd_res
    pop ax
    call wd_rnum
.nf:
    mov al, [wd_rpp+3]              ; right indent
    or al, al
    jz .nr
    xor ah, ah
    call wd_dtwip
    push ax
    mov si, wd_r_ri
    call wd_res
    pop ax
    call wd_rnum
.nr:
    mov al, [wd_rpp]                ; line spacing: 0/1/2 -> 240/360/480
    and al, WDPA_SPACE
    jz .nsp
    shr al, 1
    shr al, 1
    xor ah, ah
    mov cx, 120
    mul cx
    add ax, 240
    push ax
    mov si, wd_r_sl
    call wd_res
    pop ax
    call wd_rnum
.nsp:
    test byte [wd_rpp], WDPA_SB     ; space before: half a line, 120 twips
    jz .nsb
    mov si, wd_r_sb
    call wd_res
    mov ax, 120
    call wd_rnum
.nsb:
                                    ; NO trailing space here: every control
                                    ; word this emits already carries the one
                                    ; that delimits it (the literal strings
                                    ; end in one, wd_rnum appends one), and a
                                    ; second space is TEXT - it arrived as a
                                    ; leading space on every paragraph
    pop ds
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_rpapidx - AL = the PAP index of the paragraph starting at BX. Preserves
; all other registers.
wd_rpapidx:
    push bx
    push cx
    push ds
    PKG_LD cx, wd_len
    PKG_LDS wd_dseg
.scan:
    cmp bx, cx
    jae .tail
    cmp byte [bx], 13
    je .mark
    inc bx
    jmp short .scan
.mark:
    PKG_LDS wd_cseg
    mov al, [bx]
    jmp short .out
.tail:
    PKG_LD al, wd_pap_tail
.out:
    pop ds
    pop cx
    pop bx
    ret

; wd_re - emit AL into the staging claim at ES:DI. Sets [wd_rfull] and stops
; storing once the claim is full. Preserves all registers but DI.
wd_re:
    cmp di, WD_DOCCAP * 1024 - 2
    jae .full
    mov [es:di], al
    inc di
    ret
.full:
    mov byte [wd_rfull], 1
    ret

; wd_res - emit the NUL-terminated CS string at SI. Preserves all but DI.
wd_res:
    push ax
    push si
.step:
    mov al, [cs:si]
    or al, al
    jz .out
    inc si
    call wd_re
    jmp short .step
.out:
    pop si
    pop ax
    ret

; wd_rnum - emit signed AX in decimal, then one space. Preserves all but DI.
wd_rnum:
    push ax
    push bx
    push cx
    push dx
    or ax, ax
    jge .pos
    neg ax
    push ax
    mov al, '-'
    call wd_re
    pop ax
.pos:
    mov cx, 0
    mov bx, 10
.div:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .div
.emit:
    pop ax
    add al, '0'
    call wd_re
    loop .emit
    mov al, ' '
    call wd_re
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- the writer's strings ----------------------------------------------------
wd_r_head: db '{\rtf1\ansi\deff0{\fonttbl{\f0\fmodern Courier New;}}', 13, 10
           db '{\stylesheet{\snext0 Normal;}}', 13, 10, 0
wd_r_tail: db '}', 13, 10, 0
wd_r_pict:  db '{\pict\wbitmap0\wbmplanes1\wbmbitspixel4\wbmwidthbytes', 0
wd_r_picw:  db '\picw', 0
wd_r_pich:  db '\pich', 0
wd_r_picwg: db '\picwgoal', 0
wd_r_pichg: db '\pichgoal', 0
wd_r_pard: db '\pard\plain ', 0
wd_r_par:  db '\par', 13, 10, 0
wd_r_tab:  db '\tab ', 0
wd_r_b:    db '\b ', 0
wd_r_b0:   db '\b0 ', 0
wd_r_i:    db '\i ', 0
wd_r_i0:   db '\i0 ', 0
wd_r_sc:   db '\scaps ', 0
wd_r_sc0:  db '\scaps0 ', 0
wd_r_v:    db '\v ', 0
wd_r_v0:   db '\v0 ', 0
wd_r_ul:   db '\ul ', 0
wd_r_ulw:  db '\ulw ', 0
wd_r_uld:  db '\uldb ', 0
wd_r_ul0:  db '\ulnone ', 0
wd_r_ql:   db '\ql ', 0
wd_r_qc:   db '\qc ', 0
wd_r_qr:   db '\qr ', 0
wd_r_qj:   db '\qj ', 0
wd_r_li:   db '\li', 0
wd_r_fi:   db '\fi', 0
wd_r_ri:   db '\ri', 0
wd_r_sl:   db '\sl', 0
wd_r_sb:   db '\sb', 0
wd_r_qtab: dw wd_r_ql, wd_r_qc, wd_r_qr, wd_r_qj

; =============================================================================
; THE READER
; =============================================================================

; wd_isrtfimg - does the staging claim begin '{\rtf'?
; in:  AX = the file's byte count; out: CF=0 = yes. Preserves every register.
wd_isrtfimg:
    push ax
    push si
    push es
    mov es, [wd_stgseg]
    cmp ax, 5
    jb .no
    cmp byte [es:0], '{'
    jne .no
    cmp byte [es:1], '\'
    jne .no
    cmp byte [es:2], 'r'
    jne .no
    cmp byte [es:3], 't'
    jne .no
    cmp byte [es:4], 'f'
    jne .no
    pop es
    pop si
    pop ax
    clc
    ret
.no:
    pop es
    pop si
    pop ax
    stc
    ret

; -----------------------------------------------------------------------------
; wd_rtfparse - read the RTF in the staging claim into the document
; in:  [wd_stgseg], AX = the file's byte count
; out: CF=0 loaded, CF=1 refused. Clobbers everything.
;
; A tokeniser over groups, control words, control symbols and text, with a
; group stack that saves and restores the character attributes so a \b's
; scope ends with its group, and a destination rule: {\* ...} and the known
; non-text destinations are skipped whole (SPEC.md 68.8).
; -----------------------------------------------------------------------------
wd_rtfparse:
    mov [wd_dfsize], ax
    mov byte [wd_dtrunc], 0
    mov ax, WD_MAXKB
    call far [wd_v_resize]
    jc .no
    mov word [wd_len], 0
    mov word [wd_papn], 1           ; a fresh dictionary: entry 0 is Normal
    push es
    mov es, [wd_pseg]
    mov word [es:0], 0
    mov word [es:2], 0
    pop es
    mov word [wd_pfb], 0
    mov word [wd_pfb+2], 0
    mov byte [wd_rat], 0
    mov word [wd_rdep], 0
    mov word [wd_rskip], 0
    mov word [wd_rpin], 0           ; no \pict open, and no claim held from a
    mov word [wd_rpseg], 0          ; parse that was refused half way
    call far [wd_v_pictfree]; the OLD document's pictures go back
                                    ; HERE and not at wd_load's commit point,
                                    ; which is past the ones this parse is
                                    ; about to build (SPEC.md 86.6)
    xor si, si                      ; SI = where we are in the file
.step:
    cmp si, [wd_dfsize]
    jae .done
    push es
    mov es, [wd_stgseg]
    mov al, [es:si]
    pop es
    inc si
    cmp al, '{'
    je .open
    cmp al, '}'
    je .close
    cmp al, '\'
    je .ctrl
    cmp al, 13
    je .step
    cmp al, 10
    je .step
    cmp word [wd_rpin], 0           ; inside \pict every character is data,
    je .text                        ; and the hex pairs into bytes (86.6)
    call wd_rpbyte
    jmp .step
.text:
    cmp word [wd_rskip], 0
    jne .step
    call wd_rput
    jmp .step
.open:
    mov ax, [wd_rdep]
    cmp ax, WD_RTFDEPTH
    jae .deep
    mov bx, ax
    shl bx, 1
    mov al, [wd_rat]
    mov [bx+wd_rstk], al
    inc word [wd_rdep]
    jmp .step
.close:
    cmp word [wd_rdep], 0
    je .step
    dec word [wd_rdep]
    mov bx, [wd_rdep]
    shl bx, 1
    mov al, [bx+wd_rstk]
    mov [wd_rat], al
    mov ax, [wd_rpin]               ; a \pict ends at the depth it opened at,
    or ax, ax                       ; the same test wd_rskip makes below
    jz .nopic
    cmp [wd_rdep], ax
    ja .nopic
    call wd_rpfin
.nopic:
    mov ax, [wd_rskip]
    or ax, ax
    jz .step
    dec ax                          ; skipping stops when the group that
    cmp [wd_rdep], ax               ; started it closes
    ja .step
    mov word [wd_rskip], 0
    jmp .step
.ctrl:
    call wd_rtok                    ; consumes the control word or symbol
    jmp .step
.deep:
    mov byte [wd_dtrunc], 1         ; nested past what this reads: keep what
    jmp .done                 ; arrived and say so
.done:
    call wd_rtail                   ; the tail paragraph's format
    clc
    ret
.no:
    stc
    ret

; -----------------------------------------------------------------------------
; wd_rput - append character AL to the document, wearing [wd_rat]
; Preserves all registers. A document that reaches its ceiling stops taking
; characters and raises [wd_dtrunc].
; -----------------------------------------------------------------------------
wd_rput:
    push ax
    push bx
    push es
    cmp al, 9                       ; \tab arrives here, and a tab is one of
    je .store                       ; the three control codes this document
    cmp al, 32                      ; model holds (SPEC.md 68.3)
    jb .out
    cmp al, 126
    ja .out
.store:
    mov bx, [wd_len]
    cmp bx, [wd_cap]
    jae .full
    mov es, [wd_dseg]
    mov [es:bx], al
    mov es, [wd_cseg]
    mov al, [wd_rat]
    mov [es:bx], al
    inc word [wd_len]
    jmp short .out
.full:
    mov byte [wd_dtrunc], 1
.out:
    pop es
    pop bx
    pop ax
    ret

; wd_rputm - append a paragraph mark carrying the current PAP candidate.
; Preserves all registers.
wd_rputm:
    push ax
    push bx
    push es
    call far [wd_v_papfind]; AL = the dictionary index (CF=1 = full,
    jc .plain                       ; and Normal is the honest fallback)
    jmp short .have
.plain:
    xor al, al
.have:
    mov bx, [wd_len]
    cmp bx, [wd_cap]
    jae .full
    push ax
    mov es, [wd_dseg]
    mov byte [es:bx], 13
    pop ax
    mov es, [wd_cseg]
    mov [es:bx], al                 ; the mark's CHP byte IS the paragraph's
                                    ; dictionary index (SPEC.md 68.3)
    inc word [wd_len]
    jmp short .out
.full:
    mov byte [wd_dtrunc], 1
.out:
    pop es
    pop bx
    pop ax
    ret

; wd_rtail - the tail paragraph's format, for wd_ldpost. Preserves all.
wd_rtail:
    push ax
    call far [wd_v_papfind]
    jnc .have
    xor al, al
.have:
    mov [wd_dtail], al
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_rtok - read the control word or symbol at SI and act on it
; in:  SI = one past the backslash
; out: SI advanced past it (and past one trailing space); preserves all others
; -----------------------------------------------------------------------------
wd_rtok:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    mov es, [wd_stgseg]
    cmp si, [wd_dfsize]
    jae .out
    mov al, [es:si]
    call wd_risal
    jc .symbol
    xor di, di                      ; --- a control word --------------------
.name:
    cmp si, [wd_dfsize]
    jae .named
    mov al, [es:si]
    call wd_risal
    jc .named
    cmp di, WD_RTFCW - 1
    jae .nostore
    mov [di+wd_rcw], al
    inc di
.nostore:
    inc si
    jmp short .name
.named:
    mov byte [di+wd_rcw], 0
    xor cx, cx                      ; CX = the parameter, DX = it has one
    xor dx, dx
    mov bx, 1
    cmp si, [wd_dfsize]
    jae .noparam
    mov al, [es:si]
    cmp al, '-'
    jne .digits
    mov bx, -1
    inc si
.digits:
    cmp si, [wd_dfsize]
    jae .noparam
    mov al, [es:si]
    cmp al, '0'
    jb .noparam
    cmp al, '9'
    ja .noparam
    mov dx, 1
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, cx
    push bx
    push dx                         ; DX says the control word HAD a
    mov bx, 10                      ; parameter, and a 16-bit mul writes
    mul bx                          ; DX:AX - losing it reads \b0 as \b
    pop dx
    pop bx
    mov cx, ax
    pop ax
    add cx, ax
    inc si
    jmp short .digits
.noparam:
    or bx, bx
    jge .signed
    neg cx
.signed:
    cmp si, [wd_dfsize]             ; exactly one trailing space belongs to
    jae .act                        ; the control word
    cmp byte [es:si], ' '
    jne .act
    inc si
.act:
    call wd_rword
    jmp short .out
.symbol:
    inc si                          ; --- a control symbol ------------------
    cmp al, '*'
    je .star
    cmp al, 0x27                    ; \'hh - a hex character
    je .hex
    cmp word [wd_rskip], 0
    jne .out
    cmp al, '\'
    je .lit
    cmp al, '{'
    je .lit
    cmp al, '}'
    je .lit
    cmp al, '~'
    jne .out
    mov al, ' '
    call wd_rput
    jmp short .out
.lit:
    call wd_rput
    jmp short .out
.star:
    mov ax, [wd_rdep]               ; \* names the group a skipper
    mov [wd_rskip], ax
    jmp short .out
.hex:
    xor ax, ax
    cmp si, [wd_dfsize]
    jae .out
    mov al, [es:si]
    call wd_rhex
    jc .out
    mov ah, al
    inc si
    cmp si, [wd_dfsize]
    jae .out
    mov al, [es:si]
    call wd_rhex
    jc .out
    inc si
    push cx
    mov cl, 4
    shl ah, cl
    pop cx
    or al, ah
    cmp word [wd_rskip], 0
    jne .out
    call wd_rput
.out:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_risal - CF=0 if AL is an ASCII letter. Preserves all registers.
wd_risal:
    cmp al, 'a'
    jb .up
    cmp al, 'z'
    ja .no
    clc
    ret
.up:
    cmp al, 'A'
    jb .no
    cmp al, 'Z'
    ja .no
    clc
    ret
.no:
    stc
    ret

; wd_rhex - AL = the value of hex digit AL; CF=1 = it is not one.
wd_rhex:
    cmp al, '0'
    jb .no
    cmp al, '9'
    ja .a
    sub al, '0'
    clc
    ret
.a:
    or al, 32
    cmp al, 'a'
    jb .no
    cmp al, 'f'
    ja .no
    sub al, 'a' - 10
    clc
    ret
.no:
    stc
    ret

; -----------------------------------------------------------------------------
; wd_rword - act on the control word at [wd_rcw] with parameter CX (DX = it
;            had one)
; Preserves all registers.
;
; An unrecognised control word is IGNORED - not its group. \* is what says
; 'skip the group', and honouring that distinction is what stops an RTF file
; from arriving empty (SPEC.md 68.8).
; -----------------------------------------------------------------------------
wd_rword:
    push ax
    push bx
    push si
    push di
    mov bx, wd_r_tbl
.look:
    mov si, [cs:bx]                 ; THE TABLE AND THE NAMES IT POINTS AT are
    or si, si                       ; the module's own image, so they are read
    jz .none                        ; through CS and not DS - the package's
    mov di, wd_rcw                  ; segment no longer holds them (86.8.2)
    call wd_rstreq
    jc .next
    mov al, [cs:bx+2]               ; the action
    jmp short .do
.next:
    add bx, 3
    jmp short .look
.none:
    pop di
    pop si
    pop bx
    pop ax
    ret
.do:
    cmp al, WDR_SKIP
    jne .n1
    cmp word [wd_rskip], 0          ; a destination this reader has no use
    jne .fin                        ; for: skip to its closing brace
    mov si, [wd_rdep]
    mov [wd_rskip], si
    jmp short .fin
.n1:
    cmp word [wd_rskip], 0
    jne .fin                        ; inside a skipped group nothing acts
    cmp al, WDR_PAR
    jne .n2
    call wd_rputm
    jmp short .fin
.n2:
    cmp al, WDR_TAB
    jne .n3
    mov al, 9
    call wd_rput
    jmp short .fin
.n3:
    cmp al, WDR_PLAIN
    jne .n4
    mov byte [wd_rat], 0
    jmp short .fin
.n4:
    cmp al, WDR_PARD
    jne .n5
    mov word [wd_pfb], 0
    mov word [wd_pfb+2], 0
    jmp short .fin
.n5:
    cmp al, WDR_PICT
    jb .n6
    cmp al, WDR_PICPL
    ja .n6
    call wd_rword3                  ; the picture actions
    jmp short .fin
.n6:
    call wd_rword2                  ; the attribute, alignment and indent
                                    ; actions - split out because the block
                                    ; above ran out of short jumps
.fin:
    pop di
    pop si
    pop bx
    pop ax
    ret

; =============================================================================
; THE PICTURE READER (SPEC.md 86.6). \pict used to be a skipped destination
; and is now a collected one. The shape mirrors wd_rskip exactly: [wd_rpin]
; holds the depth the group opened at, .step routes text to the collector
; while it is set, and .close finalises when that group's brace arrives.
;
; A GROUP THIS READER CANNOT USE IS DISCARDED AT THE CLOSING BRACE, which is
; the same outcome skipping always gave. That is deliberately the only refusal
; path: deciding mid-stream that a \wmetafile is not for us would mean a
; second state to get wrong, and the bytes are bounded by the claim anyway.
; wd_rpfin validates and frees; nothing reaches the document unless every
; parameter agrees.
; =============================================================================

; wd_rword3 - the picture actions. in: AL = the action, CX = the parameter,
; DX = it had one. Preserves all registers.
wd_rword3:
    push ax
    cmp al, WDR_PICT
    jne .param
    mov ax, [wd_rdep]               ; the depth the group opened at, exactly
    mov [wd_rpin], ax               ; as WDR_SKIP records it
    mov word [wd_rpseg], 0
    mov word [wd_rpoff], 0
    mov byte [wd_rpnib], 0
    mov word [wd_rppl], 1           ; RTF's own defaults for a \pict
    mov word [wd_rpbp], 1
    mov word [wd_rpwb], 0
    mov word [wd_rpiw], 0
    mov word [wd_rpih], 0
    jmp short .out
.param:
    or dx, dx                       ; a picture parameter with no number is
    jz .out                         ; not one
    cmp al, WDR_PICWB
    jne .n1
    mov [wd_rpwb], cx
    jmp short .out
.n1:
    cmp al, WDR_PICW
    jne .n2
    mov [wd_rpiw], cx
    jmp short .out
.n2:
    cmp al, WDR_PICH
    jne .n3
    mov [wd_rpih], cx
    jmp short .out
.n3:
    cmp al, WDR_PICBP
    jne .n4
    mov [wd_rpbp], cx
    jmp short .out
.n4:
    mov [wd_rppl], cx
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_rpbyte - AL is a character inside a \pict group. Preserves all registers.
;
; Hex digits pair into bytes; everything else - the spaces and the line breaks
; the writer puts in to keep the file readable - is ignored. The claim is taken
; on the FIRST data byte and not at \pict, because its size comes from
; \wbmwidthbytes and \pich and those are control words that arrive first.
; -----------------------------------------------------------------------------
wd_rpbyte:
    push ax
    push bx
    push cx
    push dx
    push es
    call wd_rhex                    ; the READER's hex-digit decoder, which
    jc .out                         ; predates this and is exactly right
    mov ah, al
    cmp byte [wd_rpnib], 0
    jne .low
    mov [wd_rpacc], ah              ; the HIGH nibble, held for its partner
    mov byte [wd_rpnib], 1
    jmp short .out
.low:
    mov byte [wd_rpnib], 0
    mov al, [wd_rpacc]
    mov cl, 4
    shl al, cl
    or al, ah
    cmp word [wd_rpseg], 0
    jne .have
    call wd_rpclaim                 ; first byte: size it and take it
    jc .out
.have:
    mov bx, [wd_rpoff]
    cmp bx, [wd_rpcap]
    jae .out                        ; more data than the header described:
    mov es, [wd_rpseg]              ; keep the picture it described and drop
    mov [es:bx], al                 ; the rest, rather than run off the claim
    inc word [wd_rpoff]
.out:
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_rpclaim - size the picture from its header and claim it.
; out: CF=0 and [wd_rpseg]/[wd_rpcap] set; CF=1 = refused (and rpseg stays 0).
; Preserves all but the flags.
wd_rpclaim:
    push ax
    push bx
    push cx
    push dx
    cmp word [wd_rppl], 1           ; ONE plane of FOUR-bit pixels is the only
    jne .no                         ; arrangement this writes and the only one
    cmp word [wd_rpbp], 4           ; it reads: 86.5 says why
    jne .no
    mov ax, [wd_rpwb]
    or ax, ax
    jz .no
    mov cx, [wd_rpiw]
    or cx, cx
    jz .no
    cmp cx, OS88IMG_WMAX            ; the same width ceiling os88img.inc has,
    ja .no                          ; so a picture that arrives by this route
    inc cx                          ; cannot be one the decoder would refuse
    shr cx, 1
    cmp ax, cx
    jb .no                          ; a stride under (w+1)/2 cannot hold it
    mov cx, [wd_rpih]
    or cx, cx
    jz .no
    mul cx                          ; DX:AX = the whole picture
    or dx, dx
    jnz .no
    mov [wd_rpcap], ax
    add ax, 1023
    jc .no
    mov cl, 10
    shr ax, cl
    or ax, ax
    jnz .kbok
    mov ax, 1
.kbok:
    call OSAPI_MEM_CLAIM            ; out DX = the base segment
    jc .no
    mov [wd_rpseg], dx
    clc
    jmp short .out
.no:
    stc
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_rpfin - the \pict group has closed. Register it, or give it back.
; Preserves all registers.
;
; A picture whose data ran short is refused WHOLE rather than padded: half a
; picture drawn as if it were a picture is worse than the document arriving
; without it, and 47 makes refusal an ordinary path.
; -----------------------------------------------------------------------------
wd_rpfin:
    push ax
    push bx
    push cx
    push dx
    push di
    mov word [wd_rpin], 0
    mov byte [wd_rpnib], 0
    cmp word [wd_rpseg], 0          ; never claimed: nothing we could use
    je .out
    mov ax, [wd_rpoff]
    cmp ax, [wd_rpcap]
    jb .drop                        ; short of what the header promised
    mov ax, [wd_npic]
    cmp ax, WD_PICMAX               ; a document may hold WD_PICMAX (68.15);
    jae .drop                       ; the rest arrive as nothing
    mov cl, 3
    shl ax, cl                      ; * WD_PICREC
    add ax, wd_pictab
    mov di, ax
    mov ax, [wd_rpiw]
    mov [di], ax
    mov ax, [wd_rpih]
    mov [di+2], ax
    mov ax, [wd_rpwb]
    mov [di+4], ax
    mov ax, [wd_rpseg]
    mov [di+6], ax
    mov ax, [wd_npic]               ; the CHP byte IS the index (68.15), and
    inc word [wd_npic]              ; the character carries no other format.
    call wd_rputp                   ; AL is that index and wd_rputp wants it
    jmp short .out                  ; there - the character it writes is
                                    ; WD_PICCH, which is the routine's own
                                    ; business and not an argument to it
.drop:
    mov dx, [wd_rpseg]
    call OSAPI_MEM_FREE
.out:
    mov word [wd_rpseg], 0
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_rputp - put WD_PICCH in the document with AL as its CHP byte, which is
; the picture index rather than an attribute set. Preserves all registers.
wd_rputp:
    push ax
    push bx
    push es
    mov bx, [wd_len]
    cmp bx, [wd_cap]
    jae .out                        ; the same ceiling every other character
    mov ah, al                      ; meets; wd_rput's own refusal
    mov es, [wd_dseg]
    mov byte [es:bx], WD_PICCH
    mov es, [wd_cseg]
    mov [es:bx], ah
    inc word [wd_len]
.out:
    pop es
    pop bx
    pop ax
    ret

; wd_rword2 - the rest of the actions, split out because the first block
; above ran out of short jumps. in: AL = the action, CX = the parameter,
; DX = it had one, BX = the table row. Preserves all registers.
wd_rword2:
    push ax
    push bx
    push si
    cmp al, WDR_BOLD
    jb .npos
    cmp al, WDR_HID
    ja .npos
    sub al, WDR_BOLD                ; the four flag attributes, in order
    xor ah, ah
    mov si, ax
    mov ah, [cs:si+wd_r_bits]     ; CS: this table travels WITH
    or dx, dx                       ; no parameter means ON; a 0 parameter
    jz .on                          ; means OFF
    or cx, cx
    jz .off
.on:
    or [wd_rat], ah
    jmp .out
.off:
    not ah
    and [wd_rat], ah
    jmp .out
.npos:
    cmp al, WDR_UL
    jb .nul
    cmp al, WDR_ULNONE
    ja .nul
    and byte [wd_rat], ~(WDAT_UL|WDAT_WUL|WDAT_DUL) & 0xFF
    cmp al, WDR_ULNONE
    je .out
    or dx, dx
    jz .ulon
    or cx, cx
    jz .out
.ulon:
    sub al, WDR_UL
    xor ah, ah
    mov si, ax
    mov al, [cs:si+wd_r_ulbits]   ; the code into SCRIBE.OVL
    or [wd_rat], al
    jmp short .out
.nul:
    cmp al, WDR_QL
    jb .nq
    cmp al, WDR_QJ
    ja .nq
    sub al, WDR_QL
    and byte [wd_pfb], ~WDPA_ALIGN & 0xFF
    or [wd_pfb], al
    jmp short .out
.nq:
    cmp al, WDR_LI
    je .li
    cmp al, WDR_FI
    je .fi
    cmp al, WDR_RI
    je .ri
    cmp al, WDR_SL
    je .sl
    cmp al, WDR_SB
    je .sb
    jmp short .out
.li:
    call wd_rcell
    mov [wd_pfb+1], al
    jmp short .out
.fi:
    call wd_rcell
    mov [wd_pfb+2], al
    jmp short .out
.ri:
    call wd_rcell
    mov [wd_pfb+3], al
    jmp short .out
.sl:
    mov ax, cx
    or ax, ax
    jge .slp
    neg ax                          ; \sl-240 is 'exactly 240'
.slp:
    mov ah, 0
    cmp ax, 300
    jb .sl0
    mov ah, 1
    cmp ax, 420
    jb .sl0
    mov ah, 2
.sl0:
    shl ah, 1
    shl ah, 1
    and byte [wd_pfb], ~WDPA_SPACE & 0xFF
    or [wd_pfb], ah
    jmp short .out
.sb:
    or cx, cx
    jz .out
    or byte [wd_pfb], WDPA_SB
.out:
    pop si
    pop bx
    pop ax
    ret

; wd_rcell - AL = parameter CX in twips as signed cells, clamped. Preserves
; all registers but AX.
wd_rcell:
    push bx
    push cx
    push dx
    mov ax, cx
    cwd
    mov cx, WD_TWIPCELL
    idiv cx
    cmp ax, WD_INDMAX
    jle .lo
    mov ax, WD_INDMAX
.lo:
    cmp ax, -WD_INDMAX
    jge .ok
    mov ax, -WD_INDMAX
.ok:
    pop dx
    pop cx
    pop bx
    ret

; wd_rstreq - compare the NUL string at CS:SI with the one at DS:DI.
; CF=0 = equal. Preserves all registers.
wd_rstreq:
    push ax
    push si
    push di
.step:
    mov al, [cs:si]
    cmp al, [di]
    jne .no
    or al, al
    jz .yes
    inc si
    inc di
    jmp short .step
.yes:
    pop di
    pop si
    pop ax
    clc
    ret
.no:
    pop di
    pop si
    pop ax
    stc
    ret

; --- the reader's control-word table -----------------------------------------
WDR_SKIP    equ 1                   ; a destination to swallow whole
WDR_PAR     equ 2
WDR_TAB     equ 3
WDR_PLAIN   equ 4
WDR_PARD    equ 5
WDR_BOLD    equ 7                   ; the four flag attributes, in wd_r_bits
WDR_ITAL    equ 8                   ; order
WDR_SCAP    equ 9
WDR_HID     equ 10
WDR_UL      equ 11                  ; the three underlines...
WDR_ULW     equ 12
WDR_ULDB    equ 13
WDR_ULNONE  equ 14                  ; ...and the one that clears them
WDR_QL      equ 15                  ; the four alignments, in jc order
WDR_QC      equ 16
WDR_QR      equ 17
WDR_QJ      equ 18
WDR_LI      equ 19
WDR_FI      equ 20
WDR_RI      equ 21
WDR_SL      equ 22
WDR_SB      equ 23
WDR_PICT    equ 24                  ; \pict - the picture destination, which
                                    ; this reader COLLECTS instead of skipping
WDR_PICWB   equ 25                  ; \wbmwidthbytes  } the four that decide
WDR_PICW    equ 26                  ; \picw           } whether the group is
WDR_PICH    equ 27                  ; \pich           } one we can use, and
WDR_PICBP   equ 28                  ; \wbmbitspixel   } what shape it is
WDR_PICPL   equ 29                  ; \wbmplanes

wd_r_bits:   db WDAT_BOLD, WDAT_ITAL, WDAT_SCAP, WDAT_HID
wd_r_ulbits: db WDAT_UL, WDAT_WUL, WDAT_DUL

wd_r_tbl:
    dw wd_rw_par
    db WDR_PAR
    dw wd_rw_line
    db WDR_PAR
    dw wd_rw_tab
    db WDR_TAB
    dw wd_rw_plain
    db WDR_PLAIN
    dw wd_rw_pard
    db WDR_PARD
    dw wd_rw_b
    db WDR_BOLD
    dw wd_rw_i
    db WDR_ITAL
    dw wd_rw_scaps
    db WDR_SCAP
    dw wd_rw_v
    db WDR_HID
    dw wd_rw_ul
    db WDR_UL
    dw wd_rw_ulw
    db WDR_ULW
    dw wd_rw_uldb
    db WDR_ULDB
    dw wd_rw_ulnone
    db WDR_ULNONE
    dw wd_rw_ql
    db WDR_QL
    dw wd_rw_qc
    db WDR_QC
    dw wd_rw_qr
    db WDR_QR
    dw wd_rw_qj
    db WDR_QJ
    dw wd_rw_li
    db WDR_LI
    dw wd_rw_fi
    db WDR_FI
    dw wd_rw_ri
    db WDR_RI
    dw wd_rw_sl
    db WDR_SL
    dw wd_rw_sb
    db WDR_SB
    dw wd_rw_fonttbl
    db WDR_SKIP
    dw wd_rw_colortbl
    db WDR_SKIP
    dw wd_rw_stylesheet
    db WDR_SKIP
    dw wd_rw_info
    db WDR_SKIP
    dw wd_rw_pict                   ; NOT WDR_SKIP any more (SPEC.md 86.6):
    db WDR_PICT                     ; a \pict this reader understands is a
    dw wd_rw_wbmwb                  ; picture, and one it does not is
    db WDR_PICWB                    ; discarded at the closing brace, which
    dw wd_rw_picw                   ; is the same outcome skipping gave
    db WDR_PICW
    dw wd_rw_pich
    db WDR_PICH
    dw wd_rw_wbmbp
    db WDR_PICBP
    dw wd_rw_wbmpl
    db WDR_PICPL
    dw wd_rw_footnote
    db WDR_SKIP
    dw wd_rw_header
    db WDR_SKIP
    dw wd_rw_footer
    db WDR_SKIP
    dw wd_rw_xe
    db WDR_SKIP
    dw wd_rw_tc
    db WDR_SKIP
    dw 0
    db 0

wd_rw_par:        db 'par', 0
wd_rw_line:       db 'line', 0
wd_rw_tab:        db 'tab', 0
wd_rw_plain:      db 'plain', 0
wd_rw_pard:       db 'pard', 0
wd_rw_b:          db 'b', 0
wd_rw_i:          db 'i', 0
wd_rw_scaps:      db 'scaps', 0
wd_rw_v:          db 'v', 0
wd_rw_ul:         db 'ul', 0
wd_rw_ulw:        db 'ulw', 0
wd_rw_uldb:       db 'uldb', 0
wd_rw_ulnone:     db 'ulnone', 0
wd_rw_ql:         db 'ql', 0
wd_rw_qc:         db 'qc', 0
wd_rw_qr:         db 'qr', 0
wd_rw_qj:         db 'qj', 0
wd_rw_li:         db 'li', 0
wd_rw_fi:         db 'fi', 0
wd_rw_ri:         db 'ri', 0
wd_rw_sl:         db 'sl', 0
wd_rw_sb:         db 'sb', 0
wd_rw_fonttbl:    db 'fonttbl', 0
wd_rw_colortbl:   db 'colortbl', 0
wd_rw_stylesheet: db 'stylesheet', 0
wd_rw_info:       db 'info', 0
wd_rw_pict:       db 'pict', 0
wd_rw_wbmwb:      db 'wbmwidthbytes', 0
wd_rw_wbmbp:      db 'wbmbitspixel', 0
wd_rw_wbmpl:      db 'wbmplanes', 0
wd_rw_picw:       db 'picw', 0      ; \picwgoal tokenises as its OWN word -
wd_rw_pich:       db 'pich', 0      ; letters then digits - so these two do
                                    ; not have to exclude it
wd_rw_footnote:   db 'footnote', 0
wd_rw_header:     db 'header', 0
wd_rw_footer:     db 'footer', 0
wd_rw_xe:         db 'xe', 0
wd_rw_tc:         db 'tc', 0
