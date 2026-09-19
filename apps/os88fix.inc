; =============================================================================
; os8088 - apps/os88fix.inc
;
; FIXED-POINT DECIMAL ARITHMETIC, two places, for apps/plan/plan.asm (81.75).
;
; A signed 32-bit count of HUNDREDTHS. 1.00 is 100, -0.25 is -25, and the
; range is +/-21,474,836.47 - which is the whole of what a budget needs and
; rather more than a 128KB machine can hold cells for.
;
; WHY THIS EXISTS, and it is not that doubles are wrong. apps/os88fp.inc is a
; correct software IEEE-754 double and SHEET keeps it. PLAN has to fit a
; 53,760-byte arena (SPEC.md 24.5.2, 11.102) and the double costs it twice:
; ~2,800 bytes of code, and FOUR BYTES IN EVERY CELL RECORD - which is the
; expensive half, because the cell record times the cells claim is how many
; cells the sheet can hold at all. 20 bytes a cell becomes 16, so the same
; kilobyte holds 64 cells instead of 51.
;
; AND FOR MONEY IT IS THE BETTER REPRESENTATION, not a concession. 0.1 is not
; a double; a column of doubles summing to 1234.56 may print 1234.5599999999.
; Two decimal places of pennies add and subtract EXACTLY, which is what a
; budget is made of.
;
; WHAT IT COSTS, stated rather than buried:
;   - three decimal places do not exist. 1/3 is 0.33, and 0.33*3 is 0.99
;   - a multiply or a divide ROUNDS half away from zero at the second place,
;     so a chain of them drifts by a penny at a time where a double would not
;   - SQRT is exact to the penny and no further; its argument is capped at
;     429,496.72, where the intermediate would leave 32 bits
;   - there is no exponent, so no 1e300 and no gradual underflow
;
; THE ENTRY POINTS MIRROR os88fp.inc's, name for name with fx_ for fp_, and
; the register contracts are identical - A and B accumulators in the caller's
; bss, everything preserved but the documented outputs. That is deliberate:
; plan.asm was sheet.asm, and a contract-compatible library made the switch a
; rename rather than a rewrite of nine hundred call sites.
;
; --- WHAT THE CALLER MUST DECLARE, named exactly this ------------------------
;   fx_a     4    accumulator A
;   fx_b     4    accumulator B
;   fx_q     8    the 64-bit intermediate every multiply and divide runs in
;   fx_m0    2    \
;   fx_m1    2     | the multiplier's own operand copies - it cannot keep them
;   fx_n0    2     | in registers, there are not enough
;   fx_n1    2    /
;   fx_sgn   1    the sign a magnitude operation owes back
;   fx_dig   16   fx_ftoa's digit string
;   fx_tmp   4    general scratch
; =============================================================================

FX_SCALE     equ 100                 ; hundredths, and the ONE place this
                                     ; number is written down
FX_PLACES    equ 2

; -----------------------------------------------------------------------------
; fx_init - os88fp.inc's had a coprocessor to look for. This has nothing to
; decide and exists so that a caller's start-up needs no %ifdef.
; -----------------------------------------------------------------------------
fx_init:
    ret

; -----------------------------------------------------------------------------
; fx_azero - A = 0. fx_bzero - B = 0. Every register preserved.
; -----------------------------------------------------------------------------
fx_azero:
    mov word [fx_a], 0
    mov word [fx_a+2], 0
    ret

fx_bzero:
    mov word [fx_b], 0
    mov word [fx_b+2], 0
    ret

; -----------------------------------------------------------------------------
; fx_iszero - BX points at a 4-byte value; CF=1 when it is zero.
; Preserves every register. (os88fp's took the same argument for the same
; reason: the caller may be asking about A, B or a stored cell.)
; -----------------------------------------------------------------------------
fx_iszero:
    cmp word [bx], 0
    jne .no
    cmp word [bx+2], 0
    jne .no
    stc
    ret
.no:
    clc
    ret

; -----------------------------------------------------------------------------
; fx_a_to_b / fx_b_to_a - move one accumulator to the other. All preserved.
; -----------------------------------------------------------------------------
fx_a_to_b:
    push ax
    mov ax, [fx_a]
    mov [fx_b], ax
    mov ax, [fx_a+2]
    mov [fx_b+2], ax
    pop ax
    ret

fx_b_to_a:
    push ax
    mov ax, [fx_b]
    mov [fx_a], ax
    mov ax, [fx_b+2]
    mov [fx_a+2], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_pack_a - A -> the 4 bytes at DS:DI. DI preserved.
; fx_unpack_a / fx_unpack_b - the 4 bytes at DS:SI -> A / B. SI preserved.
;
; There is no packing to do - the stored form IS the working form - so these
; are moves. They keep os88fp.inc's names because every call site in plan.asm
; already says them, and because a stored value and a working value being the
; same thing is exactly what a caller should not have to know.
; -----------------------------------------------------------------------------
fx_pack_a:
    push ax
    mov ax, [fx_a]
    mov [di], ax
    mov ax, [fx_a+2]
    mov [di+2], ax
    pop ax
    ret

fx_unpack_a:
    push ax
    mov ax, [si]
    mov [fx_a], ax
    mov ax, [si+2]
    mov [fx_a+2], ax
    pop ax
    ret

fx_unpack_b:
    push ax
    mov ax, [si]
    mov [fx_b], ax
    mov ax, [si+2]
    mov [fx_b+2], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_neg - A = -A. Every register preserved.
; -----------------------------------------------------------------------------
fx_neg:
    push ax
    push dx
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    not ax
    not dx
    add ax, 1
    adc dx, 0
    mov [fx_a], ax
    mov [fx_a+2], dx
    pop dx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_add - A = A + B.  fx_sub - A = A - B.
;
; EXACT, and that is the whole argument for this file: two counts of
; hundredths add with one ADD and one ADC. No alignment, no rounding, no
; sticky bit. Overflow wraps, as plain 8086 arithmetic does, which is the
; same bargain sheet.asm's own header struck for its 16-bit stage.
; -----------------------------------------------------------------------------
fx_add:
    push ax
    push dx
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    add ax, [fx_b]
    adc dx, [fx_b+2]
    mov [fx_a], ax
    mov [fx_a+2], dx
    pop dx
    pop ax
    ret

fx_sub:
    push ax
    push dx
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    sub ax, [fx_b]
    sbb dx, [fx_b+2]
    mov [fx_a], ax
    mov [fx_a+2], dx
    pop dx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_cmpab - compare A against B.
; out: AX = -1 (A < B), 0 (equal) or 1 (A > B), and the flags set from it, so
; a caller may use either. Both accumulators preserved.
; -----------------------------------------------------------------------------
fx_cmpab:
    push dx
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    sub ax, [fx_b]
    sbb dx, [fx_b+2]
    jl .less                           ; SIGNED: the high word carries the sign
    jg .more
    or ax, ax                          ; high words equal - the low word is
    jnz .more                          ; UNSIGNED, and a difference that is
    xor ax, ax                         ; not zero can only mean A > B, because
    pop dx                             ; the signed compare above said the
    or ax, ax                          ; tops match
    ret
.less:
    mov ax, -1
    pop dx
    or ax, ax
    ret
.more:
    mov ax, 1
    pop dx
    or ax, ax
    ret

; =============================================================================
; THE 64-BIT INTERMEDIATE. A multiply of two hundredth-counts overflows 32
; bits long before either operand does - 21M * 21M is 4.6e14 - so both the
; multiply and the divide run in 64 and come back down. fx_q is that 64 bits,
; four words, little end first.
; =============================================================================

; -----------------------------------------------------------------------------
; fx_umul - the unsigned 32-bit at fx_m1:fx_m0 times the one at fx_n1:fx_n0,
; into fx_q. Four word multiplies with the carries propagated by hand.
; Clobbers AX and DX.
; -----------------------------------------------------------------------------
fx_umul:
    push bx
    push cx
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    mov ax, [fx_m0]                    ; a0*b0 -> q1:q0
    mul word [fx_n0]
    mov [fx_q], ax
    mov [fx_q+2], dx
    mov ax, [fx_m0]                    ; a0*b1 -> q2:q1
    mul word [fx_n1]
    add [fx_q+2], ax
    adc word [fx_q+4], dx
    adc word [fx_q+6], 0
    mov ax, [fx_m1]                    ; a1*b0 -> q2:q1
    mul word [fx_n0]
    add [fx_q+2], ax
    adc word [fx_q+4], dx
    adc word [fx_q+6], 0
    mov ax, [fx_m1]                    ; a1*b1 -> q3:q2
    mul word [fx_n1]
    add [fx_q+4], ax
    adc word [fx_q+6], dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; fx_udiv16 - fx_q (64, unsigned) divided by CX (16, unsigned), in place.
; out: DX = the remainder. Four DIVs with the remainder chained from the top
; word down, which is the whole of long division when the divisor fits a word.
; -----------------------------------------------------------------------------
fx_udiv16:
    push ax
    xor dx, dx
    mov ax, [fx_q+6]
    div cx
    mov [fx_q+6], ax
    mov ax, [fx_q+4]
    div cx
    mov [fx_q+4], ax
    mov ax, [fx_q+2]
    div cx
    mov [fx_q+2], ax
    mov ax, [fx_q]
    div cx
    mov [fx_q], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_udiv32 - fx_q (64, unsigned) divided by the unsigned 32-bit in CX:BX.
; The quotient replaces fx_q; DX:AX comes back holding the remainder.
;
; Restoring shift-and-subtract, 64 iterations, IN PLACE: each pass shifts
; fx_q left one bit, the bit that falls out the top joins the remainder at the
; bottom, and the quotient bit goes into fx_q's bit 0 - which the same shift
; has just vacated. One buffer does both jobs, which is why there is no
; second 64-bit temporary in the caller's bss.
; -----------------------------------------------------------------------------
fx_udiv32:
    push si
    push di
    xor ax, ax                         ; DX:AX = the running remainder
    xor dx, dx
    mov si, 64
.l:
    shl word [fx_q], 1                 ; fx_q <<= 1, carry out of the top
    rcl word [fx_q+2], 1
    rcl word [fx_q+4], 1
    rcl word [fx_q+6], 1
    rcl ax, 1                          ; ...into the remainder's bottom
    rcl dx, 1
    cmp dx, cx                         ; remainder >= divisor?
    jb .next
    ja .sub
    cmp ax, bx
    jb .next
.sub:
    sub ax, bx
    sbb dx, cx
    or word [fx_q], 1                  ; the quotient bit the shift vacated
.next:
    dec si
    jnz .l
    pop di
    pop si
    ret

; -----------------------------------------------------------------------------
; fx_amag - |A| into fx_m1:fx_m0 and its sign into fx_sgn (1 = negative).
; fx_bmag - |B| into fx_n1:fx_n0, XORing its sign into fx_sgn.
; fx_setsgn - A = the unsigned 32-bit in DX:AX, negated when fx_sgn says so.
; -----------------------------------------------------------------------------
fx_amag:
    push ax
    push dx
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    mov byte [fx_sgn], 0
    or dx, dx
    jns .pos
    mov byte [fx_sgn], 1
    not ax
    not dx
    add ax, 1
    adc dx, 0
.pos:
    mov [fx_m0], ax
    mov [fx_m1], dx
    pop dx
    pop ax
    ret

fx_bmag:
    push ax
    push dx
    mov ax, [fx_b]
    mov dx, [fx_b+2]
    or dx, dx
    jns .pos
    xor byte [fx_sgn], 1
    not ax
    not dx
    add ax, 1
    adc dx, 0
.pos:
    mov [fx_n0], ax
    mov [fx_n1], dx
    pop dx
    pop ax
    ret

fx_setsgn:
    cmp byte [fx_sgn], 0
    je .pos
    not ax
    not dx
    add ax, 1
    adc dx, 0
.pos:
    mov [fx_a], ax
    mov [fx_a+2], dx
    ret

; -----------------------------------------------------------------------------
; fx_mul - A = A * B.
;
; (a*b)/FX_SCALE, in 64 bits, ROUNDED half away from zero at the last place -
; not truncated. 2.00 * 0.15 is 0.30 either way; 0.07 * 0.07 is 0.0049, and
; truncation would make it 0.00 while a budget expects 0.00 too - but
; 1.05 * 1.05 is 1.1025, where truncation says 1.10 and rounding says 1.10 as
; well. The case that decides it is /3 below, and the same rule is used here
; so that a multiply and a divide cannot disagree about the last penny.
; -----------------------------------------------------------------------------
fx_mul:
    push ax
    push bx
    push cx
    push dx
    call fx_amag
    call fx_bmag
    call fx_umul
    mov cx, FX_SCALE * 2               ; divide by 2*scale and round from the
    call fx_udiv16                     ; remainder, which is the same as
    mov ax, dx                         ; dividing by scale and rounding at
    shl word [fx_q], 1                 ; half - one divide instead of two
    rcl word [fx_q+2], 1
    rcl word [fx_q+4], 1
    rcl word [fx_q+6], 1
    cmp ax, FX_SCALE                   ; remainder >= half the divisor?
    jb .noround
    add word [fx_q], 1
    adc word [fx_q+2], 0
    adc word [fx_q+4], 0
    adc word [fx_q+6], 0
.noround:
    mov ax, [fx_q]
    mov dx, [fx_q+2]
    call fx_setsgn
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_div - A = A / B. CF=1 and A = 0 when B is zero.
;
; (a*FX_SCALE)/b, in 64 bits, rounded half away from zero: 2.00/3 is 0.67 and
; not 0.66, which is what every spreadsheet shows and what a column of thirds
; has to add up to.
; -----------------------------------------------------------------------------
fx_div:
    push ax
    push bx
    push cx
    push dx
    mov ax, [fx_b]
    or ax, [fx_b+2]
    jz .zero
    call fx_amag
    call fx_bmag
    mov word [fx_n0], 0                ; |a| * FX_SCALE -> fx_q, keeping |b|
    mov word [fx_n1], 0                ; out of the multiplier's operands
    mov ax, [fx_b]
    mov dx, [fx_b+2]
    push ax                            ; |b| is needed AFTER the multiply
    push dx
    mov word [fx_n0], FX_SCALE
    call fx_umul
    pop dx
    pop ax
    mov bx, [fx_n0]                    ; the divisor's magnitude, which
    mov cx, [fx_n1]                    ; fx_bmag left there before fx_umul
    mov bx, ax
    mov cx, dx
    cmp byte [fx_sgn], 0               ; fx_bmag already folded B's sign into
    push bx                            ; fx_sgn; the divisor itself has to be
    push cx                            ; a magnitude
    or cx, cx
    jns .bpos
    not bx
    not cx
    add bx, 1
    adc cx, 0
.bpos:
    call fx_udiv32
    pop cx
    pop bx
    or cx, cx                          ; the rounding compare wants |b| too
    jns .bpos2
    not bx
    not cx
    add bx, 1
    adc cx, 0
.bpos2:
    shl ax, 1                          ; 2*remainder >= |b| rounds up
    rcl dx, 1
    cmp dx, cx
    jb .noround
    ja .up
    cmp ax, bx
    jb .noround
.up:
    add word [fx_q], 1
    adc word [fx_q+2], 0
.noround:
    mov ax, [fx_q]
    mov dx, [fx_q+2]
    call fx_setsgn
    clc
    jmp short .out
.zero:
    call fx_azero
    stc
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_trunc - A = A with its fraction dropped, toward zero.
; fx_floor  - A = the largest whole number <= A, which for a negative with a
;             fraction is one MORE step away from zero. Excel's INT.
; -----------------------------------------------------------------------------
fx_trunc:
    push ax
    push cx
    push dx
    call fx_amag
    mov word [fx_q], 0                 ; |a| / scale * scale
    mov word [fx_q+2], 0
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    mov ax, [fx_m0]
    mov [fx_q], ax
    mov ax, [fx_m1]
    mov [fx_q+2], ax
    mov cx, FX_SCALE
    call fx_udiv16
    mov cx, FX_SCALE
    mov ax, [fx_q]
    mul cx
    mov bx, ax
    mov ax, [fx_q+2]
    push bx
    mul cx
    mov dx, ax
    pop ax
    add dx, 0                          ; the high word's own carry is already
    call fx_setsgn                     ; in DX from the second multiply
    pop dx
    pop cx
    pop ax
    ret

fx_floor:
    push ax
    push dx
    push bx
    mov ax, [fx_a]                     ; remember whether it had a fraction
    mov dx, [fx_a+2]
    push ax
    push dx
    call fx_trunc
    pop dx
    pop ax
    cmp dx, [fx_a+2]                   ; unchanged: it was already whole
    jne .frac
    cmp ax, [fx_a]
    je .out
.frac:
    or dx, dx                          ; a POSITIVE fraction truncates the
    jns .out                           ; right way already
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    sub ax, FX_SCALE
    sbb dx, 0
    mov [fx_a], ax
    mov [fx_a+2], dx
.out:
    pop bx
    pop dx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_round - A = A rounded to CX decimal places, half away from zero, which is
; the rule Excel's ROUND states. CX may be negative (tens, hundreds).
;
; With two places stored, CX >= 2 is already the answer. Anything less is a
; divide by 10^(2-CX), rounded, and a multiply back.
; -----------------------------------------------------------------------------
fx_round:
    push ax
    push bx
    push cx
    push dx
    mov bx, FX_PLACES
    sub bx, cx                         ; BX = how many places to drop
    jle .out                           ; already at or below that precision
    cmp bx, 9
    jle .have
    mov bx, 9                          ; 10^9 overflows the word the scale
.have:                                 ; factor is built in; past that the
    mov cx, 1                          ; answer is zero either way
.pow:
    mov ax, cx
    mov dx, 10
    mul dx
    mov cx, ax
    dec bx
    jnz .pow
    push cx                            ; CX = the scale factor
    call fx_amag
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    mov ax, [fx_m0]
    mov [fx_q], ax
    mov ax, [fx_m1]
    mov [fx_q+2], ax
    pop cx
    push cx
    call fx_udiv16                     ; DX = the remainder
    pop cx
    push cx
    mov ax, cx
    shr ax, 1
    cmp dx, ax                         ; half away from zero
    jb .nor
    add word [fx_q], 1
    adc word [fx_q+2], 0
.nor:
    pop cx
    mov ax, [fx_q]                     ; ...and back up
    mul cx
    mov bx, ax
    push dx
    mov ax, [fx_q+2]
    mul cx
    pop dx
    add dx, ax
    mov ax, bx
    call fx_setsgn
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_sqrt - A = sqrt(A). CF=1 and A = 0 if A was negative, or if the square
; root's own intermediate would not fit 32 bits.
;
; sqrt(v/100) scaled back up is sqrt(v*100), so the whole of it is an integer
; square root of v*100 - and Newton on 32 bits gets there in a dozen divides.
; The cap is where v*100 leaves the word: 429,496.72.
; -----------------------------------------------------------------------------
fx_sqrt:
    push bx
    push cx
    push dx
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    or dx, dx
    js .bad
    or ax, ax                          ; sqrt(0) is 0, and Newton cannot start
    jnz .nz                            ; from it
    or dx, dx
    jz .zero
.nz:
    mov cx, FX_SCALE                   ; v * 100, and it must stay in 32 bits
    mov [fx_tmp], ax
    mov [fx_tmp+2], dx
    mov ax, [fx_tmp+2]
    mul cx
    or dx, dx
    jnz .bad                           ; past the cap in the header
    mov bx, ax                         ; BX = the high half so far
    mov ax, [fx_tmp]
    mul cx
    add dx, bx
    jc .bad
    mov [fx_tmp], ax                   ; fx_tmp = n, the value to root
    mov [fx_tmp+2], dx
    mov ax, dx                         ; the seed: half the bit length, which
    or ax, ax                          ; Newton doubles the right bits from
    jnz .seedhi
    mov ax, [fx_tmp]
    mov cx, 1
.seedlo:
    cmp ax, 4
    jb .seeded
    shr ax, 1
    shr ax, 1
    shl cx, 1
    jmp short .seedlo
.seedhi:
    mov cx, 256                        ; a high word at all means at least 2^16
.seeded:
    or cx, cx
    jnz .iter
    mov cx, 1
.iter:
    mov bx, 12                         ; Newton, a fixed dozen: each pass
.nl:                                   ; doubles the correct bits, so twelve
    mov ax, [fx_tmp]                   ; is far past the sixteen it needs
    mov dx, [fx_tmp+2]
    div cx                             ; n / x  (CX is never zero here)
    add ax, cx                         ; (x + n/x) / 2
    rcr ax, 1
    mov cx, ax
    dec bx
    jnz .nl
    mov ax, cx                         ; one guard step down: Newton on
    mul ax                             ; integers can settle one high
    mov bx, ax
    mov ax, [fx_tmp]
    sub ax, bx
    mov ax, cx
    xor dx, dx
    mov [fx_a], ax
    mov [fx_a+2], dx
    clc
    jmp short .out
.zero:
    call fx_azero
    clc
    jmp short .out
.bad:
    call fx_azero
    stc
.out:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; fx_pow - A = A^B.
; out: CF=1 and A zero when there is no answer here: a fractional exponent
;      (this library has no logarithm and no way to mean one), or 0^0.
;
; Repeated squaring, and a negative exponent is one over the result - which is
; the same shape os88fp.inc's own fp_pow uses and for the same reason: it is
; EXACT where exp(y*ln x) is not, and 10^2 comes out 100 rather than
; 99.999999999998.
; -----------------------------------------------------------------------------
fx_pow:
    push bx
    push cx
    push dx
    mov ax, [fx_b]                     ; the exponent has to be whole
    mov dx, [fx_b+2]
    mov [fx_tmp], ax
    mov [fx_tmp+2], dx
    call fx_b_to_a
    push word [fx_a]
    push word [fx_a+2]
    call fx_trunc
    pop dx
    pop ax
    cmp ax, [fx_a]
    jne .badpop
    cmp dx, [fx_a+2]
    jne .badpop
    mov ax, [fx_a]                     ; ...and fit a word once unscaled
    mov dx, [fx_a+2]
    mov cx, FX_SCALE
    idiv cx                            ; AX = the whole exponent, signed
    mov cx, ax
    pop dx                             ; the base, back off the stack below
    pop ax
    mov [fx_a], ax
    mov [fx_a+2], dx
    mov bx, cx                         ; BX = |n|, CX keeps the sign
    or bx, bx
    jge .havebx
    neg bx
.havebx:
    push cx
    mov ax, [fx_a]                     ; the base, banked
    mov dx, [fx_a+2]
    mov [fx_tmp], ax
    mov [fx_tmp+2], dx
    mov word [fx_a], FX_SCALE          ; the running product starts at 1.00
    mov word [fx_a+2], 0
.sq:
    or bx, bx
    jz .done
    mov ax, [fx_tmp]
    mov dx, [fx_tmp+2]
    mov [fx_b], ax
    mov [fx_b+2], dx
    call fx_mul
    dec bx
    jmp short .sq
.done:
    pop cx
    or cx, cx
    jge .out
    call fx_a_to_b                     ; a negative power is one over it
    mov word [fx_a], FX_SCALE
    mov word [fx_a+2], 0
    call fx_div
.out:
    clc
    jmp short .fin
.badpop:
    add sp, 4
    call fx_azero
    stc
.fin:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; fx_i2a - AX = a signed 16-bit integer -> A.  fx_i2b - the same into B.
; -----------------------------------------------------------------------------
fx_i2a:
    push ax
    push dx
    push cx
    mov cx, FX_SCALE
    imul cx                            ; DX:AX = the scaled value, signed
    mov [fx_a], ax
    mov [fx_a+2], dx
    pop cx
    pop dx
    pop ax
    ret

fx_i2b:
    call fx_i2a
    call fx_a_to_b
    ret

; -----------------------------------------------------------------------------
; fx_a2i - A -> AX, a signed 16-bit integer, TRUNCATED toward zero.
; CF=1 if it did not fit, with AX clamped to 32767 / -32768.
; -----------------------------------------------------------------------------
fx_a2i:
    push bx
    push cx
    push dx
    mov ax, [fx_a]
    mov dx, [fx_a+2]
    mov bx, dx                         ; remember the sign
    or dx, dx
    jns .pos
    not ax
    not dx
    add ax, 1
    adc dx, 0
.pos:
    mov cx, FX_SCALE
    cmp dx, cx                         ; a high word at or past the scale
    jae .big                           ; cannot give a word quotient
    div cx                             ; DX:AX / 100, unsigned, fits
    or bx, bx
    jns .psign
    neg ax
.psign:
    cmp ax, 0                          ; the signed range check
    jl .negok
    cmp ax, 0x7FFF
    ja .big
.negok:
    clc
    jmp short .out
.big:
    or bx, bx
    jns .bigpos
    mov ax, 0x8000
    stc
    jmp short .out
.bigpos:
    mov ax, 0x7FFF
    stc
.out:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; fx_u32_to_a - the UNSIGNED 32-bit in fx_q's low two words becomes A.
; os88fp.inc's fp_u64_to_a in every way that matters here: what the caller
; wants is a count past 32,767 (a date serial) without fx_i2a's sign.
; CF=1 and A clamped when the scaled value leaves 31 bits.
; -----------------------------------------------------------------------------
fx_u32_to_a:
    push ax
    push cx
    push dx
    mov cx, FX_SCALE
    mov ax, [fx_q+2]
    mul cx
    or dx, dx
    jnz .big
    mov bx, ax
    mov ax, [fx_q]
    mul cx
    add dx, bx
    js .big
    mov [fx_a], ax
    mov [fx_a+2], dx
    clc
    jmp short .out
.big:
    mov word [fx_a], 0xFFFF
    mov word [fx_a+2], 0x7FFF
    stc
.out:
    pop dx
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fx_atof - DS:SI = text -> A. SI advances past what was consumed.
; out: CF=1 and A = 0 if there was no number here at all.
;
; [+-] digits [ . digits ] [ (e|E) [+-] digits ]. The THIRD decimal digit is
; read and used to round; the rest are consumed and dropped, because a
; caller's "1.005" has to mean 1.01 rather than 1.00 and has to leave SI past
; the whole literal either way.
; -----------------------------------------------------------------------------
fx_atof:
    push bx
    push cx
    push dx
    push di
    call fx_azero
    mov byte [fx_sgn], 0
    xor bx, bx                         ; BX = the value so far, scaled
    xor cx, cx
    xor di, di                         ; DI = digits seen
    cmp byte [si], '-'
    jne .nosign
    mov byte [fx_sgn], 1
    inc si
    jmp short .int
.nosign:
    cmp byte [si], '+'
    jne .int
    inc si
.int:
    mov al, [si]
    cmp al, '0'
    jb .dot
    cmp al, '9'
    ja .dot
    inc di
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, bx                         ; (bx:cx) * 10, 32-bit
    mov dx, cx
    shl ax, 1
    rcl dx, 1
    mov [fx_tmp], ax
    mov [fx_tmp+2], dx
    shl ax, 1
    rcl dx, 1
    shl ax, 1
    rcl dx, 1
    add ax, [fx_tmp]
    adc dx, [fx_tmp+2]
    mov bx, ax
    mov cx, dx
    pop ax
    add bx, ax
    adc cx, 0
    inc si
    jmp short .int
.dot:
    xor dx, dx                         ; DX = fraction digits taken
    cmp byte [si], '.'
    jne .scale
    inc si
.fd:
    mov al, [si]
    cmp al, '0'
    jb .scale
    cmp al, '9'
    ja .scale
    inc di
    inc si
    cmp dx, FX_PLACES
    jb .keep
    cmp dx, FX_PLACES                  ; the THIRD digit rounds, the rest go
    jne .drop
    inc dx
    cmp al, '5'
    jb .drop
    add bx, 1
    adc cx, 0
    jmp short .drop
.drop:
    jmp short .fd
.keep:
    sub al, '0'
    push ax
    mov ax, bx
    push dx
    mov dx, cx
    shl ax, 1
    rcl dx, 1
    mov [fx_tmp], ax
    mov [fx_tmp+2], dx
    shl ax, 1
    rcl dx, 1
    shl ax, 1
    rcl dx, 1
    add ax, [fx_tmp]
    adc dx, [fx_tmp+2]
    mov bx, ax
    mov cx, dx
    pop dx
    pop ax
    xor ah, ah
    add bx, ax
    adc cx, 0
    inc dx
    jmp short .fd
.scale:
    or di, di                          ; no digits at all: not a number
    jz .none
.pad:
    cmp dx, FX_PLACES                  ; short of two places: pad with zeros
    jae .exp
    mov ax, bx
    push dx
    mov dx, cx
    shl ax, 1
    rcl dx, 1
    mov [fx_tmp], ax
    mov [fx_tmp+2], dx
    shl ax, 1
    rcl dx, 1
    shl ax, 1
    rcl dx, 1
    add ax, [fx_tmp]
    adc dx, [fx_tmp+2]
    mov bx, ax
    mov cx, dx
    pop dx
    inc dx
    jmp short .pad
.exp:
    mov [fx_a], bx
    mov [fx_a+2], cx
    cmp byte [si], 'e'
    je .haveexp
    cmp byte [si], 'E'
    jne .signit
.haveexp:
    push si
    inc si
    mov byte [fx_tmp+2], 0
    cmp byte [si], '-'
    jne .epos
    mov byte [fx_tmp+2], 1
    inc si
    jmp short .edig
.epos:
    cmp byte [si], '+'
    jne .edig
    inc si
.edig:
    xor cx, cx
    xor di, di
.eloop:
    mov al, [si]
    cmp al, '0'
    jb .edone
    cmp al, '9'
    ja .edone
    inc di
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, cx
    mov dx, 10
    mul dx
    mov cx, ax
    pop ax
    add cx, ax
    inc si
    cmp cx, 40                         ; anything past this saturates anyway
    jb .eloop
    mov cx, 40
    jmp short .eloop
.edone:
    or di, di                          ; `1e` with no digits is not an
    jz .eundo                          ; exponent - SI goes back to the 'e'
    add sp, 2                          ; the banked SI is not wanted
    jcxz .signit
.escale:
    push cx
    mov word [fx_b], 10 * FX_SCALE
    mov word [fx_b+2], 0
    cmp byte [fx_tmp+2], 0
    je .eup
    call fx_div
    jmp short .enext
.eup:
    call fx_mul
.enext:
    pop cx
    dec cx
    jnz .escale
    jmp short .signit
.eundo:
    pop si
.signit:
    cmp byte [fx_sgn], 0
    je .done
    call fx_neg
.done:
    clc
    jmp short .out
.none:
    call fx_azero
    stc
.out:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; fx_ftoa - A -> a NUL-terminated decimal string at DS:DI. DI preserved.
; in:  AX = how many decimal places to show. 0..2 shows exactly that many;
;      anything else (which is what os88fp.inc's "significant digits" callers
;      pass) means GENERAL - up to two, with trailing zeros and a bare point
;      trimmed.
;
; There is no exponent form and no rounding to do beyond AX: the value already
; IS two decimal places, which is the whole point of this file.
; -----------------------------------------------------------------------------
fx_ftoa:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [fx_tmp+2], ax                 ; the requested places, banked
    call fx_amag
    cmp byte [fx_sgn], 0
    je .nosign
    mov byte [di], '-'
    inc di
.nosign:
    mov word [fx_q+4], 0
    mov word [fx_q+6], 0
    mov ax, [fx_m0]
    mov [fx_q], ax
    mov ax, [fx_m1]
    mov [fx_q+2], ax
    mov cx, FX_SCALE
    call fx_udiv16                     ; fx_q = whole part, DX = hundredths
    mov [fx_tmp], dx
    mov si, fx_dig                     ; the whole part, least digit first
    xor bx, bx
.wl:
    mov cx, 10
    call fx_udiv16
    add dl, '0'
    mov [si+bx], dl
    inc bx
    mov ax, [fx_q]
    or ax, [fx_q+2]
    jnz .wcheck
    or ax, [fx_q+4]
    or ax, [fx_q+6]
    jz .wdone
.wcheck:
    cmp bx, 12
    jb .wl
.wdone:
    or bx, bx                          ; a zero whole part still prints "0"
    jnz .wemit
    mov byte [si], '0'
    mov bx, 1
.wemit:
    dec bx
.we:
    mov al, [si+bx]
    mov [di], al
    inc di
    dec bx
    jns .we
    mov ax, [fx_tmp]                   ; --- the fraction
    mov bx, [fx_tmp+2]
    cmp bx, 0
    je .end                            ; zero places asked for: whole only
    cmp bx, 1
    je .one
    cmp bx, 2
    je .two
    or ax, ax                          ; GENERAL: nothing to show when the
    jz .end                            ; hundredths are zero
    mov bx, 2
    push ax
    mov cx, 10
    xor dx, dx
    div cx
    pop ax
    or dx, dx                          ; ...and one place when the second
    jnz .two                           ; digit is a zero
.one:
    mov byte [di], '.'
    inc di
    xor dx, dx
    mov cx, 10
    div cx
    add al, '0'
    mov [di], al
    inc di
    jmp short .end
.two:
    mov byte [di], '.'
    inc di
    xor dx, dx
    mov cx, 10
    div cx
    push dx
    add al, '0'
    mov [di], al
    inc di
    pop dx
    add dl, '0'
    mov [di], dl
    inc di
.end:
    mov byte [di], 0
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
