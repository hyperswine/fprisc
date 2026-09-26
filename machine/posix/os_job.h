/* os_job.h -- blocking host work, run off the harts (os_job.c).
 *
 * A platform library (platform/esp-idf/wifi.c, bluetooth.c) whose calls can
 * block -- an RPC to the radio chip, a scan that takes seconds -- must not
 * run them on a hart: that would stall every actor on the core.  It
 * describes the call as a job and submits it; the broker thread runs it and
 * raises the slot's interrupt, which the runtime delivers to the actor that
 * bound it (std/job.fpr).
 *
 * `run` is the library's own function, so the broker names no library: a
 * program that never imports std/ble links no Bluetooth code. */
#ifndef FPR_POSIX_OS_JOB_H
#define FPR_POSIX_OS_JOB_H
#include "fpr.h"
#include <stddef.h>

typedef struct fpr_job fpr_job_t;
struct fpr_job {
  char *(*run)(const fpr_job_t *j); /* on the broker thread; answers malloc'd result text */
  int slot;
  char a[33], b[65]; /* string arguments, length-checked by the submitter */
  int n;             /* an integer argument */
  const char *bad;   /* set when an argument is refused: answered as the error, run skipped */
};

/* a slot handed out by JobHost.new, or a named panic */
int fpr_job_slot(V s);
/* queue it: TAG(0), or TAG(1) when it could not be queued (out of memory) */
V fpr_job_submit(const fpr_job_t *j);
/* copy a String into dst (truncated to cap-1); answers its FULL length, so the
 * caller refuses one that did not fit instead of using a cut copy */
size_t fpr_job_text(V s, char *dst, size_t cap);
/* malloc'd formatted text, never NULL */
char *fpr_job_printf(const char *fmt, ...);
/* replace tabs and newlines: a field must not split its row */
void fpr_job_field_safe(char *p);

#endif
