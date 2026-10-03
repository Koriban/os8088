; =============================================================================
; os8088 - VBE.DRV: mode 0104h, 1024x768x16 PLANAR (SPEC.md 39.29)
;
; THIS IS AN OVERLAY, NOT A DRIVER (SPEC.md 39.29.2, 41.12), and XMEM.DRV is
; the precedent it copies field for field: a driver's header, a driver's org 0,
; a driver's three-byte dispatcher and a driver's one-claim load - and class
; DRVC_OVL, which the kernel deliberately does not know. No row in drv_tab, no
; publication slot, no Drivers-page tick, no SYSTEM.CFG bit, no Control Panel
; page. A machine either offers 0104h or it does not; a tick box would only
; ever be a way to break a working machine.
;
; WHAT IS IN HERE AND WHAT IS NOT. This owns the work that happens ONCE per
; mode change - probe, mode set, palette, geometry - and the window switch,
; which happens at most once per multi-row operation because 1024 pixels is
; 128 bytes a row and 128 divides 65536 exactly. It owns NO DRAWING, and that
; is not a preference (SPEC.md 39.29.2): gfx_* bodies are API slots and an
; OSAPI_SLOT names a KERNEL_SEG offset; the renderer is called from inside
; mod_need's own load, since fpg_busy draws for every sector read; and the
; mouse ISR draws the cursor through int 13h, where no loaded image can be
; reached. The per-pixel half is resident or it does not work.
;
; EVERYTHING IS READ, NOTHING IS ASSUMED. The stride, window segment,
; granularity and resolution all come back from AX=4F01h and are published to
; the kernel, which writes them into vid_tab's row before vid_apply ever reads
; it. tests/vbeset is the instrument that proved every register sequence below
; on the actual card (SPEC.md 39.28.2.3, readback 13 of 13), and it was written
; that way for this: a BIOS that advertises a mode it mis-programs is a known
; class, so a constant in here would be a guess about hardware we can ask.
;
; THE PALETTE IS PROGRAMMED, NOT INHERITED, and that is the one thing this file
; does that the test did not. SPEC.md 39.28.2.4 left open whether 0104h arrives
; with mode 12h's palette; rather than answer it and depend on the answer, the
; mode set below writes all sixteen Attribute Controller registers and the
; sixteen DAC entries they name. The desktop's colours are then this driver's
; doing on every card, and the open question stops mattering.
;
; Assemble: nasm -f bin -I drivers/ -I apps/ -o vbe.bin drivers/vbe/vbe.asm
; Prefix vb_.
; =============================================================================

%include "os88drv.inc"

VB_ABI_VER  equ 1               ; the private kernel<->overlay ABI (SPEC.md
                                ; 52.11's +10 word). The kernel passes what it
                                ; expects in AH at DRVV_ATTACH and a mismatch
                                ; is refused at LOAD rather than at the first
                                ; mode set - xm_attach's reason exactly: a
                                ; half-copied floppy must fail loudly

    OS88_OVERLAY 'VBE', VB_ABI_VER, vb_entry

VB_MODE     equ 0x0104          ; 1024x768x16 planar. The planar is the point
                                ; and not the resolution: a packed mode is a
                                ; second renderer, not a bigger one
VB_MINFO    equ 256             ; the ModeInfoBlock AX=4F01h fills
VB_INFO     equ 512             ; ...and the VbeInfoBlock AX=4F00h does

; --- what the kernel dispatches (mirrored in kernel/vbe.inc) -----------------
; THESE ARE VERBS IN AL, NOT A PUBLISHED TABLE. drv_call_ent loads BP from the
; row's DRVR_ENT, so every call lands on vb_entry below and the verb selects
; there - which is one dispatch to keep in step instead of a table whose
; offsets the kernel would have to learn at attach. 0x40 and up so a DRVV_*
; added to the kernel later can never collide with one of ours.
VBV_CAPS    equ 0x40            ; out: ES:DI filled with the VBG_ block, CF=0
VBV_SET     equ 0x41            ; set the mode, palette and bank 0; out CF
VBV_BANK    equ 0x42            ; in AL = bank; map window A over it; out CF

; --- the geometry block the kernel copies into vid_tab (SPEC.md 39.29.1) -----
VBG_W       equ 0               ; word: pixels across
VBG_H       equ 2               ; word: rows
VBG_STRIDE  equ 4               ; word: bytes a row a plane
VBG_SEG     equ 6               ; word: the window segment, as the BIOS says
VBG_BANKS   equ 8               ; word: 64KB windows the plane spans
VBG_SZ      equ 10

; --- ModeInfoBlock offsets ---------------------------------------------------
MI_ATTR     equ 0
MI_GRAN     equ 4               ; WinGranularity, KB
MI_WSIZE    equ 6               ; WinSize, KB
MI_WASEG    equ 8
MI_STRIDE   equ 16              ; BytesPerScanLine
MI_XRES     equ 18
MI_YRES     equ 20
MI_BPP      equ 25
MI_MODEL    equ 27              ; 3 = planar, and the only one we take

VGA_AC      equ 0x3C0           ; Attribute Controller index/write
VGA_ACR     equ 0x3C1           ; ...and its read port
VGA_DACW    equ 0x3C8           ; DAC write index
VGA_DACD    equ 0x3C9           ; DAC data, three 6-bit bytes an entry
VGA_STAT    equ 0x3DA           ; input status 1: resets the AC flip-flop

; -----------------------------------------------------------------------------
; vb_entry - the kernel far-calls this through the header's dispatcher
;
; in:       AL = verb, AH = the ABI the kernel expects (ATTACH only),
;           DS = CS = our segment, ES = KERNEL_SEG
;
; It NAMES every verb and REFUSES anything else (SPEC.md 51.2.2). snd_entry
; let unknown verbs fall into its attach body and DRVV_READY - added to the
; kernel later - ran a second complete attach; a verb added after this ships
; must land on a refusal, never on work.
; -----------------------------------------------------------------------------
vb_entry:
    cmp al, DRVV_ATTACH
    je vb_attach
    cmp al, DRVV_DETACH
    je vb_detach
    cmp al, VBV_CAPS
    je vb_caps
    cmp al, VBV_SET
    je vb_set
    cmp al, VBV_BANK
    je vb_bank
    stc
    ret

; -----------------------------------------------------------------------------
; vb_attach - probe, validate, and publish the geometry
;
; in:       AH = VB_ABI_VER as the kernel understands it
; out:      CF = 0, SI = the VBV_* table;  CF = 1 = this card cannot do it,
;           AND NOTHING WAS CHANGED - no mode was set and no port written
; clobbers: AX, BX, CX, DX, SI, DI (flags)
;
; THE MODE IS NOT SET HERE. Attach runs at boot, inside drv_boot, with the
; splash up and the desktop's geometry already live; setting a foreign mode
; there would leave the kernel drawing mode-12h geometry into a 1024-wide
; framebuffer with nothing able to put it back. Attach only ANSWERS, and
; VBV_SET is what the kernel calls when it has decided (SPEC.md 39.29.2).
;
; Every refusal below is a reason the mode could not be driven even if the
; BIOS lists it, in the order that makes the next question meaningful - which
; is tests/vbeset's own order, and for its reason: attr bit 0 clear means the
; card does not support what the BIOS advertised, and nothing after it means
; anything.
; -----------------------------------------------------------------------------
vb_attach:
    cmp ah, VB_ABI_VER
    jne .no                     ; a kernel of another vintage

    mov di, vb_info             ; a stale 'VESA' in the buffer would read as a
    mov cx, VB_INFO             ; pass, so it is cleared before the call
    call vb_zero
    push es                     ; the BIOS fills through ES:DI and ES is
    push ds                     ; KERNEL_SEG on entry
    pop es
    mov di, vb_info
    mov ax, 0x4F00
    int 0x10
    pop es
    push es                     ; ...and a sloppy VBE BIOS is a real thing
    push ds
    pop es
    cmp word [vb_info], 'VE'
    jne .nopop
    cmp word [vb_info+2], 'SA'
    jne .nopop

    mov di, vb_minfo
    mov cx, VB_MINFO
    call vb_zero
    mov di, vb_minfo
    mov cx, VB_MODE
    mov ax, 0x4F01
    int 0x10
    pop es

    cmp word [vb_minfo + MI_XRES], 0
    je .no                      ; the mode is absent
    test word [vb_minfo + MI_ATTR], 0x0001
    jz .no                      ; listed by the BIOS, not supported by the card
    cmp byte [vb_minfo + MI_MODEL], 3
    jne .no                     ; not planar: a second renderer, not this one
    cmp byte [vb_minfo + MI_BPP], 4
    jne .no
    cmp word [vb_minfo + MI_GRAN], 0
    je .no                      ; no windowed memory to bank through

    ; --- the stride must divide 65536, or a row straddles a bank -------------
    ; SPEC.md 39.29.1 is the whole argument for this mode over 800x600 and
    ; 1280x1024, and it is CHECKED rather than trusted: a card reporting a
    ; padded stride would put a bank boundary inside a row, and every `jnc` in
    ; the resident half would then fire in the middle of one.
    mov ax, [vb_minfo + MI_STRIDE]
    or ax, ax
    jz .no
    mov bx, ax
    dec bx
    test ax, bx
    jnz .no                     ; not a power of two, so it cannot divide 65536
    cmp ax, 128
    ja .no                      ; above 128 a 64KB window holds under 512 rows,
                                ; which no mode we take can need

    ; --- the granule: a power of two, and no larger than the window ----------
    mov ax, [vb_minfo + MI_GRAN]
    mov cl, 10                  ; KB -> bytes is ten doublings
.gsh:
    shr ax, 1
    jc .gdone
    inc cl
    cmp cl, 17
    jb .gsh
    jmp short .no
.gdone:
    or ax, ax
    jnz .no                     ; more than one bit set: not a power of two
    cmp cl, 16
    ja .no                      ; a granule above 64KB cannot be addressed
                                ; through a real-mode window at all
    mov al, 16
    sub al, cl
    mov ah, 0
    mov bx, 1
    mov cl, al
    shl bx, cl
    mov [vb_bmul], bx           ; granules to a 64KB bank: 1 when gran is 64KB

    ; --- publish -------------------------------------------------------------
    mov ax, [vb_minfo + MI_XRES]
    mov [vb_geom + VBG_W], ax
    mov ax, [vb_minfo + MI_YRES]
    mov [vb_geom + VBG_H], ax
    mov ax, [vb_minfo + MI_STRIDE]
    mov [vb_geom + VBG_STRIDE], ax
    mov ax, [vb_minfo + MI_WASEG]
    mov [vb_geom + VBG_SEG], ax

    ; banks = ceil(h * stride / 65536), computed as (h + rows-1) / rows so the
    ; 17-bit product never has to exist
    mov ax, 0                   ; rows a bank = 65536 / stride, and 65536 does
    mov dx, 1                   ; not fit a word, so it is built as DX:AX
    div word [vb_minfo + MI_STRIDE]
    mov bx, ax                  ; BX = rows a bank (512 at stride 128)
    mov ax, [vb_minfo + MI_YRES]
    add ax, bx
    dec ax
    xor dx, dx
    div bx
    mov [vb_geom + VBG_BANKS], ax

    mov byte [vb_cbank], 0xFF    ; no window is known to be mapped
    xor si, si                  ; NO SERVICE TABLE: the verbs are vb_entry's,
    clc                         ; so there is nothing for the kernel to copy
    ret
.nopop:
    pop es
.no:
    stc
    ret

; -----------------------------------------------------------------------------
; vb_detach - there is nothing hooked, so there is nothing to unhook
;
; It owns no interrupt, no port and no claim; the mode is the kernel's to leave
; through vid_setmode, which is a BIOS mode set like any other. All it does is
; forget which bank was mapped, so a later attach cannot inherit a stale one.
; -----------------------------------------------------------------------------
vb_detach:
    mov byte [vb_cbank], 0xFF
    clc
    ret

; -----------------------------------------------------------------------------
; vb_caps - copy the geometry block to ES:DI (VBV_CAPS)
; in:       ES:DI = a VBG_SZ buffer in KERNEL_SEG
; -----------------------------------------------------------------------------
vb_caps:
    push cx
    push si
    push di
    mov si, vb_geom
    mov cx, VBG_SZ
    cld
    rep movsb
    pop di
    pop si
    pop cx
    clc
    ret

; -----------------------------------------------------------------------------
; vb_set - set the mode, program the palette, map bank 0 (VBV_SET)
; out:      CF = 1 if the BIOS refused the mode, and nothing was changed
;
; The palette is written AFTER the mode set and not before: a BIOS mode set
; loads its own, so anything programmed first is overwritten by the call that
; follows it.
; -----------------------------------------------------------------------------
vb_set:
    push ax
    push bx
    push cx
    push dx
    push si
    mov ax, 0x4F02
    mov bx, VB_MODE             ; bit 15 clear: let the BIOS clear the memory,
    int 0x10                    ; which saves us 98,304 bytes of rep stosw
                                ; across two banks
    cmp ax, 0x004F
    jne .no
    mov byte [vb_cbank], 0xFF    ; the mode set moved the window; forget it
    xor al, al
    call vb_bank_set
    jc .back

    ; --- IS THE WINDOW ACTUALLY THERE? ---------------------------------------
    ; A BIOS can set the mode and still not put the framebuffer where a real-
    ; mode CPU can reach it, and then every primitive in the system writes into
    ; nothing and the screen is black with no way back. That is not
    ; hypothetical: QEMU's own 0104h does exactly this - tests/vbeset's raw
    ; probe reads 00 00 00 00 at A000 there against A5 A5 A5 A5 in mode 12h -
    ; and its attribute word says so honestly with bit 5 set for NOT VGA
    ; compatible (SPEC.md 39.28.2.1).
    ;
    ; So the same one-byte question vbeset asks is asked here, and a card that
    ; cannot answer it gets mode 12h back and a refusal the caller can act on,
    ; rather than a desktop nobody can see.
    push es
    mov es, [vb_geom + VBG_SEG]
    mov al, [es:0]              ; bank what was there - this runs before the
    mov ah, al                  ; palette, so the BIOS's own clear is all that
    mov byte [es:0], 0xA5       ; has touched it, but putting it back costs
    cmp byte [es:0], 0xA5       ; two instructions and assumes nothing
    mov [es:0], ah
    pop es
    jne .back

    call vb_palette             ; ...and only now is it worth programming
    clc
    jmp short .out
.back:
    mov ax, 0x0012              ; put a mode the machine can draw in back, so
    int 0x10                    ; the caller is recovering a working card and
.no:                            ; not a dark one
    stc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vb_bank - map window A over bank AH (VBV_BANK)
; in:       AH = the 64KB bank. AH AND NOT AL, because AL carried the verb in:
;           vb_entry dispatches on it, so a bank argument there would have to
;           be destroyed before it could be read
; out:      CF = 1 if the BIOS refused
;
; Called at most once per multi-row drawing operation, because a row never
; straddles (SPEC.md 39.29.1). The early-out matters more than it looks: a
; full-screen repaint is hundreds of primitives and nearly all of them are
; wholly inside one bank, so this is a compare and a return for most of them.
; -----------------------------------------------------------------------------
vb_bank:
    mov al, ah                  ; the verb is spent; AL is the bank from here
vb_bank_set:
    cmp al, [vb_cbank]
    je .same
    push ax
    push bx
    push cx
    push dx
    mov [vb_cbank], al
    xor ah, ah
    mul word [vb_bmul]          ; DX:AX = the window position in granules
    mov dx, ax
    mov ax, 0x4F05
    xor bx, bx                  ; BH = 0 set, BL = 0 window A
    int 0x10
    cmp ax, 0x004F
    pop dx
    pop cx
    pop bx
    pop ax
    jne .no
.same:
    clc
    ret
.no:
    mov byte [vb_cbank], 0xFF    ; it refused: nothing is known to be mapped
    stc
    ret

; -----------------------------------------------------------------------------
; vb_palette - the mode 12h palette, written rather than hoped for
;
; Sixteen Attribute Controller registers naming sixteen DAC entries, and the
; entries themselves. SPEC.md 39.28.2.4 measured this exact set off a known-
; good mode 12h and entry 6 is the diagnostic one: AC 14h = 2A1500 is brown,
; and a palette nobody programmed leaves 6 -> AC 06h = 2A2A00, dark yellow.
;
; Writing an AC index with bit 5 CLEAR is what makes the register writable and
; it also disconnects the palette from the screen; the 20h at the end puts it
; back, and leaving it out blanks the display. The 3DAh read before each index
; resets the shared address/data flip-flop, which has no other way into a
; known state.
; -----------------------------------------------------------------------------
vb_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    xor bx, bx
.ac:
    mov dx, VGA_STAT
    in al, dx                   ; reset the AC flip-flop
    mov dx, VGA_AC
    mov al, bl
    out dx, al                  ; index, bit 5 clear: a write
    mov al, [vb_pac + bx]
    out dx, al
    inc bx
    cmp bx, 16
    jb .ac
    mov dx, VGA_STAT
    in al, dx
    mov dx, VGA_AC
    mov al, 0x20                ; video back on
    out dx, al

    xor bx, bx
.dac:
    mov al, [vb_pac + bx]       ; the DAC entry this colour names
    mov dx, VGA_DACW
    out dx, al
    mov si, bx
    add si, bx
    add si, bx                  ; SI = colour * 3
    mov dx, VGA_DACD
    mov al, [vb_prgb + si]
    out dx, al
    mov al, [vb_prgb + si + 1]
    out dx, al
    mov al, [vb_prgb + si + 2]
    out dx, al
    inc bx
    cmp bx, 16
    jb .dac
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; vb_zero - CX bytes at DS:DI
vb_zero:
    push ax
    push cx
    push di
    xor al, al
    cld
.z:
    mov [di], al
    inc di
    loop .z
    pop di
    pop cx
    pop ax
    ret

; --- the palette, measured off a known-good mode 12h (SPEC.md 39.28.2.4) -----
vb_pac:
    db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
    db 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
vb_prgb:
    db 0x00,0x00,0x00,  0x00,0x00,0x2A,  0x00,0x2A,0x00,  0x00,0x2A,0x2A
    db 0x2A,0x00,0x00,  0x2A,0x00,0x2A,  0x2A,0x15,0x00,  0x2A,0x2A,0x2A
    db 0x15,0x15,0x15,  0x15,0x15,0x3F,  0x15,0x3F,0x15,  0x15,0x3F,0x3F
    db 0x3F,0x15,0x15,  0x3F,0x15,0x3F,  0x3F,0x3F,0x15,  0x3F,0x3F,0x3F

vb_cbank    db 0xFF             ; the mapped bank, 0xFF = none known
vb_bmul     dw 1                ; granules to a 64KB bank
vb_geom     times VBG_SZ db 0
vb_minfo    times VB_MINFO db 0
vb_info     times VB_INFO db 0

    OS88_DRV_END
