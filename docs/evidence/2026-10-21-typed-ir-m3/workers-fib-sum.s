### fib legacy (fib-55016.s)
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

### fib legacy-best (fib-55260.s)
# fn $worker.scalar.fib (arity 1)
_fpr_fn__x24worker_x2escalar_x2efib:
    sub sp, sp, #48
    stp x29, x30, [sp, #32]
    add x29, sp, #48
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
    mov x9, x29
    ldp x29, x30, [x9, #-16]
    mov sp, x9
    ret

# wcet: $worker.scalar.fib segmax=20 exittail=20 ccalls=4

### fib typed-ir (fib-55551.s)
# fn $worker.scalar.fib (arity 1) typed-ir a64 frame=32 saved=x19,x20 values=31 regs=31 spills=0 slots=0 reloads=0 stores=0 copies=9 crossing=2 loops=0
_fpr_fn__x24worker_x2escalar_x2efib:
    sub sp, sp, #32
    stur x30, [sp, #24]
    stur x29, [sp, #16]
    add x29, sp, #32
    stp x20, x19, [x29, #-32]
    mov x19, x0
Ltir__x24worker_x2escalar_x2efib_b0:
    mov x9, x28
    mov x10, sp
    ldr x11, [x9, #456]
    sub x10, x10, x11
    ldr x11, [x9, #464]
    cmp x10, x11
    b.lo Ltir__x24worker_x2escalar_x2efib_entry0_stk
    bl _fpr_stack_grow
    cbz x0, Ltir__x24worker_x2escalar_x2efib_entry0_same
    mov sp, x0
Ltir__x24worker_x2escalar_x2efib_entry0_same:
    mov x9, x28
Ltir__x24worker_x2escalar_x2efib_entry0_stk:
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Ltir__x24worker_x2escalar_x2efib_entry0_fuel
    bl _fpr_fuel_exhausted
Ltir__x24worker_x2escalar_x2efib_entry0_fuel:
    mov x9, #2
    cmp x19, x9
    cset x9, lt
    cbnz x9, Ltir__x24worker_x2escalar_x2efib_b1
    b Ltir__x24worker_x2escalar_x2efib_b2
Ltir__x24worker_x2escalar_x2efib_b1:
    mov x0, x19
    ldp x20, x19, [x29, #-32]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret
Ltir__x24worker_x2escalar_x2efib_b2:
    mov x9, #1
    sub x10, x19, x9
    sbfx x11, x10, #0, #63
    cmp x11, x10
    b.ne Ltir__x24worker_x2escalar_x2efib_slow1
    mov x0, x10
    b Ltir__x24worker_x2escalar_x2efib_done2
Ltir__x24worker_x2escalar_x2efib_slow1:
    lsl x10, x19, #1
    orr x10, x10, #1
    lsl x9, x9, #1
    orr x1, x9, #1
    mov x0, x10
    bl _fpr_prim_fn__x2d
    mov x9, x0
    asr x0, x9, #1
Ltir__x24worker_x2escalar_x2efib_done2:
    bl _fpr_fn__x24worker_x2escalar_x2efib
    mov x20, x0
    mov x9, #2
    sub x10, x19, x9
    sbfx x11, x10, #0, #63
    cmp x11, x10
    b.ne Ltir__x24worker_x2escalar_x2efib_slow3
    mov x0, x10
    b Ltir__x24worker_x2escalar_x2efib_done4
Ltir__x24worker_x2escalar_x2efib_slow3:
    lsl x10, x19, #1
    orr x10, x10, #1
    lsl x9, x9, #1
    orr x1, x9, #1
    mov x0, x10
    bl _fpr_prim_fn__x2d
    mov x9, x0
    asr x0, x9, #1
Ltir__x24worker_x2escalar_x2efib_done4:
    bl _fpr_fn__x24worker_x2escalar_x2efib
    add x9, x20, x0
    sbfx x10, x9, #0, #63
    cmp x10, x9
    b.ne Ltir__x24worker_x2escalar_x2efib_slow5
    b Ltir__x24worker_x2escalar_x2efib_done6
Ltir__x24worker_x2escalar_x2efib_slow5:
    lsl x10, x20, #1
    orr x10, x10, #1
    lsl x11, x0, #1
    orr x1, x11, #1
    mov x0, x10
    bl _fpr_prim_fn__x2b
    asr x9, x0, #1
Ltir__x24worker_x2escalar_x2efib_done6:
    mov x0, x9
    ldp x20, x19, [x29, #-32]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret
# native-insns-v1: $worker.scalar.fib segmax=23 exittail=18 ccalls=4

### fib typed-ir-noloop (fib-55799.s)
# fn $worker.scalar.fib (arity 1) typed-ir a64 frame=32 saved=x19,x20 values=31 regs=31 spills=0 slots=0 reloads=0 stores=0 copies=9 crossing=2 loops=0
_fpr_fn__x24worker_x2escalar_x2efib:
    sub sp, sp, #32
    stur x30, [sp, #24]
    stur x29, [sp, #16]
    add x29, sp, #32
    stp x20, x19, [x29, #-32]
    mov x19, x0
Ltir__x24worker_x2escalar_x2efib_b0:
    mov x9, x28
    mov x10, sp
    ldr x11, [x9, #456]
    sub x10, x10, x11
    ldr x11, [x9, #464]
    cmp x10, x11
    b.lo Ltir__x24worker_x2escalar_x2efib_entry0_stk
    bl _fpr_stack_grow
    cbz x0, Ltir__x24worker_x2escalar_x2efib_entry0_same
    mov sp, x0
Ltir__x24worker_x2escalar_x2efib_entry0_same:
    mov x9, x28
Ltir__x24worker_x2escalar_x2efib_entry0_stk:
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Ltir__x24worker_x2escalar_x2efib_entry0_fuel
    bl _fpr_fuel_exhausted
Ltir__x24worker_x2escalar_x2efib_entry0_fuel:
    mov x9, #2
    cmp x19, x9
    cset x9, lt
    cbnz x9, Ltir__x24worker_x2escalar_x2efib_b1
    b Ltir__x24worker_x2escalar_x2efib_b2
Ltir__x24worker_x2escalar_x2efib_b1:
    mov x0, x19
    ldp x20, x19, [x29, #-32]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret
Ltir__x24worker_x2escalar_x2efib_b2:
    mov x9, #1
    sub x10, x19, x9
    sbfx x11, x10, #0, #63
    cmp x11, x10
    b.ne Ltir__x24worker_x2escalar_x2efib_slow1
    mov x0, x10
    b Ltir__x24worker_x2escalar_x2efib_done2
Ltir__x24worker_x2escalar_x2efib_slow1:
    lsl x10, x19, #1
    orr x10, x10, #1
    lsl x9, x9, #1
    orr x1, x9, #1
    mov x0, x10
    bl _fpr_prim_fn__x2d
    mov x9, x0
    asr x0, x9, #1
Ltir__x24worker_x2escalar_x2efib_done2:
    bl _fpr_fn__x24worker_x2escalar_x2efib
    mov x20, x0
    mov x9, #2
    sub x10, x19, x9
    sbfx x11, x10, #0, #63
    cmp x11, x10
    b.ne Ltir__x24worker_x2escalar_x2efib_slow3
    mov x0, x10
    b Ltir__x24worker_x2escalar_x2efib_done4
Ltir__x24worker_x2escalar_x2efib_slow3:
    lsl x10, x19, #1
    orr x10, x10, #1
    lsl x9, x9, #1
    orr x1, x9, #1
    mov x0, x10
    bl _fpr_prim_fn__x2d
    mov x9, x0
    asr x0, x9, #1
Ltir__x24worker_x2escalar_x2efib_done4:
    bl _fpr_fn__x24worker_x2escalar_x2efib
    add x9, x20, x0
    sbfx x10, x9, #0, #63
    cmp x10, x9
    b.ne Ltir__x24worker_x2escalar_x2efib_slow5
    b Ltir__x24worker_x2escalar_x2efib_done6
Ltir__x24worker_x2escalar_x2efib_slow5:
    lsl x10, x20, #1
    orr x10, x10, #1
    lsl x11, x0, #1
    orr x1, x11, #1
    mov x0, x10
    bl _fpr_prim_fn__x2b
    asr x9, x0, #1
Ltir__x24worker_x2escalar_x2efib_done6:
    mov x0, x9
    ldp x20, x19, [x29, #-32]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret
# native-insns-v1: $worker.scalar.fib segmax=23 exittail=18 ccalls=4

### sum legacy (sum-55032.s)
# fn $worker.scalar.loop (arity 2)
_fpr_fn__x24worker_x2escalar_x2eloop:
    sub sp, sp, #80
    stur x30, [sp, #72]
    stur x29, [sp, #64]
    add x29, sp, #80
    stur x0, [x29, #-24]
    stur x1, [x29, #-32]
    mov  x9, x28
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Lfuel6
    bl _fpr_fuel_exhausted
Lfuel6:
    ldur x0, [x29, #-24]
    mov x1, #0
    eor x9, x0, x1
    cmp x9, #0
    cset x9, eq
    cbz x9, Lelse4
    ldur x0, [x29, #-32]
    b Lendif5
Lelse4:
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
    ldur x0, [x29, #-32]
    ldur x1, [x29, #-24]
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
    stur x0, [x29, #-48]
    ldur x0, [x29, #-40]
    ldur x1, [x29, #-48]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    b _fpr_fn__x24worker_x2escalar_x2eloop
Lendif5:
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret

# wcet: $worker.scalar.loop segmax=43 exittail=43 ccalls=2

### sum legacy-best (sum-55276.s)
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

### sum typed-ir (sum-55567.s)
# fn $worker.scalar.loop (arity 2) typed-ir a64 frame=48 saved=x19,x20,x21 values=21 regs=21 spills=0 slots=0 reloads=0 stores=0 copies=3 crossing=3 loops=1
_fpr_fn__x24worker_x2escalar_x2eloop:
    sub sp, sp, #48
    stur x30, [sp, #40]
    stur x29, [sp, #32]
    add x29, sp, #48
    stp x20, x19, [x29, #-32]
    stur x21, [x29, #-40]
    mov x19, x0
    mov x20, x1
Ltir__x24worker_x2escalar_x2eloop_b0:
    mov x9, x28
    mov x10, sp
    ldr x11, [x9, #456]
    sub x10, x10, x11
    ldr x11, [x9, #464]
    cmp x10, x11
    b.lo Ltir__x24worker_x2escalar_x2eloop_entry0_stk
    bl _fpr_stack_grow
    cbz x0, Ltir__x24worker_x2escalar_x2eloop_entry0_same
    mov sp, x0
Ltir__x24worker_x2escalar_x2eloop_entry0_same:
    mov x9, x28
Ltir__x24worker_x2escalar_x2eloop_entry0_stk:
Ltir__x24worker_x2escalar_x2eloop_m3loop:
    mov x9, x28
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Ltir__x24worker_x2escalar_x2eloop_entry0_fuel
    bl _fpr_fuel_exhausted
Ltir__x24worker_x2escalar_x2eloop_entry0_fuel:
    mov x9, #0
    cmp x19, x9
    cset x9, eq
    cbnz x9, Ltir__x24worker_x2escalar_x2eloop_b1
    b Ltir__x24worker_x2escalar_x2eloop_b2
Ltir__x24worker_x2escalar_x2eloop_b1:
    mov x0, x20
    ldp x20, x19, [x29, #-32]
    ldur x21, [x29, #-40]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret
Ltir__x24worker_x2escalar_x2eloop_b2:
    mov x9, #1
    sub x10, x19, x9
    sbfx x11, x10, #0, #63
    cmp x11, x10
    b.ne Ltir__x24worker_x2escalar_x2eloop_slow1
    mov x21, x10
    b Ltir__x24worker_x2escalar_x2eloop_done2
Ltir__x24worker_x2escalar_x2eloop_slow1:
    lsl x10, x19, #1
    orr x0, x10, #1
    lsl x9, x9, #1
    orr x1, x9, #1
    bl _fpr_prim_fn__x2d
    asr x21, x0, #1
Ltir__x24worker_x2escalar_x2eloop_done2:
    add x9, x20, x19
    sbfx x10, x9, #0, #63
    cmp x10, x9
    b.ne Ltir__x24worker_x2escalar_x2eloop_slow3
    b Ltir__x24worker_x2escalar_x2eloop_done4
Ltir__x24worker_x2escalar_x2eloop_slow3:
    lsl x10, x20, #1
    orr x0, x10, #1
    lsl x10, x19, #1
    orr x1, x10, #1
    bl _fpr_prim_fn__x2b
    asr x9, x0, #1
Ltir__x24worker_x2escalar_x2eloop_done4:
    mov x19, x21
    mov x20, x9
    b Ltir__x24worker_x2escalar_x2eloop_m3loop
# native-insns-v1: $worker.scalar.loop segmax=36 exittail=12 ccalls=3

### sum typed-ir-noloop (sum-55815.s)
# fn $worker.scalar.loop (arity 2) typed-ir a64 frame=48 saved=x19,x20,x21 values=21 regs=21 spills=0 slots=0 reloads=0 stores=0 copies=5 crossing=3 loops=0
_fpr_fn__x24worker_x2escalar_x2eloop:
    sub sp, sp, #48
    stur x30, [sp, #40]
    stur x29, [sp, #32]
    add x29, sp, #48
    stp x20, x19, [x29, #-32]
    stur x21, [x29, #-40]
    mov x20, x0
    mov x19, x1
Ltir__x24worker_x2escalar_x2eloop_b0:
    mov x9, x28
    mov x10, sp
    ldr x11, [x9, #456]
    sub x10, x10, x11
    ldr x11, [x9, #464]
    cmp x10, x11
    b.lo Ltir__x24worker_x2escalar_x2eloop_entry0_stk
    bl _fpr_stack_grow
    cbz x0, Ltir__x24worker_x2escalar_x2eloop_entry0_same
    mov sp, x0
Ltir__x24worker_x2escalar_x2eloop_entry0_same:
    mov x9, x28
Ltir__x24worker_x2escalar_x2eloop_entry0_stk:
    ldur x10, [x9, #0]
    sub x10, x10, #1
    stur x10, [x9, #0]
    cmp x10, #0
    b.gt Ltir__x24worker_x2escalar_x2eloop_entry0_fuel
    bl _fpr_fuel_exhausted
Ltir__x24worker_x2escalar_x2eloop_entry0_fuel:
    mov x9, #0
    cmp x20, x9
    cset x9, eq
    cbnz x9, Ltir__x24worker_x2escalar_x2eloop_b1
    b Ltir__x24worker_x2escalar_x2eloop_b2
Ltir__x24worker_x2escalar_x2eloop_b1:
    mov x0, x19
    ldp x20, x19, [x29, #-32]
    ldur x21, [x29, #-40]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    ret
Ltir__x24worker_x2escalar_x2eloop_b2:
    mov x9, #1
    sub x10, x20, x9
    sbfx x11, x10, #0, #63
    cmp x11, x10
    b.ne Ltir__x24worker_x2escalar_x2eloop_slow1
    mov x21, x10
    b Ltir__x24worker_x2escalar_x2eloop_done2
Ltir__x24worker_x2escalar_x2eloop_slow1:
    lsl x10, x20, #1
    orr x0, x10, #1
    lsl x9, x9, #1
    orr x1, x9, #1
    bl _fpr_prim_fn__x2d
    asr x21, x0, #1
Ltir__x24worker_x2escalar_x2eloop_done2:
    add x9, x19, x20
    sbfx x10, x9, #0, #63
    cmp x10, x9
    b.ne Ltir__x24worker_x2escalar_x2eloop_slow3
    mov x1, x9
    b Ltir__x24worker_x2escalar_x2eloop_done4
Ltir__x24worker_x2escalar_x2eloop_slow3:
    lsl x9, x19, #1
    orr x0, x9, #1
    lsl x9, x20, #1
    orr x9, x9, #1
    mov x1, x9
    bl _fpr_prim_fn__x2b
    asr x1, x0, #1
Ltir__x24worker_x2escalar_x2eloop_done4:
    mov x0, x21
    ldp x20, x19, [x29, #-32]
    ldur x21, [x29, #-40]
    ldur x30, [x29, #-8]
    mov x9, x29
    ldur x29, [x29, #-16]
    mov sp, x9
    b _fpr_fn__x24worker_x2escalar_x2eloop
# native-insns-v1: $worker.scalar.loop segmax=35 exittail=12 ccalls=3

