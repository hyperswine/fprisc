/* park.c -- the Unix pthread sleep/wake implementation.
 * Separate from the HAL core so an RTOS host can retain task notifications.
 * Do not assume presence of pthread_condattr_setclock means it works:
 * ESP-IDF 5.3.2 returns success but still waits against gettimeofday.
 */
#include "host.h"
#include <pthread.h>
#include <time.h>

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
  int bell;          /* msip */
  uint64_t deadline; /* mtimecmp, absolute mtime; 0 = parked */
} hart_park_t;
static hart_park_t parks[FPR_NHARTS];
static pthread_once_t parks_once = PTHREAD_ONCE_INIT;
#define PARK_CAP (20ull * 10000) /* 20 ms of mtime */

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
    parks[i].deadline = 0;
  }
  pthread_condattr_destroy(&a);
}
static hart_park_t *park_of(uw hart) {
  pthread_once(&parks_once, parks_init);
  return &parks[hart % FPR_NHARTS];
}

void hal_wfi_enable(void) { pthread_once(&parks_once, parks_init); }

/* sleep until the doorbell rings or the deadline passes; the doorbell is
 * consumed here (the loop re-checks its rings after every wfi, and a bell
 * left raised would turn the next wait into a spin) and a deadline that
 * fired is disarmed, as a one-shot mtimecmp would be once re-armed */
void hal_wfi(void) {
  hart_park_t *p = park_of(fpr_hart()->id);
  pthread_mutex_lock(&p->mu);
  uint64_t now = hal_mtime(), until = now + PARK_CAP;
  if (p->deadline && p->deadline < until) until = p->deadline;
  while (!p->bell && now < until) {
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
    now = hal_mtime();
  }
  if (p->deadline && now >= p->deadline) p->deadline = 0;
  p->bell = 0;
  pthread_mutex_unlock(&p->mu);
}
void hal_ipi_send(uw hart) {
  hart_park_t *p = park_of(hart);
  pthread_mutex_lock(&p->mu);
  p->bell = 1;
  pthread_cond_signal(&p->cv);
  pthread_mutex_unlock(&p->mu);
}
void hal_ipi_clear(uw hart) {
  hart_park_t *p = park_of(hart);
  pthread_mutex_lock(&p->mu);
  p->bell = 0;
  pthread_mutex_unlock(&p->mu);
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

