/* floor.c -- what a cross-thread round trip costs on this machine with NO
 * runtime: the floors the actor runtime's cross-hart message can be judged
 * against (docs/2026-10-01-XHART.md).
 *
 *   spin    two threads hand a token back and forth through one atomic
 *           cache line, busy-waiting: the cache-line transfer cost alone
 *   condvar the same hand-off, but the waiting thread SLEEPS on a condition
 *           variable and is signalled (the runtime's posix park.c):
 *           cache transfer + an OS thread wake-up per hop
 *
 * usage: floor N   -> one JSON line, ns per round trip (fastest of 5) */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static long N;
static _Alignas(128) volatile long token;
static void prio(void) {
#ifdef __APPLE__
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
}
static void *spin_peer(void *u) {
  (void)u; prio();
  for (long i = 0; i < N; i++) {
    while (__atomic_load_n(&token, __ATOMIC_ACQUIRE) != 2 * i + 1) ;
    __atomic_store_n(&token, 2 * i + 2, __ATOMIC_RELEASE);
  }
  return 0;
}
static double spin_rt(void) {
  token = 0; pthread_t t; pthread_create(&t, 0, spin_peer, 0);
  uint64_t t0 = now_ns();
  for (long i = 0; i < N; i++) {
    __atomic_store_n(&token, 2 * i + 1, __ATOMIC_RELEASE);
    while (__atomic_load_n(&token, __ATOMIC_ACQUIRE) != 2 * i + 2) ;
  }
  uint64_t t1 = now_ns(); pthread_join(t, 0);
  return (double)(t1 - t0) / N;
}
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv[2] = {PTHREAD_COND_INITIALIZER, PTHREAD_COND_INITIALIZER};
static long turn;
static void *cv_peer(void *u) {
  (void)u; prio();
  for (long i = 0; i < N; i++) {
    pthread_mutex_lock(&mu);
    while (turn != 2 * i + 1) pthread_cond_wait(&cv[1], &mu);
    turn = 2 * i + 2; pthread_cond_signal(&cv[0]);
    pthread_mutex_unlock(&mu);
  }
  return 0;
}
static double cv_rt(void) {
  turn = 0; pthread_t t; pthread_create(&t, 0, cv_peer, 0);
  uint64_t t0 = now_ns();
  for (long i = 0; i < N; i++) {
    pthread_mutex_lock(&mu);
    turn = 2 * i + 1; pthread_cond_signal(&cv[1]);
    while (turn != 2 * i + 2) pthread_cond_wait(&cv[0], &mu);
    pthread_mutex_unlock(&mu);
  }
  uint64_t t1 = now_ns(); pthread_join(t, 0);
  return (double)(t1 - t0) / N;
}
int main(int argc, char **argv) {
  N = argc > 1 ? atol(argv[1]) : 200000;
  prio();
  double s = 1e18, c = 1e18;
  for (int r = 0; r < 5; r++) { double x = spin_rt(); if (x < s) s = x; double y = cv_rt(); if (y < c) c = y; }
  printf("{\"spin_rt_ns\":%.1f,\"condvar_rt_ns\":%.1f}\n", s, c);
  return 0;
}
