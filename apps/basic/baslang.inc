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
; THE NUMBERS ARE THE DISPATCH TABLE'S INDICES, so they are contiguous and
; the five BINARIES ARE LAST AND TOGETHER. The binaries share one prologue -
; unpack the top two slots into fp's A and B - and a table that sent each of
; them straight to its own body would have to repeat that prologue five
; times. Instead they all enter `.binary`, which runs the prologue once and
; then indexes a second, five-entry table by the same opcode. Both tables are
; checked against OP_N and OP_BIN_N at assembly time (see bas_optab), so
; adding an op and forgetting its row is a build error rather than a jump
; into whatever word follows the table.
OP_NEG      equ 2
OP_PRINT    equ 3                   ; pop and print it
OP_NEWL     equ 4                   ; end the print line
OP_OSAPI    equ 5                   ; + a count byte: the tier C gateway
OP_REG      equ 6                   ; pop an index, push that register
OP_LOAD     equ 7                   ; + an index byte: push that variable
OP_STORE    equ 8                   ; + an index byte: pop into that variable
OP_JF       equ 9                   ; + a word: pop, and jump there if FALSE
OP_JMP      equ 10                  ; + a word: jump there
OP_CLS      equ 23                  ; clear the console
OP_JT       equ 24                  ; + a word: pop, and jump there if TRUE
OP_LINE     equ 22                  ; + a word: the line now running, for a
                                    ; refusal's message (it is LAST because
                                    ; the binaries must stay contiguous)
; --- the binaries, contiguous and last --------------------------------------
OP_ADD      equ 11
OP_SUB      equ 12
OP_MUL      equ 13
OP_DIV      equ 14                  ; `/`, real division
OP_IDIV     equ 15                  ; `\`, integer division
; ...and the six comparisons, which are binaries like any other: two slots in,
; one out. SPEC.md 126's truth is QuickBASIC's - **-1 is TRUE and 0 is
; FALSE** - so a comparison's answer is an ordinary number and `PRINT 1 < 2`
; says -1, which is what a program may then add, store or test.
OP_EQ       equ 16
OP_NE       equ 17
OP_LT       equ 18
OP_GT       equ 19
OP_LE       equ 20
OP_GE       equ 21
OP_N        equ 25                  ; how many there are, table included
OP_BIN_N    equ 11                  ; ...and how many of them are binaries

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

; --- the OPEN BLOCKS, at compile time only (SPEC.md 126) --------------------
; WHILE..WEND, FOR..NEXT and the block IF all need two things remembered
; while their body is compiled: where to jump BACK to, and which forward
; word to patch once the end is known. One entry each, a stack because they
; nest, and the whole of it is gone by the time the program runs.
BAS_BLK_MAX  equ 8                  ; ...and a ninth is refused BY NAME
BAS_BLK_KIND equ 0                  ; word: BK_* below
BAS_BLK_TOP  equ 2                  ; word: the op offset to jump back to
BAS_BLK_PAT  equ 4                  ; word: the forward word to patch
BAS_BLK_V    equ 6                  ; word: FOR's loop variable, else unused
BAS_BLK_EXIT equ 8                  ; word: the head of this loop's chain of
                                    ; EXIT IFs, 0 = none. A loop may have
                                    ; several and none of them knows where
                                    ; the end is yet, so each jump's
                                    ; placeholder holds the offset of the
                                    ; one before it and the closer walks
                                    ; them - the list lives in the op stream
                                    ; and costs no table
BAS_BLK_SZ   equ 16                 ; a POWER OF TWO so bas_blkat is a shift
BK_IF    equ 1
BK_ELSE  equ 2
BK_WHILE equ 3
BK_FOR   equ 4
BK_DO    equ 5
BK_REPEAT equ 6

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

; The compiled program, WHOLE (bas_run): an op stream holds the lot now, not
; one statement. A literal is 9 bytes for as little as one source character,
; so the worst case is far past this - which is why the refusal exists and
; says so by name rather than this being sized for a program nobody writes.
BAS_OPS_MAX equ 4096
BAS_STK_MAX equ 16                  ; the evaluation stack, in SLOTS

; -----------------------------------------------------------------------------
; bas_run - compile the editor's text and run it
; in:  nothing; DS = our segment
; out: nothing; clobbers AX/BX/CX/DX/SI/DI
; -----------------------------------------------------------------------------
bas_run:
    ; **THE WHOLE PROGRAM IS COMPILED, THEN RUN.** It was compiled and run one
    ; STATEMENT at a time, with bas_opn reset per line - which works right up
    ; to the first construct whose arms are other LINES. A loop jumps
    ; backwards over statements that no longer exist by the time it wants
    ; them, so WHILE, FOR and the block IF are all impossible against a
    ; stream that holds one line. This is wave 2d's first change and every
    ; construct in it depends on this paragraph.
    ;
    ; The cost is that the op stream must now hold the whole program at once
    ; (BAS_OPS_MAX), and a program too big for it is refused BY NAME rather
    ; than wrapping.
    mov word [bas_src], bas_prog    ; the scanner's cursor
    mov word [bas_line], 1
    mov word [bas_opn], 0
    mov word [bas_nblk], 0          ; ...and no block is open yet
    mov word [bas_nvar], 0          ; **AND THE VARIABLES GO.** An entry keys
                                    ; on WHERE its name is in bas_prog, not on
                                    ; a copy of it, so an entry that outlives
                                    ; the text it points into names whatever
                                    ; now sits at that offset. Run
                                    ; `x = 7 / y = x * 6 / PRINT y`, retype the
                                    ; program as `PRINT n / N = 3 / ...`, and
                                    ; y's entry - offset 6, one character -
                                    ; spells `n` in the new text: `PRINT n`
                                    ; answered 42.
.stmt:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .fin                         ; end of the program text
    cmp al, 10
    je .blank
    ; **THE LINE NUMBER RIDES IN THE STREAM.** Compiling everything first
    ; means [bas_line] at RUN time is the last line COMPILED, so a division
    ; by zero on line 3 of a 30-line program would be reported against line
    ; 30. OP_LINE puts it back: three bytes a statement, and SPEC.md 126.7's
    ; rule that a refusal names its line keeps meaning what it says.
    mov al, OP_LINE
    call bas_emit
    mov ax, [bas_line]
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .done
    call bas_c_stmt
    cmp byte [bas_bad], 0
    jne .done
.blank:
    call bas_eol                    ; step over the line's terminator
    cmp byte [bas_bad], 0
    je .stmt
    jmp short .done
.fin:
    cmp word [bas_nblk], 0          ; ...and nothing may still be open
    jne .unclosed
    mov al, OP_END
    call bas_emit
    cmp byte [bas_bad], 0
    jne .done
    call bas_exec
    jmp short .done
.unclosed:
    mov si, bas_e_open
    jmp bas_err
.done:
    ret

; -----------------------------------------------------------------------------
; bas_c_stmt - compile one statement
; -----------------------------------------------------------------------------
bas_c_stmt:
    ; **SKIP SPACES FIRST.** bas_word reads from the cursor and does not skip
    ; any, and bas_run only skipped before the top-level call - so the moment
    ; IF compiled its arm by calling this proc again, the cursor sat on the
    ; space before `PRINT` and the arm was refused as "not a statement".
    ; Making the entry point tolerant is what lets it be reentrant at all.
    call bas_skipsp
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
    mov si, bas_kw_if
    call bas_wordis
    je .if
    mov si, bas_kw_while
    call bas_wordis
    je .while
    mov si, bas_kw_wend
    call bas_wordis
    je .wend
    mov si, bas_kw_cls
    call bas_wordis
    je .cls
    mov si, bas_kw_for
    call bas_wordis
    je .for
    mov si, bas_kw_next
    call bas_wordis
    je .next
    mov si, bas_kw_else
    call bas_wordis
    je .selse
    mov si, bas_kw_endif
    call bas_wordis
    je .sendif
    mov si, bas_kw_do
    call bas_wordis
    je .do
    mov si, bas_kw_loop
    call bas_wordis
    je .loop
    mov si, bas_kw_repeat
    call bas_wordis
    je .repeat
    mov si, bas_kw_until
    call bas_wordis
    je .until
    mov si, bas_kw_exit
    call bas_wordis
    je .exit
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
    call bas_c_rel                   ; ...the value
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

; --- IF <cond> THEN <stmt> [ELSE <stmt>] (SPEC.md 126) ----------------------
; ONE LINE. The block form - IF/THEN on a line of its own, ENDIF below it -
; spans STATEMENTS, and bas_run compiles and runs one statement at a time
; (it resets bas_opn per line), so a construct whose arms are other lines
; needs the whole program compiled first. That is wave 2d's change, which
; the loops need anyway; this is the half that fits the machine as it is,
; and it is the half that introduces the branch the rest will reuse.
;
; The arms are compiled by calling bas_c_stmt AGAIN - the statement compiler
; is reentrant, so `IF a THEN IF b THEN PRINT 1` nests without a word of
; extra code, and so does ELSE.
.if:
    call bas_c_rel                  ; the condition
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    call bas_word                   ; ...THEN, and it is not optional: the
    jc .nothen                      ; `IF x GOTO n` spelling is not this
    mov si, bas_kw_then             ; language's and is refused by name
    call bas_wordis
    jne .nothen
    mov al, OP_JF
    call bas_emit
    mov bx, [bas_opn]               ; where the target goes, once it is known
    push bx
    xor ax, ax
    call bas_emitw                  ; ...a placeholder for now
    cmp byte [bas_bad], 0
    jne .ifpop
    ; **NOTHING AFTER THEN MEANS THE BLOCK FORM.** The two share everything
    ; up to here - condition, THEN, the forward jump - and differ only in
    ; who closes it: a statement on this line closes it here, and an empty
    ; rest of line hands that job to ELSE or ENDIF, lines later. The block
    ; form is what wave 2d's whole-program compilation bought (SPEC.md
    ; 126.19); before it there was no later line to hand anything to.
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .ifblock
    cmp al, 10
    je .ifblock
    call bas_c_stmt                 ; the THEN arm, on this line
    cmp byte [bas_bad], 0
    jne .ifpop
    call bas_skipsp                 ; ...ELSE?
    call bas_word
    jc .ifnoelse
    mov si, bas_kw_else
    call bas_wordis
    jne .ifnoelse
    mov al, OP_JMP                  ; the THEN arm must step over the ELSE
    call bas_emit
    mov bx, [bas_opn]
    push bx
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .ifpop2
    pop ax                          ; ...and the JF lands HERE, on the ELSE
    pop bx
    push ax
    mov ax, [bas_opn]
    call bas_patch
    call bas_c_stmt                 ; the ELSE arm
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    mov ax, [bas_opn]
    jmp bas_patch                   ; ...and the JMP lands after it
.ifnoelse:
    ; bas_word found a word and it was not ELSE, so the cursor goes back.
    ; **NOT REACHABLE TODAY, and kept deliberately**: bas_word does not move
    ; the cursor when it finds nothing, bas_skipsp does not cross a newline,
    ; and no statement separator exists - so after an arm the probe always
    ; lands on the line's end and returns CF=1 above. Deleting these two
    ; instructions passes the gate, which is why they are described here
    ; rather than claimed as tested. They become load-bearing the day `:` or
    ; a block IF arrives, and both are cheaper to keep than to rediscover.
    mov [bas_src], di
    pop bx
    mov ax, [bas_opn]
    jmp bas_patch
.ifblock:
    pop cx                          ; the JF's slot goes on the block stack
    xor bx, bx
    mov ax, BK_IF
    jmp bas_blkpush
.ifpop2:
    pop bx
.ifpop:
    pop bx
    ret

; --- ELSE and ENDIF, as STATEMENTS (the block form) -------------------------
; The one-line form reads its own ELSE inside .if above and never reaches
; these; here ELSE begins a line, so it is a statement like any other.
.selse:
    call bas_blkpop                 ; AX = kind, BX = top, CX = the patch
    jc .x
    cmp ax, BK_IF
    jne .wrongblk
    push cx                         ; the IF's JF
    mov al, OP_JMP                  ; ...the THEN arm steps over the ELSE
    call bas_emit
    mov cx, [bas_opn]
    push cx
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .selsepop2
    pop cx                          ; CX = the JMP's slot, the new patch
    pop bx                          ; BX = the IF's JF slot
    push cx
    mov ax, [bas_opn]
    call bas_patch                  ; ...which lands on the ELSE arm
    pop cx
    xor bx, bx
    mov ax, BK_ELSE
    jmp bas_blkpush
.selsepop2:
    pop bx
    pop bx
    ret
; --- DO ... LOOP [UNTIL c] and REPEAT ... UNTIL c (SPEC.md 126) ------------
; BOTH TEST AT THE BOTTOM, which is what distinguishes them from WHILE: the
; body always runs at least once. They are the same loop with two spellings
; - REPEAT/UNTIL is this line's, DO/LOOP is QuickBASIC's - and they share
; every instruction below; only the keyword that may close them differs, so
; a DO cannot be closed by an UNTIL and the refusal says which.
;
; Neither opens a FORWARD jump, so there is nothing to patch: the block
; carries only where the top is, and the closing test jumps back to it.
; --- EXIT IF <cond>: leave the innermost loop (SPEC.md 126) ----------------
.exit:
    call bas_skipsp
    call bas_word                   ; EXIT IF, and IF is not optional - a
    jc .exitnoif                    ; bare EXIT is GFA's and means the same,
    mov si, bas_kw_if               ; but one spelling is enough
    call bas_wordis
    jne .exitnoif
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .x
    call bas_blkinloop              ; BX = which loop, searched DOWNWARDS
    jc .x
    push bx
    mov al, OP_JT                   ; ...leave it when the condition holds
    call bas_emit
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    push bx
    call bas_blkat
    mov ax, [si + BAS_BLK_EXIT]     ; the chain's old head rides in the
    mov cx, [bas_opn]               ; placeholder, and this becomes the head
    call bas_emitw
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    call bas_blkat
    mov [si + BAS_BLK_EXIT], cx
    ret
.exitnoif:
    mov si, bas_e_exitif
    jmp bas_err

.do:
    mov bx, [bas_opn]
    xor cx, cx
    mov ax, BK_DO
    jmp bas_blkpush
.repeat:
    mov bx, [bas_opn]
    xor cx, cx
    mov ax, BK_REPEAT
    jmp bas_blkpush
.loop:
    call bas_blkpop
    jc .x
    cmp ax, BK_DO
    jne .wrongblk
    push bx
    call bas_skipsp                 ; LOOP, or LOOP UNTIL <cond>
    call bas_word
    jc .loopback
    mov si, bas_kw_until
    call bas_wordis
    je .loopuntil
    mov [bas_src], di               ; a word that is not UNTIL: not ours
.loopback:
    pop bx                          ; a bare LOOP goes round for ever, which
    mov al, OP_JMP                  ; is what a program asking for one means
    call bas_emit
    mov ax, bx
    call bas_emitw
    jmp bas_exitshere
.loopuntil:
    pop bx
    jmp .bottom
.until:
    call bas_blkpop
    jc .x
    cmp ax, BK_REPEAT
    jne .wrongblk
    ; fall through: UNTIL closes a REPEAT exactly as LOOP UNTIL closes a DO
.bottom:
    ; <cond> ; JF -> top.  The test is at the BOTTOM, and UNTIL means
    ; "go round again while it is FALSE" - so the jump back is taken on
    ; false, which is OP_JF's own sense and needs no negation.
    push bx
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .btmpop
    mov al, OP_JF
    call bas_emit
    pop ax
    call bas_emitw
    jmp bas_exitshere
.btmpop:
    pop bx
    ret

.sendif:
    call bas_blkpop
    jc .x
    cmp ax, BK_IF                   ; an IF with no ELSE...
    je .endifok
    cmp ax, BK_ELSE                 ; ...or the ELSE that followed one
    jne .wrongblk
.endifok:
    mov bx, cx
    mov ax, [bas_opn]
    jmp bas_patch
.cls:
    mov al, OP_CLS
    jmp bas_emit

; --- FOR v = a TO b [STEP n] ... NEXT [v] (SPEC.md 126) ---------------------
; THE INCREMENT IS EMITTED BEFORE THE TEST and jumped over on the way in:
;
;       v = a ; limit = b
;       JMP test
;   inc:  v = v + step          <- FOR emits this, so the step literal is
;   test: JF after  (v <= limit)   code and nothing has to remember it
;       ...body...
;       JMP inc                 <- all NEXT emits
;   after:
;
; which is why NEXT is four instructions: the only thing it needs from the
; header is where `inc` is, and that is the block's TOP.
;
; THE LIMIT IS EVALUATED ONCE, into a variable no program can name
; (bas_varhidden) - re-testing `b` every time round would differ from every
; BASIC of this line the moment the body assigns to something `b` mentions.
;
; **STEP TAKES A SIGNED LITERAL**, a stated simplification: the test is `<=`
; for a positive step and `>=` for a negative one, so the DIRECTION must be
; known while the loop compiles. An expression there needs the test chosen at
; run time, and is refused by name until something wants it.
.for:
    call bas_skipsp
    call bas_word                   ; the loop variable
    jc .fornov
    call bas_varfind
    jc .x
    mov [bas_blkv], ax              ; parked: bas_blkpush carries it along
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '='
    jne .forneq
    inc word [bas_src]
    call bas_c_rel                  ; v = a
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_STORE
    call bas_emit
    mov ax, [bas_blkv]
    call bas_emit
    call bas_skipsp                 ; TO
    call bas_word
    jc .fornoto
    mov si, bas_kw_to
    call bas_wordis
    jne .fornoto
    call bas_c_rel                  ; limit = b, ONCE
    cmp byte [bas_bad], 0
    jne .x
    call bas_varhidden
    jc .x
    mov [bas_forlim], ax
    mov al, OP_STORE
    call bas_emit
    mov ax, [bas_forlim]
    call bas_emit
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_JMP                  ; ...over the increment, on the way in
    call bas_emit
    mov ax, [bas_opn]
    mov [bas_forjin], ax
    xor ax, ax
    call bas_emitw
    mov ax, [bas_opn]               ; `inc` starts here
    mov [bas_fortop], ax
    mov al, OP_LOAD                 ; v = v + step
    call bas_emit
    mov ax, [bas_blkv]
    call bas_emit
    call bas_for_step               ; the literal, and CL = OP_LE / OP_GE
    cmp byte [bas_bad], 0
    jne .x
    mov [bas_forcmp], cx
    mov al, OP_ADD
    call bas_emit
    mov al, OP_STORE
    call bas_emit
    mov ax, [bas_blkv]
    call bas_emit
    mov bx, [bas_forjin]            ; ...and the entry jump lands HERE
    mov ax, [bas_opn]
    call bas_patch
    mov al, OP_LOAD                 ; test: v  <=/>=  limit
    call bas_emit
    mov ax, [bas_blkv]
    call bas_emit
    mov al, OP_LOAD
    call bas_emit
    mov ax, [bas_forlim]
    call bas_emit
    mov ax, [bas_forcmp]
    call bas_emit
    mov al, OP_JF
    call bas_emit
    mov cx, [bas_opn]
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .x
    mov bx, [bas_fortop]            ; TOP is `inc`, which NEXT jumps to
    mov ax, BK_FOR
    call bas_blkpush
    ret
.next:
    call bas_blkpop                 ; AX = kind, BX = top, CX = the patch
    jc .x
    cmp ax, BK_FOR
    jne .wrongblk
    push cx
    mov al, OP_JMP
    call bas_emit
    mov ax, bx
    call bas_emitw
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp                 ; `NEXT v` may name it, and then it must
    push bx                         ; be the one this block opened
    call bas_word
    pop bx
    jc .nextdone
    push bx
    call bas_varfind
    pop bx
    jc .x
    cmp ax, [bas_blkv]
    jne .nextvar
.nextdone:
    mov ax, [bas_opn]
    call bas_patch
    jmp bas_exitshere
.nextvar:
    mov si, bas_e_nextvar
    jmp bas_err
.fornov:
    mov si, bas_e_forvar
    jmp bas_err
.forneq:
    mov si, bas_e_foreq
    jmp bas_err
.fornoto:
    mov si, bas_e_forto
    jmp bas_err
.nothen:
    mov si, bas_e_then
    jmp bas_err

; --- WHILE <cond> ... WEND (SPEC.md 126) ------------------------------------
; The shape every loop here takes: the condition is re-tested at the TOP, so
; a WHILE whose condition is false at the start runs its body NO times, which
; is what distinguishes it from REPEAT. The jump back is emitted by WEND,
; which is also what patches the forward one - the two halves are a stack
; entry apart and neither is written twice.
.while:
    mov bx, [bas_opn]               ; the top: BEFORE the condition, because
    push bx                         ; the condition is part of the loop
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .wpop
    mov al, OP_JF
    call bas_emit
    mov cx, [bas_opn]               ; ...and the forward word to patch
    push cx
    xor ax, ax
    call bas_emitw
    pop cx
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    mov ax, BK_WHILE
    call bas_blkpush
    ret
.wpop:
    pop bx
    ret
.wend:
    call bas_blkpop                 ; AX = kind, BX = top, CX = the patch
    jc .x                           ; (bas_blkpop says so itself)
    cmp ax, BK_WHILE
    jne .wrongblk
    push cx
    mov al, OP_JMP
    call bas_emit
    mov ax, bx                      ; ...back to the condition
    call bas_emitw
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    mov ax, [bas_opn]               ; ...and the WHILE's JF lands here
    call bas_patch
    jmp bas_exitshere               ; ...as does every EXIT IF it holds
.wrongblk:
    mov si, bas_e_wrongblk
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
    call bas_c_rel  
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
    call bas_c_rel                   ; the value...
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
; bas_c_rel - expr [ relop expr ], the whole of what a VALUE is
;
; **THIS IS THE ENTRY POINT NOW, not bas_c_expr.** A comparison binds looser
; than any arithmetic, so it sits above the whole of it: `a + 1 < b * 2` is
; one comparison of two sums, which is what every BASIC of this line means
; and what makes the operators usable without parentheses.
;
; ONE comparison, not a chain. `a < b < c` is accepted by QuickBASIC and
; means `(a < b) < c` - a truth value compared against c - which is almost
; never what the author meant. Here the second `<` is simply not consumed,
; so the statement ends early and the line is refused by name rather than
; being given that reading.
;
; THE TWO-CHARACTER OPERATORS ARE TESTED FIRST. `<` is a prefix of `<=` and
; `<>`, so testing the single characters first would read `a <= b` as
; `a < (= b)` and refuse it for the wrong reason.
; -----------------------------------------------------------------------------
bas_c_rel:
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    mov ah, [si + 1]
    cmp al, '<'
    je .lt
    cmp al, '>'
    je .gt
    cmp al, '='
    je .eq
.x:
    ret
.lt:
    cmp ah, '='
    je .le2
    cmp ah, '>'
    je .ne2
    mov cl, OP_LT
    jmp .one
.gt:
    cmp ah, '='
    je .ge2
    mov cl, OP_GT
    jmp .one
.eq:
    mov cl, OP_EQ
    jmp .one
.le2:
    mov cl, OP_LE
    jmp .two
.ge2:
    mov cl, OP_GE
    jmp .two
.ne2:
    mov cl, OP_NE
.two:
    inc word [bas_src]              ; the second character as well
.one:
    inc word [bas_src]
    push cx
    call bas_c_expr                 ; ...the right-hand side
    pop cx
    cmp byte [bas_bad], 0
    jne .x
    mov al, cl
    jmp bas_emit

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
    call bas_c_rel  
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
    call bas_c_rel  
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

; --- the open-block stack (compile time) ------------------------------------
; bas_blkat  - SI = entry BX.  BAS_BLK_SZ is 6, so (i*4) + (i*2), no `mul`
; bas_blkpush- AX = kind, BX = top, CX = patch slot; CF=1 = too deep, said
; bas_blkpop - AX = kind, BX = top, CX = patch slot; CF=1 = none open, said
bas_blkat:
    push ax
    mov ax, bx                      ; i*16 = BAS_BLK_SZ, in FOUR shifts and
    shl ax, 1                       ; **NOT `mov cl,4 / shl ax,cl`**: CX is
    shl ax, 1                       ; bas_blkpush's PATCH SLOT argument, and
    shl ax, 1                       ; clobbering CL corrupted the forward
    shl ax, 1                       ; jump of every block pushed - which on
    mov si, ax                      ; a loop is a jump to nowhere, so the
                                    ; program hung and the row read a stale
                                    ; console for the part after it
    add si, bas_blk
    pop ax
    ret

bas_blkpush:
    push bx
    push si
    push dx
    mov dx, bx                      ; DX = top, while BX indexes
    mov bx, [bas_nblk]
    cmp bx, BAS_BLK_MAX
    jae .full
    call bas_blkat
    mov [si + BAS_BLK_KIND], ax
    mov [si + BAS_BLK_TOP], dx
    mov [si + BAS_BLK_PAT], cx
    mov ax, [bas_blkv]              ; FOR's loop variable, parked by the
    mov [si + BAS_BLK_V], ax        ; caller; anything else leaves it alone
    xor ax, ax
    mov [si + BAS_BLK_EXIT], ax     ; ...and no EXIT IF has been seen yet
    inc word [bas_nblk]
    clc
.out:
    pop dx
    pop si
    pop bx
    ret
.full:
    mov si, bas_e_deepblk
    call bas_err
    stc
    jmp .out

bas_blkpop:
    push si
    mov bx, [bas_nblk]
    or bx, bx
    jz .none
    dec bx
    mov [bas_nblk], bx
    call bas_blkat
    mov ax, [si + BAS_BLK_V]
    mov [bas_blkv], ax
    mov ax, [si + BAS_BLK_EXIT]
    mov [bas_blkex], ax
    mov ax, [si + BAS_BLK_KIND]
    mov cx, [si + BAS_BLK_PAT]
    mov bx, [si + BAS_BLK_TOP]
    clc
    pop si
    ret
.none:
    mov si, bas_e_noblk
    call bas_err
    stc
    pop si
    ret

; --- bas_for_step - emit FOR's step as a literal; CL = which test ----------
; out: CX = OP_LE (counting up) or OP_GE (counting down); the PUSHN is
;      emitted here. No STEP means 1.
bas_for_step:
    push ax
    push bx
    push si
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    cmp al, 'S'
    je .maybe
    cmp al, 's'
    je .maybe
.one:
    mov ax, 1                       ; no STEP: up by one
    call fp_i2a
    jmp .emit
.maybe:
    call bas_word
    mov si, bas_kw_step
    call bas_wordis
    jne .notstep
    call bas_skipsp
    mov si, [bas_src]
    xor bx, bx                      ; BX = 1 if it is negative
    cmp byte [si], '-'
    jne .nonneg
    inc bx
    inc word [bas_src]
.nonneg:
    mov si, [bas_src]
    call fp_atof                    ; A = the magnitude
    jc .notlit
    mov [bas_src], si
    or bx, bx
    jz .emit
    mov byte [fp_as], 1             ; ...negative, which is A's sign byte
.emit:
    mov al, OP_PUSHN
    call bas_emit
    cmp byte [bas_bad], 0
    jne .sout
    mov di, bas_ops
    add di, [bas_opn]
    call fp_pack_a
    add word [bas_opn], 8
    mov cx, OP_LE
    cmp byte [fp_as], 0
    je .sout
    mov cx, OP_GE                   ; counting DOWN tests the other way
.sout:
    pop si
    pop bx
    pop ax
    ret
.notstep:
    mov [bas_src], di               ; a word that was not STEP: put it back
    jmp .one
.notlit:
    mov si, bas_e_forstep
    call bas_err
    jmp .sout

; --- bas_exitshere - the loop just closed: its EXIT IFs land on this op ----
bas_exitshere:
    mov bx, [bas_blkex]             ; the chain bas_blkpop took off the entry
    mov ax, [bas_opn]
    jmp bas_blkexits

; --- bas_blkinloop - BX = the innermost OPEN LOOP's index; CF=1 if none ----
; EXIT IF leaves the nearest LOOP, not the nearest block: written inside a
; block IF inside a WHILE it must still leave the WHILE, so the stack is
; searched downwards rather than its top being assumed.
bas_blkinloop:
    push ax
    push si
    mov bx, [bas_nblk]
.ilp:
    or bx, bx
    jz .inone
    dec bx
    call bas_blkat
    mov ax, [si + BAS_BLK_KIND]
    cmp ax, BK_WHILE
    je .ifound
    cmp ax, BK_FOR
    je .ifound
    cmp ax, BK_DO
    je .ifound
    cmp ax, BK_REPEAT
    je .ifound
    jmp .ilp
.ifound:
    clc
    pop si
    pop ax
    ret
.inone:
    mov si, bas_e_exitloop
    call bas_err
    stc
    pop si
    pop ax
    ret

; --- bas_blkexits - every EXIT IF in the chain at BX lands on AX ------------
; Each placeholder holds the offset of the one before it, so the walk reads
; a link, patches it, and follows what it read.
bas_blkexits:
    push ax
    push bx
    push cx
.elp:
    or bx, bx
    jz .edone
    mov cx, [bas_ops + bx]          ; ...the next one, before it is overwritten
    call bas_patch
    mov bx, cx
    jmp .elp
.edone:
    pop cx
    pop bx
    pop ax
    ret

; --- bas_varhidden - a variable NO PROGRAM CAN NAME ------------------------
; out: AX = its index, CF=1 if the table is full (said by name)
;
; FOR evaluates its limit ONCE, at the top, and needs somewhere to keep it;
; re-evaluating `b` every iteration would differ from every BASIC of this
; line the moment the body assigns to something `b` mentions. An entry with
; LENGTH 0 is unreachable from source, because bas_word never returns a word
; of no characters - so the table needs no second kind of entry and
; bas_varfind needs no change.
bas_varhidden:
    push bx
    push cx
    push dx
    push si
    mov dx, [bas_nvar]
    cmp dx, BAS_VAR_MAX
    jae .hfull
    mov bx, dx
    call bas_varat
    xor ax, ax
    mov [si + BAS_VAR_SRC], ax
    mov [si + BAS_VAR_LEN], ax
    mov [si + BAS_VAR_VAL], ax
    mov [si + BAS_VAR_VAL + 2], ax
    mov [si + BAS_VAR_VAL + 4], ax
    mov [si + BAS_VAR_VAL + 6], ax
    mov ax, dx
    inc dx
    mov [bas_nvar], dx
    clc
.hout:
    pop si
    pop dx
    pop cx
    pop bx
    ret
.hfull:
    mov si, bas_e_vars
    call bas_err
    stc
    jmp .hout

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
    ; ONE INDEXED JUMP (SPEC.md 126.5), not a run of compares. The chain this
    ; replaces tested in emission order, so OP_ADD and OP_MUL - which every
    ; expression runs - were reached last, after seven compares and then the
    ; operand prologue. This is the same cost whichever op it is.
    mov bl, [si]
    inc si
    cmp bl, OP_N
    jae .done                       ; an op nothing emits: stop, as before
    xor bh, bh
    shl bx, 1
    jmp [bas_optab + bx]
.binary:
    ; --- the binaries: A is the slot below the top, B is the top ------------
    ; BX still holds the op's slot in bas_optab, which is also its slot in
    ; bas_bintab once the first OP_ADD*2 entries are stepped over - so the
    ; second dispatch costs an add and no compare.
    cmp di, bas_stk + 2*BAS_SLOT
    jb .under
    push si                         ; the op cursor
    push bx
    mov si, di
    sub si, 2*BAS_SLOT
    call fp_unpack_a                ; A = the left operand
    add si, BAS_SLOT
    call fp_unpack_b                ; B = the right
    pop bx
    jmp [bas_bintab + bx - OP_ADD*2]
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

; --- OP_CLS: the console, emptied -------------------------------------------
.cls:
    push si
    push di
    call bas_clshome
    pop di
    pop si
    jmp .next

; --- OP_LINE: which line is running, for a refusal's message ----------------
.line:
    mov ax, [si]
    mov [bas_line], ax
    add si, 2
    jmp .next

; --- OP_JF / OP_JMP: the branch (SPEC.md 126) -------------------------------
; The operand is a word - an offset into bas_ops - and a FORWARD one is
; patched by the compiler once the arm it skips has been emitted
; (bas_patch). OP_JF pops its condition.
;
; **THE TEST IS fp_iszero, NOT fp_a2i.** Truth here is QuickBASIC's: zero is
; false and anything else is true. Converting to an integer first would
; truncate, so `IF 0.5 THEN` would be FALSE - a number that is not zero
; answering as though it were.
.jf:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    sub di, BAS_SLOT                ; the condition is consumed
    push si
    mov si, di
    call fp_unpack_a
    pop si
    push bx
    mov bx, fp_am0
    call fp_iszero                  ; CF=1: A is zero, so the branch is taken
    pop bx
    jc .jmpop
    add si, 2                       ; true: step over the target word
    jmp .next
.jt:
    ; OP_JF's twin, and EXIT IF is its only caller: the same pop and the
    ; same zero test, taken on the other answer.
    cmp di, bas_stk + BAS_SLOT
    jb .under
    sub di, BAS_SLOT
    push si
    mov si, di
    call fp_unpack_a
    pop si
    push bx
    mov bx, fp_am0
    call fp_iszero
    pop bx
    jnc .jmpop                      ; NOT zero, so true: take it
    add si, 2
    jmp .next
.jmpop:
    mov si, [si]
    add si, bas_ops
    jmp .next

; --- the six comparisons, as ONE body (SPEC.md 126) -------------------------
; .binary leaves the opcode in BX - it is the word it indexed bas_bintab with
; - so the operator is still in hand here and six bodies collapse to one
; table of masks. fp_cmpab answers -1, 0 or 1 and keeps both accumulators;
; the result's SIGN picks a bit, the operator picks a mask, and the AND of
; them is the answer. -1 is TRUE, which is what every BASIC of this line
; says and what makes `PRINT 1 < 2` print -1 rather than a word.
.cmp:
    push bx
    call fp_cmpab                   ; AX = -1 / 0 / 1
    mov cl, 1                       ; ...A > B
    or ax, ax
    jz .cz
    jns .cgo
    mov cl, 4                       ; ...A < B
    jmp .cgo
.cz:
    mov cl, 2                       ; ...equal
.cgo:
    pop bx
    push bx
    sub bx, OP_EQ*2                 ; BX = which comparison, doubled
    shr bx, 1
    mov bl, [bas_relmask + bx]
    xor bh, bh
    test bl, cl
    pop bx
    mov ax, 0
    jz .cset
    mov ax, -1                      ; TRUE
.cset:
    call fp_i2a
    jmp .store

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

; --- the dispatch tables (SPEC.md 126.5) ------------------------------------
; One row per opcode, IN OPCODE ORDER, and the two `times` pairs under each
; make a missing or spare row a build error: add an op, forget its row, and
; the jump would otherwise land on whatever word follows the table - which
; assembles cleanly and runs somewhere.
;
; READ THE LINE NUMBER, NOT THE SIGN: each pair reports the same mismatch
; with opposite signs, and which line fired is what says whether the table is
; short or long.
bas_optab:
    dw bas_exec.done                ; OP_END
    dw bas_exec.pushn               ; OP_PUSHN
    dw bas_exec.neg                 ; OP_NEG
    dw bas_exec.print               ; OP_PRINT
    dw bas_exec.newl                ; OP_NEWL
    dw bas_exec.osapi               ; OP_OSAPI
    dw bas_exec.reg                 ; OP_REG
    dw bas_exec.vload               ; OP_LOAD
    dw bas_exec.vstore              ; OP_STORE
    dw bas_exec.jf                  ; OP_JF
    dw bas_exec.jmpop               ; OP_JMP
    dw bas_exec.binary              ; OP_ADD  - all five share the operand
    dw bas_exec.binary              ; OP_SUB    prologue, so every one of them
    dw bas_exec.binary              ; OP_MUL    enters .binary and is sorted
    dw bas_exec.binary              ; OP_DIV    out by bas_bintab below.
    dw bas_exec.binary              ; OP_IDIV
    dw bas_exec.binary              ; OP_EQ
    dw bas_exec.binary              ; OP_NE
    dw bas_exec.binary              ; OP_LT
    dw bas_exec.binary              ; OP_GT
    dw bas_exec.binary              ; OP_LE
    dw bas_exec.binary              ; OP_GE
    dw bas_exec.line                ; OP_LINE
    dw bas_exec.cls                 ; OP_CLS
    dw bas_exec.jt                  ; OP_JT     (NO TRAILING BACKSLASH IN A
                                    ; COMMENT: nasm continues the line on one
                                    ; even there, and an ASCII brace drawn up
                                    ; the right margin silently merged two of
                                    ; these rows into one. The table was 13
                                    ; long and the assertion below said so.)
BAS_OPTAB_N equ ($ - bas_optab) / 2
    times BAS_OPTAB_N - OP_N db 0
    times OP_N - BAS_OPTAB_N db 0

; --- which results each comparison calls TRUE -------------------------------
; one bit per fp_cmpab answer: 4 = A<B, 2 = A=B, 1 = A>B
bas_relmask:
    db 2                            ; OP_EQ : equal
    db 5                            ; OP_NE : less or greater
    db 4                            ; OP_LT
    db 1                            ; OP_GT
    db 6                            ; OP_LE : less or equal
    db 3                            ; OP_GE : greater or equal
BAS_RELMASK_N equ $ - bas_relmask
    times BAS_RELMASK_N - 6 db 0
    times 6 - BAS_RELMASK_N db 0

bas_bintab:
    dw bas_exec.add                 ; OP_ADD
    dw bas_exec.sub                 ; OP_SUB
    dw bas_exec.mul                 ; OP_MUL
    dw bas_exec.div                 ; OP_DIV
    dw bas_exec.idiv                ; OP_IDIV
    dw bas_exec.cmp                 ; OP_EQ  - all six comparisons share one
    dw bas_exec.cmp                 ; OP_NE    body and tell themselves apart
    dw bas_exec.cmp                 ; OP_LT    by the opcode STILL IN BX, which
    dw bas_exec.cmp                 ; OP_GT    .binary leaves there: one table
    dw bas_exec.cmp                 ; OP_LE    of masks instead of six bodies
    dw bas_exec.cmp                 ; OP_GE
BAS_BINTAB_N equ ($ - bas_bintab) / 2
    times BAS_BINTAB_N - OP_BIN_N db 0
    times OP_BIN_N - BAS_BINTAB_N db 0

; -----------------------------------------------------------------------------
; fp_b2i_bas - B as a signed 16-bit integer in AX. CF=1 if it will not fit.
; os88fp.inc has fp_a2i and no fp_b2i, so B goes through A and is put back.
; -----------------------------------------------------------------------------
fp_b2i_bas:
    ; **NOTHING MAY BE PUSHED BETWEEN fp_push_a AND fp_pop_a.** They bank A on
    ; the CALLER'S STACK - six words - so a `pushf` in the middle is the first
    ; thing fp_pop_a takes off, as A's (sign, sign) pair; it then restores the
    ; whole of A one word shifted, and the `popf` afterwards pops A's last
    ; mantissa word as FLAGS. The depth balances, which is why nothing caught
    ; it: what is wrong is the DATA and a carry flag that is now a mantissa
    ; bit. `PRINT 10\3` refused as "outside an INTEGER" from wave 1c until the
    ; wave 2a dispatch work ran the first `\` this language had ever executed.
    ;
    ; So the value and the carry ride in REGISTERS, saved before the bank:
    ; `sbb dx, dx` is 0 or -1 for the carry and `add dx, dx` puts it back, and
    ; neither `mov` nor `pop` disturbs a flag in between.
    push cx
    push dx
    call fp_push_a
    call fp_b_to_a
    call fp_a2i
    mov cx, ax                      ; the value (fp_pop_a clobbers AX - its
    sbb dx, dx                      ; own header says so) and the carry
    call fp_pop_a
    mov ax, cx
    add dx, dx                      ; CF = what fp_a2i said
    pop dx                          ; (pops do not touch the flags)
    pop cx
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
; --- bas_emitw - AX as a WORD into the op stream -----------------------------
; Retired in the audit for having no caller; OP_JF and OP_JMP are that caller,
; and their operand is a word because an op-stream offset is.
bas_emitw:
    push bx
    mov bx, [bas_opn]
    cmp bx, BAS_OPS_MAX - 4
    jae .wfull
    mov [bas_ops + bx], ax
    add word [bas_opn], 2
    pop bx
    ret
.wfull:
    pop bx
    mov si, bas_e_long
    jmp bas_err

; --- bas_patch - the word at op-stream offset BX becomes AX ------------------
; A forward jump's target is not known until its arm is compiled, so the two
; emit a placeholder and come back. BX is where the placeholder is.
bas_patch:
    push bx
    cmp bx, BAS_OPS_MAX - 2
    jae .pout
    mov [bas_ops + bx], ax
.pout:
    pop bx
    ret

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
bas_kw_if:      db 'IF', 0
bas_kw_then:    db 'THEN', 0
bas_kw_else:    db 'ELSE', 0
bas_kw_while:   db 'WHILE', 0
bas_kw_wend:    db 'WEND', 0
bas_kw_cls:     db 'CLS', 0
bas_kw_for:     db 'FOR', 0
bas_kw_to:      db 'TO', 0
bas_kw_step:    db 'STEP', 0
bas_kw_next:    db 'NEXT', 0
bas_kw_endif:   db 'ENDIF', 0
bas_kw_do:      db 'DO', 0
bas_kw_loop:    db 'LOOP', 0
bas_kw_repeat:  db 'REPEAT', 0
bas_kw_until:   db 'UNTIL', 0
bas_kw_exit:    db 'EXIT', 0

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
bas_e_long:     db 'program too long to compile', 0
bas_e_oargs:    db 'OSAPI takes a slot and at most six registers', 0
bas_e_reg:      db 'REG() index is 0..7 - AX BX CX DX SI DI ES CF', 0
bas_e_vars:     db 'too many variables - this wave holds 16', 0
bas_e_then:     db 'IF wants THEN on the same line', 0
bas_e_open:     db 'a block is still open at the end of the program', 0
bas_e_deepblk:  db 'blocks nested deeper than eight', 0
bas_e_noblk:    db 'this closes a block that was never opened', 0
bas_e_wrongblk: db 'this is not what the open block was opened with', 0
bas_e_forvar:   db 'FOR wants a variable', 0
bas_e_foreq:    db "FOR wants '=' after its variable", 0
bas_e_forto:    db 'FOR wants TO', 0
bas_e_forstep:  db 'STEP takes a plain number here, not an expression', 0
bas_e_nextvar:  db 'NEXT names a different variable from its FOR', 0
bas_e_exitif:   db 'EXIT wants IF and a condition', 0
bas_e_exitloop: db 'EXIT IF is not inside a loop', 0
bas_e_wide:     db "'\' truncates to an INTEGER and this is outside it", 0
