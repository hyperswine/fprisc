# fn $worker.scalar.fib (arity 1)
_fpr_fn__x24worker_x2escalar_x2efib:
    sub sp, sp, #96
    stur x30, [sp, #88]
    stur x29, [sp, #80]
    add x29, sp, #96
    stur x0, [x29, #-24]
    mov  x9, x28
    mov x10, sp
    ldr x11, [x9, #456]
    sub x10, x10, x11
    ldr x11, [x9, #464]
    cmp x10, x11
    b.lo Lstk9
    bl _fpr_stack_grow
    cbz x0, Lstksame10
    mov sp, x0
Lstksame10:
    mov  x9, x28
Lstk9:
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Lfuel8
    bl _fpr_fuel_exhausted
Lfuel8:
    ldur x0, [x29, #-24]
    mov x1, #2
    cmp x0, x1
    cset x9, lt
    cbz x9, Lelse6
    b Lendif7
Lelse6:
    ldur x0, [x29, #-24]
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
    stur x0, [x29, #-40]
    bl _fpr_fn__x24worker_x2escalar_x2efib
    stur x0, [x29, #-32]
    ldur x0, [x29, #-24]
    mov x1, #2
    sub x9, x0, x1
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
    bl _fpr_prim_fn__x2d
    asr x0, x0, #1
LscalarDone3:
    bl _fpr_fn__x24worker_x2escalar_x2efib
    stur x0, [x29, #-40]
    ldur x0, [x29, #-32]
    ldur x1, [x29, #-40]
    add x9, x0, x1
    lsl x10, x9, #1
    asr x10, x10, #1
    cmp x10, x9
    b.ne LscalarSlow4
    mov x0, x9
    b LscalarDone5
LscalarSlow4:
    lsl x0, x0, #1
    mov x16, #1
    orr x0, x0, x16
    lsl x1, x1, #1
    mov x16, #1
    orr x1, x1, x16
    bl _fpr_prim_fn__x2b
    asr x0, x0, #1
LscalarDone5:
Lendif7:
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret

# wcet: $worker.scalar.fib segmax=20 exittail=20 ccalls=4
