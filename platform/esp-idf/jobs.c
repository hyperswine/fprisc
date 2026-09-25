/* jobs.c (platform/esp-idf) -- the broker that runs blocking host work.
 *
 *   slot = JobHost.new Unit          a job slot: its number is an IRQ source
 *   Sys.irqBind slot self            bind BEFORE starting (an unbound raise is lost)
 *   WifiHost.scan slot               a library's call: submit the job; 0, or why not
 *   receive self                     ... the interrupt: the job is done
 *   JobHost.result slot              its result, as text; the slot is free again
 *
 * std/job.fpr wraps that as a call that blocks only the calling actor.
 * Results are text, one line per item, fields separated by tabs; a first line
 * "error<TAB>why" is a failure.  The libraries' std modules parse the rows
 * into typed values (std/wifi, std/ble). */
#include "jobs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

void hal_irq_raise(uw src);
void hal_irq_open(uw src);

#define JOB_BASE 900
#define JOB_SLOTS 64 /* jobs in flight; the IRQ sources 900-963 (docs/BOUNDS.md) */
static char *job_result[JOB_SLOTS];
static uint8_t job_used[JOB_SLOTS];
static portMUX_TYPE job_mux = portMUX_INITIALIZER_UNLOCKED;
static QueueHandle_t jobq;

size_t fpr_job_text(V s, char *dst, size_t cap) {
  if (ISINT(s) || TID(s) != T_STR) fpr_cpanic("job: expected a String");
  str_t *t = (str_t *)s;
  size_t n = t->len < cap - 1 ? t->len : cap - 1;
  memcpy(dst, t->bytes, n);
  dst[n] = 0;
  return t->len;
}
void fpr_job_field_safe(char *p) {
  for (; *p; p++) if (*p == '\t' || *p == '\n' || *p == '\r') *p = ' ';
}
char *fpr_job_printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  char *p = 0;
  if (vasprintf(&p, fmt, ap) < 0) p = 0;
  va_end(ap);
  return p ? p : strdup("error\tout of memory\n");
}

static void finish(int slot, char *text) {
  job_result[slot - JOB_BASE] = text;
  hal_irq_raise((uw)slot);
}

static void broker(void *arg) {
  (void)arg;
  fpr_job_t j;
  for (;;) {
    if (xQueueReceive(jobq, &j, portMAX_DELAY) != pdTRUE) continue;
    /* refused at submission: answer why, run nothing */
    finish(j.slot, j.bad ? fpr_job_printf("error\t%s\n", j.bad) : j.run(&j));
  }
}

static void jobs_start(void) {
  static int started;
  taskENTER_CRITICAL(&job_mux);
  int go = !started;
  started = 1;
  taskEXIT_CRITICAL(&job_mux);
  if (!go) return;
  jobq = xQueueCreate(16, sizeof(fpr_job_t));
  /* priority 5: above the harts (1), well below lwIP and the SDIO transport;
   * an internal stack, which IDF calls that reach flash require */
  xTaskCreate(broker, "fpr-broker", 8192, NULL, 5, NULL);
}

static V j_new(V u) {
  (void)u;
  jobs_start();
  taskENTER_CRITICAL(&job_mux);
  int k = -1;
  for (int i = 0; i < JOB_SLOTS; i++) if (!job_used[i]) { job_used[i] = 1; job_result[i] = 0; k = i; break; }
  taskEXIT_CRITICAL(&job_mux);
  if (k < 0) fpr_cpanic("JobHost.new: every job slot is in use");
  hal_irq_open((uw)(JOB_BASE + k));
  return TAG((sw)(JOB_BASE + k));
}
FPR_FN(fpr_g_JobHost_x2enew, j_new, 1);

int fpr_job_slot(V s) {
  if (!ISINT(s) || UNTAG(s) < JOB_BASE || UNTAG(s) >= JOB_BASE + JOB_SLOTS || !job_used[UNTAG(s) - JOB_BASE])
    fpr_cpanic("job: not a job slot");
  return (int)UNTAG(s);
}

static V j_result(V s) {
  int k = fpr_job_slot(s) - JOB_BASE;
  char *r = job_result[k];
  V out = (V)fpr_mkstr((const uint8_t *)(r ? r : ""), r ? (uw)strlen(r) : 0);
  free(r);
  job_result[k] = 0;
  job_used[k] = 0;
  return out;
}
FPR_FN(fpr_g_JobHost_x2eresult, j_result, 1);

V fpr_job_submit(const fpr_job_t *j) { return TAG(xQueueSend(jobq, j, 0) == pdTRUE ? 0 : 1); }
