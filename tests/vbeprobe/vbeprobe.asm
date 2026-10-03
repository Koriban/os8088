; =============================================================================
; os8088 - tests/vbeprobe/vbeprobe.asm
;
; VBEPROBE: does this machine's video BIOS offer a mode os8088 could RUN in,
; and if so which one. It answers one question that has to be answered before
; any work is done on a higher resolution, and it answers it on the machine
; rather than from a datasheet.
;
; IT CHANGES NO MODE AND DRAWS NOTHING OUTSIDE ITS WINDOW. INT 10h AX=4F00h
; and AX=4F01h are both pure queries - they fill a buffer and return. The one
; call that would switch the screen, AX=4F02h, is not here and must not be:
; os8088 owns the display (SPEC.md 39) and a package that reset the mode
; behind the window manager would take the desktop with it.
;
; --- what it is looking for, and why that mode and not another ---------------
;
; os8088's renderer is FOUR-BIT PLANAR throughout - mode 12h's format, with
; the Sequencer's map mask selecting planes at one address. The VBE mode that
; is the same shape one size up is 0104h, 1024x768x16: still planar, still
; four bits, so every primitive keeps its pixel format. The 256-colour modes
; (0105h and friends) are PACKED, which is not an extension of this renderer
; but a second one.
;
; AND THE APERTURE LINES UP, which is the fact that makes 0104h interesting
; rather than merely bigger. 1024 pixels is 128 bytes a row a plane, and a
; 64KB window holds exactly 512 of those rows - so a bank boundary falls
; BETWEEN rows and never inside one. gfx_rowbase already turns a row number
; into an address and is the one place that would have to learn about banks.
; 800x600 is the harder mode, not the easier one: 100 bytes a row divides
; 65536 into 655.36, so a row there straddles.
;
; So the rows this report is for are, in order of how much they decide:
;
;   0104h present and SUPPORTED   the work is a driver and gfx_rowbase
;   0104h present, not supported  the BIOS lists it and the card will not
;                                 take it - the usual case on cards that
;                                 implement only the packed modes
;   0104h absent                  the plan changes shape entirely: a packed
;                                 256-colour mode means a second renderer
;
; WINDOW GRANULARITY AND SIZE are reported for every mode because they are
; what the banking would cost. A granularity of 64KB with a 64KB window is
; the simple case; 4KB granularity means more switches and a different sum.
;
; Never on the shipped apps disks (SPEC.md 24): its own scratch image, the
; fontbench/typebench precedent.
;
;   make vbeprobe && make test TESTAPPS=build/vbeprobe.img
;
; Prefix vp_.
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'VBEPROBE', vp_entry

VP_INFO     equ 512             ; the VbeInfoBlock AX=4F00h fills
VP_MODE     equ 256             ; ...and the ModeInfoBlock AX=4F01h does
VP_MAXM     equ 64              ; modes reported, most interesting first. The
                                ; list a BIOS returns can be long and most of
                                ; it is text modes and 320x200

; The row columns. These are the character positions of vp_s_hdr's own words
; and are only correct together with it - a heading that says one thing over a
; number that means another is the failure this names them to avoid.
;        'mode   width height bpp mdl gran wsize attr'
;         0      7     13     20  24  28   33    39
VP_C_W      equ 7
VP_C_H      equ 13
VP_C_BPP    equ 20
VP_C_MDL    equ 24
VP_C_GRAN   equ 28
VP_C_WSZ    equ 33
VP_C_ATTR   equ 39

; -----------------------------------------------------------------------------
; vp_entry - package entry (SPEC.md 20.2)
; -----------------------------------------------------------------------------
vp_entry:
    push si
    call vp_probe               ; before the window, so the first page is the
    mov si, vp_tpl              ; answer rather than an empty table
    call OSAPI_WM_CREATE
    jc .out
    mov [vp_win], bx
    mov al, 1
    call OSAPI_WM_SNAP
    clc
.out:
    pop si
    ret

vp_paint:
    call bl_paint
    ret

; -----------------------------------------------------------------------------
; vp_onkey - R re-probes, S saves the report
; -----------------------------------------------------------------------------
vp_onkey:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [vp_win], si
    mov bl, al
    or bl, 0x20
    cmp bl, 'r'
    je .again
    cmp bl, 's'
    je .save
    call bl_key
    jc .out
    call bl_paint
    jmp short .out
.again:
    call vp_probe
    call bl_paint
    jmp short .out
.save:
    mov si, vp_f_out
    call bl_save
    call bl_paint
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

vp_onclick:
    ret

; -----------------------------------------------------------------------------
; vp_probe - the whole report, built from scratch
; -----------------------------------------------------------------------------
vp_probe:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov word [bl_nrow], 0       ; a re-probe REPLACES the report rather
                                ; than appending a second copy of it
    mov si, vp_s_t1
    call bl_sline
    mov si, vp_s_t2
    call bl_sline
    call bl_blank

    ; --- AX=4F00h: is there a VBE at all? --------------------------------
    push cs
    pop es
    mov di, vp_info
    mov cx, VP_INFO             ; a BIOS that answers must not be handed a
    xor al, al                  ; buffer with yesterday's signature still in
.clr:                           ; it - a stale 'VESA' would read as a pass
    mov [es:di], al
    inc di
    loop .clr
    mov di, vp_info
    mov ax, 0x4F00
    int 0x10
    cmp ax, 0x004F              ; AL=4F supported, AH=00 succeeded. BOTH, and
    jne .novbe                  ; the whole word is the documented test
    mov si, vp_info
    cmp word [si], 'VE'         ; ...and the signature, because a machine with
    jne .novbe                  ; no VBE can still leave AX alone
    cmp word [si+2], 'SA'
    jne .novbe

    call bl_lclr                ; the version is BCD-ish - 0300h is 3.0, and
    mov si, vp_l_ver            ; 768 is not what anyone wants to read, so this
    xor di, di                  ; one is laid out by hand in hex rather than
    call bl_lput                ; going through bl_kv's decimal field
    mov di, BL_C_N
    mov ax, [vp_info + 4]
    call bl_hex4
    call bl_lcommit
    mov si, vp_l_mem            ; total memory, in 64KB blocks
    mov ax, [vp_info + 18]
    xor dx, dx
    mov cx, 6                   ; bl_kv's value field: WITHOUT this bl_dec is
    call bl_kv                  ; handed CX=0 and emits nothing at all
    call bl_blank

    ; --- walk the mode list ----------------------------------------------
    mov si, vp_s_hdr
    call bl_sline
    mov si, vp_s_hdr2
    call bl_sline
    les di, [vp_info + 14]      ; the far pointer to the mode list
    mov [vp_lptr], di
    mov [vp_lseg], es
    mov word [vp_cnt], 0
    mov word [vp_found], 0
.each:
    mov es, [vp_lseg]
    mov di, [vp_lptr]
    mov ax, [es:di]
    cmp ax, 0xFFFF              ; the list ends at FFFF
    je .listdone
    add word [vp_lptr], 2
    call vp_one                 ; AX = the mode number. EVERY mode, capped or
    jmp short .each             ; not - the cap is on the ROWS, see vp_one
.listdone:
    cmp word [vp_cnt], VP_MAXM  ; a list longer than the cap is TRUNCATED, and
    jb .verdict                 ; a report that ends without saying so reads as
    mov si, vp_s_trunc          ; a complete one. QEMU's own list overruns this
    call bl_sline               ; - a real card's rarely will
.verdict:
    call bl_blank
    mov si, vp_s_vhdr
    call bl_sline
    cmp word [vp_found], 0
    je .no104
    mov si, vp_s_yes
    call bl_sline
    jmp short .done
.no104:
    mov si, vp_s_no
    call bl_sline
    mov si, vp_s_no2
    call bl_sline
    mov si, vp_s_no3
    call bl_sline
    jmp short .done
.novbe:
    mov si, vp_s_novbe
    call bl_sline
    mov si, vp_s_novbe2
    call bl_sline
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vp_one - AX = a mode number: query it and emit a row if it is worth one
; -----------------------------------------------------------------------------
vp_one:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [vp_mode], ax
    push cs
    pop es
    mov di, vp_minfo
    mov cx, ax
    mov ax, 0x4F01
    int 0x10
    cmp ax, 0x004F
    jne .out
    mov ax, [vp_minfo + 18]     ; XResolution
    cmp ax, 640                 ; text modes and 320x200 are not what this is
    jb .out                     ; about, and a full list pages off the screen
    ; is this the one? 0104h AND bit 0 of the attributes (supported in hw).
    ; THIS RUNS BEFORE THE ROW CAP, deliberately: the cap exists so a long
    ; list does not page the verdict off the screen, and a verdict computed
    ; only from the printed rows would answer "no 0104h" for a BIOS that
    ; lists it at position 65. The cap costs rows, never the answer.
    cmp word [vp_mode], 0x0104
    jne .cap
    test byte [vp_minfo], 1
    jz .cap
    mov word [vp_found], 1
.cap:
    cmp word [vp_cnt], VP_MAXM
    jae .out
    inc word [vp_cnt]
.row:
    ; mode, WxH, bpp, model, gran, winsize, attr. DI IS A COLUMN, NOT AN
    ; ADDRESS: bl_dec and bl_hex4 both add bl_lscr themselves, so the columns
    ; here are the ones in vp_s_hdr and nothing else. And the scratch must be
    ; blanked first - it still holds the PREVIOUS line, and a row that only
    ; overwrites part of it inherits the rest.
    call bl_lclr
    xor di, di
    mov ax, [vp_mode]
    call bl_hex4
    mov di, VP_C_W
    mov ax, [vp_minfo + 18]     ; XResolution
    mov cx, 5
    xor dx, dx
    call bl_dec
    mov di, VP_C_H
    mov ax, [vp_minfo + 20]     ; YResolution
    mov cx, 6
    xor dx, dx
    call bl_dec
    mov di, VP_C_BPP
    xor ah, ah
    mov al, [vp_minfo + 25]     ; BitsPerPixel
    mov cx, 3
    xor dx, dx
    call bl_dec
    mov di, VP_C_MDL
    xor ah, ah
    mov al, [vp_minfo + 27]     ; MemoryModel: 3 planar, 4 packed, 6 direct
    mov cx, 3
    xor dx, dx
    call bl_dec
    mov di, VP_C_GRAN
    mov ax, [vp_minfo + 4]      ; WinGranularity, KB
    mov cx, 4
    xor dx, dx
    call bl_dec
    mov di, VP_C_WSZ
    mov ax, [vp_minfo + 6]      ; WinSize, KB
    mov cx, 5
    xor dx, dx
    call bl_dec
    mov di, VP_C_ATTR
    mov ax, [vp_minfo]          ; ModeAttributes
    call bl_hex4
    call bl_lcommit
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- the report's own words --------------------------------------------------
vp_ttl:     db 'VBE Probe', 0
vp_f_out:   db 'VBEPROBE.TXT', 0
vp_s_t1:    db 'os8088 VBEPROBE - what modes this video BIOS offers', 0
vp_s_t2:    db '===================================================', 0
vp_l_ver:   db 'VBE version (hex-ish)', 0
vp_l_mem:   db 'video memory (64KB)', 0   ; must stay under BL_C_N = 24
vp_s_hdr:   db 'mode   width height bpp mdl gran wsize attr', 0
vp_s_hdr2:  db '  mdl: 3 planar 4 packed 6 direct. attr bit0 = supported.', 0
vp_s_trunc: db '(list truncated at VP_MAXM modes - the rest are unread)', 0
vp_s_vhdr:  db '-- the verdict --', 0
vp_s_yes:   db '0104h (1024x768x16 PLANAR) is present AND supported.', 0
vp_s_no:    db '0104h (1024x768x16 planar) is NOT usable on this machine.', 0
vp_s_no2:   db 'A packed 256-colour mode means a SECOND renderer, not an', 0
vp_s_no3:   db 'extension of the four-bit planar one - a much larger job.', 0
vp_s_novbe: db 'No VBE: INT 10h AX=4F00h did not answer 004Fh with a', 0
vp_s_novbe2: db "'VESA' signature. This machine has plain VGA only.", 0

vp_tpl:
    dw 60, 40, 500, 300
    dw vp_ttl, vp_paint, vp_onkey, vp_onclick

%include "benchlib.inc"

VP_O_INFO   equ 16
VP_O_MINFO  equ VP_O_INFO + VP_INFO
VP_BSS_OWN  equ ((VP_O_MINFO + VP_MODE + 511) / 512) * 512

    align 512                   ; benchlib's base is an int 13h target and must
                                ; be 512-aligned (bl_save)
    OS88_BSS VP_BSS_OWN + BL_BSS_SIZE
    OS88_IMAGE_END

vp_win      equ os88_image_end + 0
vp_lptr     equ os88_image_end + 2
vp_lseg     equ os88_image_end + 4
vp_cnt      equ os88_image_end + 6
vp_found    equ os88_image_end + 8
vp_mode     equ os88_image_end + 10
vp_info     equ os88_image_end + VP_O_INFO
vp_minfo    equ os88_image_end + VP_O_MINFO
    BL_BSS os88_image_end + VP_BSS_OWN

