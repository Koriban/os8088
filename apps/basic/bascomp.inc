; os8088 - apps/basic/bascomp.inc - BASIC/8088's COMPILE-TIME half
; SPEC.md 150.39. Included by baslang.inc (resident) or by the overlay.
; DO NOT add a runtime routine here: the closure in 150.39 is what keeps
; the vector count at ten, and a routine bas_exec calls breaks it.

; --- THE MODULE'S ONE ENTRY, AT OFFSET 0 (SPEC.md 150.39) -------------------
; First in the file, so first in `.modc`, so offset 0 of the part - which is
; the offset bas_v_run carries as a constant.
;
; THERE IS NO DISPATCHER AND NO VERB INDEX, and that is what makes 150.39's
; FIRST TRAP unreachable here rather than guarded against. That trap is a
; dispatcher staging the verb number in a register a verb reads as an
; argument: SHEET's ch_modc staged it in SI, verb 0's index was 0 and its SI
; was 0, so that verb went on working and charts drew axes with no data. One
; entry needs no index, so there is no register to stage it in. A SECOND verb
; added here brings the trap with it, and its index goes in BP.
;
; `call` THEN `retf`, not a `retf` bolted onto bas_run: bas_run is reached by
; a near call in the resident build and must stay a near proc in both, and a
; body whose ending depends on the build is the kind of difference the
; one-source rule exists to prevent.
%ifdef BAS_OVERLAY
bas_modrun:
    call bas_run
    retf
%endif

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
    mov word [bas_susp], 0          ; ...and a program already waiting at an
                                    ; ON MENU is ABANDONED (SPEC.md 150.36):
                                    ; F5 while one is suspended starts over,
                                    ; and a stale wake then finds nothing to
                                    ; do, which bas_onwake is built for
    mov word [bas_src], bas_prog    ; the scanner's cursor
    mov word [bas_line], 1
    mov word [bas_opn], 0
    mov word [bas_nblk], 0          ; ...and no block is open yet
    mov word [bas_narr], 0          ; ...no array DIMmed (SPEC.md 150.31),
    mov word [bas_abase], 0         ; for the reason the variables go: an
    mov word [bas_adimd], 0         ; entry keys on where its name is in a
                                    ; text the next RUN will have replaced,
                                    ; and a second DIM of one name is
                                    ; refused - so a program run twice
                                    ; refused itself the second time
    mov word [bas_svtop], 0         ; ...and no text held (SPEC.md 150.28)
    mov word [bas_sttop], BAS_STR_MAX
    mov word [bas_nlbl], 0          ; ...nor any label seen, for the reason
    mov word [bas_nprc], 0          ; the variables go below: an entry keys on
    mov word [bas_ncal], 0
    mov word [bas_inprc], 0
    mov word [bas_nfrm], 0          ; ...and no call is in progress
    mov word [bas_nsav], 0
    xor bx, bx                      ; ...and every variable is itself
.alid:
    mov [bas_alias + bx], bl
    inc bx
    cmp bx, BAS_VAR_MAX
    jb .alid
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
    ; 30. OP_LINE puts it back: three bytes a statement, and SPEC.md 150.7's
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
    cmp byte [bas_bad], 0           ; label (SPEC.md 150.22)
    jne .done
    call bas_calfix                 ; ...and every call its procedure
    cmp byte [bas_bad], 0
    jne .done
    mov al, OP_END
    call bas_emit
    ; ...AND THAT IS WHERE THE COMPILER STOPS. bas_exec used to be called
    ; from here; it is the RESIDENT half's now (SPEC.md 150.39). Two
    ; reasons, and the second is the one that matters: it takes bas_exec
    ; off the module's vector list - leaving nine callees that cannot move
    ; the heap, which is what makes the plain far call safe without a
    ; return-rebuilding thunk - and it means the module is not even LOADED
    ; while the program runs, which is what an on-demand module is for.
    ;
    ; THE `jmp` IS NOT DECORATION AND CUTTING THE CALL ALMOST LOST IT. The
    ; lines removed were `jne .done / call bas_exec / jmp short .done`, and
    ; the jump is what steps OVER .unclosed. Without it every program fell
    ; into "nothing may still be open" after a clean compile - all four soak
    ; rows red, and the FAST TIER GREEN at 88 of 88, because no fast row
    ; compiles a program. SPEC.md 150.39 says that in as many words.
    jmp short .done
.unclosed:
    mov si, bas_e_open
    SHOUTR bas_err
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
    ; anything at all - it may even begin with a digit (SPEC.md 150.22) -
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
    mov si, bas_kw_void             ; VOID <expr>, and `~<expr>` below: GFA
    call bas_wordis                 ; has both and they differ there only in
    je .void                        ; arithmetic (SPEC.md 150.27)
    mov si, bas_kw_dim
    call bas_wordis
    je .dim
    mov si, bas_kw_option
    call bas_wordis
    je .option
    mov si, bas_kw_clr              ; CLR, ARRAYFILL and SWAP: node [94]'s
    call bas_wordis                 ; and [73]'s and [95]'s, which divide the
    je .clr                         ; job between them (SPEC.md 150.33)
    mov si, bas_kw_afill
    call bas_wordis
    je .afill
    mov si, bas_kw_swap
    call bas_wordis
    je .swap
    mov si, bas_kw_mouse            ; node [210]: ONE poll into THREE avars,
    call bas_wordis                 ; which is why it is not three reads
    je .mousest
    mov si, bas_kw_mid              ; node [156]: the ONLY function name that
    call bas_wordis                 ; may stand left of an '=' (150.50)
    je .midst
    mov si, bas_kw_lset             ; node [164], and its one sentence: "the
    call bas_wordis                 ; actual content of a$ is irrelevant:
    je .lset                        ; only its length is significant"
    mov si, bas_kw_rset
    call bas_wordis
    je .rset
    mov si, bas_kw_erase            ; node [94]'s third, REFUSED by name and
    call bas_wordis                 ; with the reason (SPEC.md 150.33)
    je .erase
    mov si, bas_kw_on               ; ON MENU - the yield, in plain sight in
    call bas_wordis                 ; the program text (SPEC.md 150.36)
    je .onstmt
    mov si, bas_kw_alert            ; node [309], and the first statement to
    call bas_wordis                 ; carry a value back (SPEC.md 150.37)
    je .alert
    mov si, bas_kw_menu             ; MENU m$() - node [299], and a statement
    call bas_wordis                 ; the keyword table misses (150.38)
    je .menu
    ; --- not a keyword, so `name = expr` (SPEC.md 150.4, wave 2) ------------
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
    ; **AN ARRAY ELEMENT ASSIGNMENT COMES FIRST**, because `a(3) = 5` and a
    ; call `a(3)` are the same shape and only the name tells them apart
    ; (SPEC.md 150.31).
    mov al, [si]                    ; ...and AL IS LOADED HERE, not inherited:
                                    ; the line that loaded it for the bare-call
                                    ; test is BELOW this block, so the first
                                    ; version tested whatever bas_wordis had
                                    ; left and `rows(0) = 1` was read as a call
    cmp al, '('
    jne .notelemst
    call bas_arrfind
    jc .notelemst
    jmp .elemstore
.notelemst:
    ; **A BARE NAME IS A CALL ONLY IF NOTHING ELSE FOLLOWS IT**, which keeps
    ; `PRIN 3` the refusal it was rather than a call to a procedure called
    ; PRIN with a stray 3 after it (SPEC.md 150.23).
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
.elemstore:
    push bx
    call bas_c_subs                 ; the subscripts first...
    pop bx
    jc .x
    push bx
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '='
    jne .elemnoeq
    inc word [bas_src]
    ; **THE ARRAY'S KIND DECIDES**, as a scalar's spelling does (150.28)
    SHOUT bas_isstrarr
    jc .elemnum
    call bas_c_str                  ; ...text, copied into the element
    cmp byte [bas_bad], 0
    jne .elempop
    mov al, OP_ASSTORE
    call bas_emit
    cmp byte [bas_bad], 0
    jne .elempop
    pop ax
    jmp bas_emit
.elemnum:
    call bas_c_rel                  ; ...then the value
    cmp byte [bas_bad], 0
    jne .elempop
    call bas_wantnum
    jc .elempop
    mov al, OP_ASTORE
    call bas_emit
    cmp byte [bas_bad], 0
    jne .elempop
    pop ax
    jmp bas_emit
.elemnoeq:
    pop bx
    mov si, bas_e_stmt
    SHOUTR bas_err
.elempop:
    pop bx
    ret

.assign:
    inc word [bas_src]
    ; **THE TARGET'S SPELLING DECIDES** (SPEC.md 150.28), so `a$ = ...` reads
    ; text and `a = ...` reads a number, and a mismatch is refused by name
    ; rather than storing one kind in the other's bytes.
    call bas_isstrname
    jc .asnum
    call bas_varfind
    jc .x
    push ax
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .xpop
    mov al, OP_SSTORE
    call bas_emit
    cmp byte [bas_bad], 0
    jne .xpop
    pop ax
    jmp bas_emit
.asnum:
    call bas_varfind                ; AX = its index, created if new
    jc .x                           ; the table is full; said by name
    push ax
    call bas_c_rel                   ; ...the value
    cmp byte [bas_bad], 0
    jne .xpop
    call bas_wantnum                ; ...and it must BE one
    jc .xpop
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
    SHOUTR bas_err

; --- IF <cond> THEN <stmt> [ELSE <stmt>] (SPEC.md 150) ----------------------
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
    call bas_wantnum                ; ...which is a number, not text
    jc .x
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
    ; 150.19); before it there was no later line to hand anything to.
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
; EXIT IF already built (SPEC.md 150.19), threaded through their own
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

; --- ELSEIF <cond> THEN: another arm (SPEC.md 150) -------------------------
; GFA spells it `ELSE IF` and takes no THEN at all; this language's block IF
; already requires THEN (SPEC.md 150.18), so it is one word here and takes
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
    SHOUTR bas_err
.elifelse:
    mov si, bas_e_elifelse
    SHOUTR bas_err
; --- DO ... LOOP [UNTIL c] and REPEAT ... UNTIL c (SPEC.md 150) ------------
; BOTH TEST AT THE BOTTOM, which is what distinguishes them from WHILE: the
; body always runs at least once. They are the same loop with two spellings
; - REPEAT/UNTIL is this line's, DO/LOOP is QuickBASIC's - and they share
; every instruction below; only the keyword that may close them differs, so
; a DO cannot be closed by an UNTIL and the refusal says which.
;
; Neither opens a FORWARD jump, so there is nothing to patch: the block
; carries only where the top is, and the closing test jumps back to it.
; --- EXIT IF <cond>: leave the innermost loop (SPEC.md 150) ----------------
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
    SHOUTR bas_err

; --- PROCEDURE / RETURN / LOCAL, and the three spellings of a call ---------
; (SPEC.md 150.23)
.gosub:
    call bas_skipsp
    call bas_word                   ; A PROCEDURE'S NAME IS AN IDENTIFIER,
    jc .gosnoname                   ; not a label's looser spelling: a bare
                                    ; call reads it with bas_word, so the
                                    ; definition and the other three
                                    ; spellings must read it the same way or
                                    ; `a.b` is two different names
    xor al, al                      ; a STATEMENT, so no value may come back
    jmp bas_callemit
.gosnoname:
    mov si, bas_e_gosname
    SHOUTR bas_err
.atcall:
    inc word [bas_src]              ; over the '@'
    call bas_word
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
    call bas_word
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
    SHOUTR bas_err
.procnoname:
    mov si, bas_e_prcname
    SHOUTR bas_err

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
    ; **NO OP_RETV** (SPEC.md 150.25): the value is on the stack where the
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
    SHOUTR bas_err
.retvalue:
    mov si, bas_e_prcval
    SHOUTR bas_err
.retout:
    mov si, bas_e_retout
    SHOUTR bas_err

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
    SHOUTR bas_err
.locnoname:
    mov si, bas_e_locname
    SHOUTR bas_err

; --- GOTO <label> (SPEC.md 150.22) ----------------------------------------
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
    SHOUTR bas_err

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

; --- SELECT <expr> / CASE / DEFAULT / ENDSELECT (SPEC.md 150.21) -----------
; GFA's multi-way branch, and it needs NO NEW OPCODE: the subject is kept in
; a variable no program can name and every test is the comparison ops the
; expression compiler already emits. What it needs instead is a SECOND chain
; beside 150.20's - a CASE may list several values and any of them enters the
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
    SHOUTR bas_err

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
    xor bx, bx                      ; 150.20's zero says so
    mov ax, BK_DEFAULT
    call bas_blkpush
    jc .x
    mov ax, [bas_blkex]
    jmp bas_blksetex
.defagain:
    mov si, bas_e_defagain
    SHOUTR bas_err

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

; --- FOR v = a TO b [STEP n] ... NEXT [v] (SPEC.md 150) ---------------------
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
    SHOUTR bas_err
.fornov:
    mov si, bas_e_forvar
    SHOUTR bas_err
.forneq:
    mov si, bas_e_foreq
    SHOUTR bas_err
.fornoto:
    mov si, bas_e_forto
    SHOUTR bas_err
.nothen:
    mov si, bas_e_then
    SHOUTR bas_err

; --- WHILE <cond> ... WEND (SPEC.md 150) ------------------------------------
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
    SHOUTR bas_err
.nokw:
    mov si, [bas_src]
    mov al, [si]
    cmp al, "'"                     ; ' is REM, as it is in every BASIC here
    je .rem
    cmp al, '@'                     ; ...and @name is a call (SPEC.md 150.23),
    je .atcall                      ; which bas_word cannot have read: '@' is
                                    ; not a character a word may hold
    cmp al, '~'                     ; ...nor is '~' (SPEC.md 150.27)
    je .tilde
    mov si, bas_e_stmt
    SHOUTR bas_err
.rem:
    call bas_toeol                  ; the rest of the line is a comment
    ret
; --- DIM name(size[,size]) (SPEC.md 150.31, 150.40) --------------------
; THE COMPILER OWNS THE NAME AND THE RUN OWNS THE SIZE. It takes the
; descriptor, writes where the name is and how many dimensions there are,
; and emits TWO EXPRESSIONS PER DIMENSION - low then high, in dimension
; order - followed by OP_DIM and the index. Nothing is laid out here: the
; arena is handed out at run time, which is what makes `DIM a(n)` possible
; at all (SPEC.md 150.40).
;
; N0 IS LEFT 0 ON PURPOSE. It is the allocated flag, it needs no storage of
; its own, and until OP_DIM runs it makes every element reference refuse by
; name through the bound check that is already there.
;
; The entry is still the natural place to keep what IS known here - the
; first draft carried four numbers on the stack through three calls and was
; unreadable by the time the second dimension was optional.
.dim:
    call bas_skipsp
    call bas_word                   ; the name, sigil and all
    jc .dimnoname
    call bas_arrfind
    jnc .dimagain                   ; a name already DIMmed REUSES its row
    mov bx, [bas_narr]
    cmp bx, BAS_ARR_MAX
    jae .dimmax
    SHOUT bas_arrat
    mov [si + BAS_ARR_SRC], di
    mov [si + BAS_ARR_LEN], cx
    mov word [bas_adimr], 0         ; a NEW row: no count to be held to
    inc word [bas_narr]             ; claimed NOW, so the row is this DIM's
    jmp short .dimrow               ; even though its sizes are not read yet
.dimagain:
    ; A SECOND DIM OF ONE NAME (SPEC.md 150.41), which ERASE exists for.
    ; The row is REUSED, so one name still maps to one descriptor index and
    ; an array still costs no run-time type word - what the old refusal
    ; really bought. The count it had is banked, because a re-DIM may change
    ; the BOUNDS and not the NUMBER of them: an element reference is compiled
    ; against this count while bas_aelem reads it at run time to decide how
    ; many subscripts to pop, so a change would leave references pushing one
    ; for a run that pops two.
    SHOUT bas_arrat
    mov ax, [si + BAS_ARR_DIM]
    mov [bas_adimr], ax
.dimrow:
    mov [bas_adimx], bx             ; ...whichever row it is
    mov word [si + BAS_ARR_N0], 0   ; not allocated yet (150.40)
    mov word [si + BAS_ARR_DIM], 1  ; ...and the count IS the loop's counter
    mov word [bas_adimf], 0         ; every dimension plain until proved
    call bas_bopen
    jc .x
    call bas_dimone                 ; the first, which every DIM has
    jc .x
    or [bas_adimf], ax              ; bit 0: dimension 0 was `lo TO hi`
.dimmore:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .dimclose
    inc word [bas_src]
    mov bx, [bas_adimx]
    SHOUT bas_arrat
    mov ax, [si + BAS_ARR_DIM]
    cmp ax, BAS_ARR_DIMMAX
    jae .dimdims                    ; node [71] allows seven; see the equ
    inc word [si + BAS_ARR_DIM]
    call bas_dimone
    jc .x
    push ax                         ; the form answer, over the re-fetch
    mov bx, [bas_adimx]
    SHOUT bas_arrat
    mov cx, [si + BAS_ARR_DIM]
    dec cx                          ; CL = which dimension that just was
    pop ax
    shl ax, cl
    or [bas_adimf], ax              ; ...its form bit, in its own place
    jmp short .dimmore
.dimclose:
    call bas_bclose
    jc .x
    ; --- a re-DIM may not change the NUMBER of sizes (150.41) ------------
    cmp word [bas_adimr], 0
    je .dimemit                     ; a new row: nothing to be held to
    mov bx, [bas_adimx]
    SHOUT bas_arrat
    mov ax, [bas_adimr]
    cmp ax, [si + BAS_ARR_DIM]
    jne .dimredim
.dimemit:
    mov al, OP_DIM
    call bas_emit
    mov ax, [bas_adimx]
    call bas_emit                   ; the row, as a byte
    mov ax, [bas_adimf]
    call bas_emit                   ; ...and which bounds were `lo TO hi`
    mov word [bas_adimd], 1         ; ...and OPTION BASE is closed now
    ret
.dimredim:
    mov si, bas_e_arrdim
    SHOUTR bas_err
.dimdims:
    mov si, bas_e_arrdims
    SHOUTR bas_err
.dimnoname:
    mov si, bas_e_arrname
    SHOUTR bas_err
; (`.dimdup` was here: a second DIM of one name is no longer refused at
; compile time, it REUSES the name's row - SPEC.md 150.41. The refusal it
; carried now happens at RUN time, from OP_DIM, when nothing has ERASEd the
; array between the two; bas_e_arrdup is still that message. A label this
; file named once was a body nothing could reach.)
.dimmax:
    mov si, bas_e_arrmax
    SHOUTR bas_err
; (`.dimfull` was here: the arena-full refusal moved to OP_DIM with the
; allocation itself, SPEC.md 150.40, and the label this file named once was
; a body nothing could reach.)

; --- OPTION BASE 0|1 ---------------------------------------------------
.option:
    call bas_skipsp
    call bas_word
    jc .optbad
    mov si, bas_kw_base
    call bas_wordis
    jne .optbad
    cmp word [bas_adimd], 0         ; ...and only before any DIM, which is a
    jne .optlate                    ; SHARPER rule since 150.40 than the
                                    ; "an array already laid out cannot move
                                    ; its base" it was: nothing is laid out
                                    ; at compile time now, and OP_DIM reads
                                    ; bas_abase AT RUN TIME - so an OPTION
                                    ; BASE after a DIM would reach back and
                                    ; change that DIM's bounds instead of
                                    ; merely disagreeing with them
    call bas_c_const
    jc .x
    cmp ax, 1
    ja .optval
    or ax, ax
    js .optval
    mov [bas_abase], ax
    ret
.optbad:
    mov si, bas_e_stmt
    SHOUTR bas_err
.optlate:
    mov si, bas_e_basedim
    SHOUTR bas_err
.optval:
    mov si, bas_e_baseval
    SHOUTR bas_err

.tilde:
    inc word [bas_src]
.void:
    call bas_c_rel                  ; anything at all, and then forget it
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_DROP
    jmp bas_emit
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
    SHOUTR bas_err
.print:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .pbare
    cmp al, 10
    je .pbare
    ; **IT ASKS, IT DOES NOT DECIDE.** `PRINT "a" = "a"` begins with text
    ; and answers a NUMBER, so looking at the first token here printed the
    ; first operand and left the comparison unread (SPEC.md 150.28).
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_PRINT
    cmp byte [bas_restype], 0
    je .psay
    mov al, OP_SPRINT               ; ...text, and it came back as text
.psay:
    call bas_emit
.pbare:
    mov al, OP_NEWL                 ; a bare PRINT is a blank line
    jmp bas_emit

; --- CLR, which costs no opcode (SPEC.md 150.33) ------------------------
; `CLR x` IS `x = 0` and `CLR x$` is `x$ = ""`, and both of those are paths
; this file already has and already tests. So this is a comma loop over two
; emissions and nothing at run time at all - a new opcode here would have
; been a second implementation of a store.
.clr:
    call bas_skipsp
    call bas_word                   ; DI/CX = the name
    jc .clrnoname
    call bas_arrfind                ; ...and an ARRAY by that name is the
    jnc .clrarr                     ; other word, with or without its parens
    call bas_isstrname
    jc .clrnum
    call bas_varfind                ; AX = its index
    jc .x
    push ax
    mov al, OP_SPUSHL
    call bas_emit
    cmp byte [bas_bad], 0
    jne .clrpop
    xor ax, ax
    call bas_emitw                  ; WHERE does not matter...
    cmp byte [bas_bad], 0
    jne .clrpop
    xor ax, ax
    call bas_emitw                  ; ...because the LENGTH is zero (150.28)
    cmp byte [bas_bad], 0
    jne .clrpop
    mov al, OP_SSTORE
    call bas_emit
    cmp byte [bas_bad], 0
    jne .clrpop
    pop ax
    call bas_emit
    jmp short .clrmore
.clrnum:
    call bas_varfind
    jc .x
    push ax
    xor ax, ax
    call bas_emitnum                ; 0, through the one routine that knows
    cmp byte [bas_bad], 0           ; how a number rides in the op stream
    jne .clrpop
    mov al, OP_STORE
    call bas_emit
    cmp byte [bas_bad], 0
    jne .clrpop
    pop ax
    call bas_emit
.clrmore:
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .x
    inc word [bas_src]
    jmp .clr                        ; the next name in the list
.clrpop:
    pop ax
    ret
.clrarr:
    mov si, bas_e_clrarr            ; the reference says it in as many words:
    SHOUTR bas_err                     ; "Arrays cannot be used with CLR, see
.clrnoname:                         ; ARRAYFILL"
    mov si, bas_e_swapname
    SHOUTR bas_err

; --- ARRAYFILL x(), aexp (SPEC.md 150.33) -------------------------------
; The value is compiled ONCE, before the op, so the statement's cost does
; not depend on how many elements it writes.
.afill:
    call bas_skipsp
    call bas_word
    jc .afillnoname
    call bas_isstrname              ; CF=0 when the name ends in '$'
    jnc .afillstr
    call bas_arrfind                ; BX = which array
    jc .afillno
    push bx
    call bas_bopen                  ; the empty parens the reference writes
    jc .afillpop
    call bas_bclose
    jc .afillpop
    call bas_bcomma
    jc .afillpop
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .afillpop
    call bas_wantnum                ; ...and it must BE a number
    jc .afillpop
    mov al, OP_AFILL
    call bas_emit
    cmp byte [bas_bad], 0
    jne .afillpop
    pop ax                          ; which array, as the index byte
    jmp bas_emit
.afillpop:
    pop ax
    ret
.afillstr:
    mov si, bas_e_afillstr          ; node [73]'s own limit, and 150.28's:
    SHOUTR bas_err                     ; 512 copies of one string, each a root
.afillno:
    mov si, bas_e_afillno
    SHOUTR bas_err
.afillnoname:
    mov si, bas_e_swapname
    SHOUTR bas_err

; --- SWAP a,b and SWAP x(),y() (SPEC.md 150.34) -------------------------
; Both operands are read by one helper, which answers WHAT each one is; the
; kinds must agree and so must the arrayness, and both are compile-time
; questions because a name's spelling is the only place its kind is written.
.swap:
    call bas_swapone                ; AL = index, AH = flags
    jc .x
    push ax
    call bas_bcomma
    jc .swappop
    call bas_swapone
    jc .swappop
    pop dx                          ; DL = the first index, DH = its flags
    mov bl, ah
    xor bl, dh
    test bl, 2                      ; one '$' and one not
    jnz .swapkind
    test bl, 1                      ; one array and one scalar
    jnz .swapmix
    push ax
    mov al, OP_SWAP
    test dh, 1
    jz .swapemit
    mov al, OP_ASWAP
.swapemit:
    call bas_emit                   ; bas_emit preserves DX, which is where
    cmp byte [bas_bad], 0           ; the first operand still is
    jne .swappop
    mov al, dl
    call bas_emit
    cmp byte [bas_bad], 0
    jne .swappop
    pop ax                          ; ...and the second rides after it
    jmp bas_emit
.swappop:
    pop ax
    ret
.swapkind:
    mov si, bas_e_swapkind
    SHOUTR bas_err
.swapmix:
    mov si, bas_e_swapmix
    SHOUTR bas_err

; --- LSET / RSET a$ = b$ (SPEC.md 150.35) -------------------------------
; ONE BODY, and which opcode it ends in is decided before the parse starts,
; because that is the only thing the two spellings differ in.
; --- MOUSE mx,my,mk, node [210] (SPEC.md 150.53) ------------------------
; THREE avars - output VARIABLES, as ALERT's choice is - and the opcode
; carries all three indices so that ONE poll fills them. Reading them with
; MOUSEX, MOUSEY and MOUSEK instead is three polls, and a pointer that moves
; between any two of them gives a position that was never real.
.mousest:
    ; THE OPCODE GOES OUT FIRST and each index follows it as that name is
    ; parsed, which is why there is no juggling here: the stream wants
    ; OP_MOUSEST, mx, my, mk in exactly the order they are read. A name that
    ; refuses leaves a partial opcode behind and that is harmless, because a
    ; refused compile never runs.
    mov al, OP_MOUSEST
    call bas_emit
    cmp byte [bas_bad], 0
    jne .mousex0
    mov cx, 3
.mousenm:
    push cx
    call bas_skipsp
    call bas_word
    jc .mousenotv
    call bas_isstrname              ; CF=0 when it ends in '$'...
    jnc .mousenotv                  ; ...and a '$' name is not a number
    call bas_varfind
    jc .mousepopx
    call bas_emit                   ; AL = the index, into the stream
    cmp byte [bas_bad], 0
    jne .mousepopx
    pop cx
    dec cx
    jz .mousex0
    ; THE LOOP MUST RE-ENTER AT THE DEPTH IT LEFT. Holding CX across the
    ; comma on the stack and jumping back from there pushes a second one
    ; every pass - stkbalance named this line before it ever ran. POP is
    ; flagless, so the jc below still reads bas_bcomma's answer.
    push cx
    call bas_bcomma
    pop cx
    jc .mousex0
    jmp short .mousenm
.mousepopx:
    pop cx
.mousex0:
    ret
.mousenotv:
    pop cx
    mov si, bas_e_mousevar
    SHOUTR bas_err

; --- MID$(a$,x[,y]) = b$, node [156] (SPEC.md 150.50) -------------------
; THE TARGET IS AN svar AND NOT AN sexp, which is what makes this the first
; string LVALUE in the chapter - and the reason it is parsed here, at
; statement position, rather than by the expression parser that compiles the
; MID$ FUNCTION. The variable's INDEX is the opcode's operand, exactly as
; LSET's is below; x, y and the text go on the stack.
;
; A MISSING y IS 32767 THE COMPILER PUSHES, which is the MID$ function's own
; trick for its missing length (150.29) - one opcode, not two - and the op
; clamps it to the room actually left.
.midst:
    call bas_bopen
    jc .midstx
    call bas_skipsp
    call bas_word
    jc .midstnotstr
    call bas_isstrname              ; CF=0 when the name ends in '$'
    jc .midstnotstr
    call bas_varfind                ; AX = its index
    jc .midstx
    push ax                         ; the variable, through the whole parse
    call bas_bcomma
    jc .midstpop
    call bas_c_rel                  ; x
    cmp byte [bas_bad], 0
    jne .midstpop
    call bas_wantnum
    jc .midstpop
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    je .midst3
    mov ax, 32767                   ; ...as many as fit
    call bas_emitnum
    cmp byte [bas_bad], 0
    jne .midstpop
    jmp short .midstend
.midst3:
    inc word [bas_src]
    call bas_c_rel                  ; y
    cmp byte [bas_bad], 0
    jne .midstpop
    call bas_wantnum
    jc .midstpop
.midstend:
    call bas_bclose
    jc .midstpop
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '='
    jne .midstnoeq
    inc word [bas_src]
    call bas_c_str                  ; the text to write in
    cmp byte [bas_bad], 0
    jne .midstpop
    mov al, OP_SMIDST
    call bas_emit
    cmp byte [bas_bad], 0
    jne .midstpop
    pop ax
    jmp bas_emit                    ; ...and which variable
.midstpop:
    pop ax
.midstx:
    ret
.midstnotstr:
    mov si, bas_e_lsetstr
    SHOUTR bas_err
.midstnoeq:
    pop ax
    mov si, bas_e_midsteq
    SHOUTR bas_err

.lset:
    mov al, OP_LSET
    jmp short .lsetgo
.rset:
    mov al, OP_RSET
.lsetgo:
    push ax                         ; [1] the opcode, through the parse
    call bas_skipsp
    call bas_word
    jc .lsetnotstr
    call bas_isstrname              ; CF=0 when the name ends in '$'
    jc .lsetnotstr
    call bas_varfind                ; AX = its index
    jc .lsetpop1
    push ax                         ; [2] ...the index, through the value
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '='
    jne .lsetnoeq
    inc word [bas_src]
    call bas_c_str                  ; the text to justify
    cmp byte [bas_bad], 0
    jne .lsetpop2
    pop bx                          ; [2] the index...
    pop ax                          ; [1] ...and the opcode
    call bas_emit                   ; bas_emit preserves BX
    cmp byte [bas_bad], 0
    jne .x
    mov al, bl
    jmp bas_emit
.lsetpop2:
    pop ax
.lsetpop1:
    pop ax
    ret
.lsetnotstr:
    pop ax
    mov si, bas_e_lsetstr
    SHOUTR bas_err
.lsetnoeq:
    pop ax
    pop ax
    mov si, bas_e_lseteq
    SHOUTR bas_err
; --- ERASE a()[, b()] (SPEC.md 150.41, node [94]) ----------------------
; One OP_ERASE per name. The empty brackets are the Compendium's spelling
; and are required: `ERASE a` would read as a scalar and there is no
; statement that deletes one.
.erase:
    call bas_skipsp
    call bas_word                   ; the name, sigil and all
    jc .erasename
    call bas_arrfind                ; BX = its row
    jc .erasenodim
    call bas_bopen
    jc .x
    call bas_bclose                 ; ...and nothing between them
    jc .x
    mov al, OP_ERASE
    call bas_emit
    mov ax, bx
    call bas_emit                   ; the row, as a byte
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .eraseout
    inc word [bas_src]
    jmp short .erase                ; node [94]: several at once
.eraseout:
    ret
.erasename:
    mov si, bas_e_arrname
    SHOUTR bas_err
.erasenodim:
    mov si, bas_e_arrnotdim
    SHOUTR bas_err

; --- ON MENU (SPEC.md 150.36) -------------------------------------------
; Bare, this wave. `ON MENU GOSUB handler` registers one and is refused by
; name until MENU exists to dispatch to - a handler with no bar to fire from
; would be a statement that compiled and could never run.
.onstmt:
    call bas_skipsp
    call bas_word
    jc .onbad
    mov si, bas_kw_menu
    call bas_wordis
    jne .onbad
    call bas_skipsp                 ; ...bare, or GOSUB and a handler
    mov si, [bas_src]
    mov al, [si]
    or al, al
    jz .onemit
    cmp al, 10
    je .onemit
    call bas_word
    jc .onbadarg
    mov si, bas_kw_gosub
    call bas_wordis
    jne .onbadarg
    call bas_skipsp
    call bas_word                   ; DI/CX = the handler's name
    jc .onbadarg
    mov byte [bas_calfn], 0         ; a PROCEDURE, as a bare call is
    mov al, OP_ONMGOSUB
    call bas_emit
    cmp byte [bas_bad], 0
    jne .x
    call bas_prcfind
    jc .ongfwd
    push bx
    call bas_prcat
    cmp word [si + BAS_PRC_NP], 0   ; ...and it takes NOTHING: a pick hands
    jne .ongpopbad                  ; over no values
    mov ax, [si + BAS_PRC_OPS]
    pop bx
    jmp bas_emitw
.ongpopbad:
    pop bx
    mov si, bas_e_onghand
    SHOUTR bas_err
.ongfwd:
    ; THE SAME FORWARD RECORD A CALL MAKES, so bas_calfix resolves it and a
    ; handler written BELOW the ON MENU GOSUB works - which is the ordinary
    ; shape, the loop coming first and the handler after it
    mov bx, [bas_opn]
    xor ax, ax
    call bas_emitw
    cmp byte [bas_bad], 0
    jne .x
    mov ax, bx
    mov bx, [bas_ncal]
    cmp bx, BAS_CAL_MAX
    jae .ongfull
    call bas_calat
    mov [si + BAS_CAL_SLOT], ax
    mov [si + BAS_CAL_SRC], di
    mov [si + BAS_CAL_LEN], cx
    mov word [si + BAS_CAL_NARG], 0
    mov word [si + BAS_CAL_FN], 0
    mov ax, [bas_line]
    mov [si + BAS_CAL_LINE], ax
    xor bx, bx                      ; ...and the argument slots cleared, so
.ongsl:                             ; a previous program's cannot be read
    mov word [si + BAS_CAL_SL + bx], 0
    add bx, 2
    cmp bx, BAS_PRC_PMAX*2
    jb .ongsl
    inc word [bas_ncal]
    ret
.ongfull:
    mov si, bas_e_calmax
    SHOUTR bas_err
.onbadarg:
    mov si, bas_e_onmarg
    SHOUTR bas_err
.onemit:
    mov al, OP_ONMENU
    jmp bas_emit
.onbad:
    mov si, bas_e_onwhat
    SHOUTR bas_err

; --- ALERT icon, message$, default, button$, choice (SPEC.md 150.37) ----
; Five operands, and the first four are pushed IN ORDER so the op pops them
; in reverse. The fifth is a VARIABLE and rides as the index byte, which is
; what makes `choice` an output rather than a value.
.alert:
    call bas_c_rel                  ; icon - accepted and ignored (150.37)
    cmp byte [bas_bad], 0
    jne .x
    call bas_wantnum
    jc .x
    call bas_bcomma
    jc .x
    call bas_c_str                  ; message$
    cmp byte [bas_bad], 0
    jne .x
    call bas_bcomma
    jc .x
    call bas_c_rel                  ; default - ignored: each set rings its own
    cmp byte [bas_bad], 0
    jne .x
    call bas_wantnum
    jc .x
    call bas_bcomma
    jc .x
    call bas_c_str                  ; button$
    cmp byte [bas_bad], 0
    jne .x
    call bas_bcomma
    jc .x
    call bas_skipsp
    call bas_word                   ; ...and the choice variable
    jc .alnovar
    call bas_isstrname              ; CF=0 means it ends in '$'
    jnc .alnovar
    call bas_varfind
    jc .x
    push ax
    mov al, OP_ALERT
    call bas_emit
    cmp byte [bas_bad], 0
    jne .alpop
    pop ax
    jmp bas_emit
.alpop:
    pop ax
    ret
.alnovar:
    mov si, bas_e_alvar
    SHOUTR bas_err

; --- MENU m$() (SPEC.md 150.38) ------------------------------------------
; The array's NAME decides, as everywhere in this chapter: it must be a
; DIMmed `$` array, and the index rides as the op's byte.
.menu:
    call bas_skipsp
    call bas_word
    jc .mennoarr
    call bas_isstrname              ; CF=0 when it ends in '$'
    jc .mennoarr
    call bas_arrfind                ; BX = which array
    jc .mennoarr
    push bx
    call bas_bopen                  ; `m$()` - and the parens stay empty
    jc .menpop
    call bas_bclose
    jc .menpop
    mov al, OP_MENU
    call bas_emit
    cmp byte [bas_bad], 0
    jne .menpop
    pop ax
    jmp bas_emit
.menpop:
    pop ax
    ret
.mennoarr:
    mov si, bas_e_menarr
    SHOUTR bas_err
.x:
    ret

; -----------------------------------------------------------------------------
; bas_c_str - compile a STRING expression (SPEC.md 150.28)
;
; literal | $-name | ( ... ) | the lot joined by '+'. The type of every
; expression is known here, at compile time, from the names in it - which is
; why no slot on the value stack carries a tag and why this is a separate
; routine rather than a case inside bas_c_expr.
; -----------------------------------------------------------------------------
bas_c_str:
    call bas_c_sfact
    cmp byte [bas_bad], 0
    jne .sx
.more:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '+'              ; ...joined, which is the only operator
    jne .sx                         ; a string takes here
    inc word [bas_src]
    call bas_c_sfact
    cmp byte [bas_bad], 0
    jne .sx
    mov al, OP_SCAT
    call bas_emit
    cmp byte [bas_bad], 0
    jne .sx
    jmp .more                       ; ...AND AGAIN: three pieces is two joins
.sx:
    ret

bas_c_sfact:
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    cmp al, '"'
    je .lit
    cmp al, '('
    je .paren
    call bas_word                   ; a $-name, or a built-in that makes text
    jc .notstr
    mov si, bas_kw_chr
    call bas_wordis
    je .b_chr
    mov si, bas_kw_str
    call bas_wordis
    je .b_str
    mov si, bas_kw_left
    call bas_wordis
    je .b_left
    mov si, bas_kw_right
    call bas_wordis
    je .b_right
    mov si, bas_kw_mid
    call bas_wordis
    je .b_mid
    mov si, bas_kw_trim             ; node [159], hidden in LEN's node
    call bas_wordis
    je .b_trim
    mov si, bas_kw_upper            ; node [163] - and there is no LOWER$
    call bas_wordis
    je .b_upper
    mov si, bas_kw_space            ; node [162], both of its forms and
    call bas_wordis                 ; SPACE$ too (SPEC.md 150.46)
    je .b_space
    mov si, bas_kw_string
    call bas_wordis
    je .b_string
    mov si, bas_kw_inkey            ; node [167]: no arguments, no parens
    call bas_wordis
    je .b_inkey
    mov si, bas_kw_spc              ; node [162]'s third, hidden in its title
    call bas_wordis                 ; exactly as TRIM$ hides in LEN's
    je .b_space                     ; ...and it IS SPACE$: see 150.52
    mov si, bas_kw_pred             ; node [158] - the TEXT half of a pair
    call bas_wordis                 ; node [146] defines twice over
    je .b_pred
    mov si, bas_kw_succ
    call bas_wordis
    je .b_succ
    ; a `$` ARRAY's element reads as text, and the same OP_ALOAD serves:
    ; an element is eight bytes and a string value is the first four of
    ; them, so the copy onto the stack is already right (SPEC.md 150.31)
    call bas_arrfind
    jc .nostrarr
    SHOUT bas_isstrarr
    jc .notstr                      ; a numeric array is not text
    jmp .selem
.nostrarr:
    call bas_isstrname
    jc .notstr
    call bas_varfind
    jc .sfx
    push ax
    mov al, OP_SLOAD
    call bas_emit
    pop ax
    cmp byte [bas_bad], 0
    jne .sfx
    jmp bas_emit                    ; ...the index byte after it
.paren:
    inc word [bas_src]
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .sfx
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'
    jne .noclose
    inc word [bas_src]
    ret
.lit:
    ; **PUSHED WHERE IT LIES** (SPEC.md 150.28): the program text is stable
    ; for the whole of a run, so a literal is an offset into it and the
    ; quotation marks are not part of the value.
    inc word [bas_src]
    mov di, [bas_src]               ; DI = the first byte of the text
    mov si, di
    xor cx, cx
.scan:
    mov al, [si]
    or al, al
    jz .noquote
    cmp al, 10
    je .noquote
    cmp al, '"'
    je .gotlit
    inc si
    inc cx
    jmp .scan
.gotlit:
    inc si
    mov [bas_src], si               ; past the closing quote
    mov al, OP_SPUSHL
    call bas_emit
    cmp byte [bas_bad], 0
    jne .sfx
    mov ax, di
    call bas_emitw                  ; where it is...
    cmp byte [bas_bad], 0
    jne .sfx
    mov ax, cx
    jmp bas_emitw                   ; ...and how long
.selem:
    push bx
    call bas_c_subs
    pop bx
    jc .selx
    mov al, OP_ALOAD
    call bas_emit
    cmp byte [bas_bad], 0
    jne .selx
    mov ax, bx
    jmp bas_emit
.selx:
    ret

; --- CHR$(n) and STR$(n): one number in, text out --------------------
.b_chr:
    mov al, OP_NCHR
    jmp short .b_n1
.b_str:
    mov al, OP_NSTR
.b_n1:
    push ax
    call bas_bopen
    jc .b_n1x
    call bas_c_rel                  ; a NUMBER, and it must be one
    cmp byte [bas_bad], 0
    jne .b_n1x
    call bas_wantnum
    jc .b_n1x
    call bas_bclose
    jc .b_n1x
    pop ax
    jmp bas_emit
.b_n1x:
    pop ax
    ret

; --- LEFT$(s$,n) and RIGHT$(s$,n) ------------------------------------
.b_left:
    mov al, OP_SLEFT
    jmp short .b_sn
.b_right:
    mov al, OP_SRIGHT
.b_sn:
    push ax
    call bas_bopen
    jc .b_snx
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_snx
    call bas_bcomma
    jc .b_snx
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .b_snx
    call bas_wantnum
    jc .b_snx
    call bas_bclose
    jc .b_snx
    pop ax
    jmp bas_emit
.b_snx:
    pop ax
    ret

; --- TRIM$(a$) and UPPER$(a$) - one string in, one out ------------------
; INKEY$ TAKES NOTHING AND IS NOT CALLED, so there is no bas_bopen here and
; no argument list - the word itself is the whole expression (node [167]).
; bas_restype is set by bas_c_sfact's caller, as it is for every other text
; result, so this emits one byte and returns.
.b_inkey:
    mov al, OP_SINKEY
    jmp bas_emit

; PRED$ / SUCC$ OF TEXT: node [158]'s CHR$(ASC(a$)-1) and CHR$(ASC(a$)+1),
; one opcode and a direction byte. The numeric half of the same two names is
; an FN1 in bas_c_fact; which one a program gets is decided by the ARGUMENT,
; through bas_isstrahead above (SPEC.md 150.51).
.b_pred:
    xor al, al
    jmp short .b_step
.b_succ:
    mov al, 1
.b_step:
    push ax
    call bas_bopen
    jc .b_stepx
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_stepx
    call bas_bclose
    jc .b_stepx
    mov al, OP_SSTEP
    call bas_emit
    cmp byte [bas_bad], 0
    jne .b_stepx
    pop ax
    jmp bas_emit                    ; ...and which way
.b_stepx:
    pop ax
    ret

.b_trim:
    mov al, OP_STRIM
    jmp short .b_s1
.b_upper:
    mov al, OP_SUPPER
.b_s1:
    push ax
    call bas_bopen
    jc .b_s1x
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_s1x
    call bas_bclose
    jc .b_s1x
    pop ax
    jmp bas_emit
.b_s1x:
    pop ax
    ret

; --- SPACE$(x), STRING$(x,a$) and STRING$(x,code) - ONE op ---------------
; MID$ below does the same thing for the same reason: its missing length is
; a 32767 THE COMPILER PUSHES, "so there is one opcode and not two". Here
; SPACE$'s repeated text is a literal space the compiler pushes, and
; STRING$'s numeric second form is an OP_NCHR it inserts - so OP_SREP
; serves all three and node [162]'s two signatures need no second op
; (SPEC.md 150.46).
;
; THE COUNT IS COMPILED FIRST because the SOURCE names it first, and
; OP_SREP pops the text off the top for exactly that reason.
.b_space:
    call bas_bopen
    jc .b_s2x
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .b_s2x
    call bas_wantnum
    jc .b_s2x
    call bas_bclose
    jc .b_s2x
    mov al, OP_SPUSHL               ; ...and the space the source never wrote
    call bas_emit
    mov ax, bas_s_sp1
    call bas_emitw
    mov ax, 1
    call bas_emitw
    mov al, OP_SREP
    jmp bas_emit
.b_string:
    call bas_bopen
    jc .b_s2x
    call bas_c_rel                  ; the COUNT
    cmp byte [bas_bad], 0
    jne .b_s2x
    call bas_wantnum
    jc .b_s2x
    call bas_bcomma
    jc .b_s2x
    call bas_c_rel                  ; ...and what to repeat, either kind
    cmp byte [bas_bad], 0
    jne .b_s2x
    call bas_bclose
    jc .b_s2x
    cmp byte [bas_restype], 0       ; a NUMBER there is a character CODE,
    jne .b_srep                     ; which is node [162]'s second form
    mov al, OP_NCHR
    call bas_emit
.b_srep:
    mov al, OP_SREP
    jmp bas_emit
.b_s2x:
    ret

; --- MID$(s$, start [, n]) -------------------------------------------
; **A MISSING LENGTH IS 32767, PUSHED BY THE COMPILER**, so there is one
; opcode and not two: "to the end" is just a count no string can reach
; (SPEC.md 150.28 caps the arena far below it), and the run-time clamp that
; every other count goes through handles it with no special case.
.b_mid:
    call bas_bopen
    jc .b_midx
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_midx
    call bas_bcomma
    jc .b_midx
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .b_midx
    call bas_wantnum
    jc .b_midx
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    je .b_mid3
    mov ax, 32767                   ; ...to the end
    call bas_emitnum
    cmp byte [bas_bad], 0
    jne .b_midx
    jmp short .b_midend
.b_mid3:
    inc word [bas_src]
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .b_midx
    call bas_wantnum
    jc .b_midx
.b_midend:
    call bas_bclose
    jc .b_midx
    mov al, OP_SMID
    jmp bas_emit
.b_midx:
    ret

.sfx:
    ret
.noquote:
    mov si, bas_e_strquote
    SHOUTR bas_err
.noclose:
    mov si, bas_e_paren
    SHOUTR bas_err
.notstr:
    mov si, bas_e_strtype
    SHOUTR bas_err

; --- bas_wantnum - refuse if bas_c_rel just left TEXT on the stack ------
; out: CF=1 and refused by name. Every site that needs a number says so -
; a condition, a loop bound, a numeric store - because the alternative is a
; string's offset read as a double, which is a plausible-looking number.
bas_wantnum:
    cmp byte [bas_restype], 0
    je .wok
    mov si, bas_e_strtype
    SHOUT bas_err
    stc
    ret
.wok:
    clc
    ret

; --- bas_bopen / bas_bcomma / bas_bclose - a built-in's punctuation -----
; out: CF=1 and refused by name. Three one-line routines rather than the
; same six instructions eight times over, which is what the first draft of
; SPEC.md 150.29 had.
bas_bopen:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '('
    jne .bono
    inc word [bas_src]
    clc
    ret
.bono:
    mov si, bas_e_paren
    SHOUT bas_err
    stc
    ret

bas_bcomma:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .bcno
    inc word [bas_src]
    clc
    ret
.bcno:
    mov si, bas_e_comma
    SHOUT bas_err
    stc
    ret

bas_bclose:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ')'
    jne .bzno
    inc word [bas_src]
    clc
    ret
.bzno:
    mov si, bas_e_paren
    SHOUT bas_err
    stc
    ret

; --- bas_emitnum - AX as a literal number on the stack ------------------
bas_emitnum:
    push ax
    push di
    mov al, OP_PUSHN
    call bas_emit
    cmp byte [bas_bad], 0
    jne .enout
    pop di
    pop ax
    push ax
    push di
    SHOUT fp_i2a
    mov di, bas_ops
    add di, [bas_opn]
    SHOUT fp_pack_a
    add word [bas_opn], 8
    cmp word [bas_opn], BAS_OPS_MAX - 10
    jb .enout
    mov si, bas_e_long
    SHOUT bas_err
.enout:
    pop di
    pop ax
    ret

; --- bas_isstrname - does the word in DI/CX end in '$'? -----------------
; out: CF=0 if it does. Preserves DI and CX, which every caller still needs.
bas_isstrname:
    push ax
    push si
    or cx, cx
    jz .nno
    mov si, di
    add si, cx
    dec si
    cmp byte [si], '$'
    jne .nno
    clc
.nout:
    pop si
    pop ax
    ret
.nno:
    stc
    jmp .nout

; --- bas_isstrahead - is the expression at the cursor a STRING? ---------
; out: CF=0 if it is. The cursor is left exactly where it was.
;
; ONE TOKEN IS ENOUGH, which is what the sigil system buys: a string
; expression begins with a quotation mark or with a `$` name, and nothing
; that begins any other way can become one.
bas_isstrahead:
    push ax
    push cx
    push si
    push di
    mov ax, [bas_src]
    push ax
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '"'
    je .ayes
.ascan:
    call bas_word
    jc .ano
    call bas_isstrname
    jnc .ayes
    ; **PRED AND SUCC ARE TRANSPARENT TO THIS QUESTION** (SPEC.md 150.51).
    ; Every other name declares its kind in its spelling - a trailing '$' -
    ; which is how a parser is chosen before anything else is read. Node
    ; [158] returns TEXT from a name that has no '$', so the only thing that
    ; can answer is the ARGUMENT: step over the name and its '(' and ask the
    ; same question one level in. Looping rather than recursing is what
    ; makes PRED(SUCC(a$)) cost nothing extra, and the cursor is restored
    ; either way because this routine always restores it.
    push si
    mov si, bas_kw_pred
    call bas_wordis
    je .astep
    mov si, bas_kw_succ
    call bas_wordis
    je .astep
    pop si
    jmp short .ano
.astep:
    pop si
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '('
    jne .ano
    inc word [bas_src]
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '"'
    je .ayes
    jmp short .ascan
.ayes:
    pop ax
    mov [bas_src], ax
    clc
.aout:
    pop di
    pop si
    pop cx
    pop ax
    ret
.ano:
    pop ax
    mov [bas_src], ax
    stc
    jmp .aout

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
    ; **A COMPARISON IS WHERE THE TWO KINDS MEET** (SPEC.md 150.28), and it
    ; is the only place they may: a string comparison compiles both sides as
    ; text, emits OP_SCMP for -1/0/1, and then runs the ordinary numeric
    ; relation against zero - so the six come free and TRUE is still -1.
    mov byte [bas_restype], 0       ; ...a number unless this says otherwise
    call bas_isstrahead
    jc .num
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    cmp al, '<'
    je .srel
    cmp al, '>'
    je .srel
    cmp al, '='
    je .srel
    ; **TEXT ON ITS OWN**, which only PRINT and a `$` store may use - and
    ; they ask [bas_restype]. A COMPARISON of text is a NUMBER, which is why
    ; this flag is set here and not by bas_c_str.
    mov byte [bas_restype], 1
    ret
.srel:
    call bas_c_relop                ; CL = which relation, cursor past it
    cmp byte [bas_bad], 0
    jne .x
    push cx
    call bas_c_str                  ; ...the right-hand text
    pop cx
    cmp byte [bas_bad], 0
    jne .x
    push cx
    mov al, OP_SCMP
    call bas_emit
    cmp byte [bas_bad], 0
    jne .spop
    call bas_emitzero               ; ...against zero
    cmp byte [bas_bad], 0
    jne .spop
    pop cx
    mov al, cl
    jmp bas_emit
.spop:
    pop cx
    ret
.num:
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    mov al, [si]
    cmp al, '<'
    je .nrel
    cmp al, '>'
    je .nrel
    cmp al, '='
    je .nrel
.x:
    ret
.nrel:
    call bas_c_relop                ; CL = which, and the cursor past it
    cmp byte [bas_bad], 0
    jne .x
    push cx
    call bas_c_expr                 ; ...the right-hand side
    pop cx
    cmp byte [bas_bad], 0
    jne .x
    mov al, cl
    jmp bas_emit

; --- bas_c_relop - the relation at the cursor; CL = its opcode ----------
; THE TWO-CHARACTER FORMS ARE READ FIRST (SPEC.md 150.18), or `a <= b`
; parses as `a < (= b)` and is refused for the wrong reason. Shared by the
; numeric path above and the string path at the top of this routine, which
; is why it is a routine at all.
bas_c_relop:
    push ax
    push si
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
    mov si, bas_e_expr
    SHOUT bas_err
    jmp .rout
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
.rout:
    pop si
    pop ax
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
    call bas_c_pow
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
    call bas_c_pow
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_MUL
    call bas_emit
    jmp .more
.idiv:
    inc word [bas_src]
    call bas_c_pow
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_IDIV
    call bas_emit
    jmp .more
.slash:
    inc word [bas_src]
    call bas_c_pow
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_DIV
    call bas_emit
    jmp .more
.x:
    ret

; -----------------------------------------------------------------------------
; bas_c_pow - power:  factor [ '^' power ]   (SPEC.md 150.45, node [128])
; -----------------------------------------------------------------------------
; BETWEEN term AND factor, which is the whole of node [128]'s ranking: `^` is
; above `* /` and BELOW signing, so its operands are FACTORS - and a factor
; is where unary minus lives. That is what makes `-2^2` four here and not
; minus four: the base is already negated when `^` sees it.
;
; RIGHT-ASSOCIATIVE, by recursing instead of looping, so `2^3^2` is 2^(3^2).
; Node [128] ranks the operators and says nothing about this, so it is
; basicnw's answer taken as a CHOICE where the Compendium is silent - not a
; reading of it (SPEC.md 150.45).
;
; `2^-3` needs no brackets for the same reason the base does not: the
; exponent is a factor too, and signing is inside it.
bas_c_pow:
    call bas_c_fact
    cmp byte [bas_bad], 0
    jne .x
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '^'
    jne .x
    inc word [bas_src]
    call bas_c_pow                  ; ...itself, which is the associativity
    cmp byte [bas_bad], 0
    jne .x
    mov al, OP_POW
    jmp bas_emit
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
    ; --- the built-ins that answer a NUMBER (SPEC.md 150.29) -----------
    mov si, bas_kw_mousex           ; node [210] - the pointer is a STATE,
    call bas_wordis                 ; so these take nothing and poll it
    je .b_mousex
    mov si, bas_kw_mousey
    call bas_wordis
    je .b_mousey
    mov si, bas_kw_mousek
    call bas_wordis
    je .b_mousek
    mov si, bas_kw_pred             ; node [146]'s half of the pair: the
    call bas_wordis                 ; argument decides which (SPEC.md 150.51)
    je .b_npred
    mov si, bas_kw_succ
    call bas_wordis
    je .b_nsucc
    mov si, bas_kw_instr            ; node [160] - and RINSTR, node [161],
    call bas_wordis                 ; which is the same search backwards
    je .b_instr
    mov si, bas_kw_rinstr
    call bas_wordis
    je .b_rinstr
    mov si, bas_kw_len
    call bas_wordis
    je .b_len
    mov si, bas_kw_asc
    call bas_wordis
    je .b_asc
    mov si, bas_kw_val
    call bas_wordis
    je .b_val
    mov si, bas_kw_dimq             ; DIM?(a()) - node [71]'s own, and the
    call bas_wordis                 ; only array-shape query the Compendium
    je .b_dimq                      ; has (SPEC.md 150.43)
    mov si, bas_kw_lbound
    call bas_wordis
    je .b_lbound
    mov si, bas_kw_ubound
    call bas_wordis
    je .b_ubound
    mov si, bas_kw_menu             ; MENU(0) - node [300]'s answer for which
    call bas_wordis                 ; entry was picked (SPEC.md 150.38)
    je .b_msel
    ; --- the one-argument numeric functions (SPEC.md 150.44) ------------
    ; ONE WALK, NOT FOURTEEN `wordis` BRANCHES: the row's position in
    ; bas_fn1names IS the FN1_* index OP_FN1 takes, so a fifteenth function
    ; is a name here and a routine there and nothing else. The index rides
    ; the host stack across the argument, as .b_bound's `which end` does.
    push dx
    mov si, bas_fn1names
    xor dx, dx
.b_fn1try:
    cmp byte [si], 0
    je .b_fn1none
    call bas_wordis
    je .b_fn1hit
.b_fn1nx:
    cmp byte [si], 0                ; ...past this name
    je .b_fn1past
    inc si
    jmp short .b_fn1nx
.b_fn1past:
    inc si                          ; ...and past its NUL
    inc dx
    jmp short .b_fn1try
.b_fn1none:
    pop dx
    jmp short .b_notfn1
.b_fn1hit:
    ; THE INDEX RIDES THE HOST STACK, and it must: this held it in a WORD OF
    ; BSS, and the argument being compiled below can contain another one of
    ; these. `ROUND(FRAC(x-3)*10)` therefore emitted FRAC's index twice -
    ; the inner compile overwrote the outer's - so the outer ROUND ran as a
    ; second FRAC and answered the residue of its own argument. A
    ; recursive-descent compiler cannot keep per-call state in a global, and
    ; .b_bound two screens down was already doing this correctly with its
    ; `which end`.
    mov cx, dx                      ; CX = which function
    pop dx                          ; ...the caller's DX back
    push cx                         ; ...and the index, over the argument
    call bas_bopen
    jc .b_fn1pop
    call bas_c_expr
    cmp byte [bas_bad], 0
    jne .b_fn1pop
    call bas_wantnum                ; ...and its argument IS a number
    jc .b_fn1pop
    call bas_bclose
    jc .b_fn1pop
    mov al, OP_FN1
    call bas_emit
    pop ax
    jmp bas_emit                    ; ...the index, as a byte
.b_fn1pop:
    pop ax
    ret
.b_notfn1:

    ; **AN ARRAY ELEMENT, AND THE NAME DECIDES** (SPEC.md 150.31): a(3) is
    ; an element where a has been DIMmed and a procedure call where it has
    ; not, which is what lets arrays cost no run-time type word.
    call bas_arrfind
    jc .notarray
    SHOUT bas_isstrarr               ; ...and a `$` array is not a number
    jnc .elemstr
    jmp .elem
.b_msel:
    call bas_bopen
    jc .x
    call bas_c_const                ; ...and it must be 0: MENU(-2)..MENU(15)
    jc .x                           ; is the AES message buffer, which this
    or ax, ax                       ; machine has none of
    jnz .b_mselbad
    call bas_bclose
    jc .x
    mov al, OP_MSEL
    jmp bas_emit
.b_mselbad:
    mov si, bas_e_mselarg
    SHOUTR bas_err
.elemstr:
    mov si, bas_e_strtype
    SHOUTR bas_err
.notarray:
    ; --- not a function, so a VARIABLE (SPEC.md 150.4, wave 2) -------------
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
; Each takes ONE piece of text and answers a number, so one body serves and
; the opcode rides in AL - the shape .cmp uses for the six comparisons.
.elem:
    push bx
    call bas_c_subs
    pop bx
    jc .elx
    mov al, OP_ALOAD
    call bas_emit
    cmp byte [bas_bad], 0
    jne .elx
    mov ax, bx
    jmp bas_emit                    ; ...the array's index after it
.elx:
    ret

; --- LBOUND(a) and UBOUND(a), and the dimension is optional -------------
; --- DIM?(a()) (SPEC.md 150.43) ----------------------------------------
; `?` IS PART OF THE NAME and the word reader stops at it, no identifier
; being allowed to hold one - so this arrives as `DIM` and the `?` is tested
; here. Without the `?` it is not this function: a bare `DIM` in an
; expression is nothing, and `DIM` the STATEMENT never reaches here.
;
; The inner brackets are the Compendium's spelling, as ARRAYFILL's and
; ERASE's are, and deliberately not LBOUND's - 150.43 says why.
.b_dimq:
    mov si, [bas_src]
    cmp byte [si], '?'
    jne .notarray                   ; a name beginning DIM, not this
    inc word [bas_src]
    call bas_bopen
    jc .x
    call bas_skipsp
    call bas_word
    jc .b_dqnotarr
    call bas_arrfind
    jc .b_dqnotarr
    push bx
    call bas_bopen                  ; ...the array's OWN empty brackets
    jc .b_dqpop
    call bas_bclose
    jc .b_dqpop
    call bas_bclose                 ; ...and DIM?'s
    pop bx
    jc .x
    mov al, OP_ADIMQ
    call bas_emit
    mov ax, bx
    jmp bas_emit                    ; which array
.b_dqpop:
    pop bx
    ret
.b_dqnotarr:
    mov si, bas_e_arrnotdim
    SHOUTR bas_err
.b_lbound:
    xor dx, dx
    jmp short .b_bound
.b_ubound:
    mov dx, 1
.b_bound:
    push dx
    call bas_bopen
    jc .b_bpop
    call bas_skipsp
    call bas_word
    jc .b_bnotarr
    call bas_arrfind
    jc .b_bnotarr
    push bx
    call bas_bclose
    pop bx
    jc .b_bpop
    mov al, OP_ABOUND
    call bas_emit
    cmp byte [bas_bad], 0
    jne .b_bpop
    mov ax, bx
    call bas_emit                   ; which array...
    cmp byte [bas_bad], 0
    jne .b_bpop
    pop ax                          ; ...and which end
    jmp bas_emit
.b_bpop:
    pop ax
    ret
.b_bnotarr:
    pop ax
    mov si, bas_e_notarr
    SHOUTR bas_err

.b_len:
    mov al, OP_SLEN
    jmp short .b_s1
.b_asc:
    mov al, OP_SASC
    jmp short .b_s1
.b_val:
    mov al, OP_SVAL
.b_s1:
    push ax
    call bas_bopen                  ; '(' , then the text, then ')'
    jc .b_s1x
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_s1x
    call bas_bclose
    jc .b_s1x
    pop ax
    jmp bas_emit
.b_s1x:
    pop ax
    ret

; --- INSTR / RINSTR (SPEC.md 150.47, nodes [160] and [161]) ------------
; NODE [160] LISTS THREE SIGNATURES FOR ONE FUNCTION - INSTR(a$,b$),
; INSTR(a$,b$,x) and INSTR(x,a$,b$) - so both orders are accepted, and the
; FIRST ARGUMENT'S TYPE is what tells them apart: bas_restype after it
; compiles. The two reach ONE opcode through a flags byte rather than two
; opcodes, and a call with no start gets a 1 from bas_emitnum exactly as
; MID$ above gets its 32767.
; MOUSEX / MOUSEY / MOUSEK: no arguments and no parentheses, like INKEY$ and
; for the same reason - the word IS the whole expression (node [210]).
.b_mousex:
    xor al, al
    jmp short .b_mouse
.b_mousey:
    mov al, 1
    jmp short .b_mouse
.b_mousek:
    mov al, 2
.b_mouse:
    push ax
    mov al, OP_MOUSE
    call bas_emit
    pop ax
    cmp byte [bas_bad], 0
    jne .b_mousenone
    jmp bas_emit                    ; ...and which of the three
.b_mousenone:
    ret

; THE NUMERIC HALF, which is an ordinary one-argument function and reaches
; the same bas_fn1tab as ABS and SQR. Node [146]'s rule - "any decimal places
; are ignored", so PRED(2.1) is 1 and not 2 - lives in bas_f_pred, where the
; 16-bit conversion IS the truncation.
.b_npred:
    mov al, FN1_PRED
    jmp short .b_nstep
.b_nsucc:
    mov al, FN1_SUCC
.b_nstep:
    push ax
    call bas_bopen
    jc .b_nstepx
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .b_nstepx
    call bas_wantnum
    jc .b_nstepx
    call bas_bclose
    jc .b_nstepx
    mov al, OP_FN1
    call bas_emit
    cmp byte [bas_bad], 0
    jne .b_nstepx
    pop ax
    jmp bas_emit
.b_nstepx:
    pop ax
    ret

.b_instr:
    xor al, al                      ; forward
    jmp short .b_in
.b_rinstr:
    mov al, SI_BACK
.b_in:
    push ax                         ; the flags, over the whole parse
    call bas_bopen
    jc .b_inx
    call bas_c_rel                  ; ...the first argument, either kind
    cmp byte [bas_bad], 0
    jne .b_inx
    cmp byte [bas_restype], 0
    je .b_inxfirst                  ; a NUMBER there: INSTR(x,a$,b$)
    ; --- INSTR(a$,b$[,x]) ---------------------------------------------
    call bas_bcomma
    jc .b_inx
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_inx
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    je .b_in3
    ; NO START GIVEN - and the two directions want OPPOSITE defaults: INSTR
    ; begins at the front, RINSTR at the far end, so a 1 here searched only
    ; position 1 backwards. 32767 is MID$'s missing length again, and the op
    ; clamps it to the string it is given.
    pop ax
    push ax                         ; ...the flags, read without losing them
    test al, SI_BACK
    mov ax, 1
    jz .b_innox
    mov ax, 32767
.b_innox:
    call bas_emitnum
    cmp byte [bas_bad], 0
    jne .b_inx
    jmp short .b_inend
.b_in3:
    inc word [bas_src]
    call bas_c_rel
    cmp byte [bas_bad], 0
    jne .b_inx
    call bas_wantnum
    jc .b_inx
    jmp short .b_inend
    ; --- INSTR(x,a$,b$) - the same call, the start spelled first -------
.b_inxfirst:
    call bas_wantnum
    jc .b_inx
    pop ax
    or al, SI_XFIRST                ; ...so the op reads the BOTTOM slot
    push ax
    call bas_bcomma
    jc .b_inx
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_inx
    call bas_bcomma
    jc .b_inx
    call bas_c_str
    cmp byte [bas_bad], 0
    jne .b_inx
.b_inend:
    call bas_bclose
    jc .b_inx
    ; AND THE RESULT IS A NUMBER whatever the arguments were. bas_c_rel sets
    ; bas_restype from what it just parsed, so INSTR(a$,b$) left it saying
    ; TEXT - a$ was the last thing it typed - and PRINT then emitted the
    ; STRING print, which read the packed double as an offset and a length,
    ; found length 0, and printed a BLANK LINE the harness drops. The forms
    ; ending in a number were all correct, which is why only half of them
    ; failed. LEN and ASC never needed this: they reach bas_c_str directly
    ; and never let bas_c_rel retype anything.
    mov byte [bas_restype], 0
    mov al, OP_SINSTR
    call bas_emit
    cmp byte [bas_bad], 0
    jne .b_inx
    pop ax
    jmp bas_emit                    ; ...and which search it was
.b_inx:
    pop ax
    ret

.atfn:
    inc word [bas_src]
    call bas_word
    jc .bad
    mov al, 1                       ; ...and a value must come back
    jmp bas_callemit
.fnword:
    call bas_skipsp
    call bas_word
    jc .bad
    mov al, 1
    jmp bas_callemit
.mixed:
    mov si, bas_e_strtype
    SHOUTR bas_err
.noopen:
    mov si, bas_e_paren
    SHOUTR bas_err
.notword:
    cmp al, '"'                     ; **NAME THE ACTUAL MISTAKE**: a piece of
    je .mixed                       ; text where arithmetic wants a number is
                                    ; not "expected a number", it is the one
                                    ; thing bas_wantnum says elsewhere, and
                                    ; `n(1) + "x"` is how it is written
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .bad
    ; fp_atof reads the number out of the source and leaves it in A; SI is
    ; advanced past what it consumed, which is exactly the scanner's job too,
    ; so the two agree by construction rather than by two sets of rules.
    mov si, [bas_src]
    SHOUT fp_atof
    jc .bad
    mov [bas_src], si
    mov al, OP_PUSHN
    call bas_emit
    cmp byte [bas_bad], 0
    jne .x
    mov di, bas_ops
    add di, [bas_opn]
    SHOUT fp_pack_a                  ; the eight bytes, into the op stream
    add word [bas_opn], 8
    cmp word [bas_opn], BAS_OPS_MAX - 10
    jb .x
    mov si, bas_e_long
    SHOUTR bas_err
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
    SHOUTR bas_err
.bad:
    mov si, bas_e_expr
    SHOUTR bas_err

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
; and SPEC.md 150's answer to it is OPTION EXPLICIT, which is decided and not
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
    SHOUT bas_varat                  ; SI = the entry. NOT `mul`: DX is the
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
    SHOUT bas_upper
    mov ah, al
    mov al, [di]
    SHOUT bas_upper
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
    SHOUT bas_varat                  ; SI = the new entry; BX == DX here, the
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
    SHOUT bas_err
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
    SHOUT bas_err
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
    SHOUT bas_err
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
    SHOUT fp_i2a
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
    SHOUT fp_atof                    ; A = the magnitude
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
    SHOUT fp_pack_a
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
    SHOUT bas_err
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
; NOT refuse on a no (SPEC.md 150.22: outside every loop is a legal place to
; be), so the search itself is the shared part.
bas_blkinloop:
    call bas_findloop
    jc .inone
    ret
.inone:
    mov si, bas_e_exitloop
    SHOUT bas_err
    stc
    ret

; --- bas_loopid - AX = WHERE THIS LINE IS, for GOTO's rule ----------------
; The IDENTITY of a loop, not a depth: two sibling loops nest equally deep
; and a jump from one into the other must still be refused. A loop's own top
; offset is unique across the program, so it IS the identity.
;
; **AND A PROCEDURE COUNTS TOO** (SPEC.md 150.23): GFA forbids a GOTO between
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
    SHOUT bas_err
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
; Labels and GOTO (SPEC.md 150.22)
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
    SHOUT bas_upper
    mov ah, al
    mov al, [di]
    SHOUT bas_upper
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
    SHOUT bas_err
    jmp .dout
.dup:
    mov si, bas_e_lbldup
    SHOUT bas_err
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
    SHOUT bas_err
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
    SHOUT bas_err
    jmp .fdone
.wrongloop:
    mov si, bas_e_lblloop
    SHOUT bas_err
    jmp .fdone

; -----------------------------------------------------------------------------
; Procedures, compile side (SPEC.md 150.23)
; -----------------------------------------------------------------------------
bas_prcat:
    push ax
    push cx
    mov ax, bx
    shl ax, 1
    shl ax, 1                       ; i*4
    mov cx, ax
    shl ax, 1                       ; i*8
    add ax, cx                      ; ...+ i*4 = i*12
    add ax, bas_prcs
    mov si, ax
    pop cx
    pop ax
    ret
    times BAS_PRC_SZ - 12 db 0
    times 12 - BAS_PRC_SZ db 0

bas_calat:
    push ax
    push cx
    mov ax, bx
    shl ax, 1
    shl ax, 1
    mov cx, ax                      ; i*4
    shl ax, 1
    shl ax, 1                       ; i*16
    add ax, cx                      ; ...+ i*4 = i*20
    add ax, bas_cals
    mov si, ax
    pop cx
    pop ax
    ret
    times BAS_CAL_SZ - 20 db 0      ; THE SHIFTS ARE THE RECORD'S SIZE and
    times 20 - BAS_CAL_SZ db 0      ; nothing else ties them to it: widening
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
    SHOUT bas_upper
    mov ah, al
    mov al, [di]
    SHOUT bas_upper
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
    SHOUT bas_err
    jmp .dout
.dup:
    mov si, bas_e_prcdup
    SHOUT bas_err
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
    SHOUT fp_i2a
    mov di, bas_ops
    add di, [bas_opn]
    SHOUT fp_pack_a
    add word [bas_opn], 8
    cmp word [bas_opn], BAS_OPS_MAX - 10
    jb .zout
    mov si, bas_e_long
    SHOUT bas_err
.zout:
    pop di
    pop ax
    ret

; --- bas_callemit - emit a call to the procedure named by DI/CX ----------
; in:  AL = 1 if the call site wants a VALUE back (SPEC.md 150.25)
; A name not yet seen is the NORMAL case, so this looks exactly like GOTO's
; forward reference and shares its shape (SPEC.md 150.23).
bas_callemit:
    push ax
    push bx
    push dx
    push si
    mov [bas_calfn], al             ; ...which kind this site can accept
    ; **THE VALUES ARE EMITTED FIRST**, before the OP_CALL, so they are on
    ; the stack when the callee's backwards prologue stores them
    ; (SPEC.md 150.24). bas_callargs preserves the NAME in DI/CX.
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
    mov cx, [si + BAS_PRC_NV]       ; ...and its references point, not copy
    push si
    call bas_varrefs
    pop si
    jc .cvpop
    mov ax, [si + BAS_PRC_OPS]
    pop bx
    call bas_emitw
    jmp .cout
.cvpop:
    pop bx
    jmp .cout
.cwrongn:
    pop bx
    mov si, bas_e_argcount
    SHOUT bas_err
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
    xor bx, bx                      ; ...and where each argument's opcode is
.cslot:
    mov ax, [bas_argsl + bx]
    mov [si + BAS_CAL_SL + bx], ax
    add bx, 2
    cmp bx, BAS_PRC_PMAX*2
    jb .cslot
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
    SHOUT bas_err
    jmp .cout

; --- bas_prcparams - the PROCEDURE's parameter list and its prologue ------
; (SPEC.md 150.24) A parameter is a LOCAL that arrives with a value in it,
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
    mov byte [bas_prcvar], 0        ; ...and none of them by reference yet
    mov [bas_prcnv], dx
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
    mov si, bas_kw_var              ; VAR, and EVERYTHING AFTER IT is by
    call bas_wordis                 ; reference - GFA's entry 238, whose own
    jne .pnotvar                    ; note is that they come last
    mov [bas_prcnv], dx             ; ...so this is where they start
    inc byte [bas_prcvar]
    call bas_skipsp
    call bas_word
    jc .pnoname
.pnotvar:
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
    push dx
    cmp byte [bas_prcvar], 0
    je .pnovar
    sub dx, [bas_prcnv]             ; the ones from VAR onwards
    mov [si + BAS_PRC_NV], dx
    pop dx
    jmp short .pproi
.pnovar:
    xor ax, ax
    mov [si + BAS_PRC_NV], ax
    pop dx
.pproi:
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
    mov al, OP_STORE                ; by value: take what was pushed...
    cmp byte [bas_prcvar], 0
    je .pbyval
    cmp bx, [bas_prcnv]
    jb .pbyval
    mov al, OP_ALIAS                ; ...by reference: point at it instead
.pbyval:
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
    SHOUT bas_err
    jmp .pout
.ptoomany:
    mov si, bas_e_prcargs
    SHOUT bas_err
    jmp .pout
.pdupname:
    mov si, bas_e_prcpdup
    SHOUT bas_err
    jmp .pout
.pnopar:
    mov si, bas_e_argpar
    SHOUT bas_err
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
    xor bx, bx
.aclr:
    mov word [bas_argsl + bx], 0
    add bx, 2
    cmp bx, BAS_PRC_PMAX*2
    jb .aclr
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
    call bas_skipsp                 ; VAR here is GFA's own error
    call bas_word
    jc .anotvar
    mov si, bas_kw_var
    call bas_wordis
    je .avarcall
    mov [bas_src], di               ; ...put the word back
.anotvar:
    push dx
    mov bx, [bas_opn]               ; **WHAT THE ARGUMENT EMITS IS HOW A
    push bx                         ; BARE VARIABLE IS RECOGNISED**: two
    call bas_c_rel                  ; bytes, the first an OP_LOAD. No
    pop bx                          ; parser change, and nothing else can
    pop dx                          ; produce that shape (SPEC.md 150.26)
    cmp byte [bas_bad], 0
    jne .aout
    push bx
    mov ax, [bas_opn]
    sub ax, bx
    cmp ax, 2
    jne .anotbare
    cmp byte [bas_ops + bx], OP_LOAD
    jne .anotbare
    jmp short .akeep
.anotbare:
    xor bx, bx                      ; ...nothing to point at
.akeep:
    mov ax, bx
    pop bx
    mov bx, dx
    shl bx, 1
    mov [bas_argsl + bx], ax
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
    SHOUT bas_err
    jmp .aout
.avarcall:
    mov si, bas_e_varcall
    SHOUT bas_err
    jmp .aout
.anopar:
    mov si, bas_e_argpar
    SHOUT bas_err
    jmp .aout

; --- bas_argsfrom - bas_argsl <- the call record at SI ------------------
bas_argsfrom:
    push ax
    push bx
    xor bx, bx
.aflp:
    mov ax, [si + BAS_CAL_SL + bx]
    mov [bas_argsl + bx], ax
    add bx, 2
    cmp bx, BAS_PRC_PMAX*2
    jb .aflp
    pop bx
    pop ax
    ret

; --- bas_varrefs - the last CX arguments of DX become references -------
; in:  DX = how many values the call hands over, CX = how many of them the
;      procedure takes BY REFERENCE (the LAST ones, GFA's entry 238), and
;      bas_argsl holding where each argument's opcode byte went.
; out: CF=1 and refused by name if one of them has nothing to point at.
;
; ONE BYTE EACH. OP_LOAD and OP_VREF are both an opcode and an index byte,
; so a call compiled before its procedure was seen is corrected in place
; with nothing moved and no second pass over the stream.
bas_varrefs:
    push ax
    push bx
    push cx
    push dx
    or cx, cx
    jz .vok
    mov ax, dx
    sub ax, cx                      ; where the by-reference ones start
.vlp:
    cmp ax, dx
    jae .vok
    mov bx, ax
    shl bx, 1
    mov bx, [bas_argsl + bx]
    or bx, bx
    jz .vnone
    mov byte [bas_ops + bx], OP_VREF
    inc ax
    jmp .vlp
.vok:
    clc
.vout:
    pop dx
    pop cx
    pop bx
    pop ax
    ret
.vnone:
    mov si, bas_e_varname
    SHOUT bas_err
    stc
    jmp .vout

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
    SHOUTR bas_err
.wantsnone:
    mov si, bas_e_wantprc           ; a statement, and its value is stranded
    SHOUTR bas_err

; --- bas_calfix - resolve every call still owed a procedure --------------
; Beside bas_fwdfix, where the program's text ends, for its reason.
bas_calfix:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor dx, dx                      ; DX = which pending call, all the way
.flp:
    cmp dx, [bas_ncal]
    jae .fdone
    mov bx, dx
    call bas_calat                  ; SI = the call's own record
    mov ax, [si + BAS_CAL_LINE]
    mov [bas_line], ax              ; every refusal below names ITS line
    mov di, [si + BAS_CAL_SRC]
    mov cx, [si + BAS_CAL_LEN]
    mov al, [si + BAS_CAL_FN]
    mov [bas_calfn], al             ; ...which bas_kinderr reads
    call bas_argsfrom               ; bas_argsl <- the slots it recorded
    call bas_prcfind                ; BX = the procedure
    jc .noprc
    call bas_prcat                  ; SI = the PROCEDURE's record now
    mov al, [si + BAS_PRC_FN]
    cmp al, [bas_calfn]             ; ...the kind the site can use
    jne .nkind
    push si
    mov bx, dx
    call bas_calat
    mov ax, [si + BAS_CAL_NARG]
    pop si
    cmp ax, [si + BAS_PRC_NP]       ; ...and how many it takes
    jne .nargs
    mov cx, [si + BAS_PRC_NV]       ; ...and which of them point
    mov bx, [si + BAS_PRC_OPS]      ; (the target, before SI is needed again)
    push bx
    push dx
    mov dx, ax
    call bas_varrefs
    pop dx
    pop ax                          ; AX = the body's offset
    jc .fdone
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
.noprc:
    mov si, bas_e_noprc
    SHOUT bas_err
    jmp .fdone
.nkind:
    call bas_kinderr
    jmp .fdone
.nargs:
    mov si, bas_e_argcount
    SHOUT bas_err
    jmp .fdone

; --- bas_frmat - SI = frame BX --------------------------------------------
; --- bas_arrfind - BX = the array named by DI/CX; CF=1 if none -----------
bas_arrfind:
    push ax
    push cx
    push dx
    push si
    push di
    xor bx, bx
    mov dx, [bas_narr]
.scan:
    cmp bx, dx
    jae .miss
    push bx
    push cx
    push di
    SHOUT bas_arrat
    cmp cx, [si + BAS_ARR_LEN]
    jne .nextpop
    mov si, [si + BAS_ARR_SRC]
.cmp:
    or cx, cx
    jz .hitpop
    mov al, [si]
    SHOUT bas_upper
    mov ah, al
    mov al, [di]
    SHOUT bas_upper
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

; --- bas_melem - SI = element [bas_mwi] of array BX ---------------------
; out: CF=1 when the index is past the array's last element. The walk needs
;      this per element and there is nothing else that answers it: a menu
;      array whose final empty string is missing must END rather than read
;      whatever lies above the array in the arena.
; --- bas_swapone - one of SWAP's two operands (SPEC.md 150.34) ----------
; out: AL = the index (a variable's, or an array's), AH bit 0 set when it is
;      an array and bit 1 set when its name ends in '$'. CF=1 and refused by
;      name. BOTH indices fit a byte - BAS_VAR_MAX is 16 and BAS_ARR_MAX is
;      8 - which is what lets one register carry the answer and the flags.
bas_swapone:
    push bx
    push cx
    push dx
    push si
    push di
    call bas_skipsp
    call bas_word                   ; DI/CX = the name
    jc .s1none
    xor dh, dh
    call bas_isstrname
    jc .s1nos
    mov dh, 2                       ; a '$' name, so a string either way
.s1nos:
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], '('
    je .s1arr
    call bas_varfind                ; AX = its index, created if new
    jc .s1out
    mov dl, al
    jmp short .s1done
.s1arr:
    call bas_arrfind                ; BX = which array
    jc .s1noarr
    mov dl, bl
    or dh, 1
    call bas_bopen                  ; `x()` - and the parens stay empty,
    jc .s1out                       ; an element swap being a different
    call bas_bclose                 ; statement nobody has asked for
    jc .s1out
.s1done:
    mov al, dl                      ; AX is not pushed, so it survives the
    mov ah, dh                      ; pops below - and `pop` leaves CF alone
    clc
.s1out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret
.s1none:
    mov si, bas_e_swapname
    SHOUT bas_err
    stc
    jmp .s1out
.s1noarr:
    mov si, bas_e_afillno
    SHOUT bas_err
    stc
    jmp .s1out

; --- bas_c_subs - the (i) or (i,j) after an array's name ---------------
; in:  BX = which array. Emits the subscripts as ORDINARY EXPRESSIONS, in
;      order, so the element ops pop them in reverse.
; out: CF=1 and refused by name, including when the count disagrees with the
;      DIM - which is 150.31's own refusal and not a silent reinterpretation.
bas_c_subs:
    ; **IT RE-ENTERS ITSELF**, and the first version did not survive that:
    ; `many(many(2))` compiles an inner subscript list in the middle of the
    ; outer one, and two compile-time words shared between them left the
    ; outer list counting the inner's subscripts - refused for a count that
    ; disagreed with the DIM. The words are saved across the whole of it;
    ; `push`/`pop` of a memory word is 8086-legal and is the cheapest way to
    ; make a scratch global reentrant.
    push word [bas_acur]
    push word [bas_asubs]
    mov [bas_acur], bx
    mov word [bas_asubs], 0
    call bas_bopen
    jc .suout
.sunext:
    call bas_c_rel                  ; one subscript...
    cmp byte [bas_bad], 0
    jne .subad
    call bas_wantnum
    jc .suout
    inc word [bas_asubs]
    call bas_skipsp
    mov si, [bas_src]
    cmp byte [si], ','
    jne .sudone
    inc word [bas_src]
    cmp word [bas_asubs], BAS_ARR_DIMMAX
    jae .sumis                      ; more than any array here can have, and
    jmp short .sunext               ; .sumis is the message for a count that
.sudone:                            ; does not match a DIM, which this is
    call bas_bclose
    jc .suout
    mov bx, [bas_acur]              ; ...and the count must match the DIM
    SHOUT bas_arrat
    mov ax, [bas_asubs]
    cmp ax, [si + BAS_ARR_DIM]
    jne .sumis
    mov bx, [bas_acur]
    clc
    jmp short .suout
.sumis:
    mov si, bas_e_arrdim
    SHOUT bas_err
.subad:
    stc
.suout:
    pushf
    pop ax
    pop word [bas_asubs]
    pop word [bas_acur]
    push ax
    popf
    ret

; --- bas_c_const - a plain integer literal at the cursor; out AX --------
; out: CF=1 and refused by name if there is not one.
;
; ONE CALLER NOW, AND IT IS `OPTION BASE`. This comment used to read "A
; BOUND IS NOT AN EXPRESSION, for the reason FOR's STEP is not one: the
; compiler has to know the size to lay the array out", which was true of DIM
; until SPEC.md 150.40 moved the array arena to run time. `OPTION BASE` still
; needs a literal, and for a reason of its own: see `.optlate`. (`STEP` is
; still a literal too, but it never came through here - it reads its own sign
; and digits inline. The old sentence compared the two rules rather than
; claiming a shared caller, and this one says which is which, because a true
; sentence under the wrong scope is the trap this chapter has hit twice.)
bas_c_const:
    push bx
    push si
    call bas_skipsp
    xor bx, bx                      ; BX = 1 if it is negative
    mov si, [bas_src]
    cmp byte [si], '-'
    jne .cnpos
    inc bx
    inc word [bas_src]
.cnpos:
    mov si, [bas_src]
    SHOUT fp_atof                    ; A = the magnitude, SI advanced
    jc .cnbad
    mov [bas_src], si
    SHOUT fp_a2i
    jc .cnbad
    or bx, bx
    jz .cnout
    neg ax
.cnout:
    clc
    pop si
    pop bx
    ret
.cnbad:
    mov si, bas_e_expr
    SHOUT bas_err
    stc
    pop si
    pop bx
    ret

; --- bas_dimone - COMPILE one size: `hi` or `lo TO hi` (SPEC.md 150.40) --
; in:  CL = which dimension this is, 0 or 1. out: CF=1 if refused.
;
; It EMITS rather than folds, which is the whole of 150.40: the bound may be
; any expression, so the compiler's job is to put the ops in the stream and
; let OP_DIM read the numbers off the stack.
;
; `lo TO hi` emits two expressions, low then high. `hi` alone emits ONE, and
; OP_DIM takes the low bound from `bas_abase` - and that asymmetry is forced
; rather than chosen: the implicit low bound would have to be pushed BEFORE
; an expression that has already been parsed by the time `TO`'s absence is
; known, and ops are emitted as they parse. So the FORM is recorded instead,
; a bit per dimension in bas_adimf, and travels as OP_DIM's second operand.
;
; IT ANSWERS THE FORM AND THE CALLER PLACES THE BIT, which is not a style
; choice: this took the dimension number in CL and set the bit itself, and CL
; is dead by then - bas_c_expr is a whole expression compiler and clobbers it.
; The bit was therefore never set, so every `lo TO hi` silently became
; `OPTION BASE TO lo`: `DIM c(2 TO 4)` reported LBOUND 2 as 0, and
; `DIM bad(5 TO 1)` was not refused at all because it read as 0 TO 5. The
; caller is the only place that still knows which dimension this was.
bas_dimone:
    push si
    call bas_c_expr                 ; the first bound, whatever it is
    cmp byte [bas_bad], 0
    jne .d1bad
    call bas_skipsp
    call bas_word                   ; ...TO?
    jc .d1just
    mov si, bas_kw_to
    call bas_wordis
    je .d1to
    mov [bas_src], di
.d1just:
    ; `DIM a(8)` is OPTION BASE..8 - NINE slots at base 0, which is the
    ; Compendium's. One expression is in the stream, so the form is 0.
    xor ax, ax
    clc
    jmp short .d1out
.d1to:
    call bas_c_expr                 ; the HIGH bound, on top of the low one
    cmp byte [bas_bad], 0
    jne .d1bad
    mov ax, 1
    clc
    jmp short .d1out
.d1bad:
    stc
.d1out:
    pop si                          ; POP does not touch CF, which is the
    ret                             ; answer above it

; -----------------------------------------------------------------------------
; The string arena (SPEC.md 150.28)
;
; TWO REGIONS GROWING TOWARDS EACH OTHER. Variables' bytes from the bottom
; up; temporaries from the top down, released ALL AT ONCE at each statement
; because OP_LINE is emitted once per statement and the value stack is empty
; between them - so no temporary can be live across one, and a concatenation
; never has to be freed on its own.
;
; A string VALUE is an absolute DS offset and a length, which is why a
; literal needs no allocation at all: it is pushed where it lies in the
; program text, and the text is stable for the whole of a run.
; -----------------------------------------------------------------------------

; --- bas_scopy - CX bytes from SI to DI, both in DS ----------------------
; BY HAND, not `rep movsb`: movsb writes to ES:DI and ES is the KERNEL'S
; segment on entry to any callback (apps/os88api.inc).
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
; A CASE's matched-jumps are a chain for 150.20's reason one construct along:
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
    SHOUT bas_varat
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
    SHOUT bas_err
    stc
    jmp .hout

; --- bas_varat - SI = the address of entry BX --------------------------------
; BAS_VAR_SZ is 12, so this is (i*4) + (i*8) and no `mul`: the one caller that
; wanted mul needed DX, and the interpreter's two want BX and CX kept too.
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
    jb .after
    cmp al, 'Z'
    jbe .take
    cmp al, 'a'
    jb .after
    cmp al, 'z'
    jbe .take
.after:
    ; **A DIGIT OR AN UNDERSCORE IS LEGAL AFTER THE FIRST CHARACTER** and
    ; not as it: `i2` is a name and `2` is a number, and bas_c_fact tells
    ; them apart by the first character alone, so a word that could start
    ; with a digit would swallow every literal in the language. Letters only
    ; is what this read until SPEC.md 150.26's row wanted a procedure called
    ; `outer2`, which was refused as "not a statement this wave knows" - the
    ; dispatch had read `outer` and found `2` where it wanted `(`.
    or cx, cx
    jz .end
    cmp al, '$'                     ; **A SIGIL ENDS A NAME AND IS PART OF
    je .sigil                       ; IT** (SPEC.md 150.4, 150.28): `a$` and
                                    ; `a` are different variables, and the
                                    ; table interns a name by where it is in
                                    ; the program text, so they are already
                                    ; different entries - nothing else is
                                    ; needed to give a name its type. The
                                    ; other four sigils are wave 5's and are
                                    ; not taken here yet.
    cmp al, '_'
    je .take
    cmp al, '0'
    jb .end
    cmp al, '9'
    ja .end
.take:
    inc si
    inc cx
    jmp .l
.sigil:
    inc si                          ; it closes the word
    inc cx
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
    SHOUTR bas_err

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
    SHOUTR bas_err

; -----------------------------------------------------------------------------
; bas_sayfp - A, onto the console, the way this language prints a number
; in:  A = the value; out: nothing; clobbers AX/BX/CX/DX/SI/DI
;
; SEVEN significant digits, which is what the reference prints and therefore
; what this must: a bare literal is a SINGLE (SPEC.md 150.4), SINGLE arithmetic
; stays SINGLE, and seven digits is what a SINGLE is worth. Checked against it
; rather than chosen - `PRINT 1/3` is ` .3333333 ` there, not sixteen digits.
;
; **The leading zero goes.** BASIC prints .3333333 and not 0.3333333, which
; fp_ftoa does not know, so it is trimmed here. And the sign's place and the
; trailing separator are QuickBASIC's, as bas_sayint already does them.
;
; This computes in DOUBLE and prints seven digits, where SPEC.md 150.4 says a
; SINGLE must also NARROW to 32 bits on every store. There is no store yet -
; wave 1c has no variables - so the two agree on every value a program can
; currently produce. The narrowing is owed when `!` variables arrive.
; -----------------------------------------------------------------------------
