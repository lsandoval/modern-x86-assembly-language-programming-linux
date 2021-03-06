; Name:     ssepackedintegerthreshold.asm
;
; Build:    g++ -c -m32 main.cpp -o main.o
;           nasm -f elf32 -o ssepackedintegerthreshold.o ssepackedintegerthreshold.asm
;           g++ -m32 -o ssepackedintegerthreshold ssepackedintegerthreshold.o main.o ../../commonfiles/xmmval.o
;
; Source:   Modern x86 Assembly Language Programming p. 279
;
; Remark:   Until ImageBuffer.cpp is converted, this example is of little use.

extern NUM_PIXELS_MAX

global SsePiThreshold
global SsePiCalcMean

; Image threshold data structure (see SsePackedIntegerThreshold.h)
struc ITD
    .PbSrc:             resd 1
    .PbMask:            resd 1
    .NumPixels:         resd 1
    .Threshold:         resb 1
    .Pad:               resb 3
    .NumMaskedPixels:   resd 1
    .SumMaskedPixels:   resd 1
    .MeanMaskedPixels:  resq 1
endstruc

section .data
align 16

PixelScale:      times 16 db 0x80            ;uint8 to int8 scale value
CountPixelsMask: times 16 db 0x01            ;mask to count pixels
R8_MinusOne:     dq -1.0                     ;invalid mean value
                
section .text

; extern "C" bool SsePiThreshold(ITD* itd);
;
; Description:  The following function performs image thresholding
;               of an 8 bits-per-pixel grayscale image.
;
; Returns:      0 = invalid size or unaligned image buffer
;               1 = success
;
; Requires:     SSSE3

%define itd [ebp+8]

SsePiThreshold:
    push    ebp
    mov     ebp,esp
    push    esi
    push    edi
; Load and verify the argument values in ITD structure
    mov     edx,itd                         ;edx = 'itd'
    xor     eax,eax                         ;set error return code
    mov     ecx,[edx+ITD.NumPixels]         ;ecx = NumPixels
    test    ecx,ecx
    jz      .done                           ;jump if num_pixels == 0
    cmp     ecx,[NUM_PIXELS_MAX]
    ja      .done                           ;jump if num_pixels too big
    test    ecx,0fh
    jnz     .done                           ;jump if num_pixels % 16 != 0
    shr     ecx,4                           ;ecx = number of packed pixels
    mov     esi,[edx+ITD.PbSrc]             ;esi = PbSrc
    test    esi,0fh
    jnz     .done                           ;jump if misaligned
    mov     edi,[edx+ITD.PbMask]            ;edi = PbMask
    test    edi,0fh
    jnz     .done                           ;jump if misaligned
; Initialize packed threshold
    movzx   eax,byte[edx+ITD.Threshold]     ;eax = threshold
    movd    xmm1,eax                        ;xmm1[7:0] = threshold
    pxor    xmm0,xmm0                       ;mask for pshufb
    pshufb  xmm1,xmm0                       ;xmm1 = packed threshold
    movdqa  xmm2,[PixelScale]
    psubb   xmm1,xmm2                       ;xmm1 = scaled threshold
; Create the mask image
.@1:
    movdqa  xmm0,[esi]                      ;load next packed pixel
    psubb   xmm0,xmm2                       ;xmm0 = scaled image pixels
    pcmpgtb xmm0,xmm1                       ;compare against threshold
    movdqa  [edi],xmm0                      ;save packed threshold mask
    add     esi,16
    add     edi,16
    dec     ecx
    jnz     .@1                             ;repeat until done
    mov     eax,1                           ;set return code
.done:
    pop     edi
    pop     esi
    pop     ebp
    ret

; extern "C" bool SsePiCalcMean(ITD* itd);
;
; Description:  The following function calculates the mean value all
;               above-threshold image pixels using the mask created by
;               the function SsePiThreshold_.
;
; Returns:      0 = invalid image size or unaligned image buffer
;               1 = success
;
; Requires:     SSSE3

%define itd [ebp+8]

SsePiCalcMean:
    push    ebp
    mov     ebp,esp
    push    ebx
    push    esi
    push    edi

; Load and verify the argument values in ITD structure
    mov     eax,itd                             ;eax = 'itd'
    mov     ecx,[eax+ITD.NumPixels]             ;ecx = NumPixels
    test    ecx,ecx
    jz      .error                              ;jump if num_pixels == 0
    cmp     ecx,[NUM_PIXELS_MAX]
    ja      .error                              ;jump if num_pixels too big
    test    ecx,0x0f
    jnz     .error                              ;jump if num_pixels % 16 != 0
    shr     ecx,4                               ;ecx = number of packed pixels
    mov     edi,[eax+ITD.PbMask]                ;edi = PbMask
    test    edi,0x0f
    jnz     .error                              ;jump if PbMask not aligned
    mov     esi,[eax+ITD.PbSrc]                 ;esi = PbSrc
    test    esi,0x0f
    jnz     .error                              ;jump if PbSrc not aligned
; Initialize values for mean calculation
    xor     edx,edx                             ;edx = update counter
    pxor    xmm7,xmm7                           ;xmm7 = packed zero
    pxor    xmm2,xmm2                           ;xmm2 = sum_masked_pixels (8 words)
    pxor    xmm3,xmm3                           ;xmm3 = sum_masked_pixels (8 words)
    pxor    xmm4,xmm4                           ;xmm4 = sum_masked_pixels (4 dwords)
    pxor    xmm6,xmm6                           ;xmm6 = num_masked_pixels (8 bytes)
    xor     ebx,ebx                             ;ebx = num_masked_pixels (1 dword)
; Register usage for processing loop
; esi = PbSrc, edi = PbMask, eax = itd
; ebx = num_pixels_masked, ecx = NumPixels / 16, edx = update counter
;
; xmm0 = packed pixel, xmm1 = packed mask
; xmm3:xmm2 = sum_masked_pixels (16 words)
; xmm4 = sum_masked_pixels (4 dwords)
; xmm5 = scratch register
; xmm6 = packed num_masked_pixels
; xmm7 = packed zero
.@1:
    movdqa    xmm0,[esi]                        ;load next packed pixel
    movdqa    xmm1,[edi]                        ;load next packed mask
; Update sum_masked_pixels (word values)
    movdqa    xmm5,[CountPixelsMask]
    pand      xmm5,xmm1
    paddb     xmm6,xmm5                         ;update num_masked_pixels
    pand      xmm0,xmm1                         ;set non-masked pixels to zero
    movdqa    xmm1,xmm0
    punpcklbw xmm0,xmm7
    punpckhbw xmm1,xmm7                         ;xmm1:xmm0 = masked pixels (words)
    paddw     xmm2,xmm0
    paddw     xmm3,xmm1             ;xmm3:xmm2 = sum_masked_pixels
; Check and see if it's necessary to update the dword sum_masked_pixels
; in xmm4 and num_masked_pixels in ebx
    inc     edx
    cmp     edx,255
    jb      .noUpdate
    call    SsePiCalcMeanUpdateSums
.noUpdate:
    add     esi,16
    add     edi,16
    dec     ecx
    jnz     .@1                                 ;repeat loop until done
; Main processing loop is finished. If necessary, perform final update
; of sum_masked_pixels in xmm4 & num_masked_pixels in ebx.
    test    edx,edx
    jz      .@2
    call    SsePiCalcMeanUpdateSums
; Compute and save final sum_masked_pixels & num_masked_pixels
.@2:
    phaddd  xmm4,xmm7
    phaddd  xmm4,xmm7
    movd    edx,xmm4                            ;edx = final sum_mask_pixels
    mov     [eax+ITD.SumMaskedPixels],edx       ;save final sum_masked_pixels
    mov     [eax+ITD.NumMaskedPixels],ebx       ;save final num_masked_pixels
; Compute mean of masked pixels
    test     ebx,ebx                            ;is num_mask_pixels zero?
    jz       .noMean                            ;if yes, skip calc of mean
    cvtsi2sd xmm0,edx                           ;xmm0 = sum_masked_pixels
    cvtsi2sd xmm1,ebx                           ;xmm1 = num_masked_pixels
    divsd    xmm0,xmm1                          ;xmm0 = mean_masked_pixels
    jmp      .@3
.noMean:
    movsd   xmm0,[R8_MinusOne]                  ;use -1.0 for no mean
.@3:
    movsd   [eax+ITD.MeanMaskedPixels],xmm0     ;save mean
    mov     eax,1                               ;set return code
.done:
    pop     edi
    pop     esi
    pop     ebx
    pop     ebp
    ret
.error:
    xor     eax,eax                             ;set error return code
    jmp     .done

; void SsePiCalcMeanUpdateSums
;
; Description:  The following function updates sum_masked_pixels in xmm4
;               and num_masked_pixels in ebx. It also resets any
;               necessary intermediate values in order to prevent an
;               overflow condition.
;
; Register contents:
;   xmm3:xmm2 = packed word sum_masked_pixels
;   xmm4 = packed dword sum_masked_pixels
;   xmm6 = packed num_masked_pixels
;   xmm7 = packed zero
;   ebx = num_masked_pixels
;
; Temp registers:
;   xmm0, xmm1, xmm5, edx

SsePiCalcMeanUpdateSums:

; Promote packed word sum_masked_pixels to dword
    movdqa      xmm0,xmm2
    movdqa      xmm1,xmm3
    punpcklwd   xmm0,xmm7
    punpcklwd   xmm1,xmm7
    punpckhwd   xmm2,xmm7
    punpckhwd   xmm3,xmm7
; Update packed dword sums in sum_masked_pixels
    paddd       xmm0,xmm1
    paddd       xmm2,xmm3
    paddd       xmm4,xmm0
    paddd       xmm4,xmm2       ;xmm4 = packed sum_masked_pixels
; Sum num_masked_pixel counts (bytes) in xmm6, then add to total in ebx.
    movdqa      xmm5,xmm6
    punpcklbw   xmm5,xmm7
    punpckhbw   xmm6,xmm7       ;xmm6:xmm5 = packed num_masked_pixels
    paddw       xmm6,xmm5       ;xmm6 = packed num_masked_pixels
    phaddw      xmm6,xmm7
    phaddw      xmm6,xmm7
    phaddw      xmm6,xmm7       ;xmm6[15:0] = final word sum
    movd        edx,xmm6
    add         ebx,edx         ;ebx = num_masked_pixels
; Reset intermediate values
    xor         edx,edx
    pxor        xmm2,xmm2
    pxor        xmm3,xmm3
    pxor        xmm6,xmm6
    ret
