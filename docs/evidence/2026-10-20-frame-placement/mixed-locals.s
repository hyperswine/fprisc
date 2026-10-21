# fn mixed (arity 3)

    .globl _fpr_fn_mixed
_fpr_fn_mixed:
    sub sp, sp, #96
    stur x30, [sp, #88]
    stur x29, [sp, #80]
    add x29, sp, #96
    stur x19, [x29, #-88]
    stur x0, [x29, #-24]
    stur x1, [x29, #-32]
    stur x2, [x29, #-40]
    sub sp, sp, #16
    stp x0, x30, [sp]
    adrp x0, _fpr_posix_hart@TLVPPAGE
    ldr x0, [x0, _fpr_posix_hart@TLVPPAGEOFF]
    ldr x16, [x0]
    blr x16
    ldr x17, [x0]
    ldp x0, x30, [sp]
    add sp, sp, #16
    mov x9, x17
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Lfuel18
    bl _fpr_fuel_exhausted
Lfuel18:
    ldur x0, [x29, #-32]
    ldur x1, [x29, #-40]
    sub x10, x0, #1
    add x9, x10, x1
    eor x10, x10, x9
    eor x9, x9, x1
    and x10, x10, x9
    asr x10, x10, #63
    cbnz x10, Lslow16
    sub x9, x0, #1
    add x0, x9, x1
    b Lfast17
Lslow16:
    bl _fpr_prim_fn__x2b
Lfast17:
    mov x19, x0
    mov x1, #7
    asr x9, x0, #1
    lsl x10, x9, #33
    asr x10, x10, #33
    cmp x10, x9
    b.ne Lslow14
    asr x9, x1, #1
    lsl x10, x9, #33
    asr x10, x10, #33
    cmp x10, x9
    b.ne Lslow14
    asr x9, x0, #1
    asr x10, x1, #1
    mul x9, x9, x10
    lsl x9, x9, #1
    mov x16, #1
    orr x0, x9, x16
    b Lfast15
Lslow14:
    bl _fpr_prim_fn__x2a
Lfast15:
    mov x19, x0
    ldur x1, [x29, #-32]
    sub x9, x0, x1
    eor x10, x0, x1
    eor x9, x9, x0
    and x10, x10, x9
    asr x10, x10, #63
    cbnz x10, Lslow12
    sub x9, x0, x1
    add x0, x9, #1
    b Lfast13
Lslow12:
    bl _fpr_prim_fn__x2d
Lfast13:
    mov x19, x0
    ldur x0, [x29, #-24]
    sub sp, sp, #16
    stur x0, [sp, #0]
    mov x0, x19
    ldur x1, [x29, #-40]
    sub x10, x0, #1
    add x9, x10, x1
    eor x10, x10, x9
    eor x9, x9, x1
    and x10, x10, x9
    asr x10, x10, #63
    cbnz x10, Lslow10
    sub x9, x0, #1
    add x0, x9, x1
    b Lfast11
Lslow10:
    bl _fpr_prim_fn__x2b
Lfast11:
    sub sp, sp, #16
    stur x0, [sp, #0]
    mov x0, #24
    bl _fpr_alloc
    mov x9, #4
    stur w9, [x0, #0]
    mov x9, #0
    stur w9, [x0, #4]
    ldur x10, [sp, #0]
    add sp, sp, #16
    stur x10, [x0, #16]
    ldur x10, [sp, #0]
    add sp, sp, #16
    stur x10, [x0, #8]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x19, [x29, #-88]
    ldur x29, [x29, #-16]
    mov sp, x9
    ret

