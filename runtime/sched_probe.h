/* Optional scheduler qualification hooks. Include after fpr.h.
 * Ordinary builds have no calls, state, clocks or extra branches. A probe
 * build supplies fpr_sched_probe; the observer must not allocate, block or
 * call back into the actor runtime. This is diagnostic, not a time bound. */
#ifndef FPR_SCHED_PROBE_H
#define FPR_SCHED_PROBE_H
enum { FPR_SCHED_DISPATCH = 1, FPR_SCHED_RETURN = 2, FPR_SCHED_FUEL = 3 };
#ifdef FPR_SCHED_PROBE
void fpr_sched_probe(unsigned event, uw hart, uw actor);
#define FPR_SCHED_EVENT(event, hart, actor) fpr_sched_probe(event, hart, actor)
#else
#define FPR_SCHED_EVENT(event, hart, actor) ((void)0)
#endif
#endif
