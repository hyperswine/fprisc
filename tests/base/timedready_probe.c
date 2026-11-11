#include "fpr.h"

static V timed_ready(V me, V peer, V ticks) {
  uint64_t deadline = hal_mtime() + (uint64_t)UNTAG(ticks);
  return TAG(fpr_wait_from_until_c(me, peer, deadline));
}
FPR_FN(fpr_g_timedReady, timed_ready, 3);
