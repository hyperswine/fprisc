/* main.c (posix) -- hosted boot: what crt0.S does on virt, done by the
 * host instead.  fpr_rt_init is the SAME portable init virt runs (buddy
 * over the heap, hart blocks, actor 0 fabricated around fpr_fn_main);
 * harts are pthreads; the scheduler, mailboxes, fuel preemption and the
 * deadlock detector are runtime/actors.c, byte-for-byte the bare-metal
 * ones.  Linux/macOS play the part of the board.
 *
 * This is the Base profile's host: an FP-RISC program compiled with
 * `fpr build` is this file, the hosted HAL and OS facility objects, the shared core,
 * and the program, linked into one ordinary executable. */
#include "host.h"
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>

/* the hosted stand-in for tp (one per hart THREAD): generated x64 code
 * TLS-loads this where generated rv64 code reads tp.  On AArch64 the hart
 * is x28 instead (fpr.h), so there is no cell to define. */
#if !(defined(__aarch64__) && defined(FPR_HART_X28))
__thread fpr_hart_t *fpr_posix_hart;
#endif

#if defined(__x86_64__)
/* X64.hs's staging cells for SysV stack args 7/8 (see the a6/a7 rules in
 * the lowering header): written at arg staging, read by the very next
 * call's spill -- per hart thread, hence TLS, like tp above. */
__thread uw fpr_x64_a6, fpr_x64_a7;
#endif

/* the program's command line, served by Sys.args (base.c) */
int fpr_posix_argc;
char **fpr_posix_argv;

void fpr_set_tp(fpr_hart_t *h); /* runtime.c: the hart register (x28 on AArch64) */

static void *hart_thread(void *arg) {
  fpr_set_tp(0); /* no hart yet: what a fresh thread-local used to read */
  hal_fault_init();
  fpr_hart_secondary((int)(uintptr_t)arg); /* sets tp, joins the loop */
  return 0;
}

int main(int argc, char **argv) {
  fpr_set_tp(0); /* x28 holds whatever the loader left: "no hart" until boot sets one */
  fpr_posix_argc = argc;
  fpr_posix_argv = argv;
  /* FPR_HARTS=n lowers (or raises up to the compile cap) the live hart
   * count -- FPR_HARTS=1 is the determinism switch for byte-compared
   * runs.  The default is the cores THIS machine has online, up to the
   * compile cap: the cap is the build machine's count (fpr build), and a
   * binary carried to a smaller machine must not run more hart threads
   * than it has cores to spin them on. */
  {
    long online = sysconf(_SC_NPROCESSORS_ONLN);
    if (online >= 1 && (uw)online < fpr_live_harts) fpr_live_harts = (uw)online;
  }
  /* A reader that has gone (`prog | head`) is EPIPE on the write, which the
   * console path ignores like a closed stdout, and a socket's peer is an
   * Err -- never a death by SIGPIPE.  os_io.c set this only once a file
   * stream was opened, so a program that only printed still died. */
  signal(SIGPIPE, SIG_IGN);
  /* policy, not capacity: the ceiling on ONE actor's stack (actors.c).
   * A setting that is not what it claims to be is refused by name, never
   * clamped or ignored (docs/2026-09-19-BOUNDS.md: limits are never silent). */
  const char *sm = getenv("FPR_STACK_MAX_MB");
  if (sm && *sm) {
    char *end; long mb = strtol(sm, &end, 10);
    if (*end || mb < 1) { fprintf(stderr, "FPR_STACK_MAX_MB=%s: must be a whole number of MiB, at least 1\n", sm); exit(2); }
    fpr_stack_max = (uw)mb << 20;
  }
  const char *e = getenv("FPR_HARTS");
  if (e && *e) {
    char *end; long n = strtol(e, &end, 10);
    if (*end || n < 1 || n > FPR_NHARTS) {
      fprintf(stderr, "FPR_HARTS=%s: must be 1..%d (this binary was built for at most %d harts)\n", e, (int)FPR_NHARTS, (int)FPR_NHARTS);
      exit(2);
    }
    fpr_live_harts = (uw)n;
  }
  hal_fault_init();
  fpr_rt_init(); /* runtime: buddy, hart blocks, actor 0 */
  for (uintptr_t i = 1; i < fpr_live_harts; i++) {
    pthread_t t;
    if (pthread_create(&t, 0, hart_thread, (void *)i))
      fpr_cpanic("posix: pthread_create");
  }
  fpr_hart_main(0); /* never returns: fpr_exit -> hal_poweroff -> exit */
  return 0;
}
