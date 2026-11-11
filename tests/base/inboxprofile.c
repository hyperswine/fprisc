#include "fpr.h"
#include <stdio.h>
#include <time.h>

static struct { uw count, charge, reserve; } totals[2];
uw fpr_inbox_profile_clock(void) {
  struct timespec ts;
#ifdef CLOCK_MONOTONIC_RAW
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
#else
  clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
  return (uw)ts.tv_sec * 1000000000 + ts.tv_nsec;
}
void fpr_inbox_profile_sample(uw charge, uw reserve, int admitted) {
  __atomic_fetch_add(&totals[admitted].count, 1, __ATOMIC_RELAXED);
  __atomic_fetch_add(&totals[admitted].charge, charge, __ATOMIC_RELAXED);
  __atomic_fetch_add(&totals[admitted].reserve, reserve, __ATOMIC_RELAXED);
}
#if FPR_SENDER_CREDITS
static uw hits;
void fpr_inbox_profile_credit_hit(void) {
  __atomic_fetch_add(&hits, 1, __ATOMIC_RELAXED);
}
#endif
static V report(V unit) {
#if FPR_SENDER_CREDITS
  if (!hits || hits > totals[1].count / 2) fpr_cpanic("inboxprofile: invalid credit reuse");
  printf("prepaid admissions %lu\n", (unsigned long)hits);
#endif
  for (int i = 0; i < 2; ++i) {
    uw count = totals[i].count;
    if (count != (i ? 32 : 2016)) fpr_cpanic("inboxprofile: sample count");
    printf("%s %lu charge_ns/attempt %lu reserve_ns/attempt %lu\n",
           i ? "accepted" : "full", (unsigned long)count,
           (unsigned long)(totals[i].charge/count), (unsigned long)(totals[i].reserve/count));
  }
  return unit;
}
FPR_FN(fpr_g_profileReport, report, 1);
