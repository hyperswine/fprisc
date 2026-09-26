/* hal.c -- the posix system's console, monotonic clock, host sleep and
 * task-raised IRQ bridge, shared by both of its hosts (docs/2026-09-19-PROFILES.md):
 * on unix beside machine/unix (boot, parking, the heap and stack guards), on
 * ESP-IDF beside machine/esp-idf (the same, over FreeRTOS).  Everything here
 * is the POSIX subset both have: stdio, clock_gettime, a pthread mutex.
 * hal_irq_open takes that mutex, so it must run in task context, never in an
 * ISR; hal_irq_raise is atomics only and may be called from anywhere.
 */
#include "fpr.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

void hal_ipi_send(uw hart); /* park.c on unix, machine/esp-idf/hal.c on the board */

void hal_putc(char c) {
  fputc(c, stdout);
  if (c == '\n') fflush(stdout);
}

/* ---- external interrupts from host threads ---------------------------
 * A host thread that waits in the kernel on the actors' behalf (os_watch.c's
 * descriptor watcher) is this board's interrupt controller: it RAISES a
 * source, and the IRQ hart's loop claims it and sends the bound actor a
 * plain Int (actors.c irq_drain), exactly as a PLIC source on bare metal.
 * Pending is one flag per source; claim takes it (so a source is claimed
 * once per raise: the "mask"), ack has nothing to unmask.  Only sources
 * something opened are scanned, so the claim is cheap. */
#define HOST_IRQ_MAX FPR_HOST_IRQ_MAX
static uint8_t irq_pending[HOST_IRQ_MAX];
static uw irq_open_list[HOST_IRQ_MAX];
static uw irq_open_n;
static pthread_mutex_t irq_open_mu = PTHREAD_MUTEX_INITIALIZER;
void hal_irq_open(uw src) {
  if (src == 0 || src >= HOST_IRQ_MAX) return;
  pthread_mutex_lock(&irq_open_mu);
  int have = 0;
  for (uw i = 0; i < irq_open_n; i++) if (irq_open_list[i] == src) have = 1;
  if (!have) {
    irq_open_list[irq_open_n] = src;
    __atomic_store_n(&irq_open_n, irq_open_n + 1, __ATOMIC_RELEASE);
  }
  pthread_mutex_unlock(&irq_open_mu);
}
sw hal_irq_claim(void) {
  uw n = __atomic_load_n(&irq_open_n, __ATOMIC_ACQUIRE);
  for (uw i = 0; i < n; i++) {
    uw s = irq_open_list[i];
    if (__atomic_exchange_n(&irq_pending[s], 0, __ATOMIC_ACQ_REL)) return (sw)s;
  }
  return 0;
}
void hal_irq_ack(uw src) { (void)src; }
/* from ANY thread: mark the source pending, then ring the IRQ hart's
 * doorbell (in that order: the hart clears its bell, then re-drains) */
void hal_irq_raise(uw src) {
  if (src == 0 || src >= HOST_IRQ_MAX) return;
  __atomic_store_n(&irq_pending[src], 1, __ATOMIC_RELEASE);
  hal_ipi_send(fpr_irq_hart);
}

/* ---- interrupt sources for host threads ----------------------------------
 * Whoever raises from a host thread on actors' behalf (os_watch.c, os_job.c)
 * takes its source here, so no range is carved out by convention and the
 * number of watchers or jobs in flight is bounded by the source space alone.
 * Sources are handed out from the top downward, away from any small number a
 * program might bind by hand; a freed source is reused first. */
static uint8_t irq_host_used[HOST_IRQ_MAX];
static pthread_mutex_t irq_host_mu = PTHREAD_MUTEX_INITIALIZER;
uw hal_irq_host_alloc(void) {
  pthread_mutex_lock(&irq_host_mu);
  for (uw s = HOST_IRQ_MAX - 1; s > 0; s--)
    if (!irq_host_used[s]) { irq_host_used[s] = 1; pthread_mutex_unlock(&irq_host_mu); return s; }
  pthread_mutex_unlock(&irq_host_mu);
  return 0;
}
void hal_irq_host_free(uw src) {
  if (src == 0 || src >= HOST_IRQ_MAX) return;
  pthread_mutex_lock(&irq_host_mu);
  irq_host_used[src] = 0;
  pthread_mutex_unlock(&irq_host_mu);
}

uint64_t hal_mtime(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 10000000ull + (uint64_t)ts.tv_nsec / 100; /* 10 MHz, like virt's CLINT */
}

int fpr_hal_sleep_us(uw us) {
#ifdef FPR_ESP_IDF
  usleep(us); /* IDF's newlib has no nanosleep; its usleep busy-waits below a tick and yields above */
#else
  struct timespec ts = {(time_t)(us / 1000000), (long)(us % 1000000) * 1000};
  nanosleep(&ts, 0);
#endif
  return 1;
}
