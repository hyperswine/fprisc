#include "fpr.h"
static unsigned released;
static void cleanup(void *p) { (void)p; __atomic_fetch_add(&released, 1, __ATOMIC_RELAXED); }
static V reg(V u) { (void)u; if (!fpr_actor_cleanup_set(cleanup, &released)) fpr_cpanic("cleanup: no actor"); return (V)&fpr_unit; }
static V clear(V u) { (void)u; fpr_actor_cleanup_clear(&released); return (V)&fpr_unit; }
static V count(V u) { (void)u; return TAG(__atomic_load_n(&released,__ATOMIC_RELAXED)); }
FPR_FN(fpr_g_Probe_x2eregister,reg,1);
FPR_FN(fpr_g_Probe_x2eclear,clear,1);
FPR_FN(fpr_g_Probe_x2ecount,count,1);
