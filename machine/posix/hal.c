/* hal.c -- the hosted console, monotonic clock and task-raised IRQ bridge.
 * Unix process/memory/context facilities live in host.c; pthread parking
 * lives in park.c. This core is a candidate for reuse by POSIX-subset hosts,
 * not yet an ESP-IDF implementation. In particular hal_irq_open uses a
 * pthread mutex and must run in task context, never an ISR.
 */
#include "host.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

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
#define HOST_IRQ_MAX 1024
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

uint64_t hal_mtime(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 10000000ull + (uint64_t)ts.tv_nsec / 100; /* 10 MHz, like virt's CLINT */
}

int fpr_hal_sleep_us(uw us) {
  struct timespec ts = {(time_t)(us / 1000000), (long)(us % 1000000) * 1000};
  nanosleep(&ts, 0);
  return 1;
}
