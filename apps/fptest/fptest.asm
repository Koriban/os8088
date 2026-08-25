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
FPT_H      equ 330
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

%include "fpcases.inc"
%include "os88fp.inc"

; -----------------------------------------------------------------------------
; bss - including every scratch word os88fp.inc's header says the caller owes
; it. They are ordinary bss like any other; the include never touches DS.
; -----------------------------------------------------------------------------
    OS88_BSS 66
    OS88_IMAGE_END

fpt_ox      equ os88_image_end + 0
fpt_oy      equ fpt_ox + 2
fpt_i       equ fpt_oy + 2
fpt_bad     equ fpt_i + 2
fpt_got     equ fpt_bad + 2          ; 8: the packed result under test

fp_as       equ fpt_got + 8          ; --- os88fp.inc's scratch ---
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
fpt_bss_end equ fp_tmp + 2

%define FPT_BSS_NEED (fpt_bss_end - os88_image_end)
    times (FPT_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - FPT_BSS_NEED) db 0
