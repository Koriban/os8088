; =============================================================================
; os8088 - tests/vbeset/vbeset.asm
;
; VBESET: VBE mode 0104h is advertised (SPEC.md 39.28.1) - can it actually be
; SET, and does os8088's OWN renderer work once it is? `tests/vbeprobe` asked
; the BIOS to describe itself and it said yes. This writes pixels.
;
; A BIOS that advertises a mode it mis-programs is a known failure class, so
; nothing here is taken from the mode list: the stride, the window segment,
; the granularity and the window size are all read back from AX=4F01h and
; USED, and the bank arithmetic is recomputed from them. If this machine
; reports a stride that is not 128 the pattern is laid out for the stride it
; reports, and the report says so.
;
; --- why this is a BOOT DISK and not an os8088 package -----------------------
;
; It cannot be a package, and the rule is binding rather than prudential.
; SPEC.md 53.7 forbids `int 10h` mode sets outside `fsx_mode` - "the kernel
; must know what it is restoring FROM" - and SPEC.md 53.6 step 1 SKIPS the
; restoring mode set when no `fsx_mode` call ever happened. A package that set
; 0104h behind the bracket's back would therefore stop the desktop ever coming
; back: the machine would sit in 1024x768 with the kernel's renderer writing
; mode-12h geometry into it and no path home. `fsx_mode` has no VBE id (they
; stop at 8), and adding one is a KERNEL change that should not be made on the
; strength of a BIOS describing itself - which is the whole reason this exists.
;
; So it boots the machine itself and owns everything. Nothing to restore, no
; kernel to strand. It is the bootdiag shape (SPEC.md 2.9.10) and reuses
; bootdiag's own paranoid loader, tests/bootdiag/bdboot.asm, unchanged.
;
; NOTHING HERE WRITES TO A DISK.
;
; --- what the pattern is for -------------------------------------------------
;
; Each item exercises one path that kernel/vga12.inc actually uses, with the
; same register sequence, because "does VBE work" is not the question - "does
; THIS renderer work in this mode" is:
;
;   16 colour bars      Set/Reset (GC0 = colour, GC1 = 0Fh) with whole-byte
;                       writes under Bit Mask FFh. All four planes, 16 colours.
;   1px frame           single-pixel Bit Mask writes with a latch-loading read,
;                       at both ends of a byte (x=0 is bit 7, x=1023 is bit 0),
;                       and it is the STRIDE test: a wrong stride skews the
;                       vertical edges into diagonals, which no photograph can
;                       mistake for working
;   diagonal            the same, a thousand times, across every row group
;   three bank lines    at rowsplit-1 / rowsplit / rowsplit+1, the rows either
;                       side of a granule boundary. SPEC.md 39.28's whole claim
;                       is that this boundary falls BETWEEN rows here
;   second bar set      the same 16 colours drawn PAST the boundary, so a bank
;                       switch is proven to carry drawing and not just
;                       addressing
;   comb                1px columns every 4 over a filled block: the Bit Mask
;                       path again, where a half-working one shows as a solid
;                       block or an empty one
;   three XOR blocks    fill 7 / fill 7 XOR once / fill 7 XOR twice, through the
;                       ALU function (GC3 = 18h) with Set/Reset 0Fh and a read
;                       before every write. The first and third must MATCH and
;                       the middle one must not
;
; --- and it does not depend on the photograph --------------------------------
;
; After drawing, every probe point is READ BACK through Read Map Select (GC4),
; which is kernel/vga12.inc's own plane-read path, and compared with what was
; written. The verdict is printed in text mode as a per-probe PASS/FAIL. A
; photograph then confirms the DISPLAY - the DAC, the sync, the panel's own
; scaler - which readback cannot see. Two screens, two photographs.
;
;   make vbeset     -> build/vbeset.img, a 1.44MB bootable floppy
;
; Prefix vs_.
; =============================================================================

    cpu 8086                    ; SPEC.md 1. The VBE BIOS is a 386-era thing
                                ; and does whatever it does; OUR half stays
bits 16                         ; 8086, so the same binary is worth booting on
                                ; anything else that turns up with a VESA ROM
    org 0                       ; loaded at 0x00A0:0000 by bdboot.asm, which
                                ; enters with DS=0, ES=PAYLOAD_SEG, SS=0 and
                                ; SP=0x7C00 - see tests/bootdiag/bdboot.asm

VS_MODE     equ 0x0104          ; 1024x768x16 PLANAR - and the planar is the
                                ; point, not the resolution (SPEC.md 39.28)
VS_INFO     equ 512             ; the VbeInfoBlock AX=4F00h fills
VS_MINFO    equ 256             ; the ModeInfoBlock AX=4F01h fills
VS_LOG      equ 2048            ; bytes of transcript kept for vs_save
VS_LOGSEC   equ 100             ; ...and the LBA it is written to. Well clear of
                                ; the payload (os88disk puts that at LBA 33) and
                                ; inside a 1.44MB disk's 2880 sectors
VS_SPT      equ 18              ; the geometry vs_save converts LBA with. The
VS_HEADS    equ 2               ; Makefile builds this image --size 1440 and
                                ; nothing else, so these are facts rather than
                                ; assumptions - but they are named, because a
                                ; second geometry would silently write to the
                                ; wrong track
VS_HAND     equ 0x10            ; bdboot.asm writes its 15-byte handover record
                                ; into the PAYLOAD's own image at this offset,
                                ; after the load. Nothing of ours may live here

VGA_GC      equ 0x3CE           ; Graphics Controller index port (data +1),
VGA_SEQ     equ 0x3C4           ; Sequencer index - kernel/vga12.inc's names

; --- VbeInfoBlock offsets ----------------------------------------------------
VI_SIG      equ 0               ; 'VESA'
VI_VER      equ 4               ; word, BCD-ish: 0200h is 2.0
VI_MEM      equ 18              ; word, 64KB blocks

; --- ModeInfoBlock offsets ---------------------------------------------------
MI_ATTR     equ 0               ; word  ModeAttributes
MI_WINA     equ 2               ; byte  WinAAttributes
MI_GRAN     equ 4               ; word  WinGranularity, KB
MI_WSIZE    equ 6               ; word  WinSize, KB
MI_WASEG    equ 8               ; word  WinASegment
MI_STRIDE   equ 16              ; word  BytesPerScanLine
MI_XRES     equ 18              ; word
MI_YRES     equ 20              ; word
MI_PLANES   equ 24              ; byte  NumberOfPlanes
MI_BPP      equ 25              ; byte  BitsPerPixel
MI_MODEL    equ 27              ; byte  MemoryModel: 3 planar, 4 packed

; =============================================================================
; entry - and the hole bdboot writes into
; =============================================================================
vs_start:
    jmp vs_main

    times VS_HAND - ($ - $$) db 0
vs_hand:
    times 16 db 0               ; bdboot's record lands HERE and nowhere else.
                                ; Reserving it is not optional: the loader
                                ; writes it AFTER the payload is read, so
                                ; whatever occupies these bytes is overwritten
                                ; between the load and the first instruction

vs_main:
    mov ax, cs
    mov ds, ax                  ; bdboot left DS=0; everything below is
    mov es, ax                  ; DS-relative
    cld

vs_again:
    mov ax, 0x0003              ; a known text mode, whatever we were left in
    int 0x10
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov si, vs_s_banner
    call vs_puts

    call vs_query               ; AX=4F00h and AX=4F01h, all of it printed
    jc vs_halt                  ; ...and a refusal already explained

    mov si, vs_s_ready
    call vs_puts
%ifdef AUTORUN
    jmp .vbearm                 ; NO KEY. This build exists to be run by a
                                ; script on an emulator with no way to type:
                                ; it takes arm 1, writes the transcript to the
                                ; disk and halts, and the host reads the image
%endif
.key:
    call vs_getkey
    cmp al, 27                  ; Esc - leave the mode alone
    je vs_bye
    cmp al, '2'
    je .control
    cmp al, '1'
    jne .key
.vbearm:
    ; --- the one irreversible step -------------------------------------------
    mov byte [vs_banked], 1
    mov ax, 0x4F02
    mov bx, VS_MODE             ; bit 15 clear: DO clear the framebuffer
    int 0x10
    mov [vs_setax], ax
    mov ax, cs                  ; a sloppy VBE BIOS is a real thing, and the
    mov ds, ax                  ; mode set is the one call worth re-anchoring
    mov es, ax                  ; after
    cmp word [vs_setax], 0x004F
    jne vs_setfail
    jmp short .armed

    ; --- THE CONTROL: the same code in a mode that is known to work ----------
    ; A test that has only ever been seen to FAIL cannot tell a card that
    ; cannot do the mode from a bug in the code asking it to. Mode 12h is the
    ; one os8088 ships on, so every primitive below is proven against it every
    ; time the OS draws anything: if the pattern comes out here and not in
    ; 0104h, the difference is the MODE. The geometry is filled in by hand
    ; because there is no 4F01h to read it from.
.control:
    mov byte [vs_banked], 0     ; no VBE window function in a plain VGA mode
    mov ax, 0x0012
    int 0x10
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov word [vs_setax], 0x004F
    mov word [vs_minfo + MI_XRES], 640
    mov word [vs_minfo + MI_YRES], 480
    mov word [vs_minfo + MI_STRIDE], 80
    mov word [vs_minfo + MI_WASEG], 0xA000
    mov word [vs_minfo + MI_GRAN], 64
    mov word [vs_minfo + MI_WSIZE], 64
    mov byte [vs_minfo + MI_BPP], 4
    mov byte [vs_minfo + MI_PLANES], 4
    mov byte [vs_minfo + MI_MODEL], 3
    mov byte [vs_winshift], 16
    mov word [vs_winmask], 0xFFFF
    mov word [vs_rowsplit], 819 ; 65536 / 80, and 819 > 480: one granule holds
    mov word [vs_rowrem], 16    ; the whole plane, so nothing banks
.armed:
    call vs_geom                ; every coordinate below derives from the
                                ; geometry just established, so one pattern
                                ; serves both arms

    call vs_raw                 ; is the memory even there? - before anything
    call vs_draw                ; the pattern
    call vs_check               ; read it back through GC4

%ifndef AUTORUN
    call vs_getkey              ; hold the picture for the camera - and THE
                                ; AUTORUN BUILD MUST NOT, which is the third
                                ; of three key waits in this file and the one
                                ; that was missed. It blocked forever with the
                                ; card still in 0104h, so the screendump came
                                ; back 1024x768 and black and the transcript
                                ; was never written
%endif
    call vs_pal                 ; ...then read the palette, STILL IN THE MODE

    mov ax, 0x0003              ; back to text for the verdict
    int 0x10
    mov ax, cs
    mov ds, ax
    mov es, ax
    call vs_report
%ifdef AUTORUN
    call vs_save                ; the transcript is the whole output of this
    jmp vs_halt                 ; build; nothing is waiting to read a screen
%endif
    call vs_getkey
    or al, 0x20
    cmp al, 's'
    jne .nosave
    call vs_save                ; ...and interactively too, so a run on real
    mov si, vs_s_saved          ; hardware comes back as TEXT rather than as a
    call vs_puts                ; photograph of an LCD (SPEC.md 39.28.2.4)
    call vs_getkey
    or al, 0x20
.nosave:
    cmp al, 'r'
    je vs_again
vs_bye:
    mov ax, 0x0003
    int 0x10
    mov ax, cs
    mov ds, ax
    mov si, vs_s_bye
    call vs_puts
vs_halt:
%ifdef AUTORUN
    ; EVERY PATH SAVES, not just the one that worked. The first version only
    ; wrote the transcript after a successful run, so a machine that REFUSED
    ; the mode - which is the answer most worth having - halted with an empty
    ; sector and nothing to read. A second save after the normal one is
    ; harmless; an unsaved refusal is a run wasted.
    call vs_save
%endif
    cli
    hlt
    jmp short vs_halt

vs_setfail:
    mov ax, 0x0003              ; it refused: say so from a known screen state
    int 0x10
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov si, vs_s_setfail
    call vs_puts
    mov ax, [vs_setax]
    call vs_hex4
    mov si, vs_s_setfail2
    call vs_puts
    jmp short vs_halt

; =============================================================================
; vs_query - AX=4F00h then AX=4F01h, printed, and every derived number
;            computed from what came back rather than from VS_MODE's name
; out: CF=1 and a printed reason if this machine cannot be asked to go on
; =============================================================================
vs_query:
    ; --- 4F00h ---------------------------------------------------------------
    mov di, vs_info
    mov cx, VS_INFO             ; a stale 'VESA' left in the buffer would read
    xor al, al                  ; as a pass, so it is cleared first
.clr:
    mov [di], al
    inc di
    loop .clr
    mov di, vs_info
    mov ax, 0x4F00
    int 0x10
    mov ax, cs
    mov ds, ax
    mov es, ax
    cmp word [vs_info + VI_SIG], 'VE'
    jne .novbe
    cmp word [vs_info + VI_SIG + 2], 'SA'
    jne .novbe

    mov si, vs_s_ver
    call vs_puts
    mov ax, [vs_info + VI_VER]
    call vs_hex4
    mov si, vs_s_mem
    call vs_puts
    mov ax, [vs_info + VI_MEM]
    call vs_dec
    mov si, vs_s_memu
    call vs_puts

    ; --- 4F01h ---------------------------------------------------------------
    mov di, vs_minfo
    mov cx, VS_MINFO
    xor al, al
.clr2:
    mov [di], al
    inc di
    loop .clr2
    mov di, vs_minfo
    mov cx, VS_MODE
    mov ax, 0x4F01
    int 0x10
    mov ax, cs
    mov ds, ax
    mov es, ax
    cmp word [vs_minfo + MI_XRES], 0
    je .nomode

    mov si, vs_s_geo
    call vs_puts
    mov ax, [vs_minfo + MI_XRES]
    call vs_dec
    mov al, 'x'
    call vs_putc
    mov ax, [vs_minfo + MI_YRES]
    call vs_dec
    mov si, vs_s_bpp
    call vs_puts
    xor ah, ah
    mov al, [vs_minfo + MI_BPP]
    call vs_dec
    mov si, vs_s_planes
    call vs_puts
    xor ah, ah
    mov al, [vs_minfo + MI_PLANES]
    call vs_dec
    mov si, vs_s_model
    call vs_puts
    xor ah, ah
    mov al, [vs_minfo + MI_MODEL]
    call vs_dec
    call vs_nl

    mov si, vs_s_attr           ; the attribute word, then the three bits that
    call vs_puts                ; decide anything, in words
    mov ax, [vs_minfo + MI_ATTR]
    call vs_hex4
    call vs_nl
    mov ax, [vs_minfo + MI_ATTR]
    mov si, vs_s_a_sup          ; bit 0: supported by the hardware
    test ax, 0x0001
    call vs_yesno
    mov ax, [vs_minfo + MI_ATTR]
    mov si, vs_s_a_vga          ; bit 5 INVERTED: 0 means VGA compatible
    xor ax, 0x0020
    test ax, 0x0020
    call vs_yesno
    mov ax, [vs_minfo + MI_ATTR]
    mov si, vs_s_a_win          ; bit 6 INVERTED: 0 means windowed memory is
    xor ax, 0x0040              ; available
    test ax, 0x0040
    call vs_yesno

    mov si, vs_s_stride         ; the stride is READ, never assumed
    call vs_puts
    mov ax, [vs_minfo + MI_STRIDE]
    call vs_dec
    mov si, vs_s_wseg
    call vs_puts
    mov ax, [vs_minfo + MI_WASEG]
    call vs_hex4
    mov si, vs_s_gran
    call vs_puts
    mov ax, [vs_minfo + MI_GRAN]
    call vs_dec
    mov si, vs_s_wsize
    call vs_puts
    mov ax, [vs_minfo + MI_WSIZE]
    call vs_dec
    call vs_nl

    ; --- the refusals, each one making the next question meaningful ----------
    test word [vs_minfo + MI_ATTR], 0x0001
    jz .unsup
    cmp byte [vs_minfo + MI_MODEL], 3
    jne .notplanar
    cmp word [vs_minfo + MI_GRAN], 0
    je .nowin
    cmp word [vs_minfo + MI_STRIDE], 2  ; 2 and not 1: a granule of 65536 over
    jb .nostride                        ; a stride of 1 is a 17-bit quotient
                                        ; and `div` would trap rather than
                                        ; answer. No real mode is near this

    ; --- the bank arithmetic, from the REPORTED granularity and stride -------
    ; winshift = log2(gran KB * 1024). The granule is a power of two on every
    ; VBE implementation there is; a machine where it is not says so and stops,
    ; rather than drawing to an address computed by a wrong rule.
    mov ax, [vs_minfo + MI_GRAN]
    mov cl, 10                  ; KB -> bytes is ten doublings
.sh:
    shr ax, 1
    jc .shdone                  ; the set bit: gran was 1 << (cl - 10)
    inc cl
    cmp cl, 26
    jb .sh
    jmp .badgran
.shdone:
    or ax, ax                   ; anything left means gran was not a power of 2
    jnz .badgran
    cmp cl, 16                  ; a granule above 64KB cannot be addressed
    ja .badgran                 ; through a real-mode window at all
    mov [vs_winshift], cl

    mov ax, 1                   ; the in-window mask, (1 << shift) - 1
    cmp cl, 16
    jae .m16
    shl ax, cl
    dec ax
    jmp short .mdone
.m16:
    mov ax, 0xFFFF              ; shift 16: the whole low word IS the offset
.mdone:
    mov [vs_winmask], ax

    ; rowsplit = granule bytes / stride, and the REMAINDER is the finding: zero
    ; means a bank boundary falls between rows, which is SPEC.md 39.28's whole
    ; argument for this mode over 800x600 and 1280x1024.
    mov cl, [vs_winshift]
    mov dx, 1                   ; DX:AX = 1 << winshift, built as a 32-bit
    xor ax, ax                  ; value because shift 16 does not fit a word
    cmp cl, 16
    je .gb16
    mov ax, 1
    shl ax, cl
    xor dx, dx
.gb16:
    div word [vs_minfo + MI_STRIDE]     ; DX:AX / stride -> AX quotient,
    mov [vs_rowsplit], ax               ;                   DX remainder
    mov [vs_rowrem], dx

    mov si, vs_s_split
    call vs_puts
    mov ax, [vs_rowsplit]
    call vs_dec
    mov si, vs_s_rows
    call vs_puts
    cmp word [vs_rowrem], 0
    jne .straddle
    mov si, vs_s_exact
    call vs_puts
    clc
    ret
.straddle:
    mov si, vs_s_strad          ; NOT a refusal: the pattern still draws, and
    call vs_puts                ; the three bank lines are then the thing to
    mov ax, [vs_rowrem]         ; look at hardest
    call vs_dec
    mov si, vs_s_strad2
    call vs_puts
    clc
    ret

.novbe:
    mov si, vs_s_novbe
    jmp short .no
.nomode:
    mov si, vs_s_nomode
    jmp short .no
.unsup:
    mov si, vs_s_unsup
    jmp short .no
.notplanar:
    mov si, vs_s_notplanar
    jmp short .no
.nowin:
    mov si, vs_s_nowin
    jmp short .no
.nostride:
    mov si, vs_s_nostride
    jmp short .no
.badgran:
    mov si, vs_s_badgran
.no:
    call vs_puts
    stc
    ret

; =============================================================================
; the planar primitives - kernel/vga12.inc's register sequences, at this mode's
; stride instead of ROW_BYTES, and through a bank window
; =============================================================================

; -----------------------------------------------------------------------------
; vs_setcol - arm Set/Reset for colour AL (vga12.inc's vga_set_color)
; -----------------------------------------------------------------------------
vs_setcol:
    push ax
    push dx
    mov [vs_colour], al
    mov dx, VGA_GC
    mov ah, al
    xor al, al                  ; GC0: Set/Reset value
    out dx, ax
    mov ax, 0x0F01              ; GC1: enable Set/Reset on all four planes
    out dx, ax
    mov ax, 0x0003              ; GC3: rotate 0, function = replace
    out dx, ax
    pop dx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vs_setxor - Set/Reset 0Fh with the ALU set to XOR (vga12.inc's vga_set_xor).
; Every target byte must then be READ before it is written, whole ones
; included: the ALU works off the latches.
; -----------------------------------------------------------------------------
vs_setxor:
    push ax
    push dx
    mov dx, VGA_GC
    mov ax, 0x0F00              ; GC0: Set/Reset value = 0Fh
    out dx, ax
    mov ax, 0x0F01              ; GC1: enable on all planes
    out dx, ax
    mov ax, 0x1803              ; GC3: rotate 0, function = XOR
    out dx, ax
    pop dx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vs_gcreset - the GC default state (vga12.inc's vga_gc_reset, SPEC.md 1.7)
; -----------------------------------------------------------------------------
vs_gcreset:
    push ax
    push dx
    mov dx, VGA_GC
    mov ax, 0x0001              ; GC1: Set/Reset enable off
    out dx, ax
    mov ax, 0x0003              ; GC3: replace
    out dx, ax
    mov ax, 0xFF08              ; GC8: Bit Mask = all bits
    out dx, ax
    mov ax, 0x0004              ; GC4: Read Map back to plane 0
    out dx, ax
    mov ax, 0x0005              ; GC5: write mode 0. vga12.inc's resting state
    out dx, ax                  ; names it and the kernel's own mode set
    pop dx                      ; establishes it - across a VBE mode set it is
    pop ax                      ; not ours to assume
    ret

; -----------------------------------------------------------------------------
; vs_off - the plane byte offset of ([vs_bytex], BX) -> DX:AX
; in:       [vs_bytex] = the BYTE column (x >> 3), BX = y
; clobbers: AX, DX, flags
; -----------------------------------------------------------------------------
vs_off:
    mov ax, bx
    mul word [vs_minfo + MI_STRIDE]     ; DX:AX = y * stride - 17 bits on a
    add ax, [vs_bytex]                  ; 1024-wide 4bpp plane, so the pair is
    adc dx, 0                           ; not an affectation
    ret

; -----------------------------------------------------------------------------
; vs_win - make the window cover plane offset DX:AX
; out:      ES = the window segment, DI = the offset within it
; clobbers: AX, BX, DX, SI, flags. CX survives.
;
; The window is only reprogrammed when the granule CHANGES, which is what keeps
; a full-width span from switching banks a thousand times.
; -----------------------------------------------------------------------------
vs_win:
    push cx
    mov si, ax                  ; BX:SI = the offset, about to be shifted down
    mov bx, dx
    mov cl, [vs_winshift]
    push si                     ; ...keeping the low word: the in-window offset
.sh:                            ; is the masked copy of it
    shr bx, 1
    rcr si, 1
    dec cl
    jnz .sh
    mov bx, si                  ; BX = the granule index - well inside a word:
    pop si                      ; a 4bpp plane is a few hundred KB at most

    and si, [vs_winmask]
    mov di, si                  ; DI = the offset within the window

    cmp byte [vs_banked], 0     ; a plain VGA mode has no window function to
    je .have                    ; call, and calling 4F05h in one would be a
                                ; VBE service asked of a BIOS not in a VBE mode
    cmp bx, [vs_curwin]
    je .have
    mov [vs_curwin], bx
    push di
    mov dx, bx                  ; DX = the window position, in granules
    mov ax, 0x4F05
    xor bx, bx                  ; BH=0 set, BL=0 window A
    int 0x10
    mov ax, cs
    mov ds, ax
    pop di
.have:
    mov es, [vs_minfo + MI_WASEG]
    pop cx
    ret

; -----------------------------------------------------------------------------
; vs_hspan - the run x=[SI..DI] on row BX in the armed colour
; in:       SI = x1, DI = x2 (x1 <= x2), BX = y, [vs_xorm] = 0 replace / 1 XOR
; clobbers: AX, CX, DX, SI, DI, ES, flags. BX survives.
;
; This is vga12.inc's vga_solid_rect reduced to one row: a masked left edge
; column, a masked right edge column, then the whole bytes between. Under
; Set/Reset the CPU byte is IGNORED, so `mov al,[es:di] / mov [es:di],al` means
; "load the latches, write the masked colour" in both modes - which is exactly
; why the edge code is shared between replace and XOR rather than written twice.
; -----------------------------------------------------------------------------
vs_hspan:
    push bx
    mov ax, si                  ; the left and right BYTE columns
    mov cl, 3
    shr ax, cl
    mov [vs_b1], ax
    mov ax, di
    shr ax, cl
    mov [vs_b2], ax

    mov cx, si                  ; left mask: from bit (7 - x1 mod 8) down to 0
    and cx, 7
    mov al, 0xFF
    shr al, cl
    mov [vs_m1], al

    mov cx, di                  ; right mask: from bit 7 down to (7 - x2 mod 8)
    and cx, 7
    xor cx, 7
    mov al, 0xFF
    shl al, cl
    mov [vs_m2], al

    mov ax, [vs_b1]
    cmp ax, [vs_b2]
    jne .wide
    mov al, [vs_m1]             ; one byte holds the whole run
    and al, [vs_m2]
    mov [vs_mcur], al
    mov ax, [vs_b1]
    call vs_edge
    jmp short .out
.wide:
    mov al, [vs_m1]             ; the left partial byte
    mov [vs_mcur], al
    mov ax, [vs_b1]
    call vs_edge

    mov al, [vs_m2]             ; the right partial byte
    mov [vs_mcur], al
    mov ax, [vs_b2]
    call vs_edge

    mov ax, [vs_b2]             ; ...and the whole bytes between them
    sub ax, [vs_b1]
    dec ax
    jz .out
    mov cx, ax                  ; CX = interior byte count
    mov ax, [vs_b1]
    inc ax
    call vs_interior
.out:
    pop bx
    ret

; vs_edge - the byte column in AX on row BX, under the mask in [vs_mcur]
vs_edge:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ax
    mov dx, VGA_GC
    mov ah, [vs_mcur]
    mov al, 8                   ; GC8: Bit Mask
    out dx, ax
    pop ax
    mov [vs_bytex], ax
    call vs_off
    call vs_win
    mov al, [es:di]             ; load the latches...
    mov [es:di], al             ; ...and write the masked colour
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; vs_interior - CX whole bytes from byte column AX on row BX
vs_interior:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov [vs_bytex], ax
    push cx
    call vs_off
    call vs_win
    pop cx
    mov dx, VGA_GC
    mov ax, 0xFF08              ; whole bytes: in replace mode the latches do
    out dx, ax                  ; not matter
    cmp byte [vs_xorm], 0
    jne .xor
    mov al, [vs_colour]         ; ignored under Set/Reset, but a defined value
    rep stosb                   ; beats whatever AL happened to be holding
    jmp short .out
.xor:
    mov al, [es:di]             ; the XOR ALU works off the latches, so EVERY
    stosb                       ; byte is read immediately before it is written
    loop .xor
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vs_rect - fill x=[SI..DI], y=[AX..DX] in the armed colour
; -----------------------------------------------------------------------------
vs_rect:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, ax
    mov [vs_y2], dx
.row:
    push si
    push di
    call vs_hspan
    pop di
    pop si
    inc bx
    cmp bx, [vs_y2]
    jbe .row
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vs_pixel - one pixel at (CX=x, BX=y) in the armed colour
; Preserves every register.
; -----------------------------------------------------------------------------
vs_pixel:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov si, cx
    mov di, cx
    call vs_hspan               ; a one-pixel span IS the single-byte masked
    pop es                      ; case above: one routine, one set of edge
    pop di                      ; arithmetic to get wrong
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; vs_getpx - read the colour at (CX=x, BX=y) -> AL
;
; Read Map Select (GC4) a plane at a time, which is kernel/vga12.inc's own
; plane-read path - its region save uses the identical sequence.
; -----------------------------------------------------------------------------
vs_getpx:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov [vs_px], cx             ; PARK x FIRST: `mov cl, 3` below writes the
    mov ax, cx                  ; low half of the register holding it, and
    mov cl, 3                   ; reading x back out of CX afterwards gave a
    shr ax, cl                  ; bit index of 4 for every pixel on the screen
    mov [vs_bytex], ax          ; - which is the NEIGHBOURING pixel, and so is
    mov ax, [vs_px]             ; invisible anywhere the picture is solid.
    and ax, 7                   ; Only the comb's alternating columns could
    xor ax, 7                   ; show it, and that is what they are for
    mov [vs_bit], al            ; the bit index within the byte
    call vs_off
    call vs_win
    mov byte [vs_plane], 0
    mov byte [vs_got], 0
.plane:
    mov dx, VGA_GC
    mov ah, [vs_plane]
    mov al, 4                   ; GC4: Read Map Select
    out dx, ax
    mov al, [es:di]
    mov cl, [vs_bit]
    shr al, cl
    and al, 1
    mov cl, [vs_plane]
    shl al, cl
    or [vs_got], al
    inc byte [vs_plane]
    cmp byte [vs_plane], 4
    jb .plane
    mov dx, VGA_GC
    mov ax, 0x0004              ; GC4 back to plane 0
    out dx, ax
    mov al, [vs_got]
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; =============================================================================
; vs_geom - derive the pattern's coordinates, and BUILD the probe table
;
; Nothing in the pattern is a literal screen position any more. The control
; arm runs at 640x480 and the VBE arm at 1024x768, and a pattern with 1024 in
; it would have written off the end of every row in the control - which is the
; one failure that would have made the control agree with the fault it exists
; to rule out.
;
; The bands are laid out from the BOTTOM for the two that must sit past a bank
; boundary when there is one, and they do not overlap in either geometry:
;
;            1024x768     640x480
;   bars       0..63        0..63
;   XOR      100..147     100..147
;   bars2    600..663     312..375     (YRES-168)
;   comb     700..731     412..443     (YRES-68)
; =============================================================================
vs_geom:
    mov ax, [vs_minfo + MI_XRES]
    mov cl, 4
    shr ax, cl
    mov [vs_barw], ax           ; sixteen bars across, whatever the width

    mov ax, [vs_minfo + MI_YRES]
    sub ax, 168
    mov [vs_yb2], ax
    mov ax, [vs_minfo + MI_YRES]
    sub ax, 68
    mov [vs_ycomb], ax

    ; --- the probes, in the order the pattern draws them ---------------------
    mov word [vs_pp], vs_probes
    mov cx, [vs_barw]           ; bar 5, half a bar in
    mov ax, 5
    mul cx
    shr cx, 1
    add cx, ax
    mov bx, 32
    mov al, 5
    call vs_addp
    mov cx, [vs_barw]           ; bar 9 - a colour with plane 3 set
    mov ax, 9
    mul cx
    shr cx, 1
    add cx, ax
    mov bx, 32
    mov al, 9
    call vs_addp

    mov cx, 210                 ; the XOR witnesses are at fixed x because
    mov bx, 110                 ; 200..447 fits both widths
    mov al, 7
    call vs_addp
    mov cx, 310
    mov bx, 110
    mov al, 8
    call vs_addp
    mov cx, 410
    mov bx, 110
    mov al, 7
    call vs_addp

    ; the three rows either side of a granule boundary - ONLY when there is
    ; one inside the picture, which the control arm has not got
    mov ax, [vs_rowsplit]
    or ax, ax
    jz .nobank
    inc ax
    cmp ax, [vs_minfo + MI_YRES]
    jae .nobank
    mov cx, 500
    mov bx, [vs_rowsplit]
    dec bx
    mov al, 14
    call vs_addp
    mov cx, 500
    mov bx, [vs_rowsplit]
    mov al, 12
    call vs_addp
    mov cx, 500
    mov bx, [vs_rowsplit]
    inc bx
    mov al, 10
    call vs_addp
.nobank:
    mov cx, [vs_barw]           ; the second bar set
    mov ax, 5
    mul cx
    shr cx, 1
    add cx, ax
    mov bx, [vs_yb2]
    add bx, 20
    mov al, 5
    call vs_addp

    mov cx, 100                 ; a lit comb column...
    mov bx, [vs_ycomb]
    add bx, 10
    mov al, 15
    call vs_addp
    mov cx, 101                 ; ...and the gap beside it
    mov bx, [vs_ycomb]
    add bx, 10
    mov al, 1
    call vs_addp

    mov cx, 0                   ; the frame's bottom corners: the left one is
    mov bx, [vs_minfo + MI_YRES]        ; past the boundary when there is one,
    dec bx                              ; and the right one is the LAST
    mov al, 15                          ; address in the framebuffer
    call vs_addp
    mov cx, [vs_minfo + MI_XRES]
    dec cx
    mov bx, [vs_minfo + MI_YRES]
    dec bx
    mov al, 15
    call vs_addp

    mov di, [vs_pp]             ; the terminator
    mov word [di], 0xFFFF
    ret

; vs_addp - append (CX, BX, AL) to the probe table
vs_addp:
    push di
    mov di, [vs_pp]
    mov [di], cx
    mov [di + 2], bx
    mov [di + 4], al
    add word [vs_pp], 5
    pop di
    ret

; =============================================================================
; vs_raw - BEFORE any drawing: is A000 the framebuffer at all?
;
; This separates the two failures that look identical from outside. With
; Set/Reset OFF, write mode 0 and the Sequencer's Map Mask open on all four
; planes, one CPU byte goes to all four planes unchanged - the simplest write
; the hardware has. Reading it back a plane at a time then says:
;
;   all four planes hold the byte   the window IS the framebuffer, and any
;                                   pattern failure is in the GC path above
;   some other value, or zero       the memory is not there, or not mapped,
;                                   and nothing built on it could have worked
;
; THE SEQUENCER'S MAP MASK IS SET HERE AND NOT INHERITED. kernel/vga12.inc
; opens with "Map Mask = 0Fh" in its resting state, which is true because the
; KERNEL's own mode set put it there. A VBE mode set is somebody else's, and
; what it leaves in the Sequencer is not a promise - the first version of this
; test inherited it and drew nothing at all.
; =============================================================================
VS_RAWB     equ 0xA5            ; a byte with bits in both nibbles, so a path
                                ; that drops half of them is visible

vs_raw:
    call vs_gcreset
    mov dx, VGA_SEQ
    mov ax, 0x0F02              ; SEQ2: Map Mask, all four planes
    out dx, ax

    mov word [vs_bytex], 1      ; (x 8..15, y 400) - a spot the pattern never
    mov bx, 400                 ; touches, so this cannot be confirmed by
    call vs_off                 ; something else having drawn there
    call vs_win
    mov byte [es:di], VS_RAWB

    mov byte [vs_plane], 0
.p:
    mov dx, VGA_GC
    mov ah, [vs_plane]
    mov al, 4                   ; GC4: Read Map Select
    out dx, ax
    mov al, [es:di]
    mov bx, 0
    mov bl, [vs_plane]
    mov [vs_rawr + bx], al
    inc byte [vs_plane]
    cmp byte [vs_plane], 4
    jb .p
    mov dx, VGA_GC
    mov ax, 0x0004
    out dx, ax
    ret

; =============================================================================
; vs_draw - the pattern
; =============================================================================
vs_draw:
    mov word [vs_curwin], 0xFFFF        ; no window is known to be mapped
    mov byte [vs_xorm], 0

    ; --- 16 colour bars, y 0..63, 64 pixels each -----------------------------
    mov byte [vs_i], 0
.bars:
    mov al, [vs_i]
    call vs_setcol
    mov al, [vs_i]
    xor ah, ah
    mul word [vs_barw]          ; x1 = i * barw, and barw is XRES/16 - the
    mov si, ax                  ; literal 64 here wrote off the end of every
    mov di, ax                  ; row in the 640-wide control arm
    add di, [vs_barw]
    dec di
    mov ax, 0
    mov dx, 63
    call vs_rect
    inc byte [vs_i]
    cmp byte [vs_i], 16
    jb .bars

    ; --- three XOR witness blocks, 48x48 at y 100 ----------------------------
    ; A is a plain fill, B is XORed once and C twice. A and C must MATCH and B
    ; must differ - readable off a photograph without a legend, and checkable
    ; without one.
    mov al, 7
    call vs_setcol
    mov si, 200
    mov di, 247
    mov ax, 100
    mov dx, 147
    call vs_rect
    mov si, 300
    mov di, 347
    mov ax, 100
    mov dx, 147
    call vs_rect
    mov si, 400
    mov di, 447
    mov ax, 100
    mov dx, 147
    call vs_rect

    call vs_setxor
    mov byte [vs_xorm], 1
    mov si, 300                 ; B: once
    mov di, 347
    mov ax, 100
    mov dx, 147
    call vs_rect
    mov si, 400                 ; C: twice, so it comes back to 7
    mov di, 447
    mov ax, 100
    mov dx, 147
    call vs_rect
    mov si, 400
    mov di, 447
    mov ax, 100
    mov dx, 147
    call vs_rect
    mov byte [vs_xorm], 0
    call vs_gcreset

    ; --- the second bar set, PAST the bank boundary --------------------------
    mov byte [vs_i], 0
.bars2:
    mov al, [vs_i]
    call vs_setcol
    mov al, [vs_i]
    xor ah, ah
    mul word [vs_barw]
    mov si, ax
    mov di, ax
    add di, [vs_barw]
    dec di
    mov ax, [vs_yb2]
    mov dx, ax
    add dx, 63
    call vs_rect
    inc byte [vs_i]
    cmp byte [vs_i], 16
    jb .bars2

    ; --- the comb: 1px columns every 4 over a filled block -------------------
    mov al, 1
    call vs_setcol
    mov si, 100
    mov di, 163
    mov ax, [vs_ycomb]
    mov dx, ax
    add dx, 31
    call vs_rect
    mov al, 15
    call vs_setcol
    mov cx, 100
.comb:
    mov bx, [vs_ycomb]
.combrow:
    call vs_pixel
    inc bx
    mov ax, [vs_ycomb]
    add ax, 31
    cmp bx, ax
    jbe .combrow
    add cx, 4
    cmp cx, 163
    jbe .comb

    ; --- the three bank lines ------------------------------------------------
    ; The rows either side of a granule boundary, in three colours a camera
    ; cannot confuse. If the boundary falls between rows these are three clean
    ; full-width lines; if drawing tears at the switch, this is where it shows.
    mov ax, [vs_rowsplit]
    or ax, ax
    jz .nolines
    inc ax
    cmp ax, [vs_minfo + MI_YRES]
    jae .nolines                ; the whole plane fits one granule: no boundary
    mov al, 14
    call vs_setcol
    mov bx, [vs_rowsplit]
    dec bx
    call vs_fullrow
    mov al, 12
    call vs_setcol
    mov bx, [vs_rowsplit]
    call vs_fullrow
    mov al, 10
    call vs_setcol
    mov bx, [vs_rowsplit]
    inc bx
    call vs_fullrow
.nolines:

    ; --- the diagonal --------------------------------------------------------
    ; y = x * YRES / XRES, a multiply and a divide per column, so it is right
    ; for whatever geometry the BIOS actually gave us rather than for 1024x768.
    mov al, 14
    call vs_setcol
    mov cx, 0
.diag:
    mov ax, cx
    mul word [vs_minfo + MI_YRES]
    div word [vs_minfo + MI_XRES]
    mov bx, ax
    call vs_pixel
    inc cx
    cmp cx, [vs_minfo + MI_XRES]
    jb .diag

    ; --- the frame, LAST so nothing draws over it ----------------------------
    mov al, 15
    call vs_setcol
    mov bx, 0
    call vs_fullrow
    mov bx, [vs_minfo + MI_YRES]
    dec bx
    call vs_fullrow
    mov bx, 0
.vside:
    mov cx, 0
    call vs_pixel
    mov cx, [vs_minfo + MI_XRES]
    dec cx
    call vs_pixel
    inc bx
    cmp bx, [vs_minfo + MI_YRES]
    jb .vside

    call vs_gcreset
    ret

; vs_fullrow - row BX, edge to edge, in the armed colour. Preserves BX.
vs_fullrow:
    push si
    push di
    mov si, 0
    mov di, [vs_minfo + MI_XRES]
    dec di
    call vs_hspan
    pop di
    pop si
    ret

; =============================================================================
; vs_check - read every probe point back and record what came out
;
; The table is vs_geom's, built from this machine's own stride, granularity
; and resolution. Writing 512 into it would have been assuming the answer the
; test exists to check.
; =============================================================================
vs_check:
    mov byte [vs_pass], 0
    mov byte [vs_fail], 0
    mov si, vs_probes
    mov di, vs_results
.one:
    mov cx, [si]
    cmp cx, 0xFFFF
    je .done
    mov bx, [si + 2]
    push si
    push di
    call vs_getpx
    pop di
    pop si
    mov [di], al                ; what the framebuffer actually held
    cmp al, [si + 4]
    jne .bad
    inc byte [vs_pass]
    jmp short .next
.bad:
    inc byte [vs_fail]
.next:
    add si, 5
    inc di
    jmp short .one
.done:
    ret

; =============================================================================
; vs_pal - read the 16-colour palette as the hardware actually holds it
;
; A PHOTOGRAPH CANNOT ANSWER A PALETTE QUESTION and two attempts proved it:
; the panel is TN, so its colour shifts with height, and the control arm's
; picture is letterboxed mid-panel while the VBE arm's fills the screen - so
; the same colour is photographed at two different viewing angles. Normalising
; each bar row against its own colour 0 and 15 cancels that, but only if the
; picture's rectangle is found correctly in the photo, and the room behind the
; laptop is brighter than the frame. Both attempts latched onto the room.
;
; The hardware is readable, so read it. Colour -> Attribute Controller palette
; register -> DAC entry -> six-bit RGB, which is the whole chain and leaves
; nothing to a camera. Both arms print it, so they compare directly.
;
; Reading the AC is the one part with a trap: writing an index with bit 5
; CLEAR is what lets 3C1h be read, and it also disconnects the palette from
; the screen - leaving it that way blanks the display. The 20h write at the
; end puts it back, and the 3DAh read before each index resets the address/
; data flip-flop, which is shared and has no other way to be put in a known
; state.
; =============================================================================
vs_pal:
    push ax
    push bx
    push cx
    push dx
    mov cx, 0
.ac:
    mov dx, 0x3DA               ; reset the AC's address/data flip-flop
    in al, dx
    mov dx, 0x3C0
    mov al, cl                  ; index, bit 5 CLEAR: this is a read
    out dx, al
    mov dx, 0x3C1
    in al, dx
    mov bx, cx
    mov [vs_pac + bx], al
    inc cx
    cmp cx, 16
    jb .ac
    mov dx, 0x3DA               ; video back on: bit 5 reconnects the palette
    in al, dx                   ; to the screen, and without this the display
    mov dx, 0x3C0               ; stays blank
    mov al, 0x20
    out dx, al

    mov cx, 0
.dac:
    mov bx, cx
    mov al, [vs_pac + bx]
    and al, 0x3F
    mov dx, 0x3C7               ; DAC read index
    out dx, al
    jmp short $+2               ; the classic I/O settle, twice - the DAC is
    jmp short $+2               ; the slowest thing on these ports
    mov dx, 0x3C9
    mov bx, cx
    shl bx, 1
    add bx, cx                  ; BX = colour * 3
    in al, dx
    mov [vs_pdac + bx], al
    in al, dx
    mov [vs_pdac + bx + 1], al
    in al, dx
    mov [vs_pdac + bx + 2], al
    inc cx
    cmp cx, 16
    jb .dac
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; vs_palprint - four lines of four, "colour AC=RRGGBB"
vs_palprint:
    push ax
    push bx
    push cx
    push si
    mov si, vs_s_pal
    call vs_puts
    mov cx, 0
.one:
    mov al, ' '
    call vs_putc
    mov al, cl
    call vs_hexnib
    mov al, ' '
    call vs_putc
    mov bx, cx
    mov al, [vs_pac + bx]
    call vs_hex2
    mov al, '='
    call vs_putc
    mov bx, cx
    shl bx, 1
    add bx, cx
    mov al, [vs_pdac + bx]
    call vs_hex2
    mov al, [vs_pdac + bx + 1]
    call vs_hex2
    mov al, [vs_pdac + bx + 2]
    call vs_hex2
    inc cx
    mov ax, cx
    and ax, 3
    jnz .one
    call vs_nl
    cmp cx, 16
    jb .one
    pop si
    pop cx
    pop bx
    pop ax
    ret

vs_hexnib:
    push ax
    and al, 0x0F
    add al, 0x90
    daa
    adc al, 0x40
    daa
    call vs_putc
    pop ax
    ret

; =============================================================================
; vs_report - the verdict, in text mode
; =============================================================================
vs_report:
    mov si, vs_s_rhdr
    call vs_puts
    cmp byte [vs_banked], 0     ; name the ARM. A control run that reported
    je .ctl                     ; "4F02h set 0104h: OK" would be the one
    mov si, vs_s_rset           ; sentence in here able to answer the whole
    jmp short .arm              ; question wrongly
.ctl:
    mov si, vs_s_rctl
.arm:
    call vs_puts

    mov si, vs_s_rraw           ; the raw write first: everything below is
    call vs_puts                ; meaningless if the memory is not there
    mov al, VS_RAWB
    call vs_hex2
    mov si, vs_s_rread
    call vs_puts
    mov byte [vs_i], 0
.rawp:
    mov bx, 0
    mov bl, [vs_i]
    mov al, [vs_rawr + bx]
    call vs_hex2
    mov al, ' '
    call vs_putc
    inc byte [vs_i]
    cmp byte [vs_i], 4
    jb .rawp
    call vs_nl

    mov si, vs_s_rpass
    call vs_puts
    xor ah, ah
    mov al, [vs_pass]
    call vs_dec
    mov si, vs_s_rof
    call vs_puts
    mov al, [vs_pass]
    add al, [vs_fail]
    xor ah, ah
    call vs_dec
    call vs_nl

    cmp byte [vs_fail], 0
    jne .bad
    mov si, vs_s_rok
    call vs_puts
    cmp byte [vs_banked], 0
    je .tail
    mov si, vs_s_rbank          ; only the VBE arm banks, so only it may claim
    call vs_puts                ; the bank switch was exercised
    jmp short .tail
.bad:
    mov si, vs_s_rbad           ; name every one that missed: a count alone
    call vs_puts                ; cannot say WHICH path is broken
    mov si, vs_probes
    mov di, vs_results
.one:
    mov cx, [si]
    cmp cx, 0xFFFF
    je .tail
    mov al, [di]
    cmp al, [si + 4]
    je .next
    push si
    push di
    mov ax, cx
    call vs_dec
    mov al, ','
    call vs_putc
    mov ax, [si + 2]
    call vs_dec
    mov si, vs_s_rwant
    call vs_puts
    pop di
    pop si
    push si
    push di
    xor ah, ah
    mov al, [si + 4]
    call vs_dec
    mov si, vs_s_rgot
    call vs_puts
    pop di
    pop si
    xor ah, ah
    mov al, [di]
    call vs_dec
    call vs_nl
.next:
    add si, 5
    inc di
    jmp short .one
.tail:
    call vs_palprint
    mov si, vs_s_rtail
    call vs_puts
    ret

; =============================================================================
; the smallest printers that will do (tests/bootdiag/bdboot.asm's, plus a
; decimal one - a stride and a row count are not hex questions)
; =============================================================================
vs_puts:
    lodsb
    test al, al
    jz vs_putc.out
    call vs_putc
    jmp short vs_puts

vs_putc:
    push ax
    push bx
    mov bx, [vs_logn]           ; TEE EVERY CHARACTER. The screen is the only
    cmp bx, VS_LOG              ; output this had, and a screen needs a camera
    jae .scr                    ; to leave the machine - which is a photograph
    mov [vs_log + bx], al       ; of an LCD at an angle, and SPEC.md 39.28.2.4
    inc word [vs_logn]          ; records what those are worth. The transcript
.scr:                           ; goes to a sector instead and comes back as
    mov ah, 0x0E                ; text, on 86Box, on MartyPC and off the
    mov bx, 0x0007              ; Satellite alike
    int 0x10
    pop bx
    pop ax
.out:
    ret

vs_nl:
    push ax
    mov al, 13
    call vs_putc
    mov al, 10
    call vs_putc
    pop ax
    ret

; vs_yesno - SI = a label, ZF as a TEST left it: prints "label yes/no"
vs_yesno:
    pushf
    call vs_puts
    popf
    jz .no
    mov si, vs_s_yes
    jmp short .say
.no:
    mov si, vs_s_no
.say:
    call vs_puts
    ret

vs_hex4:
    push ax
    mov al, ah
    call vs_hex2
    pop ax
vs_hex2:
    push ax
    push cx
    push ax
    mov cl, 4
    shr al, cl
    call .nib
    pop ax
    call .nib
    pop cx
    pop ax
    ret
.nib:
    and al, 0x0F
    add al, 0x90                ; the classic six bytes: 0..15 -> '0'..'F'
    daa
    adc al, 0x40
    daa
    jmp short vs_putc

; vs_dec - AX unsigned, no padding
vs_dec:
    push ax
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.div:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .div
.emit:
    pop ax
    add al, '0'
    call vs_putc
    loop .emit
    pop dx
    pop cx
    pop bx
    pop ax
    ret

vs_getkey:
    xor ah, ah
    int 0x16
    ret

; -----------------------------------------------------------------------------
; vs_save - put the transcript on the disk at LBA VS_LOGSEC
; out:      CF = 1 if int 13h refused (write-protected, or no disk)
;
; A RAW SECTOR AND NOT A FILE, because this disk has no filesystem to speak of:
; it is a boot sector and a payload laid down by os88disk, and the whole of
; what reads it back is four lines of Python on the host. A FAT writer here
; would be a hundred bytes to make the answer openable by something nothing is
; going to open it with.
;
; The log is padded to a whole number of sectors with spaces rather than zeros,
; so a host that prints it gets a transcript and not a wall of NULs.
; -----------------------------------------------------------------------------
vs_save:
    push ax
    push bx
    push cx
    push dx
    push es

    mov bx, [vs_logn]           ; pad to a sector boundary
    mov al, ' '
.pad:
    test bx, 511
    jz .padded
    cmp bx, VS_LOG
    jae .padded
    mov [vs_log + bx], al
    inc bx
    jmp short .pad
.padded:
    mov ax, bx
    mov cl, 9
    shr ax, cl                  ; AX = sectors to write
    or ax, ax
    jnz .have
    inc ax
.have:
    mov [vs_logsc], ax

    mov ax, VS_LOGSEC           ; LBA -> CHS, the bdboot idiom
    xor dx, dx
    mov bx, VS_SPT
    div bx
    inc dx
    mov cl, dl                  ; CL = sector, 1-based
    xor dx, dx
    mov bx, VS_HEADS
    div bx
    mov ch, al                  ; CH = cylinder
    mov dh, dl                  ; DH = head
    mov dl, 0                   ; drive A: - this image boots from nowhere else
    push cs
    pop es
    mov bx, vs_log
    mov ax, [vs_logsc]
    mov ah, 0x03                ; AH = 03h write, AL = the sector count
    int 0x13
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; the probe table - x, y, expected colour, five bytes each. 0FFFFh ends it.
;
; Between them they cover every path the pattern used: all four planes,
; Set/Reset, the Bit Mask at both ends of a byte, the XOR ALU, and - the ones
; that matter most - the rows either side of the bank boundary plus the very
; last address in the framebuffer.
; =============================================================================
vs_probes:
    times 15 * 5 db 0           ; built by vs_geom, never written here: the
                                ; coordinates depend on a geometry that is not
    dw 0xFFFF                   ; known until the mode has been set

; =============================================================================
; strings
; =============================================================================
vs_s_banner:
    db 13, 10, 'os8088 VBESET - can mode 0104h be SET, and does the', 13, 10
    db 'renderer work once it is? (SPEC.md 39.28.2)', 13, 10, 13, 10, 0
vs_s_ver:       db 'VBE version ', 0
vs_s_mem:       db '   memory ', 0
vs_s_memu:      db ' x 64KB', 13, 10, 0
vs_s_geo:       db 'mode 0104h: ', 0
vs_s_bpp:       db ' bpp ', 0
vs_s_planes:    db ' planes ', 0
vs_s_model:     db ' model ', 0
vs_s_attr:      db 'attr ', 0
vs_s_a_sup:     db '  supported by the card  ', 0
vs_s_a_vga:     db '  VGA compatible         ', 0
vs_s_a_win:     db '  windowed memory        ', 0
vs_s_yes:       db 'yes', 13, 10, 0
vs_s_no:        db 'NO', 13, 10, 0
vs_s_stride:    db 'stride ', 0
vs_s_wseg:      db '  window seg ', 0
vs_s_gran:      db '  gran ', 0
vs_s_wsize:     db 'KB  winsize ', 0
vs_s_split:     db 'a granule holds ', 0
vs_s_rows:      db ' rows', 0
vs_s_exact:     db ' EXACTLY - the boundary falls between rows', 13, 10, 0
vs_s_strad:     db ', remainder ', 0
vs_s_strad2:    db ' - ROWS STRADDLE the boundary', 13, 10, 0
vs_s_ready:
    db 13, 10, '1  set VBE 0104h - the question', 13, 10
    db '2  set plain VGA 12h - THE CONTROL, same code, known-good mode', 13, 10
    db 'Esc leave the mode alone', 13, 10, 13, 10
    db 'In graphics, press any key to come back.', 13, 10, 0
vs_s_setfail:   db 13, 10, 'AX=4F02h REFUSED the mode: AX=', 0
vs_s_setfail2:
    db 13, 10, 'The BIOS listed 0104h and will not set it. That IS the', 13, 10
    db 'answer: this card cannot be driven at 1024x768 planar.', 13, 10, 0
vs_s_novbe:     db 'No VBE here: AX=4F00h returned no VESA signature.', 13, 10, 0
vs_s_nomode:    db 'AX=4F01h gave mode 0104h no resolution: it is absent.', 13, 10, 0
vs_s_unsup:
    db 'attr bit 0 is CLEAR: the BIOS lists 0104h and the card does', 13, 10
    db 'not support it. Nothing below would mean anything.', 13, 10, 0
vs_s_notplanar: db 'MemoryModel is not 3: this 0104h is not planar.', 13, 10, 0
vs_s_nowin:     db 'WinGranularity is 0: no windowed memory to bank through.', 13, 10, 0
vs_s_nostride:  db 'BytesPerScanLine is unusable: nothing can be addressed.', 13, 10, 0
vs_s_badgran:   db 'WinGranularity is not a power of two up to 64KB.', 13, 10, 0
vs_s_rhdr:
    db 13, 10, 'os8088 VBESET - the verdict', 13, 10
    db '===========================', 13, 10, 13, 10, 0
vs_s_rset:      db 'AX=4F02h set VBE mode 0104h: OK', 13, 10, 0
vs_s_rctl:
    db 'CONTROL RUN: int 10h set plain VGA 12h, 640x480.', 13, 10
    db 'This says nothing about 0104h - it says whether the CODE works.', 13, 10, 0
vs_s_rbank:
    db 'The bank switch is in that count: three of those probes are the', 13, 10
    db 'rows either side of a 64KB granule boundary.', 13, 10, 0
vs_s_rraw:      db 'raw plane write at (8,400): wrote ', 0
vs_s_rread:     db ', planes read back ', 0
vs_s_rpass:     db 'readback through GC4: ', 0
vs_s_rof:       db ' of ', 0
vs_s_rok:
    db 13, 10, 'Every probe read back what was written - Set/Reset, the', 13, 10
    db 'Bit Mask and the XOR ALU all work here.', 13, 10
    db 'The picture before this one is what the DISPLAY made of it.', 13, 10, 0
vs_s_rbad:      db 13, 10, 'MISSED:', 13, 10, 0
vs_s_rwant:     db '  want ', 0
vs_s_rgot:      db '  got ', 0
vs_s_pal:
    db 13, 10, 'palette - colour, AC register = DAC RGB (6-bit):', 13, 10
    db 'mode 12h has 6 -> AC 14 = 2A1500 (brown). AC 06 = 2A2A00, dark yellow.', 13, 10, 0
vs_s_rtail:
    db 13, 10, 'S writes this to the disk, R runs it again,', 13, 10
    db 'any other key halts.', 13, 10, 0
vs_s_saved:     db 'written to sector 100.', 13, 10, 0
vs_s_bye:       db 13, 10, 'Left the mode alone. Power off.', 13, 10, 0

; =============================================================================
; variables - this is -f bin, so everything needs a real initialiser
; =============================================================================
vs_setax    dw 0
vs_colour   db 0
vs_xorm     db 0
vs_i        db 0
vs_plane    db 0
vs_bit      db 0
vs_got      db 0
vs_pass     db 0
vs_fail     db 0
vs_bytex    dw 0
vs_y2       dw 0
vs_b1       dw 0
vs_b2       dw 0
vs_m1       db 0
vs_m2       db 0
vs_mcur     db 0
vs_curwin   dw 0xFFFF
vs_winshift db 16
vs_winmask  dw 0xFFFF
vs_rowsplit dw 0
vs_rowrem   dw 0
vs_pac      times 16 db 0
vs_pdac     times 48 db 0
vs_px       dw 0
vs_banked   db 1
vs_barw     dw 0
vs_yb2      dw 0
vs_ycomb    dw 0
vs_pp       dw 0
vs_rawr     times 4 db 0
vs_logn     dw 0                ; characters logged so far
vs_logsc    dw 0
vs_results  times 24 db 0
vs_info     times VS_INFO db 0
vs_minfo    times VS_MINFO db 0

    align 512                   ; the transcript, written as whole sectors
vs_log      times VS_LOG db 0

vs_end:
