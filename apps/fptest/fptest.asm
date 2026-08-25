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
; the classic 0.1+0.2, and quotients that do not terminate (1/3, 2/3).
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'FPTEST', fpt_entry

FPT_W      equ 300
FPT_H      equ 440
FPT_ROWH   equ 10
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
fpt_s_hdr:  db 'os88fp.inc vs IEEE-754', 0
fpt_s_all:  db 'ALL PASS', 0
fpt_s_some: db 'FAILURES', 0

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
    call OSAPI_FONT_STR

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
    call fp_div
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
    call OSAPI_FONT_STR
    pop si
    mov cx, [fpt_ox]
    add cx, 46
    push si
    add si, 26                        ; the name pointer, last in the record
    mov si, [si]
    call OSAPI_FONT_STR
    pop si

    pop si
    add si, 28                        ; on to the next record
    inc word [fpt_i]
    jmp .case

.summary:
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
    call OSAPI_FONT_STR
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
    call OSAPI_FONT_STR
    pop si
    mov cx, [fpt_ox]
    add cx, 46
    push si
    mov si, fpt_out                   ; show what we actually produced
    call OSAPI_FONT_STR
    mov cx, [fpt_ox]                  ; ...and the raw digits + decimal
    add cx, 150                       ; exponent behind it
    mov si, fp_dig
    call OSAPI_FONT_STR
    pop si
    inc word [fpt_j]
    jmp .scase
.sdone:

    mov cx, [fpt_ox]
    add cx, 150
    mov dx, [fpt_oy]
    add dx, 2
    mov si, fpt_s_all
    cmp word [fpt_bad], 0
    je .sdraw
    mov si, fpt_s_some
.sdraw:
    call OSAPI_FONT_STR

    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

FPT_AN equ 6
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
    OS88_BSS 132
    OS88_IMAGE_END

fpt_ox      equ os88_image_end + 0
fpt_oy      equ fpt_ox + 2
fpt_i       equ fpt_oy + 2
fpt_bad     equ fpt_i + 2
fpt_got     equ fpt_bad + 2          ; 8: the packed result under test
fpt_k       equ fpt_got + 8
fpt_j       equ fpt_k + 2           ; the round-trip case index
fpt_out     equ fpt_j + 2             ; 32: the formatted text under test

fp_as       equ fpt_out + 32          ; --- os88fp.inc's scratch ---
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
fp_sgn      equ fp_nd + 2            ; word: digits in fp_dig
fpt_bss_end equ fp_sgn + 2

%define FPT_BSS_NEED (fpt_bss_end - os88_image_end)
    times (FPT_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - FPT_BSS_NEED) db 0
