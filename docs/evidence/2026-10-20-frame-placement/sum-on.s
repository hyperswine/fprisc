# fn $worker.scalar.loop (arity 2)
_fpr_fn__x24worker_x2escalar_x2eloop:
    sub sp, sp, #48
    stp x29, x30, [sp, #32]
    add x29, sp, #48
    stur x19, [x29, #-48]
Lself6:
    mov x19, x0
    stur x1, [x29, #-24]
    mov  x9, x28
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Lfuel7
    bl _fpr_fuel_exhausted
Lfuel7:
    mov x0, x19
    mov x1, #0
    eor x9, x0, x1
    cmp x9, #0
    cset x9, eq
    cbz x9, Lelse4
    ldur x0, [x29, #-24]
    b Lendif5
Lelse4:
    mov x0, x19
    mov x1, #1
    sub x9, x0, x1
    lsl x10, x9, #1
    asr x10, x10, #1
    cmp x10, x9
    b.ne LscalarSlow0
    mov x0, x9
    b LscalarDone1
LscalarSlow0:
    lsl x0, x0, #1
    mov x16, #1
    orr x0, x0, x16
    lsl x1, x1, #1
    mov x16, #1
    orr x1, x1, x16
    bl _fpr_prim_fn__x2d
    asr x0, x0, #1
LscalarDone1:
    stur x0, [x29, #-32]
    ldur x0, [x29, #-24]
    mov x1, x19
    add x9, x0, x1
    lsl x10, x9, #1
    asr x10, x10, #1
    cmp x10, x9
    b.ne LscalarSlow2
    mov x0, x9
    b LscalarDone3
LscalarSlow2:
    lsl x0, x0, #1
    mov x16, #1
    orr x0, x0, x16
    lsl x1, x1, #1
    mov x16, #1
    orr x1, x1, x16
    bl _fpr_prim_fn__x2b
    asr x0, x0, #1
LscalarDone3:
    stur x0, [x29, #-40]
    ldur x0, [x29, #-32]
    ldur x1, [x29, #-40]
    b Lself6
Lendif5:
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x19, [x29, #-48]
    ldur x29, [x29, #-16]
    mov sp, x9
    ret

# wcet: $worker.scalar.loop segmax=39 exittail=39 ccalls=2
