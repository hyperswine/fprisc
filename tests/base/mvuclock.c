/* MVU's current QOS clock primitive is not a Base HAL operation. The host
 * runner test uses an explicit test-only clock; it has no tick subscription. */
#include "fpr.h"
static V fixed_clock(V ignored) { (void)ignored; return TAG(0); }
FPR_FN(fpr_g_read, fixed_clock, 1);
