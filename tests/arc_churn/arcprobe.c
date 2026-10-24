/* Measurement-only surface for tests/arc_churn: reads the ARC table's C
 * gauges (runtime.c) and, in an FPR_COST_PROBE build, the drop ledger.
 * Linked with `fpr build --with`; not a language primitive. */
#include "fpr.h"
uw fpr_arc_cap(void);
uw fpr_arc_grows_count(void);
uw fpr_arc_compactions_count(void);
uw fpr_arc_hwm(void);
uw fpr_arc_live(void);
uw fpr_arc_used(void);
uw fpr_rx_grows_count(void);
uw fpr_rx_hwm(void);
static V cap(V u)   { (void)u; return TAG((sw)fpr_arc_cap()); }
static V grows(V u) { (void)u; return TAG((sw)fpr_arc_grows_count()); }
static V compactions(V u) { (void)u; return TAG((sw)fpr_arc_compactions_count()); }
static V hwm(V u)   { (void)u; return TAG((sw)fpr_arc_hwm()); }
static V live(V u)  { (void)u; return TAG((sw)fpr_arc_live()); }
static V used(V u)  { (void)u; return TAG((sw)fpr_arc_used()); }
static V rxGrows(V u) { (void)u; return TAG((sw)fpr_rx_grows_count()); }
static V rxHwm(V u) { (void)u; return TAG((sw)fpr_rx_hwm()); }
static uw drops(int hit) {
  uw n = 0;
#ifdef FPR_COST_PROBE
  for (uw i = 0; i < fpr_live_harts; i++) {
    fpr_hart_t *h = &fpr_harts[i];
    n += hit ? __atomic_load_n(&h->xr_drop_hit_n, __ATOMIC_RELAXED)
             : __atomic_load_n(&h->xr_drop_miss_n, __ATOMIC_RELAXED);
  }
#else
  (void)hit;
#endif
  return n;
}
static V dropHits(V u)   { (void)u; return TAG((sw)drops(1)); }
static V dropMisses(V u) { (void)u; return TAG((sw)drops(0)); }
FPR_FN(fpr_g_Arc_x2ecap, cap, 1);
FPR_FN(fpr_g_Arc_x2egrows, grows, 1);
FPR_FN(fpr_g_Arc_x2ecompactions, compactions, 1);
FPR_FN(fpr_g_Arc_x2ehwm, hwm, 1);
FPR_FN(fpr_g_Arc_x2elive, live, 1);
FPR_FN(fpr_g_Arc_x2eused, used, 1);
FPR_FN(fpr_g_Arc_x2erxGrows, rxGrows, 1);
FPR_FN(fpr_g_Arc_x2erxHwm, rxHwm, 1);
FPR_FN(fpr_g_Arc_x2edropHits, dropHits, 1);
FPR_FN(fpr_g_Arc_x2edropMisses, dropMisses, 1);
