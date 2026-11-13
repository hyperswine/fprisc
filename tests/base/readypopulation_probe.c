#include "fpr.h"
#include <stdlib.h>
#ifdef FPR_COST_PROBE
#include <stdio.h>
#endif

static unsigned arrived, finished;
static unsigned char completed[1024];
static int population;
static V population_size(V ignored) {
  (void)ignored;
  const char *value = getenv("FPR_TEST_POPULATION");
  int n = value ? atoi(value) : 32;
  if (n < 1 || n > 1024) fpr_cpanic("invalid test population");
  population = n;
  return TAG(n);
}
static V arrive(V ignored) {
  (void)ignored;
  __atomic_add_fetch(&arrived, 1, __ATOMIC_RELEASE);
  return (V)&fpr_unit;
}
static V ready(V ignored) {
  (void)ignored;
  return TAG(__atomic_load_n(&arrived, __ATOMIC_ACQUIRE));
}
static V finish(V ticket) {
  sw id = UNTAG(ticket);
  if (id < 1 || id > population || __atomic_exchange_n(&completed[id - 1], 1, __ATOMIC_RELAXED))
    fpr_cpanic("invalid or duplicate worker completion");
  __atomic_add_fetch(&finished, 1, __ATOMIC_RELEASE);
  return (V)&fpr_unit;
}
static V done(V ignored) {
  (void)ignored;
  return TAG(__atomic_load_n(&finished, __ATOMIC_ACQUIRE));
}
FPR_FN(fpr_g_Population_x2esize, population_size, 1);
FPR_FN(fpr_g_Population_x2earrive, arrive, 1);
FPR_FN(fpr_g_Population_x2eready, ready, 1);
FPR_FN(fpr_g_Population_x2efinish, finish, 1);
FPR_FN(fpr_g_Population_x2edone, done, 1);

static V report(V ignored) {
#ifdef FPR_COST_PROBE
  uint64_t count, select_ns, clock_ns;
  fpr_scheduler_costs(&count, &select_ns, &clock_ns);
  uint64_t entries, held_ns;
  fpr_scheduler_scan_costs(&entries, &held_ns);
  printf("scheduler profile: admissions=%llu select_ns=%llu clock_ns=%llu scanned=%llu lock_ns=%llu\n",
         (unsigned long long)count, (unsigned long long)select_ns, (unsigned long long)clock_ns,
         (unsigned long long)entries, (unsigned long long)held_ns);
#endif
  return ignored;
}
FPR_FN(fpr_g_Population_x2ereport, report, 1);
