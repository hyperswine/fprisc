/* ctx.S (esp-idf) -- the actor context switch for ESP32-P4 (rv32imafc, ilp32f).
 *
 * void fpr_ctx_switch(uintptr_t *save, uintptr_t *load);
 *
 * machine/virt/ctx.S, plus the float registers: under the ilp32f ABI that
 * ESP-IDF compiles with, fs0..fs11 are callee-saved, so C that called the
 * switch expects them back.  Word layout: 0 ra | 1 sp | 2 gp | 3 unused |
 * 4..15 s0..s11 | 16..27 fs0..fs11 (FPR_CTX_WORDS = 28).  tp is the running
 * hart's identity and is never saved (see machine/virt/ctx.S).  Nor is gp:
 * it is IDF's global pointer -- code reaches globals relative to it -- and
 * the same in every context.  Restoring it is not harmless: a fabricated
 * first context has none (ctx_fab.c sets ra and sp), so a new actor started
 * with gp = 0, every gp-relative global read landed near address 0, and the
 * panic handler, reading the same way, could not even say so: the chip just
 * reset by watchdog. */
    .text
    .balign 4
    .globl fpr_ctx_switch
fpr_ctx_switch:
    sw ra,    0*4(a0)
    sw sp,    1*4(a0)
    sw s0,    4*4(a0)
    sw s1,    5*4(a0)
    sw s2,    6*4(a0)
    sw s3,    7*4(a0)
    sw s4,    8*4(a0)
    sw s5,    9*4(a0)
    sw s6,   10*4(a0)
    sw s7,   11*4(a0)
    sw s8,   12*4(a0)
    sw s9,   13*4(a0)
    sw s10,  14*4(a0)
    sw s11,  15*4(a0)
#if defined(__riscv_flen) && __riscv_flen >= 32
    fsw fs0,  16*4(a0)
    fsw fs1,  17*4(a0)
    fsw fs2,  18*4(a0)
    fsw fs3,  19*4(a0)
    fsw fs4,  20*4(a0)
    fsw fs5,  21*4(a0)
    fsw fs6,  22*4(a0)
    fsw fs7,  23*4(a0)
    fsw fs8,  24*4(a0)
    fsw fs9,  25*4(a0)
    fsw fs10, 26*4(a0)
    fsw fs11, 27*4(a0)
    flw fs0,  16*4(a1)
    flw fs1,  17*4(a1)
    flw fs2,  18*4(a1)
    flw fs3,  19*4(a1)
    flw fs4,  20*4(a1)
    flw fs5,  21*4(a1)
    flw fs6,  22*4(a1)
    flw fs7,  23*4(a1)
    flw fs8,  24*4(a1)
    flw fs9,  25*4(a1)
    flw fs10, 26*4(a1)
    flw fs11, 27*4(a1)
#endif
    lw ra,    0*4(a1)
    lw sp,    1*4(a1)
    lw s0,    4*4(a1)
    lw s1,    5*4(a1)
    lw s2,    6*4(a1)
    lw s3,    7*4(a1)
    lw s4,    8*4(a1)
    lw s5,    9*4(a1)
    lw s6,   10*4(a1)
    lw s7,   11*4(a1)
    lw s8,   12*4(a1)
    lw s9,   13*4(a1)
    lw s10,  14*4(a1)
    lw s11,  15*4(a1)
    ret
