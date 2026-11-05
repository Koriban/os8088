; =============================================================================
; os8088 - apps/basic/baslang.inc
;
; THE LANGUAGE (SPEC.md 126): the three stages, over IEEE-754 doubles.
;
; SPEC.md 126.1 keeps the reference implementation's stage boundaries, and not
; out of deference: a stage boundary is where a differential test can be
; taken, so a port whose stages match can be checked one at a time against
; something that already works. This file is the first three of them -
; scanner, compiler, interpreter - with the smallest language that exercises
; all three end to end.
;
; WHAT IS HERE: PRINT of a numeric expression, with + - * / and \,
; parentheses, unary minus, REM and '. One statement a line. That is all, and
; the gaps say so by name rather than guessing.
;
; THE OP STREAM (SPEC.md 126.5) is the shape everything later plugs into. The
; compiler emits postfix, so the interpreter is a stack machine and its inner
; loop is one dispatch on one byte - which is the whole reason 126.5 chose a
; flat array over a tree for an 8086: a tree walk is a recursive descent
; through far pointers at run time.
;
; THAT DISPATCH IS A COMPARE CHAIN and this comment claimed `jmp [table + bx]`
; for three waves while bas_exec never did it. Twelve ops, a run of
; `cmp al, OP_x` / `je`, with the five binary ones grouped behind the
; operand-unpack prologue they share - which is also what makes a table
; awkward rather than obvious. It is honest at twelve; OP_ADD and OP_MUL are
; at the BACK of it behind seven compares, and SPEC.md 126.5 now owes the
; table to wave 2, where the op count stops making a chain defensible.
;
; `/` AND `\` ARE DIFFERENT OPERATORS and both work. `/` is real division -
; BASIC's `/` is floating point even between two integers, so `7/2` is 3.5 -
; and `\` is integer division, which truncates both operands to a signed
; 16-bit INTEGER first, as every BASIC of this line does. Wave 1a shipped `/`
; REFUSED BY NAME rather than answering 3, because a wrong answer that looks
; like a right one is the one thing SPEC.md 126.7's discipline exists to
; prevent; wave 1c brought the numerics and the refusal went.
; =============================================================================

; --- the op codes -------------------------------------------------------------
OP_END      equ 0                   ; stop
OP_PUSHN    equ 1                   ; + EIGHT bytes: a packed double, pushed

; --- the value stack holds DOUBLES (SPEC.md 126.4) --------------------------
; Not 16-bit words. The reference implementation answers PRINT 1000*1000 with
; 1000000 and PRINT 7/2 with 3.5, so an integer stack would have had to refuse
; both - which wave 1a did, by name, saying the numerics were coming. They are
; here, and the refusals go.
;
; A literal is converted ONCE, by fp_atof at COMPILE time, and the eight bytes
; ride in the op stream. The alternative - keeping the text and converting on
; every execution - would put a decimal parse inside a FOR loop.
BAS_SLOT    equ 8
OP_ADD      equ 2
OP_SUB      equ 3
OP_MUL      equ 4
OP_IDIV     equ 5                   ; `\`, integer division
OP_DIV      equ 11                  ; `/`, real division
OP_NEG      equ 6
OP_PRINT    equ 7                   ; pop and print it
OP_NEWL     equ 8                   ; end the print line
OP_OSAPI    equ 9                   ; + a count byte: the tier C gateway
OP_REG      equ 10                  ; pop an index, push that register
OP_LOAD     equ 12                  ; + an index byte: push that variable
OP_STORE    equ 13                  ; + an index byte: pop into that variable

; --- the scalar variables (SPEC.md 126.4, wave 2) ---------------------------
; An entry does NOT hold the name. It holds where the name IS - an offset into
; bas_prog and a length - so a name may be any length and two long names
; cannot alias by sharing a prefix, which a fixed-width name field would make
; silent. The program text is what the editor holds and it does not move for
; the whole of a run, which is the only window this table lives in: bas_run
; clears it, so a name means the same variable from the first line to the last
; and nothing survives into the next RUN.
;
; An index is resolved at COMPILE time and rides in the op stream as one byte,
; so the interpreter multiplies and indexes rather than searching.
BAS_VAR_MAX equ 16                  ; ...and a 17th is refused BY NAME
BAS_VAR_SRC equ 0                   ; word: where the name is in bas_prog
BAS_VAR_LEN equ 2                   ; word: how long it is
BAS_VAR_VAL equ 4                   ; 8:    the value, packed (SPEC.md 84)
BAS_VAR_SZ  equ 12

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
BAS_STK_MAX equ 16                  ; the evaluation stack, in SLOTS

; -----------------------------------------------------------------------------
; bas_run - compile the editor's text and run it
; in:  nothing; DS = our segment
; out: nothing; clobbers AX/BX/CX/DX/SI/DI
; -----------------------------------------------------------------------------
bas_run:
    mov word [bas_src], bas_prog    ; the scanner's cursor
    mov word [bas_line], 1
    mov word [bas_nvar], 0          ; **AND THE VARIABLES GO.** An entry keys
                                    ; on WHERE its name is in bas_prog, not on
                                    ; a copy of it, so an entry that outlives
                                    ; the text it points into names whatever
                                    ; now sits at that offset. Run
                                    ; `x = 7 / y = x * 6 / PRINT y`, retype the
                                    ; program as `PRINT n / N = 3 / ...`, and
                                    ; y's entry - offset 6, one character -
                                    ; spells `n` in the new text: `PRINT n`
                                    ; answered 42. The comment on bas_varfind
                                    ; said this line was here before it was.
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
    ; --- not a keyword, so `name = expr` (SPEC.md 126.4, wave 2) ------------
    ; THE '=' IS TESTED BEFORE THE NAME IS INTERNED. bas_varfind CREATES on a
    ; miss, so looking the name up first would make a variable out of every
    ; mistyped statement and then report the mistyped statement anyway -
    ; leaving a phantom in the table, and one entry nearer the refusal, for a
    ; line that never ran. bas_wordis and bas_skipsp both preserve DI and CX,
    ; so the name is still in hand here.
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '='
    jne .nostmt
    inc word [bas_src]
    call bas_varfind                ; AX = its index, created if new
    jc .x                           ; the table is full; said by name
    push ax
    call bas_c_expr                 ; ...the value
    cmp byte [bas_bad], 0
    jne .xpop
    mov al, OP_STORE
    call bas_emit
    cmp byte [bas_bad], 0
    jne .xpop
    pop ax                          ; ...and the index rides with the op
    jmp bas_emit
.xpop:
    pop ax
    ret
.nostmt:
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
    inc word [bas_src]
    call bas_c_fact
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_DIV
    call bas_emit
    jmp .more
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
    ; --- not a function, so a VARIABLE (SPEC.md 126.4, wave 2) -------------
    ; bas_word left the name in DI/CX and bas_wordis preserved them. A name
    ; never assigned reads 0, which is what every BASIC of this line does -
    ; the entry is born zero in bas_varfind. OPTION EXPLICIT (126, decided,
    ; not built) is where a program says it would rather have the typo.
    call bas_varfind
    jc .x                           ; the table is full; said by name
    push ax
    mov al, OP_LOAD
    call bas_emit
    pop ax
    cmp byte [bas_bad], 0
    jne .x
    jmp bas_emit                    ; ...the index byte after it
.noopen:
    mov si, bas_e_paren
    jmp bas_err
.notword:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .bad
    ; fp_atof reads the number out of the source and leaves it in A; SI is
    ; advanced past what it consumed, which is exactly the scanner's job too,
    ; so the two agree by construction rather than by two sets of rules.
    mov si, [bas_src]
    call fp_atof
    jc .bad
    mov [bas_src], si
    mov al, OP_PUSHN
    call bas_emit
    cmp byte [bas_bad], 0
    jne .x
    mov di, bas_ops
    add di, [bas_opn]
    call fp_pack_a                  ; the eight bytes, into the op stream
    add word [bas_opn], 8
    cmp word [bas_opn], BAS_OPS_MAX - 10
    jb .x
    mov si, bas_e_long
    jmp bas_err
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
.bad:
    mov si, bas_e_expr
    jmp bas_err

; -----------------------------------------------------------------------------
; bas_varfind - the index of the variable named at DI/CX, created if new
; in:  DI = the name in bas_prog, CX = its length
; out: AX = the index, CF=0; CF=1 = the table is full (the reason is said)
;      clobbers AX only
;
; CASE-INSENSITIVE, because BASIC is and bas_wordis already is: `Total` and
; `total` are one variable, which is what every BASIC of this line does and
; what a reader expects. A new entry is born ZERO - eight zero bytes IS 0.0 in
; this format (SPEC.md 84) - so a read before any write answers 0 the way
; QuickBASIC does, rather than whatever the last RUN left there.
;
; THE TYPO IS STILL A BUG and this does not fix it: `totl = total + 1` makes a
; second variable rather than an error. That is the language's own behaviour
; and SPEC.md 126's answer to it is OPTION EXPLICIT, which is decided and not
; yet built; when it is, it gates exactly this routine's create path.
; -----------------------------------------------------------------------------
bas_varfind:
    push bx
    push cx
    push dx
    push si
    push di
    xor bx, bx                      ; BX = the entry being compared
    mov dx, [bas_nvar]
.scan:
    cmp bx, dx
    jae .new
    push bx
    push cx
    push di
    call bas_varat                  ; SI = the entry. NOT `mul`: DX is the
                                    ; table's count and mul writes DX:AX, so
                                    ; the scan's own bound would be gone after
                                    ; the first entry and every name would be
                                    ; created fresh
    cmp cx, [si + BAS_VAR_LEN]
    jne .nextpop
    mov si, [si + BAS_VAR_SRC]      ; SI = its name, in bas_prog
.cmp:
    or cx, cx
    jz .hitpop
    mov al, [si]
    call bas_upper
    mov ah, al
    mov al, [di]
    call bas_upper
    cmp al, ah
    jne .nextpop
    inc si
    inc di
    dec cx
    jmp .cmp
.nextpop:
    pop di
    pop cx
    pop bx
    inc bx
    jmp .scan
.hitpop:
    pop di
    pop cx
    pop bx
    mov ax, bx                      ; found: AX = its index
    clc
    jmp .out
.new:
    cmp dx, BAS_VAR_MAX
    jae .full
    call bas_varat                  ; SI = the new entry; BX == DX here, the
                                    ; scan having run the table out
    mov [si + BAS_VAR_SRC], di
    mov [si + BAS_VAR_LEN], cx
    xor ax, ax                      ; ...born 0.0, which is eight zero bytes
    mov [si + BAS_VAR_VAL], ax
    mov [si + BAS_VAR_VAL + 2], ax
    mov [si + BAS_VAR_VAL + 4], ax
    mov [si + BAS_VAR_VAL + 6], ax
    mov ax, dx
    inc dx
    mov [bas_nvar], dx
    clc
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret
.full:
    mov si, bas_e_vars
    call bas_err
    stc
    jmp .out

; --- bas_varat - SI = the address of entry BX --------------------------------
; BAS_VAR_SZ is 12, so this is (i*4) + (i*8) and no `mul`: the one caller that
; wanted mul needed DX, and the interpreter's two want BX and CX kept too.
bas_varat:
    push ax
    mov ax, bx
    shl ax, 1
    shl ax, 1                       ; i*4
    mov si, ax
    shl ax, 1                       ; i*8
    add si, ax                      ; i*12
    add si, bas_vars
    pop ax
    ret

; --- bas_upper - AL to upper case, ASCII letters only ------------------------
bas_upper:
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    ja .no
    sub al, 32
.no:
    ret

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
    cmp al, OP_PUSHN
    je .pushn
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
    cmp al, OP_LOAD
    je .vload
    cmp al, OP_STORE
    je .vstore
    ; --- the binaries: A is the slot below the top, B is the top ------------
    cmp di, bas_stk + 2*BAS_SLOT
    jb .under
    push si
    push ax
    mov si, di
    sub si, 2*BAS_SLOT
    call fp_unpack_a                ; A = the left operand
    add si, BAS_SLOT
    call fp_unpack_b                ; B = the right
    pop ax
    cmp al, OP_ADD
    je .add
    cmp al, OP_SUB
    je .sub
    cmp al, OP_MUL
    je .mul
    cmp al, OP_DIV
    je .div
    cmp al, OP_IDIV
    je .idiv
    pop si
    jmp .done                       ; an op nothing emits
.add:
    call fp_add
    jmp .store
.sub:
    call fp_sub
    jmp .store
.mul:
    call fp_mul
    jmp .store
.div:
    call fp_div                     ; CF=1 and A=0 when B is zero, which is
    jc .divzero                     ; the one failure this layer reports
    jmp .store
.idiv:
    ; `\` is INTEGER division and truncates both operands first, which is
    ; what it means in every BASIC of this line. fp_a2i/fp_i2a carry the
    ; conversion, so the 16-bit range is the limit and a value outside it is
    ; refused rather than wrapped.
    call fp_b2i_bas
    jc .wide
    mov bx, ax
    or bx, bx
    jz .divzero
    call fp_a2i
    jc .wide
    cmp bx, 0xFFFF
    jne .idok
    cmp ax, 0x8000
    je .wide
.idok:
    cwd
    idiv bx
    call fp_i2a
.store:
    pop si                          ; the op cursor
    sub di, BAS_SLOT                ; one operand consumed
    push di
    sub di, BAS_SLOT                ; ...and the result replaces the other
    call fp_pack_a
    pop di
    jmp .next
.pushn:
    cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT
    jae .over
    ; FOUR WORDS, BY HAND, AND NOT `rep movsb`. movsb writes to ES:DI, and
    ; ES is the KERNEL'S segment on entry to any callback (apps/os88api.inc) -
    ; so the string move would have copied the literal into the kernel. Both
    ; halves here are DS-relative, which is the only thing that is true.
    push bx
    mov bx, 0
.pn:
    mov ax, [si + bx]
    mov [di + bx], ax
    add bx, 2
    cmp bx, BAS_SLOT
    jb .pn
    pop bx
    add si, BAS_SLOT                ; past the literal in the op stream
    add di, BAS_SLOT                ; ...and the stack has grown by one slot
    jmp .next
.neg:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push si
    mov si, di
    sub si, BAS_SLOT
    call fp_unpack_b                ; B = the value...
    xor ax, ax
    call fp_i2a                     ; ...A = 0, and 0 - B negates it without
    call fp_sub                     ; this file knowing how a sign is stored
    push di
    sub di, BAS_SLOT
    call fp_pack_a
    pop di
    pop si
    jmp .next
.print:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    sub di, BAS_SLOT
    push si
    push di
    mov si, di
    call fp_unpack_a
    call bas_sayfp
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
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push si
    mov si, di
    sub si, BAS_SLOT
    call fp_unpack_a
    call fp_a2i                     ; AX = the index
    pop si
    jc .badreg
    cmp ax, R_N
    jae .badreg
    mov bx, ax
    shl bx, 1
    mov ax, [bas_reg + bx]
    push si
    push di
    sub di, BAS_SLOT
    call fp_i2a
    call fp_pack_a
    pop di
    pop si
    jmp .next
.badreg:
    mov si, bas_e_reg
    jmp bas_err

; --- OP_LOAD / OP_STORE: a scalar variable (SPEC.md 126.4) ------------------
; The index is one byte in the op stream, resolved at compile time, so neither
; of these searches. EIGHT BYTES BY HAND rather than `rep movsb`, for the
; reason OP_PUSHN carries: movsb writes to ES:DI and ES is the KERNEL'S
; segment on entry to any callback, so the string move would copy into the
; kernel. [bx+di] and [bx+si] are both legal 8086 addressings; [di+bx] is the
; same mode written the other way round.
.vload:
    cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT
    jae .over
    push bx
    mov bl, [si]                    ; the index...
    inc si
    xor bh, bh
    push si                         ; ...and the op cursor, out of the way
    call bas_varat                  ; SI = the entry
    add si, BAS_VAR_VAL
    xor bx, bx
.ld:
    mov ax, [si + bx]
    mov [di + bx], ax
    add bx, 2
    cmp bx, BAS_SLOT
    jb .ld
    pop si
    pop bx
    add di, BAS_SLOT
    jmp .next
.vstore:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    sub di, BAS_SLOT                ; the value is consumed
    push bx
    mov bl, [si]
    inc si
    xor bh, bh
    push si
    call bas_varat
    add si, BAS_VAR_VAL
    xor bx, bx
.st:
    mov ax, [di + bx]
    mov [si + bx], ax
    add bx, 2
    cmp bx, BAS_SLOT
    jb .st
    pop si
    pop bx
    jmp .next

; --- OP_OSAPI: the gateway (BASIC-BINDINGS-PLAN 3) --------------------------
.osapi:
    mov cl, [si]
    inc si
    xor ch, ch
    push si
    mov bx, cx
    mov ax, BAS_SLOT
    mul bx
    mov bx, ax                      ; BX = count * 8
    sub di, bx
    cmp di, bas_stk
    jb .ounder
    push di
    mov si, di
    call fp_unpack_a                ; the slot
    call fp_a2i
    mov [bas_fp], ax
    mov word [bas_fp + 2], KERNEL_SEG
    dec cx
    jz .ogo
    xor bx, bx
.ofill:
    add si, BAS_SLOT
    push bx
    push cx
    call fp_unpack_a
    call fp_a2i
    pop cx
    pop bx
    mov [bas_reg + bx], ax
    add bx, 2
    dec cx
    jnz .ofill
.ogo:
    mov ax, [bas_reg + R_AX*2]
    mov bx, [bas_reg + R_BX*2]
    mov cx, [bas_reg + R_CX*2]
    mov dx, [bas_reg + R_DX*2]
    mov si, [bas_reg + R_SI*2]
    mov di, [bas_reg + R_DI*2]
    call far [bas_fp]
    pushf                           ; CF FIRST, before anything disturbs it
    mov [bas_reg + R_AX*2], ax
    mov [bas_reg + R_BX*2], bx
    mov [bas_reg + R_CX*2], cx
    mov [bas_reg + R_DX*2], dx
    mov [bas_reg + R_SI*2], si
    mov [bas_reg + R_DI*2], di
    pop ax
    and ax, 1
    mov [bas_reg + R_CF*2], ax
    pop di
    pop si
    jmp .next
.ounder:
    pop si
    mov si, bas_e_stk
    jmp bas_err
.divzero:
    pop si
    mov si, bas_e_div0
    jmp bas_err
.wide:
    pop si
    mov si, bas_e_wide
    jmp bas_err
.under:
    mov si, bas_e_stk
    jmp bas_err
.over:
    mov si, bas_e_deep
    jmp bas_err

; -----------------------------------------------------------------------------
; fp_b2i_bas - B as a signed 16-bit integer in AX. CF=1 if it will not fit.
; os88fp.inc has fp_a2i and no fp_b2i, so B goes through A and is put back.
; -----------------------------------------------------------------------------
fp_b2i_bas:
    call fp_push_a
    call fp_b_to_a
    call fp_a2i
    pushf
    call fp_pop_a
    popf
    ret

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

; -----------------------------------------------------------------------------
; bas_sayfp - A, onto the console, the way this language prints a number
; in:  A = the value; out: nothing; clobbers AX/BX/CX/DX/SI/DI
;
; SEVEN significant digits, which is what the reference prints and therefore
; what this must: a bare literal is a SINGLE (SPEC.md 126.4), SINGLE arithmetic
; stays SINGLE, and seven digits is what a SINGLE is worth. Checked against it
; rather than chosen - `PRINT 1/3` is ` .3333333 ` there, not sixteen digits.
;
; **The leading zero goes.** BASIC prints .3333333 and not 0.3333333, which
; fp_ftoa does not know, so it is trimmed here. And the sign's place and the
; trailing separator are QuickBASIC's, as bas_sayint already does them.
;
; This computes in DOUBLE and prints seven digits, where SPEC.md 126.4 says a
; SINGLE must also NARROW to 32 bits on every store. There is no store yet -
; wave 1c has no variables - so the two agree on every value a program can
; currently produce. The narrowing is owed when `!` variables arrive.
; -----------------------------------------------------------------------------
bas_sayfp:
    push bx
    ; **NOT fp_dig.** That is fp_ftoa's OWN internal digit scratch
    ; (apps/fptest declares it as "24: the digit string fp_ftoa builds"), so
    ; handing it in as the DESTINATION makes the routine overwrite its working
    ; buffer as it converts. It printed 3.5 as `3..` and 3.14159 as `3......`
    ; - the integer part right and every fractional digit a full stop.
    mov di, bas_fpbuf
    mov ax, 7
    call fp_ftoa                    ; A -> a NUL string at DS:DI
    mov si, bas_fpbuf
    cmp byte [si], '-'
    jne .nosign
    mov si, bas_s_minus
    call con_say
    inc di                          ; ...and print the rest without it
    mov si, di
    jmp .lead
.nosign:
    mov si, bas_s_sp                ; the sign's place, as QuickBASIC leaves it
    call con_say
    mov si, di
.lead:
    cmp byte [si], '0'              ; 0.5 prints as .5
    jne .go
    cmp byte [si + 1], '.'
    jne .go
    inc si
.go:
    call con_say
    mov si, bas_s_sp                ; and the separator after it
    call con_say
    pop bx
    ret

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
bas_s_minus:    db '-', 0
bas_s_bar:      db '| ', 0
bas_s_errat:    db 'Error at line', 0
bas_s_colon:    db ': ', 0

bas_e_stmt:     db 'not a statement this wave knows', 0
bas_e_expr:     db 'expected a number', 0
bas_e_paren:    db 'expected )', 0
bas_e_div0:     db 'division by zero', 0
bas_e_stk:      db 'expression went wrong', 0
bas_e_deep:     db 'expression too deep', 0
bas_e_long:     db 'line too long to compile', 0
bas_e_oargs:    db 'OSAPI takes a slot and at most six registers', 0
bas_e_reg:      db 'REG() index is 0..7 - AX BX CX DX SI DI ES CF', 0
bas_e_vars:     db 'too many variables - this wave holds 16', 0
bas_e_wide:     db "'\\' truncates to an INTEGER and this is outside it", 0
