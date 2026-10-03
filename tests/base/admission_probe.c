#include "fpr.h"
static uw fail_phase, seen, pause_phase, queued;
static V pause_boss;
int fpr_admission_test_queue(void) { return __atomic_exchange_n(&queued, 0, __ATOMIC_RELAXED) != 0; }
int fpr_admission_test_fail(uw phase) {
  if (__atomic_load_n(&pause_phase, __ATOMIC_RELAXED) == phase) {
    __atomic_store_n(&pause_phase, 0, __ATOMIC_RELAXED);
    (void)fpr_send_as((uw)fpr_hart()->current, pause_boss, TAG((sw)phase));
    fpr_actor_sleep_us(3000000);
  }
  if (__atomic_load_n(&fail_phase, __ATOMIC_RELAXED) != phase) return 0;
  __atomic_store_n(&fail_phase, 0, __ATOMIC_RELAXED);
  __atomic_fetch_add(&seen, 1, __ATOMIC_RELAXED);
  return 1;
}
static V fail_next(V n) { __atomic_store_n(&fail_phase, (uw)UNTAG(n), __ATOMIC_RELAXED); return (V)&fpr_unit; }
static V count(V u) { (void)u; return TAG(__atomic_load_n(&seen, __ATOMIC_RELAXED)); }
FPR_FN(fpr_g_Probe_x2efailNext, fail_next, 1);
FPR_FN(fpr_g_Probe_x2edenials, count, 1);

static V pause_next(V boss, V n) {
  pause_boss = boss;
  __atomic_store_n(&pause_phase, (uw)UNTAG(n), __ATOMIC_RELAXED);
  return (V)&fpr_unit;
}
static V force_queue(V u) { (void)u; __atomic_store_n(&queued, 1, __ATOMIC_RELAXED); return (V)&fpr_unit; }
FPR_FN(fpr_g_Probe_x2epauseNext, pause_next, 2);
FPR_FN(fpr_g_Probe_x2eforceQueue, force_queue, 1);
