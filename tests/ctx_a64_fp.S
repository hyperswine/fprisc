/* ctx_a64_fp.S -- helpers for tests/ctx_a64_fp.c (tests/check_ctx_a64_fp.py).
 * Each sets d8..d15 to known values right before fpr_ctx_switch and reads
 * them right after, with no compiler code in between, and keeps AAPCS64
 * for its own C caller by saving and restoring d8..d15 itself. */
#ifdef __APPLE__
#define SYM(x) _##x
#else
#define SYM(x) x
#endif
    .text
    .balign 16
/* test_switch_with(save x0, load x1, in x2, out x3): d8..d15 = in[0..7],
 * switch, out[0..7] = d8..d15 as found when this context resumes */
    .globl SYM(test_switch_with)
SYM(test_switch_with):
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    str x3, [sp, #16]
    stp d8, d9, [sp, #32]
    stp d10, d11, [sp, #48]
    stp d12, d13, [sp, #64]
    stp d14, d15, [sp, #80]
    ldp d8, d9, [x2, #0]
    ldp d10, d11, [x2, #16]
    ldp d12, d13, [x2, #32]
    ldp d14, d15, [x2, #48]
    bl SYM(fpr_ctx_switch)
    ldr x3, [sp, #16]
    stp d8, d9, [x3, #0]
    stp d10, d11, [x3, #16]
    stp d12, d13, [x3, #32]
    stp d14, d15, [x3, #48]
    ldp d8, d9, [sp, #32]
    ldp d10, d11, [sp, #48]
    ldp d12, d13, [sp, #64]
    ldp d14, d15, [sp, #80]
    ldp x29, x30, [sp], #96
    ret
