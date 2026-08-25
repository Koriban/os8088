; =============================================================================
; os8088 - apps/os88fp.inc
;
; IEEE-754 DOUBLE, IN SOFTWARE, FOR AN 8086 WITH NO FPU.
;
; Stage 4.0 of the spreadsheet roadmap. Sheet's cells have been signed 16-bit
; integers throughout - 123456 commits as -7616, division truncates, and every
; text, date, trigonometric, financial and fraction-returning statistical
; function in Excel's library is blocked on that one fact rather than on
; effort. This is the file that removes it.
;
; --- WHY BINARY DOUBLE AND NOT DECIMAL --------------------------------------
; apps/calc/calc.asm already carries a complete, working decimal engine
; (SPEC.md 65.2): sign-magnitude, a 32-bit 9-digit magnitude, a decimal-place
; count, 64-bit intermediates, add/sub/mul/div with correct rounding. Reusing
; it would have been far less code than this file, and it has the real virtue
; that 0.1 + 0.2 is exactly 0.3.
;
; It was rejected for two reasons specific to a SPREADSHEET rather than a
; calculator:
;
;   1. BIFF's NUMBER record IS an IEEE-754 double, and so is one of RK's four
;      subtypes. File interchange is one of Sheet's real strengths - SYLK, DIF
;      and BIFF, read and written - and a decimal core would mean a lossy
;      conversion at every one of those boundaries, in both directions.
;   2. An 8087 accelerates binary doubles DIRECTLY (fld / faddp / fstp qword)
;      and does essentially nothing for sign-magnitude decimal: its BCD support
;      is load and store, not arithmetic. A decimal core would make the
;      hardware path this roadmap calls for almost pointless.
;
; Nine significant digits against Excel's fifteen settled it.
;
; --- THE STORED FORM ---------------------------------------------------------
; 8 bytes, little-endian, exactly as IEEE-754 and exactly as BIFF wants them:
; 52 fraction bits, an 11-bit exponent biased by 1023, one sign bit.
;
; --- THE WORKING FORM --------------------------------------------------------
; Arithmetic does not run on the packed form. An operand is unpacked into a
; sign byte, a SIGNED UNBIASED exponent, and a 64-bit mantissa normalized so
; bit 63 is always set:
;
;       value = (-1)^sign * m * 2^exp          with m in [2^63, 2^64)
;
; The 11 bits of headroom above the 53-bit significand are guard bits, and they
; are the whole reason results round correctly rather than merely plausibly.
; Packing rounds to nearest, ties to even.
;
; STATED SIMPLIFICATIONS, so they are findable rather than surprising:
;   * SUBNORMALS FLUSH TO ZERO on unpack, and underflow flushes to zero on
;     pack. A spreadsheet that reaches 1e-308 has a modelling problem rather
;     than a rounding one.
;   * NO INFINITY AND NO NaN IS EVER PRODUCED. Overflow CLAMPS to the largest
;     finite double; division by zero returns CF=1 and leaves the result zero.
;     Turning that into Excel's #DIV/0! is the CELL's business, not this
;     file's - an error type is a value-model decision and belongs one layer up.
;   * NEGATIVE ZERO is never written; a zero result packs as +0.
;
; --- USING IT ----------------------------------------------------------------
; `%include "os88fp.inc"` at the END of the package, before OS88_BSS, for the
; fixed-offset reason SPEC.md 20.2 gives.
;
; IT DECLARES NO STORAGE. Like apps/os88chart.inc, the CALLER declares the
; scratch, under these exact names, and every routine here reaches it through
; the caller's own DS - which is never changed anywhere in this file:
;
;   fp_as    db     A's sign, 0 or 1        fp_bs    db     B's sign
;   fp_ae    dw     A's exponent, signed    fp_be    dw     B's exponent
;   fp_am0-3 dw x4  A's mantissa, m0 low    fp_bm0-3 dw x4  B's mantissa
;   fp_t0-3  dw x4  a 64-bit temporary      fp_p0-7  dw x8  the 128-bit product
;   fp_sticky dw    "bits were lost below"  fp_tmp   dw     general scratch
;
; The shape is a two-register machine: unpack into A and B, operate, pack A.
; =============================================================================

FP_SZ      equ 8                    ; a packed double, in bytes
FP_BIAS    equ 1023
FP_EADJ    equ 1086                 ; FP_BIAS + 52 + 11 - the shift between a
                                    ; stored biased exponent and this file's
                                    ; own, given the 11-bit normalization

; =============================================================================
; 64-bit primitives. Every one takes BX = a 4-word block, m0 first.
; =============================================================================

; fp_shl1 - BX left one bit; CF = the bit shifted out of the top
fp_shl1:
    shl word [bx], 1
    rcl word [bx+2], 1
    rcl word [bx+4], 1
    rcl word [bx+6], 1
    ret

; fp_shr1 - BX right one bit; CF = the bit shifted out of the bottom
fp_shr1:
    shr word [bx+6], 1
    rcr word [bx+4], 1
    rcr word [bx+2], 1
    rcr word [bx], 1
    ret

; fp_iszero - CF=1 if the block at BX is all zero
fp_iszero:
    push ax
    mov ax, [bx]
    or ax, [bx+2]
    or ax, [bx+4]
    or ax, [bx+6]
    or ax, ax
    pop ax
    jnz .no
    stc
    ret
.no:
    clc
    ret

; fp_setsticky - OR "any bit set at BX" into fp_sticky
fp_setsticky:
    call fp_iszero
    jc .out
    mov word [fp_sticky], 1
.out:
    ret

; fp_shrn - BX right CX bits, ORing every bit that falls off into fp_sticky.
; CX >= 64 clears the block entirely, which is what an operand too small to
; affect the sum needs.
fp_shrn:
    push cx
    or cx, cx
    jz .out
    cmp cx, 64
    jb .loop
    call fp_setsticky
    mov word [bx], 0
    mov word [bx+2], 0
    mov word [bx+4], 0
    mov word [bx+6], 0
    jmp .out
.loop:
    call fp_shr1
    jnc .next
    mov word [fp_sticky], 1
.next:
    dec cx
    jnz .loop
.out:
    pop cx
    ret

; fp_addt - BX += fp_t (64-bit). CF = carry out of the top.
fp_addt:
    push ax
    mov ax, [fp_t0]
    add [bx], ax
    mov ax, [fp_t1]
    adc [bx+2], ax
    mov ax, [fp_t2]
    adc [bx+4], ax
    mov ax, [fp_t3]
    adc [bx+6], ax
    pop ax
    ret

; fp_subt - BX -= fp_t (64-bit). CF = borrow.
fp_subt:
    push ax
    mov ax, [fp_t0]
    sub [bx], ax
    mov ax, [fp_t1]
    sbb [bx+2], ax
    mov ax, [fp_t2]
    sbb [bx+4], ax
    mov ax, [fp_t3]
    sbb [bx+6], ax
    pop ax
    ret

; fp_cmp64 - compare the block at BX against fp_t; flags as for CMP (unsigned)
fp_cmp64:
    push ax
    mov ax, [bx+6]
    cmp ax, [fp_t3]
    jne .done
    mov ax, [bx+4]
    cmp ax, [fp_t2]
    jne .done
    mov ax, [bx+2]
    cmp ax, [fp_t1]
    jne .done
    mov ax, [bx]
    cmp ax, [fp_t0]
.done:
    pop ax
    ret

; fp_norm - normalize the mantissa at BX so bit 63 is set, decrementing the
; exponent word at DI once per shift. A zero mantissa is left alone.
fp_norm:
    call fp_iszero
    jc .out
.loop:
    test word [bx+6], 0x8000
    jnz .out
    call fp_shl1
    dec word [di]
    jmp .loop
.out:
    ret

; =============================================================================
; Pack and unpack
; =============================================================================

; -----------------------------------------------------------------------------
; fp_unpack_a - DS:SI = a packed double -> the A accumulator. SI preserved.
;
; The 53-bit significand sits in bits 0..52 of the stored form; shifted left by
; 11 its leading 1 lands on bit 63, which is what every routine below assumes.
; The four source words go through fp_t first rather than being juggled in
; registers - there are not enough registers to hold four words, two shift
; counts and a pointer at once, and trying was this file's first bug.
; -----------------------------------------------------------------------------
fp_unpack_a:
    push ax
    push bx
    push cx
    push dx
    mov ax, [si+6]                    ; the top word: sign, exponent, 4 bits
    mov byte [fp_as], 0
    test ax, 0x8000
    jz .sign
    mov byte [fp_as], 1
.sign:
    mov dx, ax
    and dx, 0x7FF0
    mov cl, 4
    shr dx, cl                        ; dx = the biased exponent
    or dx, dx
    jz .zero                          ; 0 = zero or subnormal - flushed
    sub dx, FP_EADJ
    mov [fp_ae], dx
    and ax, 0x000F
    or ax, 0x0010                     ; put the implicit leading 1 back
    mov [fp_t3], ax
    mov ax, [si+4]
    mov [fp_t2], ax
    mov ax, [si+2]
    mov [fp_t1], ax
    mov ax, [si]
    mov [fp_t0], ax
    ; the whole 53 bits, left 11
    mov cl, 11
    mov ax, [fp_t0]
    shl ax, cl
    mov [fp_am0], ax
    mov ax, [fp_t1]
    shl ax, cl
    mov [fp_am1], ax
    mov ax, [fp_t2]
    shl ax, cl
    mov [fp_am2], ax
    mov ax, [fp_t3]
    shl ax, cl
    mov [fp_am3], ax
    mov cl, 5                         ; ...and the bits carried up from below
    mov ax, [fp_t0]
    shr ax, cl
    or [fp_am1], ax
    mov ax, [fp_t1]
    shr ax, cl
    or [fp_am2], ax
    mov ax, [fp_t2]
    shr ax, cl
    or [fp_am3], ax
    jmp .out
.zero:
    mov word [fp_ae], 0
    mov word [fp_am0], 0
    mov word [fp_am1], 0
    mov word [fp_am2], 0
    mov word [fp_am3], 0
.out:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; fp_unpack_b - the same into B. Written as a copy through A rather than
; duplicated, so there is exactly one piece of unpacking arithmetic to be
; wrong: unpack into A, move A to B, and put the caller's A back.
fp_unpack_b:
    push ax
    call fp_push_a
    call fp_unpack_a
    call fp_a_to_b
    call fp_pop_a
    pop ax
    ret

; fp_a_to_b / fp_b_to_a - move one accumulator to the other
fp_a_to_b:
    push ax
    mov al, [fp_as]
    mov [fp_bs], al
    mov ax, [fp_ae]
    mov [fp_be], ax
    mov ax, [fp_am0]
    mov [fp_bm0], ax
    mov ax, [fp_am1]
    mov [fp_bm1], ax
    mov ax, [fp_am2]
    mov [fp_bm2], ax
    mov ax, [fp_am3]
    mov [fp_bm3], ax
    pop ax
    ret

fp_b_to_a:
    push ax
    mov al, [fp_bs]
    mov [fp_as], al
    mov ax, [fp_be]
    mov [fp_ae], ax
    mov ax, [fp_bm0]
    mov [fp_am0], ax
    mov ax, [fp_bm1]
    mov [fp_am1], ax
    mov ax, [fp_bm2]
    mov [fp_am2], ax
    mov ax, [fp_bm3]
    mov [fp_am3], ax
    pop ax
    ret

; fp_push_a / fp_pop_a - bank A on the stack (6 words), for the two places
; that need a third operand's worth of room
fp_push_a:
    pop ax                            ; the return address, put back last
    push word [fp_am3]
    push word [fp_am2]
    push word [fp_am1]
    push word [fp_am0]
    push word [fp_ae]
    push word [fp_as]
    push ax
    ret

; NOTE both of these CLOBBER AX, and fp_pop_a restores only A's sign BYTE.
; `push word [fp_as]` necessarily reads two bytes, and fp_bs is the next one -
; so popping the pair back would silently undo whatever had just been written
; to B. That is not hypothetical: it was this file's first real bug, and it
; presented as "every operation with a negative operand is wrong" while
; same-sign addition looked perfect.
fp_pop_a:
    pop ax
    pop word [fp_tmp]                 ; the saved (as, bs) pair
    pop word [fp_ae]
    pop word [fp_am0]
    pop word [fp_am1]
    pop word [fp_am2]
    pop word [fp_am3]
    push ax
    mov al, [fp_tmp]                  ; ...and put back ONLY A's half of it
    mov [fp_as], al
    ret

; fp_swap_ab - exchange the two accumulators
fp_swap_ab:
    push ax
    push bx
    mov al, [fp_as]
    mov bl, [fp_bs]
    mov [fp_as], bl
    mov [fp_bs], al
    mov ax, [fp_ae]
    mov bx, [fp_be]
    mov [fp_ae], bx
    mov [fp_be], ax
    mov ax, [fp_am0]
    mov bx, [fp_bm0]
    mov [fp_am0], bx
    mov [fp_bm0], ax
    mov ax, [fp_am1]
    mov bx, [fp_bm1]
    mov [fp_am1], bx
    mov [fp_bm1], ax
    mov ax, [fp_am2]
    mov bx, [fp_bm2]
    mov [fp_am2], bx
    mov [fp_bm2], ax
    mov ax, [fp_am3]
    mov bx, [fp_bm3]
    mov [fp_am3], bx
    mov [fp_bm3], ax
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; fp_pack_a - the A accumulator -> the packed double at DS:DI. DI preserved.
; A is left undisturbed; the rounding happens on a copy in fp_t.
;
; Rounds to nearest, TIES TO EVEN. Half-up would bias every long column of
; sums upward, which in a spreadsheet is exactly the visible kind of wrong.
; -----------------------------------------------------------------------------
fp_pack_a:
    push ax
    push bx
    push cx
    push dx
    push di
    mov bx, fp_am0
    call fp_iszero
    jc .zero
    mov ax, [fp_am0]                  ; round on a copy
    mov [fp_t0], ax
    mov ax, [fp_am1]
    mov [fp_t1], ax
    mov ax, [fp_am2]
    mov [fp_t2], ax
    mov ax, [fp_am3]
    mov [fp_t3], ax
    mov dx, [fp_ae]
    mov word [fp_sticky], 0
    mov bx, fp_t0
    mov cx, 10                        ; ten bits away, keeping them sticky...
    call fp_shrn
    mov ax, [fp_t0]                   ; ...the eleventh is the guard bit
    and ax, 1
    mov [fp_tmp], ax
    call fp_shr1
    cmp word [fp_tmp], 0
    je .rounded                       ; guard clear: nothing to decide
    cmp word [fp_sticky], 0
    jne .roundup                      ; guard set and something below: up
    mov ax, [fp_t0]
    and ax, 1
    jz .rounded                       ; an exact tie to an EVEN significand
.roundup:
    add word [fp_t0], 1
    adc word [fp_t1], 0
    adc word [fp_t2], 0
    adc word [fp_t3], 0
    test word [fp_t3], 0x0020         ; carried into bit 53? renormalize
    jz .rounded
    call fp_shr1
    inc dx
.rounded:
    add dx, FP_EADJ                   ; back to a stored biased exponent
    cmp dx, 0x7FF
    jl .noover
    mov word [fp_t0], 0xFFFF          ; clamp to the largest finite double
    mov word [fp_t1], 0xFFFF
    mov word [fp_t2], 0xFFFF
    mov word [fp_t3], 0x001F
    mov dx, 0x7FE
.noover:
    cmp dx, 1
    jl .zero                          ; underflow flushes
    mov ax, [fp_t0]
    mov [di], ax
    mov ax, [fp_t1]
    mov [di+2], ax
    mov ax, [fp_t2]
    mov [di+4], ax
    mov ax, [fp_t3]
    and ax, 0x000F                    ; drop the implicit 1
    mov cl, 4
    shl dx, cl
    or ax, dx
    cmp byte [fp_as], 0
    je .nosign
    or ax, 0x8000
.nosign:
    mov [di+6], ax
    jmp .out
.zero:
    mov word [di], 0
    mov word [di+2], 0
    mov word [di+4], 0
    mov word [di+6], 0
.out:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; Integer conversion
; =============================================================================

; fp_i2a - AX = a signed 16-bit integer -> the A accumulator
fp_i2a:
    push ax
    push bx
    push di
    mov byte [fp_as], 0
    or ax, ax
    jge .abs
    mov byte [fp_as], 1
    neg ax
.abs:
    mov [fp_am0], ax
    mov word [fp_am1], 0
    mov word [fp_am2], 0
    mov word [fp_am3], 0
    mov word [fp_ae], 0
    mov bx, fp_am0
    mov di, fp_ae
    call fp_norm
    pop di
    pop bx
    pop ax
    ret

; fp_a2i - the A accumulator -> AX, a signed 16-bit integer, TRUNCATED toward
; zero. CF=1 if it did not fit, with AX clamped to 32767 / -32768.
fp_a2i:
    push bx
    push cx
    push dx
    mov bx, fp_am0
    call fp_iszero
    jc .zero
    mov dx, [fp_ae]
    cmp dx, 0
    jge .over                         ; 2^63 or more: never fits
    mov cx, dx
    neg cx
    cmp cx, 64
    jae .zero                         ; below 1: truncates to 0
    mov ax, [fp_am0]
    mov [fp_t0], ax
    mov ax, [fp_am1]
    mov [fp_t1], ax
    mov ax, [fp_am2]
    mov [fp_t2], ax
    mov ax, [fp_am3]
    mov [fp_t3], ax
    mov bx, fp_t0
    mov word [fp_sticky], 0
    call fp_shrn
    mov ax, [fp_t1]
    or ax, [fp_t2]
    or ax, [fp_t3]
    or ax, ax
    jnz .over
    mov ax, [fp_t0]
    cmp byte [fp_as], 0
    jne .neg
    cmp ax, 0x7FFF
    ja .over
    jmp .ok
.neg:
    cmp ax, 0x8000
    ja .over
    neg ax
.ok:
    pop dx
    pop cx
    pop bx
    clc
    ret
.zero:
    xor ax, ax
    pop dx
    pop cx
    pop bx
    clc
    ret
.over:
    mov ax, 0x7FFF
    cmp byte [fp_as], 0
    je .oout
    mov ax, 0x8000
.oout:
    pop dx
    pop cx
    pop bx
    stc
    ret

; =============================================================================
; Arithmetic. Every operation is A op= B, leaving the result in A.
; =============================================================================

; fp_neg64 - two's-complement negate the block at BX
fp_neg64:
    not word [bx]
    not word [bx+2]
    not word [bx+4]
    not word [bx+6]
    add word [bx], 1
    adc word [bx+2], 0
    adc word [bx+4], 0
    adc word [bx+6], 0
    ret

; fp_azero - make A a clean positive zero
fp_azero:
    mov byte [fp_as], 0
    mov word [fp_ae], 0
    mov word [fp_am0], 0
    mov word [fp_am1], 0
    mov word [fp_am2], 0
    mov word [fp_am3], 0
    ret

; fp_b_to_t - copy B's mantissa into the temporary
fp_b_to_t:
    push ax
    mov ax, [fp_bm0]
    mov [fp_t0], ax
    mov ax, [fp_bm1]
    mov [fp_t1], ax
    mov ax, [fp_bm2]
    mov [fp_t2], ax
    mov ax, [fp_bm3]
    mov [fp_t3], ax
    pop ax
    ret

; -----------------------------------------------------------------------------
; fp_add - A = A + B
;
; The larger exponent wins the alignment, so the two are ordered first and the
; SMALLER operand is the one shifted right - shifting the larger one would
; throw away the bits that matter instead of the ones that do not.
; -----------------------------------------------------------------------------
fp_add:
    push ax
    push bx
    push cx
    push di
    mov bx, fp_bm0
    call fp_iszero
    jc .out                           ; B is zero: A already is the answer
    mov bx, fp_am0
    call fp_iszero
    jc .takeb
    mov ax, [fp_ae]
    cmp ax, [fp_be]
    jge .ordered
    call fp_swap_ab
.ordered:
    mov cx, [fp_ae]
    sub cx, [fp_be]                   ; cx = how far to bring B down
    call fp_b_to_t
    mov word [fp_sticky], 0
    mov bx, fp_t0
    call fp_shrn
    mov al, [fp_as]
    cmp al, [fp_bs]
    jne .unlike
    mov bx, fp_am0                    ; like signs: a plain sum
    call fp_addt
    jnc .out
    call fp_shr1                      ; it carried out of the top - the carry
    or word [fp_am3], 0x8000          ; is the new leading 1
    inc word [fp_ae]
    jmp .out
.unlike:
    mov bx, fp_am0
    call fp_cmp64                     ; A's magnitude against the aligned B's
    jb .bwins
    call fp_subt
    jmp .renorm
.bwins:
    call fp_subt                      ; A - B underflows, so negate the wrap:
    call fp_neg64                     ; |B - A| without needing a third block
    mov al, [fp_bs]
    mov [fp_as], al
.renorm:
    mov bx, fp_am0
    mov di, fp_ae
    call fp_norm
    call fp_iszero
    jnc .out
    call fp_azero                     ; exact cancellation packs as +0
    jmp .out
.takeb:
    call fp_b_to_a
.out:
    pop di
    pop cx
    pop bx
    pop ax
    ret

; fp_sub - A = A - B. One flip and a sum; there is no separate subtraction path
; to get wrong.
fp_sub:
    push ax
    mov al, [fp_bs]
    xor al, 1
    mov [fp_bs], al
    call fp_add
    mov al, [fp_bs]                   ; put B back as the caller left it
    xor al, 1
    mov [fp_bs], al
    pop ax
    ret

; -----------------------------------------------------------------------------
; fp_mul - A = A * B
;
; A full 64x64 -> 128 product, of which the top 64 bits become the result and
; the bottom 64 become the sticky bit. Sixteen word multiplies with carry
; propagation; the loop is indexed rather than unrolled because sixteen copies
; of the same six lines is where a transcription error hides.
; -----------------------------------------------------------------------------
fp_mul:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov al, [fp_as]
    xor al, [fp_bs]
    mov [fp_tmp], ax                  ; the result's sign, banked
    mov bx, fp_am0
    call fp_iszero
    jc .zero
    mov bx, fp_bm0
    call fp_iszero
    jc .zero
    mov di, fp_p0                     ; clear the 128-bit accumulator
    mov cx, 8
.clr:
    mov word [di], 0
    add di, 2
    dec cx
    jnz .clr
    xor si, si                        ; si = i*2
.iloop:
    xor di, di                        ; di = j*2
.jloop:
    mov bx, fp_am0
    add bx, si
    mov ax, [bx]
    mov bx, fp_bm0
    add bx, di
    mul word [bx]                     ; dx:ax = am[i] * bm[j]
    mov bx, fp_p0
    add bx, si
    add bx, di
    add [bx], ax
    adc [bx+2], dx
    jnc .nocarry
    add bx, 4
.carry:
    add word [bx], 1
    jnc .nocarry
    add bx, 2
    cmp bx, fp_p0 + 16
    jb .carry
.nocarry:
    add di, 2
    cmp di, 8
    jb .jloop
    add si, 2
    cmp si, 8
    jb .iloop
    mov dx, [fp_ae]                   ; e = ea + eb + 64
    add dx, [fp_be]
    add dx, 64
    test word [fp_p0 + 14], 0x8000    ; is the product already 2^127-aligned?
    jnz .aligned
    mov bx, fp_p0                     ; no: one 128-bit shift left
    call fp_shl1                      ; CF = the bit crossing the 64-bit seam,
    mov ax, 0                         ; and it has to be BANKED NOW - the
    adc ax, 0                         ; second fp_shl1 overwrites the flags
    mov bx, fp_p0 + 8
    call fp_shl1
    or [fp_p0 + 8], ax                ; ...then carried into the low bit
    dec dx
.aligned:
    mov ax, [fp_p0]                   ; everything below the top 64 is sticky
    or ax, [fp_p0 + 2]
    or ax, [fp_p0 + 4]
    or ax, [fp_p0 + 6]
    mov word [fp_sticky], 0
    or ax, ax
    jz .nostick
    mov word [fp_sticky], 1
.nostick:
    mov ax, [fp_p0 + 8]
    mov [fp_am0], ax
    mov ax, [fp_p0 + 10]
    mov [fp_am1], ax
    mov ax, [fp_p0 + 12]
    mov [fp_am2], ax
    mov ax, [fp_p0 + 14]
    mov [fp_am3], ax
    mov [fp_ae], dx
    mov ax, [fp_tmp]
    mov [fp_as], al
    mov bx, fp_am0
    mov di, fp_ae
    call fp_norm
    jmp .out
.zero:
    call fp_azero
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; fp_t -= fp_bm
fp_subb_from_t:
    push ax
    mov ax, [fp_bm0]
    sub [fp_t0], ax
    mov ax, [fp_bm1]
    sbb [fp_t1], ax
    mov ax, [fp_bm2]
    sbb [fp_t2], ax
    mov ax, [fp_bm3]
    sbb [fp_t3], ax
    pop ax
    ret

; compare fp_t against fp_bm, flags as for CMP
fp_cmpt_b:
    push ax
    mov ax, [fp_t3]
    cmp ax, [fp_bm3]
    jne .d
    mov ax, [fp_t2]
    cmp ax, [fp_bm2]
    jne .d
    mov ax, [fp_t1]
    cmp ax, [fp_bm1]
    jne .d
    mov ax, [fp_t0]
    cmp ax, [fp_bm0]
.d:
    pop ax
    ret

; -----------------------------------------------------------------------------
; fp_div - A = A / B. CF=1 and A=0 if B is zero.
;
; Restoring shift-and-subtract, 64 iterations, producing 64 quotient bits.
; A is brought below B first so the quotient cannot need a 65th bit.
; -----------------------------------------------------------------------------
fp_div:
    push ax
    push bx
    push cx
    push dx
    push di
    mov bx, fp_bm0
    call fp_iszero
    jc .divzero
    mov al, [fp_as]
    xor al, [fp_bs]
    mov [fp_tmp], ax
    mov bx, fp_am0
    call fp_iszero
    jc .zero
    mov dx, [fp_ae]                   ; e = ea - eb - 64
    sub dx, [fp_be]
    sub dx, 64
    mov ax, [fp_am0]                  ; the remainder starts as A's mantissa
    mov [fp_t0], ax
    mov ax, [fp_am1]
    mov [fp_t1], ax
    mov ax, [fp_am2]
    mov [fp_t2], ax
    mov ax, [fp_am3]
    mov [fp_t3], ax
    call fp_cmpt_b
    jb .small
    mov bx, fp_t0                     ; A >= B: bring it under, and pay for it
    call fp_shr1                      ; with one exponent instead of a 65th bit
    inc dx
.small:
    mov word [fp_p0], 0
    mov word [fp_p0 + 2], 0
    mov word [fp_p0 + 4], 0
    mov word [fp_p0 + 6], 0
    mov cx, 64
.dloop:
    mov bx, fp_p0
    call fp_shl1
    mov bx, fp_t0
    call fp_shl1
    jc .dosub                         ; past 2^64, so certainly >= the divisor
    call fp_cmpt_b
    jb .nosub
.dosub:
    call fp_subb_from_t
    or word [fp_p0], 1
.nosub:
    dec cx
    jnz .dloop
    mov ax, [fp_p0]
    mov [fp_am0], ax
    mov ax, [fp_p0 + 2]
    mov [fp_am1], ax
    mov ax, [fp_p0 + 4]
    mov [fp_am2], ax
    mov ax, [fp_p0 + 6]
    mov [fp_am3], ax
    mov [fp_ae], dx
    mov ax, [fp_tmp]
    mov [fp_as], al
    mov word [fp_sticky], 0
    mov bx, fp_t0                     ; a non-zero remainder means the quotient
    call fp_iszero                    ; was cut short, which rounding must know
    jc .nostick
    mov word [fp_sticky], 1
.nostick:
    mov bx, fp_am0
    mov di, fp_ae
    call fp_norm
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret
.zero:
    call fp_azero
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    clc
    ret
.divzero:
    call fp_azero
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; -----------------------------------------------------------------------------
; fp_cmpab - compare A against B.
; out: AX = -1 (A < B), 0 (equal) or 1 (A > B), and the flags set from it, so
; a caller may use either. Preserves both accumulators.
; -----------------------------------------------------------------------------
fp_cmpab:
    push bx
    push cx
    mov bx, fp_am0
    call fp_iszero
    mov cl, 0
    jnc .anz
    mov cl, 1
.anz:
    mov bx, fp_bm0
    call fp_iszero
    mov ch, 0
    jnc .bnz
    mov ch, 1
.bnz:
    cmp cl, 1
    jne .aisnz
    cmp ch, 1
    je .equal                         ; both zero
    cmp byte [fp_bs], 0               ; A is zero: B's sign decides
    je .less
    jmp .greater
.aisnz:
    cmp ch, 1
    jne .bothnz
    cmp byte [fp_as], 0               ; B is zero: A's sign decides
    je .greater
    jmp .less
.bothnz:
    mov cl, [fp_as]
    cmp cl, [fp_bs]
    je .samesign
    cmp byte [fp_as], 0               ; different signs: the negative is less
    je .greater
    jmp .less
.samesign:
    mov cx, [fp_ae]                   ; same sign: exponent, then mantissa
    cmp cx, [fp_be]
    jl .magless
    jg .magmore
    call fp_b_to_t
    mov bx, fp_am0
    call fp_cmp64
    jb .magless
    ja .magmore
    jmp .equal
.magless:
    cmp byte [fp_as], 0               ; a smaller magnitude is only "less" when
    je .less                          ; both are positive
    jmp .greater
.magmore:
    cmp byte [fp_as], 0
    je .greater
    jmp .less
.less:
    mov ax, -1
    jmp .done
.greater:
    mov ax, 1
    jmp .done
.equal:
    xor ax, ax
.done:
    pop cx
    pop bx
    cmp ax, 0
    ret
