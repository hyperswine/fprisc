/* host.c -- facilities of a Unix process, not the common POSIX subset.
 * Exit, native first-context layout, virtual-memory reservation and guarded
 * stacks stay together here until another host supplies its own versions.
 * ESP-IDF must not link this file: it has different lifetime, memory and ABI.
 */
#include "host.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#ifdef FPR_COST_PROBE
/* FPR_COST_REPORT=1 in a probe build: the whole process's ledger, one JSON
 * line on stderr at exit, so a program needs no Cost.report call of its own
 * (tools/regions-stage0.py reads it; docs/2026-10-24-REGIONS-STAGE0.md). */
static void cost_report(void) {
  const char *where = getenv("FPR_COST_REPORT");
  if (!where || !*where) return;
  /* "1": stderr; anything else is a file the line is appended to */
  FILE *out = stderr;
  if (where[0] != '1' || where[1]) { out = fopen(where, "a"); if (!out) return; }
  uint64_t ar = 0, ab = 0, c = 0, cb = 0, ms = 0, t = 0, sc = 0, sb = 0, rx = 0;
  for (uw i = 0; i < fpr_live_harts; i++) {
    fpr_hart_t *h = &fpr_harts[i];
    ar += h->cost_alloc_requests; ab += h->cost_alloc_bytes;
    c += h->cost_copies; cb += h->cost_copy_bytes; ms += h->cost_msg_slabs;
    t += h->cost_turns; sc += h->cost_state_copies; sb += h->cost_state_bytes;
    rx += h->xr_recv_n;
  }
  fprintf(out, "[fpr cost] {\"alloc_requests\":%llu,\"alloc_bytes\":%llu,\"copies\":%llu,"
          "\"copy_bytes\":%llu,\"message_slabs\":%llu,\"turns\":%llu,\"state_copies\":%llu,"
          "\"state_bytes\":%llu,\"receives\":%llu,\"buddy_allocs\":%llu,\"buddy_frees\":%llu}\n",
          (unsigned long long)ar, (unsigned long long)ab, (unsigned long long)c,
          (unsigned long long)cb, (unsigned long long)ms, (unsigned long long)t,
          (unsigned long long)sc, (unsigned long long)sb, (unsigned long long)rx,
          (unsigned long long)fpr_cost_buddy_allocs, (unsigned long long)fpr_cost_buddy_frees);
  if (out != stderr) fclose(out);
}
/* FPR_ALLOC_SITES=<file>: the allocation-site table (runtime.c site_note),
 * one line per chain, with main's address so tools/alloc_sites.py can undo
 * the load slide */
#define SITE_N 16384
#define SITE_DEPTH 6
extern uw fpr_site_keys[SITE_N][SITE_DEPTH], fpr_site_counts[SITE_N], fpr_site_bytes[SITE_N], fpr_site_dropped;
int fpr_alloc_sites_enabled(void) { const char *w = getenv("FPR_ALLOC_SITES"); return w && *w; }
static void sites_report(void) {
  const char *where = getenv("FPR_ALLOC_SITES");
  if (!where || !*where) return;
  FILE *out = fopen(where, "w");
  if (!out) return;
  extern int main(int, char **);
  fprintf(out, "main %llx dropped %llu\n", (unsigned long long)(uintptr_t)&main, (unsigned long long)fpr_site_dropped);
  for (uw i = 0; i < SITE_N; i++) {
    if (!fpr_site_counts[i]) continue;
    fprintf(out, "%llu %llu", (unsigned long long)fpr_site_counts[i], (unsigned long long)fpr_site_bytes[i]);
    for (int d = 0; d < SITE_DEPTH; d++) fprintf(out, " %llx", (unsigned long long)fpr_site_keys[i][d]);
    fprintf(out, "\n");
  }
  fclose(out);
}
#endif
void hal_poweroff(int code) {
#ifdef FPR_COST_PROBE
  cost_report();
  sites_report();
#endif
  fflush(stdout);
  fflush(stderr);
  exit(code);
}
void fpr_park(void) { pause(); } /* FPR_PARK: unreachable after exit() */

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
#include <errno.h>
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
  if (cap && *cap) {
    /* refused by name, never ignored: a cap that is not a number of MiB
     * at least 1 would otherwise leave the heap unbounded without a word */
    char *end; long mb = strtol(cap, &end, 10);
    if (*end || mb < 1) { fprintf(stderr, "FPR_HEAP_MB=%s: must be a whole number of MiB, at least 1\n", cap); exit(2); }
    max = (uw)mb << 20;
  }
  char *p = fpr_heap_reserve(0, max, cap ? max : (uw)16 << 20, &bytes);
  if (!p) { fprintf(stderr, "fpr: cannot reserve address space for the heap\n"); exit(1); }
  *lo = p;
  *hi = *span_hi = p + bytes;
}

void hal_heap_release(void *p, uw bytes) {
  uintptr_t pg = (uintptr_t)getpagesize();
  uintptr_t a = ((uintptr_t)p + pg - 1) & ~(pg - 1), e = ((uintptr_t)p + bytes) & ~(pg - 1);
  if (e <= a) return;
  /* MADV_FREE wherever the host has it (macOS, FreeBSD, Linux since 4.5):
   * the pages stay mapped until the kernel wants them, so a block that is
   * taken again soon costs no fault and no zeroing.  MADV_DONTNEED drops
   * them at once: a loop that frees and retakes a 1 MiB block each cycle
   * then faults every page back in (csv: 82.9 k faults against 44.3 k, 12%
   * of its wall time; docs/2026-11-14-PERFORMANCE-PROFILE.md).  The price
   * is in the reading, not the memory: lazily freed pages count in the
   * resident size until they are reclaimed.  A kernel that refuses the
   * advice (EINVAL before Linux 4.5) gets the old call. */
#ifdef MADV_FREE
  static int no_free;
  if (!no_free) {
    if (madvise((void *)a, e - a, MADV_FREE) == 0) return;
    if (errno != EINVAL) return;
    no_free = 1;
  }
#endif
#ifndef __APPLE__
  madvise((void *)a, e - a, MADV_DONTNEED);
#endif
}
