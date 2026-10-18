/* Independent byte/layout and allocation check; linked only by the test. */
#include "fpr.h"
extern V fpr_g_chr_call1(V);
static V validate(V unit) {
  (void)unit;
#ifndef FPR_COST_PROBE
#error bytestrings test needs FPR_COST_PROBE
#endif
  fpr_hart_t *h = fpr_hart();
  uint64_t before = h->cost_alloc_requests;
  for (unsigned round = 0; round < 4; round++) {
    for (unsigned byte = 0; byte < 256; byte++) {
      str_t *s = (str_t *)fpr_g_chr_call1(TAG(byte));
      if (s->tid != T_STR || s->var != 0 || s->len != 1 || s->bytes[0] != byte)
        fpr_cpanic("byte String: invalid value");
    }
  }
  return BOOL(h->cost_alloc_requests == before);
}
static V invalid(V unit) {
  /* Deliberately bypass the type checker to verify the primitive's guard. */
  (void)unit;
  return fpr_g_chr_call1(fpr_g_chr_call1(TAG(65)));
}
FPR_FN(fpr_g_ByteProbe_x2evalidate, validate, 1);
FPR_FN(fpr_g_ByteProbe_x2einvalid, invalid, 1);
