; =============================================================================
; os8088 - tests/kbdfsx/kbdfsx.asm
;
; KBDFSX: what the KEYBOARD and the MOUSE are doing either side of a
; FULL-SCREEN bracket, on a machine with no debugger and no serial port free.
;
; The field report this exists for (docs/FIELD-NOTES.md): a Toshiba Satellite
; 4025CDT running the VBE desktop comes back from a full-screen game, or from
; ARTFUL, with the KEYBOARD DEAD and the MOUSE STILL WORKING - the desktop is
; fully usable with the pointer, and only a restart gets the keys back.
;
; --- why that symptom narrows it, and what this therefore samples -----------
;
; The machine has a PS/2 keyboard AND a PS/2 mouse, so BOTH devices are behind
; the one 8042. That rules out the whole shared-buffer family at a stroke: a
; byte stranded in the output buffer with its interrupt edge erased silences
; EVERY device behind that controller, and this machine's mouse is still
; delivering. Whatever stops the keyboard is keyboard-SPECIFIC, and on a PS/2
; machine there are only four things that are:
;
;   IRQ1 MASKED at the master 8259 while IRQ12 (slave, bit 4) stays open.
;       Port 0x21 bit 1. The kernel masks IRQ1 deliberately in two places -
;       mou_p2_init's probe window and the hibernate stub - and both say in
;       their own comments that leaving it masked is a machine with no
;       keyboard. Column `21`.
;   THE 8042 COMMAND BYTE: bit 0 (keyboard interrupt) cleared or bit 4
;       (keyboard interface disabled) set, with bit 1/bit 5 leaving AUX alone.
;       NOT sampled automatically - see the warning below. Menu: `Read 8042`.
;   THE int 09h VECTOR overwritten while int 74h (IRQ12's) survives.
;       Columns `i09` and `i74`, as seg:off.
;   THE BIOS BUFFER: head and tail at 40:1A/40:1C. If the TAIL MOVES when a
;       key is pressed, IRQ1 fired and the ROM stored the byte, so everything
;       above is innocent and the fault is above the ISR. If it does NOT move,
;       the byte never arrived and one of the three above is why. This single
;       column is the fork in the whole investigation.
;
; THE 8042 COMMAND BYTE IS NOT READ ON THE SAMPLE PATH AND MUST NOT BE.
; Reading it is `write 0x20 to 64h, read 60h`, and 60h is the ONE buffer both
; devices share: a keystroke or a mouse packet landing in that window is
; consumed by us and lost, and a mouse packet lost mid-triple desynchronises
; the stream. An instrument that perturbs the thing it is measuring would turn
; "the keyboard died" into "the keyboard died while KBDFSX was watching". It
; is a separate menu item, pressed deliberately, and the row it writes says so.
;
; --- and why the bracket is entered FROM HERE -------------------------------
;
; The report is taken BEFORE, TWICE INSIDE and AFTER one OSAPI_FSX_RUN, then
; every half second for thirty seconds on the window timer. The failure is
; reported as "after exiting", so what matters is whether the state is already
; wrong on the way out or goes wrong some ticks later - and a row every half
; second is what tells those apart. Nothing here has to be timed by hand.
;
; TWO BRACKETS, and the pair IS the experiment: `Full Screen (same mode)`
; never calls OSAPI_FSX_MODE, so SPEC.md 53.6 skips the restore and the video
; mode is never touched; `Full Screen (mode 13h)` sets one, which is what a
; game does and what forces the kernel to put the VBE desktop back through
; VBE.DRV on the way home. If only the second kills the keyboard, the mode
; restore is the trigger and the bracket is innocent.
;
; --- reading the answer -----------------------------------------------------
;
; THE SAVE IS ON THE MENU, reachable with the MOUSE ALONE, and that is the
; whole reason this is not a keyboard-driven report: on the machine this was
; written for the keyboard is dead by the time the interesting rows exist, and
; a report that needed a keystroke to write itself out could never be read.
; `Save Report` writes KBDFSX.TXT to the current volume; the keys S/R also
; work while they still can.
;
; Never on a shipped disk (SPEC.md 24): its own image, vbeprobe's precedent.
;
;   make kbdfsx && make test TESTAPPS=build/kbdfsx.img
;
; Prefix kf_.
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'KBDFSX', kf_entry

KF_HOLD     equ 36              ; ticks the bracket holds before coming home -
                                ; two seconds at 18.2Hz, long enough to see and
                                ; short enough that a wedged bracket on real
                                ; hardware is not a lost session
KF_TICK     equ 9               ; ...and the sampling period after it, half a
                                ; second, re-armed by the handler
KF_NREC     equ 40              ; rows of raw sample. 4 around the bracket and
                                ; 30 seconds of timer at 2Hz is 64, so this
                                ; fills and stops rather than wrapping: the
                                ; FIRST rows after the bracket are the ones
                                ; worth keeping, not the last
KF_REC      equ 24              ; bytes a record (see kf_grab)

KF_R_21     equ 0               ; byte  master 8259 OCW1 - bit 1 IS the answer
KF_R_A1     equ 1               ; byte  slave 8259 OCW1 - bit 4 is IRQ12
KF_R_64     equ 2               ; byte  8042 status, READ ONLY (harmless)
KF_R_BTN    equ 3               ; byte  mouse buttons
KF_R_HEAD   equ 4               ; word  40:1A
KF_R_TAIL   equ 6               ; word  40:1C
KF_R_I09O   equ 8               ; word  int 09h offset...
KF_R_I09S   equ 10              ; word  ...and segment
KF_R_I74O   equ 12              ; word  int 74h, IRQ12's own gate
KF_R_I74S   equ 14              ; word
KF_R_KEYS   equ 16              ; word  keys THIS PACKAGE has been handed
KF_R_MX     equ 18              ; word
KF_R_MY     equ 20              ; word
KF_R_TICK   equ 22              ; word  [ticks], so the rows carry their own clock

; The report columns. These are the character positions of kf_s_hdr's own
; words and are only correct together with it (tests/vbeprobe's rule).
;  'when       21   A1   64   head tail i09        i74        keys mouse'
;   0          11   16   21   26   31   36        47        58   63
KF_C_21     equ 11
KF_C_A1     equ 16
KF_C_64     equ 21
KF_C_HEAD   equ 26
KF_C_TAIL   equ 31
KF_C_I09    equ 36
KF_C_I74    equ 47
KF_C_KEYS   equ 58
KF_C_MOU    equ 63

; -----------------------------------------------------------------------------
; kf_entry - package entry (SPEC.md 20.2)
; -----------------------------------------------------------------------------
kf_entry:
    push si
    mov si, kf_tpl
    call OSAPI_WM_CREATE
    jc .out
    mov [kf_win], bx
    mov al, 1
    call OSAPI_WM_SNAP
    mov ax, kf_ontimer          ; AFTER wm_create, which the API asks for
    call OSAPI_WM_ONTIMER       ; (CF=1 on kern_small: there is no timer there
                                ; and the menu's Sample Now is the second path)
    mov si, kf_menus            ; AND THE MENU IS PUBLISHED, NOT MERELY
    call OSAPI_MENU_SET         ; DECLARED. OS88_MENUSET lays the table out and
                                ; nothing reads it until this call - the first
                                ; build left it out and came up with the app's
                                ; name in the bar and no Record menu under it,
                                ; which on the field machine would have meant a
                                ; report that could not be saved without the
                                ; keyboard it exists to prove is dead
    call kf_head                ; the report's own headings
    mov si, kf_l_start
    call kf_row                 ; ...and one row before anything has happened
    call kf_arm
    clc
.out:
    pop si
    ret

; kf_arm - ask for the next timer tick; harmless when the kernel refuses
kf_arm:
    push ax
    push bx
    mov bx, [kf_win]
    mov ax, KF_TICK
    call OSAPI_WM_TIMER
    pop bx
    pop ax
    ret

kf_paint:
    call bl_paint
    ret

; -----------------------------------------------------------------------------
; kf_onkey - COUNT IT FIRST, then let benchlib have it
;
; The count is the point: it is the only column that says whether a keystroke
; reached the PACKAGE, as against reaching the BIOS buffer (head/tail) or the
; controller (64h). Three different answers, three columns, one row.
; -----------------------------------------------------------------------------
kf_onkey:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [kf_win], si
    inc word [kf_keys]
    mov [kf_lastk], al
    mov bl, al
    or bl, 0x20
    cmp bl, 'k'                 ; K - a row right now, from the keyboard, which
    je .key                     ; is worth having while the keyboard still works
    cmp bl, 's'
    je .save
    call bl_key
    jc .out
    call bl_paint
    jmp short .out
.key:
    mov si, kf_l_key
    call kf_row
    mov si, [kf_win]            ; SI IS THE WINDOW, and bl_paint reads it as one
                                ; (`mov bx, si` at its head). Every site that
                                ; set SI to a STRING and then repainted was
                                ; handing a label or a filename over as a
                                ; window handle - which is how `Sample Now`
                                ; came to paint white down the left of a
                                ; 1024x768 desktop
    call bl_paint
    jmp short .out
.save:
    call kf_save
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

kf_onclick:
    ret

; -----------------------------------------------------------------------------
; kf_ontimer - a row every KF_TICK, and re-arm (SPEC.md 13.9: one-shot)
; -----------------------------------------------------------------------------
kf_ontimer:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [kf_win], si
    cmp byte [kf_watch], 0      ; only while a bracket has been run: before
    je .out                     ; that there is nothing to watch for
    mov al, 4
    call kf_lab
    call kf_row
    mov si, [kf_win]            ; kf_lab left a LABEL in SI - see kf_onkey
    call bl_paint
.out:
    call kf_arm                 ; ALWAYS re-armed, so Sample Now and the
    pop di                      ; bracket both have a live timer waiting
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; kf_oncmd - the menu (SI = window, AH = menu, AL = item)
; -----------------------------------------------------------------------------
kf_oncmd:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [kf_win], si
    or ah, ah
    jnz .out
    cmp al, 0
    je .fssame
    cmp al, 1
    je .fsmode
    cmp al, 2
    je .now
    cmp al, 3
    je .cmd42
    cmp al, 4
    je .save
    cmp al, 5
    je .top
    jmp short .out
.fssame:
    mov byte [kf_setmode], 0
    call kf_bracket
    jmp short .rep
.fsmode:
    mov byte [kf_setmode], 1
    call kf_bracket
    jmp short .rep
.now:
    mov si, kf_l_now
    call kf_row
    jmp short .rep
.cmd42:
    call kf_cmdbyte
    jmp short .rep
.save:
    call kf_save
    jmp short .out
.top:
    mov word [bl_top], 0
.rep:
    mov si, [kf_win]            ; `.now` above left a LABEL in SI, and this is
    call bl_paint               ; the arm it reached - see kf_onkey
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; kf_modeline - say what OSAPI_FSX_MODE did, on the arm that asked it
; -----------------------------------------------------------------------------
kf_modeline:
    push si
    cmp byte [kf_setmode], 0
    je .out                     ; the same-mode arm never asked
    mov si, kf_s_modeok
    cmp byte [kf_modefail], 0
    je .say
    mov si, kf_s_modeno
.say:
    call bl_sline
    cmp byte [kf_modefail], 0
    je .out
    mov si, kf_s_modeno2
    call bl_sline
.out:
    pop si
    ret

; -----------------------------------------------------------------------------
; kf_lab - AL = 0..4 (pre/in/end/after/timer) -> SI = the label for THIS ARM
; Preserves every register but SI.
;
; THE ROWS HAVE TO NAME THEIR ARM. The first field run came back with three
; brackets in it, logged as three identical pre-fs/in-fs/after triples, and
; nothing in the report said which were `same mode` and which were `mode 13h`
; - which is the entire comparison this package exists to make. The answer
; then had to be asked of the operator's memory, which is precisely what a
; written report is for not having to do.
; -----------------------------------------------------------------------------
kf_lab:
    push ax
    push bx
    xor ah, ah
    cmp byte [kf_setmode], 0
    je .have
    add ax, 5                   ; the second row of the table
.have:
    mov bx, ax
    shl bx, 1
    mov si, [bx + kf_labtab]
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; kf_bracket - one OSAPI_FSX_RUN, sampled on both sides of it
;
; [kf_setmode] picks the arm. THE PAIR IS THE EXPERIMENT (see the head of this
; file): without a mode set, SPEC.md 53.6 skips the restore entirely and the
; card is never touched; with one, the kernel has to put the desktop's own
; mode back on the way home - which on a VBE machine means a far call into
; VBE.DRV, a path that exists on NO other desktop.
; -----------------------------------------------------------------------------
kf_bracket:
    push ax
    push bx
    push cx
    push si
    mov byte [kf_watch], 1      ; the timer starts sampling from here on
    mov byte [kf_modefail], 0   ; THIS bracket's answer, not the last one's
    xor al, al
    call kf_lab
    call kf_grab                ; the LAST row before the screen is taken
    mov ax, kf_fsmain
    mov bx, [kf_win]
    xor cx, cx                  ; no worker to keep alive
    call OSAPI_FSX_RUN
    pushf
    mov al, 3
    call kf_lab
    call kf_grab                ; ...and the FIRST one after it is given back
    popf
    jnc .flush
    mov si, kf_s_nofsx          ; refused: nothing was taken and nothing drawn
    call bl_sline
.flush:
    call kf_modeline            ; WHETHER THE MODE SET TOOK, which the first
                                ; field build recorded in [kf_modefail] and
                                ; then never printed. Without it a `mode 13h`
                                ; arm that was REFUSED reads exactly like one
                                ; that worked - and the two arms are then the
                                ; same experiment run twice
    call kf_flush               ; every record since, turned into report lines
    pop si                      ; - and NOT one of them written from inside the
    pop cx                      ; bracket, which is the next routine's whole
    pop bx                      ; constraint
    pop ax
    ret

; -----------------------------------------------------------------------------
; kf_fsmain - the bracket's body (SPEC.md 53.1)
;
; IT RECORDS AND DOES NOT REPORT. Only OSAPI_MOUSE, OSAPI_GET_TICKS and the
; fsx calls are legal in here (SPEC.md 53.7), so the samples go into the raw
; array and every line of text is built after the bracket has ended. Writing
; the report from in here would be a desktop drawing call inside a foreign
; mode, which is the one thing this bracket must not do.
;
; IT COMES HOME ON A CLOCK AND NOT ON A KEY. The machine this was written for
; loses its keyboard around this bracket, so a body that waited for a keypress
; to exit could wedge the session on the very failure it is here to record.
; -----------------------------------------------------------------------------
kf_fsmain:
    push ax
    push bx
    push cx
    push si
    cmp byte [kf_setmode], 0
    je .nomode
    push es
    push di
    push ds
    pop es
    mov di, kf_fsi
    mov al, FSXM_VGA13          ; what a game does: a real mode set, so the
    call OSAPI_FSX_MODE         ; kernel owes a real restore on the way home
    pop di
    pop es
    jnc .nomode
    mov byte [kf_modefail], 1   ; refused - the row after says so, and the
.nomode:                        ; bracket still runs, which keeps the arms
                                ; comparable
    mov al, 1
    call kf_lab
    call kf_grab                ; inside, as early as the bracket allows

    call OSAPI_GET_TICKS        ; ...hold it for KF_HOLD, on the system clock
    mov bx, ax
.wait:
    call OSAPI_GET_TICKS
    sub ax, bx                  ; modular: a wrap subtracts correctly
    cmp ax, KF_HOLD
    jb .wait

    mov al, 2
    call kf_lab
    call kf_grab                ; and again, just before handing it back
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; kf_grab - one raw sample, labelled SI, appended to the array
; out: nothing; preserves every register
;
; EVERY READ IN HERE IS PASSIVE. `in al, 0x64` is the 8042's STATUS port and
; costs the controller nothing; the BIOS buffer, the IVT and the two 8259
; masks are memory and OCW1 reads. Nothing touches port 60h, which is the one
; byte both devices share - see this file's head for why that matters.
; -----------------------------------------------------------------------------
kf_grab:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    mov bx, [kf_nrec]
    cmp bx, KF_NREC
    jae .full                   ; it FILLS AND STOPS: the rows just after the
                                ; bracket are the ones worth keeping, and a
                                ; ring would spend them on a quiet minute
    mov ax, bx
    add ax, ax
    mov di, ax
    add di, kf_labs
    mov [di], si                ; the label, parallel to the record
    mov ax, KF_REC
    mul bx
    mov di, ax
    add di, kf_recs

    in  al, 0x21                ; THE MASTER MASK - bit 1 is IRQ1 and is the
    mov [di + KF_R_21], al      ; first thing to look at in the whole report
    in  al, 0xA1                ; ...and bit 4 of the slave is IRQ12, the
    mov [di + KF_R_A1], al      ; mouse's, which is known to still work
    in  al, 0x64                ; status only; port 60h is never touched
    mov [di + KF_R_64], al

    push ds                     ; the BIOS data area: head and tail say
    mov ax, 0x40                ; whether IRQ1 fired AT ALL
    mov ds, ax
    mov ax, [0x1A]
    mov cx, [0x1C]
    pop ds
    mov [di + KF_R_HEAD], ax
    mov [di + KF_R_TAIL], cx

    push ds                     ; the two gates, as seg:off
    xor ax, ax
    mov ds, ax
    mov ax, [0x09 * 4]
    mov cx, [0x09 * 4 + 2]
    mov bx, [0x74 * 4]
    mov dx, [0x74 * 4 + 2]
    pop ds
    mov [di + KF_R_I09O], ax
    mov [di + KF_R_I09S], cx
    mov [di + KF_R_I74O], bx
    mov [di + KF_R_I74S], dx

    mov ax, [kf_keys]
    mov [di + KF_R_KEYS], ax
    call OSAPI_MOUSE            ; legal in a bracket (SPEC.md 53.7)
    mov [di + KF_R_MX], cx
    mov [di + KF_R_MY], dx
    mov [di + KF_R_BTN], al
    call OSAPI_GET_TICKS
    mov [di + KF_R_TICK], ax
    inc word [kf_nrec]
.full:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; kf_flush - turn every ungrabbed record into a report line
; -----------------------------------------------------------------------------
kf_flush:
    push ax
    push bx
    push si
.one:
    mov bx, [kf_shown]
    cmp bx, [kf_nrec]
    jae .out
    call kf_emit
    inc word [kf_shown]
    jmp short .one
.out:
    pop si
    pop bx
    pop ax
    ret

; kf_row - grab one and show it, for every caller OUTSIDE the bracket
kf_row:
    call kf_grab
    call kf_flush
    ret

; -----------------------------------------------------------------------------
; kf_emit - record BX as one line of the report
; -----------------------------------------------------------------------------
kf_emit:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov ax, bx
    add ax, ax
    mov si, ax
    add si, kf_labs
    mov si, [si]                ; the label it was grabbed with
    mov ax, KF_REC
    mul bx
    mov bx, ax
    add bx, kf_recs

    call bl_lclr
    xor di, di
    call bl_lput

    mov al, [bx + KF_R_21]      ; every byte as four digits: the columns are
    xor ah, ah                  ; that wide and a 2-digit field beside a
    mov di, KF_C_21             ; 4-digit one is a column somebody misreads
    call bl_hex4
    mov al, [bx + KF_R_A1]
    xor ah, ah
    mov di, KF_C_A1
    call bl_hex4
    mov al, [bx + KF_R_64]
    xor ah, ah
    mov di, KF_C_64
    call bl_hex4
    mov ax, [bx + KF_R_HEAD]
    mov di, KF_C_HEAD
    call bl_hex4
    mov ax, [bx + KF_R_TAIL]
    mov di, KF_C_TAIL
    call bl_hex4

    mov ax, [bx + KF_R_I09S]    ; seg:off, because a vector that MOVED is the
    mov di, KF_C_I09            ; finding and a half of it is not
    call bl_hex4
    mov byte [bl_lscr + KF_C_I09 + 4], ':'
    mov ax, [bx + KF_R_I09O]
    mov di, KF_C_I09 + 5
    call bl_hex4
    mov ax, [bx + KF_R_I74S]
    mov di, KF_C_I74
    call bl_hex4
    mov byte [bl_lscr + KF_C_I74 + 4], ':'
    mov ax, [bx + KF_R_I74O]
    mov di, KF_C_I74 + 5
    call bl_hex4

    mov ax, [bx + KF_R_KEYS]
    mov di, KF_C_KEYS
    call bl_hex4
    mov ax, [bx + KF_R_MX]
    mov di, KF_C_MOU
    call bl_hex4
    mov byte [bl_lscr + KF_C_MOU + 4], ','
    mov ax, [bx + KF_R_MY]
    mov di, KF_C_MOU + 5
    call bl_hex4
    mov byte [bl_lscr + KF_C_MOU + 9], ','
    mov al, [bx + KF_R_BTN]
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .dig
    add al, 7
.dig:
    mov [bl_lscr + KF_C_MOU + 10], al
    call bl_lcommit
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; kf_cmdbyte - READ THE 8042's COMMAND BYTE, deliberately and never on the
;              sample path (see this file's head)
;
; `write 0x20 to 64h, read 60h`. Port 60h is the ONE buffer the keyboard and
; the mouse share, so a keystroke or a mouse packet arriving inside this
; window is eaten by us: a lost key, or a lost byte out of the middle of a
; mouse triple, which desynchronises the pointer until the next idle. That is
; why it is a menu item and not a column, and why the row it writes names
; itself - a report that silently perturbed the device it was measuring would
; be worse than no report.
;
; Interrupts are off for the exchange so that int 09h and the aux gate cannot
; race us for the byte; pushf/popf, never cli/sti, which is the kernel's rule
; and right here for its reason - the caller is a menu handler and the UI
; task's flags are not ours to force on.
; -----------------------------------------------------------------------------
kf_cmdbyte:
    push ax
    push cx
    push si
    pushf
    cli
    mov cx, 0x4000              ; the input buffer has to be empty before a
.ibf:                           ; command may be posted
    in  al, 0x64
    test al, 0x02
    jz .send
    loop .ibf
.send:
    mov al, 0x20
    out 0x64, al
    mov cx, 0x4000
.obf:
    in  al, 0x64
    test al, 0x01               ; OBF - and if it never comes the controller
    jnz .have                   ; is not answering, which is itself the answer
    loop .obf
    mov byte [kf_cmdok], 0
    jmp short .done
.have:
    in  al, 0x60
    mov [kf_cmd], al
    mov byte [kf_cmdok], 1
.done:
    popf

    call bl_lclr                ; one line, decoded, because four bit names are
    mov si, kf_s_cmd            ; easier to be right about than one hex byte
    xor di, di
    call bl_lput
    cmp byte [kf_cmdok], 0
    jne .got
    mov si, kf_s_cmdno
    mov di, 12
    call bl_lput
    jmp short .emit
.got:
    mov al, [kf_cmd]
    xor ah, ah
    mov di, 12
    call bl_hex4
    mov si, kf_s_kint           ; bit 0: the KEYBOARD's interrupt, and a 0 here
    mov al, [kf_cmd]            ; with the mouse alive is the whole bug
    test al, 0x01
    mov di, 18
    call kf_flag
    mov si, kf_s_aint           ; bit 1: the AUX interrupt, which is known to
    mov al, [kf_cmd]            ; be working on the machine this is for
    test al, 0x02
    mov di, 30
    call kf_flag
    mov si, kf_s_kdis           ; bit 4 SET = the keyboard interface is OFF,
    mov al, [kf_cmd]            ; which 0xAD does and 0xAE undoes
    test al, 0x10
    mov di, 42
    call kf_flag
    mov si, kf_s_adis           ; bit 5 SET = the aux clock is off (PS/2); on
    mov al, [kf_cmd]            ; an AT controller this bit is PC MODE instead
    test al, 0x20
    mov di, 54
    call kf_flag
.emit:
    call bl_lcommit
    pop si
    pop cx
    pop ax
    ret

; kf_flag - SI = a name, ZF from a `test`, DI = column: name plus 0 or 1
kf_flag:
    push ax
    push di
    pushf
    call bl_lput
    mov al, '0'
    popf
    jz .put
    mov al, '1'
.put:
    pop di
    push di
    add di, bl_lscr
    add di, 9
    mov [di], al
    pop di
    pop ax
    ret

kf_save:
    push si
    mov si, kf_f_out
    call bl_save
    mov si, [kf_win]            ; ...and the FILENAME, here - see kf_onkey
    call bl_paint
    pop si
    ret

; -----------------------------------------------------------------------------
; kf_head - the report's own headings, once
; -----------------------------------------------------------------------------
kf_head:
    push si
    mov si, kf_s_t1
    call bl_sline
    mov si, kf_s_t2
    call bl_sline
    call bl_blank
    mov si, kf_s_h1
    call bl_sline
    mov si, kf_s_h2
    call bl_sline
    mov si, kf_s_h3
    call bl_sline
    call bl_blank
    mov si, kf_s_hdr
    call bl_sline
    pop si
    ret

; --- the report's own words --------------------------------------------------
kf_ttl:     db 'Keyboard / Mouse across Full Screen', 0
kf_f_out:   db 'KBDFSX.TXT', 0
kf_s_t1:    db 'os8088 KBDFSX - the keyboard and the mouse either side of a', 0
kf_s_t2:    db 'full-screen bracket. Save is on the MENU: it works with no keyboard.', 0
kf_s_h1:    db '21 bit 1 = IRQ1 MASKED (keyboard). A1 bit 4 = IRQ12 (PS/2 mouse).', 0
kf_s_h2:    db 'head/tail: 40:1A and 40:1C. If TAIL MOVES on a keypress the byte', 0
kf_s_h3:    db 'arrived and the fault is ABOVE the ISR; if not, it never came.', 0
kf_s_hdr:   db 'when       21   A1   64   head tail i09        i74        keys mouse', 0
kf_s_cmd:   db '8042 cmd', 0
kf_s_cmdno: db '(no answer - the controller never set OBF)', 0
kf_s_kint:  db 'kbdint=', 0
kf_s_aint:  db 'auxint=', 0
kf_s_kdis:  db 'kbdoff=', 0
kf_s_adis:  db 'auxoff=', 0
kf_s_nofsx: db 'OSAPI_FSX_RUN REFUSED: the screen was not free. Nothing taken.', 0

kf_l_start: db 'start', 0
kf_l_now:   db 'now', 0
kf_l_key:   db 'key', 0

; Two rows of five, indexed by [kf_setmode] - see kf_lab. Ten characters is
; the label column's whole width (KF_C_21 is 11), so these are as long as
; they go.
kf_labtab:
    dw kf_l_p0, kf_l_i0, kf_l_e0, kf_l_a0, kf_l_t0
    dw kf_l_p1, kf_l_i1, kf_l_e1, kf_l_a1, kf_l_t1
kf_l_p0:    db 'pre same', 0
kf_l_i0:    db 'in same', 0
kf_l_e0:    db 'end same', 0
kf_l_a0:    db 'aft same', 0
kf_l_t0:    db 'tmr same', 0
kf_l_p1:    db 'pre 13h', 0
kf_l_i1:    db 'in 13h', 0
kf_l_e1:    db 'end 13h', 0
kf_l_a1:    db 'aft 13h', 0
kf_l_t1:    db 'tmr 13h', 0

kf_s_modeok:  db 'OSAPI_FSX_MODE set 320x200x256 - the kernel owes a real restore.', 0
kf_s_modeno:  db 'OSAPI_FSX_MODE REFUSED. This arm changed NO mode, so it is the', 0
kf_s_modeno2: db 'same experiment as the other one - do not read them as a pair.', 0

kf_about:   db 'Kbd/Mouse FSX', 0

    OS88_MENUSET kf_menus, kf_about, kf_oncmd
        OS88_MENU kf_m_rec, kf_i_rec, 6
    OS88_MENUSET_END kf_menus

kf_m_rec:   db 'Record', 0
kf_i_rec:   dw kf_it_fs1, kf_it_fs2, kf_it_now, kf_it_cmd, kf_it_save, kf_it_top
kf_it_fs1:  db 'Full Screen (same mode)', 0
kf_it_fs2:  db 'Full Screen (mode 13h)', 0
kf_it_now:  db 'Sample Now', 0
kf_it_cmd:  db 'Read 8042 (eats a byte)', 0
kf_it_save: db 'Save Report', 0
kf_it_top:  db 'Top of Report', 0

kf_tpl:
    dw 20, 30, 600, 340
    dw kf_ttl, kf_paint, kf_onkey, kf_onclick

%include "benchlib.inc"

KF_O_RECS   equ 32
KF_O_LABS   equ KF_O_RECS + KF_NREC * KF_REC
KF_O_FSI    equ KF_O_LABS + KF_NREC * 2
KF_BSS_OWN  equ ((KF_O_FSI + FSI_SIZE + 511) / 512) * 512

    align 512                   ; benchlib's base is an int 13h target and must
    OS88_BSS KF_BSS_OWN + BL_BSS_SIZE   ; be 512-aligned (bl_save)
    OS88_IMAGE_END

kf_win      equ os88_image_end + 0
kf_keys     equ os88_image_end + 2
kf_nrec     equ os88_image_end + 4
kf_shown    equ os88_image_end + 6
kf_watch    equ os88_image_end + 8
kf_setmode  equ os88_image_end + 9
kf_modefail equ os88_image_end + 10
kf_cmdok    equ os88_image_end + 11
kf_cmd      equ os88_image_end + 12
kf_lastk    equ os88_image_end + 13
kf_recs     equ os88_image_end + KF_O_RECS
kf_labs     equ os88_image_end + KF_O_LABS
kf_fsi      equ os88_image_end + KF_O_FSI
    BL_BSS os88_image_end + KF_BSS_OWN
