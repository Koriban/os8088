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
; Every expected double in apps/fptest/fpcases.inc was GENERATED ON THE HOST,
; computed in double precision and emitted as exact bytes. That is the whole
; point: the reference is not my own arithmetic restated in assembly, it is
; what a real IEEE-754 implementation produced. A case only passes if all
; EIGHT bytes match.
;
; The cases cover carrying, cancellation, mixed signs, wildly different
; exponents, the classic 0.1+0.2, quotients that do not terminate (1/3, 2/3),
; ties broken only by bits lost below the working form, the overflow clamp,
; division by zero (CF asserted too, not just the bytes), the subnormal flush,
; sqrt/trunc/floor/round, the logarithms, the trigonometry, powers, text ->
; double, and text -> double -> text.
;
; ONE RUNNER, A HANDLER PER KIND OF CASE (the first apps size pass). The
; kinds were copies of the same loop - run, pack, compare eight bytes, place
; a row, draw a verdict - and are now one walk over fpcases.inc's groups that
; calls a handler per record. Every case is checked exactly as before.
;
; THE ONE PLACE EIGHT BYTES ARE NOT DEMANDED is fpt_hmath's group, and the
; reason is arithmetic rather than convenience: a TRUNCATED SERIES is not the
; correctly-rounded double and no amount of care makes it one. Those cases
; are compared bit for bit first and, only when that fails, by DISTANCE -
; FPT_ULPS units in the last place over the whole 64 bits. Everything else
; here, fp_sqrt and fp_round included, still has to match exactly.
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'FPTEST', fpt_entry

FPT_W      equ 460               ; 460 and not 300 for a THIRD column: see
FPT_H      equ 440               ; fpcases.inc, above FPT_XN's group header
FPT_ROWH   equ 9                    ; 45 row slots have to fit the content area

; -----------------------------------------------------------------------------
; fpt_entry
; -----------------------------------------------------------------------------
fpt_entry:
    push si
    mov si, fpt_tpl
    call OSAPI_WM_CREATE
    ; OUR REGION MAY MOVE (SPEC.md 66.6.1). Here, where the window
    ; exists, and not beside any worker's declaration: a package with
    ; NO worker is the case that moves most easily, and putting it at
    ; the spawn left exactly those runs declaring nothing - measured,
    ; by the row that reads MC_RLOC back out of the kernel's own table.
    ; The relocation proc is the `ret` below: nothing here holds a segment.
    OS88_REGION_MOVABLE fpt_ret
    pop si
fpt_ret:
    ret

fpt_tpl:
    dw 40, 40, FPT_W, FPT_H
    dw fpt_title, fpt_paint, 0, 0

fpt_title:  db 'FP self-test', 0
fpt_s_pass: db 'ok  ', 0
fpt_s_fail: db 'FAIL', 0
; The header is ONE string, drawn once: 'os88fp' at +4, the verdict at +60
; and the counts at +140 are 7 and 10 cells apart in an 8-pixel font, which
; is what the spaces below are.
fpt_s_hdr:  db 'os88fp ', 0
fpt_s_all:  db 'ALL PASS', 0
fpt_s_some: db 'FAILURES', 0
fpt_s_soft: db '  soft ', 0
fpt_s_hw:   db '  8087 ', 0

; fpt_apps - append the NUL string at SI to ES:DI. The NUL is stored and DI
; left on it, so the line is terminated after every append.
fpt_apps:
    lodsb
    stosb
    or al, al
    jnz fpt_apps
    dec di
    ret

; fpt_appn - AX = a failure count, appended in decimal at ES:DI; -1 prints
; as '-', "this pass did not run". A count is at most fpcases.inc's total,
; which that file holds under 1000 - the HUNDREDS place arrived with the
; series cases (84.11), which took the total past AAM's two digits.
; BX and DX are the caller's: fpt_paint holds the 8087 pass's count in DX
; across the software pass's call to here.
fpt_appn:
    inc ax                            ; -1 -> 0
    jz .dash
    dec ax
    push bx
    push dx
    xor dx, dx
    mov bx, 100
    div bx                            ; AX = hundreds, DX = the last two
    mov bl, al
    xchg ax, dx
    aam                               ; AH = tens, AL = units
    add ax, '00'
    or bl, bl
    jz .tens
    add bl, '0'
    xchg ax, bx
    stosb                             ; the hundreds...
    xchg ax, bx
    jmp short .ten                    ; ...and then the tens, unsuppressed
.tens:
    cmp ah, '0'
    je .out
.ten:
    xchg al, ah
    stosb
    xchg al, ah
.out:
    stosb
    pop dx
    pop bx
.z:
    mov byte [di], 0
    ret
.dash:
    mov al, '-'
    stosb
    jmp short .z

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
    push es
    push ds                           ; ES = DS for the string instructions,
    pop es                            ; everywhere below (ES is ours to use)
    cld
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov bx, si
    call OSAPI_WM_CONTENT
    mov [fpt_ox], ax
    mov [fpt_oy], dx
    xchg bx, dx                       ; BX = top
    mov cx, ax
    add cx, FPT_W - 3
    lea dx, [bx + FPT_H - 16]
    call OSAPI_GFX_FILL
    mov al, CBLACK
    call OSAPI_SET_COLOR

    mov word [fp_hw], 0               ; fp_hw AND fpt_quiet, which follows it:
    call fpt_runall                   ; --- pass 1: the software path, always,
    push ax                           ; on every machine, drawing every row ---

    call OSAPI_CPU_INFO
    test ah, CPU_F_X87
    mov ax, -1                        ; -1 = "not run", which is not the same
    jz .nohw                          ; answer as 0 and must not read like it
    call fp_init                      ; --- pass 2: the SAME 88 cases against
    inc byte [fpt_quiet]              ; the SAME host-computed bytes, on the
    call fpt_runall                   ; coprocessor. Rows are not redrawn: the
.nohw:                                ; two paths agreeing is the point, so
    xchg dx, ax                       ; there is nothing new to show per case
    pop cx                            ; CX = soft failures, DX = 8087 ones

    mov si, fpt_s_all                 ; the verdict is BOTH passes: a machine
    jcxz .soft                        ; with a coprocessor has to be right
    jmp short .some                   ; twice to read ALL PASS here
.soft:
    or dx, dx
    jle .allok                        ; -1 is "not run", which is not a failure
.some:
    mov si, fpt_s_some
.allok:
    mov di, fpt_line                  ; "os88fp ALL PASS  soft 0  8087 0", or
    push si                           ; "8087 -" when there is no part in the
    mov si, fpt_s_hdr                 ; socket
    call fpt_apps
    pop si
    call fpt_apps
    mov si, fpt_s_soft
    call fpt_apps
    xchg ax, cx
    call fpt_appn
    mov si, fpt_s_hw
    call fpt_apps
    xchg ax, dx
    call fpt_appn
    mov cx, [fpt_ox]
    add cx, 4
    mov dx, [fpt_oy]
    inc dx
    inc dx
    mov si, fpt_line
    call OSAPI_FONT_STR_XPARENT

    pop es
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; fpt_row - OSAPI_FONT_STR_XPARENT, unless this pass is the silent one. Every
; per-case row goes through here; the COUNTING does not, because a pass that
; does not draw still has to fail when it is wrong.
fpt_row:
    cmp byte [fpt_quiet], 0
    jne .skip
    call OSAPI_FONT_STR_XPARENT
.skip:
    ret

; -----------------------------------------------------------------------------
; fpt_runall - the whole suite, on whichever path fp_hw currently selects.
; Out AX = the failures; BX, CX, DX, SI, DI and BP are lost.
;
; It was inline in fpt_paint until the coprocessor arrived. Running the SAME
; cases against the SAME host-computed IEEE-754 bytes on both paths is the
; acceptance test for the hardware path, and it is stronger than diffing the
; two against each other: agreeing with one another while both being wrong is
; a thing two implementations of the same algorithm can do, and agreeing with
; a real IEEE-754 implementation is not.
;
; It walks fpcases.inc's groups: a header names the count, the verdict
; column and the first row, and its handler runs one record and answers ZF=1
; for a pass and BX = a string for 40 pixels right of the verdict (0: none).
; -----------------------------------------------------------------------------
fpt_runall:
    mov byte [fpt_bad], 0
    mov si, fpt_data
.grp:
    lodsb
    mov cl, al                        ; CL = the count; a zero one ends the
    mov ch, 0                         ; walk, which is what `dw 0` reads as
    jcxz .end
    lodsb
    mov [fpt_r], al                   ; the group's first row
    lodsw
    mov [fpt_vx], ax                  ; its verdict column - a WORD, since
    lodsw                             ; FPT_XN's is at 300
    xchg bp, ax                       ; BP = its handler
.case:
    push cx
    mov al, FPT_ROWH
    mul byte [fpt_r]
    inc byte [fpt_r]
    add ax, 14
    add ax, [fpt_oy]
    xchg dx, ax                       ; DX = this row's y
    call bp                           ; ZF = pass, BX = the text beside it
    pop cx
    push cx
    push si
    mov si, fpt_s_pass
    je .verdict
    mov si, fpt_s_fail
    inc byte [fpt_bad]
.verdict:
    mov cx, [fpt_vx]
    add cx, [fpt_ox]
    call fpt_row
    mov si, bx
    or si, si
    jz .next
    add cx, 40
    call fpt_row
.next:
    pop si
    pop cx
    dec cl
    jnz .case
    jmp short .grp
.end:
    mov al, [fpt_bad]
    cbw
    ret

; fpt_ld - expand the pool index at [SI] (bit 7 is an op bit and is ignored)
; into the eight bytes at ES:DI. SI + 1, DI + 8; AX and CX are lost.
fpt_ld:
    lodsb
    push si
    and ax, 0x7F
    sub ax, FPT_NW
    jae .whole
    shl ax, 1                         ; the word class: 2 * index past fpt_pw,
    add ax, fpt_pq                    ; which is where fpt_pq is from here
    xchg si, ax
    xor ax, ax
    mov cx, 3                         ; three zero words below it
    rep stosw
    inc cx
    jmp short .copy
.whole:
    mov cl, 3
    shl ax, cl
    add ax, fpt_pq
    xchg si, ax
    mov cx, 4
.copy:
    rep movsw
    pop si
    ret

; fpt_op - bit 7 of [SI] and of [SI+1] are an operator's bits 1 and 0;
; out BX = the operator * 2, AX lost.
fpt_op:
    mov ax, [si]
    and ax, 0x8080
    rol al, 1
    rol ax, 1
    shl ax, 1
    xchg bx, ax
    ret

; fpt_hbin - [expected][a|op1][b|op0] 'name': A = a op b.
fpt_hbin:
    mov di, fpt_exp
    call fpt_ld
    call fpt_op
    call fpt_ld                       ; -> fpt_a
    call fpt_ld                       ; -> fpt_b
    push si
    mov si, fpt_b
    call fp_unpack_b
    jmp short fpt_tail

; fpt_huna - [expected|op1][a|op0][digits] 'name': A = op(a).
fpt_huna:
    call fpt_op
    add bl, fpt_uops - fpt_ops
    mov di, fpt_exp
    call fpt_ld
    call fpt_ld                       ; -> fpt_a
    lodsb
    cbw
    xchg cx, ax                       ; CX = the digit count, for ROUND
    push si
fpt_tail:
    mov si, fpt_a
    call fp_unpack_a
    call [bx + fpt_ops]
    pop si
    mov bx, si                        ; the case's name, beside the verdict
    call fpt_skip
                                      ; ...and into fpt_chk
; fpt_chk - pack A and compare all eight bytes with fpt_exp, and the CF
; verdict fpt_div left. ZF = 1 for a pass. CX, DI lost.
fpt_chk:
    mov di, fpt_got
    call fp_pack_a
    push si
    mov si, fpt_exp
    mov cx, 4
    repe cmpsw
    pop si
    jne .out
    cmp byte [fpt_cferr], 0           ; a wrong CF fails the case even when
.out:                                 ; all eight bytes match
    mov byte [fpt_cferr], 0
    ret

; fpt_div - fp_div, and CF is part of its contract: set for a zero divisor,
; clear otherwise - so it is asserted, not just the bytes.
fpt_div:
    call fp_div
    sbb al, al
    mov bx, fp_bm0
    call fp_iszero
    sbb ah, ah
    xor al, ah
    mov [fpt_cferr], al
    ret

fpt_ops:    dw fp_add, fp_sub, fp_mul, fpt_div
fpt_uops:   dw fp_sqrt, fp_trunc, fp_floor, fp_round
fpt_mops:   dw fp_ln, fp_exp, fp_sin, fp_cos, fp_tan, fp_atan, fpt_pow

; 64 ulps: a hundred times tighter than the series' own error bound and a
; hundred times looser than a demand they cannot meet. It is a bound on the
; LIBRARY, not a knob - loosening it to make a case pass is the one thing it
; must never be used for.
FPT_ULPS    equ 64

; fpt_hmath - [op][expected][a][arg lo][arg hi] 'name': A = op(a), where the
; operator is a WHOLE byte and not fpt_op's two bits - fpt_mops has seven
; entries. Every one of them is a SERIES, so the eight-byte comparison is
; followed by fpt_ulps when it fails; fpt_uops' four are exact and stay in
; fpt_huna's group, where nothing but an exact match passes.
fpt_hmath:
    lodsb
    cbw
    shl ax, 1
    xchg bx, ax                       ; BX = the operator * 2
    mov di, fpt_exp
    call fpt_ld                       ; -> fpt_exp
    call fpt_ld                       ; -> fpt_a
    lodsw
    xchg cx, ax                       ; CX = the spare argument, for O_POW
    push si
    mov si, fpt_a
    call fp_unpack_a
    call [bx + fpt_mops]
    pop si
    call fpt_chk                      ; packs A into fpt_got; ZF = bit-exact
    pushf
    mov bx, si                        ; the case's name, beside the verdict
    call fpt_skip
    popf
    jz .out                           ; bit for bit: nothing more to ask
    call fpt_ulps
.out:
    ret

; fpt_pow - fp_pow, whose SECOND operand no MATH record has a field for: the
; spare argument carries the exponent in TENTHS, which reaches 0.5, 6, -2, 10
; and 3 without widening every other record in the group by eight bytes.
; In A = the base, CX = the tenths. SI is the caller's to lose.
fpt_pow:
    mov di, fp_tv                     ; the base, parked
    call fp_pack_a
    xchg ax, cx
    call fp_i2a
    mov ax, 10
    call fp_i2b
    call fp_div                       ; A = arg / 10
    call fp_a_to_b                    ; -> B, the exponent
    mov si, fp_tv
    call fp_unpack_a                  ; A = the base again
    jmp fp_pow

; fpt_ulps - how far fpt_got is from fpt_exp in UNITS IN THE LAST PLACE over
; the whole 64 bits, with ZF = 1 for FPT_ULPS or fewer. DX is the row's y and
; survives; CX, AX and DI are lost.
;
; THE WHOLE 64 BITS, and not "the low word may differ": that was the first
; version and tan(pi/4) failed on it, where the answer is 1.0 and the
; reference 0.9999999999999999 - one ulp apart, on opposite sides of an
; exponent step, so THREE of the four words differ. Two same-signed doubles
; read as 64-bit integers are monotonic, and then a subtraction says it.
fpt_ulps:
    push si
    push di
    push bx
    mov si, fpt_exp
    mov di, fpt_got
    mov bx, fpt_ulp
    mov cx, 4
    clc                               ; `mov`, `not`, `inc` and `loop` all
.sub:                                 ; leave CF alone, which is why the
    mov ax, [si]                      ; pointers walk by `inc` twice and not
    sbb ax, [di]                      ; by `add bx, 2`
    mov [bx], ax
    inc si
    inc si
    inc di
    inc di
    inc bx
    inc bx
    loop .sub
    jnc .pos
    mov cx, 4                         ; expected < got: negate the distance
    mov bx, fpt_ulp
    stc
.neg:
    mov ax, [bx]
    not ax
    adc ax, 0
    mov [bx], ax
    inc bx
    inc bx
    loop .neg
.pos:
    mov ax, [fpt_ulp+2]               ; anything above the low word is already
    or ax, [fpt_ulp+4]                ; further than FPT_ULPS can reach
    or ax, [fpt_ulp+6]
    jnz .far
    cmp word [fpt_ulp], FPT_ULPS
    jbe .near
.far:
    mov al, 1
    jmp short .z
.near:
    xor al, al
.z:
    or al, al                         ; ZF = 1 only within the tolerance
    pop bx
    pop di
    pop si
    ret

; fpt_hatof - 'text' [expected]: text -> double.
fpt_hatof:
    push si
    call fp_atof
    pop si
    call fpt_skip
    mov di, fpt_exp
    call fpt_ld
    xor bx, bx
    jmp fpt_chk

; fpt_hstr - 'in' 'expected': text -> double -> text, at ten significant
; digits as a cell shows them. An empty expectation is the input itself. The
; raw digits and decimal exponent behind the text go at x 150.
fpt_hstr:
    push si
    call fp_atof
    pop si
    mov di, fpt_out
    mov ax, 10
    call fp_ftoa
    mov bx, si                        ; BX -> the input
    call fpt_skip                     ; SI -> the expected text
    mov di, si
    call fpt_skip                     ; SI -> the next record
    cmp byte [di], 0
    jne .cmp
    mov di, bx
.cmp:
    push si
    mov si, fpt_out
.l:
    lodsb
    scasb
    jne .e
    or al, al
    jnz .l
.e:
    pop si
    pushf
    mov cx, [fpt_ox]
    add cx, 150
    push si
    mov si, fp_dig
    call fpt_row
    pop si
    mov bx, fpt_out                   ; show what we actually produced
    popf
    ret

; fpt_hi2a - [expected][n lo][n hi] 'name': A = fp_i2a(n), all eight bytes.
fpt_hi2a:
    mov di, fpt_exp
    call fpt_ld
    lodsw
    call fp_i2a
    mov bx, si
    call fpt_skip
    jmp fpt_chk

; fpt_ha2i - [a][n lo][n hi][cf: 0 / -1] 'name': AX = fp_a2i(a), and CF.
fpt_ha2i:
    mov di, fpt_a
    call fpt_ld
    push si
    mov si, fpt_a
    call fp_unpack_a
    pop si
    call fp_a2i                       ; AX, CF
    sbb cl, cl                        ; CL = 0 / -1
    cmp ax, [si]
    jne .v
    cmp cl, [si+2]
.v:
    lea bx, [si+3]                    ; the name
    pushf                             ; ZF is the verdict; fpt_skip spends it
    mov si, bx
    call fpt_skip
    popf
    ret

; fpt_hcmp - [a][b][r] 'name': fp_cmpab's AX is r AND its flags say the same.
fpt_hcmp:
    mov di, fpt_a
    call fpt_ld                       ; -> fpt_a
    call fpt_ld                       ; -> fpt_b
    push si
    mov si, fpt_b
    call fp_unpack_b
    mov si, fpt_a
    call fp_unpack_a
    pop si
    call fp_cmpab                     ; AX = -1 / 0 / 1, flags = cmp ax, 0
    mov cl, 0                         ; what the FLAGS say, before anything
    je .fl                            ; writes them. CL and not DL: DX is the
    mov cl, -1                        ; row's y, which fpt_runall draws the
    jl .fl                            ; verdict at after this returns
    mov cl, 1
.fl:
    cmp al, cl                        ; the flags and AX agree...
    jne .v
    cmp al, [si]                      ; ...and both say what the host said
.v:
    lea bx, [si+1]
    pushf
    mov si, bx
    call fpt_skip
    popf
    ret

; fpt_skip - SI past the NUL string at SI. AL lost.
fpt_skip:
    lodsb
    or al, al
    jnz fpt_skip
    ret

%include "fpcases.inc"
%include "os88fp.inc"

; -----------------------------------------------------------------------------
; bss - including every scratch word os88fp.inc's header says the caller owes
; it. They are ordinary bss like any other; the include never touches DS.
; -----------------------------------------------------------------------------
    OS88_BSS 245
    OS88_IMAGE_END

fpt_ox      equ os88_image_end + 0
fpt_oy      equ fpt_ox + 2
fpt_bad     equ fpt_oy + 2            ; byte: this pass's failures
fpt_r       equ fpt_bad + 1           ; byte: the row being drawn
fpt_cferr   equ fpt_r + 1             ; non-zero: a div returned the wrong CF
fpt_line    equ fpt_cferr + 1         ; 32: the summary line, ON ITS OWN
fpt_out     equ fpt_line + 32         ; 34: ONE buffer, three lives - below

; FPT_OUT = 7 IS A PUBLISHED OFFSET: tests/fptest.py reads the summary line
; out of this segment at os88_image_end + 7, which is fpt_line - the five
; bytes above are all that may ever go before it. A new field goes at the
; END of this block, with fpt_vx, and not here.
;
; THE SUMMARY HAS ITS OWN BUFFER, and did not used to. It shared fpt_out,
; 32 of whose 34 bytes are the four doubles a case under test lives in, and
; that was free while a paint took half a second: the gate read the line long
; before anything wrote there again. At 126 cases a paint takes over two
; seconds - long enough for a REDRAW to arrive, and a redraw re-runs the
; cases, so the first thing it did was put a double over the line's tail
; while the gate was reading it. MEASURED, not feared: '  8087 -' came back
; as ' a\xe7R\xee!0'. 32 bytes, in an app that ships on no disk.

; fpt_out is the formatted text under test in a round trip - and, for an
; arithmetic case, which never formats anything, it is the four doubles: the
; expectation, both operands and the result.
fpt_exp     equ fpt_out               ; 8: the expected double, expanded
fpt_a       equ fpt_exp + 8           ; 8: operand a
fpt_b       equ fpt_a + 8             ; 8: operand b
fpt_got     equ fpt_b + 8             ; 8: the packed result under test

fp_as       equ fpt_out + 34          ; --- os88fp.inc's scratch ---
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
fp_nd       equ fp_d10 + 2            ; word: digits in fp_dig
fp_sgn      equ fp_nd + 2
fp_sq       equ fp_sgn + 2            ; 8: fp_sqrt's input
fp_g        equ fp_sq + 8             ; 8: its running guess
fp_tv       equ fp_g + 8              ; 8: a general packed temporary
fp_hw       equ fp_tv + 8             ; --- the coprocessor path ---
fpt_quiet   equ fp_hw + 1             ; ours: non-zero = draw no rows. It sits
                                      ; HERE so one word store clears both
fp_x1       equ fpt_quiet + 1         ; 10: A in 80-bit form
fp_x2       equ fp_x1 + 10            ; 10: B
fp_sw       equ fp_x2 + 10            ; where the status word lands
fp_e0       equ fp_sw + 2             ; --- the transcendental layer (84.10)
fp_e1       equ fp_e0 + 8             ; four packed temporaries and a
fp_e2       equ fp_e1 + 8             ; counter, which fp_ln, fp_exp and
fp_e3       equ fp_e2 + 8             ; fp_pow share
fp_ek       equ fp_e3 + 8
fpt_ulp     equ fp_ek + 2             ; 8: ours, the signed distance between
                                      ; a series answer and the reference
fpt_vx      equ fpt_ulp + 8           ; word: the group's verdict column
fpt_bss_end equ fpt_vx + 2

%define FPT_BSS_NEED (fpt_bss_end - os88_image_end)
    times (FPT_BSS_NEED - OS88_BSS_SIZE) db 0
    times (OS88_BSS_SIZE - FPT_BSS_NEED) db 0
