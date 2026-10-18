/* Test-only monotonic clock. No instrumentation in the timed loop. */
#include "fpr.h"
#include <time.h>
static struct timespec start;
static V begin(V unit) {
    (void)unit;
    if (clock_gettime(CLOCK_MONOTONIC,&start)) fpr_cpanic("benchmark clock failed");
    return (V)&fpr_unit;
}
static V elapsed(V unit) {
    (void)unit;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now)) fpr_cpanic("benchmark clock failed");
    return TAG((intptr_t)(now.tv_sec-start.tv_sec)*1000000000LL+now.tv_nsec-start.tv_nsec);
}
FPR_FN(fpr_g_Bench_x2estart,begin,1);
FPR_FN(fpr_g_Bench_x2eelapsed,elapsed,1);
