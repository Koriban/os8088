; =============================================================================
; os8088 - apps/basic/baslang.inc
;
; THE LANGUAGE (SPEC.md 150): the three stages, over IEEE-754 doubles.
;
; SPEC.md 150.1 keeps the reference implementation's stage boundaries, and not
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
; THE OP STREAM (SPEC.md 150.5) is the shape everything later plugs into. The
; compiler emits postfix, so the interpreter is a stack machine and its inner
; loop is one dispatch on one byte - which is the whole reason 150.5 chose a
; flat array over a tree for an 8086: a tree walk is a recursive descent
; through far pointers at run time.
;
; THAT DISPATCH IS A COMPARE CHAIN and this comment claimed `jmp [table + bx]`
; for three waves while bas_exec never did it. Twelve ops, a run of
; `cmp al, OP_x` / `je`, with the five binary ones grouped behind the
; operand-unpack prologue they share - which is also what makes a table
; awkward rather than obvious. It is honest at twelve; OP_ADD and OP_MUL are
; at the BACK of it behind seven compares, and SPEC.md 150.5 now owes the
; table to wave 2, where the op count stops making a chain defensible.
;
; `/` AND `\` ARE DIFFERENT OPERATORS and both work. `/` is real division -
; BASIC's `/` is floating point even between two integers, so `7/2` is 3.5 -
; and `\` is integer division, which truncates both operands to a signed
; 16-bit INTEGER first, as every BASIC of this line does. Wave 1a shipped `/`
; REFUSED BY NAME rather than answering 3, because a wrong answer that looks
; like a right one is the one thing SPEC.md 150.7's discipline exists to
; prevent; wave 1c brought the numerics and the refusal went.
; =============================================================================

; --- the op codes -------------------------------------------------------------
OP_END      equ 0                   ; stop
OP_PUSHN    equ 1                   ; + EIGHT bytes: a packed double, pushed

; --- the value stack holds DOUBLES (SPEC.md 150.4) --------------------------
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
; one out. SPEC.md 150's truth is QuickBASIC's - **-1 is TRUE and 0 is
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
                                    ; zero it (SPEC.md 150.23)
OP_VREF     equ 28                  ; + an index byte: push the INDEX, not the
                                    ; value - what a bare-variable argument's
                                    ; OP_LOAD is rewritten to when the
                                    ; parameter turns out to be VAR
OP_ALIAS    equ 29                  ; + an index byte: pop an index and point
                                    ; that variable at it (SPEC.md 150.26)
OP_DROP     equ 30                  ; pop a value and forget it (150.27)
; --- strings (SPEC.md 150.28): a value is a DS offset and a length --------
OP_SPUSHL   equ 31                  ; + a word offset and a word length: a
                                    ; literal, pushed WHERE IT LIES in the
                                    ; program text - no copy
OP_SLOAD    equ 32                  ; + an index byte: push that string
OP_SSTORE   equ 33                  ; + an index byte: pop and COPY into it
OP_SCAT     equ 34                  ; pop two, join them in a temporary
OP_SPRINT   equ 35                  ; pop and say it
OP_SCMP     equ 36                  ; pop two, push -1/0/1 as a NUMBER, so
                                    ; 150.18's six relations serve strings
; --- the eight built-ins (SPEC.md 150.29) ---------------------------------
OP_SLEN     equ 37                  ; pop text, push its length
OP_SASC     equ 38                  ; pop text, push its first byte's code
OP_SVAL     equ 39                  ; pop text, push the number at its front
OP_NCHR     equ 40                  ; pop a code, push one character
OP_NSTR     equ 41                  ; pop a number, push it as text
OP_SLEFT    equ 42                  ; pop n and text, push the first n
OP_SRIGHT   equ 43                  ; ...the last n
OP_SMID     equ 44                  ; pop n, start and text, push the slice
; --- arrays (SPEC.md 150.31) ----------------------------------------------
OP_ALOAD    equ 45                  ; + an index byte: pop the subscripts,
                                    ; push that element
OP_ASTORE   equ 46                  ; + an index byte: pop a value and the
                                    ; subscripts, store it
OP_ABOUND   equ 47                  ; + an index byte and a which byte: push
                                    ; LBOUND or UBOUND
OP_ASSTORE  equ 48                  ; + an index byte: pop TEXT and the
                                    ; subscripts, COPY it into that element
; --- clearing, filling, swapping (SPEC.md 150.33, 150.34) -----------------
OP_AFILL    equ 49                  ; + an index byte: pop ONE value and write
                                    ; it into every element of that array
OP_SWAP     equ 50                  ; + TWO index bytes: exchange two
                                    ; variables' eight bytes
OP_ASWAP    equ 51                  ; + TWO index bytes: exchange two arrays'
                                    ; TWELVE descriptor bytes - not sixteen,
                                    ; the first four being the name's place
; --- LSET and RSET (SPEC.md 150.35) --------------------------------------
OP_LSET     equ 52                  ; + an index byte: pop text and justify it
OP_RSET     equ 53                  ; ...LEFT or RIGHT inside that string's
                                    ; EXISTING length, which never changes -
                                    ; so neither of them allocates
; --- the event loop (SPEC.md 150.36) -------------------------------------
OP_ONMENU   equ 54                  ; SUSPEND: save the cursor, post a wake
                                    ; and RETURN out of the interpreter, so
                                    ; the callback ends and the UI task gets
                                    ; its own events delivered
OP_ALERT    equ 55                  ; + an index byte: RE-ENTRANT. First pass
                                    ; raises the alert and suspends AT ITSELF;
                                    ; the resume finds the answer waiting and
                                    ; stores it (SPEC.md 150.37)
OP_MENU     equ 56                  ; + an index byte: build the bar from that
                                    ; string array and install it (150.38)
OP_ONMGOSUB equ 57                  ; + a WORD: the handler a pick resumes in,
                                    ; patched like a call's (SPEC.md 150.38)
OP_MSEL     equ 58                  ; push MENU(0) - which element of m$() was
                                    ; picked (node [300])
OP_N        equ 59                  ; how many there are, table included
OP_BIN_N    equ 11                  ; ...and how many of them are binaries

; --- the scalar variables (SPEC.md 150.4, wave 2) ---------------------------
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
BAS_VAR_SOFF equ 4                  ; ...or, for a `$` name, where its bytes
BAS_VAR_SLEN equ 6                  ; are and how many: SPEC.md 150.28's
                                    ; four-byte value, inside the same eight,
                                    ; so the table does not grow
BAS_VAR_SZ  equ 12

; The string arena, and the one constant that sizes it. 4096 against a 2048
; program, and it is REFUSED BY NAME when it fills rather than wrapping.
BAS_STR_MAX equ 4096

; --- arrays (SPEC.md 150.31) ----------------------------------------------
; A name, its two dimensions' lower bound and count, how many dimensions it
; has, and where its elements start in bas_arena. TWO is the limit here; a
; third is 150.31's "not here, and in this order when it is".
BAS_ARR_MAX   equ 8
BAS_ARR_SRC   equ 0
BAS_ARR_LEN   equ 2
BAS_ARR_LO0   equ 4
BAS_ARR_N0    equ 6
BAS_ARR_LO1   equ 8
BAS_ARR_N1    equ 10
BAS_ARR_DIM   equ 12               ; word: 1 or 2
BAS_ARR_AT    equ 14               ; word: its first element, arena-relative
BAS_ARR_SZ    equ 16               ; a POWER OF TWO, so the indexer shifts

BAS_ARR_BYTES equ 4096             ; 512 elements across the whole program

; --- the OPEN BLOCKS, at compile time only (SPEC.md 150) --------------------
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

; --- labels and GOTO (SPEC.md 150.22) --------------------------------------
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

; --- procedures (SPEC.md 150.23) -------------------------------------------
BAS_PRC_MAX  equ 8
BAS_PRC_SRC  equ 0
BAS_PRC_LEN  equ 2
BAS_PRC_OPS  equ 4                  ; word: where its body begins
BAS_PRC_NP   equ 6                  ; word: how many values it takes
BAS_PRC_FN   equ 8                  ; word: 1 if it RETURNS one
BAS_PRC_NV   equ 10                 ; word: how many of its values are BY
BAS_PRC_SZ   equ 12                 ; REFERENCE, which are the last ones
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
BAS_CAL_SL   equ 12                 ; KIND the call site wanted, likewise;
BAS_CAL_SZ   equ 20                 ; then one slot per argument, holding
                                    ; where its OPCODE byte is so a VAR
                                    ; parameter can rewrite it (150.26)

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
BAS_SAV_ALI  equ 10                 ; ...and what it was pointing AT
BAS_SAV_SZ   equ 12

; --- the register file (SPEC.md 150, BASIC-BINDINGS-PLAN 3) ------------------
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

; --- the COMPILE-TIME half (SPEC.md 150.39) -----------------------------
; Seventy routines, extracted so the SAME TEXT can assemble into either
; the resident image or BASIC.OVL. Nothing moved logically yet: this file
; is included here, so the binary is the same program laid out in a
; different order. The cut itself is the next step, and the closure that
; chose these seventy left only TEN vectors (150.39).
; EITHER IN `.modc` OR IN `.text`, and the Makefile chooses with -D. The
; switch comes from the COMMAND LINE on purpose: SPEC.md 150.39's second trap
; is a `%define` placed after the `%ifdef`s that test it - NASM's
; preprocessor is one pass - and a -D is defined before line 1 of anything,
; so that trap cannot fire here at all.
;
; `vstart=0` because the module is fetched into a claim of its own and its
; labels are offsets from ITS base; NASM coalesces every `.text` fragment and
; puts `.modc` after all of them, so the resident image's recorded length IS
; the cut point and tools/os88ovl.py needs telling nothing (SPEC.md 68.10).
%ifdef BAS_OVERLAY
section .modc vstart=0 align=1
%include "basic/bascomp.inc"
section .text
%else
%include "basic/bascomp.inc"
%endif
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
; i*12 as i*8 + i*4, the index being in CX in both callers.
bas_savat:
    push ax
    push bx
    mov ax, cx
    shl ax, 1
    shl ax, 1
    mov bx, ax                      ; i*4
    shl ax, 1                       ; i*8
    add ax, bx                      ; ...+ i*4 = i*12
    add ax, bas_savs
    mov di, ax
    pop bx
    pop ax
    ret
    times BAS_SAV_SZ - 12 db 0
    times 12 - BAS_SAV_SZ db 0

; --- bas_dosave - BX = a variable: push it on the save stack and zero it --
; A LOCAL is exactly this (SPEC.md 150.23): the old value goes where RETURN
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
    mov al, [bas_alias + bx]        ; the alias is saved BESIDE the value and
    mov [di + BAS_SAV_ALI], al      ; restored with it, so a local inside a
    mov [bas_alias + bx], bl        ; procedure called by reference is its
                                    ; own again (SPEC.md 150.26)
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
    mov al, [di + BAS_SAV_ALI]
    mov [bas_alias + bx], al
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

; -----------------------------------------------------------------------------
; Arrays, compile side (SPEC.md 150.31)
; -----------------------------------------------------------------------------
bas_arrat:
    push ax
    mov ax, bx
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, bas_arrs
    mov si, ax
    pop ax
    ret
    times BAS_ARR_SZ - 16 db 0
    times 16 - BAS_ARR_SZ db 0

bas_melem:
    push ax
    push bx
    push cx
    push dx
    push bx
    call bas_arrat                  ; SI = the array's entry
    pop bx
    mov ax, [bas_mwi]
    mov cx, [si + BAS_ARR_N0]
    cmp word [si + BAS_ARR_DIM], 2
    jne .me1
    mov dx, cx
    mov ax, [si + BAS_ARR_N1]
    mul dx
    mov cx, ax                      ; a two-dimensional m$() is walked flat
    mov ax, [bas_mwi]
.me1:
    cmp ax, cx
    jae .memiss
    mov dx, [si + BAS_ARR_AT]
    shl ax, 1
    shl ax, 1
    shl ax, 1                       ; eight bytes an element (150.31)
    add ax, dx
    add ax, bas_arena
    mov si, ax
    clc
    jmp short .meout
.memiss:
    stc
.meout:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- bas_mcopy - SI's string into bas_mtext, NUL-terminated -------------
; in:  SI = a value slot (offset at [si], length at [si+2])
; out: AX = where the copy begins, CF=1 if the arena is full. The copy is
;      the whole point: see BAS_MEN_TEXT's comment in basic.asm.
bas_mcopy:
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, [si]
    mov cx, [si + 2]
    mov ax, [bas_mwtop]
    mov dx, ax
    add dx, cx
    inc dx                          ; ...and its NUL
    cmp dx, BAS_MEN_TEXT
    ja .mcfull
    mov di, bas_mtext
    add di, ax                      ; DI = where it goes, and DI ADVANCES:
    push ax                         ; only BX, SI, DI and BP can index, so
    mov dx, cx                      ; `[di + ax]` is not an address at all
.mclp:
    or cx, cx
    jz .mcend
    mov al, [bx]
    mov [di], al
    inc bx
    inc di
    dec cx
    jmp short .mclp
.mcend:
    mov byte [di], 0
    inc dx                          ; ...and its NUL
    add [bas_mwtop], dx
    pop ax
    add ax, bas_mtext               ; a POINTER, which is what the set holds
    clc
    jmp short .mcout
.mcfull:
    stc
.mcout:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; --- bas_menpick - a pick on one of the PROGRAM's menus -----------------
; in:  AH = the bar menu (2 and up are the program's), AL = the item
; out: nothing. Slice 3a has nowhere to send it: ON MENU GOSUB is next, and
;      until it exists a pick is recorded in MENU(0) and does nothing else -
;      which is better than falling into File's handler, where `ah >= 2`
;      used to land.
bas_menpick:
    push ax
    push bx
    push cx
    push dx
    push di
    cmp word [bas_mon], 0
    je .mpout                       ; no program bar: a stale pick, ignored
    mov bl, al                      ; the ITEM, before AL is reused
    mov al, ah
    sub al, 2                       ; ...and the program's menu, 0-based
    xor ah, ah
    mov cl, BAS_MEN_ITEMS*2
    mul cl                          ; AX = the menu's row in bas_midx
    mov di, ax
    xor bh, bh
    shl bx, 1
    add di, bx
    mov ax, [bas_midx + di]
    mov [bas_msel], ax              ; MENU(0): WHICH ELEMENT of m$() it was,
                                    ; which is what node [300] answers with
    ; --- and into the handler, which costs NO new machinery -------------
    ; The program is suspended at an ON MENU with its cursor saved. A frame
    ; whose RETURN is that cursor, and a cursor set to the handler, is
    ; exactly what OP_CALL builds for a GOSUB (150.23) - so OP_RET carries
    ; the handler back to the ON MENU with nothing added to the
    ; interpreter. The wake is what resumes it, keeping ONE resume path.
    cmp word [bas_mhand], 0
    je .mpout
    cmp word [bas_susp], 0
    je .mpout                       ; nothing waiting: a pick with no
    push si                         ; program running is not an error
    mov bx, [bas_nfrm]
    cmp bx, BAS_FRM_MAX
    jae .mppop
    call bas_frmat                  ; SI = the frame
    mov ax, [bas_nsav]
    mov [si + BAS_FRM_SAVE], ax
    mov ax, [bas_scur]
    mov [si + BAS_FRM_RET], ax      ; ...the ON MENU's own continuation
    inc word [bas_nfrm]
    mov ax, [bas_mhand]
    mov [bas_scur], ax
    mov bx, [bas_wn]
    call OSAPI_WM_WAKE
.mppop:
    pop si
.mpout:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- bas_alset - ALERT's button$ to one of the five sets ----------------
; in:  DI = the value slot holding it (offset at [di], length at [di+2])
; out: AX = the OS88UI_A* set, CF=1 and no match. Preserves everything else.
;
; CASE-INSENSITIVE AND WHOLE: `button$` is an sexp, so this is a RUN-TIME
; match and a prefix must not do - `OK` is a set and so is `OK|Cancel`.
; THE OFFSET AND LENGTH RIDE ON THE STACK because only BX, SI and DI can
; address memory on an 8086 and three pointers are wanted at once: the
; pattern, the program's bytes, and the table.
bas_alset:
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, [di]
    mov dx, [di + 2]
    push bx
    push dx
    xor di, di                      ; DI = the table's offset
.asnext:
    cmp di, BAS_ALSETS*4
    jae .asmiss
    mov si, [bas_altab + di]
    pop dx
    pop bx
    push bx
    push dx
    mov cx, dx
.ascmp:
    mov al, [si]
    or al, al
    jz .asend
    or cx, cx
    jz .asno                        ; the program's string ran out first
    mov ah, al
    mov al, [bx]
    call bas_upper                  ; the pattern is stored upper-case
    cmp al, ah
    jne .asno
    inc si
    inc bx
    dec cx
    jmp short .ascmp
.asend:
    or cx, cx
    jnz .asno                       ; ...or is longer than the pattern
    mov ax, [bas_altab + di + 2]
    add sp, 4
    clc
    jmp short .asout
.asno:
    add di, 4
    jmp short .asnext
.asmiss:
    add sp, 4
    stc
.asout:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; --- bas_almake - ALERT's message$ into bas_almsg -----------------------
; in:  DI = the value slot holding it
; out: CF=1 if it holds a '|', the dialog being ONE line (SPEC.md 150.37).
;      Otherwise bas_almsg holds it, NUL-terminated and CLIPPED to
;      OS88UI_AMAX - clipping is what the Compendium's own alert does to an
;      over-long line, so it is not refused; the LINES are the surprise.
; IT KEEPS SCANNING AFTER THE CLIP, so a '|' past character 34 is still
; found: otherwise the refusal would depend on where in the string it sat.
bas_almake:
    push ax
    push bx
    push cx
    push si
    push di
    mov si, [di]
    mov cx, [di + 2]
    mov di, bas_almsg
    xor bx, bx
.amlp:
    or cx, cx
    jz .amdone
    mov al, [si]
    cmp al, '|'
    je .ambar
    cmp bx, OS88UI_AMAX
    jae .amskip
    mov [di + bx], al
    inc bx
.amskip:
    inc si
    dec cx
    jmp short .amlp
.amdone:
    mov byte [di + bx], 0
    clc
    jmp short .amout
.ambar:
    stc
.amout:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; --- bas_aldone - os88ui_ask's completion (SPEC.md 150.37) --------------
; in:  AL = the 0-based button index, or OS88UI_ACANCEL when the alert was
;      DISMISSED; the gfx lock is held and SI is our window
; out: nothing; the answer is stored and a wake posted
;
; IT DOES NOT RESUME HERE, though the lock is held and it could. One resume
; path is worth more than a saved wake: resuming from the completion would
; nest the host stack one alert deeper every time a program answered an
; alert with another alert, and 150.36's whole shape is that a suspension
; UNWINDS before it comes back.
bas_aldone:
    push ax
    push bx
    cmp al, OS88UI_ACANCEL
    je .adcan
    xor ah, ah
    inc ax                          ; 0-based here, 1..3 in the language
    jmp short .adset
.adcan:
    xor ax, ax                      ; DISMISSED: 0, which no button maps to
.adset:
    mov [bas_alans], ax
    mov word [bas_alpend], 1
    mov bx, [bas_wn]
    call OSAPI_WM_WAKE
    pop bx
    pop ax
    ret

bas_scopy:
    push ax
    push cx
    push si
    push di
    or cx, cx
    jz .cdone
.clp:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    dec cx
    jnz .clp
.cdone:
    pop di
    pop si
    pop cx
    pop ax
    ret

; --- bas_stmpalloc - CX bytes of TEMPORARY; out AX = a DS offset ---------
; out: CF=1 and refused by name if the two regions would meet
bas_stmpalloc:
    push bx
    push cx
    push si
    cmp cx, BAS_STR_MAX
    ja .tlong
    call .take
    jnc .tout
    call bas_scompact               ; ...which may be enough on its own
    call .take
    jnc .tout
    mov si, bas_e_strfull
    call bas_err
    stc
.tout:
    pop si
    pop cx
    pop bx
    ret
.take:
    mov ax, [bas_sttop]
    sub ax, cx
    cmp ax, [bas_svtop]             ; ...the variables' region is below
    jb .tno
    mov [bas_sttop], ax
    add ax, bas_sarena
    clc
    ret
.tno:
    stc
    ret
.tlong:
    mov si, bas_e_strlong
    call bas_err
    stc
    jmp .tout

; --- bas_svaralloc - CX bytes for a VARIABLE; out AX = a DS offset -------
bas_svaralloc:
    push bx
    push cx
    push si
    cmp cx, BAS_STR_MAX
    ja .vlong
    call .take
    jnc .vout
    call bas_scompact
    call .take
    jnc .vout
    mov si, bas_e_strfull
    call bas_err
    stc
.vout:
    pop si
    pop cx
    pop bx
    ret
.take:
    mov bx, [bas_svtop]
    mov ax, bx
    add ax, cx
    cmp ax, [bas_sttop]
    ja .vno
    mov [bas_svtop], ax
    mov ax, bx                      ; ...where it starts, absolute
    add ax, bas_sarena
    clc
    ret
.vno:
    stc
    ret
.vlong:
    mov si, bas_e_strlong
    call bas_err
    stc
    jmp .vout

; --- bas_aelem - SI = array BX's element, subscripts on the stack -------
; in:  BX = which array, DI = one past the top of the value stack with the
;      subscripts pushed in order.
; out: SI = the element's address, DI dropped by the subscript count,
;      CF=1 and refused by name if a subscript is outside the array.
bas_aelem:
    push ax
    push bx
    push cx
    push dx
    push bx
    call bas_arrat                  ; SI = the entry
    pop bx
    push si                         ; the entry, through the pops below
    mov cx, [si + BAS_ARR_DIM]
    cmp cx, 2
    je .ae2
    ; --- one dimension ------------------------------------------------
    call bas_asub                   ; AX = the subscript, DI -= a slot
    jc .aebad
    pop si
    push si
    sub ax, [si + BAS_ARR_LO0]
    js .aerange
    cmp ax, [si + BAS_ARR_N0]
    jae .aerange
    jmp short .aeat
.ae2:
    call bas_asub                   ; the SECOND subscript is on top
    jc .aebad
    pop si
    push si
    mov dx, ax
    sub dx, [si + BAS_ARR_LO1]
    js .aerange
    cmp dx, [si + BAS_ARR_N1]
    jae .aerange
    call bas_asub                   ; ...then the first
    jc .aebad
    pop si
    push si
    sub ax, [si + BAS_ARR_LO0]
    js .aerange
    cmp ax, [si + BAS_ARR_N0]
    jae .aerange
    mul word [si + BAS_ARR_N1]      ; row-major: i*n1 + j
    add ax, dx
.aeat:
    shl ax, 1                       ; eight bytes an element
    shl ax, 1
    shl ax, 1
    pop si
    add ax, [si + BAS_ARR_AT]
    add ax, bas_arena
    mov si, ax
    clc
.aeout:
    pop dx
    pop cx
    pop bx
    pop ax
    ret
.aerange:
    pop si
    mov si, bas_e_arrrange
    call bas_err
    stc
    jmp .aeout
.aebad:
    pop si
    stc
    jmp .aeout

; --- bas_asub - pop one subscript as a 16-bit integer; out AX -----------
bas_asub:
    push bx
    push cx
    push si
    sub di, BAS_SLOT
    mov si, di
    call fp_unpack_a
    call fp_a2i
    pop si
    pop cx
    pop bx
    ret

; --- bas_sarg1 - pop the top slot as a 16-bit count; out AX -------------
; in:  DI = one past the top slot. out: DI -= one slot, AX = the number,
;      CF=1 and refused by name if it is negative.
; A count is a count: SPEC.md 150.29 clamps a count that is too LARGE and
; refuses one that is negative, because a negative length is a program
; saying something it cannot mean.
bas_sarg1:
    push bx
    push cx
    push si
    sub di, BAS_SLOT
    mov si, di
    call fp_unpack_a
    call fp_a2i
    jc .a1bad
    or ax, ax
    js .a1bad
    clc
.a1out:
    pop si
    pop cx
    pop bx
    ret
.a1bad:
    mov si, bas_e_negcount
    call bas_err
    stc
    jmp .a1out

; --- bas_sayrun - CX bytes at SI onto the console -----------------------
; NOT con_say: that stops at a NUL, and a string here is counted, so a NUL
; is an ordinary character in it (CHR$(0) is a value a program may hold).
bas_sayrun:
    push ax
    push cx
    push si
    or cx, cx
    jz .rdone
.rlp:
    mov al, [si]
    call con_write
    inc si
    dec cx
    jnz .rlp
.rdone:
    pop si
    pop cx
    pop ax
    ret

; --- bas_scmpbytes - SI/CX against BX/AX; out AX = -1, 0 or 1 -----------
; BYTE ORDER, NOT LOCALE (SPEC.md 150.28): "Z" < "a" because 90 < 97, and a
; shorter string that is a prefix of a longer one sorts first.
bas_scmpbytes:
    push bx
    push cx
    push dx
    push si
    push di
    mov di, bx                      ; DI = the right-hand bytes
    mov dx, ax                      ; DX = its length
.clp:
    or cx, cx
    jz .lend
    or dx, dx
    jz .rshort
    mov al, [si]
    mov bl, [di]
    cmp al, bl
    jb .less
    ja .more
    inc si
    inc di
    dec cx
    dec dx
    jmp .clp
.lend:
    or dx, dx                       ; the left ran out...
    jnz .less                       ; ...and the right did not
    xor ax, ax                      ; both: equal
    jmp .cout
.rshort:
    mov ax, 1
    jmp .cout
.less:
    mov ax, -1
    jmp .cout
.more:
    mov ax, 1
.cout:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; --- bas_isstrvar - is variable BX a `$` name? --------------------------
; out: CF=0 if it is. THE TYPE IS THE SPELLING (SPEC.md 150.28), so this is
; the last character of the name where it sits in the program text, and no
; field in the entry says it.
bas_isstrvar:
    push ax
    push bx
    push cx
    push si
    call bas_varat
    mov cx, [si + BAS_VAR_LEN]
    or cx, cx
    jz .isno                        ; a hidden entry (150.17) is a number
    mov si, [si + BAS_VAR_SRC]
    add si, cx
    dec si
    cmp byte [si], '$'
    jne .isno
    clc
.isout:
    pop si
    pop cx
    pop bx
    pop ax
    ret
.isno:
    stc
    jmp .isout

; -----------------------------------------------------------------------------
; Compaction's ROOTS (SPEC.md 150.32)
;
; A root is a pointer to an (offset, length) WORD PAIR, and that is the only
; thing the walk needs to know about it - which is why one abstraction covers
; both kinds: a string variable's BAS_VAR_SOFF and BAS_VAR_SLEN are adjacent
; words, and so are a string array element's first two. 150.28's four-byte
; value earns its keep here.
;
; Root 0..BAS_VAR_MAX-1 are the variables. Above that they are the elements
; of the string arrays, each array's in turn, which gives every element a
; stable number without a table.
; -----------------------------------------------------------------------------

; --- bas_isstrarr - does array BX hold text? CF=0 if it does -------------
bas_isstrarr:
    push ax
    push bx
    push cx
    push si
    call bas_arrat
    mov cx, [si + BAS_ARR_LEN]
    or cx, cx
    jz .iano
    mov si, [si + BAS_ARR_SRC]
    add si, cx
    dec si
    cmp byte [si], '$'
    jne .iano
    clc
.iaout:
    pop si
    pop cx
    pop bx
    pop ax
    ret
.iano:
    stc
    jmp .iaout

; --- bas_arrcount - AX = how many elements array BX has ------------------
bas_arrcount:
    push bx
    push dx
    push si
    call bas_arrat
    mov ax, [si + BAS_ARR_N0]
    mul word [si + BAS_ARR_N1]
    pop si
    pop dx
    pop bx
    ret

; --- bas_nroots - AX = how many roots there are now ---------------------
bas_nroots:
    push bx
    push cx
    push dx
    mov dx, BAS_VAR_MAX
    xor bx, bx
.nrlp:
    cmp bx, [bas_narr]
    jae .nrdone
    call bas_isstrarr
    jc .nrnext
    call bas_arrcount
    add dx, ax
.nrnext:
    inc bx
    jmp .nrlp
.nrdone:
    mov ax, dx
    pop dx
    pop cx
    pop bx
    ret

; --- bas_rootat - root BX; out DI = its (offset,length) pair ------------
; out: AX = its arena-relative offset, or 0xFFFF for "owns no bytes" -
;      not a string, never assigned, or EMPTY (150.28's rule, which the
;      walk needs or it never terminates).
bas_rootat:
    push bx
    push cx
    push dx
    push si
    cmp bx, BAS_VAR_MAX
    jb .rvar
    sub bx, BAS_VAR_MAX
    xor dx, dx                      ; DX = which array
.ralp:
    cmp dx, [bas_narr]
    jae .rnone                      ; past the end: nothing
    push bx
    mov bx, dx
    call bas_isstrarr
    jc .ranext
    call bas_arrcount               ; AX = its element count
    pop bx
    cmp bx, ax
    jb .rafound
    sub bx, ax
    inc dx
    jmp .ralp
.ranext:
    pop bx
    inc dx
    jmp .ralp
.rafound:
    ; element BX of array DX
    mov cx, bx
    mov bx, dx
    call bas_arrat
    mov ax, cx
    shl ax, 1
    shl ax, 1
    shl ax, 1                       ; eight bytes an element
    add ax, [si + BAS_ARR_AT]
    add ax, bas_arena
    mov di, ax
    jmp short .rgot
.rvar:
    call bas_varat
    add si, BAS_VAR_SOFF
    mov di, si
.rgot:
    cmp word [di + 2], 0            ; a length of zero owns no bytes
    je .rnone
    mov ax, [di]
    or ax, ax
    jz .rnone
    sub ax, bas_sarena
    jmp short .rout
.rnone:
    mov ax, 0xFFFF
.rout:
    pop si
    pop dx
    pop cx
    pop bx
    ret

; --- bas_svoff - AX = variable BX's arena offset, or 0xFFFF --------------
; 0xFFFF for "owns no bytes in the arena", so a caller can skip it without a
; second test: not a string, never assigned, or EMPTY.
;
; **EMPTY MATTERS.** A zero-length string owns nothing, but it does hold an
; offset, and compaction chooses the lowest offset at or above its write
; pointer and then advances the pointer by the LENGTH - so an empty string
; is chosen, copied (nothing), leaves the pointer where it was, and is
; chosen again: compaction never returns. `e$ = ""` followed by enough
; assignments to fill the arena is all it takes, and it hangs the whole
; package rather than refusing.
bas_svoff:
    push bx
    push si
    call bas_isstrvar
    jc .ono
    call bas_varat
    cmp word [si + BAS_VAR_SLEN], 0
    je .ono
    mov ax, [si + BAS_VAR_SOFF]
    or ax, ax
    jz .ono
    sub ax, bas_sarena              ; arena-relative, for comparing
    pop si
    pop bx
    ret
.ono:
    mov ax, 0xFFFF
    pop si
    pop bx
    ret

; --- bas_scompact - slide the variables' region down over its garbage ----
; ONE OWNER PER STRING is what makes this a slide and not a trace: an
; assignment COPIES (SPEC.md 150.28), so no two variables share bytes. The
; roots are therefore the string variables, one each, and the walk is
; "repeatedly take the lowest one not packed yet" - sixteen variables, so
; two passes of sixteen rather than a sort.
;
; **ONLY THE VARIABLES' REGION MOVES.** This is reached from an allocation
; that failed, which happens inside an op, so a TEMPORARY may well be live
; and holding an offset; the temporaries' region is not touched here, so
; that offset stays true.
bas_scompact:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor dx, dx                      ; DX = where the next one goes
.sweep:
    mov cx, 0xFFFF                  ; the lowest offset at or above DX
    xor bx, bx
.look:
    push bx
    call bas_nroots
    pop bx
    cmp bx, ax
    jae .chose
    call bas_rootat                 ; AX = its offset, DI = its pair
    cmp ax, 0xFFFF
    je .looknext
    cmp ax, dx
    jb .looknext                    ; already packed below
    cmp ax, cx
    jae .looknext
    mov cx, ax
.looknext:
    inc bx
    jmp .look
.chose:
    cmp cx, 0xFFFF
    je .packed
    xor bx, bx                      ; ...and WHICH root that was
.who:
    push bx
    call bas_nroots
    pop bx
    cmp bx, ax
    jae .packed                     ; (cannot happen: CX came from one)
    call bas_rootat
    cmp ax, cx
    je .move
    inc bx
    jmp .who
.move:
    ; DI = the (offset, length) pair, wherever it lives - a variable's
    ; entry or an array element (SPEC.md 150.32), and the walk does not
    ; care which
    mov cx, [di + 2]
    push di
    mov si, [di]
    mov di, dx
    add di, bas_sarena
    call bas_scopy
    mov ax, di
    pop di
    mov [di], ax
    add dx, cx
    jmp .sweep
.packed:
    mov [bas_svtop], dx
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

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
    times BAS_VAR_SZ - 12 db 0      ; THE SHIFTS ARE THE RECORD'S SIZE, and
    times 12 - BAS_VAR_SZ db 0      ; this was the one table of eight with no
                                    ; such pair - the widest-used of them,
                                    ; where an added field would have made
                                    ; entry 1 start inside entry 0 and the
                                    ; symptom would have named whatever read
                                    ; it second (bas_calat's lesson, 150.24)

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
    jmp short .next
; --- bas_exec.resume - carry on from an ON MENU (SPEC.md 150.36) --------
; TWO WORDS ARE THE WHOLE MACHINE at an op boundary, which is a property of
; this interpreter and not luck: OP_CALL stores its return as a
; bas_ops-relative offset in a bss frame rather than pushing it, so nothing
; of a program's state rides the host stack across a `.next`. That is now a
; RULE for every opcode - one that left something pushed would make a
; program unwakeable, and the symptom would be a hang rather than an opcode
; that reads wrong.
;
; Called from bas_onwake with the gfx lock HELD and [bas_susp] already
; cleared.
.resume:
    mov si, [bas_scur]
    add si, bas_ops
    mov di, [bas_sdi]
.next:
    ; ONE INDEXED JUMP (SPEC.md 150.5), not a run of compares. The chain this
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
    ; **AND EVERY TEMPORARY GOES WITH IT** (SPEC.md 150.28). The value stack
    ; is empty between statements, so nothing can be holding one; releasing
    ; them all here is what keeps a concatenation from ever needing to be
    ; freed on its own, and it costs one store on an op that was already
    ; emitted once per statement.
    mov word [bas_sttop], BAS_STR_MAX
    jmp .next

; --- OP_JF / OP_JMP: the branch (SPEC.md 150) -------------------------------
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

; --- OP_CALL / OP_RET / OP_LOCAL (SPEC.md 150.23) --------------------------
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

; --- OP_VREF: push the INDEX of a variable, not its value ---------------
; An ordinary number, so the value stack needs no second kind of slot and
; nothing else in the interpreter learns about references (SPEC.md 150.26).
.vrefop:
    cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT
    jae .over
    push bx
    mov bl, [si]
    inc si
    xor bh, bh
    mov bl, [bas_alias + bx]        ; **WHAT THE NAME ALREADY RESOLVES TO**,
                                    ; not the name's own index: passing a VAR
                                    ; parameter ON to a second call must hand
                                    ; over the ORIGINAL variable, or the
                                    ; chain is one link long and the inner
                                    ; procedure writes the outer's parameter
                                    ; instead of the caller's variable. It
                                    ; also keeps the table one deep, so
                                    ; OP_LOAD and OP_STORE resolve with one
                                    ; byte-read and never a loop.
    push si
    mov ax, bx
    call fp_i2a
    call fp_pack_a                  ; A -> DS:DI, which is the stack's top
    pop si
    pop bx
    add di, BAS_SLOT
    jmp .next

; --- OP_ALIAS: point a variable at the one whose index is on the stack --
.aliasop:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push bx
    mov bl, [si]                    ; the parameter...
    inc si
    xor bh, bh
    push si
    sub di, BAS_SLOT
    mov si, di
    call fp_unpack_a
    call fp_a2i                     ; ...and the variable it points at
    mov [bas_alias + bx], al
    pop si
    pop bx
    jmp .next

.dropop:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    sub di, BAS_SLOT
    jmp .next

; --- the string ops (SPEC.md 150.28) --------------------------------------
; A string on the value stack is the slot's FIRST TWO WORDS: a DS offset and
; a length. The other four bytes of the slot are not read, and no slot says
; which kind it holds - the compiler knows every expression's type from the
; names in it, so a numeric op and a string op never meet.
.spushl:
    cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT
    jae .over
    mov ax, [si]                    ; where it lies in the program text...
    mov [di], ax
    mov ax, [si + 2]                ; ...and how long it is
    mov [di + 2], ax
    add si, 4
    add di, BAS_SLOT
    jmp .next

; **A READ TAKES A COPY**, and that is not an accident (SPEC.md 150.28).
; Pushing the variable's own offset would put a reference to the VARIABLES'
; region on the value stack - and an allocation later in the same expression
; may compact that region and slide those bytes out from under it. Copying
; here makes the invariant simple and checkable: every string on the value
; stack is a literal in the program text or a temporary, and the variables'
; region is referenced only by the variable table.
.sload:
    cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT
    jae .over
    push bx
    push si
    mov bl, [si]
    xor bh, bh
    mov bl, [bas_alias + bx]        ; ...through the alias, as .vload does
    call bas_varat
    mov cx, [si + BAS_VAR_SLEN]     ; its length cannot change...
    push cx
    call bas_stmpalloc              ; AX = a temporary of its own
    pop cx
    jc .slpop
    mov [di], ax
    mov [di + 2], cx
    push di
    mov di, ax
    ; **ITS OFFSET IS READ AFTER THE ALLOCATION, NOT BEFORE.** The
    ; allocation may compact the variables' region and slide this very
    ; string down - which is the hazard that made a read take a copy in the
    ; first place, walked into again one line further in. A 200-iteration
    ; `c$ = "y" + c$` is what found it.
    call bas_varat
    mov si, [si + BAS_VAR_SOFF]
    call bas_scopy
    pop di
    pop si                          ; the op cursor
    inc si                          ; ...past the index byte
    pop bx
    add di, BAS_SLOT
    jmp .next
.slpop:
    pop si
    pop bx
    jmp .done

; **THE STORE COPIES THE BYTES**, which is what gives every arena string
; exactly one owner and makes compaction a slide (SPEC.md 150.28).
.sstore:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    sub di, BAS_SLOT                ; DI = the slot holding the value
    push bx
    push si                         ; the op cursor, out of varat's way
    mov bl, [si]
    xor bh, bh
    mov bl, [bas_alias + bx]
    mov cx, [di + 2]                ; its length...
    call bas_svaralloc              ; ...and room of its own
    jc .sspop
    push di
    push ax
    mov si, [di]                    ; the bytes, wherever they are
    mov cx, [di + 2]
    mov di, ax
    call bas_scopy
    pop ax
    pop di
    mov cx, [di + 2]
    push di
    call bas_varat                  ; SI = the entry; BX is still its index
    mov [si + BAS_VAR_SOFF], ax
    mov [si + BAS_VAR_SLEN], cx
    pop di
    pop si                          ; ...and the op cursor back
    inc si                          ; past the index byte
    pop bx
    jmp .next
.sspop:
    pop si
    pop bx
    jmp .done

.scat:
    cmp di, bas_stk + 2*BAS_SLOT
    jb .under
    push bx
    push si
    sub di, 2*BAS_SLOT              ; DI = the left one's slot
    mov cx, [di + 2]
    add cx, [di + BAS_SLOT + 2]     ; the joined length
    call bas_stmpalloc
    jc .scpop
    mov bx, ax                      ; BX = where it goes
    push bx
    mov si, [di]                    ; the left half
    mov cx, [di + 2]
    push di
    mov di, bx
    call bas_scopy
    pop di
    pop bx
    push bx
    add bx, [di + 2]                ; ...then the right half after it
    mov si, [di + BAS_SLOT]
    mov cx, [di + BAS_SLOT + 2]
    push di
    mov di, bx
    call bas_scopy
    pop di
    pop bx
    mov cx, [di + 2]
    add cx, [di + BAS_SLOT + 2]
    mov [di], bx
    mov [di + 2], cx
    add di, BAS_SLOT                ; ...one slot where two were
    pop si
    pop bx
    jmp .next
.scpop:
    pop si
    pop bx
    jmp .done

; --- the eight built-ins at run time (SPEC.md 150.29) --------------------
; Each of the five that answers text ALLOCATES A TEMPORARY, which is what
; makes `a$ = MID$(a$, 2)` correct: the result cannot alias its own source.
.slen:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push si
    sub di, BAS_SLOT
    mov ax, [di + 2]
    call fp_i2a
    call fp_pack_a
    add di, BAS_SLOT
    pop si
    jmp .next

.sasc:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push si
    sub di, BAS_SLOT
    cmp word [di + 2], 0
    je .ascempty
    mov si, [di]
    mov al, [si]
    xor ah, ah
    call fp_i2a
    call fp_pack_a
    add di, BAS_SLOT
    pop si
    jmp .next
.ascempty:
    pop si
    mov si, bas_e_ascempty
    jmp bas_err

; **A COPY WITH A NUL AFTER IT** (SPEC.md 150.29): fp_atof reads to a
; terminator and a string here is counted, so the parser would run off the
; end of the last one in the arena.
.sval:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push bx
    push si
    sub di, BAS_SLOT
    mov cx, [di + 2]
    inc cx                          ; ...room for the NUL
    call bas_stmpalloc
    jc .svalx
    mov bx, ax
    push bx
    mov si, [di]
    mov cx, [di + 2]
    push di
    mov di, bx
    call bas_scopy
    add di, cx
    mov byte [di], 0
    pop di
    pop bx
    mov si, bx
    call fp_atof                    ; A = the number at the front...
    jnc .svalok
    xor ax, ax                      ; ...or ZERO, which is the reference's
    call fp_i2a                     ; answer and not a refusal
.svalok:
    call fp_pack_a
    add di, BAS_SLOT
    pop si
    pop bx
    jmp .next
.svalx:
    pop si
    pop bx
    jmp .done

.nchr:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push bx
    push si
    sub di, BAS_SLOT
    mov si, di
    call fp_unpack_a
    call fp_a2i
    jc .chrbad
    cmp ax, 255
    ja .chrbad
    mov bx, ax
    mov cx, 1
    call bas_stmpalloc
    jc .nchrx
    mov [di], ax
    mov word [di + 2], 1
    mov si, ax
    mov al, bl
    mov [si], al
    add di, BAS_SLOT
    pop si
    pop bx
    jmp .next
.chrbad:
    pop si
    pop bx
    mov si, bas_e_chrrange
    jmp bas_err
.nchrx:
    pop si
    pop bx
    jmp .done

; **IT KEEPS PRINT'S LEADING SPACE** for a non-negative number, because the
; reference does and because `PRINT x` and `PRINT STR$(x)` may not differ.
.nstr:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push bx
    push si
    sub di, BAS_SLOT
    mov si, di
    call fp_unpack_a
    mov cx, 24
    call bas_stmpalloc
    jc .nstrx
    mov bx, ax
    push bx
    push di
    mov di, bx
    cmp byte [fp_as], 0
    jne .nstrneg
    mov byte [di], ' '              ; the sign's place
    inc di
.nstrneg:
    mov ax, 7
    call fp_ftoa                    ; A -> a NUL string at DS:DI
    pop di
    pop bx
    mov si, bx                      ; ...and its length is to the NUL
    xor cx, cx
.nstrlen:
    cmp byte [si], 0
    je .nstrgot
    inc si
    inc cx
    jmp .nstrlen
.nstrgot:
    mov [di], bx
    mov [di + 2], cx
    add di, BAS_SLOT
    pop si
    pop bx
    jmp .next
.nstrx:
    pop si
    pop bx
    jmp .done

; --- LEFT$ / RIGHT$ / MID$, which are one body and three starts ----------
; Each wants (source, start, count) and differs only in how start and count
; are worked out, so they meet at .ssliceg with BX = start (0-based) and
; CX = how many, both already clamped.
.sleft:
    cmp di, bas_stk + 2*BAS_SLOT
    jb .under
    push bx
    push si
    call bas_sarg1                  ; AX = the count, DI -= one slot
    jc .sslx
    sub di, BAS_SLOT                ; ...and DOWN TO THE SOURCE: the stack
                                    ; pointer is one PAST the top, so after
                                    ; consuming n operands it has moved n
                                    ; slots - which .scat does in one
                                    ; `sub di, 2*BAS_SLOT` and this forgot.
                                    ; [di+2] then read the count's own
                                    ; second word, which for 3.0 is 0, so
                                    ; every slice answered "".
    xor bx, bx                      ; ...from the beginning
    mov cx, ax
    jmp short .sslice
.sright:
    cmp di, bas_stk + 2*BAS_SLOT
    jb .under
    push bx
    push si
    call bas_sarg1
    jc .sslx
    sub di, BAS_SLOT                ; down to the source, as above
    mov cx, [di + 2]                ; ...from the end: start = len - n
    cmp ax, cx
    jb .srsome
    xor bx, bx                      ; more than there is: all of it
    jmp short .sslice
.srsome:
    mov bx, cx
    sub bx, ax
    mov cx, ax
    jmp short .sslice
.smid:
    cmp di, bas_stk + 3*BAS_SLOT
    jb .under
    push bx
    push si
    call bas_sarg1                  ; the count...
    jc .sslx
    mov cx, ax
    push cx
    call bas_sarg1                  ; ...and the start, 1-BASED
    pop cx
    jc .sslx
    sub di, BAS_SLOT                ; down to the source, as above
    or ax, ax
    jz .smidclamp                   ; MID$(s$,0) reads as 1
    dec ax
.smidclamp:
    mov bx, ax
.sslice:
    ; DI = the source slot, BX = start (0-based), CX = how many
    mov ax, [di + 2]
    cmp bx, ax
    jae .sslempty                   ; start past the end: ""
    sub ax, bx                      ; what is actually left
    cmp cx, ax
    jbe .sslfit
    mov cx, ax                      ; clamped, not refused
.sslfit:
    push cx
    call bas_stmpalloc
    pop cx
    jc .sslx
    push ax
    push di
    mov si, [di]
    add si, bx
    mov di, ax
    call bas_scopy
    pop di
    pop ax
    mov [di], ax
    mov [di + 2], cx
    add di, BAS_SLOT
    pop si
    pop bx
    jmp .next
.sslempty:
    mov word [di + 2], 0            ; the offset may stay: nothing reads it
    add di, BAS_SLOT
    pop si
    pop bx
    jmp .next
.sslx:
    pop si
    pop bx
    jmp .done

; --- the array ops (SPEC.md 150.31) --------------------------------------
; **THE BOUNDS CHECK IS THE POINT.** An 8086 has none of its own, and a
; subscript one past the end would read or write whatever the arena holds
; next - another array, or the string region - so it is refused by name with
; nothing plausible returned.
;
; bas_aelem does the arithmetic for all three: in BX = which array, with the
; subscripts already on the value stack; out SI = the element, DI dropped by
; as many slots as there were subscripts.
.aload:
    push bx
    mov bl, [si]
    inc si
    xor bh, bh
    push si
    call bas_aelem
    jc .alx
    xor bx, bx                      ; BX counts: the only register an 8086
.alcp:                              ; may add to SI or DI, and it is free
    mov ax, [si + bx]               ; once bas_aelem has answered
    mov [di + bx], ax
    add bx, 2
    cmp bx, BAS_SLOT
    jb .alcp
    pop si
    pop bx
    add di, BAS_SLOT
    jmp .next
.alx:
    pop si
    pop bx
    jmp .done

.astore:
    push bx
    mov bl, [si]
    inc si
    xor bh, bh
    push si                         ; the op cursor
    cmp di, bas_stk + BAS_SLOT
    jb .asund
    push dx
    sub di, BAS_SLOT                ; DI = the VALUE's slot, above the subs
    push di
    call bas_aelem                  ; SI = the element, DI = where the stack
    jc .asx2                         ; must END - the subscripts are gone
    ; **DI MUST NOT BE RESTORED.** The first version popped the value's slot
    ; back into DI after the store, which left the stack n slots high per
    ; assignment - sixteen of them in a FOR loop and the evaluation stack is
    ; full. The final DI is bas_aelem's; the value's slot is only a source.
    mov dx, di
    pop di                          ; DI = the value's slot, to copy FROM
    xor bx, bx
.ascp:
    mov ax, [di + bx]
    mov [si + bx], ax
    add bx, 2
    cmp bx, BAS_SLOT
    jb .ascp
    mov di, dx                      ; ...and the value is consumed too
    pop dx
    pop si
    pop bx
    jmp .next
.asx2:
    pop di
    pop dx
.asund:
    pop si
    pop bx
    jmp .done

; **AN ELEMENT OWNS ITS BYTES** (SPEC.md 150.28's one-owner rule, which is
; what makes compaction a slide): a string on the value stack is a literal
; or a temporary, and a temporary dies at the end of the statement - so
; storing the pair without copying would leave the element pointing at bytes
; about to be reused. The value goes in bas_asval rather than round three
; calls on the stack, which is where the first draft of this lost its error
; paths.
.asstore:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push bx
    mov bl, [si]
    inc si
    xor bh, bh
    push si                         ; the op cursor
    sub di, BAS_SLOT                ; DI = the text's slot
    mov ax, [di]
    mov [bas_asval], ax
    mov ax, [di + 2]
    mov [bas_asval + 2], ax
    call bas_aelem                  ; SI = the element, DI = where it ends
    jc .assbad
    push si
    push di
    mov cx, [bas_asval + 2]
    call bas_svaralloc              ; room of its own
    jc .assbad2
    mov di, ax
    mov si, [bas_asval]
    mov cx, [bas_asval + 2]
    call bas_scopy                  ; ...and it keeps DI and CX
    mov ax, di
    pop di
    pop si
    mov [si], ax
    mov [si + 2], cx
    pop si
    pop bx
    jmp .next
.assbad2:
    pop di
    pop si
.assbad:
    pop si
    pop bx
    jmp .done

.abound:
    cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT
    jae .over
    push bx
    mov bl, [si]                    ; which array...
    inc si
    xor bh, bh
    push si
    mov si, bas_arrs                ; (bas_arrat wants BX and gives SI)
    call bas_arrat
    pop ax                          ; the op cursor, to read `which end`
    push ax
    mov bx, ax
    mov al, [bx]                    ; 0 = LBOUND, 1 = UBOUND
    xor ah, ah
    or al, al
    jnz .abup
    mov ax, [si + BAS_ARR_LO0]
    jmp short .abgot
.abup:
    mov ax, [si + BAS_ARR_LO0]
    add ax, [si + BAS_ARR_N0]
    dec ax
.abgot:
    call fp_i2a
    call fp_pack_a
    pop si
    inc si                          ; past the `which end` byte
    pop bx
    add di, BAS_SLOT
    jmp .next

.sprint:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    sub di, BAS_SLOT
    push bx
    push si
    mov cx, [di + 2]
    mov si, [di]
    call bas_sayrun                 ; CX bytes, which may hold a NUL
    pop si
    pop bx
    jmp .next

; **-1, 0 or 1 AS A NUMBER** (SPEC.md 150.28), so 150.18's six relations
; serve strings with no second table and no second convention.
.scmp:
    cmp di, bas_stk + 2*BAS_SLOT
    jb .under
    push bx
    push si
    sub di, 2*BAS_SLOT
    mov si, [di]
    mov cx, [di + 2]
    mov bx, [di + BAS_SLOT]
    mov ax, [di + BAS_SLOT + 2]
    call bas_scmpbytes              ; AX = -1 / 0 / 1
    call fp_i2a
    call fp_pack_a
    add di, BAS_SLOT
    pop si
    pop bx
    jmp .next

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

; --- the six comparisons, as ONE body (SPEC.md 150) -------------------------
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

; --- OP_LOAD / OP_STORE: a scalar variable (SPEC.md 150.4) ------------------
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
    mov bl, [bas_alias + bx]        ; ...which variable that REALLY is: the
                                    ; table is identity but where a VAR
                                    ; parameter points at the caller's
                                    ; (SPEC.md 150.26)
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
    mov bl, [bas_alias + bx]        ; ...through the alias, as .vload does
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

; --- OP_AFILL, OP_SWAP, OP_ASWAP (SPEC.md 150.33, 150.34) ---------------
; Each reads its index byte(s) from the op stream, and each must SAVE SI
; around bas_arrat/bas_varat, which answer in SI and so clobber the cursor.
.afill:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    push bx
    push cx
    push dx
    mov bl, [si]
    inc si
    xor bh, bh
    push si
    call bas_arrat                  ; SI = the entry
    mov ax, [si + BAS_ARR_N0]       ; the element count is 150.31's own
    cmp word [si + BAS_ARR_DIM], 2  ; arithmetic, as bas_aelem's is
    jne .afin
    mul word [si + BAS_ARR_N1]
.afin:
    mov cx, ax
    mov ax, [si + BAS_ARR_AT]
    add ax, bas_arena
    sub di, BAS_SLOT                ; the value's slot, and it is consumed
    mov si, ax                      ; SI = the first element
    jcxz .afidone
.afielem:
    xor bx, bx
.afib:
    mov ax, [di + bx]               ; EIGHT BYTES BY HAND, for OP_PUSHN's
    mov [si + bx], ax               ; reason: ES is the KERNEL's segment
    add bx, 2
    cmp bx, BAS_SLOT
    jb .afib
    add si, BAS_SLOT
    loop .afielem
.afidone:
    pop si                          ; the op cursor again
    pop dx
    pop cx
    pop bx
    jmp .next
.swap:
    push bx
    push dx
    push di
    mov bl, [si]
    inc si
    xor bh, bh
    push si
    call bas_varat                  ; SI = the first entry
    mov dx, si
    pop si
    mov bl, [si]
    inc si
    xor bh, bh
    push si
    call bas_varat                  ; SI = the second
    mov di, si
    mov si, dx
    xor bx, bx
.swb:
    mov ax, [si + bx + BAS_VAR_VAL] ; for a '$' pair these eight bytes are
    mov dx, [di + bx + BAS_VAR_VAL] ; 150.28's offset and length, so the
    mov [si + bx + BAS_VAR_VAL], dx ; exchange cannot make a second owner
    mov [di + bx + BAS_VAR_VAL], ax ; and the arena is untouched
    add bx, 2
    cmp bx, BAS_SLOT
    jb .swb
    pop si
    pop di
    pop dx
    pop bx
    jmp .next
.aswap:
    push bx
    push dx
    push di
    mov bl, [si]
    inc si
    xor bh, bh
    push si
    call bas_arrat
    mov dx, si
    pop si
    mov bl, [si]
    inc si
    xor bh, bh
    push si
    call bas_arrat
    mov di, si
    mov si, dx
    mov bx, BAS_ARR_LO0             ; FROM THE BOUNDS ON, not from zero: the
.aswb:                              ; first four bytes are where the NAME is,
    mov ax, [si + bx]               ; and swapping those too would exchange
    mov dx, [di + bx]               ; the names and do nothing at all
    mov [si + bx], dx
    mov [di + bx], ax
    add bx, 2
    cmp bx, BAS_ARR_SZ              ; ...and it ends at the record's end, so
    jb .aswb                        ; a field added later moves with the rest
    pop si
    pop di
    pop dx
    pop bx
    jmp .next
    ; THE NAME IS THE FIRST FOUR BYTES, and that is what the loop's starting
    ; offset rests on - so it is asserted here rather than trusted. NO RUN
    ; CAN CHECK IT: an index is resolved at compile time and nothing reads
    ; BAS_ARR_SRC afterwards, so a build that swapped all sixteen passed
    ; basiclang3 with every answer unchanged (SPEC.md 150.34). A claim no
    ; test can fail gets a check that can.
    times BAS_ARR_LO0 - 4 db 0
    times 4 - BAS_ARR_LO0 db 0

; --- OP_ONMGOSUB / OP_MSEL (SPEC.md 150.38) -----------------------------
.onmgosub:
    push ax
    mov ax, [si]                    ; the handler, bas_ops-RELATIVE as a
    mov [bas_mhand], ax             ; call's operand is (150.23)
    pop ax
    add si, 2
    jmp .next
.msel:
    cmp di, bas_stk + BAS_STK_MAX*BAS_SLOT
    jae .over
    push ax
    mov ax, [bas_msel]
    call fp_i2a
    call fp_pack_a
    pop ax
    add di, BAS_SLOT
    jmp .next

; --- OP_MENU (SPEC.md 150.38) -------------------------------------------
; + an index byte. Walks m$() in the Compendium's layout (node [299]),
; COPIES every title and item into bas_mtext, builds the pointer tables and
; installs the set with File and Run still in front of it.
;
; THE WALK'S STATE IS IN BSS, not in registers: there are five values live
; at once (the element index, the menu, the item, the arena top and the
; array) and this runs once per MENU statement, not once per op.
.menu:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bl, [si]
    xor bh, bh                      ; BX = which array, and it stays there
    ; --- the set's own head, and the two menus that STAY -----------------
    ; THE FIRST VERSION LEFT ALL OF THIS ZERO AND THE ROW PASSED. bas_mset
    ; is bss, so the bar went up with a NULL app name, a NULL command
    ; handler and two null entries where File and Run belong: the program
    ; printed its answers and THE BAR WAS RUBBLE. The values-only
    ; assertions could not see it, exactly as tests/basiclang.py's own
    ; comment warns, and it surfaced only because the NEXT part's
    ; File > New had no handler left to reach.
    ;
    ; COPIED FROM THE STATIC SET rather than written out here, so File and
    ; Run cannot drift away from bas_menus if either is ever edited.
    push bx
    mov ax, [bas_menus + AM_NAME]
    mov [bas_mset + AM_NAME], ax
    mov ax, [bas_menus + AM_ONCMD]
    mov [bas_mset + AM_ONCMD], ax
    mov si, bas_menus + AM_LIST
    mov di, bas_mset + AM_LIST
    xor bx, bx
.mnhead:
    mov al, [si + bx]               ; BY HAND: ES is the kernel's segment
    mov [di + bx], al
    inc bx
    cmp bx, 2*AMENU_ENTSZ
    jb .mnhead
    pop bx
    mov word [bas_mwi], 0
    mov word [bas_mwm], 0
    mov word [bas_mwtop], 0
.mnmenu:
    ; --- a menu: its title, then its items, then an empty string --------
    call bas_melem                  ; SI = element [bas_mwi], or CF=1 past
    jc .mndone                      ; the end of the array
    cmp word [si + 2], 0
    je .mndone                      ; the empty string that ends the BAR
    cmp word [bas_mwm], BAS_MEN_MAX
    jae .mnmany
    call bas_mcopy                  ; AX = where the title now lives
    jc .mntext
    ; the entry, at AM_LIST + (2 + this menu) * AMENU_ENTSZ
    mov di, [bas_mwm]
    mov cx, di
    add cx, 2                       ; File and Run come first
    mov ax, cx
    mov cl, AMENU_ENTSZ
    mul cl
    mov dx, ax                      ; DX = the entry's offset in the list
    call bas_melem                  ; (the title again, for its text ptr)
    call bas_mcopy
    mov di, bas_mset + AM_LIST
    add di, dx
    mov [di + AMENU_TITLE], ax
    ; ...its item array, at bas_mitems + menu*BAS_MEN_ITEMS*2
    mov ax, [bas_mwm]
    mov cl, BAS_MEN_ITEMS*2
    mul cl
    add ax, bas_mitems
    mov [di + AMENU_ITEMS], ax
    inc word [bas_mwi]              ; past the title
    mov word [bas_mwn], 0
.mnitem:
    call bas_melem
    jc .mnend                       ; the array ran out: this menu ends
    cmp word [si + 2], 0
    je .mnempty                     ; the empty string that ends this MENU
    ; THE ACCESSORY SLOTS, m$(3)..m$(8), are one character long and their
    ; contents are ignored (node [300]) - and this OS has none, so they are
    ; skipped in the FIRST menu, where the Compendium puts them
    cmp word [bas_mwm], 0
    jne .mnreal
    cmp word [si + 2], 1
    je .mnskip
.mnreal:
    cmp word [bas_mwn], BAS_MEN_ITEMS
    jae .mnitems
    call bas_mcopy                  ; AX = the item's stable text
    jc .mntext
    mov di, [bas_mwm]
    mov ax, di
    mov cl, BAS_MEN_ITEMS*2
    mul cl
    mov dx, ax                      ; DX = this menu's table offset
    call bas_melem
    call bas_mcopy
    mov di, dx
    add di, [bas_mwn]
    add di, [bas_mwn]
    mov [bas_mitems + di], ax
    mov ax, [bas_mwi]               ; ...and WHICH element it was, for MENU(0)
    mov [bas_midx + di], ax
    inc word [bas_mwn]
.mnskip:
    inc word [bas_mwi]
    jmp .mnitem
.mnempty:
    inc word [bas_mwi]              ; past the empty string
.mnend:
    mov ax, [bas_mwm]
    mov cl, AMENU_ENTSZ
    mul cl
    mov di, bas_mset + AM_LIST + 2*AMENU_ENTSZ
    add di, ax
    mov ax, [bas_mwn]
    mov [di + AMENU_NITEM], ax
    inc word [bas_mwm]
    jmp .mnmenu
.mndone:
    ; --- install it, File and Run in front -------------------------------
    mov ax, [bas_mwm]
    add ax, 2
    mov [bas_mset + AM_COUNT], ax
    mov word [bas_mon], 1
    mov word [bas_mbar], 1          ; ...and the BAR is owed a redraw, which
                                    ; only bas_onwake can pay: wm_front takes
                                    ; the gfx lock and this runs under it
    push bx
    mov bx, [bas_wn]
    mov si, bas_mset
    call OSAPI_MENU_SET             ; relayouts if ours is the active window
    call OSAPI_WM_WAKE              ; ...so a wake is posted even when the
    pop bx                          ; program has no ON MENU of its own
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    inc si                          ; past the index byte
    jmp .next
.mnmany:
    mov si, bas_e_menmany
    jmp .mnbad
.mnitems:
    mov si, bas_e_menitem
    jmp .mnbad
.mntext:
    mov si, bas_e_mentext
.mnbad:
    add sp, 12                      ; the six pushes above, dropped: bas_err
    jmp bas_err                     ; does not come back here

; --- OP_ALERT (SPEC.md 150.37) ------------------------------------------
; RE-ENTRANT, which is how a statement that blocks lives on a system whose
; alert is asynchronous. The first pass pops the four operands, raises the
; alert and saves the cursor pointing AT THIS OPCODE; the completion stores
; the answer and wakes us; the resume lands back here, finds it pending and
; stores it into `choice`.
;
; THE OPERANDS ARE POPPED ON THE FIRST PASS ONLY, which the pending test is
; what guards: the DI saved at the suspension is already the reduced one, so
; a second pop would take four slots belonging to somebody else.
.alert:
    cmp word [bas_alpend], 0
    je .alraise
    mov word [bas_alpend], 0
    push bx
    push di                         ; DI is the value stack, and fp_pack_a
    mov bl, [si]                    ; wants it for the destination
    xor bh, bh
    mov bl, [bas_alias + bx]
    push si
    call bas_varat                  ; SI = the entry
    mov ax, [bas_alans]
    call fp_i2a
    mov di, si
    add di, BAS_VAR_VAL
    call fp_pack_a
    pop si
    pop di
    pop bx
    inc si                          ; past the index byte, and on
    jmp .next
.alraise:
    cmp di, bas_stk + 4*BAS_SLOT
    jb .under
    sub di, BAS_SLOT                ; button$ is the top of the four
    call bas_alset                  ; AX = the set, CF=1 no match
    jc .albtnbad
    push ax
    sub di, BAS_SLOT                ; `default`: IGNORED (150.37)
    sub di, BAS_SLOT                ; message$
    call bas_almake                 ; into bas_almsg, clipped; CF=1 on a '|'
    jc .almsgbad
    sub di, BAS_SLOT                ; `icon`: IGNORED
    ; SUSPEND FIRST, because os88ui_ask wants SI and DI for its own
    ; arguments and those two registers ARE the interpreter (150.36)
    mov ax, si
    dec ax                          ; ...AT this opcode, not past it
    sub ax, bas_ops
    mov [bas_scur], ax
    mov [bas_sdi], di
    mov word [bas_susp], 1
    pop ax                          ; the set
    mov bx, [bas_wn]
    mov si, bas_almsg
    mov di, bas_aldone
    call os88ui_ask                 ; the gfx lock is held either way in:
    jc .albusy                      ; AM_ONCMD holds it, bas_onwake took it
    ret                             ; ...and the completion wakes us
.albusy:
    mov word [bas_susp], 0
    mov si, bas_e_albusy
    jmp bas_err
.almsgbad:
    pop ax
    mov si, bas_e_almsg
    jmp bas_err
.albtnbad:
    mov si, bas_e_albtn
    jmp bas_err

; --- OP_ONMENU (SPEC.md 150.36) -----------------------------------------
; THE YIELD IS A RETURN. A program runs on the UI task under the gfx lock
; (SPEC.md 12.2's AM_ONCMD contract), so yielding IN PLACE cannot work: the
; task that would deliver the events this statement exists to dispatch is
; the one inside here. So the cursor is saved, a wake is posted, and the
; interpreter RETURNS - which ends the callback and releases the lock the
; ordinary way. bas_onwake brings it back.
;
; THE WAKE IS POSTED BEFORE THE RETURN and the kernel keeps at most one
; queued per window, so this cannot fill the event ring however tight the
; program's loop is (OSAPI_WM_WAKE's own promise). CF=1 means the ring was
; full of other records: the suspension is undone and the statement is a
; no-op this pass rather than a program that never wakes.
.onmenu:
    mov ax, si                      ; the cursor, PAST this opcode, so the
    sub ax, bas_ops                 ; resume carries on at the next statement
    mov [bas_scur], ax
    mov [bas_sdi], di
    mov word [bas_susp], 1
    push bx
    mov bx, [bas_wn]
    call OSAPI_WM_WAKE
    pop bx
    jc .onmfull
    ret                             ; ...out of bas_exec altogether
.onmfull:
    mov word [bas_susp], 0          ; the ring was full: carry straight on
    jmp .next                       ; rather than wait for a wake that was
                                    ; never queued

; --- OP_LSET / OP_RSET (SPEC.md 150.35) ---------------------------------
; NEITHER ALLOCATES. The field's length does not change, so the bytes are
; written where they already are and no arena work and no compaction can
; follow - which is also why a zero-length a$ is a no-op rather than an
; error. A source can never overlap the field: a slice allocates a
; temporary and copies into it (bas_stmpalloc), a literal lies in the
; program text, and every other string owns its bytes alone (150.28).
.lsetop:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    xor ax, ax                      ; AL = 0: justify LEFT
    jmp short .lsetrun
.rsetop:
    cmp di, bas_stk + BAS_SLOT
    jb .under
    mov ax, 1                       ; AL = 1: justify RIGHT
.lsetrun:
    sub di, BAS_SLOT                ; DI = the source slot, and it is spent
    push bx
    push cx
    push dx
    push di                         ; [A] the value stack pointer
    push si                         ; [B] the op cursor
    push ax                         ; [C] which of the two
    mov dx, [di + 2]                ; the source's length...
    mov bx, [di]                    ; ...and where its bytes are
    push bx                         ; [D]
    mov bl, [si]
    xor bh, bh
    mov bl, [bas_alias + bx]        ; VAR's indirection, as OP_SSTORE's
    call bas_varat                  ; SI = the entry (and SI is clobbered)
    mov cx, [si + BAS_VAR_SLEN]     ; CX = THE FIELD'S WIDTH, which is the
    mov di, [si + BAS_VAR_SOFF]     ; whole of what a$ contributes
    pop si                          ; [D] SI = the source's bytes
    pop ax                          ; [C]
    cmp dx, cx
    jbe .lsn
    mov dx, cx                      ; LONGER THAN THE FIELD: the first CX of
.lsn:                               ; it, one rule for both (SPEC.md 150.35)
    or al, al
    jnz .rsetbody
    xor bx, bx                      ; --- LEFT: the bytes, then spaces ----
.lsb:
    cmp bx, dx
    jae .lsp
    mov al, [si + bx]
    mov [di + bx], al
    inc bx
    jmp short .lsb
.lsp:
    mov al, ' '
.lsps:
    cmp bx, cx
    jae .lsdone
    mov [di + bx], al
    inc bx
    jmp short .lsps
.rsetbody:
    sub cx, dx                      ; --- RIGHT: spaces, then the bytes ---
    xor bx, bx                      ; CX = the padding, and the width is not
    mov al, ' '                     ; wanted again
.rsps:
    cmp bx, cx
    jae .rscp
    mov [di + bx], al
    inc bx
    jmp short .rsps
.rscp:
    add di, cx                      ; the bytes begin after the padding, so
    xor bx, bx                      ; ONE index serves here too
.rsb:
    cmp bx, dx
    jae .lsdone
    mov al, [si + bx]
    mov [di + bx], al
    inc bx
    jmp short .rsb
.lsdone:
    pop si                          ; [B] the op cursor
    inc si                          ; past the index byte
    pop di                          ; [A] the value stack pointer
    pop dx
    pop cx
    pop bx
    jmp .next
.under:
    mov si, bas_e_stk
    jmp bas_err
.over:
    mov si, bas_e_deep
    jmp bas_err

; --- the dispatch tables (SPEC.md 150.5) ------------------------------------
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
    dw bas_exec.vrefop              ; OP_VREF
    dw bas_exec.aliasop             ; OP_ALIAS
    dw bas_exec.dropop              ; OP_DROP
    dw bas_exec.spushl              ; OP_SPUSHL
    dw bas_exec.sload               ; OP_SLOAD
    dw bas_exec.sstore              ; OP_SSTORE
    dw bas_exec.scat                ; OP_SCAT
    dw bas_exec.sprint              ; OP_SPRINT
    dw bas_exec.scmp                ; OP_SCMP
    dw bas_exec.slen                ; OP_SLEN
    dw bas_exec.sasc                ; OP_SASC
    dw bas_exec.sval                ; OP_SVAL
    dw bas_exec.nchr                ; OP_NCHR
    dw bas_exec.nstr                ; OP_NSTR
    dw bas_exec.sleft               ; OP_SLEFT
    dw bas_exec.sright              ; OP_SRIGHT
    dw bas_exec.smid                ; OP_SMID
    dw bas_exec.aload               ; OP_ALOAD
    dw bas_exec.astore              ; OP_ASTORE
    dw bas_exec.abound              ; OP_ABOUND
    dw bas_exec.asstore             ; OP_ASSTORE
    dw bas_exec.afill               ; OP_AFILL
    dw bas_exec.swap                ; OP_SWAP
    dw bas_exec.aswap               ; OP_ASWAP
    dw bas_exec.lsetop              ; OP_LSET
    dw bas_exec.rsetop              ; OP_RSET
    dw bas_exec.onmenu              ; OP_ONMENU
    dw bas_exec.alert               ; OP_ALERT
    dw bas_exec.menu                ; OP_MENU
    dw bas_exec.onmgosub            ; OP_ONMGOSUB
    dw bas_exec.msel                ; OP_MSEL
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
; **os88dec.inc DOES THE DIGITS** (SPEC.md 20.5.2). This was a hand-written
; `div 10` loop, which is the one thing docs/INDEX.md's entry for that
; include tells you not to write - and the index was never read. `dec_s16`
; writes NUL-ended text at DS:DI and keeps every register but DI, so the
; whole of this is a buffer and a con_say.
bas_sayint:
    push di
    push si
    mov di, bas_numbuf
    call dec_s16
    mov si, bas_numbuf
    call con_say
    pop si
    pop di
    ret

; --- bas_err - SI = a NUL reason. Say it with the line number and stop -------
; SPEC.md 150.7's discipline: a refusal is reported BY NAME, with its reason,
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
bas_kw_var:     db 'VAR', 0
bas_kw_void:    db 'VOID', 0
bas_kw_len:     db 'LEN', 0
bas_kw_asc:     db 'ASC', 0
bas_kw_val:     db 'VAL', 0
bas_kw_chr:     db 'CHR$', 0
bas_kw_str:     db 'STR$', 0
bas_kw_left:    db 'LEFT$', 0
bas_kw_right:   db 'RIGHT$', 0
bas_kw_mid:     db 'MID$', 0
bas_kw_dim:     db 'DIM', 0
bas_kw_option:  db 'OPTION', 0
bas_kw_base:    db 'BASE', 0
bas_kw_lbound:  db 'LBOUND', 0
bas_kw_ubound:  db 'UBOUND', 0
bas_kw_clr:     db 'CLR', 0
bas_kw_afill:   db 'ARRAYFILL', 0
bas_kw_swap:    db 'SWAP', 0
bas_kw_lset:    db 'LSET', 0
bas_kw_rset:    db 'RSET', 0
bas_kw_erase:   db 'ERASE', 0
bas_kw_on:      db 'ON', 0
bas_kw_menu:    db 'MENU', 0
bas_kw_alert:   db 'ALERT', 0

; --- ALERT's five button sets (SPEC.md 150.37) ---------------------------
; STORED UPPER-CASE and matched whole, because `button$` is an sexp and the
; match is therefore a RUN-TIME one. The set value rides beside the pattern:
; OS88UI_ASTEP is 4 and absent here (it is behind OS88UI_AEXTRA, SHEET's
; macro debugger), so the values are not the table's own indices.
bas_als_ok:     db 'OK', 0
bas_als_yn:     db 'YES|NO', 0
bas_als_sdc:    db 'SAVE|DISCARD|CANCEL', 0
bas_als_cp:     db 'CANCEL|PROCEED', 0
bas_als_okc:    db 'OK|CANCEL', 0
bas_als_shc:    db 'STEP|HALT|CONTINUE', 0
bas_altab:
    dw bas_als_ok,  OS88UI_AOK
    dw bas_als_yn,  OS88UI_AYESNO
    dw bas_als_sdc, OS88UI_ASAVE
    dw bas_als_cp,  OS88UI_ADANGER
    dw bas_als_okc, OS88UI_AOKCAN
    dw bas_als_shc, OS88UI_ASTEP
BAS_ALSETS equ ($ - bas_altab) / 4

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
bas_e_varname:  db 'a VAR value wants a variable to point at', 0
bas_e_varcall:  db 'VAR belongs in the definition, not in the call', 0
bas_e_strfull:  db 'out of room for text - this wave holds 4096 bytes', 0
bas_e_strquote: db 'a piece of text wants a closing quotation mark', 0
bas_e_strtype:  db 'that mixes text and numbers', 0
bas_e_strlong:  db 'one piece of text is longer than the arena', 0
bas_e_comma:    db 'this wants a comma and another value', 0
bas_e_ascempty: db 'ASC wants text with at least one character in it', 0
bas_e_chrrange: db 'CHR$ takes a code from 0 to 255', 0
bas_e_negcount: db 'that many characters is a negative number', 0
bas_e_arrmax:   db 'too many arrays - this wave holds eight', 0
bas_e_arrfull:  db 'out of room for arrays - this wave holds 512 elements', 0
bas_e_arrdup:   db 'that array is already DIMmed', 0
bas_e_arrname:  db 'DIM wants a name and a size in brackets', 0
bas_e_arrdim:   db 'that array was DIMmed with a different number of sizes', 0
bas_e_arrrange: db 'that subscript is outside the array', 0
bas_e_arrto:    db 'a size runs low TO high', 0
bas_e_arrdims:  db 'DIM takes one or two sizes here', 0
bas_e_basedim:  db 'OPTION BASE must come before any DIM', 0
bas_e_baseval:  db 'OPTION BASE takes 0 or 1', 0
bas_e_clrarr:   db 'CLR takes variables; ARRAYFILL fills an array', 0
bas_e_afillstr: db 'ARRAYFILL cannot fill a string array', 0
bas_e_afillno:  db 'ARRAYFILL wants an array that has been DIMmed', 0
bas_e_swapkind: db 'SWAP wants two of the same kind', 0
bas_e_swapmix:  db 'SWAP takes two variables or two arrays, not one of each', 0
bas_e_swapname: db 'SWAP wants two names', 0
bas_e_lsetstr:  db 'LSET and RSET want a $ name', 0
bas_e_lseteq:   db 'LSET and RSET go LSET a$ = b$', 0
bas_e_onwhat:   db 'ON MENU is the only ON this wave knows', 0
bas_e_onmarg:   db 'ON MENU takes nothing yet - handlers come with MENU', 0
bas_e_albtn:    db 'those ALERT buttons are not one of the six sets', 0
bas_e_almsg:    db 'an ALERT message is ONE line here - no | in it', 0
bas_e_albusy:   db 'an alert is already up', 0
bas_e_alvar:    db 'ALERT wants a number variable for the choice', 0
bas_e_menarr:   db 'MENU wants a DIMmed string array, as MENU m$()', 0
bas_e_menmany:  db 'MENU fits three menus beside File and Run', 0
bas_e_menitem:  db 'that MENU has more items than one menu holds', 0
bas_e_mentext:  db 'those MENU titles do not fit the bar text arena', 0
bas_e_onghand:  db 'ON MENU GOSUB wants a PROCEDURE that takes nothing', 0
bas_e_mselarg:  db 'MENU() takes 0 here - the rest is the AES message buffer', 0
; REFUSED WITH A REASON, not as an unknown word (SPEC.md 150.7): ERASE is the
; reference's and leaving it out is a decision, so the message says so and
; names the word a program reaching for it probably wanted. SHORT BECAUSE THE
; CONSOLE IS 80 COLUMNS - the first draft ran to 135 with `Error at line N: `
; on it, which WRAPS, and a wrapped refusal is two console lines where every
; gate asserts one. The whole reason is SPEC.md 150.33's, not a message's.
bas_e_erase:    db 'ERASE frees nothing here - ARRAYFILL clears one in place', 0
bas_e_notarr:   db 'that is not an array', 0
bas_e_wide:     db "'\' truncates to an INTEGER and this is outside it", 0
