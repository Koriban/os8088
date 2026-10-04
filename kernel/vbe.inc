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
VBV_PROVE   equ 0x43            ; set it, prove the window, put mode 12h back

; --- the geometry block the overlay fills, read into vid_tab's row -----------
VBG_W       equ 0
VBG_H       equ 2
VBG_STRIDE  equ 4
VBG_SEG     equ 6
VBG_BANKS   equ 8
VBG_WFN     equ 10              ; dword: VBE's WinFuncPtr (see the driver)
VBG_GRAN    equ 14              ; word: granules to a 64KB bank
VBG_SZ      equ 16

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

vbe_cbank:  db 0xFF         ; the mapped bank, 0xFF = none known
vbe_hbank:  db 0            ; ...and the bank gfx_rowbase last HOMED on,
                            ; for a primitive that walks its rect twice
vbe_known:  db 0            ; 0 = the card has not been asked yet
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
    mov al, DRVV_ATTACH         ; LOADED IS NOT ATTACHED, and the distinction
    mov ah, VBE_ABI_VER         ; is drv_load_at's own: it does the mount, the
    call vbe_call               ; claim, the read and drv_check and STOPS, so
    jc .drop                    ; the probe inside the image has not run yet.
                                ; Leaving this out loaded the file, asked it
                                ; for a geometry it had never measured, and
                                ; lit nothing - the Display page simply had no
                                ; extra row and nothing said why
    push cs
    pop es                      ; the overlay writes the block through ES, and
    mov di, vbe_geom            ; ES is KERNEL_SEG inside every call we make
    mov al, VBV_CAPS
    call vbe_call
    jnc .out
.drop:
    call vbe_drop               ; it took the file and then refused
.no:
    stc
.out:
    pop es
    pop di
    pop bx
    ret

; -----------------------------------------------------------------------------
; vbe_avail - ask once, and light [vid_avail]'s bit if the answer is yes
; out:      nothing (all registers preserved)
;
; THE ONE CALLER IS THE CONTROL PANEL'S DISPLAY PAGE, through cw_vbe_avail,
; and that is the whole of why there is no boot sniff: CTRL.DRV has just been
; read off the system disk to draw the page, so the disk is demonstrably there
; at the one moment the question is asked. A machine that never opens that
; page never reads this file, and an 8088 - which can execute the probe and
; could never usefully run the mode - pays nothing either way.
;
; ASKED ONCE A SESSION. [vid_avail] is fixed for the life of the machine
; everywhere else (vid_probe_avail writes it once), so a second answer here
; would be the only moving bit in that byte.
;
; THE IMAGE IS KEPT, and that is a deliberate 1,372 bytes rather than an
; oversight: vid_setmode's VBE arm dispatches VBV_SET, and vid_setmode runs
; under the splash's resident-window rule and the gfx lock, where a disk read
; is not available to it. Loading here is what makes the mode settable there.
; Freeing it again when the user switches away is SPEC.md 39.29.3's, not this
; stage's.
; -----------------------------------------------------------------------------
vbe_avail:
    push ax
    cmp byte [vbe_known], 0
    jne .out
    mov byte [vbe_known], 1     ; asked, whatever the answer
    call vbe_caps
    jc .out                     ; the bit stays clear, and vbe_caps has already
                                ; given the image back

    ; ...AND THE BIOS SAYING YES IS NOT THE SAME AS THE CARD BEING DRIVABLE.
    ; VBV_PROVE sets the mode, writes one byte through the window, reads it
    ; back and puts mode 12h again - so a card that lists 0104h and cannot map
    ; it never grows a Display row at all, instead of growing one that has to
    ; be RECOVERED from at the moment it is picked. That is SPEC.md 47's "grey
    ; a fact, never a guess" with the fact measured.
    ;
    ; [spl_busy] is held across it for vid_setmode's own reason (SPEC.md
    ; 15.3.8.3): for part of it the card is not in the mode [vid_seg]
    ; describes, and a loading-screen frame arriving from IRQ0 would write its
    ; box at an address that is not the framebuffer.
    inc byte [spl_busy]
    mov al, VBV_PROVE
    call vbe_call
    dec byte [spl_busy]

    jc .out
    call vbe_setrow
    or byte [vid_avail], VID_A_VBE
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; vbe_setrow - overwrite vid_tab's VBE row with what the card actually reports
; out:      nothing (all registers preserved)
;
; vid_tab is otherwise four rows of constants, and this is the fifth being
; honest instead: a BIOS that advertises a mode it mis-programs is a known
; class (SPEC.md 39.28.2), so the segment, stride and width come from AX=4F01h
; and not from this file.
;
; THE HEIGHT IS NOT TAKEN FROM THE CARD. It is the rows ONE 64KB window holds -
; 65536 / stride - or the card's own height, whichever is smaller, because
; nothing below the renderer knows about banking yet (SPEC.md 39.29.1). At
; stride 128 that is 512 of the 768 the card offers, and the bottom third of
; the panel stays black until stage 2.
; -----------------------------------------------------------------------------
vbe_setrow:
    push ax
    push dx
    mov ax, [vbe_geom + VBG_SEG]
    mov [vid_tab_vbe], ax
    mov ax, [vbe_geom + VBG_STRIDE]
    mov [vid_tab_vbe + 2], ax           ; stride
    mov [vid_tab_vbe + 8], ax           ; ...and rowadd, which is the same
                                        ; number on a linear surface
    mov ax, [vbe_geom + VBG_W]
    mov [vid_tab_vbe + 14], ax          ; cw
    mov ax, [vbe_geom + VBG_H]          ; THE CARD'S OWN HEIGHT. It used to be
                                        ; clamped to the rows one 64KB window
                                        ; holds, because nothing below the
                                        ; renderer could cross a bank; SPEC.md
                                        ; 39.29.10's carry test is what lifts
                                        ; that, and the bottom third of the
                                        ; panel stops being dead
    mov [vid_tab_vbe + 16], ax          ; ch
    pop dx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vbe_bank - map window A over bank AL (SPEC.md 39.29.10)
; in:       AL = the 64KB bank
; out:      nothing. ALL REGISTERS AND THE FLAGS ARE PRESERVED, because the
;           callers are row loops that are carrying their own arithmetic in
;           every register they have, and gfx_rowbase_calc's own contract
;           preserves BX
;
; THE HOT PATH, and the reason it does not go through vbe_call. Three things
; rule that out: vbe_call brackets the dispatch with the heap compaction nest
; (SPEC.md 66.6.3), which is not an ISR-safe thing to do and the CURSOR draws
; from IRQ4; the overlay's answer would be an `int 10h AX=4F05h` into a BIOS
; that is not re-entrant; and both cost a far call through a dispatcher for
; what is six instructions of port writing.
;
; VBE publishes WinFuncPtr for exactly this - a far address that moves the
; window with no BIOS entry at all - and the driver hands it over at CAPS. It
; takes BH = 0 (set), BL = 0 (window A), DX = the position in GRANULES, which
; is why [vbe_gran] is published with it: a bank is 64KB and a granule may be
; smaller, so the kernel multiplies rather than assuming they are the same.
;
; THE EARLY-OUT IS MOST OF THE VALUE. A full-screen repaint is hundreds of
; primitives and nearly every one is wholly inside one bank, so this is a
; compare and a return for all of them.
;
; EVERY BYTE THIS ROUTINE TOUCHES IS `cs:`, AND THAT IS NOT STYLE. It is
; reached from inside three row loops that have given DS away - vga12.inc's
; plane-major blit (DS = the caller's planes), vga_save_vram (DS = VGA_SEG)
; and vga_restore_vram (DS = the save-under claim) - so a plain DS read here
; is a read of whatever those routines pointed at. It shipped that way once
; and all three reads are catastrophic rather than merely wrong:
;
;   cmp al, [vbe_cbank]       compares the wanted bank against A PIXEL, so a
;                             pixel that happens to equal AL takes `.same`
;                             and the window is never moved
;   mov [vbe_cbank], al       WRITES A BYTE INTO THE FRAMEBUFFER
;   call far [vbe_geom+WFN]   fetches a far pointer OUT OF VIDEO MEMORY and
;                             calls it
;
; The field saw exactly that pair of symptoms: the desktop went black on the
; mode switch (the wild far call) and dragging a window across row 512 left a
; staircase of save-under debris (the compare that matched). CS is KERNEL_SEG
; throughout `.text`, so the override is correct at every call site and costs
; one byte each. SPEC.md 39.29.10.1.
;
; This is the same defect as `[vid_stride]` (SPEC.md 39.29.10) one level up:
; anything a drawing inner loop can call must address its own state through
; CS, because the inner loops are precisely where DS is not ours.
; -----------------------------------------------------------------------------
vbe_bank:
    cmp al, [cs:vbe_cbank]
    je .same
    pushf                       ; a row loop's flags are its own
    push ax
    push bx
    push cx
    push dx
    push si                     ; ...and the pointer registers, which the four
    push di                     ; row loops that reach this hold LIVE across it
    push es                     ; (DI is a save-under buffer in vga_save_vram,
    push ds                     ; SI the source in vga_restore_vram). VBE says
                                ; WinFuncPtr preserves what it does not return,
                                ; and a laptop BIOS is still a laptop BIOS:
                                ; eight bytes buys the whole question
    mov [cs:vbe_cbank], al
    xor ah, ah
    mul word [cs:vbe_geom + VBG_GRAN]   ; DX:AX = the window position
    mov dx, ax
    xor bx, bx                  ; BH = 0 set, BL = 0 window A
    call far [cs:vbe_geom + VBG_WFN]
    pop ds
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
.same:
    ret

; -----------------------------------------------------------------------------
; vbe_bank_next - the row walk has just carried out of 16 bits: step the window
; out:      nothing (every register and the flags preserved)
;
; Reached only from VBROW below, and only on the one row in 512 where
; `add di, [vid_stride]` wraps - which is exactly the row that enters the next
; bank, because 128 divides 65536 (SPEC.md 39.29.10). DI has already wrapped to
; the correct offset INSIDE that bank, by the same arithmetic.
; -----------------------------------------------------------------------------
vbe_bank_next:
    pushf
    push ax
    mov al, [cs:vbe_cbank]      ; cs: for vbe_bank's reason, below
    inc al
    call vbe_bank
    pop ax
    popf
    ret

; -----------------------------------------------------------------------------
; vbe_bank_reset - forget which window is mapped (a mode set moved it)
; -----------------------------------------------------------------------------
vbe_bank_reset:
    mov byte [cs:vbe_cbank], 0xFF
    ret

; -----------------------------------------------------------------------------
; vbe_home - put the window back where this rect STARTED
; out:      nothing (every register and the flags preserved)
;
; A PRIMITIVE THAT WALKS ITS RECT MORE THAN ONCE MUST CALL THIS BETWEEN WALKS,
; and six of them do. gfx_rect_setup selects the bank ONCE, for the first row of
; the first walk; VBROW then steps it forward as the walk crosses row 512. The
; second walk restarts its pointer at [gfx_roff] - a bank-0 offset - and
; without this the window is still wherever the first walk ended, so everything
; the second walk touches lands 512 rows away.
;
; The walkers are the three that fill an edge column, the other edge column and
; then the interior (vga_solid_rect, gfx_fill_gray_raw, gfx_fill_pat_raw), and
; the three that walk once per PLANE (vga_save_vram, vga_restore_vram and the
; plane-major blit). The field saw it as solid light-grey blocks where a window
; had been dragged, and as the dragged window's own text drawn twice 512 rows
; apart - the interior of a fill and three planes of a save landing in the
; wrong window. SPEC.md 39.29.10.2.
;
; The `cmp` is what keeps it off every other adapter: with no banked mode
; [vbe_geom] is zero, so an unconditional vbe_bank here would far-call 0000:0000
; on a machine that has never seen a VESA BIOS.
; -----------------------------------------------------------------------------
vbe_home:
    pushf                       ; a walk's loop flags are its own, as in VBROW
    push ax
    cmp byte [cs:vid_kind], VID_VBE
    jne .out
    mov al, [cs:vbe_hbank]
    call vbe_bank               ; ...which early-outs when it is already there,
.out:                           ; so a walk that never straddled pays a compare
    pop ax
    popf
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
