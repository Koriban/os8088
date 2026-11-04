; =============================================================================
; os8088 - apps/basic/baslang.inc
;
; THE LANGUAGE (SPEC.md 126), wave 1a: the three stages, with integers.
;
; SPEC.md 126.1 keeps the reference implementation's stage boundaries, and not
; out of deference: a stage boundary is where a differential test can be
; taken, so a port whose stages match can be checked one at a time against
; something that already works. This file is the first three of them -
; scanner, compiler, interpreter - with the smallest language that exercises
; all three end to end.
;
; WHAT IS HERE: PRINT of an INTEGER expression, with + - * and \, parentheses,
; unary minus, REM and '. One statement a line. That is all, and the gaps say
; so by name rather than guessing.
;
; THE OP STREAM (SPEC.md 126.5) is the shape everything later plugs into. The
; compiler emits postfix, so the interpreter is a stack machine and its inner
; loop is one dispatch - which is the whole reason 126.5 chose a flat array
; over a tree for an 8086: a tree walk is a recursive descent through far
; pointers at run time, and this is `jmp [table + bx]`.
;
; `/` IS REFUSED BY NAME and `\` is not. BASIC's `/` is floating-point
; division even between two integers, so an integer `/` here would be a wrong
; answer that looks like a right one - the one thing SPEC.md 126.7's whole
; discipline exists to prevent. `\` is integer division in every BASIC of this
; line and is exactly what this wave can do, so it is the one that works.
; =============================================================================

; --- the op codes -------------------------------------------------------------
OP_END      equ 0                   ; stop
OP_PUSHI    equ 1                   ; + a word: push it
OP_ADD      equ 2
OP_SUB      equ 3
OP_MUL      equ 4
OP_IDIV     equ 5                   ; `\`, integer division
OP_NEG      equ 6
OP_PRINT    equ 7                   ; pop and print it
OP_NEWL     equ 8                   ; end the print line
OP_OSAPI    equ 9                   ; + a count byte: the tier C gateway
OP_REG      equ 10                  ; pop an index, push that register

; --- the register file (SPEC.md 126, BASIC-BINDINGS-PLAN 3) ------------------
; GFA needed six trap verbs and eight parameter arrays because that IS the
; AES/VDI calling convention. This OS passes in REGISTERS over one flat space
; of 194 slots, so the whole of tier C is one verb and one small array.
R_AX equ 0
R_BX equ 1
R_CX equ 2
R_DX equ 3
R_SI equ 4
R_DI equ 5
R_ES equ 6                          ; read-only in wave 1b: a buffer argument
                                    ; needs the string heap (wave 3) and the
                                    ; pin-and-pass operator with it
R_CF equ 7                          ; THE CARRY FLAG, and the reason this
                                    ; array exists at all: failure on this OS
                                    ; is CF, uniformly, and a binding layer
                                    ; that dropped it would turn every refused
                                    ; call into a silently wrong answer
R_N  equ 8

BAS_OPS_MAX equ 512                 ; the compiled program
BAS_STK_MAX equ 16                  ; the evaluation stack, in WORDS

; -----------------------------------------------------------------------------
; bas_run - compile the editor's text and run it
; in:  nothing; DS = our segment
; out: nothing; clobbers AX/BX/CX/DX/SI/DI
; -----------------------------------------------------------------------------
bas_run:
    mov word [bas_src], bas_prog    ; the scanner's cursor
    mov word [bas_line], 1
.stmt:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .done                        ; end of the program text
    cmp al, 10
    je .blank
    ; --- compile one line into a fresh op stream and run it ------------------
    mov word [bas_opn], 0
    call bas_c_stmt
    cmp byte [bas_bad], 0
    jne .done
    mov al, OP_END                  ; TERMINATE IT. bas_opn is reset per
    call bas_emit                   ; statement but bas_ops keeps the bytes,
                                    ; so without this the interpreter runs on
                                    ; into whatever the PREVIOUS line left -
                                    ; zeroed bss hides it until the second
                                    ; statement is shorter than the first
    cmp byte [bas_bad], 0
    jne .done                       ; the error is already on the console
%ifdef BAS_DIAG
    mov ax, [bas_opn]               ; TEMPORARY: how many op bytes this line
    call bas_sayint                 ; compiled to, so a wrong answer can be
    mov si, bas_s_bar               ; blamed on the compiler or the
    call con_say                    ; interpreter rather than guessed at
%endif
    call bas_exec
    cmp byte [bas_bad], 0
    jne .done
.blank:
    call bas_eol                    ; step over the line's terminator
    cmp byte [bas_bad], 0
    je .stmt
.done:
    ret

; -----------------------------------------------------------------------------
; bas_c_stmt - compile one statement
; -----------------------------------------------------------------------------
bas_c_stmt:
    call bas_word                   ; DI = the keyword, CX = its length
    jc .nokw
    mov si, bas_kw_print
    call bas_wordis
    je .print
    mov si, bas_kw_rem
    call bas_wordis
    je .rem
    mov si, bas_kw_end
    call bas_wordis
    je .end
    mov si, bas_kw_osapi
    call bas_wordis
    je .osapi
    mov si, bas_e_stmt
    jmp bas_err
.nokw:
    mov si, [bas_src]
    mov al, [si]
    cmp al, "'"                     ; ' is REM, as it is in every BASIC here
    je .rem
    mov si, bas_e_stmt
    jmp bas_err
.rem:
    call bas_toeol                  ; the rest of the line is a comment
    ret
.end:
    mov al, OP_END
    jmp bas_emit
.osapi:
    ; OSAPI slot [,ax [,bx [,cx [,dx [,si [,di]]]]]]
    ; The slot and up to six register values, left to right. Anything not
    ; given keeps whatever the last call left in it, which is what makes a
    ; sequence of related calls short.
    xor cx, cx                      ; CX = how many values pushed
.oarg:
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .x
    inc cx
    cmp cx, 7
    ja .otoomany
    call bas_skipsp
    push cx
    mov si, [bas_src]
    cmp byte [si], ','
    pop cx
    jne .odone
    inc word [bas_src]
    jmp .oarg
.odone:
    mov al, OP_OSAPI
    push cx
    call bas_emit
    pop cx
    mov al, cl
    jmp bas_emit                    ; the count rides with the op
.otoomany:
    mov si, bas_e_oargs
    jmp bas_err
.print:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .pbare
    cmp al, 10
    je .pbare
    call bas_c_expr                 ; the value...
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_PRINT                ; ...and print it
    call bas_emit
.pbare:
    mov al, OP_NEWL                 ; a bare PRINT is a blank line
    jmp bas_emit
.x:
    ret

; -----------------------------------------------------------------------------
; bas_c_expr - expression:  term { (+|-) term }
; -----------------------------------------------------------------------------
bas_c_expr:
    call bas_c_term
    cmp byte [bas_bad], 0
    jne .x
.more:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    cmp al, '+'
    je .add
    cmp al, '-'
    je .sub
    ret
.add:
    inc word [bas_src]
    call bas_c_term
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_ADD
    call bas_emit
    jmp .more
.sub:
    inc word [bas_src]
    call bas_c_term
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_SUB
    call bas_emit
    jmp .more
.x:
    ret

; -----------------------------------------------------------------------------
; bas_c_term - term:  factor { (*|\) factor }
; -----------------------------------------------------------------------------
bas_c_term:
    call bas_c_fact
    cmp byte [bas_bad], 0
    jne .x
.more:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    cmp al, '*'
    je .mul
    cmp al, '\'
    je .idiv
    cmp al, '/'
    je .slash
    ret
.mul:
    inc word [bas_src]
    call bas_c_fact
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_MUL
    call bas_emit
    jmp .more
.idiv:
    inc word [bas_src]
    call bas_c_fact
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_IDIV
    call bas_emit
    jmp .more
.slash:
    ; REFUSED BY NAME, with the reason and the thing that does work. `/` is
    ; floating-point division in this language even between two integers
    ; (SPEC.md 126.4), so answering it with an integer divide would be a wrong
    ; answer wearing a right one's clothes.
    mov si, bas_e_slash
    jmp bas_err
.x:
    ret

; -----------------------------------------------------------------------------
; bas_c_fact - factor:  number | '(' expr ')' | '-' factor
; -----------------------------------------------------------------------------
bas_c_fact:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    cmp al, '-'
    je .neg
    cmp al, '('
    je .paren
    cmp al, 'A'                     ; a word here is a function call, and in
    jb .notword                     ; wave 1b there is exactly one
    cmp al, 'z'
    ja .notword
    call bas_word
    jc .bad
    mov si, bas_kw_reg
    call bas_wordis
    jne .nofn
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '('
    jne .noopen
    inc word [bas_src]
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'
    jne .noclose
    inc word [bas_src]
    mov al, OP_REG
    jmp bas_emit
.nofn:
    mov si, bas_e_fn
    jmp bas_err
.noopen:
    mov si, bas_e_paren
    jmp bas_err
.notword:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .bad
    call bas_number                 ; AX = the value
    jc .over
    push ax
    mov al, OP_PUSHI
    call bas_emit
    pop ax
    jmp bas_emitw
.neg:
    inc word [bas_src]
    call bas_c_fact
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_NEG
    jmp bas_emit
.paren:
    inc word [bas_src]
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'
    jne .noclose
    inc word [bas_src]
.x:
    ret
.noclose:
    mov si, bas_e_paren
    jmp bas_err
.over:
    mov si, bas_e_over
    jmp bas_err
.bad:
    mov si, bas_e_expr
    jmp bas_err

; -----------------------------------------------------------------------------
; bas_exec - run the compiled op stream
; -----------------------------------------------------------------------------
bas_exec:
    mov si, bas_ops
    mov di, bas_stk                 ; DI = the stack pointer, growing up
.next:
    mov al, [si]
    inc si
    cmp al, OP_END
    je .done
    cmp al, OP_PUSHI
    je .pushi
    cmp al, OP_PRINT
    je .print
    cmp al, OP_NEWL
    je .newl
    cmp al, OP_NEG
    je .neg
    cmp al, OP_OSAPI
    je .osapi
    cmp al, OP_REG
    je .reg
    ; --- the binaries: pop B into BX, leave A on the stack to be replaced ----
    cmp di, bas_stk + 4
    jb .under
    sub di, 2
    mov bx, [di]                    ; B
    mov dx, [di-2]                  ; A
    cmp al, OP_ADD
    je .add
    cmp al, OP_SUB
    je .sub
    cmp al, OP_MUL
    je .mul
    cmp al, OP_IDIV
    je .idiv
    jmp .done                       ; an op nothing emits
.add:
    add dx, bx
    jo .wide
    jmp .store
.sub:
    sub dx, bx
    jo .wide
    jmp .store
.mul:
    mov ax, dx
    imul bx                         ; DX:AX - and OF is set exactly when the
    jo .wide                        ; upper half is not AX's sign extension,
    mov dx, ax                      ; which is the test we want, for free
    jmp .store                      ; **AND NOT A FALL-THROUGH INTO .idiv.**
                                    ; Leaving this out made 2+3*4 answer 5:
                                    ; the multiply gave 12, fell into the
                                    ; divide and made it 12\4 = 3, and 2+3 is
                                    ; 5. It assembled, it ran, and only the
                                    ; number was wrong
.idiv:
    or bx, bx
    jz .divzero
    ; -32768 \ -1 is +32768, which does not fit, and an 8086 answers that
    ; with INT 0 - a TRAP, not a wrong answer. A refusal is better than
    ; either, so it is tested for rather than discovered.
    cmp bx, 0xFFFF
    jne .divok
    cmp dx, 0x8000
    je .divover
.divok:
    mov ax, dx
    cwd                             ; sign-extend AX into DX:AX for idiv
    idiv bx
    mov dx, ax
.store:
    mov [di-2], dx
    jmp .next
.pushi:
    cmp di, bas_stk + BAS_STK_MAX*2
    jae .over
    mov ax, [si]
    inc si
    inc si
    mov [di], ax
    inc di
    inc di
    jmp .next
.neg:
    cmp di, bas_stk + 2
    jb .under
    neg word [di-2]
    jmp .next
.print:
    cmp di, bas_stk + 2
    jb .under
    sub di, 2
    mov ax, [di]
    push si
    push di
    call bas_sayint
    pop di
    pop si
    jmp .next
.newl:
    push si
    push di
    mov si, bas_s_crlf
    call con_say
    pop di
    pop si
    jmp .next
.done:
    ret

; --- OP_REG: pop an index, push that register -------------------------------
.reg:
    cmp di, bas_stk + 2
    jb .under
    mov bx, [di-2]
    cmp bx, R_N
    jae .badreg
    shl bx, 1
    mov bx, [bas_reg + bx]
    mov [di-2], bx
    jmp .next
.badreg:
    mov si, bas_e_reg
    jmp bas_err

; --- OP_OSAPI: the gateway (SPEC.md 126, BASIC-BINDINGS-PLAN 3) -------------
; The values were pushed left to right - slot, then AX, BX, CX, DX, SI, DI -
; so they come off in reverse. SI and DI are THIS INTERPRETER'S op pointer and
; stack pointer, so both are saved across the call; the API cell preserves
; everything it does not document, DS included, but it cannot preserve what
; we hand it on purpose.
.osapi:
    mov cl, [si]                    ; the count
    inc si
    xor ch, ch
    push si                         ; the op stream's cursor
    mov bx, cx
    shl bx, 1
    cmp di, bas_stk
    jb .ounder
    sub di, bx                      ; DI = the first of the run
    cmp di, bas_stk
    jb .ounder
    mov si, di                      ; walk it forwards: slot first
    mov ax, [si]
    mov [bas_fp], ax                ; the slot is the OFFSET; KERNEL_SEG is
    mov word [bas_fp + 2], KERNEL_SEG   ; fixed at build time (apps/os88api.inc)
    dec cx
    jz .ogo
    mov bx, 0                       ; then AX, BX, CX, DX, SI, DI in order
.ofill:
    add si, 2
    mov ax, [si]
    mov [bas_reg + bx], ax
    add bx, 2
    dec cx
    jnz .ofill
.ogo:
    push di                         ; the value stack's pointer
    mov ax, [bas_reg + R_AX*2]
    mov bx, [bas_reg + R_BX*2]
    mov cx, [bas_reg + R_CX*2]
    mov dx, [bas_reg + R_DX*2]
    mov si, [bas_reg + R_SI*2]
    mov di, [bas_reg + R_DI*2]
    call far [bas_fp]
    pushf                           ; CF FIRST, before anything can disturb it
    mov [bas_reg + R_AX*2], ax
    mov [bas_reg + R_BX*2], bx
    mov [bas_reg + R_CX*2], cx
    mov [bas_reg + R_DX*2], dx
    mov [bas_reg + R_SI*2], si
    mov [bas_reg + R_DI*2], di
    pop ax
    and ax, 1                       ; ...and published as 0 or 1, because a
    mov [bas_reg + R_CF*2], ax      ; refused call reporting success is the
    pop di                          ; worst defect this layer can have
    pop si
    jmp .next
.ounder:
    pop si
    mov si, bas_e_stk
    jmp bas_err

.divzero:
    mov si, bas_e_div0
    jmp bas_err
.divover:
    mov si, bas_e_over
    jmp bas_err
.wide:
    ; A RESULT THAT DOES NOT FIT IS REFUSED, NOT WRAPPED. The reference
    ; implementation answers PRINT 1000*1000 with 1000000, widening past the
    ; 16 bits this wave has; wrapping would make it 16960 - a wrong answer
    ; that looks like a right one, which is the single thing SPEC.md 126.7's
    ; discipline exists to stop. The wider arithmetic arrives with the
    ; numerics in wave 1c; until then this says so.
    mov si, bas_e_wide
    jmp bas_err
.under:
    mov si, bas_e_stk
    jmp bas_err
.over:
    mov si, bas_e_deep
    jmp bas_err

; =============================================================================
; the scanner
; =============================================================================

; --- bas_skipsp - step the cursor over spaces and tabs -----------------------
bas_skipsp:
    push si
    push ax
    mov si, [bas_src]
.l:
    mov al, [si]
    cmp al, ' '
    je .step
    cmp al, 9
    jne .done
.step:
    inc si
    jmp .l
.done:
    mov [bas_src], si
    pop ax
    pop si
    ret

; --- bas_toeol / bas_eol - to the line's end, and over it --------------------
bas_toeol:
    push si
    push ax
    mov si, [bas_src]
.l:
    mov al, [si]
    or al, al
    jz .done
    cmp al, 10
    je .done
    inc si
    jmp .l
.done:
    mov [bas_src], si
    pop ax
    pop si
    ret

bas_eol:
    call bas_toeol
    push si
    mov si, [bas_src]
    cmp byte [si], 10
    jne .done
    inc si
    mov [bas_src], si
    inc word [bas_line]
.done:
    pop si
    ret

; --- bas_number - AX = the value at the cursor; CF=1 on overflow -------------
; A 16-bit INTEGER is what SPEC.md 126.4 says a bare number is here, so a
; literal that will not fit is refused rather than wrapped - BASIC/nw's own
; `LET a% = 100000` is error 6, and a silent wrap would be the wrong answer.
bas_number:
    push bx
    push cx
    push dx
    push si
    xor ax, ax
    mov bx, 10
    mov si, [bas_src]
.l:
    mov cl, [si]
    cmp cl, '0'
    jb .done
    cmp cl, '9'
    ja .done
    mul bx                          ; DX:AX
    or dx, dx
    jnz .over
    sub cl, '0'
    xor ch, ch
    add ax, cx
    jc .over
    cmp ax, 32767
    ja .over
    inc si
    jmp .l
.done:
    mov [bas_src], si
    clc
.x:
    pop si
    pop dx
    pop cx
    pop bx
    ret
.over:
    stc
    jmp .x

; --- bas_word - DI = the word at the cursor, CX = its length; CF=1 if none ---
bas_word:
    push ax
    push si
    mov di, [bas_src]               ; DI = the word's start, and the output
    mov si, di
    xor cx, cx
.l:
    mov al, [si]
    cmp al, 'A'
    jb .end
    cmp al, 'Z'
    jbe .take
    cmp al, 'a'
    jb .end
    cmp al, 'z'
    ja .end
.take:
    inc si
    inc cx
    jmp .l
.end:
    or cx, cx
    jz .none
    mov [bas_src], si               ; past the word
    pop si
    pop ax
    clc                             ; (pops do not touch the flags)
    ret
.none:
    pop si
    pop ax
    stc
    ret

; --- bas_wordis - ZF=1 if the word at DI/CX matches the NUL string at SI -----
; Case-insensitive, because BASIC is (`print` and `PRINT` are one keyword).
bas_wordis:
    push ax
    push bx
    push cx
    push si
    push di
    xor bx, bx
.l:
    mov al, [si]
    or al, al
    jz .end
    or cx, cx
    jz .no
    mov ah, [di]
    cmp ah, 'a'
    jb .noup
    cmp ah, 'z'
    ja .noup
    sub ah, 32
.noup:
    cmp al, ah
    jne .no
    inc si
    inc di
    dec cx
    jmp .l
.end:
    or cx, cx                       ; the whole word, not a prefix
    jnz .no
    xor bx, bx                      ; ZF = 1
.out:
    or bx, bx
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret
.no:
    mov bx, 1                       ; ZF = 0
    jmp .out

; =============================================================================
; emitting, printing and refusing
; =============================================================================

; --- bas_emit / bas_emitw - one byte, one word, into the op stream -----------
bas_emit:
    push bx
    mov bx, [bas_opn]
    cmp bx, BAS_OPS_MAX - 3
    jae .full
    mov [bas_ops + bx], al
    inc word [bas_opn]
    pop bx
    ret
.full:
    pop bx
    mov si, bas_e_long
    jmp bas_err

bas_emitw:
    push bx
    mov bx, [bas_opn]
    cmp bx, BAS_OPS_MAX - 3
    jae .full
    mov [bas_ops + bx], ax
    inc word [bas_opn]
    inc word [bas_opn]
    pop bx
    ret
.full:
    pop bx
    mov si, bas_e_long
    jmp bas_err

; --- bas_sayint - AX = a signed 16-bit value, onto the console ---------------
; QuickBASIC's PRINT puts a space where the sign would be on a positive
; number, and this language keeps that (`STR$` does too - library.md says so
; in as many words), so the two agree and a port's output lines up.
bas_sayint:
    push ax
    push bx
    push cx
    push dx
    push si
    mov si, bas_numbuf + 7          ; build it backwards from the end
    mov byte [si], 0
    mov cx, ax
    or ax, ax
    jns .pos
    neg ax
.pos:
    mov bx, 10
.l:
    xor dx, dx
    div bx
    add dl, '0'
    dec si
    mov [si], dl
    or ax, ax
    jnz .l
    dec si
    mov byte [si], ' '              ; the sign's place, as QuickBASIC leaves it
    or cx, cx
    jns .go
    mov byte [si], '-'
.go:
    call con_say
    mov si, bas_s_sp                ; ...and the one AFTER it: QuickBASIC
    call con_say                    ; separates numbers that way, and the
                                    ; reference does it too - checked, not
                                    ; assumed (` 42 `, trailing space and all)
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- bas_err - SI = a NUL reason. Say it with the line number and stop -------
; SPEC.md 126.7's discipline: a refusal is reported BY NAME, with its reason,
; at the line that has it - never as a wrong answer and never silently.
bas_err:
    push si
    mov si, bas_s_errat
    call con_say
    mov ax, [bas_line]
    call bas_sayint
    mov si, bas_s_colon
    call con_say
    pop si
    call con_say
    mov si, bas_s_crlf
    call con_say
    mov byte [bas_bad], 1
    ret

; --- the keywords and the reasons --------------------------------------------
bas_kw_print:   db 'PRINT', 0
bas_kw_rem:     db 'REM', 0
bas_kw_end:     db 'END', 0
bas_kw_osapi:   db 'OSAPI', 0
bas_kw_reg:     db 'REG', 0

bas_s_crlf:     db 13, 10, 0
bas_s_sp:       db ' ', 0
bas_s_bar:      db '| ', 0
bas_s_errat:    db 'Error at line', 0
bas_s_colon:    db ': ', 0

bas_e_stmt:     db 'not a statement this wave knows', 0
bas_e_expr:     db 'expected a number', 0
bas_e_paren:    db 'expected )', 0
bas_e_over:     db 'number too big for an INTEGER', 0
bas_e_div0:     db 'division by zero', 0
bas_e_stk:      db 'expression went wrong', 0
bas_e_deep:     db 'expression too deep', 0
bas_e_long:     db 'line too long to compile', 0
bas_e_oargs:    db 'OSAPI takes a slot and at most six registers', 0
bas_e_reg:      db 'REG() index is 0..7 - AX BX CX DX SI DI ES CF', 0
bas_e_fn:       db 'not a function this wave knows', 0
bas_e_wide:     db 'result is wider than an INTEGER - wave 1c brings the rest', 0
bas_e_slash:    db "'/' is floating point and arrives in wave 1c - use '\\'", 0
