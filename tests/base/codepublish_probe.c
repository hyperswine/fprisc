#include "fpr.h"
static uw fences[FPR_NHARTS], required;
/* Instrument the platform operation: test the dispatch protocol, even on
 * hosts whose instruction and data caches are coherent. */
void fpr_instruction_fence(void) {
  __atomic_add_fetch(&fences[fpr_hart()->id], 1, __ATOMIC_RELAXED);
}
static V publish(V u) {
  (void)u;
  required = __atomic_load_n(&fences[1], __ATOMIC_RELAXED) + 1;
  fpr_code_publish();
  return TAG(0);
}
static V check(V u) {
  (void)u;
  return TAG(__atomic_load_n(&fences[1], __ATOMIC_RELAXED) >= required);
}
FPR_FN(fpr_g_Probe_x2epublish, publish, 1);
FPR_FN(fpr_g_Probe_x2echeck, check, 1);
