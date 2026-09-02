; =============================================================================
; os8088 - apps/fptest/fptest.asm
;
; The test app for apps/os88fp.inc, and the reason that file can be trusted
; before a single cell in Sheet depends on it.
;
; Floating point is the worst possible thing to debug from inside a
; spreadsheet: a wrong bit in the guard region shows up as a value that is
; merely a little off, in one cell, on some inputs. So the soft-float core is
; proven HERE first, against real IEEE-754, and only then wired into Sheet.
;
; apps/fptest/fpcases.inc is GENERATED ON THE HOST by a Python recipe that
; computes each expected result in double precision and emits the exact bytes.
; That is the whole point: the reference is not my own arithmetic restated in
; assembly, it is what a real IEEE-754 implementation produced. A case only
; passes if all EIGHT bytes match.
;
; Regenerate it with the recipe in the repository history for this file; the
; cases cover carrying, cancellation, mixed signs, wildly different exponents,
; the classic 0.1+0.2, quotients that do not terminate (1/3, 2/3), ties broken
; only by bits lost below the working form, the overflow clamp, division by
; zero (CF asserted too, not just the bytes), and the subnormal flush.
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'FPTEST', fpt_entry

FPT_W      equ 300
FPT_H      equ 440
FPT_ROWH   equ 9                    ; 45 row slots have to fit the content area
FPT_REC    equ 26                   ; 8 a + 8 b + 2 op + 8 expected... the name
                                    ; pointer makes 28; see fpt_cases' layout

; -----------------------------------------------------------------------------
; fpt_entry
; -----------------------------------------------------------------------------
fpt_entry:
    push si
    mov si, fpt_tpl
    call OSAPI_WM_CREATE
    pop si
    ret

fpt_tpl:
    dw 40, 40, FPT_W, FPT_H
    dw fpt_title, fpt_paint, 0, 0

fpt_title:  db 'FP self-test', 0
fpt_s_pass: db 'ok  ', 0
fpt_s_fail: db 'FAIL', 0
fpt_s_hdr:  db 'os88fp', 0
fpt_s_all:  db 'ALL PASS', 0
fpt_s_some: db 'FAILURES', 0
fpt_s_soft:  db 'soft ', 0
fpt_s_hw:    db '8087 ', 0

; fpt_itoa - AX signed -> the string at DI. Diagnostics only.
fpt_itoa:
    push ax
    push bx
    push cx
    push dx
    push di
    or ax, ax
    jge .pos
    mov byte [di], '-'
    inc di
    neg ax
.pos:
    xor cx, cx
    mov bx, 10
.push:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .push
.pop:
    pop ax
    add al, '0'
    mov [di], al
    inc di
    dec cx
    jnz .pop
    mov byte [di], 0
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fpt_paint - run every case and draw the result table. Running the tests in
; the paint proc is deliberate: it means a redraw re-runs them, so the answer
; on screen is never a stale one.
; -----------------------------------------------------------------------------
fpt_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    mov bx, si
    call OSAPI_WM_CONTENT
    mov [fpt_ox], ax
    mov [fpt_oy], dx

    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov ax, [fpt_ox]
    mov bx, [fpt_oy]
    mov cx, ax
    add cx, FPT_W - 3
    mov dx, bx
    add dx, FPT_H - 16
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR

    mov cx, [fpt_ox]
    add cx, 4
    mov dx, [fpt_oy]
    add dx, 2
    mov si, fpt_s_hdr
    call OSAPI_FONT_STR_XPARENT

    mov byte [fpt_draw], 1
    mov byte [fp_hw], 0               ; --- pass 1: the software path, always,
    call fpt_runall                   ; on every machine ---
    mov ax, [fpt_bad]
    mov [fpt_badsoft], ax

    mov word [fpt_badhw], -1          ; -1 = "not run", which is not the same
    call OSAPI_CPU_INFO               ; answer as 0 and must not read like it
    test ah, CPU_F_X87
    jz .nohw
    call fp_init                      ; --- pass 2: the SAME 70 cases against
    mov byte [fpt_draw], 0            ; the SAME host-computed bytes, on the
    call fpt_runall                   ; coprocessor. Rows are not redrawn: the
    mov byte [fpt_draw], 1            ; two paths agreeing is the point, so
    mov ax, [fpt_bad]                 ; there is nothing new to show per case
    mov [fpt_badhw], ax
    mov byte [fp_hw], 0
.nohw:

    mov si, fpt_s_all                 ; the verdict is BOTH passes: a machine
    cmp word [fpt_badsoft], 0         ; with a coprocessor has to be right
    jne .some                         ; twice to read ALL PASS here
    cmp word [fpt_badhw], 0
    jle .allok                        ; -1 is "not run", which is not a failure
.some:
    mov si, fpt_s_some
.allok:
    mov cx, [fpt_ox]
    add cx, 60
    mov dx, [fpt_oy]
    add dx, 2
    call OSAPI_FONT_STR_XPARENT

    mov di, fpt_line                  ; "soft 0  8087 0", or "8087 -" when
    mov ax, [fpt_badsoft]             ; there is no part in the socket
    call fpt_lbl_soft
    mov ax, [fpt_badhw]
    call fpt_lbl_hw
    mov byte [di], 0
    mov cx, [fpt_ox]
    add cx, 140
    mov dx, [fpt_oy]
    add dx, 2
    mov si, fpt_line
    call OSAPI_FONT_STR_XPARENT

    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; fpt_lbl_soft / fpt_lbl_hw - AX = a bad count, DI = where to write; append
; "soft N  " / "8087 N". A count of -1 prints as '-': the pass did not run.
fpt_lbl_soft:
    push si
    mov si, fpt_s_soft
    call fpt_apps
    call fpt_appn
    mov byte [di], ' '
    inc di
    mov byte [di], ' '
    inc di
    pop si
    ret

fpt_lbl_hw:
    push si
    mov si, fpt_s_hw
    call fpt_apps
    call fpt_appn
    pop si
    ret

fpt_apps:                             ; SI -> a NUL string, append it at DI
    push ax
.l:
    mov al, [si]
    or al, al
    jz .e
    mov [di], al
    inc di
    inc si
    jmp .l
.e:
    pop ax
    ret

fpt_appn:                             ; AX -> decimal at DI, or '-' if -1
    cmp ax, -1
    jne .num
    mov byte [di], '-'
    inc di
    ret
.num:
    push di
    mov di, fpt_num
    call fpt_itoa
    pop di
    push si
    mov si, fpt_num
    call fpt_apps
    pop si
    ret

; fpt_row - OSAPI_FONT_STR_XPARENT, unless this pass is the silent one. Every per-case
; row in fpt_runall goes through here; the COUNTING does not, because a pass
; that does not draw still has to fail when it is wrong.
fpt_row:
    cmp byte [fpt_draw], 0
    je .skip
    call OSAPI_FONT_STR_XPARENT
.skip:
    ret

; -----------------------------------------------------------------------------
; fpt_runall - the whole suite, on whichever path fp_hw currently selects.
;
; It was inline in fpt_paint until the coprocessor arrived. Running the SAME
; cases against the SAME host-computed IEEE-754 bytes on both paths is the
; acceptance test for the hardware path, and it is stronger than diffing the
; two against each other: agreeing with one another while both being wrong is
; a thing two implementations of the same algorithm can do, and agreeing with
; a real IEEE-754 implementation is not.
;
; Leaves the count in fpt_bad. Draws a row per case unless fpt_draw is zero.
; -----------------------------------------------------------------------------
fpt_runall:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    mov word [fpt_bad], 0
    mov word [fpt_i], 0
    mov si, fpt_cases
.case:
    mov ax, [fpt_i]
    cmp ax, FPT_N
    jae .summary
    push si

    ; --- run it: A = a, B = b, A op= B ---
    call fp_unpack_a                  ; si -> a
    add si, 8
    call fp_unpack_b                  ; si -> b
    add si, 8
    mov ax, [si]                      ; the operator
    add si, 2
    push si                           ; si -> the expected result
    mov byte [fpt_cferr], 0
    or ax, ax
    jnz .notadd
    call fp_add
    jmp .done
.notadd:
    cmp ax, 1
    jne .notsub
    call fp_sub
    jmp .done
.notsub:
    cmp ax, 2
    jne .notmul
    call fp_mul
    jmp .done
.notmul:
    call fp_div                       ; CF is part of div's contract: set for
    jc .refused                       ; a zero divisor, clear otherwise - so
    mov bx, fp_bm0                    ; it is asserted, not just the bytes
    call fp_iszero
    jnc .done
    jmp .badcf
.refused:
    mov bx, fp_bm0
    call fp_iszero
    jc .done
.badcf:
    mov byte [fpt_cferr], 1
.done:
    mov di, fpt_got
    call fp_pack_a
    pop si                            ; si -> expected

    ; --- compare all eight bytes ---
    mov di, fpt_got
    mov cx, 4
    mov bp, 1                         ; bp = 1 while still equal
.cmpw:
    mov ax, [si]
    cmp ax, [di]
    je .cmpnext
    xor bp, bp
.cmpnext:
    add si, 2
    add di, 2
    dec cx
    jnz .cmpw
    cmp byte [fpt_cferr], 0           ; a wrong CF fails the case even when
    je .cfok                          ; all eight bytes match
    xor bp, bp
.cfok:

    pop si                            ; si -> the start of this record again
    push si

    ; --- draw the row ---
    mov ax, [fpt_i]
    mov cx, FPT_ROWH
    mul cx
    add ax, 14
    add ax, [fpt_oy]
    mov dx, ax                        ; dx = this row's y
    mov cx, [fpt_ox]
    add cx, 6
    mov di, fpt_s_pass
    or bp, bp
    jnz .verdict
    mov di, fpt_s_fail
    inc word [fpt_bad]
.verdict:
    push si
    mov si, di
    call fpt_row
    pop si
    mov cx, [fpt_ox]
    add cx, 46
    push si
    add si, 26                        ; the name pointer, last in the record
    mov si, [si]
    call fpt_row
    pop si

    pop si
    add si, 28                        ; on to the next record
    inc word [fpt_i]
    jmp .case

.summary:
    ; --- sqrt / trunc / floor / round, against host-computed bytes ---
    mov word [fpt_m], 0
    mov si, fpt_math
.mcase:
    mov ax, [fpt_m]
    cmp ax, FPT_MN
    jae .mdone
    push si
    call fp_unpack_a
    add si, 8
    mov cx, [si+2]                    ; the digit count, for ROUND
    mov ax, [si]                      ; the operation
    mov [fpt_mop], ax                 ; ...banked, because the comparison below
    or ax, ax                         ; treats a series result differently
    jnz .mnotsqrt
    call fp_sqrt
    jmp .mgot
.mnotsqrt:
    cmp ax, 1
    jne .mnotrunc
    call fp_trunc
    jmp .mgot
.mnotrunc:
    cmp ax, 2
    jne .mnotfloor
    call fp_floor
    jmp .mgot
.mnotfloor:
    cmp ax, 4
    jne .mnotln
    call fp_ln
    jmp .mgot
.mnotln:
    cmp ax, 5
    jne .mnotexp
    call fp_exp
    jmp .mgot
.mnotexp:
    cmp ax, 6
    jne .mnotsin
    call fp_sin
    jmp .mgot
.mnotsin:
    cmp ax, 7
    jne .mnotcos
    call fp_cos
    jmp .mgot
.mnotcos:
    cmp ax, 8
    jne .mnottan
    call fp_tan
    jmp .mgot
.mnottan:
    cmp ax, 9
    jne .mnotatn
    call fp_atan
    jmp .mgot
.mnotatn:
    call fp_round
.mgot:
    mov di, fpt_got
    call fp_pack_a
    pop si
    add si, 12                        ; past the input, op and digits
    mov di, fpt_got
    mov cx, 4
    mov bp, 1
.mcmp:
    mov ax, [si]
    cmp ax, [di]
    je .mcmpn
    xor bp, bp
.mcmpn:
    add si, 2
    add di, 2
    dec cx
    jnz .mcmp
    or bp, bp
    jnz .mnear                        ; bit for bit: nothing more to ask
    cmp word [fpt_mop], 4
    jb .mnear                         ; sqrt, trunc, floor and round ARE exact
                                      ; and stay compared exactly
; --- A SERIES IS NOT BIT-EXACT, so how far apart is it? ----------------------
; The distance is measured in UNITS IN THE LAST PLACE, over the whole 64 bits,
; which is the only comparison that behaves at a boundary. The first version
; allowed the low word to differ and nothing else, and tan(pi/4) failed on it:
; the answer is 1.0 and the reference 0.9999999999999999, ONE ulp apart and on
; opposite sides of an exponent step, so three of the four words differ.
; Treating two same-signed doubles as 64-bit integers makes them monotonic,
; and then a subtraction says it.
    push si                           ; PUSH/POP and not sub/add: the exact
    push di                           ; path below jumps straight to .mnear
    sub si, 8                         ; without having subtracted, and an
    sub di, 8                         ; unbalanced `add` there walked every
    mov bp, 1                         ; record pointer off the end of the
                                      ; table - 44 failures and garbled names
    mov ax, [si]                      ; want - got, 64 bits
    sub ax, [di]
    mov [fpt_ulp], ax
    mov ax, [si+2]
    sbb ax, [di+2]
    mov [fpt_ulp+2], ax
    mov ax, [si+4]
    sbb ax, [di+4]
    mov [fpt_ulp+4], ax
    mov ax, [si+6]
    sbb ax, [di+6]
    mov [fpt_ulp+6], ax
    jnc .mpos
    mov cx, 4                         ; negative: negate it, word by word
    mov bx, fpt_ulp
    stc
.mneg:
    mov ax, [bx]
    not ax
    adc ax, 0
    mov [bx], ax
    add bx, 2
    dec cx
    jnz .mneg
.mpos:
    cmp word [fpt_ulp+6], 0
    jne .mfar
    cmp word [fpt_ulp+4], 0
    jne .mfar
    cmp word [fpt_ulp+2], 0
    jne .mfar
    cmp word [fpt_ulp], 64            ; 64 ulps: a hundred times tighter than
    jbe .mulpout                      ; the series' own error bound and a
.mfar:                                ; hundred times looser than a demand it
    xor bp, bp                        ; cannot meet
.mulpout:
    pop di
    pop si
.mnear:
    mov ax, [fpt_m]
    mov cx, FPT_ROWH
    mul cx
    add ax, 14
    add ax, [fpt_oy]
    mov dx, ax
    mov cx, [fpt_ox]
    add cx, 150
    push si
    mov si, fpt_s_pass
    or bp, bp
    jnz .mverd
    mov si, fpt_s_fail
    inc word [fpt_bad]
.mverd:
    call fpt_row
    pop si
    mov cx, [fpt_ox]
    add cx, 190
    push si
    mov si, [si]                      ; the case's name
    call fpt_row
    pop si
    add si, 2
    inc word [fpt_m]
    jmp .mcase
.mdone:

    ; --- atof-only cases: text -> double, against host-computed bytes. This
    ; exists to SPLIT a round-trip failure: if these pass, the parser is right
    ; and the formatter is the one that is wrong.
    mov word [fpt_k], 0
    mov si, fpt_atof
.acase:
    mov ax, [fpt_k]
    cmp ax, FPT_AN
    jae .adone
    push si
    call fp_atof
    mov di, fpt_got
    call fp_pack_a
    pop si
    add si, 10                        ; past the padded text
    mov di, fpt_got
    mov cx, 4
    mov bp, 1
.acmp:
    mov ax, [si]
    cmp ax, [di]
    je .acmpn
    xor bp, bp
.acmpn:
    add si, 2
    add di, 2
    dec cx
    jnz .acmp
    mov ax, [fpt_i]
    add ax, [fpt_k]
    mov cx, FPT_ROWH
    mul cx
    add ax, 14
    add ax, [fpt_oy]
    mov dx, ax
    mov cx, [fpt_ox]
    add cx, 200
    push si
    mov si, fpt_s_pass
    or bp, bp
    jnz .averd
    mov si, fpt_s_fail
    inc word [fpt_bad]
.averd:
    call fpt_row
    pop si
    inc word [fpt_k]
    jmp .acase
.adone:

    ; --- round-trip cases: text -> double -> text ---
    mov word [fpt_j], 0
    mov si, fpt_str
.scase:
    mov ax, [fpt_j]
    cmp ax, FPT_SN
    jae .sdone
    push si
    call fp_atof                      ; si -> the input text
    pop si
    push si
    mov di, fpt_out
    mov ax, 10                        ; ten significant digits, as a cell shows
    call fp_ftoa
    pop si
.snext:
    mov al, [si]                      ; step past the input string
    inc si
    or al, al
    jnz .snext
    mov di, fpt_out                   ; compare against the expected text
    mov bp, 1
.scmp:
    mov al, [si]
    mov ah, [di]
    cmp al, ah
    je .scmpok
    xor bp, bp
    jmp .scmpend
.scmpok:
    or al, al
    jz .scmpend
    inc si
    inc di
    jmp .scmp
.scmpend:
    mov al, [si]                      ; step past the expected string
    inc si
    or al, al
    jnz .scmpend
    mov ax, [fpt_i]
    add ax, [fpt_j]
    mov cx, FPT_ROWH
    mul cx
    add ax, 14
    add ax, [fpt_oy]
    mov dx, ax
    mov cx, [fpt_ox]
    add cx, 6
    push si
    mov si, fpt_s_pass
    or bp, bp
    jnz .sverdict
    mov si, fpt_s_fail
    inc word [fpt_bad]
.sverdict:
    call fpt_row
    pop si
    mov cx, [fpt_ox]
    add cx, 46
    push si
    mov si, fpt_out                   ; show what we actually produced
    call fpt_row
    mov cx, [fpt_ox]                  ; ...and the raw digits + decimal
    add cx, 150                       ; exponent behind it
    mov si, fp_dig
    call fpt_row
    pop si
    inc word [fpt_j]
    jmp .scase
.sdone:

    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

FPT_AN equ 10
fpt_atof:
    db '1', 0
    times (10 - 2) db 0
    dw 0x0000, 0x0000, 0x0000, 0x3FF0
    db '2.5', 0
    times (10 - 4) db 0
    dw 0x0000, 0x0000, 0x0000, 0x4004
    db '100', 0
    times (10 - 4) db 0
    dw 0x0000, 0x0000, 0x0000, 0x4059
    db '0.1', 0
    times (10 - 4) db 0
    dw 0x999A, 0x9999, 0x9999, 0x3FB9
    db '1e3', 0
    times (10 - 4) db 0
    dw 0x0000, 0x0000, 0x4000, 0x408F
    db '0.001', 0
    times (10 - 6) db 0
    dw 0xA9FC, 0xD2F1, 0x624D, 0x3F50
    db '1e-3', 0                           ; a NEGATIVE text exponent
    times (10 - 5) db 0
    dw 0xA9FC, 0xD2F1, 0x624D, 0x3F50
    db '-2.5e-2', 0                        ; sign AND exponent together
    times (10 - 8) db 0
    dw 0x999A, 0x9999, 0x9999, 0xBF99
    db '1e600', 0                          ; past any double: the CLAMP,
    times (10 - 6) db 0                    ; never a folded 1e88
    dw 0xFFFF, 0xFFFF, 0xFFFF, 0x7FEF
    db '1e-600', 0                         ; ...and the FLUSH the other way
    times (10 - 7) db 0
    dw 0x0000, 0x0000, 0x0000, 0x0000

FPT_MN equ 46
fpt_math:
    dw 0x0000, 0x0000, 0x0000, 0x4000
    dw 0, 0
    dw 0x3BCD, 0x667F, 0xA09E, 0x3FF6      ; sqrt2 -> 1.4142135623730951
    dw fpt_m0
    dw 0x0000, 0x0000, 0x0000, 0x4062
    dw 0, 0
    dw 0x0000, 0x0000, 0x0000, 0x4028      ; sqrt144 -> 12.0
    dw fpt_m1
    dw 0x0000, 0x0000, 0x0000, 0x3FD0
    dw 0, 0
    dw 0x0000, 0x0000, 0x0000, 0x3FE0      ; sqrt.25 -> 0.5
    dw fpt_m2
    dw 0x0000, 0x0000, 0x8480, 0x412E
    dw 0, 0
    dw 0x0000, 0x0000, 0x4000, 0x408F      ; sqrt1e6 -> 1000.0
    dw fpt_m3
    dw 0x0000, 0x0000, 0x0000, 0x4002
    dw 0, 0
    dw 0x0000, 0x0000, 0x0000, 0x3FF8      ; sqrt2.25 -> 1.5
    dw fpt_m4
    dw 0x999A, 0x9999, 0x9999, 0x400D
    dw 1, 0
    dw 0x0000, 0x0000, 0x0000, 0x4008      ; trunc3.7 -> 3.0
    dw fpt_m5
    dw 0x999A, 0x9999, 0x9999, 0xC00D
    dw 1, 0
    dw 0x0000, 0x0000, 0x0000, 0xC008      ; trunc-3.7 -> -3.0
    dw fpt_m6
    dw 0xCCCD, 0xCCCC, 0xCCCC, 0x3FEC
    dw 1, 0
    dw 0x0000, 0x0000, 0x0000, 0x0000      ; trunc.9 -> 0.0
    dw fpt_m7
    dw 0x999A, 0x9999, 0x9999, 0x400D
    dw 2, 0
    dw 0x0000, 0x0000, 0x0000, 0x4008      ; floor3.7 -> 3.0
    dw fpt_m8
    dw 0x999A, 0x9999, 0x9999, 0xC00D
    dw 2, 0
    dw 0x0000, 0x0000, 0x0000, 0xC010      ; floor-3.7 -> -4.0
    dw fpt_m9
    dw 0x866E, 0xF01B, 0x21F9, 0x4009
    dw 3, 2
    dw 0x851F, 0x51EB, 0x1EB8, 0x4009      ; rnd pi,2 -> 3.14
    dw fpt_m10
    dw 0x0000, 0x0000, 0x0000, 0x4004
    dw 3, 0
    dw 0x0000, 0x0000, 0x0000, 0x4008      ; rnd 2.5 -> 3.0
    dw fpt_m11
    dw 0x0000, 0x0000, 0x0000, 0xC004
    dw 3, 0
    dw 0x0000, 0x0000, 0x0000, 0xC008      ; rnd -2.5 -> -3.0
    dw fpt_m12
    dw 0x0000, 0x0000, 0x4800, 0x4093
    dw 3, -2
    dw 0x0000, 0x0000, 0xC000, 0x4092      ; rnd1234,-2 -> 1200.0
    dw fpt_m13
    dw 0x0000, 0x0000, 0x0000, 0x3FC0
    dw 3, 2
    dw 0x70A4, 0x0A3D, 0xA3D7, 0x3FC0      ; rnd.125,2 -> 0.13
    dw fpt_m14
    dw 0x0000, 0x0000, 0x0000, 0x3FF0
    dw 4, 0
    dw 0x0000, 0x0000, 0x0000, 0x0000      ; ln(1) = 0
    dw fpt_t0
    dw 0x0000, 0x0000, 0x0000, 0x4000
    dw 4, 0
    dw 0x39EF, 0xFEFA, 0x2E42, 0x3FE6      ; ln(2) = 0.69314718055994529
    dw fpt_t1
    dw 0x0000, 0x0000, 0x0000, 0x4024
    dw 4, 0
    dw 0x5516, 0xBBB5, 0x6BB1, 0x4002      ; ln(10) = 2.3025850929940459
    dw fpt_t2
    dw 0x0000, 0x0000, 0x0000, 0x3FE0
    dw 4, 0
    dw 0x39EF, 0xFEFA, 0x2E42, 0xBFE6      ; ln(0.5) = -0.69314718055994529
    dw fpt_t3
    dw 0x0000, 0x2000, 0xA05F, 0x4202
    dw 4, 0
    dw 0xAA5B, 0x2AA2, 0x069E, 0x4037      ; ln(1e+10) = 23.025850929940457
    dw fpt_t4
    dw 0xA9FC, 0xD2F1, 0x624D, 0x3F50
    dw 4, 0
    dw 0xFFA0, 0x998F, 0xA18A, 0xC01B      ; ln(0.001) = -6.9077552789821368
    dw fpt_t5
    dw 0x0000, 0x0000, 0x0000, 0x0000
    dw 5, 0
    dw 0x0000, 0x0000, 0x0000, 0x3FF0      ; exp(0) = 1
    dw fpt_t6
    dw 0x0000, 0x0000, 0x0000, 0x3FF0
    dw 5, 0
    dw 0x5769, 0x8B14, 0xBF0A, 0x4005      ; exp(1) = 2.7182818284590451
    dw fpt_t7
    dw 0x0000, 0x0000, 0x0000, 0xBFF0
    dw 5, 0
    dw 0xEF38, 0x362C, 0x8B56, 0x3FD7      ; exp(-1) = 0.36787944117144233
    dw fpt_t8
    dw 0x0000, 0x0000, 0x0000, 0x4024
    dw 5, 0
    dw 0x0560, 0xCF95, 0x829D, 0x40D5      ; exp(10) = 22026.465794806718
    dw fpt_t9
    dw 0x0000, 0x0000, 0x0000, 0x3FE0
    dw 5, 0
    dw 0x069C, 0x8E1E, 0x6129, 0x3FFA      ; exp(0.5) = 1.6487212707001282
    dw fpt_t10
    dw 0x0000, 0x0000, 0x0000, 0xC014
    dw 5, 0
    dw 0x5376, 0xE00D, 0x993F, 0x3F7B      ; exp(-5) = 0.006737946999085467
    dw fpt_t11
    dw 0x0000, 0x0000, 0x0000, 0x0000
    dw 6, 0
    dw 0x0000, 0x0000, 0x0000, 0x0000      ; SIN(0) = 0
    dw fpt_g0
    dw 0x7365, 0x382D, 0xC152, 0x3FE0
    dw 6, 0
    dw 0xFFFF, 0xFFFF, 0xFFFF, 0x3FDF      ; SIN(0.523599) = 0.49999999999999994
    dw fpt_g1
    dw 0x2D18, 0x5444, 0x21FB, 0x3FF9
    dw 6, 0
    dw 0x0000, 0x0000, 0x0000, 0x3FF0      ; SIN(1.5708) = 1
    dw fpt_g2
    dw 0x0000, 0x0000, 0x0000, 0x3FF0
    dw 6, 0
    dw 0x0CEE, 0x8F09, 0xED54, 0x3FEA      ; SIN(1) = 0.8414709848078965
    dw fpt_g3
    dw 0x0000, 0x0000, 0x0000, 0xBFF0
    dw 6, 0
    dw 0x0CEE, 0x8F09, 0xED54, 0xBFEA      ; SIN(-1) = -0.8414709848078965
    dw fpt_g4
    dw 0x0000, 0x0000, 0x0000, 0x4008
    dw 6, 0
    dw 0xD55B, 0x6DB6, 0x1038, 0x3FC2      ; SIN(3) = 0.14112000805986721
    dw fpt_g5
    dw 0x0000, 0x0000, 0x0000, 0x0000
    dw 7, 0
    dw 0x0000, 0x0000, 0x0000, 0x3FF0      ; COS(0) = 1
    dw fpt_g6
    dw 0x7365, 0x382D, 0xC152, 0x3FF0
    dw 7, 0
    dw 0x0001, 0x0000, 0x0000, 0x3FE0      ; COS(1.0472) = 0.50000000000000011
    dw fpt_g7
    dw 0x0000, 0x0000, 0x0000, 0x3FF0
    dw 7, 0
    dw 0x068C, 0x0FB5, 0x4A28, 0x3FE1      ; COS(1) = 0.54030230586813977
    dw fpt_g8
    dw 0x2D18, 0x5444, 0x21FB, 0x4009
    dw 7, 0
    dw 0x0000, 0x0000, 0x0000, 0xBFF0      ; COS(3.14159) = -1
    dw fpt_g9
    dw 0x0000, 0x0000, 0x0000, 0x0000
    dw 8, 0
    dw 0x0000, 0x0000, 0x0000, 0x0000      ; TAN(0) = 0
    dw fpt_g10
    dw 0x2D18, 0x5444, 0x21FB, 0x3FE9
    dw 8, 0
    dw 0xFFFF, 0xFFFF, 0xFFFF, 0x3FEF      ; TAN(0.785398) = 0.99999999999999989
    dw fpt_g11
    dw 0x0000, 0x0000, 0x0000, 0x3FF0
    dw 8, 0
    dw 0xE3A6, 0x5CBE, 0xEB24, 0x3FF8      ; TAN(1) = 1.5574077246549023
    dw fpt_g12
    dw 0x0000, 0x0000, 0x0000, 0x0000
    dw 9, 0
    dw 0x0000, 0x0000, 0x0000, 0x0000      ; ATN(0) = 0
    dw fpt_g13
    dw 0x0000, 0x0000, 0x0000, 0x3FF0
    dw 9, 0
    dw 0x2D18, 0x5444, 0x21FB, 0x3FE9      ; ATN(1) = 0.78539816339744828
    dw fpt_g14
    dw 0x0000, 0x0000, 0x0000, 0xBFF0
    dw 9, 0
    dw 0x2D18, 0x5444, 0x21FB, 0xBFE9      ; ATN(-1) = -0.78539816339744828
    dw fpt_g15
    dw 0x0000, 0x0000, 0x0000, 0x3FE0
    dw 9, 0
    dw 0xBB4F, 0x0561, 0xAC67, 0x3FDD      ; ATN(0.5) = 0.46364760900080609
    dw fpt_g16
    dw 0x0000, 0x0000, 0x0000, 0x4024
    dw 9, 0
    dw 0x0054, 0x2C16, 0x89BD, 0x3FF7      ; ATN(10) = 1.4711276743037347
    dw fpt_g17
    dw 0x0000, 0x0000, 0x4000, 0x408F
    dw 9, 0
    dw 0x58BD, 0xC0E6, 0x1DE2, 0x3FF9      ; ATN(1000) = 1.5697963271282298
    dw fpt_g18
fpt_g0: db 'SIN0', 0
fpt_g1: db 'SIN0.5236', 0
fpt_g2: db 'SIN1.571', 0
fpt_g3: db 'SIN1', 0
fpt_g4: db 'SIN-1', 0
fpt_g5: db 'SIN3', 0
fpt_g6: db 'COS0', 0
fpt_g7: db 'COS1.047', 0
fpt_g8: db 'COS1', 0
fpt_g9: db 'COS3.142', 0
fpt_g10: db 'TAN0', 0
fpt_g11: db 'TAN0.7854', 0
fpt_g12: db 'TAN1', 0
fpt_g13: db 'ATN0', 0
fpt_g14: db 'ATN1', 0
fpt_g15: db 'ATN-1', 0
fpt_g16: db 'ATN0.5', 0
fpt_g17: db 'ATN10', 0
fpt_g18: db 'ATN1000', 0

fpt_t0: db 'LN1', 0
fpt_t1: db 'LN2', 0
fpt_t2: db 'LN10', 0
fpt_t3: db 'LN0.5', 0
fpt_t4: db 'LN1e+10', 0
fpt_t5: db 'LN0.001', 0
fpt_t6: db 'EXP0', 0
fpt_t7: db 'EXP1', 0
fpt_t8: db 'EXP-1', 0
fpt_t9: db 'EXP10', 0
fpt_t10: db 'EXP0.5', 0
fpt_t11: db 'EXP-5', 0

fpt_m0: db 'sqrt2', 0
fpt_m1: db 'sqrt144', 0
fpt_m2: db 'sqrt.25', 0
fpt_m3: db 'sqrt1e6', 0
fpt_m4: db 'sqrt2.25', 0
fpt_m5: db 'trunc3.7', 0
fpt_m6: db 'trunc-3.7', 0
fpt_m7: db 'trunc.9', 0
fpt_m8: db 'floor3.7', 0
fpt_m9: db 'floor-3.7', 0
fpt_m10: db 'rnd pi,2', 0
fpt_m11: db 'rnd 2.5', 0
fpt_m12: db 'rnd -2.5', 0
fpt_m13: db 'rnd1234,-2', 0
fpt_m14: db 'rnd.125,2', 0

; Round-trip cases: each is an input string then the expected output string,
; both NUL-terminated. Ten significant digits, which is what a spreadsheet
; cell shows. These are what prove the two conversions agree with each other
; AND with the arithmetic between them.
FPT_SN equ 12
fpt_str:
    db '1', 0,            '1', 0
    db '2.5', 0,          '2.5', 0
    db '-3.75', 0,        '-3.75', 0
    db '0.1', 0,          '0.1', 0
    db '100', 0,          '100', 0
    db '0.001', 0,        '0.001', 0
    db '123.456', 0,      '123.456', 0
    db '1e3', 0,          '1000', 0
    db '-0.5', 0,         '-0.5', 0
    db '1000000', 0,      '1000000', 0
    db '0', 0,            '0', 0
    db '3.14159', 0,      '3.14159', 0

%include "fpcases.inc"
%include "os88fp.inc"

; -----------------------------------------------------------------------------
; bss - including every scratch word os88fp.inc's header says the caller owes
; it. They are ordinary bss like any other; the include never touches DS.
; -----------------------------------------------------------------------------
    OS88_BSS 263
    OS88_IMAGE_END

fpt_ox      equ os88_image_end + 0
fpt_oy      equ fpt_ox + 2
fpt_i       equ fpt_oy + 2
fpt_bad     equ fpt_i + 2
fpt_got     equ fpt_bad + 2          ; 8: the packed result under test
fpt_m       equ fpt_got + 8
fpt_k       equ fpt_m + 2
fpt_j       equ fpt_k + 2           ; the round-trip case index
fpt_out     equ fpt_j + 2             ; 32: the formatted text under test

fpt_draw    equ fpt_out + 32          ; non-zero: draw a row per case
fpt_badsoft equ fpt_draw + 1          ; each pass's verdict, kept apart so the
fpt_badhw   equ fpt_badsoft + 2       ; summary can name which path failed
fpt_line    equ fpt_badhw + 2         ; 24: the summary being built
fpt_num     equ fpt_line + 24         ; 8: one number on its way into it
fpt_cferr   equ fpt_num + 8           ; non-zero: a div returned the wrong CF

fp_as       equ fpt_cferr + 1         ; --- os88fp.inc's scratch ---
fp_bs       equ fp_as + 1
fp_ae       equ fp_bs + 1
fp_be       equ fp_ae + 2
fp_am0      equ fp_be + 2
fp_am1      equ fp_am0 + 2
fp_am2      equ fp_am1 + 2
fp_am3      equ fp_am2 + 2
fp_bm0      equ fp_am3 + 2
fp_bm1      equ fp_bm0 + 2
fp_bm2      equ fp_bm1 + 2
fp_bm3      equ fp_bm2 + 2
fp_t0       equ fp_bm3 + 2
fp_t1       equ fp_t0 + 2
fp_t2       equ fp_t1 + 2
fp_t3       equ fp_t2 + 2
fp_p0       equ fp_t3 + 2            ; 8 words: the 128-bit product
fp_sticky   equ fp_p0 + 16
fp_tmp      equ fp_sticky + 2
fp_dig      equ fp_tmp + 2            ; 24: the digit string fp_ftoa builds
fp_d10      equ fp_dig + 24           ; word: the decimal exponent
fp_nd       equ fp_d10 + 2
fp_sgn      equ fp_nd + 2
fp_sq       equ fp_sgn + 2            ; 8: fp_sqrt's input
fp_g        equ fp_sq + 8             ; 8: its running guess
fp_tv       equ fp_g + 8              ; 8: a general packed temporary            ; word: digits in fp_dig
fp_hw       equ fp_tv + 8             ; --- the coprocessor path ---
fp_x1       equ fp_hw + 1             ; 10: A in 80-bit form
fp_x2       equ fp_x1 + 10            ; 10: B
fp_sw       equ fp_x2 + 10            ; where the status word lands
fp_e0       equ fp_sw + 2             ; --- the transcendental layer (84.8)
fp_e1       equ fp_e0 + 8             ; four packed temporaries and a
fp_e2       equ fp_e1 + 8             ; counter, which fp_ln, fp_exp and
fp_e3       equ fp_e2 + 8             ; fp_pow share
fp_ek       equ fp_e3 + 8
fpt_mop     equ fp_ek + 2             ; the math op, for the comparison
fpt_ulp     equ fpt_mop + 2           ; 8: the signed distance between
                                      ; the answer and the reference
fpt_bss_end equ fpt_ulp + 8

%define FPT_BSS_NEED (fpt_bss_end - os88_image_end)
    times (FPT_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - FPT_BSS_NEED) db 0
