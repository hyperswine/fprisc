/* park.c -- the Unix pthread sleep/wake implementation.
 * Separate from the HAL core so an RTOS host can retain task notifications.
 * Do not assume presence of pthread_condattr_setclock means it works:
 * ESP-IDF 5.3.2 returns success but still waits against gettimeofday.
 */
#include "host.h"
#include <pthread.h>
#include <stdlib.h>
#include <time.h>
#ifndef FPR_SPIN_US_DEFAULT
#define FPR_SPIN_US_DEFAULT 20
#endif

/* ---- sleep/wake + timer obligations (actors.c) ---------------------- */
/* An idle hart used to nap 200 us and look again: 5,000 wake-ups a second
 * per hart, ~5% of a core for a server doing nothing.  Now it PARKS: msip
 * is `bell`, mtimecmp is `deadline`, and wfi waits on the hart's condition
 * variable until either fires.  The wait is capped (PARK_CAP) so that
 * nothing can depend on the doorbell for correctness -- a wake source that
 * forgets to ring costs latency, never a hang -- at ~50 wake-ups a second
 * per idle hart. */
typedef struct {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int bell;          /* msip: set/cleared atomically (seq_cst) */
  int waiting;       /* the hart is in, or entering, the condition wait (seq_cst) */
  uint64_t deadline; /* mtimecmp, absolute mtime; 0 = parked */
#ifdef FPR_COST_PROBE
  uint64_t bell_at;  /* probe: when the doorbell was rung */
#endif
} hart_park_t;
static hart_park_t parks[FPR_NHARTS];
static pthread_once_t parks_once = PTHREAD_ONCE_INIT;
#define PARK_CAP (20ull * 10000) /* 20 ms of mtime */
/* SPIN BEFORE SLEEPING (2026-10-01, docs/2026-10-01-XHART.md): a hart that
 * just ran out of work watches its doorbell for spin_ns before it sleeps in
 * the kernel.  A cross-hart reply that arrives inside the window costs no
 * OS sleep and no OS wake -- the profile found those two at ~90% of a
 * cross-hart round trip (399,941 sleeps for 400,000 messages).  A hart with
 * nothing coming sleeps one window later than it used to.  FPR_SPIN_US sets
 * the window (0 = sleep at once, the old behaviour). */
static uint64_t spin_ns;
static void parks_init(void) {
  pthread_condattr_t a;
  pthread_condattr_init(&a);
#ifndef __APPLE__
  pthread_condattr_setclock(&a, CLOCK_MONOTONIC); /* macOS waits RELATIVE instead */
#endif
  for (uw i = 0; i < FPR_NHARTS; i++) {
    pthread_mutex_init(&parks[i].mu, 0);
    pthread_cond_init(&parks[i].cv, &a);
    parks[i].bell = 0;
    parks[i].waiting = 0;
    parks[i].deadline = 0;
  }
  pthread_condattr_destroy(&a);
  const char *s = getenv("FPR_SPIN_US");
  spin_ns = (s && *s ? strtoull(s, 0, 10) : FPR_SPIN_US_DEFAULT) * 1000ull;
}
static hart_park_t *park_of(uw hart) {
  pthread_once(&parks_once, parks_init);
  return &parks[hart % FPR_NHARTS];
}
static uint64_t mono_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static inline void cpu_relax(void) {
#if defined(__aarch64__)
  __asm__ volatile("isb");
#elif defined(__x86_64__)
  __asm__ volatile("pause");
#endif
}
void hal_wfi_enable(void) { pthread_once(&parks_once, parks_init); }
/* sleep until the doorbell rings or the deadline passes; the doorbell is
 * consumed here (the loop re-checks its rings after every wfi, and a bell
 * left raised would turn the next wait into a spin) and a deadline that
 * fired is disarmed, as a one-shot mtimecmp would be once re-armed.
 *
 * The doorbell needs no lock to ring when nobody sleeps: the sleeper raises
 * `waiting` and then reads `bell`; the ringer raises `bell` and then reads
 * `waiting` (both seq_cst, a Dekker pair).  Either the sleeper sees the
 * bell and does not wait, or the ringer sees it waiting and signals under
 * the mutex -- which it can only take once the sleeper is inside
 * pthread_cond_wait, so the signal is not lost. */
void hal_wfi(void) {
  hart_park_t *p = park_of(fpr_hart()->id);
#ifdef FPR_COST_PROBE
  fpr_hart_t *ph = fpr_hart();
  uint64_t pt0 = FPR_PROBE_NOW();
  int waited = 0;
#endif
  if (spin_ns) {
    uint64_t dl = __atomic_load_n(&p->deadline, __ATOMIC_RELAXED);
    uint64_t end = mono_ns() + spin_ns;
    while (!__atomic_load_n(&p->bell, __ATOMIC_ACQUIRE)) {
      if (dl && hal_mtime() >= dl) break;
      if (mono_ns() >= end) break;
      for (int i = 0; i < 8; i++) cpu_relax();
    }
    if (__atomic_exchange_n(&p->bell, 0, __ATOMIC_ACQ_REL)) return; /* rung while spinning */
  }
  pthread_mutex_lock(&p->mu);
  __atomic_store_n(&p->waiting, 1, __ATOMIC_SEQ_CST);
  uint64_t now = hal_mtime(), until = now + PARK_CAP;
  if (p->deadline && p->deadline < until) until = p->deadline;
  while (!__atomic_load_n(&p->bell, __ATOMIC_SEQ_CST) && now < until) {
    uint64_t ticks = until - now; /* 100 ns each */
#ifdef __APPLE__
    struct timespec rel = {(time_t)(ticks / 10000000ull), (long)(ticks % 10000000ull) * 100};
    pthread_cond_timedwait_relative_np(&p->cv, &p->mu, &rel);
#else
    struct timespec abs;
    clock_gettime(CLOCK_MONOTONIC, &abs);
    abs.tv_sec += (time_t)(ticks / 10000000ull);
    abs.tv_nsec += (long)(ticks % 10000000ull) * 100;
    if (abs.tv_nsec >= 1000000000L) { abs.tv_sec++; abs.tv_nsec -= 1000000000L; }
    pthread_cond_timedwait(&p->cv, &p->mu, &abs);
#endif
#ifdef FPR_COST_PROBE
    waited = 1;
#endif
    now = hal_mtime();
  }
  __atomic_store_n(&p->waiting, 0, __ATOMIC_SEQ_CST);
#ifdef FPR_COST_PROBE
  {
    uint64_t pt1 = FPR_PROBE_NOW();
    if (waited) {
      FPR_COST_ADD(ph, xp_park_n, 1);
      FPR_COST_ADD(ph, xp_park_ns, pt1 - pt0);
      if (__atomic_load_n(&p->bell, __ATOMIC_RELAXED) && p->bell_at && pt1 > p->bell_at) {
        FPR_COST_ADD(ph, xp_bell_n, 1);
        FPR_COST_ADD(ph, xp_bell_ns, pt1 - p->bell_at);
      }
    }
  }
#endif
  if (p->deadline && now >= p->deadline) p->deadline = 0;
  __atomic_store_n(&p->bell, 0, __ATOMIC_RELEASE);
  pthread_mutex_unlock(&p->mu);
}
void hal_ipi_send(uw hart) {
  hart_park_t *p = park_of(hart);
#ifdef FPR_COST_PROBE
  if (!__atomic_load_n(&p->bell, __ATOMIC_RELAXED)) p->bell_at = FPR_PROBE_NOW();
#endif
  __atomic_store_n(&p->bell, 1, __ATOMIC_SEQ_CST);
  if (__atomic_load_n(&p->waiting, __ATOMIC_SEQ_CST)) {
    pthread_mutex_lock(&p->mu);
    pthread_cond_signal(&p->cv);
    pthread_mutex_unlock(&p->mu);
  }
}
void hal_ipi_clear(uw hart) {
  __atomic_store_n(&park_of(hart)->bell, 0, __ATOMIC_SEQ_CST);
}
void hal_timer_park(uw hart) {
  hart_park_t *p = park_of(hart);
  pthread_mutex_lock(&p->mu);
  p->deadline = 0;
  pthread_mutex_unlock(&p->mu);
}
/* arming is the hart's own act, except a re-arm request another hart makes
 * (it rings the doorbell as well), so a sooner deadline needs no signal */
void hal_timer_arm(uw hart, uint64_t delta) {
  hart_park_t *p = park_of(hart);
  pthread_mutex_lock(&p->mu);
  p->deadline = hal_mtime() + (delta ? delta : 1);
  pthread_mutex_unlock(&p->mu);
}
int hal_timer_native(void) { return 0; }

