/* Adversarial foreign boundary: the declared Int payload is actually a
 * young heap reference. A pending region must promote the real value. */
#include "fpr.h"
#include <string.h>

static V original;
static int opened;
static const uint8_t message[] = "survived the call region";

static V payload(V unused) {
  (void)unused;
  uw before = fpr_region_call_opens_count();
  uint8_t scratch[256] = {0};
  for (unsigned i = 0; i < 2048; ++i)
    (void)fpr_mkstr(scratch, sizeof(scratch));
  original = (V)fpr_mkstr(message, sizeof(message)-1);
  opened = fpr_region_call_opens_count() > before;
  return original;
}

static V check(V value) {
  if (!opened || value == original || ISINT(value)) return TAG(0);
  const str_t *s = (const str_t *)value;
  return TAG(s->tid == T_STR && s->len == sizeof(message)-1 &&
             !memcmp(s->bytes, message, sizeof(message)-1));
}

FPR_FN(fpr_g_Variant_x2epayload, payload, 1);
FPR_FN(fpr_g_Variant_x2echeck, check, 1);
