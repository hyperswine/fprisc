/* Deterministic regressions for the shared watcher, independent of actor scheduling. */
#include <errno.h>

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <poll.h>
#include <stdatomic.h>
#include <unistd.h>
#include <sys/socket.h>
#include "fpr.h"
static int fail_create = 1;
static atomic_int hold_poll, poll_held, release_poll, raised, fail_realloc;
static void *test_realloc(void *p, size_t n) {
  if (atomic_exchange(&fail_realloc, 0)) return NULL;
  return realloc(p, n);
}
static int test_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg) {
  if (fail_create) return EAGAIN;
  return pthread_create(t, a, fn, arg);
}
static int test_poll(struct pollfd *p, nfds_t n, int timeout) {
  int r = poll(p, n, timeout);
  if (r > 0 && atomic_exchange(&hold_poll, 0)) {
    atomic_store(&poll_held, 1);
    while (!atomic_load(&release_poll)) usleep(1000);
  }
  return r;
}
#define pthread_create test_create
#define poll test_poll
#define realloc test_realloc
#include "os_watch.c"
#undef realloc
#undef pthread_create
#undef poll
const hdr_t fpr_unit = {0, 0}, fpr_true = {0, 1}, fpr_false = {0, 0};
V fpr_alloc(V n) { void *p = calloc(1, n); assert(p); return (V)p; }
str_t *fpr_mkstr(const uint8_t *src, uw n) { str_t *s = calloc(1, sizeof(*s) + n + 1); assert(s); s->len = n; memcpy(s->bytes, src, n); return s; }
void fpr_cpanic(const char *s) { fprintf(stderr, "%s\n", s); abort(); }
void fpr_set_tp(fpr_hart_t *h) { (void)h; }
void hal_irq_raise(uw source) { (void)source; atomic_fetch_add(&raised, 1); }
/* the host's source pool, as machine/posix/hal.c hands it out: from the top
 * down, freed ones first; stub_limit stands in for a pool that is used up */
static int stub_limit = FPR_HOST_IRQ_MAX;
static uint8_t stub_used[FPR_HOST_IRQ_MAX];
uw hal_irq_host_alloc(void) {
  int n = 0;
  for (int i = 1; i < FPR_HOST_IRQ_MAX; i++) n += stub_used[i];
  if (n >= stub_limit) return 0;
  for (uw s = FPR_HOST_IRQ_MAX - 1; s > 0; s--) if (!stub_used[s]) { stub_used[s] = 1; return s; }
  return 0;
}
void hal_irq_host_free(uw s) { stub_used[s] = 0; }
static int fd_count(void) { int n = 0; for (int i = 0; i < 512; i++) if (fcntl(i, F_GETFD) >= 0) n++; return n; }
static void until(atomic_int *flag) { for (int i = 0; i < 3000; i++) { if (atomic_load(flag)) return; usleep(1000); } assert(!"timeout"); }
static void finish_close(V id) {
  for (int i = 0; i < 3000; i++) {
    if (h_watch_close(id) == (V)&fpr_true) return;
    usleep(1000);
  }
  assert(!"close timeout");
}
static V event(int fd, int mask) {
  V pair[2] = {TAG(fd), TAG(mask)};
  return os_cons(os_cell(T_TUP2, 0, 2, pair), (V)&os_nil);
}
static void until_raised(int count) {
  for (int i = 0; i < 3000; i++) {
    if (atomic_load(&raised) >= count) return;
    usleep(1000);
  }
  assert(!"IRQ timeout");
}
int main(void) {
  int before = fd_count();
  for (int i = 0; i < 40; i++) {
    V result = h_watch_open(0);
    assert(((hdr_t *)result)->var == 1);
    assert(watcher_at(FPR_HOST_IRQ_MAX - 1) == NULL);
    assert(fd_count() == before);
  }
  fail_create = 0;
  V result = h_watch_open(0); assert(((hdr_t *)result)->var == 0);
  V id = FPR_FLD(result, 0); watcher_t *w = watcher_of(id); pthread_mutex_unlock(&w->mu);
  int a[2], b[2]; assert(pipe(a) == 0 && pipe(b) == 0);
  atomic_store(&hold_poll, 1);
  h_watch_arm(id, os_cons(TAG(a[0]), (V)&os_nil));
  assert(write(a[1], "a", 1) == 1); until(&poll_held);
  /* Poll already returned old readiness; replace its set before it publishes. */
  h_watch_arm(id, os_cons(TAG(b[0]), (V)&os_nil));
  atomic_store(&release_poll, 1);
  assert(write(b[1], "b", 1) == 1);
  int ready = 0;
  for (int i = 0; i < 3000; i++) {
    pthread_mutex_lock(&w->mu); ready = w->nready != 0; pthread_mutex_unlock(&w->mu);
    if (ready) break; usleep(1000);
  }
  assert(ready);
  V got = h_watch_take(id);
  assert(((hdr_t *)got)->var == 1 && UNTAG(FPR_FLD(got, 0)) == b[0]);
  assert(((hdr_t *)FPR_FLD(got, 1))->var == 0);
  h_watch_arm(id, (V)&os_nil);
  finish_close(id);
  close(a[0]); close(a[1]); close(b[0]); close(b[1]);
  assert(fd_count() == before);
  for (int i = 0; i < 80; i++) {
    result = h_watch_open(0); assert(((hdr_t *)result)->var == 0);
    id = FPR_FLD(result, 0);
    assert(UNTAG(id) == FPR_HOST_IRQ_MAX - 1); /* the top source, reused after each close */
    assert(pipe(a) == 0);
    if (i % 2) {
      h_watch_arm(id, os_cons(TAG(a[0]), (V)&os_nil));
      w = watcher_at(FPR_HOST_IRQ_MAX - 1);
      int polling = 0;
      for (int j = 0; j < 3000; j++) {
        pthread_mutex_lock(&w->mu); polling = w->polling; pthread_mutex_unlock(&w->mu);
        if (polling) break; usleep(1000);
      }
      assert(polling);
    }
    finish_close(id); /* alternate condition wait and blocked poll */
    close(a[0]); close(a[1]);
    assert(fd_count() == before && watcher_at(FPR_HOST_IRQ_MAX - 1) == NULL);
  }
  /* Stop after poll has observed readiness but before publication. */
  result = h_watch_open(0); id = FPR_FLD(result, 0);
  assert(pipe(a) == 0);
  atomic_store(&hold_poll, 1); atomic_store(&poll_held, 0); atomic_store(&release_poll, 0);
  h_watch_arm(id, os_cons(TAG(a[0]), (V)&os_nil));
  assert(write(a[1], "a", 1) == 1); until(&poll_held);
  int irqs = atomic_load(&raised);
  assert(h_watch_close(id) == (V)&fpr_false); /* does not wait for worker */
  atomic_store(&release_poll, 1);
  finish_close(id);
  assert(atomic_load(&raised) == irqs);
  close(a[0]); close(a[1]);
  /* 24 at once, then a pool that is used up: the 25th open answers Err by name */
  stub_limit = 24;
  V ids[24];
  for (int i = 0; i < 24; i++) {
    result = h_watch_open(0); assert(((hdr_t *)result)->var == 0);
    ids[i] = FPR_FLD(result, 0);
    assert(UNTAG(ids[i]) == FPR_HOST_IRQ_MAX - 1 - i);
  }
  result = h_watch_open(0); assert(((hdr_t *)result)->var == 1);
  for (int i = 0; i < 24; i++) finish_close(ids[i]);
  stub_limit = FPR_HOST_IRQ_MAX;
  /* Directional timer mechanism: a writable socket must not satisfy a read
   * registration; timer-only completion raises exactly once with no events. */
  result = h_watch_open(0); id = FPR_FLD(result, 0);
  int sockets[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  irqs = atomic_load(&raised);
  assert(((hdr_t *)h_watch_arm_events(id, event(sockets[0], 1), TAG(15000)))->var == 0);
  until_raised(irqs + 1);
  got = h_watch_take_events(id); assert(((hdr_t *)got)->var == 0);
  usleep(5000); assert(atomic_load(&raised) == irqs + 1);
  irqs = atomic_load(&raised);
  assert(((hdr_t *)h_watch_arm_events(id, event(sockets[0], 2), TAG(1000000)))->var == 0);
  until_raised(irqs + 1);
  got = h_watch_take_events(id);
  assert(((hdr_t *)got)->var == 1);
  V pair = FPR_FLD(got, 0);
  assert(UNTAG(FPR_FLD(pair, 0)) == sockets[0] && UNTAG(FPR_FLD(pair, 1)) == 2);
  /* Published old-generation readiness must not leak into a replacement arm. */
  irqs = atomic_load(&raised);
  h_watch_arm_events(id, event(sockets[0], 2), TAG(1000000));
  until_raised(irqs + 1);
  h_watch_arm_events(id, (V)&os_nil, TAG(-1));
  got = h_watch_take_events(id); assert(((hdr_t *)got)->var == 0);
  /* Replacing a blocked read with an earlier timer-only wait interrupts poll. */
  h_watch_arm_events(id, event(sockets[0], 1), TAG(1000000));
  irqs = atomic_load(&raised);
  h_watch_arm_events(id, (V)&os_nil, TAG(10000));
  until_raised(irqs + 1);
  got = h_watch_take_events(id); assert(((hdr_t *)got)->var == 0);
  assert(((hdr_t *)h_watch_arm_events(id, event(sockets[0], 0), TAG(1000)))->var == 1);
  assert(((hdr_t *)h_watch_arm_events(id, event(sockets[0], 1), TAG(-2)))->var == 1);
  /* A replacement allocation failure must leave no old kernel registration. */
  h_watch_arm_events(id, event(sockets[0], 1), TAG(1000000));
  V many = (V)&os_nil;
  for (int i = 0; i < 32; i++) {
    V fields[2] = {TAG(sockets[0]), TAG(1)};
    many = os_cons(os_cell(T_TUP2, 0, 2, fields), many);
  }
  atomic_store(&fail_realloc, 1);
  assert(((hdr_t *)h_watch_arm_events(id, many, TAG(1000000)))->var == 1);
  w = watcher_of(id);
  assert(!w->armed && !w->nwant && !w->nready && !w->deadline_us);
  pthread_mutex_unlock(&w->mu);
  finish_close(id);
  close(sockets[0]); close(sockets[1]);
  assert(fd_count() == before);
  for (int i = 1; i < FPR_HOST_IRQ_MAX; i++) assert(!stub_used[i]); /* every source given back */
  puts("Watcher: close during pending readiness; simultaneous capacity reclaimed: PASS");
  puts("Watcher: close/reopen 80 times, idle and polling, no descriptor leaks: PASS");
  puts("Watcher: failed starts release resources; re-arm rejects stale readiness: PASS");
  puts("Watcher: directions, timer IRQ, earlier timer re-arm, stale-event removal and allocation-failure disarm: PASS");
  return 0;
}
