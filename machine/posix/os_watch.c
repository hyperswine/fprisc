/* Shared descriptor watcher: pthread worker plus host wake transport. */
#include "os_value.h"
#include <fcntl.h>
#ifdef ESP_PLATFORM
#include <sys/poll.h>
#else
#include <poll.h>
#endif
#include <pthread.h>
#include <unistd.h>
#include "watch_wake.h"

/* ---- Os.watch*: waiting on descriptors IN THE KERNEL ---------------------
 * No actor may wait inside the kernel -- it would take its hart with it -- so
 * a waiter used to poll without blocking and sleep between polls, backing off
 * to 5 ms: an idle server's first byte waited for the next tick.  Now a HOST
 * thread, outside the hart pool, blocks in poll(2) for the actors.  When
 * something is ready it records what, and raises an interrupt (hal.c
 * hal_irq_raise); the IRQ hart delivers it to the actor bound with
 * Sys.irqBind, exactly as a device interrupt on bare metal.
 *
 *   Os.watchOpen : Unit -> Result Int String      a watcher; its irq number
 *   Os.watchArm  : Int -> List Int -> Unit        wait on these (Nil: on none)
 *   Os.watchTake : Int -> List Int                what was ready, and forget it
 *   Os.watchClose : Int -> Bool                   retry until closed; discard handle
 *
 * One-shot: after a raise the watcher waits on nothing until it is armed
 * again.  Level-triggered underneath, so data that arrived while it was
 * disarmed is found by the next arm.  A descriptor that has gone bad
 * (hangup, error, closed) counts as ready: the read says why.  A new arm
 * interrupts a poll already under way through a self-pipe. */
void hal_irq_raise(uw src);
void fpr_set_tp(fpr_hart_t *h);
typedef struct {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int wake[2];                /* the self-pipe: [0] polled, [1] written by arm */
  int *want; size_t nwant, capwant;
  int armed, polling, closing, stopped;
  uint64_t generation; /* reject readiness from a replaced descriptor set */
  int *ready; size_t nready, capready;
  uw irq;
} watcher_t;
/* the open watchers by interrupt source (hal_irq_host_alloc): a table indexed
 * from the top of the source space, which is where sources are handed out,
 * grown to the deepest one in use.  There is no watcher count of its own: a
 * host runs out of sources, or of wake descriptors (ESP-IDF registers 24
 * eventfds), and says which. */
static watcher_t **watchers;
static size_t nwatchers;
static size_t wslot(uw irq) { return FPR_HOST_IRQ_MAX - 1 - irq; }
static watcher_t *watcher_at(uw irq) { /* watch_mu held */
  return (irq && irq < FPR_HOST_IRQ_MAX && wslot(irq) < nwatchers) ? watchers[wslot(irq)] : 0;
}
static int watcher_room(uw irq) { /* watch_mu held: make the table reach this source */
  size_t i = wslot(irq);
  if (i < nwatchers) return 1;
  size_t n = nwatchers ? nwatchers : 8;
  while (n <= i) n *= 2;
  watcher_t **t = realloc(watchers, n * sizeof *t);
  if (!t) return 0;
  memset(t + nwatchers, 0, (n - nwatchers) * sizeof *t);
  watchers = t; nwatchers = n;
  return 1;
}
#ifdef FPR_ESP_IO_SMOKE
unsigned fpr_watch_raised;
#endif
static pthread_mutex_t watch_mu = PTHREAD_MUTEX_INITIALIZER;

static int grow_ints(int **a, size_t *cap, size_t need) {
  if (need <= *cap) return 1;
  size_t c = *cap ? *cap : 16;
  while (c < need) c *= 2;
  int *n = realloc(*a, c * sizeof **a);
  if (!n) return 0;
  *a = n; *cap = c;
  return 1;
}

static void *watch_thread(void *arg) {
  watcher_t *w = arg;
  fpr_set_tp(0); /* not a hart: anything asking which one hears "none" */
  struct pollfd *p = 0;
  size_t cap = 0;
  for (;;) {
    pthread_mutex_lock(&w->mu);
    while (!w->armed && !w->closing) pthread_cond_wait(&w->cv, &w->mu);
    if (w->closing) break;
    size_t n = w->nwant;
    uint64_t generation = w->generation;
    if (n + 1 > cap) {
      size_t c = cap ? cap : 16;
      while (c < n + 1) c *= 2;
      struct pollfd *np = realloc(p, c * sizeof *p);
      if (!np) { pthread_mutex_unlock(&w->mu); fpr_cpanic("Os.watch: out of memory"); }
      p = np; cap = c;
    }
    p[0].fd = w->wake[0]; p[0].events = POLLIN; p[0].revents = 0;
    for (size_t i = 0; i < n; i++) { p[i + 1].fd = w->want[i]; p[i + 1].events = POLLIN; p[i + 1].revents = 0; }
    w->polling = 1;
    pthread_mutex_unlock(&w->mu);
    int r;
    do r = poll(p, (nfds_t)(n + 1), -1); while (r < 0 && errno == EINTR);
    pthread_mutex_lock(&w->mu);
    w->polling = 0;
    if (w->closing) break;
    if (p[0].revents) watch_wake_drain(w->wake);
    if (generation != w->generation) { pthread_mutex_unlock(&w->mu); continue; }
    /* Failed poll must wake readers to observe descriptor errors, not spin. */
    if (r < 0) for (size_t i = 1; i <= n; i++) p[i].revents = POLLERR;
    size_t got = 0;
    for (size_t i = 1; i <= n; i++)
      if (p[i].revents) {
        if (!grow_ints(&w->ready, &w->capready, w->nready + 1)) { pthread_mutex_unlock(&w->mu); fpr_cpanic("Os.watch: out of memory"); }
        w->ready[w->nready++] = p[i].fd;
        got++;
      }
    if (got) w->armed = 0; /* one-shot: the actor re-arms after it takes */
    pthread_mutex_unlock(&w->mu);
    if (got) {
#ifdef FPR_ESP_IO_SMOKE
      __atomic_add_fetch(&fpr_watch_raised, 1, __ATOMIC_RELAXED);
#endif
      hal_irq_raise(w->irq);
    }
  }
  /* Detached worker owns teardown. No actor waits in pthread_join. The last
   * close call reclaims the control block only after this mutex is released. */
  free(p);
  free(w->want); free(w->ready);
  watch_wake_close(w->wake);
  pthread_cond_destroy(&w->cv);
  w->stopped = 1;
  pthread_mutex_unlock(&w->mu);
  return 0;
}

/* Registry -> watcher is the lock order. Keep lookup and locking together:
 * another actor may finish closing this slot concurrently. */
static watcher_t *watcher_of(V irqv) {
  if (!ISINT(irqv)) fpr_cpanic("Os.watch: the watcher is not an Int");
  sw irq = UNTAG(irqv);
  pthread_mutex_lock(&watch_mu);
  watcher_t *w = irq > 0 ? watcher_at((uw)irq) : 0;
  if (w) pthread_mutex_lock(&w->mu);
  pthread_mutex_unlock(&watch_mu);
  if (!w) fpr_cpanic("Os.watch: no such watcher");
  if (w->closing) { pthread_mutex_unlock(&w->mu); fpr_cpanic("Os.watch: watcher is closing"); }
  return w; /* locked */
}

static V h_watch_open(V u) {
  (void)u;
  pthread_mutex_lock(&watch_mu);
  uw irq = hal_irq_host_alloc();
  if (!irq) { pthread_mutex_unlock(&watch_mu); return os_err("no interrupt source left for a watcher"); }
  watcher_t *w = watcher_room(irq) ? calloc(1, sizeof *w) : 0;
  if (!w) { hal_irq_host_free(irq); pthread_mutex_unlock(&watch_mu); return os_err("out of memory"); }
  if (watch_wake_open(w->wake) != 0) {
    int saved = errno; free(w); hal_irq_host_free(irq); pthread_mutex_unlock(&watch_mu);
    errno = saved; return os_errno();
  }
  int bad = pthread_mutex_init(&w->mu, 0);
  if (bad) goto failed_wake;
  bad = pthread_cond_init(&w->cv, 0);
  if (bad) goto failed_mutex;
  w->irq = irq;
  pthread_t t;
  pthread_attr_t a;
  bad = pthread_attr_init(&a);
  if (bad) goto failed_cond;
  bad = pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
#ifdef ESP_PLATFORM
  if (!bad) bad = pthread_attr_setstacksize(&a, 16384);
#else
  if (!bad) bad = pthread_attr_setstacksize(&a, 256 * 1024);
#endif
  if (!bad) bad = pthread_create(&t, &a, watch_thread, w);
  pthread_attr_destroy(&a);
  if (bad) goto failed_cond;
  /* Publish only a fully initialized watcher with a running thread. */
  watchers[wslot(irq)] = w;
  pthread_mutex_unlock(&watch_mu);
  return os_ok(TAG((sw)w->irq));
failed_cond:
  pthread_cond_destroy(&w->cv);
failed_mutex:
  pthread_mutex_destroy(&w->mu);
failed_wake:
  watch_wake_close(w->wake);
  free(w);
  hal_irq_host_free(irq);
  pthread_mutex_unlock(&watch_mu);
  return os_err(strerror(bad));
}
FPR_FN(fpr_g_Os_x2ewatchOpen, h_watch_open, 1);

static V h_watch_arm(V irqv, V fdsv) {
  size_t n = 0;
  for (V c = fdsv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) n++;
  watcher_t *w = watcher_of(irqv);
  /* the same set, already armed: nothing to tell the thread */
  int same = w->armed && n == w->nwant;
  if (!grow_ints(&w->want, &w->capwant, n ? n : 1)) { pthread_mutex_unlock(&w->mu); fpr_cpanic("Os.watchArm: out of memory"); }
  size_t i = 0;
  for (V c = fdsv; i < n; c = ((V *)((char *)c + 8))[1], i++) {
    V f = ((V *)((char *)c + 8))[0];
    int fd = ISINT(f) ? (int)UNTAG(f) : -1;
    if (same && w->want[i] != fd) same = 0;
    w->want[i] = fd;
  }
  if (!same) {
    w->generation++;
    w->nwant = n;
    w->armed = n > 0;
    if (w->armed) pthread_cond_signal(&w->cv);
    if (w->polling) watch_wake_signal(w->wake); /* interrupt the old set's poll */
  }
  pthread_mutex_unlock(&w->mu);
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Os_x2ewatchArm, h_watch_arm, 2);

static V h_watch_take(V irqv) {
  watcher_t *w = watcher_of(irqv);
  /* copy under the lock, build after it: an allocation may switch actors,
   * and nothing may be switched away while holding the watcher's mutex */
  int small[64], *got = small;
  size_t n = w->nready;
  if (n > 64 && !(got = malloc(n * sizeof *got))) { pthread_mutex_unlock(&w->mu); fpr_cpanic("Os.watchTake: out of memory"); }
  memcpy(got, w->ready, n * sizeof *got);
  w->nready = 0;
  pthread_mutex_unlock(&w->mu);
  V out = (V)&os_nil;
  for (size_t i = n; i-- > 0;) out = os_cons(TAG(got[i]), out);
  if (got != small) free(got);
  return out;
}
FPR_FN(fpr_g_Os_x2ewatchTake, h_watch_take, 1);

/* Begin shutdown, then report whether teardown is complete. False means the
 * caller must yield/sleep before trying again; True releases the handle.
 * Like a closed fd, it must not be used after success: slots can be reused.
 * The caller owns IRQ binding lifetime and must stop arming/taking first. */
static V h_watch_close(V irqv) {
  if (!ISINT(irqv)) fpr_cpanic("Os.watchClose: watcher is not an Int");
  sw irq = UNTAG(irqv);
  pthread_mutex_lock(&watch_mu);
  watcher_t *w = irq > 0 ? watcher_at((uw)irq) : 0;
  if (!w) { pthread_mutex_unlock(&watch_mu); fpr_cpanic("Os.watchClose: no such watcher"); }
  pthread_mutex_lock(&w->mu);
  if (w->stopped) {
    watchers[wslot((uw)irq)] = 0;
    pthread_mutex_unlock(&w->mu);
    pthread_mutex_destroy(&w->mu);
    free(w);
    hal_irq_host_free((uw)irq); /* the source is free for the next watcher or job */
    pthread_mutex_unlock(&watch_mu);
    return (V)&fpr_true;
  }
  if (!w->closing) {
    w->closing = 1;
    pthread_cond_signal(&w->cv);
    if (w->polling) watch_wake_signal(w->wake);
  }
  pthread_mutex_unlock(&w->mu);
  pthread_mutex_unlock(&watch_mu);
  return (V)&fpr_false;
}
FPR_FN(fpr_g_Os_x2ewatchClose, h_watch_close, 1);
