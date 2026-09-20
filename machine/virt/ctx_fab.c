/* ctx_fab.c (virt) — fabricate a first-activation context for ctx.S:
 * ra = the trampoline, sp = the fresh stack.  tp is deliberately NOT
 * part of the context (see ctx.S): the actor runs with whatever hart
 * picks it up, so a spawn stolen before first activation still reads
 * the RIGHT fpr_hart(). */
#include "fpr.h"
void fpr_ctx_fabricate(uw *ctx, void (*entry)(void), uw stack_top16,
                       fpr_hart_t *owner) {
  (void)owner;
  ctx[0] = (uw)(uintptr_t)entry;
  ctx[1] = stack_top16;
}
