/* Exact entry-tick oracle: no scheduler transition before readback. */
#include "fpr.h"
static V arm(V unit) {
    (void)unit;
    fpr_hart()->fuel = 1000000;
    return (V)&fpr_unit;
}
static V used(V unit) {
    (void)unit;
    return TAG(1000000 - fpr_hart()->fuel);
}
static V force(V unit) {
    (void)unit;
    fpr_hart()->fuel = 1;
    return (V)&fpr_unit;
}
FPR_FN(fpr_g_Loops_x2earm, arm, 1);
FPR_FN(fpr_g_Loops_x2eused, used, 1);
FPR_FN(fpr_g_Loops_x2eforce, force, 1);
