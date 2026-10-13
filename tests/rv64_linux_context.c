/* Linux LP64D context ABI: libc TP/GP, FP callee saves and rounding mode. */
#include "fpr.h"
#include <fenv.h>
#include <stdio.h>
#include <stdlib.h>

_Static_assert(FPR_CTX_WORDS == 29, "RV64 Linux context includes fcsr");
static uw main_ctx[FPR_CTX_WORDS], other_ctx[FPR_CTX_WORDS];
static unsigned char stack[65536] __attribute__((aligned(16)));
extern void fpr_ctx_switch(uw *, uw *);

static void other(void) {
  for (;;) {
    fesetround(FE_DOWNWARD);
    __asm__ volatile("fmv.d.x fs0, zero\nfmv.d.x fs11, zero" ::: "fs0", "fs11");
    fpr_ctx_switch(other_ctx, main_ctx);
  }
}
int main(void) {
  uw tp, gp, next_tp, next_gp;
  __asm__ volatile("mv %0, tp\nmv %1, gp" : "=r"(tp), "=r"(gp));
  other_ctx[0] = (uw)(uintptr_t)other;
  other_ctx[1] = (uw)(uintptr_t)(stack + sizeof stack);
  register double first __asm__("fs0") = 1.25;
  register double last __asm__("fs11") = 19.5;
  for (int i = 0; i < 20; ++i) {
    fesetround(FE_UPWARD);
    __asm__ volatile("" : "+f"(first), "+f"(last));
    fpr_ctx_switch(main_ctx, other_ctx);
    __asm__ volatile("" : "+f"(first), "+f"(last));
    __asm__ volatile("mv %0, tp\nmv %1, gp" : "=r"(next_tp), "=r"(next_gp));
    if (first != 1.25 || last != 19.5 || fegetround() != FE_UPWARD || tp != next_tp || gp != next_gp)
      return 1;
  }
  fesetround(FE_TONEAREST);
  puts("RV64_CONTEXT_PASS fp_registers fcsr tp gp");
  return 0;
}
