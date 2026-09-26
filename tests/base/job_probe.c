/* job_probe.c -- a host job for tests/base/job.fpr: the broker on the unix host.
 * Built beside the program with `fpr build --with`.  Probe.job slot n submits
 * a job that sleeps n ms on the broker thread and answers "pong<TAB>n". */
#include "os_job.h"
#include <unistd.h>

static char *run_pong(const fpr_job_t *j) {
  usleep((useconds_t)j->n * 1000);
  return fpr_job_printf("pong\t%d\n", j->n);
}
static V p_job(V s, V n) {
  fpr_job_t j = {.run = run_pong, .slot = fpr_job_slot(s), .n = (int)UNTAG(n)};
  return fpr_job_submit(&j);
}
FPR_FN(fpr_g_Probe_x2ejob, p_job, 2);
