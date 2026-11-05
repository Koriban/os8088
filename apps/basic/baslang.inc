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
OP_CALL     equ 25                  ; + a word: call the procedure there
OP_RET      equ 26                  ; ...and come back out of one
OP_LOCAL    equ 27                  ; + an index byte: save that variable on
                                    ; the frame's share of the save stack and
                                    ; zero it (SPEC.md 126.23)
OP_N        equ 28                  ; how many there are, table included
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
BK_SELECT equ 7
BK_DEFAULT equ 8
BK_PROC  equ 9
BK_FUNC  equ 10

; --- labels and GOTO (SPEC.md 126.22) --------------------------------------
; A label's name is kept as WHERE IT IS in bas_prog, for bas_vars' reason -
; the text is stable for the whole of a run, and a copy would be 16 more
; names to store. LOOP is the innermost loop's own top offset, unique per
; loop and 0 for none, which is what makes a jump into a DIFFERENT loop at
; the same nesting depth refusable.
BAS_LBL_MAX  equ 16
BAS_LBL_SRC  equ 0
BAS_LBL_LEN  equ 2
BAS_LBL_OPS  equ 4                  ; word: where in the op stream it is
BAS_LBL_LOOP equ 6
BAS_LBL_SZ   equ 8

; A GOTO that names a label not seen yet. LINE rides along so the refusal
; names the GOTO's own line and not the program's last one - the resolution
; happens where the text ends, long after [bas_line] has moved on.
BAS_FWD_MAX  equ 8
BAS_FWD_SRC  equ 0
BAS_FWD_LEN  equ 2
BAS_FWD_SLOT equ 4                  ; word: the placeholder to patch
BAS_FWD_LOOP equ 6
BAS_FWD_LINE equ 8
BAS_FWD_SZ   equ 10

; --- procedures (SPEC.md 126.23) -------------------------------------------
BAS_PRC_MAX  equ 8
BAS_PRC_SRC  equ 0
BAS_PRC_LEN  equ 2
BAS_PRC_OPS  equ 4                  ; word: where its body begins
BAS_PRC_NP   equ 6                  ; word: how many values it takes
BAS_PRC_FN   equ 8                  ; word: 1 if it RETURNS one
BAS_PRC_SZ   equ 10
BAS_PRC_PMAX equ 4                  ; ...and the most it may take

; A call whose procedure has not been seen yet. LINE rides along for
; BAS_FWD_LINE's reason.
BAS_CAL_MAX  equ 16
BAS_CAL_SRC  equ 0
BAS_CAL_LEN  equ 2
BAS_CAL_SLOT equ 4
BAS_CAL_LINE equ 6
BAS_CAL_NARG equ 8                  ; word: so the count is checked even when
BAS_CAL_FN   equ 10                 ; the procedure is seen later - and the
BAS_CAL_SZ   equ 12                 ; KIND the call site wanted, likewise

; A FRAME is two words and nothing else: where to come back to, and where
; this frame's saved variables begin. Thirty-two of them is the recursion
; depth, and GFA's own manual recurses ten deep in its FUNCTION example.
BAS_FRM_MAX  equ 32
BAS_FRM_RET  equ 0
BAS_FRM_SAVE equ 2
BAS_FRM_SZ   equ 4

; ONE save stack for every frame. A record is which variable and what it
; held, so a LOCAL is a push and a RETURN is a run of pops.
BAS_SAV_MAX  equ 64
BAS_SAV_IDX  equ 0
BAS_SAV_VAL  equ 2
BAS_SAV_SZ   equ 10

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
    mov word [bas_nlbl], 0          ; ...nor any label seen, for the reason
    mov word [bas_nprc], 0          ; the variables go below: an entry keys on
    mov word [bas_ncal], 0
    mov word [bas_inprc], 0
    mov word [bas_nfrm], 0          ; ...and no call is in progress
    mov word [bas_nsav], 0
    mov word [bas_nfwd], 0          ;
                                    ; where its name is in a text that the
                                    ; next RUN will have replaced
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
    call bas_fwdfix                 ; ...and every GOTO must have found its
    cmp byte [bas_bad], 0           ; label (SPEC.md 126.22)
    jne .done
    call bas_calfix                 ; ...and every call its procedure
    cmp byte [bas_bad], 0
    jne .done
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
    ; **A LABEL IS PROBED BEFORE THE KEYWORDS**, because its name may be
    ; anything at all - it may even begin with a digit (SPEC.md 126.22) -
    ; and what identifies it is the colon, not the name. The probe puts the
    ; cursor back when there is no colon, so an ordinary statement pays one
    ; scan of its first word for this.
    call bas_lblmaybe
    jc .nolabel
    call bas_lbldef
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp                 ; ...and a label may share its line
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .lbldone
    cmp al, 10
    je .lbldone
    jmp bas_c_stmt                  ; TAIL call, not a nested one: a line of
.lbldone:                           ; eight labels must not be eight frames
    ret
.nolabel:
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
    mov si, bas_kw_elseif           ; BEFORE or after ELSE makes no
    call bas_wordis                 ; difference: bas_wordis compares the
    je .selseif                     ; whole word, never a prefix
    mov si, bas_kw_select           ; SELECT, and SWITCH is GFA's own second
    call bas_wordis                 ; spelling of it (the compendium's entry
    je .select                      ; 228), not a synonym invented here
    mov si, bas_kw_switch
    call bas_wordis
    je .select
    mov si, bas_kw_case
    call bas_wordis
    je .case
    mov si, bas_kw_dflt
    call bas_wordis
    je .sdefault
    mov si, bas_kw_othw             ; ...which GFA accepts and rewrites to
    call bas_wordis                 ; DEFAULT for other BASICs' sake
    je .sdefault
    mov si, bas_kw_endsel
    call bas_wordis
    je .sendsel
    mov si, bas_kw_endsw
    call bas_wordis
    je .sendsel
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
    mov si, bas_kw_goto
    call bas_wordis
    je .goto
    mov si, bas_kw_gosub            ; GOSUB name / @name / name - one call,
    call bas_wordis                 ; three spellings, GFA's entry 237
    je .gosub
    mov si, bas_kw_proc
    call bas_wordis
    je .proc
    mov si, bas_kw_sub
    call bas_wordis
    je .proc
    mov si, bas_kw_return
    call bas_wordis
    je .sreturn
    mov si, bas_kw_endproc
    call bas_wordis
    je .sreturn
    mov si, bas_kw_endsub
    call bas_wordis
    je .sreturn
    mov si, bas_kw_local
    call bas_wordis
    je .slocal
    mov si, bas_kw_func
    call bas_wordis
    je .func
    mov si, bas_kw_endfunc
    call bas_wordis
    je .sendfunc
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
    je .assign
    ; **A BARE NAME IS A CALL ONLY IF NOTHING ELSE FOLLOWS IT**, which keeps
    ; `PRIN 3` the refusal it was rather than a call to a procedure called
    ; PRIN with a stray 3 after it (SPEC.md 126.23).
    mov al, [si]
    or al, al
    jz .barecall
    cmp al, 10
    je .barecall
    cmp al, '('                     ; ...or hands over values
    je .barecall
    jmp .nostmt
.barecall:
    xor al, al
    jmp bas_callemit                ; DI/CX = the name
.assign:
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
; AN ARM'S TWO JUMPS ARE DIFFERENT KINDS OF PENDING. The false-jump at the
; arm's head has exactly ONE destination - the next arm, which the next line
; names - so the entry's PAT slot holds it and each arm patches the last
; one. The jump at the arm's FOOT goes to the end of the whole construct,
; which no arm knows, and there is one per arm; so those are the chain
; EXIT IF already built (SPEC.md 126.19), threaded through their own
; placeholders and walked once by ENDIF. An ELSE arm has no false-jump, and
; PAT = 0 says so - offset 0 is the program's first OPCODE and can never be
; a placeholder, which is what makes zero a usable "none" here.
.selse:
    call bas_blkpop                 ; AX = kind, BX = top, CX = the JF slot,
    jc .x                           ; and the done-chain in [bas_blkex]
    cmp ax, BK_IF
    jne .wrongblk
    push cx
    mov ax, [bas_blkex]             ; this arm is finished: jump to the ENDIF
    call bas_donejmp
    mov [bas_blkex], ax
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    mov ax, [bas_opn]
    call bas_patch                  ; ...and the JF lands on the ELSE arm
    xor cx, cx                      ; ELSE opens no false-jump of its own
    xor bx, bx
    mov ax, BK_ELSE
    call bas_blkpush
    jc .x
    mov ax, [bas_blkex]
    jmp bas_blksetex

; --- ELSEIF <cond> THEN: another arm (SPEC.md 126) -------------------------
; GFA spells it `ELSE IF` and takes no THEN at all; this language's block IF
; already requires THEN (SPEC.md 126.18), so it is one word here and takes
; one, and the refusals say so by name.
.selseif:
    call bas_blkpop
    jc .x
    cmp ax, BK_ELSE                 ; ...which is a DIFFERENT mistake from
    je .elifelse                    ; closing the wrong kind of block
    cmp ax, BK_IF
    jne .wrongblk
    push cx
    mov ax, [bas_blkex]
    call bas_donejmp
    mov [bas_blkex], ax
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    mov ax, [bas_opn]
    call bas_patch                  ; the last arm's JF lands on THIS TEST,
    call bas_c_rel                  ; which is the one instruction that
    cmp byte [bas_bad], 0           ; makes ELSEIF cheaper than a nested IF
    jne .x
    call bas_skipsp
    call bas_word
    jc .elifnothen
    mov si, bas_kw_then
    call bas_wordis
    jne .elifnothen
    mov al, OP_JF
    call bas_emit
    mov cx, [bas_opn]               ; ...and this arm opens its own
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .x
    xor bx, bx
    mov ax, BK_IF                   ; still a BK_IF: ENDIF closes either
    call bas_blkpush
    jc .x
    mov ax, [bas_blkex]
    jmp bas_blksetex
.elifnothen:
    mov si, bas_e_then
    jmp bas_err
.elifelse:
    mov si, bas_e_elifelse
    jmp bas_err
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

; --- PROCEDURE / RETURN / LOCAL, and the three spellings of a call ---------
; (SPEC.md 126.23)
.gosub:
    call bas_skipsp
    call bas_lblword                ; a procedure's name is a label's name
    jc .gosnoname
    xor al, al                      ; a STATEMENT, so no value may come back
    jmp bas_callemit
.gosnoname:
    mov si, bas_e_gosname
    jmp bas_err
.atcall:
    inc word [bas_src]              ; over the '@'
    call bas_lblword
    jc .gosnoname
    xor al, al                      ; ...and @name HERE is a procedure call;
    jmp bas_callemit                ; @name in an EXPRESSION is a function's,
                                    ; which is how GFA's two entries read

.func:
    mov dx, 1                       ; ...the one difference between them
    jmp short .proc0
.proc:
    xor dx, dx
.proc0:
    cmp word [bas_inprc], 0         ; ...and not inside another one
    jne .procin
    call bas_skipsp
    call bas_lblword
    jc .procnoname
    ; **THE JUMP OVER THE BODY COMES FIRST.** A main program that runs off
    ; its own end must step over every procedure rather than fall into the
    ; first one, and three bytes a procedure removes the whole question.
    ; Its placeholder is the block's PAT, patched by RETURN.
    mov al, OP_JMP
    call bas_emit
    cmp byte [bas_bad], 0
    jne .x
    mov bx, [bas_opn]               ; ...and the slot rides on the STACK: CX
    push bx                         ; and DI are the NAME, which bas_prcdef
    xor ax, ax                      ; still needs
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .procpop
    call bas_prcdef                 ; ...the body begins HERE, after the jump
    cmp byte [bas_bad], 0
    jne .procpop
    push dx
    call bas_prckind                ; which of the two it is
    call bas_prcparams              ; (w, h) - the prologue, if there is one
    pop dx
    cmp byte [bas_bad], 0
    jne .procpop
    pop cx                          ; CX = the jump to patch at the end
    xor bx, bx
    mov ax, BK_PROC
    or dx, dx
    jz .procpush
    mov ax, BK_FUNC                 ; ...and ENDFUNC closes this one
.procpush:
    jmp bas_blkpush
.procpop:
    pop bx
    ret
.procin:
    mov si, bas_e_prcin
    jmp bas_err
.procnoname:
    mov si, bas_e_prcname
    jmp bas_err

.sreturn:
    cmp word [bas_inprc], 0
    je .retout
    call bas_isfn                   ; AX = 1 inside a FUNCTION
    or ax, ax
    jnz .retfn
    ; --- a PROCEDURE's RETURN: nothing after it, and it closes the body --
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .retbare
    cmp al, 10
    jne .retvalue
.retbare:
    call bas_blkpop                 ; AX = kind, CX = the jump over the body
    jc .x
    cmp ax, BK_PROC
    jne .wrongblk
    push cx
    mov al, OP_RET
    call bas_emit
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    mov ax, [bas_opn]
    call bas_patch                  ; ...and the jump over lands after it
    mov word [bas_inprc], 0
    ret
.retfn:
    ; --- a FUNCTION's RETURN: a value, and it does NOT close the body.
    ; **NO OP_RETV** (SPEC.md 126.25): the value is on the stack where the
    ; expression left it and OP_RET touches the stack not at all, so it is
    ; still there when the caller's expression goes on.
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .retnoval
    cmp al, 10
    je .retnoval
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_RET
    jmp bas_emit
.retnoval:
    mov si, bas_e_fnval
    jmp bas_err
.retvalue:
    mov si, bas_e_prcval
    jmp bas_err
.retout:
    mov si, bas_e_retout
    jmp bas_err

.sendfunc:
    call bas_blkpop
    jc .x
    cmp ax, BK_FUNC
    jne .wrongblk
    push cx
    ; A BODY THAT FALLS OFF ITS END RETURNS 0, where GFA's manual offers
    ; only "expect unpredictable results if you reach this point".
    call bas_emitzero
    cmp byte [bas_bad], 0
    jne .efpop
    mov al, OP_RET
    call bas_emit
    pop bx
    cmp byte [bas_bad], 0
    jne .x
    mov ax, [bas_opn]
    call bas_patch
    mov word [bas_inprc], 0
    ret
.efpop:
    pop bx
    ret

.slocal:
    cmp word [bas_inprc], 0         ; a LOCAL outside a procedure would save
    je .locout                      ; a value nothing ever restores
.loclp:
    call bas_skipsp
    call bas_word                   ; a VARIABLE's name, not a label's
    jc .locnoname
    call bas_varfind                ; AX = its index, created if new
    jc .x
    push ax
    mov al, OP_LOCAL
    call bas_emit
    pop ax
    cmp byte [bas_bad], 0
    jne .x
    call bas_emit                   ; AL = which variable
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .locdone
    inc word [bas_src]
    jmp .loclp
.locdone:
    ret
.locout:
    mov si, bas_e_locout
    jmp bas_err
.locnoname:
    mov si, bas_e_locname
    jmp bas_err

; --- GOTO <label> (SPEC.md 126.22) ----------------------------------------
.goto:
    call bas_skipsp
    call bas_lblword                ; DI = the name, CX = its length
    jc .gotonolbl
    call bas_lblfind                ; BX = which label, CF=1 if not seen yet
    jc .gotofwd
    call bas_lblat
    mov ax, [si + BAS_LBL_LOOP]
    call bas_loopsame               ; ...and it must be THIS loop
    jc .x
    mov al, OP_JMP
    call bas_emit
    call bas_lblat
    mov ax, [si + BAS_LBL_OPS]
    jmp bas_emitw
.gotofwd:
    ; A LABEL BELOW THIS LINE IS NOT A SPECIAL CASE, it is the normal one:
    ; the placeholder goes in the pending table with everything the refusal
    ; will need, including the line, and the end of the program answers it.
    mov al, OP_JMP
    call bas_emit
    mov bx, [bas_opn]
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .x
    jmp bas_fwdadd                  ; BX = the slot, DI/CX = the name
.gotonolbl:
    mov si, bas_e_gotolbl
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

; --- SELECT <expr> / CASE / DEFAULT / ENDSELECT (SPEC.md 126.21) -----------
; GFA's multi-way branch, and it needs NO NEW OPCODE: the subject is kept in
; a variable no program can name and every test is the comparison ops the
; expression compiler already emits. What it needs instead is a SECOND chain
; beside 126.20's - a CASE may list several values and any of them enters the
; one body, whose address is not known until the last of them is parsed.
.select:
    call bas_c_expr                 ; the subject, evaluated ONCE - a SELECT
    cmp byte [bas_bad], 0           ; over `f(x)` must not call it per arm
    jne .x
    call bas_varhidden              ; ...and kept where FOR keeps its limit
    jc .x
    push ax
    mov al, OP_STORE
    call bas_emit
    pop ax
    cmp byte [bas_bad], 0
    jne .x
    push ax
    call bas_emit                   ; AL = which variable
    pop ax
    cmp byte [bas_bad], 0
    jne .x
    mov [bas_blkv], ax              ; ...and it rides in the entry's V, the
    xor cx, cx                      ; field FOR uses for the same purpose
    xor bx, bx
    mov ax, BK_SELECT
    jmp bas_blkpush

; --- CASE <v>[,<v>...] | CASE <a> TO <b> | CASE TO <b> | CASE <a> TO -------
.case:
    call bas_blkpop                 ; AX = kind, CX = the open arm's no-match
    jc .x                           ; jump, V = the subject, chain in blkex
    cmp ax, BK_DEFAULT
    je .caseaft
    cmp ax, BK_SELECT
    jne .wrongblk
    call bas_armclose               ; CX = the arm above's no-match jump
    cmp byte [bas_bad], 0
    jne .x
    xor ax, ax
    mov [bas_casech], ax            ; no value of this CASE has matched yet
.casealt:
    call bas_skipsp
    call bas_word                   ; CASE TO <b>, an open LOWER end?
    jc .casea
    mov si, bas_kw_to
    call bas_wordis
    je .caseupper
    mov [bas_src], di               ; not TO, so hand it to the expression
.casea:
    call bas_emitsubj
    call bas_c_expr                 ; the value, or the range's lower end
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    call bas_word                   ; ...TO, making it a range?
    jc .caseeq
    mov si, bas_kw_to
    call bas_wordis
    je .caserange
    mov [bas_src], di
.caseeq:
    mov al, OP_EQ
    call bas_emit
    jmp .casematch
.caseupper:
    call bas_emitsubj
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_LE
    call bas_emit
    jmp short .casematch
.caserange:
    ; An upper end that is not there is `CASE <a> TO`, an open UPPER end.
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .caselower
    cmp al, 10
    je .caselower
    cmp al, ','
    je .caselower
    ; <a> TO <b> IS TWO TESTS AND NOT ONE, because there is no AND yet: the
    ; lower end is tested first and a failure skips the upper end's test
    ; rather than this whole CASE - the alternatives after a comma are still
    ; owed their turn.
    mov al, OP_GE
    call bas_emit
    mov al, OP_JF
    call bas_emit
    mov cx, [bas_opn]
    push cx
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .casepop
    call bas_emitsubj
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .casepop
    mov al, OP_LE
    call bas_emit
    cmp byte [bas_bad], 0
    jne .casepop
    mov ax, [bas_casech]
    call bas_casejt
    mov [bas_casech], ax
    pop bx                          ; ...and the lower end's failure lands
    mov ax, [bas_opn]               ; on the next alternative, HERE
    call bas_patch
    jmp short .casemore
.caselower:
    mov al, OP_GE
    call bas_emit
.casematch:
    cmp byte [bas_bad], 0
    jne .x
    mov ax, [bas_casech]            ; a match leaves the tests for the body
    call bas_casejt
    mov [bas_casech], ax
.casemore:
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .casedone
    inc word [bas_src]
    jmp .casealt
.casedone:
    mov al, OP_JMP                  ; nothing matched: on to the next CASE,
    call bas_emit                   ; which is this arm's one PAT slot
    mov cx, [bas_opn]
    push cx
    xor ax, ax
    call bas_emitw
    pop cx
    cmp byte [bas_bad], 0
    jne .x
    push cx
    mov bx, [bas_casech]            ; ...and every match lands HERE, on the
    mov ax, [bas_opn]               ; body, which is only now known
    call bas_blkexits
    pop cx
    xor bx, bx
    mov ax, BK_SELECT
    call bas_blkpush
    jc .x
    mov ax, [bas_blkex]
    jmp bas_blksetex
.casepop:
    pop bx
    ret
.caseaft:
    mov si, bas_e_caseaft
    jmp bas_err

.sdefault:
    call bas_blkpop
    jc .x
    cmp ax, BK_DEFAULT
    je .defagain
    cmp ax, BK_SELECT
    jne .wrongblk
    call bas_armclose
    cmp byte [bas_bad], 0
    jne .x
    xor cx, cx                      ; DEFAULT opens no no-match jump, and
    xor bx, bx                      ; 126.20's zero says so
    mov ax, BK_DEFAULT
    call bas_blkpush
    jc .x
    mov ax, [bas_blkex]
    jmp bas_blksetex
.defagain:
    mov si, bas_e_defagain
    jmp bas_err

.sendsel:
    call bas_blkpop
    jc .x
    cmp ax, BK_SELECT               ; ...and ENDIF cannot close either of
    je .endifok                     ; them, nor ENDSELECT an IF: the tail is
    cmp ax, BK_DEFAULT              ; shared, the kind test is not
    je .endifok
    jmp .wrongblk

.sendif:
    call bas_blkpop
    jc .x
    cmp ax, BK_IF                   ; an IF with no ELSE...
    je .endifok
    cmp ax, BK_ELSE                 ; ...or the ELSE that followed one
    jne .wrongblk
.endifok:
    or cx, cx                       ; the last arm's false-jump, if the last
    jz .endifch                     ; arm was not an ELSE
    mov bx, cx
    mov ax, [bas_opn]
    call bas_patch
.endifch:
    jmp bas_exitshere               ; ...then every arm's finished-jump
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
    cmp al, '@'                     ; ...and @name is a call (SPEC.md 126.23),
    je .atcall                      ; which bas_word cannot have read: '@' is
                                    ; not a character a word may hold
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
    cmp al, '@'                     ; @name(...) is a FUNCTION call here
    je .atfn
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
    mov si, bas_kw_fn               ; FN name(...), GFA's other spelling
    call bas_wordis
    je .fnword
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
.atfn:
    inc word [bas_src]
    call bas_lblword
    jc .bad
    mov al, 1                       ; ...and a value must come back
    jmp bas_callemit
.fnword:
    call bas_skipsp
    call bas_lblword
    jc .bad
    mov al, 1
    jmp bas_callemit
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
;
; This is bas_findloop plus the refusal. GOTO asks the same question and must
; NOT refuse on a no (SPEC.md 126.22: outside every loop is a legal place to
; be), so the search itself is the shared part.
bas_blkinloop:
    call bas_findloop
    jc .inone
    ret
.inone:
    mov si, bas_e_exitloop
    call bas_err
    stc
    ret

; --- bas_loopid - AX = WHERE THIS LINE IS, for GOTO's rule ----------------
; The IDENTITY of a loop, not a depth: two sibling loops nest equally deep
; and a jump from one into the other must still be refused. A loop's own top
; offset is unique across the program, so it IS the identity.
;
; **AND A PROCEDURE COUNTS TOO** (SPEC.md 126.23): GFA forbids a GOTO between
; a procedure and the main program as firmly as one out of a FOR, and both
; sit at no loop at all. Outside a loop the answer is therefore the
; procedure's own number with the top bit set - an op offset cannot reach
; 0x8000 (BAS_OPS_MAX is far below it), so the two kinds of answer cannot
; collide, and the main program's 0 is distinct from both.
bas_loopid:
    push bx
    push si
    call bas_findloop
    jc .lnone
    call bas_blkat
    mov ax, [si + BAS_BLK_TOP]
    pop si
    pop bx
    ret
.lnone:
    mov ax, [bas_inprc]
    or ax, ax
    jz .lout                        ; the main program, outside every loop
    or ax, 0x8000
.lout:
    pop si
    pop bx
    ret

; --- bas_loopsame - refuse unless AX is the loop this line is in ----------
; out: CF=1 and refused by name if it is not
bas_loopsame:
    push ax
    push bx
    push cx
    mov cx, ax
    call bas_loopid
    cmp ax, cx
    jne .lsno
    clc
.lsout:
    pop cx
    pop bx
    pop ax
    ret
.lsno:
    mov si, bas_e_lblloop
    call bas_err
    stc
    jmp .lsout

bas_findloop:
    push ax
    push si
    mov bx, [bas_nblk]
.ilp:
    or bx, bx
    jz .ifnone
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
.ifnone:
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

; -----------------------------------------------------------------------------
; Labels and GOTO (SPEC.md 126.22)
; -----------------------------------------------------------------------------

; --- bas_lblat / bas_fwdat - SI = entry BX of each table ------------------
; BAS_LBL_SZ is 8, so three shifts; BAS_FWD_SZ is 10, which is i*8 + i*2 -
; and NEITHER uses `mul`, for bas_varat's reason: the callers hold their scan
; bound in DX and `mul` writes DX:AX.
bas_lblat:
    push ax
    mov ax, bx
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, bas_lbls
    mov si, ax
    pop ax
    ret
    times BAS_LBL_SZ - 8 db 0
    times 8 - BAS_LBL_SZ db 0

bas_fwdat:
    push ax
    push cx
    mov ax, bx
    shl ax, 1
    mov cx, ax                      ; i*2
    shl ax, 1
    shl ax, 1                       ; i*8
    add ax, cx
    add ax, bas_fwds
    mov si, ax
    pop cx
    pop ax
    ret
    times BAS_FWD_SZ - 10 db 0
    times 10 - BAS_FWD_SZ db 0

; --- bas_lblchar - is AL legal in a label name? ---------------------------
; Letters, digits, '_' and '.', and a label MAY BEGIN WITH A DIGIT (GFA's
; entry 249), which is why this is not bas_word's test.
; out: CF=0 if it is
bas_lblchar:
    cmp al, '_'
    je .yes
    cmp al, '.'
    je .yes
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .yes
    cmp al, 'A'
    jb .no
    cmp al, 'Z'
    jbe .yes
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    jbe .yes
.no:
    stc
    ret
.yes:
    clc
    ret

; --- bas_lblword - scan a label NAME at the cursor ------------------------
; out: DI = where it starts, CX = how long, CF=1 if there is none at all.
;      The cursor is left after the name.
bas_lblword:
    push ax
    push si
    mov di, [bas_src]
    mov si, di
    xor cx, cx
.lwl:
    mov al, [si]
    call bas_lblchar
    jc .lwend
    inc si
    inc cx
    jmp .lwl
.lwend:
    or cx, cx
    jz .lwno
    mov [bas_src], si
    clc
    pop si
    pop ax
    ret
.lwno:
    stc
    pop si
    pop ax
    ret

; --- bas_lblmaybe - a label DEFINITION at the cursor? ---------------------
; out: DI/CX = the name and CF=0 with the cursor past the colon, or CF=1 with
;      the cursor exactly where it was.
;
; THE COLON IS WHAT IDENTIFIES IT, not the name: a label may be spelled like
; a keyword or begin with a digit, so nothing about the word itself can
; decide this. The restore is the whole reason this is a separate proc.
bas_lblmaybe:
    push ax
    push si
    mov ax, [bas_src]
    push ax
    call bas_lblword
    jc .lmno
    mov si, [bas_src]
    cmp byte [si], ':'
    jne .lmno
    inc word [bas_src]
    pop ax
    clc
    pop si
    pop ax
    ret
.lmno:
    pop ax
    mov [bas_src], ax
    stc
    pop si
    pop ax
    ret

; --- bas_lblfind - BX = the label named by DI/CX; CF=1 if there is none ---
bas_lblfind:
    push ax
    push cx
    push dx
    push si
    push di
    xor bx, bx
    mov dx, [bas_nlbl]
.scan:
    cmp bx, dx
    jae .miss
    push bx
    push cx
    push di
    call bas_lblat
    cmp cx, [si + BAS_LBL_LEN]
    jne .nextpop
    mov si, [si + BAS_LBL_SRC]
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
    clc
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret
.miss:
    stc
    jmp .out

; --- bas_lbldef - define the label DI/CX here ----------------------------
bas_lbldef:
    push ax
    push bx
    push si
    call bas_lblfind                ; ...and only once: the second one would
    jnc .dup                        ; silently take every jump
    mov bx, [bas_nlbl]
    cmp bx, BAS_LBL_MAX
    jae .lfull
    call bas_lblat
    mov [si + BAS_LBL_SRC], di
    mov [si + BAS_LBL_LEN], cx
    mov ax, [bas_opn]
    mov [si + BAS_LBL_OPS], ax
    push si
    call bas_loopid
    pop si
    mov [si + BAS_LBL_LOOP], ax
    inc word [bas_nlbl]
.dout:
    pop si
    pop bx
    pop ax
    ret
.lfull:
    mov si, bas_e_lblmax
    call bas_err
    jmp .dout
.dup:
    mov si, bas_e_lbldup
    call bas_err
    jmp .dout

; --- bas_fwdadd - a GOTO at slot BX still owed the label DI/CX -----------
bas_fwdadd:
    push ax
    push bx
    push si
    mov ax, bx                      ; the slot, while BX indexes
    mov bx, [bas_nfwd]
    cmp bx, BAS_FWD_MAX
    jae .ffull
    call bas_fwdat
    mov [si + BAS_FWD_SLOT], ax
    mov [si + BAS_FWD_SRC], di
    mov [si + BAS_FWD_LEN], cx
    mov ax, [bas_line]              ; ...so the refusal names THIS line and
    mov [si + BAS_FWD_LINE], ax     ; not the program's last one
    push si
    call bas_loopid
    pop si
    mov [si + BAS_FWD_LOOP], ax
    inc word [bas_nfwd]
.fout:
    pop si
    pop bx
    pop ax
    ret
.ffull:
    mov si, bas_e_fwdmax
    call bas_err
    jmp .fout

; --- bas_fwdfix - resolve every GOTO still owed a label ------------------
; Called where the program's TEXT ends, beside the unclosed-block refusal:
; both are questions that only the end of the program can answer.
;
; THE LOOP CHECK IS THE SAME ONE A BACKWARD GOTO TAKES, but it cannot go
; through bas_loopsame - no block is open any more by the time this runs, so
; "this line's loop" is gone and the pending entry's own record is the only
; copy left. That is what BAS_FWD_LOOP is for.
bas_fwdfix:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor dx, dx
.flp:
    cmp dx, [bas_nfwd]
    jae .fdone
    mov bx, dx
    call bas_fwdat
    mov ax, [si + BAS_FWD_LINE]
    mov [bas_line], ax              ; the refusals below name the GOTO's line
    mov di, [si + BAS_FWD_SRC]
    mov cx, [si + BAS_FWD_LEN]
    mov ax, [si + BAS_FWD_LOOP]
    push ax
    call bas_lblfind                ; BX = the label
    pop ax
    jc .nolbl
    push ax
    call bas_lblat
    mov cx, [si + BAS_LBL_LOOP]
    mov bx, [si + BAS_LBL_OPS]
    pop ax
    cmp ax, cx
    jne .wrongloop
    mov ax, bx                      ; AX = where the label is...
    mov bx, dx
    call bas_fwdat
    mov bx, [si + BAS_FWD_SLOT]     ; ...and BX = the placeholder
    call bas_patch
    inc dx
    jmp .flp
.fdone:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
.nolbl:
    mov si, bas_e_nolbl
    call bas_err
    jmp .fdone
.wrongloop:
    mov si, bas_e_lblloop
    call bas_err
    jmp .fdone

; -----------------------------------------------------------------------------
; Procedures, compile side (SPEC.md 126.23)
; -----------------------------------------------------------------------------
bas_prcat:
    push ax
    push cx
    mov ax, bx
    shl ax, 1
    mov cx, ax                      ; i*2
    shl ax, 1
    shl ax, 1                       ; i*8
    add ax, cx                      ; ...+ i*2 = i*10
    add ax, bas_prcs
    mov si, ax
    pop cx
    pop ax
    ret
    times BAS_PRC_SZ - 10 db 0
    times 10 - BAS_PRC_SZ db 0

bas_calat:
    push ax
    push cx
    mov ax, bx
    shl ax, 1
    shl ax, 1
    mov cx, ax                      ; i*4
    shl ax, 1                       ; i*8
    add ax, cx                      ; ...+ i*4 = i*12
    add ax, bas_cals
    mov si, ax
    pop cx
    pop ax
    ret
    times BAS_CAL_SZ - 12 db 0      ; THE SHIFTS ARE THE RECORD'S SIZE and
    times 12 - BAS_CAL_SZ db 0      ; nothing else ties them to it: widening
                                    ; BAS_CAL_SZ to 10 for the value count
                                    ; and leaving three shifts here put entry
                                    ; 1's first word on entry 0's last, so
                                    ; `GOSUB hello` was refused for handing
                                    ; over the wrong number of values. Every
                                    ; indexer below carries the same pair now

; --- bas_prcfind - BX = the procedure named by DI/CX; CF=1 if none --------
; bas_lblfind's body one table along. The two are not merged because the
; tables hold different things and the loop is nine instructions.
bas_prcfind:
    push ax
    push cx
    push dx
    push si
    push di
    xor bx, bx
    mov dx, [bas_nprc]
.scan:
    cmp bx, dx
    jae .miss
    push bx
    push cx
    push di
    call bas_prcat
    cmp cx, [si + BAS_PRC_LEN]
    jne .nextpop
    mov si, [si + BAS_PRC_SRC]
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
    clc
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret
.miss:
    stc
    jmp .out

; --- bas_prcdef - the procedure DI/CX begins here -------------------------
bas_prcdef:
    push ax
    push bx
    push si
    call bas_prcfind
    jnc .dup
    mov bx, [bas_nprc]
    cmp bx, BAS_PRC_MAX
    jae .pfull
    call bas_prcat
    mov [si + BAS_PRC_SRC], di
    mov [si + BAS_PRC_LEN], cx
    mov ax, [bas_opn]
    mov [si + BAS_PRC_OPS], ax
    inc word [bas_nprc]
    mov ax, [bas_nprc]              ; ...and 1-based, so 0 can mean "none"
    mov [bas_inprc], ax
.dout:
    pop si
    pop bx
    pop ax
    ret
.pfull:
    mov si, bas_e_prcmax
    call bas_err
    jmp .dout
.dup:
    mov si, bas_e_prcdup
    call bas_err
    jmp .dout

; --- bas_prckind - the procedure being compiled returns a value if DX -----
bas_prckind:
    push bx
    push si
    mov bx, [bas_inprc]
    dec bx
    call bas_prcat
    mov [si + BAS_PRC_FN], dx
    pop si
    pop bx
    ret

; --- bas_isfn - AX = 1 if the procedure being compiled is a FUNCTION -----
bas_isfn:
    push bx
    push si
    mov bx, [bas_inprc]
    dec bx
    call bas_prcat
    mov ax, [si + BAS_PRC_FN]
    pop si
    pop bx
    ret

; --- bas_emitzero - PUSHN 0.0 -------------------------------------------
bas_emitzero:
    push ax
    push di
    mov al, OP_PUSHN
    call bas_emit
    cmp byte [bas_bad], 0
    jne .zout
    xor ax, ax
    call fp_i2a
    mov di, bas_ops
    add di, [bas_opn]
    call fp_pack_a
    add word [bas_opn], 8
    cmp word [bas_opn], BAS_OPS_MAX - 10
    jb .zout
    mov si, bas_e_long
    call bas_err
.zout:
    pop di
    pop ax
    ret

; --- bas_callemit - emit a call to the procedure named by DI/CX ----------
; in:  AL = 1 if the call site wants a VALUE back (SPEC.md 126.25)
; A name not yet seen is the NORMAL case, so this looks exactly like GOTO's
; forward reference and shares its shape (SPEC.md 126.23).
bas_callemit:
    push ax
    push bx
    push dx
    push si
    mov [bas_calfn], al             ; ...which kind this site can accept
    ; **THE VALUES ARE EMITTED FIRST**, before the OP_CALL, so they are on
    ; the stack when the callee's backwards prologue stores them
    ; (SPEC.md 126.24). bas_callargs preserves the NAME in DI/CX.
    call bas_callargs               ; DX = how many
    cmp byte [bas_bad], 0
    jne .cout
    mov al, OP_CALL
    call bas_emit
    cmp byte [bas_bad], 0
    jne .cout
    call bas_prcfind
    jc .fwd
    push bx
    call bas_prcat
    cmp dx, [si + BAS_PRC_NP]       ; ...and it must want that many
    jne .cwrongn
    mov ax, [si + BAS_PRC_FN]       ; ...and be the kind this site can use
    cmp al, [bas_calfn]
    jne .cwrongk
    mov ax, [si + BAS_PRC_OPS]
    pop bx
    call bas_emitw
    jmp .cout
.cwrongn:
    pop bx
    mov si, bas_e_argcount
    call bas_err
    jmp .cout
.cwrongk:
    pop bx
    call bas_kinderr
    jmp .cout
.fwd:
    mov bx, [bas_opn]
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .cout
    mov ax, bx                      ; the slot, while BX indexes the table
    mov bx, [bas_ncal]
    cmp bx, BAS_CAL_MAX
    jae .cfull
    call bas_calat
    mov [si + BAS_CAL_SLOT], ax
    mov [si + BAS_CAL_SRC], di
    mov [si + BAS_CAL_LEN], cx
    mov [si + BAS_CAL_NARG], dx     ; ...checked where the name is resolved
    mov al, [bas_calfn]
    xor ah, ah
    mov [si + BAS_CAL_FN], ax       ; ...and so is the kind
    mov ax, [bas_line]
    mov [si + BAS_CAL_LINE], ax
    inc word [bas_ncal]
.cout:
    pop si
    pop dx
    pop bx
    pop ax
    ret
.cfull:
    mov si, bas_e_calmax
    call bas_err
    jmp .cout

; --- bas_prcparams - the PROCEDURE's parameter list and its prologue ------
; (SPEC.md 126.24) A parameter is a LOCAL that arrives with a value in it,
; so the prologue is one OP_LOCAL and one OP_STORE each and needs no new
; mechanism. It runs BACKWARDS: the caller pushes left to right, so the last
; parameter is on top of the value stack - which is why the whole list is
; collected before any of it is emitted.
bas_prcparams:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor dx, dx                      ; DX = how many
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '('
    jne .pdone
    inc word [bas_src]
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'              ; PROCEDURE p() takes none
    je .pclose
.plp:
    call bas_skipsp
    call bas_word
    jc .pnoname
    call bas_varfind                ; AX = its index, created if new
    jc .pout
    cmp dx, BAS_PRC_PMAX
    jae .ptoomany
    xor bx, bx                      ; ...and not a name twice: the second
.pdup:                              ; OP_LOCAL would save the first's own
    cmp bx, dx                      ; already zeroed value
    jae .pkeep
    cmp al, [bas_prcp + bx]
    je .pdupname
    inc bx
    jmp .pdup
.pkeep:
    mov bx, dx
    mov [bas_prcp + bx], al
    inc dx
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .pclose
    inc word [bas_src]
    jmp .plp
.pclose:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'
    jne .pnopar
    inc word [bas_src]
.pdone:
    ; the count goes in the table, for a call to be checked against
    mov bx, [bas_inprc]
    dec bx                          ; 1-based while it is live
    call bas_prcat
    mov [si + BAS_PRC_NP], dx
    ; ...and now the prologue, last parameter first
    mov bx, dx
.elp:
    or bx, bx
    jz .pout
    dec bx
    push bx
    mov al, OP_LOCAL
    call bas_emit
    pop bx
    cmp byte [bas_bad], 0
    jne .pout
    push bx
    mov al, [bas_prcp + bx]
    call bas_emit
    mov al, OP_STORE
    call bas_emit
    pop bx
    cmp byte [bas_bad], 0
    jne .pout
    push bx
    mov al, [bas_prcp + bx]
    call bas_emit
    pop bx
    cmp byte [bas_bad], 0
    jne .pout
    jmp .elp
.pout:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
.pnoname:
    mov si, bas_e_locname
    call bas_err
    jmp .pout
.ptoomany:
    mov si, bas_e_prcargs
    call bas_err
    jmp .pout
.pdupname:
    mov si, bas_e_prcpdup
    call bas_err
    jmp .pout
.pnopar:
    mov si, bas_e_argpar
    call bas_err
    jmp .pout

; --- bas_callargs - a call's (a, b) list; out: DX = how many -------------
; Each one is compiled where it stands, so the values are on the stack left
; to right and the callee's backwards prologue finds them in order.
bas_callargs:
    push ax
    push bx
    push cx
    push si
    push di
    xor dx, dx
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '('
    jne .adone
    inc word [bas_src]
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'
    je .aclose
.alp:
    cmp dx, BAS_PRC_PMAX
    jae .atoomany
    push dx
    call bas_c_rel                  ; the value
    pop dx
    cmp byte [bas_bad], 0
    jne .aout
    inc dx
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .aclose
    inc word [bas_src]
    jmp .alp
.aclose:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'
    jne .anopar
    inc word [bas_src]
.adone:
    clc
.aout:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret
.atoomany:
    mov si, bas_e_prcargs
    call bas_err
    jmp .aout
.anopar:
    mov si, bas_e_argpar
    call bas_err
    jmp .aout

; --- bas_kinderr - refuse a call whose kind is wrong --------------------
; in:  [bas_calfn] = what the site wanted. The two sentences are different
;      facts and a program is helped by which one it is.
;
; **IT RETURNS, so it is CALLED.** bas_err ends in a `ret`, so `jmp bas_err`
; from inside a proc returns to that proc's own CALLER - which is right for
; a statement body with nothing pushed, and wrong for one holding six
; registers. Both of this routine's callers hold some: reached by `jmp`, the
; refusal printed correctly and then returned into the caller's saved
; registers, which left the whole package wedged - the NEXT program typed
; after it never ran, and the row read the previous one's console.
bas_kinderr:
    cmp byte [bas_calfn], 0
    je .wantsnone
    mov si, bas_e_wantfn            ; an expression, and it returns nothing
    jmp bas_err
.wantsnone:
    mov si, bas_e_wantprc           ; a statement, and its value is stranded
    jmp bas_err

; --- bas_calfix - resolve every call still owed a procedure --------------
; Beside bas_fwdfix, where the program's text ends, for its reason.
bas_calfix:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor dx, dx
.flp:
    cmp dx, [bas_ncal]
    jae .fdone
    mov bx, dx
    call bas_calat
    mov ax, [si + BAS_CAL_LINE]
    mov [bas_line], ax
    mov di, [si + BAS_CAL_SRC]
    mov cx, [si + BAS_CAL_LEN]
    mov bx, [si + BAS_CAL_NARG]     ; what the call hands over...
    push bx
    mov bx, [si + BAS_CAL_FN]
    push bx
    call bas_prcfind
    jc .noprcpop2
    call bas_prcat
    mov ax, [si + BAS_PRC_OPS]
    pop bx
    cmp bx, [si + BAS_PRC_FN]       ; ...the kind the site can use...
    jne .nkindpop
    pop bx
    cmp bx, [si + BAS_PRC_NP]       ; ...and what it takes
    jne .nargs
    mov bx, dx
    push ax
    call bas_calat
    mov bx, [si + BAS_CAL_SLOT]
    pop ax
    call bas_patch
    inc dx
    jmp .flp
.fdone:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
.nkindpop:
    pop bx                          ; drop the value count
    mov bx, dx                      ; ...and read the CALL's kind back: SI is
    call bas_calat                  ; the PROCEDURE's entry by now
    mov al, [si + BAS_CAL_FN]
    mov [bas_calfn], al
    call bas_kinderr
    jmp .fdone
.noprcpop2:
    pop bx
.noprcpop:
    pop bx
.noprc:
    mov si, bas_e_noprc
    call bas_err
    jmp .fdone
.nargs:
    mov si, bas_e_argcount
    call bas_err
    jmp .fdone

; --- bas_frmat - SI = frame BX --------------------------------------------
bas_frmat:
    push ax
    mov ax, bx
    shl ax, 1
    shl ax, 1
    add ax, bas_frms
    mov si, ax
    pop ax
    ret
    times BAS_FRM_SZ - 4 db 0
    times 4 - BAS_FRM_SZ db 0

; --- bas_savat - DI = save record CX -------------------------------------
; i*10 as ((i*4)+i)*2, which needs the index still in CX - it is, both
; callers holding the count there.
bas_savat:
    push ax
    mov ax, cx
    shl ax, 1
    shl ax, 1
    add ax, cx                      ; i*5
    shl ax, 1                       ; ...*2
    add ax, bas_savs
    mov di, ax
    pop ax
    ret
    times BAS_SAV_SZ - 10 db 0
    times 10 - BAS_SAV_SZ db 0

; --- bas_dosave - BX = a variable: push it on the save stack and zero it --
; A LOCAL is exactly this (SPEC.md 126.23): the old value goes where RETURN
; will find it, and the new one is 0 - which GFA's manual notes its own
; original neglected to state.
bas_dosave:
    push ax
    push bx
    push cx
    push si
    push di
    mov cx, [bas_nsav]
    cmp cx, BAS_SAV_MAX
    jae .sfull
    call bas_varat                  ; SI = the variable
    add si, BAS_VAR_VAL
    call bas_savat                  ; DI = the save record
    mov [di + BAS_SAV_IDX], bx
    xor bx, bx                      ; ...and BX is the byte counter now: it
.cp:                                ; is the only index register an 8086 can
    mov ax, [si + bx]               ; add to SI or DI, which is why vload and
    mov [di + BAS_SAV_VAL + bx], ax ; vstore count in it too
    mov word [si + bx], 0           ; ...and born 0
    add bx, 2
    cmp bx, BAS_SLOT
    jb .cp
    inc word [bas_nsav]
.sout:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret
.sfull:
    mov si, bas_e_savmax
    call bas_err
    jmp .sout

; --- bas_unsave - put every saved variable above the mark CX back ---------
bas_unsave:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov dx, cx
.ulp:
    mov cx, [bas_nsav]
    cmp cx, dx
    jbe .udone
    dec cx
    mov [bas_nsav], cx
    call bas_savat                  ; DI = the record
    mov bx, [di + BAS_SAV_IDX]
    call bas_varat                  ; SI = the variable it belongs to
    add si, BAS_VAR_VAL
    xor bx, bx
.cp:
    mov ax, [di + BAS_SAV_VAL + bx]
    mov [si + bx], ax
    add bx, 2
    cmp bx, BAS_SLOT
    jb .cp
    jmp .ulp
.udone:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- bas_donejmp - a JMP onto the end of the construct, chained -----------
; in:  AX = the chain's head so far, 0 if this is the first
; out: AX = the new head, which is the placeholder this call just emitted
;
; The old head rides IN the placeholder, so the pending jumps are a list in
; the op stream and no table pays for them.
bas_donejmp:
    push cx
    mov cl, OP_JMP
    call bas_chainj
    pop cx
    ret

; --- bas_casejt - the same, as a jump-if-TRUE -----------------------------
; A CASE's matched-jumps are a chain for 126.20's reason one construct along:
; several of them, one destination, and the destination not known yet.
bas_casejt:
    push cx
    mov cl, OP_JT
    call bas_chainj
    pop cx
    ret

; in:  CL = the opcode, AX = the chain's head so far
; out: AX = the new head
bas_chainj:
    push bx
    push dx
    mov dx, ax                      ; the old head, out of AL's way
    mov al, cl
    call bas_emit
    mov bx, [bas_opn]
    mov ax, dx
    call bas_emitw
    mov ax, bx
    pop dx
    pop bx
    ret

; --- bas_armclose - finish the arm above a CASE or DEFAULT ----------------
; in:  CX = the arm above's pending no-match jump, 0 if there is no arm
;      above at all (the first CASE of a SELECT, whose tests the subject's
;      store falls straight into)
; out: [bas_blkex] extended by this arm's finished-jump
bas_armclose:
    push ax
    push bx
    push cx
    or cx, cx
    jz .acout
    mov ax, [bas_blkex]
    call bas_donejmp                ; the arm above is finished: to ENDSELECT
    mov [bas_blkex], ax
    cmp byte [bas_bad], 0
    jne .acout
    pop bx                          ; ...and its no-match jump lands HERE,
    push bx                         ; on the first of this arm's tests
    mov ax, [bas_opn]
    call bas_patch
.acout:
    pop cx
    pop bx
    pop ax
    ret

; --- bas_emitsubj - push the SELECT subject, whichever variable it is -----
bas_emitsubj:
    push ax
    mov al, OP_LOAD
    call bas_emit
    mov ax, [bas_blkv]
    call bas_emit
    pop ax
    ret

; --- bas_blksetex - the top block's chain head is AX ----------------------
; bas_blkpush zeroes the field deliberately, so that a caller who has never
; heard of the chain cannot inherit one; a caller who HAS writes it here,
; right after pushing.
bas_blksetex:
    push bx
    push si
    mov bx, [bas_nblk]
    or bx, bx
    jz .sxout
    dec bx
    call bas_blkat
    mov [si + BAS_BLK_EXIT], ax
.sxout:
    pop si
    pop bx
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

; --- OP_CALL / OP_RET / OP_LOCAL (SPEC.md 126.23) --------------------------
; A FRAME IS TWO WORDS: where to come back to, and where this frame's share
; of the one save stack begins. Recursion is then free - it is what a stack
; of frames already is - and RETURN is a run of pops down to the mark.
.callop:
    push bx
    mov bx, [bas_nfrm]
    cmp bx, BAS_FRM_MAX
    jae .toodeep
    push si
    call bas_frmat                  ; SI = the frame
    mov ax, [bas_nsav]
    mov [si + BAS_FRM_SAVE], ax
    pop ax                          ; the op cursor, as it was
    push ax
    add ax, 2                       ; ...the word operand is consumed too
    sub ax, bas_ops
    mov [si + BAS_FRM_RET], ax
    inc word [bas_nfrm]
    pop si
    pop bx
    mov si, [si]                    ; and in we go
    add si, bas_ops
    jmp .next
.toodeep:
    pop bx
    mov si, bas_e_deepcall
    jmp bas_err                     ; ...and it names the line, OP_LINE
                                    ; having kept [bas_line] current

.retop:
    push bx
    mov bx, [bas_nfrm]
    or bx, bx
    jz .retnone                     ; nothing emits this outside a procedure
    dec bx
    mov [bas_nfrm], bx
    push si
    call bas_frmat
    mov ax, [si + BAS_FRM_RET]
    mov cx, [si + BAS_FRM_SAVE]
    pop si
    mov si, ax
    add si, bas_ops
    push si
    call bas_unsave                 ; CX = the mark: put the locals back
    pop si
    pop bx
    jmp .next
.retnone:
    pop bx
    jmp .done

.localop:
    push bx
    mov bl, [si]                    ; which variable...
    inc si
    xor bh, bh
    push si
    call bas_dosave                 ; ...onto the save stack, and zeroed
    pop si
    pop bx
    cmp byte [bas_bad], 0
    jne .done
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
    dw bas_exec.callop              ; OP_CALL
    dw bas_exec.retop               ; OP_RET
    dw bas_exec.localop             ; OP_LOCAL
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
; PLAIN DIGITS, no sign space and no separator. It had QuickBASIC's number
; padding, copied from bas_sayfp above - and its ONLY caller is the refusal
; line, where that padding reads as `Error at line  3 : ...`. PRINT's spacing
; belongs to PRINT and bas_sayfp does it for itself; a future caller that
; wants ` 42 ` can say so in two more con_says.
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
    or cx, cx
    jns .go
    dec si
    mov byte [si], '-'
.go:
    call con_say
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
bas_kw_elseif:  db 'ELSEIF', 0
bas_kw_select:  db 'SELECT', 0
bas_kw_switch:  db 'SWITCH', 0
bas_kw_case:    db 'CASE', 0
bas_kw_dflt:    db 'DEFAULT', 0
bas_kw_othw:    db 'OTHERWISE', 0
bas_kw_endsel:  db 'ENDSELECT', 0
bas_kw_endsw:   db 'ENDSWITCH', 0
bas_kw_goto:    db 'GOTO', 0
bas_kw_gosub:   db 'GOSUB', 0
bas_kw_proc:    db 'PROCEDURE', 0
bas_kw_sub:     db 'SUB', 0
bas_kw_return:  db 'RETURN', 0
bas_kw_endproc: db 'ENDPROC', 0
bas_kw_endsub:  db 'ENDSUB', 0
bas_kw_local:   db 'LOCAL', 0
bas_kw_func:    db 'FUNCTION', 0
bas_kw_endfunc: db 'ENDFUNC', 0
bas_kw_fn:      db 'FN', 0

bas_s_crlf:     db 13, 10, 0
bas_s_sp:       db ' ', 0
bas_s_minus:    db '-', 0
bas_s_bar:      db '| ', 0
bas_s_errat:    db 'Error at line ', 0
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
bas_e_elifelse: db 'ELSEIF cannot come after ELSE', 0
bas_e_caseaft:  db 'CASE cannot come after DEFAULT', 0
bas_e_defagain: db 'this SELECT already has a DEFAULT', 0
bas_e_lblmax:   db 'too many labels - this wave holds 16', 0
bas_e_fwdmax:   db 'too many GOTOs waiting for their labels - eight', 0
bas_e_lbldup:   db 'that label is already defined', 0
bas_e_nolbl:    db 'GOTO names a label the program does not have', 0
bas_e_lblloop:  db 'GOTO cannot jump into or out of a loop', 0
bas_e_gotolbl:  db 'GOTO wants a label', 0
bas_e_prcmax:   db 'too many procedures - this wave holds eight', 0
bas_e_calmax:   db 'too many calls waiting for their procedures - sixteen', 0
bas_e_prcdup:   db 'that procedure is already defined', 0
bas_e_noprc:    db 'that names a procedure the program does not have', 0
bas_e_prcname:  db 'PROCEDURE wants a name', 0
bas_e_prcin:    db 'a procedure cannot be declared inside another', 0
bas_e_retout:   db 'RETURN is not inside a procedure', 0
bas_e_gosname:  db 'GOSUB wants a procedure name', 0
bas_e_locout:   db 'LOCAL is not inside a procedure', 0
bas_e_locname:  db 'LOCAL wants a variable name', 0
bas_e_deepcall: db 'procedures called more than 32 deep', 0
bas_e_savmax:   db 'more than 64 locals held at once', 0
bas_e_prcargs:  db 'a procedure takes at most four values here', 0
bas_e_prcpdup:  db 'that parameter name is used twice', 0
bas_e_argpar:   db 'a list of values wants )', 0
bas_e_argcount: db 'that call hands over the wrong number of values', 0
bas_e_fnval:    db 'RETURN inside a FUNCTION wants a value', 0
bas_e_prcval:   db 'RETURN inside a PROCEDURE takes no value', 0
bas_e_wantfn:   db 'that is a PROCEDURE and returns no value', 0
bas_e_wantprc:  db 'that is a FUNCTION - its value has nowhere to go', 0
bas_e_wide:     db "'\' truncates to an INTEGER and this is outside it", 0
