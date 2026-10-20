	.build_version macos, 27, 0	sdk_version 27, 0
	.section	__TEXT,__text,regular,pure_instructions
	.globl	_fib_plain                      ; -- Begin function fib_plain
	.p2align	2
_fib_plain:                             ; @fib_plain
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	add	x29, sp, #16
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	cmp	x0, #2
	b.ge	LBB0_2
; %bb.1:
	mov	x19, #0                         ; =0x0
	b	LBB0_4
LBB0_2:
	mov	x19, #0                         ; =0x0
	mov	x20, x0
LBB0_3:                                 ; =>This Inner Loop Header: Depth=1
	sub	x0, x20, #1
	bl	_fib_plain
	mov	x8, x0
	sub	x0, x20, #2
	add	x19, x8, x19
	cmp	x20, #3
	mov	x20, x0
	b.hi	LBB0_3
LBB0_4:
	add	x0, x0, x19
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_fib_checked                    ; -- Begin function fib_checked
	.p2align	2
_fib_checked:                           ; @fib_checked
	.cfi_startproc
; %bb.0:
	stp	x20, x19, [sp, #-32]!           ; 16-byte Folded Spill
	stp	x29, x30, [sp, #16]             ; 16-byte Folded Spill
	add	x29, sp, #16
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	subs	x19, x0, #2
	b.lt	LBB1_4
; %bb.1:
	mov	x8, #1                          ; =0x1
	movk	x8, #16384, lsl #48
	cmp	x0, x8
	b.hs	LBB1_5
; %bb.2:
	sub	x0, x0, #1
	bl	_fib_checked
	mov	x20, x0
	mov	x0, x19
	bl	_fib_checked
	adds	x0, x20, x0
	b.vs	LBB1_5
; %bb.3:
	mov	x8, #-4611686018427387904       ; =0xc000000000000000
	cmn	x0, x8
	b.pl	LBB1_5
LBB1_4:
	ldp	x29, x30, [sp, #16]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp], #32             ; 16-byte Folded Reload
	ret
LBB1_5:
	brk	#0x1
	.cfi_endproc
                                        ; -- End function
.subsections_via_symbols
