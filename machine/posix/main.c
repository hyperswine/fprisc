/* main.c (posix) -- hosted boot: what crt0.S does on virt, done by the
 * host instead.  fpr_rt_init is the SAME portable init virt runs (buddy
 * over the heap, hart blocks, actor 0 fabricated around fpr_fn_main);
 * harts are pthreads; the scheduler, mailboxes, fuel preemption and the
 * deadlock detector are runtime/actors.c, byte-for-byte the bare-metal
 * ones.  Linux/macOS play the part of the board.
 *
 * This is the Base profile's host: an FP-RISC program compiled with
 * `fpr build` is this file, hal.c/base.c, the shared core,
 * and the program, linked into one ordinary executable. */
#include "fpr.h"
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>

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

void hal_fault_init(void); /* hal.c: this thread's alternate signal stack */

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
  /* policy, not capacity: the ceiling on ONE actor's stack (actors.c) */
  const char *sm = getenv("FPR_STACK_MAX_MB");
  if (sm && atol(sm) > 0) fpr_stack_max = (uw)atol(sm) << 20;
  const char *e = getenv("FPR_HARTS");
  if (e && *e) {
    long n = strtol(e, 0, 10);
    if (n < 1) n = 1;
    if (n > FPR_NHARTS) n = FPR_NHARTS;
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
