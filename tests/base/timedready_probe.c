#include "fpr.h"

static V timed_ready(V me, V peer, V ticks) {
  uint64_t deadline = hal_mtime() + (uint64_t)UNTAG(ticks);
  return TAG(fpr_wait_from_until_c(me, peer, deadline));
}
FPR_FN(fpr_g_timedReady, timed_ready, 3);

static V timed_any(V me, V ticks) {
  uint64_t deadline = hal_mtime() + (uint64_t)UNTAG(ticks);
  return TAG(fpr_wait_any_until_c(me, deadline));
}
FPR_FN(fpr_g_timedAny, timed_any, 2);
