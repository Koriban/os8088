; =============================================================================
; os8088 - apps/basic/basic.asm
;
; BASIC (SPEC.md 126), wave 0: THE SEAM.
;
; Nothing of the language is here. What this wave proves is the frame the
; language will be built in - the package skeleton, the two panes, the menu
; bar and the command path - and, above all, THE SIZE. SPEC.md 126.6 splits
; the interpreter across BASIC.O88 and BASIC.OVL on the arithmetic that it
; cannot fit beside sixty-four built-ins, an editor and a console in one
; 63.5KB segment, and that arithmetic is worth nothing until the empty frame
; has been measured. So this is the baseline the overlay decision is taken
; against, and `make basic` prints it.
;
; TWO PANES, one window: the editor above and the console below, which is
; SPEC.md 126's shape for both halves of the target - a GUI program and a
; text one are the same program with a different surface (126.8). Wave 0
; draws their frames and captions and owns no text widget yet: os88text.inc
; (SPEC.md 83) becomes the editor in wave 0c and os88con.inc (70.8) the
; console in 0b, each measured as it lands.
;
; Run does nothing, deliberately and visibly. It writes one line into the
; console pane saying so, which is the smallest thing that proves the whole
; path - a menu pick reaching a handler reaching a repaint - without
; pretending to be an interpreter.
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
BAS_BSS_OWN equ 2 + OS88TEXT_SZ + BAS_PROG_MAX  ; ours, ahead of the console's

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
                                    ; go in wave 0c

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
    call con_open
    mov word [con_cy], CON_ROWS - BAS_CON_ROWS
    mov word [con_cx], 0
    mov si, bas_s_banner
    jmp con_say                     ; tail call: con_say's ret is ours

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

    call con_markall                ; a W_PAINT owes the WHOLE pane: the dirty
    call con_rows_owed              ; bitmap is for the incremental case, and
                                    ; this is not one

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
    call bas_conreset               ; item 0 = New: back to what a fresh
    jmp .redraw                     ; launch shows
.about:
    mov bx, si
    jmp bas_about                   ; tail call: the card's ret is ours
.run:
    ; --- Run: wave 0 has no interpreter, and says so rather than pretending --
    push si
    mov si, bas_s_norun
    or al, al
    jz .sayit
    mov si, bas_s_stop
.sayit:
    call con_say                    ; con_write's LF scrolls and CR does not
    pop si                          ; move the row - the ROM's teletype, not
                                    ; ANSI's NEL - so every line here ends 13,10
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
; CF=1 from os88text_key means the box did not want that keystroke, and in
; wave 0c nothing else does either - Escape, Tab and the function keys fall
; through to the kernel, which is what the control is for.
; -----------------------------------------------------------------------------
bas_onkey:
    push ax
    push bx
    push si
    mov bx, si                      ; BX = our window, for the clip
    mov si, bas_tx
    call os88text_key               ; AL/AH is the keystroke, SI the block
    jc .out                         ; CF=1: not ours
    call OSAPI_WM_CLIP_SET          ; BX is still our window: os88text_key
    jc .out                         ; preserves it, and CF=1 here means not one
    mov si, bas_tx                  ; pixel of us is visible. wm_clip_set has
    call os88text_draw              ; SI of its own, so the block is reloaded
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
; in:  SI = window ptr; gfx lock held (CX/DX = the click, unused in wave 0)
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
; The window is not resizable in wave 0, so the content rect is the derived
; constant above from the wm_content origin and no OSAPI_WM_GROW is owed.
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

bas_s_banner:   db 'BASIC for os8088 - SPEC.md 126', 13, 10
                db 'Wave 0b: the console pane is real.', 13, 10
                db 'Ready', 13, 10, 0
bas_s_norun:    db 'No interpreter yet - wave 0 is the seam.', 13, 10, 0
bas_s_stop:     db 'Nothing to stop.', 13, 10, 0

; --- the standard About card's lines (SPEC.md 20.5.1) ------------------------
bas_ablines:
    dw bas_ab1, bas_ab2, bas_ab3, bas_ab4, 0
bas_ab1:        db 'BASIC for os8088', 0
bas_ab2:        db 0
bas_ab3:        db 'SPEC.md 126 - wave 0,', 0
bas_ab4:        db 'the seam', 0

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

%define CON_TTY
%define CON_BSS_AT (os88_image_end + BAS_BSS_OWN)
%include "os88con.inc"

    OS88_BSS BAS_BSS_OWN + CON_BSS
    OS88_IMAGE_END

; --- loader-zeroed bss (SPEC.md 21 step 5) -----------------------------------
; [bas_status] is a POINTER and the loader zeroes it (SPEC.md 21 step 5), so
; the first paint - which happens when the loader shows the window, before any
; command can run - would draw through a null. bas_paint reads a zero as
; "Ready" rather than bas_entry storing it, because an initialiser in the
; entry proc is a line that can be deleted while the paint still looks right
; on every path a test takes.
bas_abon        equ os88_image_end + 0   ; byte: the About card is up
                                         ; +1 is spare, and deliberately: it
                                         ; keeps the two below even, so the
                                         ; console's cell buffer - words of
                                         ; (character, attribute) - starts on
                                         ; an even address
bas_tx          equ os88_image_end + 2   ; the editor's block (SPEC.md 83)
bas_prog        equ bas_tx + OS88TEXT_SZ ; ...and the program text it edits,
                                         ; NUL-terminated, lines separated by
                                         ; a single LF
