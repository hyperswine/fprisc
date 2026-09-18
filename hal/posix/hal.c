/* hal.c (posix) -- the hosted HAL binding: libc IS the board.
 *
 * The virt HAL's obligations, re-satisfied by a host OS's userspace:
 * console bytes to stdout, poweroff is exit(2), the CLINT sleep/wake
 * doorbells become a short nanosleep poll (correct first: the wake
 * protocol's CAS/ring machinery in actors.c is untouched; a futex per
 * hart is the obvious upgrade), the timer is not native (fuel
 * preemption still bounds every actor's slice; the deadlock detector
 * samples on every poll wakeup), and there are no external interrupts
 * to claim.  Time is CLOCK_MONOTONIC in virt's 10 MHz mtime units. */
#include "fpr.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

void hal_putc(char c) {
  fputc(c, stdout);
  if (c == '\n') fflush(stdout);
}

void hal_poweroff(int code) {
  fflush(stdout);
  fflush(stderr);
  exit(code);
}
void fpr_park(void) { pause(); } /* FPR_PARK: unreachable after exit() */

/* ---- sleep/wake + timer obligations (actors.c) ---------------------- */
void hal_wfi_enable(void) {}
void hal_wfi(void) { /* poll pace; every path re-checks its rings after */
  struct timespec ts = {0, 200 * 1000};
  nanosleep(&ts, 0);
}
void hal_ipi_send(uw hart) { (void)hart; } /* wakeups land on the next poll */
void hal_ipi_clear(uw hart) { (void)hart; }
void hal_timer_park(uw hart) { (void)hart; }
void hal_timer_arm(uw hart, uint64_t delta) { (void)hart; (void)delta; }
int hal_timer_native(void) { return 0; }

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

/* ---- external interrupts: none on a host ---------------------------- */
void hal_irq_open(uw src) { (void)src; }
sw hal_irq_claim(void) { return 0; } /* 0 = nothing pending */
void hal_irq_ack(uw src) { (void)src; }

/* ---- first-activation contexts for hal/unix/ctx_x64.S / ctx_a64.S --- */
void fpr_ctx_fabricate(uw *ctx, void (*entry)(void), uw stack_top16,
                       fpr_hart_t *owner) {
  (void)owner; /* posix: the hart pointer is per-thread TLS, not a ctx slot */
  ctx[0] = (uw)(uintptr_t)entry;
#if defined(__x86_64__)
  /* jmp-entry must look like post-call state: entry %rsp == 8 mod 16,
   * or gcc's 16-byte spills inside the trampoline are misaligned */
  ctx[1] = stack_top16 - 8;
#else
  ctx[1] = stack_top16;
#endif
}
