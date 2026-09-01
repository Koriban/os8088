; =============================================================================
; os8088 - apps/imgtest/imgtest.asm
;
; The test app for apps/os88img.inc, and the reason that file can be trusted
; before WORD's Insert > Picture depends on it.
;
; A decoder is the classic thing that passes its own test: write the encoder
; and the decoder from one understanding of a format and they agree with each
; other about something neither has got right. So apps/imgtest/imgcases.inc is
; GENERATED ON THE HOST by tools/os88imgcase.py, which computes every expected
; answer from the FORMAT DOCUMENTS - ZSoft's Technical Reference Manual
; revision 5, the BITMAPINFOHEADER layout, apps/frotz/zpic.inc's own header -
; and never by running this and recording what it said. Same argument
; apps/fptest makes for the soft-float core (84).
;
; Each case reads a REAL FILE off the disk, so the path under test is the one
; a package actually uses: claim, OSAPI_FILE_READ, img_load. A case passes
; only if the width, the height, the stride, the error code AND a rotate-xor
; checksum of every decoded byte all match.
;
; One case is not generated at all. MAIN.PCX is 1152x90 in four planes, off
; the Dr. Dobb's File Formats disc, written by PC Paintbrush by somebody who
; had never heard of this project - the one file here that cannot share a
; misreading with the decoder.
; =============================================================================

%include "os88api.inc"

    OS88_HEADER 'IMGTEST', it_entry

IT_W        equ 300
IT_H        equ 240
IT_ROWH     equ 9

IT_SRCKB    equ 64                  ; the biggest file the corpus holds
IT_DSTKB    equ 64                  ; ...and the biggest picture in it

; -----------------------------------------------------------------------------
it_entry:
    push si
    mov ax, IT_SRCKB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [it_srcseg], dx
    mov ax, IT_DSTKB
    call OSAPI_MEM_CLAIM
    jc .fail
    mov [it_dstseg], dx
    call it_runall
    mov si, it_tpl
    call OSAPI_WM_CREATE
    pop si
    clc
    ret
.fail:
    pop si
    stc
    ret

it_tpl:
    dw 30, 30, IT_W, IT_H
    dw it_title, it_paint, 0, 0
it_title:   db 'os88img self-test', 0
it_s_ok:    db 'ok  ', 0
it_s_bad:   db 'FAIL', 0
it_s_all:   db 'ALL PASS', 0
it_s_some:  db 'FAILURES', 0

%include "imgcases.inc"

; -----------------------------------------------------------------------------
; it_runall - every case, leaving a pass/fail byte per case in it_res.
; -----------------------------------------------------------------------------
it_runall:
    push ax
    push bx
    push cx
    push si
    push di
    mov word [it_npass], 0
    xor cx, cx
.each:
    mov [it_case], cx
    call it_one
    mov bx, [it_case]
    mov di, it_res
    add di, bx
    mov [di], al
    cmp al, 0
    je .next
    inc word [it_npass]
.next:
    mov cx, [it_case]
    inc cx
    cmp cx, IMGC_N
    jb .each
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; it_one - run case [it_case]. out: AL = 1 pass, 0 fail.
; -----------------------------------------------------------------------------
it_one:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov ax, [it_case]
    mov bx, IMGC_REC
    mul bx
    add ax, imgc_tab
    mov di, ax                          ; DI = this case's record
    mov si, [di]                        ; its file name
    mov es, [it_srcseg]
    xor bx, bx
    mov cx, 0xFFFF                      ; DX:CX is the capacity, and 64K
    xor dx, dx                          ; does not fit the word CX is
    call OSAPI_FILE_READ                ; out DX:AX = the size, or CF=1
    jc .fail
    or dx, dx
    jnz .fail                           ; a file past 64KB is not in the corpus
    mov si, it_blk
    mov [si+IMG_SRCLEN], ax
    mov ax, [it_srcseg]
    mov [si+IMG_SRCSEG], ax
    mov ax, [it_dstseg]
    mov [si+IMG_DSTSEG], ax
    mov word [si+IMG_DSTMAX], 0         ; the whole 64KB
    mov word [si+IMG_ROWBUF], it_row
    mov ax, [di+2]                      ; the picture number asked for
    mov [si+IMG_PICNO], ax
    call img_load
    mov ax, [di+4]                      ; the error code expected
    cmp ax, [si+IMG_ERR]
    jne .fail
    or ax, ax
    jnz .pass                           ; a refusal case ends here: there is no
                                        ; picture to compare and IMG_W is 0
    mov ax, [di+6]
    cmp ax, [si+IMG_W]
    jne .fail
    mov ax, [di+8]
    cmp ax, [si+IMG_H]
    jne .fail
    mov ax, [di+10]
    cmp ax, [si+IMG_STRIDE]
    jne .fail
    call it_cksum                       ; -> AX
    cmp ax, [di+12]
    jne .fail
.pass:
    mov al, 1
    jmp .out
.fail:
    xor al, al
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; it_cksum - the rotate-xor of stride*height decoded bytes, in AX.
; A plain sum would not notice two rows swapped; the rotate makes position
; part of the answer, which is the whole point of checking a decoder.
; -----------------------------------------------------------------------------
it_cksum:
    push bx
    push cx
    push dx
    push si
    push es
    mov si, it_blk
    mov ax, [si+IMG_STRIDE]
    mul word [si+IMG_H]                 ; DX:AX - the geometry check inside
    mov cx, ax                          ; img_load already proved it fits
    mov es, [si+IMG_DSTSEG]
    xor si, si
    xor bx, bx                          ; BX = the running value
.b:
    mov ax, bx
    shl bx, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    or bx, ax                           ; ...a 16-bit rotate left by one
    mov al, [es:si]
    xor ah, ah
    xor bx, ax
    inc si
    dec cx
    jnz .b
    mov ax, bx
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
it_paint:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, si
    call OSAPI_WM_CONTENT               ; AX/DX = the content origin
    mov [it_ox], ax
    mov [it_oy], dx
    xor cx, cx
.row:
    mov [it_case], cx
    mov ax, cx
    mov bx, IT_ROWH
    mul bx
    add ax, [it_oy]
    add ax, 4
    mov [it_ty], ax
    mov di, it_res
    add di, cx
    cmp byte [di], 0
    je .bad
    mov si, it_s_ok
    jmp .name
.bad:
    mov si, it_s_bad
.name:
    mov ax, [it_ox]
    add ax, 4
    mov bx, [it_ty]
    call it_say
    mov cx, [it_case]
    mov ax, cx
    mov bx, IMGC_REC
    mul bx
    add ax, imgc_tab
    mov di, ax
    mov si, [di]
    mov ax, [it_ox]
    add ax, 44
    mov bx, [it_ty]
    call it_say
    mov cx, [it_case]
    inc cx
    cmp cx, IMGC_N
    jb .row
    mov si, it_s_some
    mov ax, [it_npass]
    cmp ax, IMGC_N
    jne .verdict
    mov si, it_s_all
.verdict:
    mov ax, [it_ox]
    add ax, 4
    mov bx, IMGC_N
    push dx
    mov dx, IT_ROWH
    push ax
    mov ax, bx
    mul dx
    mov bx, ax
    pop ax
    pop dx
    add bx, [it_oy]
    add bx, 12
    call it_say
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; it_say - SI = a NUL string, drawn at AX,BX. OSAPI_FONT_RUN takes CX=x,
; DX=y, AL=ink and AH=background, and draws both in ONE pass (6.1) - the
; erase-then-letter pair is the double-draw flash PERFORMANCE.md names.
it_say:
    push ax
    push bx
    push cx
    push dx
    push si
    mov cx, ax
    mov dx, bx
    mov ax, CBLACK | (CWHITE << 8)
    call OSAPI_FONT_RUN
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

%include "os88img.inc"

    OS88_BSS IT_BSS
    OS88_IMAGE_END

it_srcseg  equ os88_image_end + 0
it_dstseg  equ it_srcseg + 2
it_case    equ it_dstseg + 2
it_npass   equ it_case + 2
it_ox      equ it_npass + 2
it_oy      equ it_ox + 2
it_ty      equ it_oy + 2
it_res     equ it_ty + 2               ; IMGC_N bytes
it_blk     equ it_res + IMGC_N         ; OS88IMG_SZ
it_row     equ it_blk + OS88IMG_SZ     ; OS88IMG_ROW
it_bss_end equ it_row + OS88IMG_ROW
IT_BSS     equ it_bss_end - os88_image_end
