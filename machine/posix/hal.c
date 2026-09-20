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

/* ---- first-activation contexts for machine/unix/ctx_x64.S / ctx_a64.S --- */
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

/* ---- the stack guard (runtime/actors.c asks; this machine can) --------
 * The lowest page of an actor's stack is made inaccessible, so running off
 * the end is a fault AT the end instead of a walk through whatever lay
 * below.  The fault is caught on an alternate signal stack -- the one that
 * faulted has, by definition, no room left -- and said by name. */
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* the guard page for a stack whose block starts at `lo`.  A block sits a
 * header past a page boundary, so that page is the guard; were it not
 * page-placed, guarding it would take a neighbour's bytes too, so the
 * first page wholly inside the stack is used instead. */
static uintptr_t guard_page(void *lo, uintptr_t pg) {
  uintptr_t page = (uintptr_t)lo & ~(pg - 1);
  if ((uintptr_t)lo - page > 64) page += pg;
  return page;
}
void hal_stack_guard(void *lo, uw size) {
  uintptr_t pg = (uintptr_t)getpagesize();
  if (size < 4 * pg) return; /* a stack this small cannot spare a page */
  mprotect((void *)guard_page(lo, pg), pg, PROT_NONE);
}
void hal_stack_unguard(void *lo, uw size) {
  uintptr_t pg = (uintptr_t)getpagesize();
  if (size < 4 * pg) return;
  mprotect((void *)guard_page(lo, pg), pg, PROT_READ | PROT_WRITE);
}

/* is `addr` in (or a big frame's step below) the guard of the stack at `lo`? */
int hal_stack_guard_hit(void *lo, uw size, void *addr) {
  uintptr_t pg = (uintptr_t)getpagesize(), at = (uintptr_t)addr;
  if (!lo || size < 4 * pg) return 0;
  uintptr_t g = guard_page(lo, pg);
  return at + 8 * pg >= g && at < g + pg;
}
/* the last words, and the end.  Signal context: write(2), _exit. */
void hal_stack_overflow_die(uw id, uw size) {
  char msg[200];
  int n = snprintf(msg, sizeof msg,
                   "\n*** FPRISC PANIC [actor %lu]: stack overflow -- the actor ran off its %lu KiB stack "
                   "(recursion that is not a tail call goes as deep as its input; use an accumulator)\n",
                   (unsigned long)id, (unsigned long)(size >> 10));
  fflush(stdout);
  if (n > 0) (void)!write(2, msg, (size_t)n);
  _exit(1);
}
static void fault_handler(int sig, siginfo_t *info, void *ctx) {
  (void)ctx;
  uw id = 0, size = 0;
  void *lo = fpr_current_stack(&id, &size);
  if (hal_stack_guard_hit(lo, size, info->si_addr)) hal_stack_overflow_die(id, size);
  signal(sig, SIG_DFL); /* not ours: let it be the crash it is */
}

/* once per hart THREAD: an alternate stack is a per-thread thing */
void hal_fault_altstack(void) {
  stack_t ss = {0};
  ss.ss_size = 64 * 1024;
  ss.ss_sp = malloc(ss.ss_size);
  if (ss.ss_sp) sigaltstack(&ss, 0);
}
void hal_fault_init(void) {
  hal_fault_altstack();
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = fault_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigaction(SIGSEGV, &sa, 0);
  sigaction(SIGBUS, &sa, 0);
}

/* ---- the heap: a reservation, not a size --------------------------------
 * The heap used to be FPR_HEAP_MB (256) of .bss, chosen at build time.  It is
 * address space now: the largest span the system will reserve, from 1 TiB
 * (the buddy's largest block) down, mapped MAP_NORESERVE so nothing is
 * committed until it is touched.  What bounds a program is memory, and the
 * address space.  FPR_HEAP_MB in the ENVIRONMENT caps the span for a run (a
 * test of exhaustion, a machine with strict overcommit); fpr_heap_reserve is
 * shared with QOS Portable's host, which reserves at the apps' address. */
#ifndef MAP_NORESERVE
#define MAP_NORESERVE 0
#endif
/* Asking for a SPECIFIC address portably is the awkward part.  Linux treats a
 * plain address argument as a hint it will honour when the range is free, so
 * `p == at` is the whole test.  FREEBSD does not: the address is advisory and
 * it will quietly hand back somewhere else, so that test fails every time and
 * a host whose app images are linked at a fixed base (QOS Portable) can never
 * start.  MAP_FIXED alone would be wrong -- it REPLACES whatever is already
 * mapped there -- but FreeBSD's MAP_EXCL turns MAP_FIXED into "this address
 * or fail", which is exactly the guarantee the hint was standing in for.
 * Where MAP_EXCL does not exist (Linux, macOS) the hint-and-check stands. */
#if defined(MAP_FIXED) && defined(MAP_EXCL)
#define FPR_MAP_AT (MAP_FIXED | MAP_EXCL)
#else
#define FPR_MAP_AT 0
#endif
void *fpr_heap_reserve(void *at, uw max, uw min, uw *bytes) {
  for (uw want = max; want >= min && want; want >>= 1) {
    int flags = MAP_PRIVATE | MAP_ANON | MAP_NORESERVE | (at ? FPR_MAP_AT : 0);
    void *p = mmap(at, want, PROT_READ | PROT_WRITE, flags, -1, 0);
    if (p == MAP_FAILED) continue;
    if (at && p != at) { munmap(p, want); continue; } /* never over something live */
    *bytes = want;
    return p;
  }
  return 0;
}

/* A program with a reservation that must sit at a FIXED address (QOS
 * Portable's host: app images are linked at one) makes it here, before this
 * heap can land on top of it. */
__attribute__((weak)) void hal_heap_before_reserve(void) {}

void hal_heap_span(char **lo, char **hi, char **span_hi) {
  hal_heap_before_reserve();
  uw bytes = 0, max = (uw)1 << 40;
  const char *cap = getenv("FPR_HEAP_MB");
  if (cap && atol(cap) > 0) max = (uw)atol(cap) << 20;
  char *p = fpr_heap_reserve(0, max, cap ? max : (uw)16 << 20, &bytes);
  if (!p) { fprintf(stderr, "fpr: cannot reserve address space for the heap\n"); exit(1); }
  *lo = p;
  *hi = *span_hi = p + bytes;
}

void hal_heap_release(void *p, uw bytes) {
  uintptr_t pg = (uintptr_t)getpagesize();
  uintptr_t a = ((uintptr_t)p + pg - 1) & ~(pg - 1), e = ((uintptr_t)p + bytes) & ~(pg - 1);
  if (e <= a) return;
#ifdef __APPLE__
  madvise((void *)a, e - a, MADV_FREE);
#else
  madvise((void *)a, e - a, MADV_DONTNEED);
#endif
}
