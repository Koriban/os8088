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
.out:
    pop si
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

    ; --- the editor pane ------------------------------------------------------
    ; The ink first. OSAPI_GFX_FRAME draws in [gfx_color], which is GLOBAL
    ; state and not an argument, and bas_repaint has just set it to CWHITE for
    ; its fill - so without this the frames are drawn white on white, which
    ; assembles, runs, and shows a window with its captions and no panes. It
    ; did exactly that on the first boot; nothing but looking would have said
    ; so, which is PERFORMANCE.md's point about chrome.
    mov al, CBLACK
    call OSAPI_SET_COLOR

    mov ax, di
    mov bx, si
    mov cx, di
    add cx, BAS_CONT_W - 1
    mov dx, si
    add dx, BAS_ED_H - 1
    call OSAPI_GFX_FRAME

    mov cx, di
    add cx, 6
    mov dx, si
    add dx, 6
    push si
    mov si, bas_s_edit
    mov ax, (CWHITE << 8) | CBLACK  ; AL = ink, AH = ground: W_PAINT arrives
    call OSAPI_FONT_RUN             ; white-filled, and font_run draws the
    pop si                          ; ground and the glyphs in ONE pass, which
                                    ; is CLAUDE.md's hard rule - a gfx_fill
                                    ; then a font_str writes every pixel twice

    ; --- the console pane -----------------------------------------------------
    mov ax, di
    mov bx, si
    add bx, BAS_CON_Y
    mov cx, di
    add cx, BAS_CONT_W - 1
    mov dx, si
    add dx, BAS_CON_Y + BAS_CON_H - 1
    call OSAPI_GFX_FRAME

    mov cx, di
    add cx, 6
    mov dx, si
    add dx, BAS_CON_Y + 6
    push si
    mov si, bas_s_con
    mov ax, (CWHITE << 8) | CBLACK
    call OSAPI_FONT_RUN
    pop si

    ; --- the status line, which is what Run writes ---------------------------
    mov cx, di
    add cx, 6
    mov dx, si
    add dx, BAS_CON_Y + 22
    push si
    mov si, [bas_status]            ; bas_oncmd is its only writer...
    or si, si                       ; ...and the LOADER is the first one: bss
    jnz .havestatus                 ; arrives zeroed (SPEC.md 21 step 5), and a
    mov si, bas_s_ready             ; zero is not a string. The window is shown
.havestatus:                        ; before any command runs, so without this
    mov ax, (CWHITE << 8) | CBLACK  ; the first paint draws through a null
    call OSAPI_FONT_RUN
    pop si

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
    mov word [bas_status], bas_s_new ; item 0 = New
    jmp .redraw
.about:
    mov bx, si
    jmp bas_about                   ; tail call: the card's ret is ours
.run:
    ; --- Run: wave 0 has no interpreter, and says so rather than pretending --
    mov word [bas_status], bas_s_norun
    or al, al
    jz .redraw
    mov word [bas_status], bas_s_stop
.redraw:
    call bas_abdismiss              ; CF=1: the card came down, and that
    jnc bas_repaint                 ; repaint drew the new status already
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
    dw bas_ttl, bas_paint, 0, bas_abdismiss   ; no onkey in wave 0: the editor
                                              ; arrives in 0c and takes it

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

bas_s_edit:     db 'Program', 0
bas_s_con:      db 'Output', 0
bas_s_ready:    db 'Ready', 0
bas_s_new:      db 'New program', 0
bas_s_norun:    db 'No interpreter yet - wave 0 is the seam (SPEC.md 126)', 0
bas_s_stop:     db 'Nothing to stop', 0

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

    OS88_BSS 4
    OS88_IMAGE_END

; --- loader-zeroed bss (SPEC.md 21 step 5) -----------------------------------
; [bas_status] is a POINTER and the loader zeroes it (SPEC.md 21 step 5), so
; the first paint - which happens when the loader shows the window, before any
; command can run - would draw through a null. bas_paint reads a zero as
; "Ready" rather than bas_entry storing it, because an initialiser in the
; entry proc is a line that can be deleted while the paint still looks right
; on every path a test takes.
bas_abon        equ os88_image_end + 0   ; byte: the About card is up
bas_status      equ os88_image_end + 2   ; word: near ptr to the status string
