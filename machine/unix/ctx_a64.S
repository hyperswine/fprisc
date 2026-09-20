/* ctx_a64.S — fpr_ctx_switch for AArch64 AAPCS64.  x0=save x1=load.
 * Layout: 0 = resume pc, 1 = sp, 4..12 = x19..x27, 14 = x29 (slot 13
 * is padding); d8-d15 are deliberately NOT saved (ctx[] is 16 words;
 * the runtime's switch paths do no FP, matching virt ctx.S's
 * integer-only contract).
 *
 * x28 is DELIBERATELY NOT in the frame: under the QOS-app
 * convention x28 is the hosted world's tp -- the hart pointer, set
 * once per hart thread by fpr_set_tp and never a per-context value.
 * Not saving it is what makes it survive actor switches AND cross-
 * hart migration with the current hart's value, exactly the way tp
 * behaves on bare metal.  (Generated code never allocates x28 -- the
 * IR map is x19..x27 + x29 -- and app C compiles with -ffixed-x28.) */
#ifdef __APPLE__
#define SYM(x) _##x
#else
#define SYM(x) x
#endif
    .text
    .balign 16
    .globl SYM(fpr_ctx_switch)
SYM(fpr_ctx_switch):
    mov x9, sp
    str x30, [x0, #0]          // resume pc: our return address
    str x9,  [x0, #8]
    stp x19, x20, [x0, #32]
    stp x21, x22, [x0, #48]
    stp x23, x24, [x0, #64]
    stp x25, x26, [x0, #80]
    str x27, [x0, #96]         // x28 stays live: it is the hart register
    str x29, [x0, #112]

    ldr x9,  [x1, #8]
    mov sp, x9
    ldp x19, x20, [x1, #32]
    ldp x21, x22, [x1, #48]
    ldp x23, x24, [x1, #64]
    ldp x25, x26, [x1, #80]
    ldr x27, [x1, #96]         // x28 stays live: it is the hart register
    ldr x29, [x1, #112]
    ldr x30, [x1, #0]
    ret
