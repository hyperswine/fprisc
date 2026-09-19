/* ctx.S — cooperative context switch for actors.
 *
 * void fpr_ctx_switch(uintptr_t *save, uintptr_t *load);
 *
 * Saves the callee-saved machine state of the CALLER into `save` and
 * resumes whoever previously saved into `load` (or a freshly fabricated
 * context whose ra points at the actor trampoline). Only callee-saved
 * state needs to move: from C's point of view this is just a function
 * call that happens to return on a different stack.
 *
 * Layout (WORD indices):  0 ra | 1 sp | 2 gp | 3 (unused) | 4..15 s0..s11
 * Word size follows XLEN (asm.h), matching the uintptr_t ctx[16] in
 * actors.c on both rv32 and rv64.
 *
 * tp is NOT actor state and is neither saved nor restored: it is the
 * RUNNING HART's identity (set once per hart by fpr_set_tp), the same
 * discipline x28 gets on the a64 tier and TLS on posix.  Restoring a
 * saved tp broke migration: an actor donated to another hart resumed
 * with its OLD hart's pointer and read that hart's current/fuel --
 * the stolen actor was effectively impersonating whatever the old
 * hart happened to be running.  (The legacy nested-process world
 * repoints tp around its whole nested scheduler via fpr_set_tp, which
 * composes fine: within either world tp is invariant.)
 */
#include "asm.h"
    .text
    .balign 4
    .globl fpr_ctx_switch
fpr_ctx_switch:
    REG_S ra,   0*WSZ(a0)
    REG_S sp,   1*WSZ(a0)
    REG_S gp,   2*WSZ(a0)
    REG_S s0,   4*WSZ(a0)
    REG_S s1,   5*WSZ(a0)
    REG_S s2,   6*WSZ(a0)
    REG_S s3,   7*WSZ(a0)
    REG_S s4,   8*WSZ(a0)
    REG_S s5,   9*WSZ(a0)
    REG_S s6,  10*WSZ(a0)
    REG_S s7,  11*WSZ(a0)
    REG_S s8,  12*WSZ(a0)
    REG_S s9,  13*WSZ(a0)
    REG_S s10, 14*WSZ(a0)
    REG_S s11, 15*WSZ(a0)

    REG_L ra,   0*WSZ(a1)
    REG_L sp,   1*WSZ(a1)
    REG_L gp,   2*WSZ(a1)
    REG_L s0,   4*WSZ(a1)
    REG_L s1,   5*WSZ(a1)
    REG_L s2,   6*WSZ(a1)
    REG_L s3,   7*WSZ(a1)
    REG_L s4,   8*WSZ(a1)
    REG_L s5,   9*WSZ(a1)
    REG_L s6,  10*WSZ(a1)
    REG_L s7,  11*WSZ(a1)
    REG_L s8,  12*WSZ(a1)
    REG_L s9,  13*WSZ(a1)
    REG_L s10, 14*WSZ(a1)
    REG_L s11, 15*WSZ(a1)
    ret
