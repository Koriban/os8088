; =============================================================================
; os8088 - apps/basic/basic.asm
;
; BASIC/8088 (SPEC.md 126) - THE PACKAGE: the window, the two panes and the
; command path. The LANGUAGE is basic/baslang.inc, included below.
;
; TWO PANES, one window: the editor above and the console below, which is
; SPEC.md 126's shape for both halves of the target - a GUI program and a
; text one are the same program with a different surface (126.8). The editor
; is os88text.inc (SPEC.md 83) over bas_prog; the console is os88con.inc's
; teletype half (70.8), and every output a program makes goes through
; con_say. Run compiles the editor's text and runs it (bas_run).
;
; THE SIZE IS THE THING THIS FILE WATCHES. SPEC.md 126.6 plans a split
; across BASIC.O88 and BASIC.OVL on the arithmetic that an interpreter
; cannot fit beside sixty-four built-ins, an editor and a console in one
; 63.5KB segment. Nothing is split yet and the wall is not in sight;
; `make basic` prints where it stands, and that number is to be MEASURED
; rather than quoted from a comment like this one.
;
; (This header described wave 0 - "nothing of the language is here", "owns
; no text widget yet", "Run does nothing, deliberately and visibly" - for
; four waves after each stopped being true. SPEC.md 126's own discipline is
; that a refusal is stated by name; a stale description is the same defect
; pointed at the reader.)
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'BASIC', bas_entry, 0, OS88_HIGH | OS88_HIGHMEM

; --- geometry (SPEC.md 11: content is x+1..x+w-2, y+TITLE_H..y+h-2) ----------
; DERIVED, never quoted: SPEC.md 126.12.1's rule for a dialog is the rule for
; a window too, and the one number a package must not contain is TITLE_H.
BAS_W       equ 480                         ; outer
BAS_H       equ 300
BAS_CONT_W  equ BAS_W - 2                   ; 478
BAS_CONT_H  equ BAS_H - TITLE_H - 1         ; 281

BAS_ED_H    equ 200                         ; the editor pane's height
BAS_GAP     equ 8                           ; ...and the gutter below it
BAS_CON_Y   equ BAS_ED_H + BAS_GAP          ; the console pane's top, 208
BAS_CON_H   equ BAS_CONT_H - BAS_CON_Y      ; ...and what is left for it, 73
BAS_CON_PAD equ 2                           ; the console text inset inside
                                            ; its frame
; How much of the fixed 80x25 is on view - DERIVED from the pane, never a
; second set of numbers that could disagree with it (SPEC.md 70.8: the screen
; is fixed and a resize changes only how much is VISIBLE).
BAS_CON_COLS equ (BAS_CONT_W - 2*BAS_CON_PAD) / 8
BAS_CON_ROWS equ (BAS_CON_H  - 2*BAS_CON_PAD) / 8

BAS_PROG_MAX equ 2048                       ; the program buffer, NUL included

; F5 = Run. W_ONKEY is handed AL = ascii, AH = the scancode (SPEC.md 9.7.1),
; and a function key has no ascii - so this is scancode 0x3F with AL = 0, the
; same shape as the KEY_ALTENTER the SDK names. Every BASIC of this line runs
; on F5, and it is also what lets a gate drive the language with no mouse at
; all: `tests/basiclang.py` types a program and presses it.
BAS_KEY_RUN equ 0x3F00
; -----------------------------------------------------------------------------
; bas_entry - package entry point (SPEC.md 20.2)
; in:  DS=ES=KERNEL_SEG, IF=1, gfx lock NOT held
; out: BX = window ptr, CF clear (CF set = abort, from wm_create)
;
; hello.asm's shape (SPEC.md 27) and for its reasons: wm_create is lock-free,
; the loader shows the window, and registering the menu set HERE is what makes
; the first bar the loader draws already ours. OSAPI_MENU_SET and
; OSAPI_ABOUT_SET both preserve the flags, so wm_create's CF reaches the
; loader down this one path untouched.
; -----------------------------------------------------------------------------
bas_entry:
    push si
    mov si, bas_tpl
    call OSAPI_WM_CREATE             ; BX = window ptr, CF on table full
    jc .out
    OS88_REGION_MOVABLE             ; SPEC.md 66.6.1 - and this package has no
                                    ; worker, which is the case that moves most
    mov si, bas_menus
    call OSAPI_MENU_SET
    mov si, bas_about
    call OSAPI_ABOUT_SET

    ; --- the editor (SPEC.md 83) ---------------------------------------------
    ; The BLOCK's non-geometry fields, once: where the buffer is and how big.
    ; The RECT is geometry and belongs in the paint (bas_paint), because a
    ; window moves and these are SCREEN coordinates.
    mov word [bas_tx + TX_BUF], bas_prog
    mov word [bas_tx + TX_MAX], BAS_PROG_MAX
    mov byte [bas_tx + TX_FOCUS], 1 ; the caret is in the program pane from the
                                    ; start: there is nowhere else for a key to
                                    ; go but the About card, which takes
                                    ; one keystroke to dismiss itself

    ; --- the numerics (SPEC.md 84) -------------------------------------------
    ; fp_init probes for a coprocessor and sets [fp_hw]; every dispatcher
    ; gates on it (84.6), so without this call the software path runs on a
    ; machine that has an 8087 - correct, and slower than it needs to be.
    call fp_init

    ; --- the console (SPEC.md 70.8) ------------------------------------------
    ; con_open and not con_clear: it sets the attribute, calls con_font AND
    ; clears. The face is the trap os88con.inc's own header warns about -
    ; until con_font runs, ASCII 32..127 is a blank hole, so a console whose
    ; carrier forgot it holds all the right characters and draws every letter
    ; as nothing. The buffer reads perfectly and the screen is empty.
    call bas_conreset
.out:
    pop si
    ret

; -----------------------------------------------------------------------------
; bas_new - File > New: an empty program and a fresh console
; in:  nothing; out: nothing; clobbers AX/SI like any internal call
;
; It cleared the CONSOLE only until wave 2, which read as New having done
; nothing: the program is the thing on screen, and it stayed. NEW empties the
; program in every BASIC of this line, and here it has a second job - the
; variable table keys on offsets INTO this text (bas_varfind), so leaving the
; text while clearing nothing else would be the one state those entries must
; never see. bas_run clears them too, so both doors are shut.
; -----------------------------------------------------------------------------
bas_new:
    mov word [bas_tx + TX_LEN], 0
    mov word [bas_tx + TX_CAR], 0
    mov word [bas_tx + TX_TOP], 0
    mov byte [bas_prog], 0          ; ...and the buffer itself NUL-terminated
    mov word [bas_nvar], 0
    jmp bas_conreset                ; tail call: its ret is ours

; -----------------------------------------------------------------------------
; bas_conreset - a fresh console, with the cursor where the user can see it
; in:  nothing; out: nothing; clobbers AX/SI like any internal call
;
; con_open clears the 25-row buffer and parks the cursor at (0,0). This pane
; shows the LAST BAS_CON_ROWS of those twenty-five (SPEC.md 70.8: a short
; window is a viewport onto a fixed buffer, and con_row's only bound is
; [con_vtop]) - so a console opened and written to immediately puts its first
; lines on rows nobody is looking at, and the pane stays black until eighteen
; lines have scrolled past.
;
; So the cursor starts on the FIRST VISIBLE ROW. Everything after that is the
; teletype's own business: con_write's LF scrolls the buffer at row 24 and the
; viewport keeps showing the bottom of it, which is what a terminal does.
; -----------------------------------------------------------------------------
bas_conreset:
    call bas_clshome
    mov si, bas_s_banner
    jmp con_say                     ; tail call: con_say's ret is ours

; --- bas_clshome - an empty console with the cursor where it can be seen ----
; bas_conreset's first half, on its own because CLS wants it WITHOUT the
; banner: a program that clears the screen and prints has not asked to be
; told what it is running on.
bas_clshome:
    call con_open
    mov word [con_cy], CON_ROWS - BAS_CON_ROWS
    mov word [con_cx], 0
    ret

; -----------------------------------------------------------------------------
; bas_paint - W_PAINT: the two panes and what is in them
; in:  SI = window ptr; caller holds the gfx lock
; out: nothing; preserves all registers
;
; SI is the window pointer and the kernel's contract for it is that it ARRIVES
; that way (SPEC.md 11): a paint path that clobbers it silently skips the
; redraw while every byte of state underneath is correct, which reads as a
; drawing bug and is not one. Hence the push/pop around everything.
;
; The content origin is fetched EVERY paint and never cached: a rect in bss is
; valid until the next thing that can move the window, which is any moment
; this code is not running (apps/os88api.inc's own warning).
; -----------------------------------------------------------------------------
bas_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    mov bp, si                      ; BP = the window ptr, HELD. SS != DS here,
                                    ; so [bp+disp] would address the task stack
                                    ; - but a plain register hold is not an
                                    ; address, and this is one
    mov bx, bp
    call OSAPI_WM_CONTENT            ; AX = content left, DX = content top
    mov di, ax                      ; DI = left, SI = top, for this paint only.
    mov si, dx                       ; Fetched ONCE per paint and never cached
                                     ; in bss: a rect there is valid until the
                                     ; next thing that can move the window,
                                     ; which is any moment this code is not
                                     ; running (apps/os88api.inc's warning).
                                     ; Within one paint the gfx lock is held,
                                     ; so nothing can move it

    ; --- the ink ---------------------------------------------------------------
    ; OSAPI_GFX_FRAME draws in [gfx_color], which is GLOBAL state and not an
    ; argument, and bas_repaint has just set it to CWHITE for its fill - so
    ; without this the console's frame is drawn white on white. It did exactly
    ; that on the first boot: a window with its captions and no panes, which
    ; assembles, runs, and only LOOKING says otherwise.
    mov al, CBLACK
    call OSAPI_SET_COLOR

    ; --- the editor (SPEC.md 83) ----------------------------------------------
    ; The rect is SCREEN coordinates and INCLUSIVE - gfx_frame's convention, so
    ; the drawn control and the clickable one read the same four words and
    ; cannot drift. Set EVERY paint, for the console's reason: a window moves,
    ; and a moved window does not call this proc at all (SPEC.md 11.96.12).
    mov [bas_tx + TX_X1], di
    mov [bas_tx + TX_Y1], si
    mov ax, di
    add ax, BAS_CONT_W - 1
    mov [bas_tx + TX_X2], ax
    mov ax, si
    add ax, BAS_ED_H - 1
    mov [bas_tx + TX_Y2], ax
    push si
    mov si, bas_tx
    call os88text_draw              ; the box, its lines and the caret
    pop si

    ; --- the console pane -----------------------------------------------------
    mov ax, di
    mov bx, si
    add bx, BAS_CON_Y
    mov cx, di
    add cx, BAS_CONT_W - 1
    mov dx, si
    add dx, BAS_CON_Y + BAS_CON_H - 1
    call OSAPI_GFX_FRAME

    ; --- the console's geometry, and it is owed EVERY paint ------------------
    ; os88con.inc's header is emphatic about this: a window can be resized,
    ; dragged across an extended desktop's seam or land on an adapter of a
    ; different size, and a MOVED window does not call this proc at all
    ; (SPEC.md 11.96.12) - so a geometry computed once at launch describes
    ; where the window USED to be.
    mov ax, di
    add ax, BAS_CON_PAD
    add ax, 7                       ; the text pen must be a MULTIPLE OF 8:
    and ax, ~7                      ; con_emit hands it to OSAPI_GFX_BLIT1
    mov [con_px], ax
    mov [con_oy], si                ; the content top...
    mov word [con_topy], BAS_CON_Y + BAS_CON_PAD   ; ...and the first text row
    mov word [con_vcols], BAS_CON_COLS             ; how much of the fixed
    mov word [con_vrows], BAS_CON_ROWS             ; 80x25 is on view
    ; [con_vtop] is NOT zero, and this is the contract's one real trap.
    ; con_row tests `cmp bx, [con_vtop] / jb .done` and has NO lower bound, so
    ; a vtop of 0 draws all twenty-five rows whatever [con_vrows] says - over
    ; the pane, over the window's own bottom edge and onto the desktop, which
    ; is exactly what it did. A short window shows the BOTTOM of the buffer,
    ; which is what a teletype wants: telnet.asm's `CON_ROWS - vrows`.
    mov word [con_vtop], CON_ROWS - BAS_CON_ROWS
    ; [con_mono] is a fact about the screen THIS window is on, and a window
    ; can be dragged onto another one - so it is re-derived here with the
    ; rest, telnet.asm's idiom. OSAPI_VIDEO answers in SI as well as DH, and
    ; SI is our content top, so the call is bracketed.
    push si
    call OSAPI_VIDEO                ; DH = bits per pixel, 4 or 1
    cmp dh, 2                       ; CF = 1bpp...
    sbb dh, dh
    neg dh                          ; ...as the 0/1 [con_mono] is, branch-free
    mov [con_mono], dh
    pop si

    ; **THE SCROLL DEBT FIRST, OR NOTHING DRAWS AT ALL.** con_rows_owed
    ; begins `cmp word [con_scrl], 0 / jne .owed` and returns having drawn
    ; NOTHING while a scroll stands (SPEC.md 96.54.14): a mark names a BUFFER
    ; row, and with the glass owing a blit it does not name the glass. BASIC
    ; never spent the debt, so the FIRST time output passed the bottom of the
    ; eight-row pane [con_scrl] went non-zero and stayed there - and from
    ; that moment every repaint filled the pane white and drew nothing back.
    ; Six PRINTs in one program were enough. The buffer was never the
    ; problem: a memory dump had all ten lines of it sitting in rows 12..23
    ; with the viewport on 17..24.
    ;
    ; THE DEBT IS DROPPED, NOT SPENT, which is telnet.asm's own wording at
    ; the same call: every row is about to be drawn from the buffer, so a
    ; pending "blit the pixels up by N" is not owed - and spending it is not
    ; harmless, because con_scrollpaint moves the pane up N and marks only
    ; the N rows it vacated.
    call con_takescroll             ; the debt FIRST...
    call con_markall                ; ...then the WHOLE pane: the dirty bitmap
    call con_rows_owed              ; is for the incremental case, and a
                                    ; W_PAINT is not one

    ; --- and the About card LAST, over the panes (SPEC.md 20.5.1) ------------
    cmp byte [bas_abon], 0
    je .out
    mov bx, bp
    mov si, bas_ablines
    call os88ui_about_d             ; _d: this paint's region is already armed
.out:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; bas_oncmd - AM_ONCMD: the File and Run menus (SPEC.md 12.2)
; in:  AL = item index, AH = menu index, SI = owning window, BX = the menu set
; out: nothing; clobbers AX/BX/CX/DX like any window callback
;
; On the UI task with the gfx lock already held, so it draws directly and must
; never take the lock. The kernel does not repaint after a command returns,
; so the redraw is ours - and the status string is stored BEFORE the card is
; dismissed, so one repaint draws both and nothing is written twice
; (PERFORMANCE.md's rule 2).
; -----------------------------------------------------------------------------
bas_oncmd:
    or ah, ah
    jnz .run                        ; menu 1 = Run
    ; --- File ----------------------------------------------------------------
    or al, al
    jnz .about                      ; item 1 = About
    push si                         ; item 0 = New: the program AND the
    call bas_new                    ; console, which is what New means.
    pop si                          ; **SI IS THE WINDOW AND bas_new ENDS IN
                                    ; bas_conreset, WHICH LOADS SI WITH THE
                                    ; BANNER.** .redraw hands SI to
                                    ; bas_abdismiss and bas_repaint, and a
                                    ; repaint through the wrong pointer draws
                                    ; nothing while every byte of state is
                                    ; already correct - so New cleared the
                                    ; program and the screen kept showing it.
                                    ; .run and .stop below both bracket for
                                    ; this reason; New was the path that did
                                    ; not, back when it only reset the console
                                    ; and nothing it touched was on screen.
    jmp .redraw
.about:
    mov bx, si
    jmp bas_about                   ; tail call: the card's ret is ours
.run:
    ; --- Run: compile the editor's text and run it (baslang.inc) ------------
    or al, al
    jnz .stop                       ; item 1 = Stop
    push si                         ; item 0 = Run: compile and run the text
    mov byte [bas_bad], 0           ; in the editor, for real
    call bas_run
    pop si
    jmp .redraw
.stop:
    push si
    mov si, bas_s_stop
    call con_say
    pop si
.redraw:
    call bas_abdismiss              ; CF=1: the card came down, and that
    jnc bas_repaint                 ; repaint drew the new status already
    ret

; -----------------------------------------------------------------------------
; bas_onkey - W_ONKEY: AL = ascii, AH = scan, SI = our window
; out: nothing; preserves every register
;
; The gfx lock is held but NO CLIP REGION IS ARMED - os88ui.inc's own contract
; says it plainly: "nothing armed one for a click, a key or a menu pick"
; (SPEC.md 11.3). So a handler that draws arms its own, and does not undo it:
; the region dies at the kernel's gfx_unlock.
;
; CF=1 from os88text_key means the box did not want that keystroke, and
; nothing else here does either - Escape, Tab and the function keys fall
; through to the kernel, which is what the control is for. The About card is
; the one thing taken before the box sees it.
; -----------------------------------------------------------------------------
bas_onkey:
    push ax
    push bx
    push si
    ; THE CARD TAKES THE KEYSTROKE, exactly as bas_onclick lets it take a
    ; click. This handler draws the EDITOR, and the card is drawn over the
    ; same content by bas_paint - so without this a keystroke with the card up
    ; letters the program text across it and leaves it in pieces until
    ; something else repaints. One key puts the card away and does nothing
    ; else; os88ui_abdismiss repaints, so the editor is drawn by that.
    cmp byte [bas_abon], 0
    je .edit
    call bas_abdismiss              ; SI = the window, as it wants
    jmp .out
.edit:
    cmp ax, BAS_KEY_RUN             ; **F5 RUNS IT**, which is QuickBASIC's
    je .run                         ; key and the one a BASIC is reached for
    mov bx, si                      ; BX = our window, for the clip
    mov si, bas_tx
    call os88text_key               ; AL/AH is the keystroke, SI the block
    jc .out                         ; CF=1: not ours
    call OSAPI_WM_CLIP_SET          ; BX is still our window: os88text_key
    jc .out                         ; preserves it, and CF=1 here means not one
    mov si, bas_tx                  ; pixel of us is visible. wm_clip_set has
    call os88text_draw              ; SI of its own, so the block is reloaded
    jmp short .out                  ; **AND NOT INTO .run BELOW.** A label put
                                    ; in front of `.out` is reached by every
                                    ; path that falls to it: without this the
                                    ; edit path ran the program on EVERY
                                    ; keystroke the box accepted, which read
                                    ; on the console as each answer printed
                                    ; twice with the half-typed line's error
                                    ; between them (7, 7, expected a number,
                                    ; expected a number, 42, 42)
.run:
    ; THE MENU ITEM'S OWN PATH, not a second copy of it: bas_oncmd takes
    ; AH = the menu and AL = the item, so F5 is Run/Run spelled in registers.
    ; A copy here would be a second place to keep the repaint and the
    ; [bas_bad] reset in step, and this proc owes its caller every register,
    ; so the three bas_oncmd clobbers that are not already banked are.
    push cx
    push dx
    push di
    mov ax, 0x0100                  ; AH = 1 (Run), AL = 0 (its first item)
    call bas_oncmd                  ; SI is still the window, which is what
    pop di                          ; it wants; it keeps SI across the run
    pop dx
    pop cx
.out:
    pop si
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; bas_onclick - W_ONCLICK: CX = x, DX = y, SI = our window
; out: nothing; preserves every register
;
; **SI GOES BACK AS IT CAME.** apps/os88api.inc is emphatic: ui_task arms the
; release to the SI it finds AFTER this returns (SPEC.md 13.7), so a handler
; that comes back with SI pointing elsewhere has named that as the window and
; the release goes through it. BP holds the window across the body instead.
;
; The About card first - a card the user cannot click away is not a card - and
; the editor only if the click was not spent on it.
; -----------------------------------------------------------------------------
bas_onclick:
    push ax
    push bx
    push cx
    push dx
    push si
    push bp
    mov bp, si                      ; BP = our window, held (a plain register
                                    ; hold, not an address: SS != DS here)
    call bas_abdismiss              ; SI = the window, as it wants
    jc .out                         ; CF=1: the click was spent on the card
    mov si, bas_tx
    call os88text_click             ; CX/DX = the click
    jc .out                         ; CF=1: outside the box
    mov bx, bp
    call OSAPI_WM_CLIP_SET
    jc .out
    mov si, bas_tx
    call os88text_draw
.out:
    pop bp
    pop si                          ; ...and SI is the window again
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; bas_about - the OSAPI_ABOUT_SET handler (slot 0x018A)
; in:  SI = our window ptr; UI task, gfx lock HELD
; out: nothing; clobbers BX/SI, which any window callback may
; -----------------------------------------------------------------------------
bas_about:
    mov byte [bas_abon], 1
    mov bx, si
    mov si, bas_ablines
    jmp os88ui_about                ; arms the clip itself - a menu dispatch
                                    ; arrives without one (SPEC.md 11.3)

; -----------------------------------------------------------------------------
; bas_abdismiss - take the card down if it is up; also the W_ONCLICK
; in:  SI = window ptr; gfx lock held (CX/DX = the click, unused: any click
;      anywhere on the card dismisses it)
; out: CF = 1 if the click was spent on it; clobbers AX and BX
; -----------------------------------------------------------------------------
bas_abdismiss:
    mov bx, bas_abon
    mov ax, bas_repaint
    jmp os88ui_abdismiss            ; cmp/clear/clip/repaint/answer: the
                                    ; library's, and CF is its

; -----------------------------------------------------------------------------
; bas_repaint - erase the content and draw it again
; in:  SI = window ptr; caller holds the gfx lock
; out: nothing; preserves all registers
;
; The window is not resizable, so the content rect is the derived constant
; above from the wm_content origin and no OSAPI_WM_GROW is owed. A resize
; (SPEC.md 11.96) would make that false and is owed with the GUI verbs.
; -----------------------------------------------------------------------------
bas_repaint:
    push ax
    push bx
    push cx
    push dx
    mov al, CWHITE
    call OSAPI_SET_COLOR
    mov bx, si
    call OSAPI_WM_CONTENT            ; AX = content left, DX = content top
    mov bx, dx
    mov cx, ax
    add cx, BAS_CONT_W - 1
    add dx, BAS_CONT_H - 1
    call OSAPI_GFX_FILL
    call bas_paint                   ; SI = window ptr still
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- window template (SPEC.md 11: 16 bytes, 8 words) -------------------------
bas_tpl:
    dw 80, 40, BAS_W, BAS_H
    dw bas_ttl, bas_paint, bas_onkey, bas_onclick

; --- the app menu set (SPEC.md 12.2) -----------------------------------------
; TWO menus of MENU_APPMAX's five. OS88_MENUSET_END asserts the cap, which is
; the build-time half of what SPEC.md 126's own MENU statement has to do at
; run time: the kernel drops a sixth silently.
    OS88_MENUSET bas_menus, bas_name, bas_oncmd
        OS88_MENU bas_m_file, bas_i_file, 2
        OS88_MENU bas_m_run,  bas_i_run,  2
    OS88_MENUSET_END bas_menus

bas_name:
bas_ttl:        db 'BASIC', 0        ; the bar label and the window title: ONE
                                     ; string, named twice for the two readers
bas_m_file:     db 'File', 0
bas_i_file:     dw bas_it_new, bas_it_about
bas_it_new:     db 'New', 0
bas_it_about:   db 'About', 0
bas_m_run:      db 'Run', 0
bas_i_run:      dw bas_it_run, bas_it_stop
bas_it_run:     db 'Run', 0
bas_it_stop:    db 'Stop', 0

bas_s_banner:   db 'BASIC/8088 - SPEC.md 126', 13, 10
                db 'Ready', 13, 10, 0
bas_s_stop:     db 'Nothing to stop.', 13, 10, 0

; --- the standard About card's lines (SPEC.md 20.5.1) ------------------------
bas_ablines:
    dw bas_ab1, bas_ab2, bas_ab3, bas_ab4, 0
bas_ab1:        db 'BASIC/8088', 0
bas_ab2:        db 0
bas_ab3:        db 'A BASIC for OS/8088,', 0
bas_ab4:        db 'SPEC.md 126', 0

; --- the shared controls (SPEC.md 20.5.1) ------------------------------------
%define OS88UI_ABOUT
%define OS88UI_NOBTN
%define OS88UI_ABDISMISS
%include "os88ui.inc"

; --- the console (SPEC.md 70.8) ----------------------------------------------
; CON_TTY is the teletype half - con_write, con_say, con_open - which is what
; PRINT is going to be. The full-screen half (CON_FSX) is not wanted: a BASIC
; program's output belongs in its window.
;
; Its bss follows OURS rather than starting at os88_image_end, so the two do
; not overlap; CON_BSS is defined by the include, which is why OS88_BSS comes
; after it.
; os88text.inc needs os88ui.inc's UI_* macros, so it comes after it.
%include "os88text.inc"

; --- software floating point (SPEC.md 84) ------------------------------------
; Opt-OUT gates: what a package does not call it need not carry (84.8). The
; transcendentals, sqrt and pow arrive with the built-in library in wave 5.
%define OS88FP_NOTRANS
%define FP_NO_SQRT
%define FP_NO_POW
%include "os88fp.inc"

%define CON_TTY
%define CON_BSS_AT (os88_image_end + BAS_BSS_OWN)
%include "os88con.inc"

; The language itself (SPEC.md 126.5). After os88con.inc, because every one of
; its outputs goes through con_say.
%include "basic/baslang.inc"

; --- the bss this package declares for itself, as OFFSETS ------------------
; The chain is laid out TWICE and that is the point. Here it is pure
; constants, so BAS_BSS_OWN - the number OS88_BSS reserves and the base
; os88con.inc's own bss is placed above (CON_BSS_AT) - is DERIVED from the
; fields rather than hand-summed beside them. Below OS88_IMAGE_END the same
; chain is laid again as LABELS, each one `os88_image_end + its offset here`,
; because the label the fields hang off does not exist until the image is
; closed and the size has to be known before it is.
;
; It was one hand-written sum until the audit: `BAS_STK_MAX*2` paid for a
; value stack of WORDS, wave 1c widened a slot to 8 bytes to hold a double,
; and the sum kept paying the old price - so bas_numbuf, bas_reg, bas_fp and
; os88fp.inc's register-A scratch all sat 96 bytes inside the stack, with
; bas_exec's bound check permitting all 16 slots because IT counted in slots.
; Four slots fitted; the FIFTH landed on bas_numbuf. It takes a RIGHT-NESTED
; expression to get there - `1+(2+(3+(4+5)))` holds five operands at once,
; where `1+2*3*4` reaches only three, because + and * are left-associative
; and the interpreter folds each pair as soon as it has both.
;
; A DERIVED TOTAL CANNOT DRIFT; an assertion only reports that it has. The
; two `times` lines of the house idiom for an unchecked OS88_BSS literal DO
; work here - they were written, they fired on this very shortfall, and they
; assemble clean against the chain below - but with the total derived there
; is nothing left for them to check, so they are not carried.
;
; Placement is free: every term this names (OS88TEXT_SZ, BAS_OPS_MAX,
; BAS_STK_MAX, BAS_SLOT, R_N) comes from an include above, and the chain
; assembles equally well beside BAS_PROG_MAX, where the old literal was. It
; sits here so the fields read in the same order as the labels below it.
; (Both of those were claimed the other way round in this comment for an
; afternoon, on a build that was really failing for one undefined symbol.)
BAS_B_bas_abon   equ 0
BAS_B_bas_tx     equ 2
BAS_B_bas_prog   equ BAS_B_bas_tx + OS88TEXT_SZ
BAS_B_bas_src    equ BAS_B_bas_prog + BAS_PROG_MAX
BAS_B_bas_line   equ BAS_B_bas_src + 2
BAS_B_bas_opn    equ BAS_B_bas_line + 2
BAS_B_bas_bad    equ BAS_B_bas_opn + 2
BAS_B_bas_ops    equ BAS_B_bas_bad + 2
BAS_B_bas_stk    equ BAS_B_bas_ops + BAS_OPS_MAX
BAS_B_bas_numbuf equ BAS_B_bas_stk + BAS_STK_MAX*BAS_SLOT
BAS_B_bas_reg    equ BAS_B_bas_numbuf + 8
BAS_B_bas_nvar   equ BAS_B_bas_reg + R_N*2
BAS_B_bas_vars   equ BAS_B_bas_nvar + 2
BAS_B_bas_nblk   equ BAS_B_bas_vars + BAS_VAR_MAX*BAS_VAR_SZ
BAS_B_bas_blkv   equ BAS_B_bas_nblk + 2
BAS_B_bas_blkex  equ BAS_B_bas_blkv + 2
BAS_B_bas_forlim equ BAS_B_bas_blkex + 2
BAS_B_bas_forjin equ BAS_B_bas_forlim + 2
BAS_B_bas_fortop equ BAS_B_bas_forjin + 2
BAS_B_bas_forcmp equ BAS_B_bas_fortop + 2
BAS_B_bas_casech equ BAS_B_bas_forcmp + 2
BAS_B_bas_blk    equ BAS_B_bas_casech + 2
BAS_B_bas_fp     equ BAS_B_bas_blk + BAS_BLK_MAX*BAS_BLK_SZ
BAS_B_fp_as      equ BAS_B_bas_fp + 4
BAS_B_fp_bs      equ BAS_B_fp_as + 1
BAS_B_fp_ae      equ BAS_B_fp_bs + 1
BAS_B_fp_be      equ BAS_B_fp_ae + 2
BAS_B_fp_am0     equ BAS_B_fp_be + 2
BAS_B_fp_am1     equ BAS_B_fp_am0 + 2
BAS_B_fp_am2     equ BAS_B_fp_am1 + 2
BAS_B_fp_am3     equ BAS_B_fp_am2 + 2
BAS_B_fp_bm0     equ BAS_B_fp_am3 + 2
BAS_B_fp_bm1     equ BAS_B_fp_bm0 + 2
BAS_B_fp_bm2     equ BAS_B_fp_bm1 + 2
BAS_B_fp_bm3     equ BAS_B_fp_bm2 + 2
BAS_B_fp_t0      equ BAS_B_fp_bm3 + 2
BAS_B_fp_t1      equ BAS_B_fp_t0 + 2
BAS_B_fp_t2      equ BAS_B_fp_t1 + 2
BAS_B_fp_t3      equ BAS_B_fp_t2 + 2
BAS_B_fp_p0      equ BAS_B_fp_t3 + 2
BAS_B_fp_sticky  equ BAS_B_fp_p0 + 16
BAS_B_fp_tmp     equ BAS_B_fp_sticky + 2
BAS_B_fp_dig     equ BAS_B_fp_tmp + 2
BAS_B_fp_d10     equ BAS_B_fp_dig + 24
BAS_B_fp_nd      equ BAS_B_fp_d10 + 2
BAS_B_fp_sgn     equ BAS_B_fp_nd + 2
BAS_B_fp_sq      equ BAS_B_fp_sgn + 2
BAS_B_fp_g       equ BAS_B_fp_sq + 8
BAS_B_fp_tv      equ BAS_B_fp_g + 8
BAS_B_fp_hw      equ BAS_B_fp_tv + 8
BAS_B_fp_x1      equ BAS_B_fp_hw + 1
BAS_B_fp_x2      equ BAS_B_fp_x1 + 10
BAS_B_fp_sw      equ BAS_B_fp_x2 + 10
BAS_B_fp_e0      equ BAS_B_fp_sw + 2
BAS_B_fp_e1      equ BAS_B_fp_e0 + 8
BAS_B_fp_e2      equ BAS_B_fp_e1 + 8
BAS_B_fp_e3      equ BAS_B_fp_e2 + 8
BAS_B_fp_ek      equ BAS_B_fp_e3 + 8
BAS_B_bas_fpend  equ BAS_B_fp_ek + 2
BAS_B_bas_fpbuf  equ BAS_B_bas_fpend

BAS_BSS_OWN equ BAS_B_bas_fpbuf + 32    ; ...the whole of it, DERIVED

    OS88_BSS BAS_BSS_OWN + CON_BSS
    OS88_IMAGE_END

; --- loader-zeroed bss (SPEC.md 21 step 5) -----------------------------------
; The loader zeroes all of it, which is what [bas_abon] and [bas_bad] rely on:
; the first paint happens when the loader shows the window, before any command
; can run, and it reads both. Neither is initialised in bas_entry, because an
; initialiser in the entry proc is a line that can be deleted while the paint
; still looks right on every path a test takes.
;
; (This comment described a [bas_status] pointer until the audit. There has
; never been one - the status line is con_say's, on the console pane - and
; nothing but the comment said otherwise, which is how it survived.)
bas_abon        equ os88_image_end + BAS_B_bas_abon   ; byte: the About card is up
                                         ; +1 is spare, and deliberately: it
                                         ; keeps the two below even, so the
                                         ; console's cell buffer - words of
                                         ; (character, attribute) - starts on
                                         ; an even address
bas_tx          equ os88_image_end + BAS_B_bas_tx   ; the editor's block (SPEC.md 83)
bas_prog        equ os88_image_end + BAS_B_bas_prog   ; ...and the program text it edits,
                                         ; NUL-terminated, lines separated by
                                         ; a single LF
; --- the language's own state (baslang.inc) ---------------------------------
bas_src         equ os88_image_end + BAS_B_bas_src   ; word: the scanner's cursor
bas_line        equ os88_image_end + BAS_B_bas_line   ; word: the line it is on, for errors
bas_opn         equ os88_image_end + BAS_B_bas_opn   ; word: bytes emitted so far
bas_bad         equ os88_image_end + BAS_B_bas_bad   ; byte: a refusal has been reported
                                         ; +1 spare, to keep the rest even
bas_ops         equ os88_image_end + BAS_B_bas_ops   ; the compiled op stream
bas_stk         equ os88_image_end + BAS_B_bas_stk   ; the evaluation stack, BAS_STK_MAX
                                         ; slots of BAS_SLOT bytes - NOT words
                                         ; (wave 1c widened a slot to hold a
                                         ; double, and bas_exec's bound check
                                         ; counts in slots)
bas_numbuf      equ os88_image_end + BAS_B_bas_numbuf   ; 8 bytes: ' -32768', 0
bas_reg         equ os88_image_end + BAS_B_bas_reg   ; the tier C register file, R_N words
bas_nvar        equ os88_image_end + BAS_B_bas_nvar   ; word: how many of the
                                         ; table below are in use this RUN
bas_vars        equ os88_image_end + BAS_B_bas_vars   ; the scalar variables
                                         ; (SPEC.md 126.4): BAS_VAR_MAX entries
                                         ; of BAS_VAR_SZ. A name is NOT stored -
                                         ; the entry points at the one in
                                         ; bas_prog, so a name is any length and
                                         ; two long names cannot alias by being
                                         ; truncated to a common prefix. The
                                         ; text is stable for the whole of a
                                         ; run, which is the only window the
                                         ; table lives in
bas_nblk        equ os88_image_end + BAS_B_bas_nblk   ; word: open blocks
bas_blkv        equ os88_image_end + BAS_B_bas_blkv   ; word: the loop
                                         ; variable a FOR is pushing, or
                                         ; the one a NEXT just popped
bas_blkex       equ os88_image_end + BAS_B_bas_blkex   ; word: the exit
                                         ; chain a bas_blkpop just took
bas_forlim      equ os88_image_end + BAS_B_bas_forlim  ; FOR's four
bas_forjin      equ os88_image_end + BAS_B_bas_forjin  ; scratch words, used
bas_fortop      equ os88_image_end + BAS_B_bas_fortop  ; only while ONE header
bas_forcmp      equ os88_image_end + BAS_B_bas_forcmp  ; is being compiled -
                                         ; a nested FOR's header is finished
                                         ; before the outer one's NEXT, so
                                         ; one set serves any nesting
bas_casech      equ os88_image_end + BAS_B_bas_casech ; word: the chain of
                                         ; a CASE's matched-jumps, alive only
                                         ; while ONE CASE line is compiled -
                                         ; a CASE cannot hold another, so one
                                         ; word serves, for bas_forcmp's reason
bas_blk         equ os88_image_end + BAS_B_bas_blk    ; ...and the stack of
                                         ; them, COMPILE TIME ONLY: a loop
                                         ; remembers where to jump back to and
                                         ; which forward word to patch, and
                                         ; none of it survives into the run
bas_fp          equ os88_image_end + BAS_B_bas_fp   ; dword: the far pointer a dynamic
                                         ; OSAPI call is made through

; --- os88fp.inc's scratch (SPEC.md 84.3: the include declares no storage) ----
fp_as           equ os88_image_end + BAS_B_fp_as
fp_bs           equ os88_image_end + BAS_B_fp_bs
fp_ae           equ os88_image_end + BAS_B_fp_ae
fp_be           equ os88_image_end + BAS_B_fp_be
fp_am0          equ os88_image_end + BAS_B_fp_am0
fp_am1          equ os88_image_end + BAS_B_fp_am1
fp_am2          equ os88_image_end + BAS_B_fp_am2
fp_am3          equ os88_image_end + BAS_B_fp_am3
fp_bm0          equ os88_image_end + BAS_B_fp_bm0
fp_bm1          equ os88_image_end + BAS_B_fp_bm1
fp_bm2          equ os88_image_end + BAS_B_fp_bm2
fp_bm3          equ os88_image_end + BAS_B_fp_bm3
fp_t0           equ os88_image_end + BAS_B_fp_t0
fp_t1           equ os88_image_end + BAS_B_fp_t1
fp_t2           equ os88_image_end + BAS_B_fp_t2
fp_t3           equ os88_image_end + BAS_B_fp_t3
fp_p0           equ os88_image_end + BAS_B_fp_p0   ; 8 words: the 128-bit product
fp_sticky       equ os88_image_end + BAS_B_fp_sticky
fp_tmp          equ os88_image_end + BAS_B_fp_tmp
fp_dig          equ os88_image_end + BAS_B_fp_dig   ; 24: the digit string fp_ftoa builds
fp_d10          equ os88_image_end + BAS_B_fp_d10
fp_nd           equ os88_image_end + BAS_B_fp_nd
fp_sgn          equ os88_image_end + BAS_B_fp_sgn
fp_sq           equ os88_image_end + BAS_B_fp_sq   ; 8: fp_sqrt's input (dropped, but the
fp_g            equ os88_image_end + BAS_B_fp_g   ; layout is the published one)
fp_tv           equ os88_image_end + BAS_B_fp_tv
fp_hw           equ os88_image_end + BAS_B_fp_hw   ; the coprocessor path's flag
fp_x1           equ os88_image_end + BAS_B_fp_x1   ; 10: A in 80-bit form
fp_x2           equ os88_image_end + BAS_B_fp_x2
fp_sw           equ os88_image_end + BAS_B_fp_sw
fp_e0           equ os88_image_end + BAS_B_fp_e0
fp_e1           equ os88_image_end + BAS_B_fp_e1
fp_e2           equ os88_image_end + BAS_B_fp_e2
fp_e3           equ os88_image_end + BAS_B_fp_e3
fp_ek           equ os88_image_end + BAS_B_fp_ek
bas_fpend       equ os88_image_end + BAS_B_bas_fpend

; bas_sayfp's OWN output buffer. fp_ftoa's string may be 17 significant
; digits, a sign, a point and an exponent, so 32 is generous and the cost of
; being wrong here is the defect above.
bas_fpbuf       equ os88_image_end + BAS_B_bas_fpbuf
