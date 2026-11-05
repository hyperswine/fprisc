/* Bounded, allocation-free observer for scheduler qualification. Plain builds
 * retain only the fixture markers and stall control, with no runtime hooks. */
#include "fpr.h"
#include "sched_probe.h"
#include <stdio.h>
#include <stdatomic.h>
#include <time.h>

#ifdef FPR_SCHED_PROBE
#define ACTORS 128
static uint64_t probe_ns(void) {
#ifdef __APPLE__
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) fpr_cpanic("scheduler probe clock");
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
#endif
}
static struct {
  _Atomic uint64_t role, fuel, slots, total_ns, max_ns, harts;
} records[ACTORS];
static struct { uw actor; uint64_t start; } running[FPR_NHARTS];
static _Atomic uint64_t window_start, window_end;
#define OBSERVERS_CLOSED (1u << 31)
static _Atomic unsigned observers;
static void require(int yes) { if (!yes) fpr_cpanic("scheduler probe contract"); }
void fpr_sched_probe(unsigned event, uw hart, uw actor) {
  require(hart < FPR_NHARTS && hart < 64 && actor < ACTORS);
  if (event == FPR_SCHED_DISPATCH) {
    running[hart].actor = actor;
    running[hart].start = probe_ns();
    atomic_fetch_or_explicit(&records[actor].harts, (uint64_t)1 << hart, memory_order_relaxed);
    return;
  }
  /* End closes admission in the same atomic word as the active count. Later
   * hooks cannot keep the snapshot waiter busy, and updates admitted earlier
   * complete before report reads the counters. */
  unsigned active = atomic_load(&observers);
  for (;;) {
    if (active & OBSERVERS_CLOSED) return;
    if (atomic_compare_exchange_weak(&observers, &active, active + 1)) break;
  }
  uint64_t begin = atomic_load(&window_start);
  uint64_t end = atomic_load(&window_end);
  if (event == FPR_SCHED_FUEL) {
    require(running[hart].actor == actor);
    if (begin && !end) atomic_fetch_add_explicit(&records[actor].fuel, 1, memory_order_relaxed);
  } else if (event == FPR_SCHED_RETURN) {
    require(running[hart].actor == actor);
    uint64_t now = probe_ns();
    if (begin && !end && running[hart].start >= begin) {
      uint64_t elapsed = now - running[hart].start;
      atomic_fetch_add_explicit(&records[actor].slots, 1, memory_order_relaxed);
      atomic_fetch_add_explicit(&records[actor].total_ns, elapsed, memory_order_relaxed);
      uint64_t old = atomic_load_explicit(&records[actor].max_ns, memory_order_relaxed);
      while (old < elapsed && !atomic_compare_exchange_weak_explicit(
          &records[actor].max_ns, &old, elapsed, memory_order_relaxed, memory_order_relaxed)) {}
    }
  } else require(0);
  atomic_fetch_sub(&observers, 1);
}
#endif

static V role(V value) {
#ifdef FPR_SCHED_PROBE
  uw hart = fpr_hart()->id;
  require(hart < FPR_NHARTS && running[hart].actor < ACTORS);
  atomic_store_explicit(&records[running[hart].actor].role, (uint64_t)UNTAG(value), memory_order_relaxed);
#else
  (void)value;
#endif
  return (V)&fpr_unit;
}
static V begin(V ignored) {
  (void)ignored;
#ifdef FPR_SCHED_PROBE
  require(!atomic_load(&window_start));
  atomic_store(&window_start, probe_ns());
#endif
  return (V)&fpr_unit;
}
static V end(V ignored) {
  (void)ignored;
#ifdef FPR_SCHED_PROBE
  atomic_store(&window_end, probe_ns());
  atomic_fetch_or(&observers, OBSERVERS_CLOSED);
  while (atomic_load(&observers) != OBSERVERS_CLOSED) atomic_signal_fence(memory_order_seq_cst);
#endif
  return (V)&fpr_unit;
}
static V report(V ignored) {
  (void)ignored;
#ifdef FPR_SCHED_PROBE
  require(atomic_load(&window_end));
  for (uw i = 0; i < ACTORS; i++) {
    uint64_t role = atomic_load(&records[i].role);
    if (role) fprintf(stderr, "[fpr sched] {\"actor\":%lu,\"role\":%llu,\"fuel\":%llu,\"slots\":%llu,\"total_ns\":%llu,\"max_ns\":%llu,\"hart_mask\":%llu}\n",
      (unsigned long)i, (unsigned long long)role, (unsigned long long)atomic_load(&records[i].fuel),
      (unsigned long long)atomic_load(&records[i].slots), (unsigned long long)atomic_load(&records[i].total_ns),
      (unsigned long long)atomic_load(&records[i].max_ns), (unsigned long long)atomic_load(&records[i].harts));
  }
#endif
  return (V)&fpr_unit;
}
static V stall(V ignored) {
  (void)ignored;
  fputs("scheduler stall entered\n", stderr);
  fflush(stderr);
  for (;;) atomic_signal_fence(memory_order_seq_cst);
}
/* Keep a function value opaque to the compiler so the scheduler fixture can
 * exercise its general guarded entry. This boundary is bounded and performs
 * no allocation, mutation, locking or scheduler operation. */
static V opaque(V value) { return value; }
FPR_FN(fpr_g_schedProbeOpaque, opaque, 1);
FPR_FN(fpr_g_schedProbeRole, role, 1);
FPR_FN(fpr_g_schedProbeBegin, begin, 1);
FPR_FN(fpr_g_schedProbeEnd, end, 1);
FPR_FN(fpr_g_schedProbeReport, report, 1);
FPR_FN(fpr_g_schedProbeStall, stall, 1);
