%ifdef CH_OVERLAY
; =============================================================================
; os88chartovl.inc - the resident half of the shared chart module (82.16).
;
; apps/os88chart.inc is ~4,800 bytes of rasterizer that BOTH sheet.asm and
; chart.asm carried a private copy of. It is a module now - one CHART.OVL
; loaded beside the package and far-called - and this file is what each
; package keeps resident to reach it: the loader, the shims the module calls
; back through, and the verb wrapper.
;
; ONLY SHEET OVERLAYS IT, and CHART.OVL IS SHEET'S FILE ALONE. chart.o88
; defines neither CH_ symbol, never includes this file, and carries the
; rasterizer resident; the Makefile cuts CHART.OVL from build/sheet.bin and
; from nothing else.
;
; An earlier version of this comment claimed "ONE FILE SERVES BOTH PACKAGES"
; and that "the Makefile asserts the two independently-assembled .OVLs are
; identical". BOTH HALVES ARE FALSE, and 82.16.1 - written later, and right -
; says why the first one CANNOT be true: the module reaches the ch_* block at
; absolute offsets past the package's own image end, and the two packages'
; images are different lengths, so one binary could never address both. There
; is no identity rule in the Makefile and no second assembly for it to compare
; against.
;
; The cost of leaving that standing is not a wrong result, it is a wrong
; BOUNDARY: a jointly-owned tail is one nothing else may be put in, so the
; comment quietly retires Sheet's only room to grow. It is Sheet's tail, and
; a second tenant belongs in it (82.16.6).
;
; Include it BEFORE os88chart.inc, and after os88fp.inc (the shims name it).
; The caller must have called OSAPI_FILE_HERE at entry and banked the answer
; in ch_ovdir/ch_ovdrv - that is where the .OVL lives, and the user is free to
; navigate away a moment later.
; =============================================================================
CH_OVKB      equ 8                  ; the claim CHART.OVL is read into, KB
CHM_DRAW     equ 0                  ; the verbs - the module's dispatch indices
CHM_SCALE    equ 1
CHM_BMPWRITE equ 2
CHM_MAX      equ 2

; -----------------------------------------------------------------------------
; The shims apps/os88chart.inc's vectors point at (82.16).
;
; Each is a near call to the real routine and then the FAR return the module's
; `call far [ch_v_*]` is waiting for. Registers and flags pass through both
; ways untouched, so a shimmed routine keeps its own contract - which is the
; whole reason the shim exists rather than the vector naming the routine: every
; routine here is a near proc ending in `ret`, and far-calling one pops the
; offset, leaves the segment on the stack and returns into nothing.
;
; ch_s_aiszero is the fused one. The module used to load `bx, fp_am0` itself,
; which is an address in THIS package's bss and exactly what a module shared
; with another package cannot know. The shim supplies it.
; -----------------------------------------------------------------------------
ch_s_unpacka:
    call fp_unpack_a
    retf
ch_s_unpackb:
    call fp_unpack_b
    retf
ch_s_a2i:
    call fp_a2i
    retf
ch_s_cmpab:
    call fp_cmpab
    retf
ch_s_round:
    call fp_round
    retf
ch_s_scale10:
    call fp_scale10
    retf
ch_s_aiszero:
    mov bx, fp_am0
    call fp_iszero
    retf

; ch_ovbind - fill the vector table: this package's shim offsets, and this
; package's segment. The offsets are assembled in; only the segment is a
; runtime fact, and it is the same one for all of them.
ch_ovbind:
    push ax
    push bx
    push si
    push di
    mov si, ch_ovshims
    mov di, ch_v_first
    mov ax, cs
    mov bx, 7
.l:
    push ax
    mov ax, [si]
    mov [di], ax                      ; the shim's offset...
    pop ax
    mov [di+2], ax                    ; ...and our own segment
    add si, 2
    add di, 4
    dec bx
    jnz .l
    pop di
    pop si
    pop bx
    pop ax
    ret

ch_ovshims:
    dw ch_s_unpacka, ch_s_unpackb, ch_s_a2i, ch_s_cmpab
    dw ch_s_round, ch_s_scale10, ch_s_aiszero

; -----------------------------------------------------------------------------
; ch_ovneed - make sure CHART.OVL is loaded.
; out: CF=0 with [ch_ovseg] holding it; CF=1 and [ch_ovfail] set. Preserves
; every register, because it sits under calls whose arguments are in them.
;
; REFUSAL IS AN ORDINARY PATH (SPEC.md 47): no heap, or a disk without the
; file, and the chart simply does not draw. The caller sees CF=1 and says so
; in its own voice - this include has no toast of its own and should not grow
; one, because the two packages report differently.
; -----------------------------------------------------------------------------
ch_ovneed:
    cmp word [ch_ovseg], 0
    jne .ok
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    call OSAPI_FILE_HERE            ; where the USER is, to be put back
    mov [ch_ovwas], dx
    mov [ch_ovwdr], bl
    mov dx, [ch_ovdir]              ; ...and off to where we were launched
    mov bl, [ch_ovdrv]
    call OSAPI_FILE_GOTO
    mov ax, CH_OVKB
    call OSAPI_MEM_CLAIM
    jc .nomem
    mov [ch_ovseg], dx
    mov word [ch_ovfar], 0          ; the dispatcher is at the claim's 0
    mov [ch_ovfar+2], dx
    mov es, dx
    xor bx, bx
    mov cx, CH_OVKB * 1024
    xor dx, dx
    mov si, ch_ovname
    call OSAPI_FILE_READ
    jc .noread
    call ch_ovback
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
.ok:
    clc
    ret
.noread:
    mov dx, [ch_ovseg]              ; the claim goes back: a half-loaded
    call OSAPI_MEM_FREE             ; module is worse than none
    mov word [ch_ovseg], 0
.nomem:
    call ch_ovback
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    stc
    ret

; ch_ovback - put the volume back where the user left it. Preserves all.
ch_ovback:
    push bx
    push dx
    mov dx, [ch_ovwas]
    mov bl, [ch_ovwdr]
    call OSAPI_FILE_GOTO
    pop dx
    pop bx
    ret

%endif

%ifdef CH_OVERLAY
; -----------------------------------------------------------------------------
; ch_ovcall - far-call the module.
; in:  BP = the verb (CHM_*), everything else as that verb documents
; out: as the verb; CF=1 if the module could not be loaded at all.
;
; BP carries the verb because none of the four entry points takes it as an
; argument - ch_scale wants DX/SI/DI/CX, ch_bmp_write ES/BX/SI - so it is the
; one register free to say WHICH without disturbing what they were handed.
; -----------------------------------------------------------------------------
ch_ovcall:
    call ch_ovneed
    jc .no
    call far [ch_ovfar]             ; the dispatcher is at the claim's offset
.no:                                ; 0, so the far pointer is (0, the claim)
    ret

ch_ovname:  db 'CHART.OVL', 0
%endif
