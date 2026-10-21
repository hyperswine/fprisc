/* The C side of the M2 interoperability fixture (tests/typed_ir/scalarlib.fpr,
 * scalar_mod.fpr): native functions call back into C through TirProbe.cb
 * and TirProbe.mark; C calls native functions directly through the
 * function values the root hands TirProbe.call1/call2 (a static PAP whose
 * code pointer is the generated entry: tagged words in x0.., the result
 * in x0, the generated-code ABI the legacy generator uses too). */
#include "fpr.h"
#include <stdint.h>

/* cb n = 2n + 1, observable in the native caller's result */
static V cb(V n) { return TAG(UNTAG(n) * 2 + 1); }

/* every level of a deep recursion marks the stack segment it runs in */
static void *segs[64];
static unsigned nsegs;
static V mark(V n) {
  (void)n;
  uw id, size;
  void *lo = fpr_current_stack(&id, &size);
  unsigned i;
  for (i = 0; i < nsegs; i++) if (segs[i] == lo) break;
  if (i == nsegs && nsegs < 64) segs[nsegs++] = lo;
  return TAG(1);
}
static V segments(V unit) { (void)unit; return TAG((sw)nsegs); }

static V call1(V fn, V a) {
  pap_t *p = (pap_t *)fn;
  return ((V (*)(V))(uintptr_t)p->fn)(a);
}
static V call2(V fn, V a, V b) {
  pap_t *p = (pap_t *)fn;
  return ((V (*)(V, V))(uintptr_t)p->fn)(a, b);
}

FPR_FN(fpr_g_TirProbe_x2ecb, cb, 1);
FPR_FN(fpr_g_TirProbe_x2emark, mark, 1);
FPR_FN(fpr_g_TirProbe_x2esegments, segments, 1);
FPR_FN(fpr_g_TirProbe_x2ecall1, call1, 2);
FPR_FN(fpr_g_TirProbe_x2ecall2, call2, 3);
