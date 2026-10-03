; =============================================================================
; vbe.inc - the kernel's HALF of VBE mode 0104h (SPEC.md 39.29)
;
; VBE.DRV owns the probe, the mode set, the palette and the window switch; this
; file is the sixteen bytes shaped like a drv_tab row that are not in it, the
; three-line dispatcher, and the load/free pair. The split is SPEC.md 39.29.2's
; and it is not negotiable: gfx_* bodies are API slots, the renderer is called
; from inside mod_need's own load, and the mouse ISR draws from a context where
; no loaded image can be reached - so the once-per-mode half is a file and the
; per-pixel half is resident.
;
; THERE IS NO BOOT SNIFF, and that is the one place this departs from
; XMEM.DRV's shape (SPEC.md 41.12.1) deliberately rather than by omission.
;
; xm_sniff exists because a package can ask for extended memory at any moment,
; with no disk in the drive and nothing the kernel could read - so the answer
; has to already be known, and int 15h AH=88h is free to ask. VBE's probe is
; not free: AX=4F00h fills a 512-byte buffer and AX=4F01h a 256-byte one, and
; a kernel that reserved either would be spending resident RAM on a question
; only one page in the system asks.
;
; And it does not have to. The ONE consumer is Control Panel's Display page,
; which lives in CTRL.DRV and is itself loaded from the system disk when the
; user opens it - so the disk is already required at the only moment the
; question is ever asked (SPEC.md 2.8's own test, one layer out). Loading this
; overlay to find out costs a read the user has already paid for, and costs an
; 8088 - which can execute the probe but could never usefully run the mode -
; exactly nothing.
;
; .text and not .bss, because -f bin zeroes nothing.
; =============================================================================

%ifdef OS88_DRIVERS             ; kern_small cannot load a .DRV of any kind
                                ; (SPEC.md 51.0), so none of this exists there
section .text

; --- the verbs VBE.DRV answers (mirrored in drivers/vbe/vbe.asm) -------------
; In AL, not a published table: drv_call_ent loads BP from the row's DRVR_ENT,
; so every call lands on the image's one entry proc and the verb selects there.
; 0x40 and up, so a DRVV_* added to the kernel later cannot collide.
VBV_CAPS    equ 0x40            ; out: ES:DI filled with the VBG_ block
VBV_SET     equ 0x41            ; set the mode, palette and bank 0
VBV_BANK    equ 0x42            ; in AH = bank; map window A over it

; --- the geometry block the overlay fills, read into vid_tab's row -----------
VBG_W       equ 0
VBG_H       equ 2
VBG_STRIDE  equ 4
VBG_SEG     equ 6
VBG_BANKS   equ 8
VBG_SZ      equ 10

VBE_ABI_VER equ 1               ; what we expect the image to be; it refuses a
                                ; mismatch at LOAD rather than at the first
                                ; mode set, so a half-copied floppy is loud

vbe_fname:  db 'VBE.DRV', 0

; -----------------------------------------------------------------------------
; vbe_row - a DRVR_-shaped record OUTSIDE drv_tab (SPEC.md 39.29.2, 41.12)
;
; DRVR_TITLE points at the file name for xm_row's reason: the field may not be
; 0 in a record the shared loader walks, and there is no row, no caption and no
; Drivers page here, so nothing ever draws it. Every reader of DRVR_TITLE takes
; BX from drv_tab, and this record is not in drv_tab by construction.
;
; No DRVR_PAD byte after DRVR_ERR: the pad exists so DRVR_SIZE is 16 and
; drv_row can index drv_tab by shifting, and nothing ever strides over this.
; -----------------------------------------------------------------------------
vbe_row:
    dw PKG_DISP, 0              ; DRVR_DISP, DRVR_SEG
    dw vbe_fname, vbe_fname     ; DRVR_FILE, DRVR_TITLE
    dw 0, 0                     ; DRVR_KB, DRVR_ENT
    db DRVC_OVL                 ; DRVR_CLASS - not a class the kernel knows
    db 1                        ; DRVR_WANT - ALWAYS 1, because nothing sniffs:
                                ; the want is expressed by calling vbe_caps at
                                ; all, and no settings file can reach this
    db DRVE_OK                  ; DRVR_ERR

vbe_geom:   times VBG_SZ db 0   ; what the card actually reports. THE KERNEL
                                ; NEVER ASSUMES THESE: a BIOS that advertises a
                                ; mode it mis-programs is a known class, which
                                ; is why tests/vbeset reads every one of them
                                ; off the hardware too (SPEC.md 39.28.2)

; -----------------------------------------------------------------------------
; vbe_call - dispatch one verb into the overlay
; in:       AL = VBV_*, other registers per verb
; out:      per verb; CF = 1 and nothing called if the image is not loaded
; clobbers: BX and BP are banked; DS and ES are drv_call's to restore
;
; IT DOES NOT GO THROUGH drv_call, and that is a measurement rather than a
; preference. drv_call range-checks BX against drv_tab and refuses a row
; outside it, so reaching it needs a name on the whitelist at its `.stray`
; label - and that whitelist is in `.cold`, which had ONE byte of its rung
; left. Six bytes there crossed it: +512 bytes of every machine's RAM, for a
; feature an 8088 can detect and could never usefully run. xm_dsp already
; dispatches its service verbs by far-calling the header directly for its own
; reasons (SPEC.md 41.12.2); doing the same for ATTACH as well costs about
; fifteen bytes of `.text`, where 234 are free, and the rung stays uncrossed.
;
; What drv_call did for us and is replicated here: DS = the image, ES =
; KERNEL_SEG, a 0 DRVR_SEG refused rather than far-called, and the heap
; compaction nest held across the call (SPEC.md 66.6.3) so the image's own
; claim cannot move under it.
;
; THIS FILE IS .text AND driver.inc IS .cold, so the two calls that remain -
; the load and the release - are FAR through the drvf_* thunks.
; -----------------------------------------------------------------------------
vbe_call:
    push bx
    push bp
    push ds
    push es
    push cs
    pop es                      ; ES = KERNEL_SEG, which is what the image
    mov bx, [es:vbe_row+DRVR_SEG]       ; reads everything it is handed through
    or bx, bx
    jz .gone                    ; nothing loaded: a refusal, never a far call
                                ; to segment zero
    mov ds, bx
    mov bp, [es:vbe_row+DRVR_ENT]
    call COLD_SEG:wm_nest_pushd_x
    call far [es:vbe_row+DRVR_DISP]
    pushf                       ; the verb's answer, across the unnest
    pop bx
    pop es
    pop ds
    call COLD_SEG:wm_nest_pop_x
    push bx
    popf
    jmp short .out
.gone:
    pop es
    pop ds
    stc
.out:
    pop bp
    pop bx
    ret

; -----------------------------------------------------------------------------
; vbe_caps - make sure the overlay is there and read the geometry out of it
; out:      CF = 0 and [vbe_geom] filled = this machine can do 1024x768 planar;
;           CF = 1 = it cannot, for any reason, and the image is given back
; clobbers: AX (flags)
;
; THE IMAGE IS RELEASED ON A REFUSAL rather than left in the heap until
; somebody asks again - ss_open's rule, and here it is the common case: every
; machine that is not the one this was written for takes it.
;
; drv_load_at answers CF = 0 immediately when DRVR_SEG is already live, so a
; second call in the same Control Panel session is six compares.
; -----------------------------------------------------------------------------
vbe_caps:
    push bx
    push di
    push es
    mov bx, vbe_row
    call COLD_SEG:drvf_drv_load_at
    jc .no
    push cs
    pop es                      ; the overlay writes the block through ES, and
    mov di, vbe_geom            ; ES is KERNEL_SEG inside every call we make
    mov al, VBV_CAPS
    call vbe_call
    jnc .out
    call vbe_drop               ; it took the file and then refused
.no:
    stc
.out:
    pop es
    pop di
    pop bx
    ret

; -----------------------------------------------------------------------------
; vbe_drop - give the image back
; Preserves every register but the flags. Safe when nothing is loaded.
; -----------------------------------------------------------------------------
vbe_drop:
    push ax
    push bx
    cmp word [vbe_row+DRVR_SEG], 0
    je .out
    mov bx, vbe_row
    call COLD_SEG:drvf_drv_release
.out:
    pop bx
    pop ax
    ret

%endif                          ; OS88_DRIVERS
