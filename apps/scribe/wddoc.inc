; =============================================================================
; os8088 - apps/word/wddoc.inc
;
; THE REAL WORD .DOC FORMAT (SPEC.md 68.4) - the Word for Windows 1.x/2.x
; binary file, written and read from the Opus structures rather than a
; private container with Opus's magic on it:
;
;   wordtech/file.h    struct FIB, cbFileHeader, cbSector, nFibCurrent,
;                      wMagic, struct BTE
;   wordtech/fkp.h     struct FKP - the 512-byte formatting page
;   wordtech/doc.h     struct SED, struct PCD, struct ESTCP, clxtPrc/clxtPlcpcd
;   wordtech/prm.h     the sprm codes; wordtech/prcsubs.c's dnsprm the widths
;   wordtech/props.h   jc*, kul*, stcNormal
;   wordwin.h          struct DOP
;
; Two directions, deliberately NOT symmetric. The writer emits a SIMPLE file
; (fComplex clear, one contiguous text run), which is what Word's own full
; save writes; the reader accepts simple AND complex, walking the piece table
; when it finds one, because that is the half that lets this app open a file
; somebody else fast-saved (SPEC.md 68.4.1).
;
; Every FC in a file this app can touch fits in 16 bits - the whole file has
; to fit the staging claim to be read at all, and the writer refuses past
; WD_DOCCAP - so the high word of every FC is CHECKED to be zero on the way
; in and written as zero on the way out, and the arithmetic below is 16-bit.
; That is a bound, not an assumption: wd_dvfc is where it is enforced.
; =============================================================================

; --- the FIB's fields, by byte offset (wordtech/file.h) ----------------------
WDF_IDENT    equ 0              ; wIdent  = WD_DOCMAGIC
WDF_NFIB     equ 2              ; nFib    = WD_NFIBCUR
WDF_FLAGS    equ 10             ; fDot:1 fGlsy:1 fComplex:1 fHasPic:1 ...
WDF_NFIBBACK equ 12             ; nFibBack = WD_NFIBBACK
WDF_FCMIN    equ 24             ; FC: where the text starts
WDF_FCMAC    equ 28             ; FC: one past the last text byte
WDF_CBMAC    equ 32             ; FC: one past the last byte written
WDF_CCPTEXT  equ 52             ; CP: the main document's length
WDF_FCSTSHO  equ 88             ; FC  } the ORIGINAL stsh allocation - the
WDF_CBSTSHO  equ 92             ; uns } same pair as fcStshf on a full save
WDF_FCSTSH   equ 94             ; FC  } style sheet
WDF_CBSTSH   equ 98             ; uns }
WDF_FCSED    equ 124            ; FC  } section table
WDF_CBSED    equ 128            ; uns }
WDF_FCBTECHP equ 160            ; FC  } the CHPX bin table
WDF_CBBTECHP equ 164            ; uns }
WDF_FCBTEPAP equ 166            ; FC  } the PAPX bin table
WDF_CBBTEPAP equ 170            ; uns }
WDF_FCDOP    equ 262            ; FC  } document properties
WDF_CBDOP    equ 266            ; uns }
WDF_FCCLX    equ 274            ; FC  } the complex part: the piece table
WDF_CBCLX    equ 278            ; uns }
WDF_PNCHP    equ 306            ; PN: the first CHPX FKP page
WDF_PNPAP    equ 308            ; PN: ...and the first PAPX one
WDF_CPNCHP   equ 310            ; PN: how many CHPX FKP pages
WDF_CPNPAP   equ 312            ; PN: ...and how many PAPX. cbFIB is 314, so
                                ; these two are its last words and the header
                                ; page is sized by the +127 rule below
                                ;
                                ; Every offset above is 94 + 6n for the nth
                                ; (FC, uns) pair, counting fcStshf as n = 0:
                                ; fcPlcfsed is n = 5, fcPlcfbteChpx n = 11,
                                ; fcPlcfbtePapx n = 12, fcDop n = 28 and
                                ; fcClx n = 30. 35 pairs end at 304, wSpare4
                                ; is there, and the four PNs follow

WD_NFIBCUR   equ 33             ; nFibCurrent     (file.h)
WD_NFIBBACK  equ 25             ; nFibBackCurrent
WD_NFIBMIN   equ 18             ; nFibMinDoc - 'identifies readable files'
WD_HDRPAGE   equ 384            ; cbFileHeader = ((cbFIB + 127) >> 7) << 7
WD_SECT      equ 512            ; cbSector
WD_FCOMPLEX  equ 0x0004         ; the FIB flag word's fComplex bit

; --- sprms (wordtech/prm.h), operand widths from dnsprm ----------------------
WDS_PSTC     equ 2              ; byte: stc
WDS_PJC      equ 5              ; byte: jc
WDS_PDXAR    equ 16             ; word: dxaRight
WDS_PDXAL    equ 17             ; word: dxaLeft
WDS_PDXAL1   equ 19             ; word: dxaLeft1, SIGNED
WDS_PDYALIN  equ 20             ; word: dyaLine
WDS_PDYABEF  equ 21             ; word: dyaBefore
WDS_CFBOLD   equ 60             ; byte
WDS_CFITAL   equ 61             ; byte
WDS_CFSCAP   equ 65             ; byte
WDS_CFVAN    equ 67             ; byte: fVanish - hidden
WDS_CKUL     equ 69             ; byte: kul
WD_KULSING   equ 1              ; kulSingle  (props.h)
WD_KULWORD   equ 2              ; kulWord
WD_KULDBL    equ 3              ; kulDouble

WD_TWIPCELL  equ 144            ; one cell = 1/10" = 144 twips (SPEC.md 68.3)
WD_CBPHE     equ 6              ; sizeof (struct PHE)  - word.h
WD_CBPCD     equ 8              ; sizeof (struct PCD)  - doc.h
WD_CBSED     equ 6              ; sizeof (struct SED)
WD_CBDOP     equ 66             ; sizeof (struct DOP)  - wordwin.h

WD_DOCCAP    equ 62             ; the save staging claim, KB (SPEC.md 68.4).
                                ; 30KB of text plus its 384-byte header is
                                ; 31,104, so this leaves ~30KB of FKP pages
                                ; and tables. Past it the save REFUSES; it
                                ; never truncates
WD_MAXBTE    equ 64             ; FKP pages of each kind. 64 x 512 = 32KB,
                                ; which is what WD_DOCCAP has room for once
                                ; the text is in - so the two ceilings agree
                                ; and neither can be hit without the other
WD_MAXPCD    equ 1024           ; pieces a complex file may have. Read in
                                ; place out of the staging image - no copy,
                                ; so this bounds the WALK and nothing else
; --- the picture record (SPEC.md 86.7) ---------------------------------------
; Derived from two documents Microsoft itself wrote and cross-checked against
; each other: TECHREF.DOC, which ships with Word 1.1a and holds exactly one
; metafile picture, and SNAP.DOC, a Paint bitmap pasted into Word and saved.
; They agree field for field and differ in `mm`, which is what makes `mm` the
; discriminator rather than a guess.
WD_PICF      equ 46             ; cbHeader, and the payload starts there
WD_MM_BMP    equ 99             ; mm: a bitmap payload. A metafile is 7
WD_PICTW     equ 15             ; twips a pixel, the 96dpi logical inch
WD_PICWHITE  equ 0xFC80         ; WHICH OF THE SIXTEEN GO TO 1 when a 4bpp
                                ; picture is reduced for a .DOC: bit N set
                                ; means colour N is light. Computed once, from
                                ; 0.299R + 0.587G + 0.114B over os8088's own
                                ; palette against a midpoint - so 7 (light
                                ; grey) and 10..15 are white, and 0..6, 8 and
                                ; 9 are black. A threshold and not a dither: a
                                ; dither is a decision about how a picture
                                ; should LOOK, and docs/IMGCONV-PLAN.md puts
                                ; those on the host. Black-and-white art -
                                ; which is what a .DOC picture came from in
                                ; the first place - round-trips EXACTLY,
                                ; because 0 and 15 sit either side of it
WD_GRPMAX    equ 24             ; the biggest grpprl either builder makes:
                                ; six paragraph sprms at 3 bytes is 18

; =============================================================================
; THE WRITER
; =============================================================================

; -----------------------------------------------------------------------------
; wd_docimg - assemble the whole file image into the staging claim
; in:  ES = the staging claim (WD_DOCCAP KB), DS = the package
; out: CF=0 and [wd_dend] = the image's byte count; CF=1 = it does not fit.
;      Clobbers AX BX CX DX SI DI; preserves DS and ES.
;
; Opus's own file order, from the table at the head of wordtech/savefast.c:
; FIB, text, the CHP FKPs, the PAP FKPs, STSH, plcfsed, the two bin tables,
; DOP. Each structure's fc/cb pair is patched into the FIB as it lands, so
; there is one pass and no fixup list.
; -----------------------------------------------------------------------------
wd_docimg:
    cld
    xor di, di                      ; --- the header page, zeroed whole ------
    mov cx, WD_HDRPAGE / 2
    xor ax, ax
    rep stosw
    mov word [es:WDF_IDENT], WD_DOCMAGIC
    mov word [es:WDF_NFIB], WD_NFIBCUR
    mov word [es:WDF_NFIBBACK], WD_NFIBBACK
    mov word [es:WDF_FCMIN], WD_HDRPAGE
    mov ax, [wd_len]                ; --- the text --------------------------
    inc ax                          ; ...plus the paragraph mark this port
    mov [wd_dvlen], ax              ; keeps implicit. A Word file's text ends
    mov [es:WDF_CCPTEXT], ax        ; with a ¶ and its N marks are N
    add ax, WD_HDRPAGE              ; paragraphs; this port holds N-1 marks
    mov [es:WDF_FCMAC], ax          ; and a TAIL paragraph with no mark
    mov cx, [wd_len]                ; (SPEC.md 68.3), so the two
    jcxz .notext                    ; representations differ by exactly this
    push ds                         ; one character - appended here, dropped
    PKG_LDS wd_dseg            ; by wd_dtrim on the way back in
    xor si, si
    rep movsb                       ; ES:DI is already at WD_HDRPAGE
    pop ds
.notext:
    mov al, 13
    stosb
    call wd_dpicw                     ; THE PICTURES, BEFORE THE FKPs: their
    jc .no                            ; offsets have to be known when the
                                      ; CHPX that names them is built, and
                                      ; wd_dchps runs below this (86.7)
    call wd_dalign                    ; the FKPs start on a page boundary
    mov ax, di                      ; --- the CHPX FKP pages ----------------
    call wd_dpnof
    mov [es:WDF_PNCHP], ax
    mov [wd_dpn0], ax
    call wd_dchps
    jc .no
    mov ax, [wd_dbn0]
    mov [es:WDF_CPNCHP], ax
    mov ax, di                      ; --- the PAPX FKP pages ----------------
    call wd_dpnof
    mov [es:WDF_PNPAP], ax
    mov [wd_dpn1], ax
    call wd_dpaps
    jc .no
    mov ax, [wd_dbn1]
    mov [es:WDF_CPNPAP], ax
    call wd_dstsh                   ; --- STSH, plcfsed, bin tables, DOP ----
    jc .no
    call wd_dsed
    jc .no
    call wd_dbte
    jc .no
    call wd_ddop
    jc .no
    mov [es:WDF_CBMAC], di
    mov [wd_dend], di
    clc
    ret
.no:
    stc
    ret

; =============================================================================
; wd_dpicw - write a PICF and its pixels for every picture in the document,
; recording each one's fc in wd_dpicfc.
; in/out: ES:DI, the staging cursor. CF=1 = it did not fit.
;
; RIGHT AFTER THE TEXT AND BEFORE THE FKP PAGES, because wd_dchps builds the
; CHPX that names a picture and needs its fc to already exist. It is also
; where Word puts them: TECHREF.DOC's two pictures sit between fcMac and the
; first FKP page.
;
; THE 4bpp PICTURE IS REDUCED TO 1bpp HERE, and that is the conversion the
; format asks for rather than a shortcut. Every embedded picture in a Word
; 1.1a file that has been measured is bmPlanes 1, bmBitsPixel 1 - both
; specimens, and there is no third to argue with - so a .DOC picture is
; monochrome and 86.5's RTF is where the colour lives. WD_PICWHITE decides
; which of the sixteen go to 1.
;
; A DDB row is padded to a WORD, not to a byte and not to a dword: SNAP.DOC's
; 44-pixel picture carries bmWidthBytes 6, and 44 bits is 5.5 bytes, so 6 is
; ceil to even and the arithmetic closes on lcb = 46 + 6*26 = 202, which is
; exactly the spacing to that file's next record.
; =============================================================================
wd_dpicw:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [wd_dpicn], 0          ; the picture being written
.pic:
    mov ax, [wd_dpicn]
    cmp ax, [wd_npic]
    jae .done
    mov bx, ax
    shl bx, 1
    mov [bx+wd_dpicfc], di          ; where this one's PICF begins
    mov cl, 3
    shl ax, cl                      ; * WD_PICREC
    add ax, wd_pictab
    mov bx, ax
    mov ax, [bx]                    ; bank the slot: every routine below
    mov [wd_dpicwd], ax             ; works from bss, so nothing has to keep
    mov ax, [bx+2]                  ; a register pointed at the table while
    mov [wd_dpicht], ax             ; DS is the picture's own segment
    mov ax, [bx+4]
    mov [wd_dpicst], ax
    mov ax, [bx+6]
    mov [wd_dpicsg], ax
    mov ax, [wd_dpicwd]             ; bmWidthBytes: ceil(w/8), rounded up to
    add ax, 7                       ; an EVEN number. A DDB row is
    mov cl, 3                       ; word-aligned - SNAP.DOC's 44-pixel
    shr ax, cl                      ; picture carries 6, and 44 bits is 5.5
    inc ax                          ; bytes, so 6 is ceil-to-even and the
    and ax, 0xFFFE                  ; arithmetic closes on lcb = 46 + 6*26
    mov [wd_dpicbw], ax             ; = 202, which is exactly the spacing to
    mul word [wd_dpicht]            ; that file's NEXT record
    or dx, dx
    jnz .no
    add ax, WD_PICF
    jc .no
    mov [wd_dpiclcb], ax
    add ax, di                      ; ...and all of it has to fit what is left
    jc .no
    cmp ax, WD_DOCCAP * 1024 - 2
    jae .no
    call wd_dpichdr                 ; the 46 bytes...
    call wd_dpicbits                ; ...and the reduced rows
    inc word [wd_dpicn]
    jmp short .pic
.no:
    stc
    jmp short .out
.done:
    clc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_dpichdr - the 46-byte PICF at ES:DI, from the banked wd_dpic* words.
; Advances DI by 46 and preserves everything else.
wd_dpichdr:
    push ax
    push dx
    mov ax, [wd_dpiclcb]            ; +0  lcb, a DWORD
    stosw
    xor ax, ax
    stosw
    mov ax, WD_PICF                 ; +4  cbHeader
    stosw
    mov ax, WD_MM_BMP               ; +6  mm = 99, the bitmap discriminator
    stosw
    mov ax, [wd_dpicwd]             ; +8  xExt  } SNAP.DOC carries the PIXEL
    stosw                           ;           } dimensions here, not the
    mov ax, [wd_dpicht]             ; +10 yExt  } display size
    stosw
    xor ax, ax
    stosw                           ; +12 hMF, a live handle: 0 on disk
    stosw                           ; +14 bmType
    mov ax, [wd_dpicwd]             ; +16 bmWidth, pixels
    stosw
    mov ax, [wd_dpicht]             ; +18 bmHeight
    stosw
    mov ax, [wd_dpicbw]             ; +20 bmWidthBytes
    stosw
    mov ax, 0x0101                  ; +22 bmPlanes = 1, bmBitsPixel = 1
    stosw
    xor ax, ax                      ; +24 bmBits, a pointer: 0 on disk
    stosw
    stosw
    mov ax, [wd_dpicwd]             ; +28 dxaGoal, twips
    mov dx, WD_PICTW
    mul dx
    stosw
    mov ax, [wd_dpicht]             ; +30 dyaGoal
    mov dx, WD_PICTW
    mul dx
    stosw
    mov ax, 1000                    ; +32 mx } tenths of a percent, so 1000 is
    stosw                           ;        } 100% - both specimens agree
    stosw                           ; +34 my } that this is the unit
    xor ax, ax
    stosw                           ; +36 } the four cropping words, zero in
    stosw                           ; +38 } both specimens
    stosw                           ; +40 }
    stosw                           ; +42 }
    mov ax, 4                       ; +44 the constant both specimens carry
    stosw
    pop dx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dpicbits - the picture's rows at ES:DI, reduced 4bpp -> 1bpp.
; Advances DI by bmWidthBytes * height; preserves everything else.
;
; Bit 7 is the LEFTMOST pixel, which is the same end os88img.inc reads a 1bpp
; row from (SPEC.md 85) - so this and the decoder that will read it back agree
; by construction rather than by testing.
;
; WD_PICWHITE is shifted right by the colour index and the low bit tested,
; which is a sixteen-way lookup written as one shift. DS is the picture's own
; segment for the fetch and the package for everything else, so it is swapped
; around each pixel: two segment loads a pixel is nothing beside the shift.
; -----------------------------------------------------------------------------
wd_dpicbits:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [wd_dpicy], 0
.row:
    mov ax, [wd_dpicy]
    cmp ax, [wd_dpicht]
    jae .done
    mul word [wd_dpicst]            ; DX:AX = the row's offset. wd_pictkeep
    mov si, ax                      ; already proved a picture fits a segment
    mov word [wd_dpicx], 0
    mov byte [wd_dpicac], 0
    mov byte [wd_dpicnb], 0
    mov word [wd_dpicbc], 0
.px:
    mov ax, [wd_dpicx]
    cmp ax, [wd_dpicwd]
    jae .rowend
    mov bx, ax
    shr bx, 1
    add bx, si
    push ds
    mov ds, [wd_dpicsg]
    mov dl, [bx]
    pop ds
    test byte [wd_dpicx], 1         ; an even x is the HIGH nibble
    jnz .low
    mov cl, 4
    shr dl, cl
    jmp short .have
.low:
    and dl, 0x0F
.have:
    mov ax, WD_PICWHITE
    mov cl, dl
    shr ax, cl                      ; bit N of the mask says colour N is light
    shl byte [wd_dpicac], 1
    test al, 1
    jz .black
    or byte [wd_dpicac], 1
.black:
    inc byte [wd_dpicnb]
    cmp byte [wd_dpicnb], 8
    jb .nextpx
    mov al, [wd_dpicac]
    stosb
    inc word [wd_dpicbc]
    mov byte [wd_dpicac], 0
    mov byte [wd_dpicnb], 0
.nextpx:
    inc word [wd_dpicx]
    jmp short .px
.rowend:
    cmp byte [wd_dpicnb], 0         ; a width that is not a multiple of eight
    je .pad                         ; leaves a part byte, shifted UP so its
.flush:                             ; pixels stay leftmost
    shl byte [wd_dpicac], 1
    inc byte [wd_dpicnb]
    cmp byte [wd_dpicnb], 8
    jb .flush
    mov al, [wd_dpicac]
    stosb
    inc word [wd_dpicbc]
.pad:
    mov cx, [wd_dpicbw]             ; ...and the row pads out to the stride
    sub cx, [wd_dpicbc]
    jbe .rowdone
    xor al, al
.padb:
    stosb
    loop .padb
.rowdone:
    inc word [wd_dpicy]
    jmp .row                        ; NOT short: a row is a long way back
.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_dalign - advance ES:DI to the next 512-byte boundary, zeroing what it
; crosses. Preserves everything but DI.
wd_dalign:
    push ax
    push cx
    mov ax, di
    and ax, WD_SECT - 1
    jz .out
    mov cx, WD_SECT
    sub cx, ax
    xor al, al
    cld
    rep stosb
.out:
    pop cx
    pop ax
    ret

; wd_dpnof - AX = a byte offset -> its page number. Preserves all others.
wd_dpnof:
    push cx
    mov cl, 9
    shr ax, cl
    pop cx
    ret

; wd_droom - CF=1 if AX more bytes past DI would not fit the staging claim.
; Preserves everything.
wd_droom:
    push ax
    add ax, di
    jc .no
    cmp ax, WD_DOCCAP * 1024
    ja .no
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret

; -----------------------------------------------------------------------------
; wd_dgrpc - build the CHPX grpprl for an attribute byte
; in:  AL = the WDAT_* byte
; out: CX = the grpprl's length, built at [wd_dgrp]; preserves all but CX.
;      An attribute of zero gives CX = 0, which the FKP writes as the nil
;      offset - Word's own 'this run is the default CHP'.
; -----------------------------------------------------------------------------
wd_dgrpc:
    push ax
    push bx
    push dx
    cmp byte [wd_dpicrun], 0        ; A PICTURE'S CHPX IS NOT A grpprl AND
    je .attrs                       ; NOT AN ATTRIBUTE SET (SPEC.md 86.7).
    xor ah, ah                      ; AL arrived as the picture INDEX; what
    mov bx, ax                      ; goes out is the twelve-byte structure
    shl bx, 1                       ; SNAP.DOC and TECHREF.DOC both carry,
    mov ax, [bx+wd_dpicfc]          ; with fcPic little-endian at bytes 8..10
    mov bx, wd_dgrp                 ; and the rest zero
    mov word [bx+0], 0x0200         ; the two constants both specimens share
    mov word [bx+2], 0
    mov word [bx+4], 0
    mov word [bx+6], 0
    mov [bx+8], ax                  ; fcPic, low word...
    mov byte [bx+10], 0             ; ...and its third byte. The staging claim
                                    ; is WD_DOCCAP KB, so an fc here never
                                    ; reaches the high byte - and the file's
                                    ; own 64KB ceiling is checked in wd_droom
    mov byte [bx+11], 3
    mov cx, 12
    jmp .out
.attrs:
    mov dl, al
    xor bx, bx
    test dl, WDAT_BOLD
    jz .nb
    mov byte [bx+wd_dgrp], WDS_CFBOLD
    mov byte [bx+wd_dgrp+1], 1
    add bx, 2
.nb:
    test dl, WDAT_ITAL
    jz .ni
    mov byte [bx+wd_dgrp], WDS_CFITAL
    mov byte [bx+wd_dgrp+1], 1
    add bx, 2
.ni:
    test dl, WDAT_SCAP
    jz .ns
    mov byte [bx+wd_dgrp], WDS_CFSCAP
    mov byte [bx+wd_dgrp+1], 1
    add bx, 2
.ns:
    test dl, WDAT_HID
    jz .nh
    mov byte [bx+wd_dgrp], WDS_CFVAN
    mov byte [bx+wd_dgrp+1], 1
    add bx, 2
.nh:
    xor al, al                      ; the three underlines are ONE sprm with
    test dl, WDAT_UL                ; three values (sprmCKul), never three
    jz .n1                          ; flags
    mov al, WD_KULSING
.n1:
    test dl, WDAT_WUL
    jz .n2
    mov al, WD_KULWORD
.n2:
    test dl, WDAT_DUL
    jz .n3
    mov al, WD_KULDBL
.n3:
    or al, al
    jz .nu
    mov byte [bx+wd_dgrp], WDS_CKUL
    mov [bx+wd_dgrp+1], al
    add bx, 2
.nu:
    mov cx, bx
.out:
    pop dx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dgrpp - build the PAPX grpprl for a PAP dictionary entry
; in:  AL = the dictionary index
; out: CX = the grpprl's length, built at [wd_dgrp]; preserves all but CX.
;      Only what DIFFERS from Normal is emitted - Normal is the style the
;      PAPX names, so an all-default paragraph writes an empty grpprl.
; -----------------------------------------------------------------------------
wd_dgrpp:
    push ax
    push bx
    push dx
    push si
    push ds
    xor ah, ah
    mov si, ax
    shl si, 1
    shl si, 1
    PKG_LDS wd_pseg
    mov dx, [si]                    ; DL = packed, DH = left
    mov si, [si+2]                  ; SL = first (signed), SH = right
    pop ds
    xor bx, bx
    mov al, dl
    and al, WDPA_ALIGN              ; jcLeft/Center/Right/Both are 0..3 in
    jz .nj                          ; exactly our order (props.h)
    mov byte [bx+wd_dgrp], WDS_PJC
    mov [bx+wd_dgrp+1], al
    add bx, 2
.nj:
    mov al, dh                      ; left indent
    or al, al
    jz .nl
    xor ah, ah
    call wd_dtwip
    mov byte [bx+wd_dgrp], WDS_PDXAL
    mov [bx+wd_dgrp+1], ax
    add bx, 3
.nl:
    mov ax, si
    or al, al                       ; first-line indent, SIGNED
    jz .nf
    cbw
    call wd_dtwip
    mov byte [bx+wd_dgrp], WDS_PDXAL1
    mov [bx+wd_dgrp+1], ax
    add bx, 3
.nf:
    mov ax, si
    mov al, ah                      ; right indent
    or al, al
    jz .nr
    xor ah, ah
    call wd_dtwip
    mov byte [bx+wd_dgrp], WDS_PDXAR
    mov [bx+wd_dgrp+1], ax
    add bx, 3
.nr:
    mov al, dl                      ; line spacing: 0/1/2 -> 240/360/480
    and al, WDPA_SPACE
    jz .nsp
    shr al, 1
    shr al, 1
    xor ah, ah
    push dx                         ; DX carries the packed byte and a 16-bit
    mov si, 120                     ; mul writes DX:AX - the space-before bit
    mul si                          ; below is read out of DL
    pop dx
    add ax, 240
    mov byte [bx+wd_dgrp], WDS_PDYALIN
    mov [bx+wd_dgrp+1], ax
    add bx, 3
.nsp:
    test dl, WDPA_SB                ; space before: half a line, 120 twips
    jz .nsb
    mov byte [bx+wd_dgrp], WDS_PDYABEF
    mov word [bx+wd_dgrp+1], 120
    add bx, 3
.nsb:
    mov cx, bx
    pop si
    pop dx
    pop bx
    pop ax
    ret

; wd_dtwip - AX = signed cells -> AX = twips. Preserves all others.
wd_dtwip:
    push dx
    push cx
    mov cx, WD_TWIPCELL
    imul cx
    pop cx
    pop dx
    ret

; =============================================================================
; THE FKP PAGES
;
; One 512-byte page holds, from its start: rgfc[crun+1] file offsets, then
; crun one-byte offsets to the properties, and from its END downwards the
; properties themselves. The offset byte is in WORDS (fetch.c: `bchpx <<=
; 1`), so every property record starts on an even offset, and 0 means 'this
; run has none' - the default CHP, or the default PAP. crun is byte 511.
;
; The page is built in [wd_dfkp], a 512-byte scratch in bss, and copied into
; the image whole. Building it in place would need two pointers into ES that
; grow towards each other, and the pointer arithmetic is the entire risk of
; this structure.
; =============================================================================

; wd_fkinit - start a page whose first fc is AX. Preserves all registers.
; rgfc[0] is written HERE and not by the first run, so a page that ends up
; with no runs at all still says which fc it starts at - which is what the
; bin table reads back out of it.
wd_fkinit:
    push ax
    push cx
    push di
    push es
    push ax
    push ds
    pop es
    mov di, wd_dfkp
    mov cx, WD_SECT / 2
    xor ax, ax
    cld
    rep stosw
    pop ax
    pop es
    pop di
    mov [wd_dfkp], ax
    mov word [wd_dfkp+2], 0
    mov word [wd_dfkn], 0           ; crun
    mov word [wd_dfkhi], WD_SECT-1  ; where the properties have got down to.
                                    ; 511 and not 512: byte 511 IS crun
                                    ; (fkp.h - cbFkp is 512 - sizeof(FC) - 1)
    pop cx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_fkadd - add a run to the page being built
; in:  AX = the run's FIRST fc (used only for run 0), DX = its LIM fc,
;      CX = the property length at [wd_dprop] (0 = the nil offset)
; out: CF=1 = the page is full and nothing was written; preserves all
; -----------------------------------------------------------------------------
wd_fkadd:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov bx, [wd_dfkn]
    mov si, bx                      ; the head AFTER this run: (crun+2) FCs
    shl si, 1                       ; and (crun+1) offset bytes
    shl si, 1
    add si, bx
    add si, 4 + 4 + 1               ; = 4*(crun+2) + (crun+1)
    mov di, [wd_dfkhi]              ; where this run's property would land
    jcxz .nop
    sub di, cx
    and di, 0xFFFE                  ; word-aligned: the offset byte is halved
.nop:
    cmp di, si
    jbe .full
    mov si, bx                      ; rgfc[crun+1] = the run's limit
    inc si
    shl si, 1
    shl si, 1
    add si, wd_dfkp
    mov [si], dx
    mov word [si+2], 0
    jcxz .nilrun
    mov [wd_dfkhi], di
    push di                         ; the property bytes go at the page's
    push cx                         ; high-water mark
    push es
    push ds
    pop es
    add di, wd_dfkp
    mov si, wd_dprop
    cld
    rep movsb
    pop es
    pop cx
    pop di
    mov si, di
    shr si, 1                       ; ...and the offset byte is that / 2
    jmp short .off
.nilrun:
    xor si, si
.off:
    mov di, bx                      ; the offset byte is BANKED, not stored:
    add di, wd_dfkb                 ; rgb[i] sits at 4*(crun+1) + i and crun
    mov [di], si                    ; is not known until the page is sealed,
    inc word [wd_dfkn]              ; so writing it now writes it in a place
                                    ; the next run moves. rgfc[i] at 4*i does
                                    ; not move, which is why THAT one is
                                    ; stored where it belongs as it goes
    clc
    jmp short .out
.full:
    stc
.out:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_fkflush - copy the built page into the image at ES:DI and advance DI.
; Preserves all but DI.
wd_fkflush:
    push ax
    push bx
    push cx
    push si
    push di                         ; the IMAGE pointer - DI is this routine's
                                    ; OUTPUT, so it comes back before the copy
                                    ; and not after it
    mov ax, [wd_dfkn]
    mov [wd_dfkp + WD_SECT - 1], al ; crun, byte 511
    mov di, ax                      ; the offset bytes land at 4*(crun+1),
    inc di                          ; now that crun is final
    shl di, 1
    shl di, 1
    add di, wd_dfkp
    mov si, wd_dfkb
    mov cx, ax
    jcxz .noff
    push es
    push ds
    pop es
    cld
    rep movsb
    pop es
.noff:
    pop di
    mov si, wd_dfkp
    mov cx, WD_SECT
    cld
    rep movsb
    pop si
    pop cx
    pop bx
    pop ax
    ret

; wd_btadd - bank a page's first fc in the bin table under construction
; in:  AX = the fc; out: CF=1 = there are more pages than WD_MAXBTE allows.
; Preserves all registers.
wd_btadd:
    push bx
    mov bx, [wd_dbtn]
    cmp bx, WD_MAXBTE
    jae .full
    shl bx, 1
    mov [bx+wd_dbtfc], ax
    inc word [wd_dbtn]
    clc
    jmp short .out
.full:
    stc
.out:
    pop bx
    ret

; -----------------------------------------------------------------------------
; wd_dchps - write every CHPX FKP page
; in/out: ES:DI in the image; out CF=1 = out of room. [wd_dbn0] = the page
;         count, and the page-start fcs are banked in wd_dbtfc.
;
; A run is a maximal span of equal attribute byte. A paragraph mark's CHP
; byte is its PAP index, not attributes (SPEC.md 68.3), so a 13 reads as
; plain - which is also what it is in the file, where the paragraph's
; properties live in the PAPX.
; -----------------------------------------------------------------------------
wd_dchps:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [wd_dbtn], 0
    mov bx, WD_HDRPAGE              ; BX = the fc the current run starts at
    xor si, si                      ; SI = the character index it starts at
.page:
    mov ax, WD_SECT
    call wd_droom
    jc .no
    mov ax, bx
    call wd_btadd
    jc .no
    call wd_fkinit
.run:
    cmp si, [wd_dvlen]
    jae .seal
    call wd_dattr                   ; AL = the attribute, [wd_dend] = one
    call wd_dgrpc                   ; past the run's last character
    call wd_dchpx                   ; the CHPX -> [wd_dprop], CX its length
    mov dx, [wd_dend]
    add dx, WD_HDRPAGE
    mov ax, bx
    call wd_fkadd
    jc .full
    mov bx, dx
    mov si, [wd_dend]
    jmp short .run
.full:
    cmp word [wd_dfkn], 0           ; a page that could not hold even ONE run
    je .no                          ; would loop forever; the biggest grpprl
    call wd_fkflush                 ; either builder makes is WD_GRPMAX, so
    jmp short .page                 ; this is a guard and not a path
.seal:
    call wd_fkflush
    mov ax, [wd_dbtn]
    mov [wd_dbn0], ax
    clc
    jmp short .out
.no:
    stc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dchpx - wrap the grpprl at [wd_dgrp] as a CHPX at [wd_dprop]
; in:  CX = the grpprl's length; out: CX = the CHPX's, 0 for an empty grpprl
;      (which the FKP writes as the nil offset). Preserves all but CX.
;
; A CHPX is a cb byte and THEN the grpprl (fetch.c: `cch = *hpchpx++`). A
; PAPX is not - its first byte is a count of words - so only this side wraps.
; -----------------------------------------------------------------------------
wd_dchpx:
    push ax
    push si
    push di
    push es
    jcxz .out
    push ds
    pop es
    mov al, cl
    mov [wd_dprop], al
    mov si, wd_dgrp
    mov di, wd_dprop + 1
    cld
    rep movsb
    mov cl, [wd_dprop]
    xor ch, ch
    inc cx
.out:
    pop es
    pop di
    pop si
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dattr - the attribute run beginning at SI
; in:  SI = a character index
; out: AL = the run's attribute byte, [wd_dend] = one past its last
;      character; preserves every other register
; -----------------------------------------------------------------------------
wd_dattr:
    push bx
    push cx
    push dx
    push ds
    mov bx, si
    PKG_STB wd_dpicrun, 0
    call wd_dispic                  ; A PICTURE IS ALWAYS A RUN OF ONE, so its
    jne .notpic                     ; CHPX can carry its own fcPic and nothing
    PKG_STB wd_dpicrun, 1     ; else shares it (SPEC.md 86.7)
    call wd_dat1                    ; AL = the CHP byte, which for a picture
    mov dl, al                      ; character is its INDEX (68.15)
    inc bx
    jmp short .end
.notpic:
    call wd_dat1
    mov dl, al
    PKG_LD cx, wd_dvlen
.scan:
    inc bx
    cmp bx, cx
    jae .end
    call wd_dispic                  ; ...and the run before one ends AT it
    je .end
    call wd_dat1
    cmp al, dl
    je .scan
.end:
    PKG_ST wd_dend, bx
    mov al, dl
    pop ds
    pop dx
    pop cx
    pop bx
    ret

; wd_dispic - ZF=1 if the character at index BX is a picture. Clobbers DS only.
wd_dispic:
    push ax
    PKG_CMP bx, wd_len
    jae .no
    PKG_LDS wd_dseg
    mov al, [bx]
    cmp al, WD_PICCH
    pop ax
    ret
.no:
    or al, 1                        ; anything that clears ZF
    pop ax
    ret

; wd_dat1 - AL = the CHARACTER attribute at index BX (a ¶'s byte is its PAP
; index, so it reads as plain). Clobbers AL and DS only.
wd_dat1:
    PKG_CMP bx, wd_len
    jae .plain                      ; the appended trailing mark
    PKG_LDS wd_dseg
    mov al, [bx]
    cmp al, 13
    je .plain
    PKG_LDS wd_cseg
    mov al, [bx]
    ret
.plain:
    xor al, al
    ret

; -----------------------------------------------------------------------------
; wd_dpaps - write every PAPX FKP page
; in/out ES:DI; out CF=1 = out of room, [wd_dbn1] = the page count.
;
; One run per paragraph, its fc range covering the mark as well as the text,
; and its PAPX is (cw, stc, PHE, grpprl): cw is a count of WORDS (nFib >= 25,
; file.h's history entry 25), stc is stcNormal, and the PHE has fUnk set,
; because this port does not paginate and will not claim a height it has not
; measured.
; -----------------------------------------------------------------------------
wd_dpaps:
    push ax
    push bx
    push cx
    push dx
    push si
    mov word [wd_dbtn], 0
    mov bx, WD_HDRPAGE
    xor si, si
.page:
    mov ax, WD_SECT
    call wd_droom
    jc .no
    mov ax, bx
    call wd_btadd
    jc .no
    call wd_fkinit
.run:
    cmp si, [wd_dvlen]
    jae .seal
    call wd_dpara                   ; AL = the PAP index, [wd_dend] = one
    call wd_dpapx                   ; past the mark; CX = the PAPX's length
    mov dx, [wd_dend]
    add dx, WD_HDRPAGE
    mov ax, bx
    call wd_fkadd
    jc .full
    mov bx, dx
    mov si, [wd_dend]
    jmp short .run
.full:
    cmp word [wd_dfkn], 0
    je .no
    call wd_fkflush
    jmp short .page
.seal:
    call wd_fkflush
    mov ax, [wd_dbtn]
    mov [wd_dbn1], ax
    clc
    jmp short .out
.no:
    stc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dpara - the paragraph beginning at SI
; out: AL = its PAP dictionary index, [wd_dend] = one past its mark (or the
;      buffer's end for the tail paragraph); preserves all other registers
; -----------------------------------------------------------------------------
wd_dpara:
    push bx
    push cx
    push ds
    mov bx, si
    PKG_LD cx, wd_len
    PKG_LDS wd_dseg
.scan:
    cmp bx, cx
    jae .tail
    cmp byte [bx], 13
    je .mark
    inc bx
    jmp short .scan
.mark:
    PKG_LDS wd_cseg
    mov al, [bx]                    ; the mark's CHP byte IS the index
    inc bx
    jmp short .end
.tail:
    PKG_LD al, wd_pap_tail        ; the tail paragraph rides the mark this
    inc bx                          ; writer appends, at index [wd_len]
.end:
    PKG_ST wd_dend, bx
    pop ds
    pop cx
    pop bx
    ret

; wd_dpapx - build the PAPX for PAP index AL at [wd_dprop]; CX = its length.
; Preserves all but CX. It lands in the property buffer directly, because
; wd_dgrpp builds the grpprl in the OTHER one and the two never overlap.
wd_dpapx:
    push ax
    push bx
    push si
    push di
    push es
    call wd_dgrpp                   ; CX = the grpprl at [wd_dgrp]
    mov bx, cx
    add cx, 1 + 1 + WD_CBPHE        ; cw counts the cw byte, stc, the PHE and
    inc cx                          ; the grpprl, rounded up to a whole word
    and cl, 0xFE
    mov al, cl
    shr al, 1
    push cx
    push ds
    pop es
    mov di, wd_dprop
    cld
    mov [di], al                    ; cw, in WORDS
    mov byte [di+1], 0              ; stc = stcNormal
    mov word [di+2], 2              ; PHE: fUnk set - the height is unknown
    mov word [di+4], 0
    mov word [di+6], 0
    add di, 2 + WD_CBPHE
    mov si, wd_dgrp
    mov cx, bx
    rep movsb
    mov byte [di], 0                ; the pad byte a PAPX rounded up to a
                                    ; whole word gets. cw counts it, so a
                                    ; stale byte here is read as an sprm -
                                    ; found by diffing this writer's output
                                    ; against tools/os88doc.py's
    pop cx
    pop es
    pop di
    pop si
    pop bx
    pop ax
    ret

; =============================================================================
; THE SMALL STRUCTURES
; =============================================================================

; wd_dstsh - the style sheet: cstcStd, the three style STTBs, the PLESTCP.
; in/out ES:DI; CF=1 = no room. Preserves all but DI.
wd_dstsh:
    push ax
    push cx
    push si
    mov ax, 64
    call wd_droom
    jc .no
    mov [es:WDF_FCSTSH], di
    mov [es:WDF_FCSTSHO], di
    mov word [es:WDF_FCSTSH+2], 0
    mov word [es:WDF_FCSTSHO+2], 0
    mov si, di
    cld
    xor ax, ax                      ; cstcStd = 0: Normal is the only style,
    stosw                           ; and stcNormal is 0 (props.h)
    mov ax, 2 + 1 + 6               ; --- the name STTB: bMax counts ITSELF
    stosw                           ; (create.c: `bMax -= sizeof(int)`)
    mov al, 6
    stosb
    push si
    mov si, wd_d_normal
    mov cx, 6
    push ds
    push cs
    pop ds
    rep movsb
    pop ds
    pop si
    mov ax, 2 + 1                   ; --- the CHPX rule STTB: one entry, 255
    stosw                           ; = 'no rule' (create.c's fStyleRules)
    mov al, 255
    stosb
    mov ax, 2 + 1                   ; --- the PAPX rule STTB, likewise
    stosw
    mov al, 255
    stosb
    mov ax, 1                       ; --- the PLESTCP: a count, then the
    stosw                           ; ESTCPs (create.c's HplReadPlf)
    xor al, al
    stosb                           ; stcNext = Normal
    stosb                           ; stcBase = Normal
    mov ax, di
    sub ax, si
    mov [es:WDF_CBSTSH], ax
    mov [es:WDF_CBSTSHO], ax
    clc
    jmp short .out
.no:
    stc
.out:
    pop si
    pop cx
    pop ax
    ret

; wd_dsed - the section table: one section, its SEPX fcNil (= the default
; section properties, so no SEPX is written at all). in/out ES:DI.
wd_dsed:
    push ax
    mov ax, 32
    call wd_droom
    jc .no
    mov [es:WDF_FCSED], di
    mov word [es:WDF_FCSED+2], 0
    cld
    xor ax, ax                      ; rgcp[0] = 0
    stosw
    stosw
    mov ax, [wd_dvlen]              ; rgcp[1] = ccpText
    stosw
    xor ax, ax
    stosw
    stosw                           ; SED: fn = 0 and the flags clear
    mov ax, 0xFFFF                  ; SED.fcSepx = fcNil
    stosw
    stosw
    mov word [es:WDF_CBSED], 4 + 4 + WD_CBSED
    clc
    jmp short .out
.no:
    stc
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dbte - the two bin tables
; in/out ES:DI; CF=1 = no room. Preserves all but DI.
;
; The FKP pages of one kind are laid down contiguously, so page k's PN is
; the FIB's pnChpFirst/pnPapFirst plus k and only the page-start FCs need
; banking. The PAP pass overwrote the CHP pass's array, so the CHP table is
; rebuilt from the ONE fact that survives - every CHP page but the first
; starts where the previous one's last run ended, which is what wd_dbtfc
; holds for the PAP pass and what the FKPs themselves hold for the CHP pass.
; So the CHP table is written FIRST, out of the pages already in the image.
; -----------------------------------------------------------------------------
wd_dbte:
    push ax
    push bx
    push cx
    push dx
    push si
    mov ax, [wd_dbn0]               ; CHP pages
    add ax, [wd_dbn1]
    shl ax, 1
    shl ax, 1
    add ax, 64
    call wd_droom
    jc .no
    mov [es:WDF_FCBTECHP], di       ; --- the CHPX bin table ----------------
    mov word [es:WDF_FCBTECHP+2], 0
    mov bx, [wd_dbn0]
    mov dx, [wd_dpn0]
    call wd_dbtwr
    mov ax, bx                      ; cb = 4*(n+1) + 2*n = 6n + 4
    shl ax, 1
    add ax, bx
    shl ax, 1
    add ax, 4
    mov [es:WDF_CBBTECHP], ax
    mov [es:WDF_FCBTEPAP], di       ; --- the PAPX bin table ----------------
    mov word [es:WDF_FCBTEPAP+2], 0
    mov bx, [wd_dbn1]
    mov dx, [wd_dpn1]
    call wd_dbtwr
    mov ax, bx
    shl ax, 1
    add ax, bx
    shl ax, 1
    add ax, 4
    mov [es:WDF_CBBTEPAP], ax
    clc
    jmp short .out
.no:
    stc
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_dbtwr - write one bin table: BX pages starting at page DX. in/out ES:DI.
; Each page's first FC is read back out of the page itself (rgfc[0]), which
; is the copy that cannot go stale. Preserves all but DI.
wd_dbtwr:
    push ax
    push cx
    push si
    xor si, si
    cld
.fc:
    cmp si, bx
    jae .lim
    mov ax, dx
    add ax, si
    mov cl, 9
    shl ax, cl                      ; the page's byte offset...
    mov cx, ax
    push si
    mov si, cx
    mov ax, [es:si]                 ; ...and its rgfc[0]
    pop si
    stosw
    xor ax, ax
    stosw
    inc si
    jmp short .fc
.lim:
    mov ax, [es:WDF_FCMAC]          ; the last CP is the text's end
    stosw
    xor ax, ax
    stosw
    xor si, si
.pn:
    cmp si, bx
    jae .done
    mov ax, dx
    add ax, si
    stosw
    inc si
    jmp short .pn
.done:
    pop si
    pop cx
    pop ax
    ret

; wd_ddop - the document properties. in/out ES:DI; CF=1 = no room.
wd_ddop:
    push ax
    push cx
    push di
    mov ax, WD_CBDOP + 2
    call wd_droom
    jc .no
    mov [es:WDF_FCDOP], di
    mov word [es:WDF_FCDOP+2], 0
    mov word [es:WDF_CBDOP], WD_CBDOP
    push di
    mov cx, WD_CBDOP
    xor al, al
    cld
    rep stosb
    pop di
    mov word [es:di+10], 15840      ; yaPage: 11" in twips
    mov word [es:di+12], 12240      ; xaPage: 8.5"
    mov word [es:di+14], 1440       ; dyaTop
    mov word [es:di+16], 1800       ; dxaLeft   - Word's 1.25"
    mov word [es:di+18], 1440       ; dyaBottom
    mov word [es:di+20], 1800       ; dxaRight
    mov word [es:di+24], 720        ; dxaTab: the default stop, 0.5"
    pop cx                          ; the DI pushed on entry, discarded: DI
    add di, WD_CBDOP                ; is an output
    clc
    jmp short .out
.no:
    pop di
    stc
.out:
    pop cx
    pop ax
    ret

wd_d_normal: db 'Normal'

; =============================================================================
; THE READER
; =============================================================================

; -----------------------------------------------------------------------------
; wd_docparse - load a Word file out of the staging claim into the document
; in:  [wd_stgseg] = the staging claim holding the whole file, AX = its byte
;      count
; out: CF=0 loaded, CF=1 refused (the caller toasts; the document is
;      untouched). Clobbers everything.
;
; Order: validate the FIB, find the pieces, size the document claim, copy the
; text, paint the CHP from the CHPX FKPs, stamp the paragraph marks from the
; PAPX FKPs, then compact away the characters this port cannot hold. Nothing
; is written into the document until validation has passed, so a refusal
; really does leave the document alone.
; -----------------------------------------------------------------------------
wd_docparse:
    mov [wd_dfsize], ax
    mov byte [wd_dtrunc], 0
    push es
    mov es, [wd_stgseg]
    call wd_dvfib
    pop es
    jc .no
    call wd_dpieces
    jc .no
    mov ax, [wd_dccp]
    cmp ax, WD_MAXKB * 1024
    jbe .fits
    mov ax, WD_MAXKB * 1024
    mov [wd_dccp], ax
    mov byte [wd_dtrunc], 1
.fits:
    mov ax, [wd_dccp]
    add ax, 1023
    push cx
    mov cl, 10
    shr ax, cl
    pop cx
    inc ax
    call far [wd_v_resize]
    jc .no
    mov word [wd_papn], 1           ; a fresh dictionary: entry 0 is Normal
    push es                         ; and wd_papfind grows it from there
    mov es, [wd_pseg]
    mov word [es:0], 0
    mov word [es:2], 0
    pop es
    call wd_dtext                   ; the pieces' text -> [wd_dseg]
    call wd_dchpin                  ; the CHPX runs    -> [wd_cseg]
    call wd_dpapin                  ; the PAPX runs    -> the ¶ marks
    call wd_dtrim                   ; the file's last ¶ is our TAIL paragraph
    call wd_dcompact                ; drop what this port cannot render
    call far [wd_v_pictfree]; THE OLD DOCUMENT'S PICTURES GO BACK
                                    ; HERE, not at wd_load's commit point,
                                    ; which is past the ones wd_dpicr is
                                    ; about to build (SPEC.md 86.7). Safe
                                    ; this late: every refusal wd_docparse
                                    ; can make is above this line, so by now
                                    ; the read has committed and the rule the
                                    ; commit point was protecting - that a
                                    ; refusal must not cost the pictures it
                                    ; was not replacing - still holds
    call wd_dpicr                   ; ...then pair each surviving WD_PICCH
                                    ; with its PICF. AFTER compaction, so the
                                    ; indices it writes are the final ones
    mov al, [wd_pap_tail]           ; banked across wd_clamp, which clears it
    mov [wd_dtail], al
    clc
    ret
.no:
    stc
    ret

; -----------------------------------------------------------------------------
; wd_dvfib - validate the FIB against the file size
; in:  ES = the staging claim, [wd_dfsize] = the byte count
; out: CF=1 = refuse. Preserves all registers.
;
; Every fc/cb pair must lie inside the file and every fc's high word must be
; zero - the 16-bit bound the head of this file states. A file that fails
; here is refused whole rather than half-read.
; -----------------------------------------------------------------------------
wd_dvfib:
    push ax
    push bx
    cmp word [wd_dfsize], WD_HDRPAGE
    jb .no
    cmp word [es:WDF_IDENT], WD_DOCMAGIC
    jne .no
    mov ax, [es:WDF_NFIB]
    cmp ax, WD_NFIBMIN
    jb .no
    mov bx, WDF_FCMIN
    call wd_dvfc
    jc .no
    mov bx, WDF_FCMAC
    call wd_dvfc
    jc .no
    mov bx, WDF_FCSTSH
    call wd_dvpair
    jc .no
    mov bx, WDF_FCSED
    call wd_dvpair
    jc .no
    mov bx, WDF_FCBTECHP
    call wd_dvpair
    jc .no
    mov bx, WDF_FCBTEPAP
    call wd_dvpair
    jc .no
    mov bx, WDF_FCCLX
    call wd_dvpair
    jc .no
    mov ax, [es:WDF_FCMIN]
    cmp ax, [es:WDF_FCMAC]
    ja .no
    clc
    jmp short .out
.no:
    stc
.out:
    pop bx
    pop ax
    ret

; wd_dvfc - the FC at ES:BX is 16-bit and inside the file. CF=1 = it is not.
; Preserves all registers.
wd_dvfc:
    push ax
    cmp word [es:bx+2], 0
    jne .no
    mov ax, [es:bx]
    cmp ax, [wd_dfsize]
    ja .no
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret

; wd_dvpair - the (FC, uns) pair at ES:BX. A cb of 0 passes whatever the fc
; says, which is how Opus's own reader treats an absent structure.
; Preserves all registers.
wd_dvpair:
    push ax
    cmp word [es:bx+4], 0
    je .ok
    call wd_dvfc
    jc .no
    mov ax, [es:bx]
    add ax, [es:bx+4]
    jc .no
    cmp ax, [wd_dfsize]
    ja .no
.ok:
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret

; -----------------------------------------------------------------------------
; wd_dpieces - find the text's pieces (SPEC.md 68.4.1)
; in:  [wd_stgseg]
; out: CF=1 = refuse; [wd_dpcn] = the piece count, [wd_dpcp]/[wd_dpcd] = the
;      plcpcd's CP and PCD arrays, [wd_dccp] = the document's total length.
;      Preserves all registers.
;
; A simple file is described as ONE piece so that everything downstream has a
; single shape to walk.
; -----------------------------------------------------------------------------
wd_dpieces:
    push ax
    push bx
    push cx
    push dx
    push es
    mov es, [wd_stgseg]
    test word [es:WDF_FLAGS], WD_FCOMPLEX
    jnz .complex
    mov word [wd_dpcn], 1            ; --- simple: one piece ------------------
    mov ax, [es:WDF_CCPTEXT]
    mov [wd_dccp], ax
    mov ax, [es:WDF_FCMIN]
    mov [wd_dp1fc], ax
    add ax, [wd_dccp]
    jc .no
    cmp ax, [wd_dfsize]
    ja .no
    clc
    jmp .out
.complex:
    cmp word [es:WDF_CBCLX], 0
    je .no
    mov bx, [es:WDF_FCCLX]
    mov cx, [es:WDF_CBCLX]
    add cx, bx                      ; CX = one past the CLX
.skipprc:
    cmp bx, cx
    jae .no
    cmp byte [es:bx], 1             ; clxtPrc: a byte, a word length and a
    jne .plc                        ; grpprl - skipped whole (SPEC.md 68.4.1)
    mov ax, [es:bx+1]
    add bx, 3
    add bx, ax
    jc .no
    jmp short .skipprc
.plc:
    cmp byte [es:bx], 2             ; clxtPlcpcd
    jne .no
    mov ax, [es:bx+1]               ; its byte length
    add bx, 3
    cmp ax, 4 + WD_CBPCD
    jb .no
    sub ax, 4                       ; n = (cb - 4) / (4 + cbPCD)
    xor dx, dx
    mov cx, 4 + WD_CBPCD
    div cx
    or ax, ax
    jz .no
    cmp ax, WD_MAXPCD
    ja .no
    mov [wd_dpcn], ax
    mov [wd_dpcp], bx               ; the CP array...
    mov cx, ax
    shl ax, 1
    shl ax, 1
    add ax, 4
    add bx, ax
    mov [wd_dpcd], bx               ; ...then the PCDs
    mov bx, [wd_dpcp]               ; the last CP is the document's length
    mov ax, cx
    shl ax, 1
    shl ax, 1
    add bx, ax
    cmp word [es:bx+2], 0
    jne .no
    mov ax, [es:bx]
    mov [wd_dccp], ax
    clc
    jmp short .out
.no:
    stc
.out:
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dpget - piece BX's file offset, length and first CP
; in:  BX = a piece index
; out: AX = its fc, CX = its length in characters, DX = its first CP;
;      CF=1 = it does not lie inside the file. Preserves BX, SI, DI, ES.
; -----------------------------------------------------------------------------
wd_dpget:
    push si
    push es
    mov es, [wd_stgseg]
    cmp word [wd_dpcn], 1
    jne .cx
    or bx, bx
    jnz .no
    mov ax, [wd_dp1fc]
    mov cx, [wd_dccp]
    xor dx, dx
    jmp short .chk
.cx:
    mov si, bx
    shl si, 1
    shl si, 1
    add si, [wd_dpcp]
    cmp word [es:si+2], 0
    jne .no
    cmp word [es:si+6], 0
    jne .no
    mov dx, [es:si]                 ; cp
    mov cx, [es:si+4]               ; the next cp
    sub cx, dx
    jc .no
    mov si, bx
    shl si, 1
    shl si, 1
    shl si, 1                       ; x 8 = cbPCD
    add si, [wd_dpcd]
    cmp word [es:si+4], 0           ; the PCD's fc, high word
    jne .no
    mov ax, [es:si+2]
.chk:
    push ax
    add ax, cx
    jc .no2
    cmp ax, [wd_dfsize]
    ja .no2
    pop ax
    pop es
    pop si
    clc
    ret
.no2:
    pop ax
.no:
    pop es
    pop si
    stc
    ret

; -----------------------------------------------------------------------------
; wd_dfcof - the file offset a document CP maps to
; in:  AX = a CP
; out: CF=0 and AX = its fc; CF=1 = it is in no piece. Preserves all others.
; -----------------------------------------------------------------------------
wd_dfcof:
    push bx
    push cx
    push dx
    push si
    mov si, ax
    xor bx, bx
.piece:
    cmp bx, [wd_dpcn]
    jae .no
    call wd_dpget
    jc .next
    cmp si, dx
    jb .next
    push dx
    add dx, cx
    cmp si, dx
    pop dx
    jae .next
    sub si, dx
    add ax, si
    pop si
    pop dx
    pop cx
    pop bx
    clc
    ret
.next:
    inc bx
    jmp short .piece
.no:
    pop si
    pop dx
    pop cx
    pop bx
    stc
    ret

; -----------------------------------------------------------------------------
; wd_dtext - copy every piece's text into the document claim
; Preserves all registers.
;
; Characters are copied VERBATIM here, so a CP still indexes the same
; character it does in the file; wd_dcompact drops what this port cannot hold
; afterwards, once the properties have been painted.
; -----------------------------------------------------------------------------
wd_dtext:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    xor bx, bx
.piece:
    PKG_CMP bx, wd_dpcn
    jae .done
    call wd_dpget
    jc .next
    PKG_CMP dx, wd_dccp
    jae .next
    mov si, ax
    mov di, dx
    PKG_LD ax, wd_dccp
    sub ax, di
    cmp cx, ax                      ; a piece that runs past the ceiling is
    jbe .fit                        ; clipped to it
    mov cx, ax
.fit:
    jcxz .next
    PKG_LDS wd_stgseg
    PKG_LDE wd_dseg
    cld
    rep movsb
.next:
    inc bx
    jmp short .piece
.done:
    pop es
    pop ds
    mov ax, [wd_dccp]
    mov [wd_len], ax
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dchpin - paint the CHP array from the CHPX FKPs
; Preserves all registers.
;
; Piece by piece: ask for the run covering the current fc, paint the
; characters it covers, jump to its limit. A file that describes no run for
; some fc leaves the CHP byte at its cleared value, which is plain.
; -----------------------------------------------------------------------------
wd_dchpin:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, [wd_cseg]               ; the CHP claim starts blank
    xor di, di
    mov cx, [wd_len]
    xor al, al
    cld
    jcxz .noclr
    rep stosb
.noclr:
    xor bx, bx
.piece:
    cmp bx, [wd_dpcn]
    jae .done
    call wd_dpget
    jc .next
    mov si, ax                      ; SI = the fc walking the piece
    mov di, dx                      ; DI = the document index it maps to
    mov [wd_dprem], cx              ; how many characters are left in it
.run:
    cmp word [wd_dprem], 0
    je .next
    mov ax, si
    xor cl, cl                      ; the CHP tables
    call wd_dfkfind                 ; AL = the attribute, [wd_dfclim] = lim
    mov cx, [wd_dfclim]
    sub cx, si
    jbe .one
    cmp cx, [wd_dprem]
    jbe .paint
.clip:
    mov cx, [wd_dprem]
    jmp short .paint
.one:
    mov cx, 1                       ; a run that does not advance still has
                                    ; to: one character, then ask again
    cmp cx, [wd_dprem]
    jbe .paint
    jmp short .clip
.paint:
    push di
    push cx
    push es
    PKG_LDE wd_cseg
    cld
    rep stosb                       ; AL is the attribute
    pop es
    pop cx
    pop di
    add di, cx
    add si, cx
    sub [wd_dprem], cx
    jmp short .run
.next:
    inc bx
    jmp short .piece
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
; wd_dpapin - stamp the paragraph marks with their PAP dictionary indices
; Preserves all registers.
;
; Walks the document's own marks rather than the FKP runs: a mark's CP maps
; back to an fc through the pieces (wd_dfcof), and the PAPX covering that fc
; is the paragraph's format. Doing it in this direction means a run split
; across two pieces needs no special case at all, and the mark - the thing
; that actually carries the index (SPEC.md 68.3) - is what drives the loop.
; -----------------------------------------------------------------------------
wd_dpapin:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    PKG_STB wd_pap_tail, 0
    xor si, si
    PKG_LD cx, wd_len
.scan:
    cmp si, cx
    jae .tail
    PKG_LDS wd_dseg
    mov al, [si]
    push cs
    pop ds
    cmp al, 13
    jne .next
    mov ax, si
    call wd_dpapat                  ; AL = the index for the fc of CP SI
    jc .next
    mov es, [wd_cseg]
    mov [es:si], al
.next:
    inc si
    jmp short .scan
.tail:
    or cx, cx
    jz .done
    mov ax, cx                      ; the tail paragraph: the LAST character
    dec ax                          ; is inside it, and its PAPX is the one
    call wd_dpapat                  ; that covers it
    jc .done
    PKG_ST wd_pap_tail, al
.done:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dpapat - the dictionary index for the paragraph covering CP AX
; out: CF=0 and AL = the index; CF=1 = there is no PAPX there, or the
;      dictionary is full. Preserves all other registers.
; -----------------------------------------------------------------------------
wd_dpapat:
    push bx
    push cx
    push dx
    push si
    push es
    call wd_dfcof
    jc .no
    xor cl, cl
    mov cl, 1                       ; the PAP tables
    call wd_dfkfind                 ; [wd_dprop2] = the PAPX, or 0
    mov word [wd_pfb], 0            ; the candidate starts at Normal
    mov word [wd_pfb+2], 0
    mov si, [wd_dprop2]
    or si, si
    jz .find                        ; a nil PAPX IS Normal
    mov es, [wd_stgseg]
    mov cl, [es:si]                 ; cw, a count of WORDS (nFib >= 25)
    xor ch, ch
    shl cx, 1
    cmp cx, 1 + 1 + WD_CBPHE
    jbe .find
    sub cx, 1 + 1 + WD_CBPHE        ; what is left is the grpprl
    add si, 2 + WD_CBPHE
    call wd_dprl
.find:
    call far [wd_v_papfind]; CF=1 = the dictionary is full
    jmp short .out
.no:
    stc
.out:
    pop es
    pop si
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; wd_dprl - apply a paragraph grpprl to the candidate at [wd_pfb]
; in:  ES:SI = the grpprl, CX = its length
; out: nothing; preserves all registers
;
; Every sprm is stepped by its dnsprm width, so an sprm this port has no
; field for is SKIPPED rather than guessed at - which is the whole reason the
; widths are transcribed at the head of this file.
; -----------------------------------------------------------------------------
wd_dprl:
    push ax
    push bx
    push cx
    push dx
    push si
.step:
    or cx, cx
    jz .out
    mov al, [es:si]                 ; the sprm code
    inc si
    dec cx
    call wd_dpwid                   ; BL = its operand width in bytes
    xor bh, bh
    cmp bx, cx
    ja .out                         ; a grpprl that runs off its own end
    cmp al, WDS_PJC
    je .jc
    cmp al, WDS_PDXAL
    je .left
    cmp al, WDS_PDXAL1
    je .first
    cmp al, WDS_PDXAR
    je .right
    cmp al, WDS_PDYALIN
    je .line
    cmp al, WDS_PDYABEF
    je .before
.skip:
    add si, bx
    sub cx, bx
    jmp short .step
.jc:
    mov al, [es:si]
    and al, WDPA_ALIGN
    and byte [wd_pfb], ~WDPA_ALIGN & 0xFF
    or [wd_pfb], al
    jmp short .skip
.left:
    call wd_dcell
    mov [wd_pfb+1], al
    jmp short .skip
.first:
    call wd_dcell
    mov [wd_pfb+2], al
    jmp short .skip
.right:
    call wd_dcell
    mov [wd_pfb+3], al
    jmp short .skip
.line:
    mov ax, [es:si]                 ; 240 -> 0, 360 -> 1, 480 or more -> 2;
    mov dl, 0                       ; anything else rounds to the nearest of
    cmp ax, 300                     ; the three the renderer has
    jb .lset
    mov dl, 1
    cmp ax, 420
    jb .lset
    mov dl, 2
.lset:
    shl dl, 1
    shl dl, 1
    and byte [wd_pfb], ~WDPA_SPACE & 0xFF
    or [wd_pfb], dl
    jmp short .skip
.before:
    mov ax, [es:si]
    or ax, ax
    jz .skip
    or byte [wd_pfb], WDPA_SB
    jmp short .skip
.out:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_dcell - AL = the signed word operand at ES:SI in cells, clamped to the
; indent range. Preserves all but AX.
wd_dcell:
    push bx
    push cx
    push dx
    mov ax, [es:si]
    cwd
    mov cx, WD_TWIPCELL
    idiv cx
    cmp ax, WD_INDMAX
    jle .lo
    mov ax, WD_INDMAX
.lo:
    cmp ax, -WD_INDMAX
    jge .ok
    mov ax, -WD_INDMAX
.ok:
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; wd_dpwid - BL = the operand width of paragraph sprm AL, from dnsprm's cch
; (1 = none, 2 = a byte, 3 = a word, 0 = a length byte follows the code).
; in: ES:SI = one past the sprm code, for the variable kind. Preserves all
; registers but BX.
; -----------------------------------------------------------------------------
wd_dpwid:
    push ax
    cmp al, 15                      ; sprmPChgTabsPapx } cch 0: the byte at
    je .var                         ; sprmPChgTabs     } SI is the length
    cmp al, 23
    je .var
    cmp al, 3                       ; sprmPStcPermute: cch 0 as well
    je .var
    cmp al, 16                      ; 16..22 and 26..36 are the word-operand
    jb .b1                          ; paragraph sprms; everything else in the
    cmp al, 22                      ; sgcPap range takes a byte
    jbe .b2
    cmp al, 26
    jb .b1
    cmp al, 36
    jbe .b2
    cmp al, 52                      ; sprmPRuler: a length byte
    je .var
.b1:
    mov bl, 1
    jmp short .out
.b2:
    mov bl, 2
    jmp short .out
.var:
    mov bl, [es:si]
    inc bl
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dfkfind - the FKP run covering an fc
; in:  AX = the fc, CL = 0 for the CHP tables / 1 for the PAP tables
; out: AL = the attribute the run's grpprl means (0 for a PAP run - the PAP
;      caller reads [wd_dprop2] itself), [wd_dfclim] = the run's limit fc,
;      [wd_dprop2] = the property record's file offset (0 = nil).
;      Preserves every register but AX.
; -----------------------------------------------------------------------------
wd_dfkfind:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, [wd_stgseg]
    mov word [wd_dprop2], 0
    mov bx, [wd_dfsize]             ; a default limit that always terminates
    mov [wd_dfclim], bx
    or cl, cl
    jnz .pap
    mov bx, [es:WDF_FCBTECHP]
    mov dx, [es:WDF_CBBTECHP]
    jmp short .have
.pap:
    mov bx, [es:WDF_FCBTEPAP]
    mov dx, [es:WDF_CBBTEPAP]
.have:
    or dx, dx
    jz .none
    cmp dx, 4 + 6
    jb .none
    push ax
    mov ax, dx                      ; n = (cb - 4) / 6
    sub ax, 4
    xor dx, dx
    mov cx, 6
    div cx
    mov di, ax                      ; DI = n
    pop ax
    or di, di
    jz .none
    xor si, si                      ; find the i with fc[i] <= AX < fc[i+1]
.scan:
    cmp si, di
    jae .none
    push si
    shl si, 1
    shl si, 1
    add si, bx
    mov cx, [es:si]                 ; fc[i]
    mov dx, [es:si+4]               ; fc[i+1]
    pop si
    cmp ax, cx
    jb .nexti
    cmp ax, dx
    jb .found
.nexti:
    inc si
    jmp short .scan
.found:
    push ax                         ; the BTE: the page holding this run
    mov ax, di
    shl ax, 1
    shl ax, 1
    add ax, 4
    add bx, ax                      ; BX = the PN array
    mov ax, si
    shl ax, 1
    add bx, ax
    mov dx, [es:bx]                 ; DX = the page number
    pop ax
    call wd_dfkrun
    jmp short .out
.none:
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
; wd_dfkrun - decode the run covering fc AX inside FKP page DX
; out: AL = the CHP attribute the run's grpprl means, [wd_dfclim] = the run's
;      limit, [wd_dprop2] = the property record's file offset (0 = nil).
;      Preserves all but AX.
; -----------------------------------------------------------------------------
wd_dfkrun:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, [wd_stgseg]
    push ax
    mov ax, dx                      ; the page's byte offset
    mov cl, 9
    shl ax, cl
    mov di, ax
    add ax, WD_SECT
    jc .nopop
    cmp ax, [wd_dfsize]
    ja .nopop
    pop ax
    mov bl, [es:di + WD_SECT - 1]   ; crun
    xor bh, bh
    or bx, bx
    jz .nil
    xor si, si
.scan:
    cmp si, bx
    jae .nil
    push si
    shl si, 1
    shl si, 1
    add si, di
    mov cx, [es:si]
    mov dx, [es:si+4]
    pop si
    cmp ax, cx
    jb .nexti
    cmp ax, dx
    jb .hit
.nexti:
    inc si
    jmp short .scan
.hit:
    mov [wd_dfclim], dx
    mov cx, bx                      ; rgb[i] is at 4*(crun+1) + i
    inc cx
    shl cx, 1
    shl cx, 1
    add cx, si
    add cx, di
    mov bx, cx
    mov cl, [es:bx]
    xor ch, ch
    or cx, cx
    jz .nil
    shl cx, 1                       ; the offset is in WORDS (fetch.c)
    add cx, di
    cmp cx, [wd_dfsize]
    jae .nil
    mov [wd_dprop2], cx
    mov si, cx
    mov cl, [es:si]                 ; a CHPX is a cb byte then the grpprl
    xor ch, ch
    inc si
    call wd_dchprl
    jmp short .out
.nopop:
    pop ax
.nil:
    mov word [wd_dprop2], 0
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
; wd_dchprl - the attribute byte a character grpprl means
; in:  ES:SI = the grpprl, CX = its length
; out: AL = the WDAT_* byte; preserves all other registers
; -----------------------------------------------------------------------------
wd_dchprl:
    push bx
    push cx
    push dx
    push si
    xor dl, dl
.step:
    or cx, cx
    jz .out
    mov al, [es:si]
    inc si
    dec cx
    cmp al, WDS_CFBOLD
    je .bold
    cmp al, WDS_CFITAL
    je .ital
    cmp al, WDS_CFSCAP
    je .scap
    cmp al, WDS_CFVAN
    je .hid
    cmp al, WDS_CKUL
    je .kul
    call wd_dcwid                   ; anything else steps by its own width
    xor bh, bh
    cmp bx, cx
    ja .out
    add si, bx
    sub cx, bx
    jmp short .step
.bold:
    mov bl, WDAT_BOLD
    jmp short .flag
.ital:
    mov bl, WDAT_ITAL
    jmp short .flag
.scap:
    mov bl, WDAT_SCAP
    jmp short .flag
.hid:
    mov bl, WDAT_HID
.flag:
    or cx, cx
    jz .out
    mov al, [es:si]
    inc si
    dec cx
    test al, 1                      ; 0 off, 1 on; 128+ is 'toggle from the
    jz .step                        ; style', and with one style that is on
    or dl, bl
    jmp short .step
.kul:
    or cx, cx
    jz .out
    mov al, [es:si]
    inc si
    dec cx
    and dl, ~(WDAT_UL | WDAT_WUL | WDAT_DUL) & 0xFF
    cmp al, WD_KULSING
    jne .k2
    or dl, WDAT_UL
    jmp short .step
.k2:
    cmp al, WD_KULWORD
    jne .k3
    or dl, WDAT_WUL
    jmp short .step
.k3:
    cmp al, WD_KULDBL
    jne .step
    or dl, WDAT_DUL
    jmp short .step
.out:
    mov al, dl
    pop si
    pop dx
    pop cx
    pop bx
    ret

; wd_dcwid - BL = the operand width of character sprm AL (dnsprm again).
; Preserves all registers but BX.
wd_dcwid:
    push ax
    mov bl, 1
    cmp al, 58                      ; sprmCPlain: no operand at all
    je .out
    cmp al, 56                      ; sprmCSpare0 } cch 0: a length byte
    je .var
    cmp al, 57                      ; sprmCDefault
    je .var
    cmp al, 68                      ; sprmCFtc: a word
    je .w2
    cmp al, 70                      ; sprmCSizePos: three bytes
    je .w3
    cmp al, 74                      ; sprmCHps: a word
    je .w2
    mov bl, 1
    jmp short .out
.var:
    mov bl, [es:si]
    inc bl
    jmp short .out
.w2:
    mov bl, 2
    jmp short .out
.w3:
    mov bl, 3
.out:
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dtrim - turn the file's last paragraph mark into this port's tail
; Preserves all registers.
;
; The other half of wd_docimg's appended 13. A Word file's text ends with a ¶
; and its N marks are N paragraphs; this document model holds N-1 marks and a
; TAIL paragraph whose format lives in [wd_pap_tail] (SPEC.md 68.3). So the
; final mark is REMOVED and its dictionary index becomes the tail's - which
; makes save/load a fixed point instead of growing a paragraph a round.
; -----------------------------------------------------------------------------
wd_dtrim:
    push ax
    push bx
    push ds
    PKG_LD bx, wd_len
    or bx, bx
    jz .out
    dec bx
    PKG_LDS wd_dseg
    cmp byte [bx], 13
    jne .out
    PKG_LDS wd_cseg
    mov al, [bx]
    PKG_ST wd_pap_tail, al
    PKG_ST wd_len, bx
.out:
    pop ds
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dcompact - drop the characters this port cannot hold
; Preserves all registers.
;
; Runs LAST, after the properties are painted, so that a CP still indexed the
; same character while the painting happened. Text and CHP move together, one
; index at a time - the two claims are parallel arrays and every operation in
; this app keeps them so (SPEC.md 68.3).
; -----------------------------------------------------------------------------
wd_dcompact:
    push ax
    push bx
    push cx
    push si
    push di
    push ds
    push es
    PKG_LD cx, wd_len
    xor si, si
    xor di, di
.step:
    cmp si, cx
    jae .done
    PKG_LDS wd_dseg
    mov al, [si]
    cmp al, 13
    je .keep
    cmp al, 9
    je .keep
    cmp al, WD_PICCH                ; a picture SURVIVES compaction now
    je .keep                        ; (SPEC.md 86.7): it is the one control
    cmp al, 32                      ; character below 32 this port renders,
    jb .drop                        ; and wd_dpicr pairs it with its record
    cmp al, 126
    jbe .keep
.drop:
    inc si
    jmp short .step
.keep:
    PKG_LDS wd_dseg
    PKG_LDE wd_dseg
    mov al, [si]
    mov [es:di], al
    PKG_LDS wd_cseg
    PKG_LDE wd_cseg
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    jmp short .step
.done:
    pop es
    pop ds
    mov [wd_len], di
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; -----------------------------------------------------------------------------
; =============================================================================
; wd_dpicr - pair every WD_PICCH in the loaded text with its PICF, expanding
; each one back to 4bpp. Preserves all registers; a picture that will not load
; simply is not registered, and its character keeps the 8-pixel cell an
; unknown index gets.
;
; IT WALKS THE RECORDS IN DOCUMENT ORDER AND DOES NOT READ fcPic. The writer
; puts the PICFs immediately after the text, in the order their characters
; appear, and the first one therefore begins exactly at fcMac - wd_docimg
; writes the text, the trailing CR, and then calls wd_dpicw. Each record's own
; lcb gives the next. So the Nth picture character takes the Nth record, and
; the CHPX never has to be parsed for this at all.
;
; The CHPX still CARRIES fcPic, because that is what a real Word 1.1a reads
; and writing it costs nothing. This reader does not need it, and the honest
; consequence is worth stating: a .DOC whose pictures are laid out some other
; way will not load them here. os8088's .DOC is already its own dialect in the
; CHPX (SPEC.md 68.4.2), and this is inside that.
; =============================================================================
wd_dpicr:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, [wd_stgseg]             ; the first record sits at fcMac, which
    mov ax, [es:WDF_FCMAC]          ; wd_dvfib has already checked is inside
    mov [wd_dpicp], ax              ; the file (WDF_FCMAC, offset 28)
    xor bx, bx                      ; BX = the character index
.scan:
    cmp bx, [wd_len]
    jae .out
    push ds
    PKG_LDS wd_dseg
    mov al, [bx]
    pop ds
    cmp al, WD_PICCH
    jne .next
    cmp word [wd_npic], WD_PICMAX
    jae .out                        ; past what a document may hold (68.15)
    call wd_dpic1                   ; -> CF=0 and the picture registered
    jc .out                         ; a record that does not parse ends the
    mov ax, [wd_npic]               ; walk: the ones after it are found by
    dec ax                          ; stepping over this one, so there is
    push ds                         ; nothing left to trust
    PKG_LDS wd_cseg
    mov [bx], al                    ; the CHP byte IS the index (68.15)
    pop ds
.next:
    inc bx
    jmp short .scan
.out:
    pop es
    pop di
    pop si                          ; SEVEN pushed, and for one build six came
    pop dx                          ; back: the missing pop left wd_docparse
    pop cx                          ; returning through a shifted stack, and
    pop bx                          ; the document loaded EMPTY - text and all
    pop ax
    ret

; -----------------------------------------------------------------------------
; wd_dpic1 - read the PICF at [wd_dpicp] and register it, advancing [wd_dpicp]
; past the record. out: CF=0 registered; CF=1 = it is not one we can use.
; -----------------------------------------------------------------------------
wd_dpic1:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov es, [wd_stgseg]
    mov si, [wd_dpicp]
    mov ax, si
    add ax, WD_PICF
    jc .no
    cmp ax, [wd_dfsize]             ; the header has to be inside the file
    ja .no
    cmp word [es:si+4], WD_PICF     ; cbHeader
    jne .no
    cmp word [es:si+6], WD_MM_BMP   ; mm - a metafile is 7 and this port has
    jne .no                         ; no renderer for one
    cmp byte [es:si+22], 1          ; bmPlanes
    jne .no
    cmp byte [es:si+23], 1          ; bmBitsPixel: the only depth a .DOC
    jne .no                         ; picture has ever been measured at
    mov ax, [es:si+16]              ; bmWidth
    mov [wd_dpicwd], ax
    or ax, ax
    jz .no
    cmp ax, OS88IMG_WMAX
    ja .no
    mov ax, [es:si+18]              ; bmHeight
    mov [wd_dpicht], ax
    or ax, ax
    jz .no
    mov ax, [es:si+20]              ; bmWidthBytes
    mov [wd_dpicbw], ax
    or ax, ax
    jz .no
    mov cx, [wd_dpicwd]             ; ...and it must cover the width it claims
    add cx, 7                       ; at one bit a pixel: ceil(w/8)
    shr cx, 1
    shr cx, 1
    shr cx, 1
    cmp ax, cx
    jb .no
    mul word [wd_dpicht]            ; DX:AX = the pixel bytes
    or dx, dx
    jnz .no
    mov cx, ax
    add ax, WD_PICF
    jc .no
    add ax, [wd_dpicp]
    jc .no
    cmp ax, [wd_dfsize]             ; ...and all of it is inside the file
    ja .no
    mov ax, [wd_dpicwd]             ; the 4bpp destination: (w+1)/2, no pad
    inc ax
    shr ax, 1
    mov [wd_dpicst], ax
    mul word [wd_dpicht]
    or dx, dx
    jnz .no
    mov cx, ax
    add ax, 1023
    jc .no
    push cx
    mov cl, 10
    shr ax, cl
    pop cx
    or ax, ax
    jnz .kb
    mov ax, 1
.kb:
    call OSAPI_MEM_CLAIM            ; out DX = the base segment
    jc .no
    mov [wd_dpicsg], dx
    call wd_dpicexp                 ; 1bpp -> 4bpp, into that claim
    mov ax, [wd_npic]               ; the slot: w, h, stride, segment
    mov cl, 3
    shl ax, cl
    add ax, wd_pictab
    mov di, ax
    mov ax, [wd_dpicwd]
    mov [di], ax
    mov ax, [wd_dpicht]
    mov [di+2], ax
    mov ax, [wd_dpicst]
    mov [di+4], ax
    mov ax, [wd_dpicsg]
    mov [di+6], ax
    inc word [wd_npic]
    mov ax, [wd_dpicbw]             ; step past the record: lcb bytes, and a
    mul word [wd_dpicht]            ; record is padded to an even boundary -
    add ax, WD_PICF                 ; the spacing SNAP.DOC's two pictures
    inc ax                          ; showed
    and ax, 0xFFFE
    add [wd_dpicp], ax
    clc
    jmp short .out
.no:
    stc
.out:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; -----------------------------------------------------------------------------
; wd_dpicexp - expand the 1bpp rows at ES:[wd_dpicp]+46 into the 4bpp claim.
; Bit set -> CWHITE, clear -> CBLACK, which is the inverse of the reduction
; WD_PICWHITE performs on the way out, so black-and-white art makes the round
; trip byte for byte. Preserves all registers.
; -----------------------------------------------------------------------------
wd_dpicexp:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov word [wd_dpicy], 0
.row:
    mov ax, [wd_dpicy]
    cmp ax, [wd_dpicht]
    jae .done
    mul word [wd_dpicbw]            ; the SOURCE row
    add ax, [wd_dpicp]
    add ax, WD_PICF
    mov si, ax
    mov ax, [wd_dpicy]
    mul word [wd_dpicst]            ; ...and the destination one
    mov di, ax
    mov word [wd_dpicx], 0
    mov byte [wd_dpicac], 0
.px:
    mov ax, [wd_dpicx]
    cmp ax, [wd_dpicwd]
    jae .rowend
    mov bx, ax
    push cx
    mov cl, 3
    shr bx, cl
    pop cx
    add bx, si
    mov es, [wd_stgseg]
    mov dl, [es:bx]                 ; the byte holding this pixel
    mov cx, [wd_dpicx]
    and cx, 7
    mov ax, 0x0080
.bit:
    or cx, cx
    jz .masked
    shr ax, 1
    dec cx
    jmp short .bit
.masked:
    test dl, al                     ; bit 7 is the LEFTMOST pixel
    mov al, 0                       ; CBLACK
    jz .have
    mov al, 15                      ; CWHITE
.have:
    test byte [wd_dpicx], 1
    jnz .odd
    push cx
    mov cl, 4
    shl al, cl
    pop cx
    mov [wd_dpicac], al             ; an even x is the HIGH nibble and waits
    jmp short .nextpx
.odd:
    or al, [wd_dpicac]
    mov es, [wd_dpicsg]
    mov [es:di], al
    inc di
.nextpx:
    inc word [wd_dpicx]
    jmp short .px
.rowend:
    test word [wd_dpicwd], 1        ; an odd width leaves one pixel in the
    jz .rowdone                     ; high nibble with no partner, and the
    mov al, [wd_dpicac]             ; stride (w+1)/2 has the room for it
    mov es, [wd_dpicsg]
    mov [es:di], al
.rowdone:
    inc word [wd_dpicy]
    jmp .row
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; wd_ldpost - what every loader ends with, after wd_clamp
; Preserves all registers.
;
; wd_clamp puts the caret at the top and clears the tail index, the has*
; flags and the typing attributes - which is right for a load and wrong for
; the three facts the FILE just supplied. This puts those three back, and it
; is shared by the Word reader, the RTF reader and the plain-text fold so
; they cannot drift apart.
; -----------------------------------------------------------------------------
wd_ldpost:
    push ax
    mov al, [wd_dtail]
    mov [wd_pap_tail], al
    cmp word [wd_papn], 1
    jbe .n1
    mov byte [wd_hasfmt], 1
.n1:
    or al, al
    jz .n2
    mov byte [wd_hasfmt], 1
.n2:
    call far [wd_v_ldscan]; tabs -> [wd_hastab], hidden -> [wd_hashid]
    pop ax
    ret
