#include "fpr.h"
static V armed_target, armed_boss;
static uw armed_phase;
static V arm(V target, V boss, V phase) {
  armed_target = target; armed_boss = boss;
  __atomic_store_n(&armed_phase, (uw)UNTAG(phase), __ATOMIC_RELEASE);
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Inbox_x2earm, arm, 3);
void fpr_inbox_test_phase(uw phase, V target) {
  if (target != armed_target) return;
  uw expected = phase;
  if (!__atomic_compare_exchange_n(&armed_phase, &expected, 0, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return;
  if (!fpr_sent(fpr_send_as((uw)fpr_hart()->current, armed_boss, TAG((sw)phase))))
    fpr_cpanic("inbox probe: event refused");
  fpr_actor_sleep_us(100000);
}
static V address(V value) { return TAG((sw)value); }
FPR_FN(fpr_g_Inbox_x2eaddress, address, 1);
