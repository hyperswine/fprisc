#include "fpr.h"
static V probe_fail(V n) { (void)n; fpr_actor_fail("probe: deliberate failure"); }
FPR_FN(fpr_g_Probe_x2efail, probe_fail, 1);
