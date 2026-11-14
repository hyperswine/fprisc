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
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

void hal_ipi_send(uw hart); /* park.c on unix, machine/esp-idf/hal.c on the board */

#ifdef FPR_COST_PROBE
#include <time.h>
uint64_t hal_probe_ns(void) {
#ifdef __APPLE__
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
#endif
}
#endif

/* how long an actor about to block on an otherwise idle hart re-checks its
 * mailbox first (actors.c spin_until): $FPR_BLOCK_SPIN_NS, default 2 us */
uw hal_block_spin_ns(void) {
  const char *s = getenv("FPR_BLOCK_SPIN_NS");
  return s && *s ? (uw)strtoull(s, 0, 10) : 2000;
}

/* Standard output is flushed at every newline when it is a terminal (or
 * $FPR_STDOUT_LINES=1, or on ESP-IDF, whose console is a UART): what a person
 * watches appears as it is printed.  Into a pipe or a file it is buffered,
 * as a C program's is, because a write(2) per printed line was most of the
 * running time of a program that prints many lines.  The buffer is written
 * when it fills, when a hart goes idle (park.c), before any diagnostic, raw
 * descriptor read or write, child process and exit -- so output still appears
 * in program order -- and, whatever the program then does (a blocking call,
 * a long computation), by a flusher thread within OUT_LATENCY_US of the first
 * byte buffered.  A process killed by a signal loses at most what it printed
 * in that last interval. */
#define OUT_LATENCY_US 50000
static int out_lines = -1;
static int out_dirty;
#ifndef FPR_ESP_IDF
static pthread_mutex_t out_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t out_cv = PTHREAD_COND_INITIALIZER;
static int out_flusher_started;
void hal_console_flush(void);
/* sleeps until something is buffered, gives the writer OUT_LATENCY_US to
 * add to it, writes it out; one write(2) per interval of printing */
static void *out_flusher(void *arg) {
  (void)arg;
  for (;;) {
    pthread_mutex_lock(&out_mu);
    while (!__atomic_load_n(&out_dirty, __ATOMIC_ACQUIRE)) pthread_cond_wait(&out_cv, &out_mu);
    pthread_mutex_unlock(&out_mu);
    usleep(OUT_LATENCY_US);
    hal_console_flush();
  }
  return 0;
}
static void out_wake(void) {
  pthread_mutex_lock(&out_mu);
  if (!out_flusher_started) {
    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    /* without the thread the other flushes still hold; try again next time */
    if (pthread_create(&t, &a, out_flusher, 0) == 0) out_flusher_started = 1;
    pthread_attr_destroy(&a);
  }
  pthread_cond_signal(&out_cv);
  pthread_mutex_unlock(&out_mu);
}
#else
static void out_wake(void) {}
#endif
static int line_mode(void) {
  int m = __atomic_load_n(&out_lines, __ATOMIC_RELAXED);
  if (m < 0) {
#ifdef FPR_ESP_IDF
    m = 1;
#else
    const char *e = getenv("FPR_STDOUT_LINES");
    m = (e && *e && *e != '0') || isatty(1);
    if (!m) setvbuf(stdout, 0, _IOFBF, 1 << 16);
#endif
    __atomic_store_n(&out_lines, m, __ATOMIC_RELAXED);
  }
  return m;
}
void hal_console_flush(void) {
  if (__atomic_load_n(&out_dirty, __ATOMIC_RELAXED) && __atomic_exchange_n(&out_dirty, 0, __ATOMIC_ACQ_REL))
    fflush(stdout);
}
static void wrote(int newline) {
  if (newline && line_mode()) fflush(stdout);
  else if (!__atomic_exchange_n(&out_dirty, 1, __ATOMIC_ACQ_REL)) out_wake(); /* clean -> buffered: once an interval */
}

void hal_putc(char c) {
  if (out_lines < 0) line_mode(); /* the buffer is chosen before the first byte */
  fputc(c, stdout);
  wrote(c == '\n');
}

void hal_console_bytes(const char *bytes, uw len) {
  if (!len) return;
  if (out_lines < 0) line_mode();
  fwrite(bytes, 1, len, stdout);
  wrote(memchr(bytes, '\n', len) != 0);
}

/* diagnostics (runtime.c praw, [warn]/[ERR] echo): stderr, unbuffered,
 * after flushing stdout so the two streams interleave in program order on
 * a shared terminal.  FPR_DIAG_STDOUT=1: the pre-#39 single stream. */
void hal_diag_bytes(const char *bytes, uw len) {
  static int to_stdout = -1;
  if (to_stdout < 0) {
    const char *e = getenv("FPR_DIAG_STDOUT");
    to_stdout = e && *e && *e != '0';
  }
  if (to_stdout) { hal_console_bytes(bytes, len); return; }
  __atomic_store_n(&out_dirty, 0, __ATOMIC_RELEASE);
  fflush(stdout);
  fwrite(bytes, 1, len, stderr);
}

void hal_eputc(char c) {
  hal_diag_bytes(&c, 1);
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
/* Sys.irqRaise src: raise a host source from FP-RISC itself -- what a host
 * thread does on an actor's behalf, available to a program so the routing
 * can be exercised without a device (tests/base/irqdead.fpr) */
static V h_irq_raise(V srcv) {
  if (!ISINT(srcv) || UNTAG(srcv) < 1) fpr_cpanic("Sys.irqRaise: a source is an Int >= 1");
  hal_irq_raise((uw)UNTAG(srcv));
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Sys_x2eirqRaise, h_irq_raise, 1);

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
