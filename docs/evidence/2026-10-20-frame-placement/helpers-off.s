# fn loop (arity 2)
    .globl _fpr_fn_loop
_fpr_fn_loop:
    sub sp, sp, #128
    stur x30, [sp, #120]
    stur x29, [sp, #112]
    add x29, sp, #128
    stur x0, [x29, #-24]
    stur x1, [x29, #-32]
    mov  x9, x28
    mov x10, sp
    ldr x11, [x9, #456]
    sub x10, x10, x11
    ldr x11, [x9, #464]
    cmp x10, x11
    b.lo Lstk61
    bl _fpr_stack_grow
    cbz x0, Lstksame62
    mov sp, x0
Lstksame62:
    mov  x9, x28
Lstk61:
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Lfuel60
    bl _fpr_fuel_exhausted
Lfuel60:
    ldur x0, [x29, #-24]
    mov x1, #1
    and x9, x0, x1
    mov x16, #1
    and x9, x9, x16
    cbz x9, Lslow51
    eor x9, x0, x1
    cmp x9, #0
    cset x9, eq
    b Ljoin52
Lslow51:
    bl _fpr_prim_fn__x3d_x3d
    ldursw x9, [x0, #4]
Ljoin52:
    cbz x9, Lelse58
    ldur x0, [x29, #-32]
    b Lendif59
Lelse58:
    ldur x0, [x29, #-24]
    mov x1, #3
    sub x9, x0, x1
    eor x10, x0, x1
    eor x9, x9, x0
    and x10, x10, x9
    asr x10, x10, #63
    cbnz x10, Lslow53
    sub x9, x0, x1
    add x0, x9, #1
    b Lfast54
Lslow53:
    bl _fpr_prim_fn__x2d
Lfast54:
    stur x0, [x29, #-40]
    ldur x0, [x29, #-24]
    mov x1, #511
    and x0, x0, x1
    mov x16, #1
    orr x0, x0, x16
    stur x0, [x29, #-72]
    ldur x0, [x29, #-32]
    mov x1, #511
    and x0, x0, x1
    mov x16, #1
    orr x0, x0, x16
    stur x0, [x29, #-80]
    mov  x9, x28
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Lvfuel55
    bl _fpr_fuel_exhausted
Lvfuel55:
    adrp x0, _fpr_unit@PAGE
    add x0, x0, _fpr_unit@PAGEOFF
    ldur x0, [x29, #-72]
    ldur x1, [x29, #-80]
    bl _fpr_fn_mix
    ldur x1, [x29, #-80]
    bl _fpr_fn_mix
    stur x0, [x29, #-64]
    ldur x0, [x29, #-32]
    ldur x1, [x29, #-64]
    sub x10, x0, #1
    add x9, x10, x1
    eor x10, x10, x9
    eor x9, x9, x1
    and x10, x10, x9
    asr x10, x10, #63
    cbnz x10, Lslow56
    sub x9, x0, #1
    add x0, x9, x1
    b Lfast57
Lslow56:
    bl _fpr_prim_fn__x2b
Lfast57:
    stur x0, [x29, #-48]
    ldur x0, [x29, #-40]
    ldur x1, [x29, #-48]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    b _fpr_fn_loop
Lendif59:
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret

# wcet: loop segmax=41 exittail=41 ccalls=4
