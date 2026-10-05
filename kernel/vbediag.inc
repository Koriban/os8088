; =============================================================================
; VBEDIAG - move a window across the bank boundary with NO MOUSE (SPEC.md 39.29.12)
; =============================================================================
;
; `make VBEDIAG=1` and boot it. Fourteen seconds after the desktop settles the
; kernel opens a window of its own, drags it DOWN across row 512, drags it back
; UP, and stops. Nothing is clicked and nothing is typed.
;
; WHY IT HAS TO BE A KNOB, which is this tree's own argument used again: a
; package needs a double-click, and 86Box takes no scripted input at all - no
; QMP, no socket, and its pointer capture WARPS the cursor back to centre after
; every motion event, so an XTEST relative move and the warp cancel exactly
; (tools/os88box.py measured it: the host pointer reads the same coordinate
; after every move). STKDIAG and BOOTMARK exist for the same reason - the
; operator's click lands inside the thing being measured, or cannot be sent.
;
; WHAT IT IS FOR. The field reports a window that MOVES leaving its old image
; behind on a 1024x768 desktop, and the two observations that bound it are:
;
;   - a FULL repaint clears it. Swapping themes does; so does the screen saver.
;   - a window DRAG does not, and neither does the refit a mode switch runs.
;
; Those are two different repaints. wm_paint_all redraws the whole desktop;
; ui_drag's commit calls wm_dmg_vacate / wm_dmg_union / wm_paint_dmg, which
; redraws only the damage and reaches the dither through an ARMED CLIP REGION
; (wm_dmg_gray). So the suspect is the damage path and not the renderer, and
; this knob drives EXACTLY that path - the same three calls in the same order,
; with the window's own rect - rather than a repaint of its own invention. A
; reproduction that used wm_paint_all would prove nothing, because that is the
; arm already known to work.
;
; IT RUNS ON THE FIELD MACHINE TOO. The floppy boots a 4025CDT exactly as it
; boots 86Box, so the same disk answers the same question on the card that
; actually shows the defect - which matters, because 86Box's Trident has shown
; a clean desktop through every build in which the NeoMagic was broken
; (SPEC.md 39.29.8.2).
;
; WHAT IT DOES NOT DO: it draws no numbers. The window record is readable from
; the picture - where the window IS, and whether a second copy of it is left
; where it WAS - and a numeric panel would need a formatter this does not have
; room to justify yet.
; -----------------------------------------------------------------------------

VBD_T0      equ 18 * 14         ; ticks before step 1 - the desktop, settled.
                                ; 18.2 Hz, so this is ~14 seconds, which is
                                ; inside os88box.py's default 95-second boot
                                ; wait with room for a slow floppy
VBD_GAP     equ 18 * 5          ; ...and between the steps, so a photograph or
                                ; a screenshot can land between any two
VBD_DY      equ 330             ; how far DOWN. The window starts at y=140 and
                                ; is 200 tall, so it lands at 470..670 - ACROSS
                                ; row 512, which is the whole point. A move
                                ; that stayed inside one bank would reproduce
                                ; nothing and would look like a pass

VBD_SH      equ 2               ; the drop shadow, included in the vacated rect
                                ; the way ui_drag includes it

vbd_state:  db 0                ; 0 = not armed yet, 1 = waiting to open,
                                ; 2 = opened, 3 = moved down, 4 = finished
vbd_win:    dw 0                ; the window, once there is one
vbd_due:    dw 0                ; the tick the next step is owed at - SEEDED ON
                                ; THE FIRST CALL and not at assembly time,
                                ; because `ticks` starts at the SCHEDULER and
                                ; ui_task does not run until the desktop
                                ; exists. A 360KB floppy boot is 90 seconds, so
                                ; an absolute VBD_T0 would already be in the
                                ; past and every step would fire at once
vbd_oy:     dw 0                ; where it was, for the vacate

vbd_tpl:    dw 180, 140         ; x, y - ABOVE the boundary, so the first move
            dw 360, 200         ; w, h   is the one that crosses it
            dw vbd_ttl, 0, 0, 0 ; title, paint, onkey, onclick. W_PAINT = 0 is
                                ; legal (wm_draw_win tests it), and the frame
                                ; plus the caption is enough to see a ghost by
vbd_ttl:    db 'VBEDIAG', 0

; -----------------------------------------------------------------------------
; vbd_step - called from the top of ui_task's loop; does nothing until it is due
; in:       -
; out:      nothing; every register preserved
;
; `ticks` wraps at 65536, which is just under an hour, and every comparison
; here is a SUBTRACTION so the wrap costs nothing: `ticks - due` is still the
; right sign across it where `ticks >= due` is not.
; -----------------------------------------------------------------------------
vbd_step:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    cmp byte [vbd_state], 4
    je .out                     ; finished: one compare, forever after
    cmp byte [vbd_state], 0
    jne .armed
    mov byte [vbd_state], 1     ; FIRST CALL: the clock starts HERE, which is
    jmp short .again            ; the first pass of ui_task and so the first
.armed:                         ; moment a desktop exists to put a window on
    mov ax, [ticks]
    sub ax, [vbd_due]
    js .out                     ; not yet - and signed, for the wrap
    mov al, [vbd_state]
    cmp al, 1
    je .open
    cmp al, 2
    je .down
    cmp al, 3
    je .up
    mov byte [vbd_state], 4     ; nothing left to do
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

    ; --- step 1: open a window of our own ---------------------------------
.open:
    mov si, vbd_tpl
    push cs
    pop es                      ; wm_create reads the template at ES:SI
    call wm_create
    jc .giveup                  ; the table is full: say so by doing nothing
    mov [vbd_win], bx
    call wm_show
    mov byte [vbd_state], 2
    jmp short .again

    ; --- step 2: drag it DOWN, across row 512 ------------------------------
.down:
    mov bx, [vbd_win]
    mov ax, [bx+W_Y]
    mov [vbd_oy], ax
    add ax, VBD_DY
    mov [bx+W_Y], ax
    call vbd_commit
    mov byte [vbd_state], 3
    jmp short .again

    ; --- step 3: ...and back where it came from ----------------------------
.up:
    mov bx, [vbd_win]
    mov ax, [bx+W_Y]
    mov [vbd_oy], ax
    sub ax, VBD_DY
    mov [bx+W_Y], ax
    call vbd_commit
    mov byte [vbd_state], 4
.again:
    mov ax, [ticks]
    add ax, VBD_GAP             ; ...and VBD_T0 for the arm, which is longer
    cmp byte [vbd_state], 1
    jne .seed
    mov ax, [ticks]
    add ax, VBD_T0
.seed:
    mov [vbd_due], ax
    jmp short .out
.giveup:
    mov byte [vbd_state], 4
    jmp short .out

; -----------------------------------------------------------------------------
; vbd_commit - repaint a window that has just MOVED, down ui_drag's own path
; in:       BX = the window, W_Y already written, [vbd_oy] = where it was
; out:      nothing
;
; THE THREE CALLS AND THEIR ORDER ARE ui_drag's AND ARE COPIED DELIBERATELY
; (kernel/ui.inc, SPEC.md 11.91.2): vacate records WHERE IT WAS before the
; union grows the rect past it, and wm_paint_dmg wants the gfx lock already
; held. Reproducing the defect means taking this path and not a tidier one.
; -----------------------------------------------------------------------------
vbd_commit:
    call gfx_lock               ; wm_paint_dmg runs under a CALLER-held lock
    mov si, bx                  ; SI = the window, for both damage calls
    mov ax, [bx+W_X]            ; where it was, drop shadow included
    mov cx, ax
    add cx, [bx+W_W]
    add cx, VBD_SH
    mov bx, [vbd_oy]
    mov dx, bx
    add dx, [si+W_H]
    add dx, VBD_SH
    call wm_dmg_vacate
    call wm_dmg_union           ; ...grown to cover where it is now
    call wm_paint_dmg
    jmp gfx_unlock              ; the tail call ui_drag's own `.done` makes
