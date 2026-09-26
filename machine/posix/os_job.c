/* os_job.c -- blocking host work, run off the harts: the posix system's job
 * broker, shared by both of its hosts (docs/2026-09-19-PROFILES.md).
 *
 * A platform library whose calls can block -- an RPC to the radio chip, a
 * scan that takes seconds -- must not run them on a hart: that would stall
 * every actor on the core.  It describes the call as a job (os_job.h) and
 * submits it; the broker thread runs it and raises the slot's interrupt,
 * which the runtime delivers to the actor that bound it:
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
 * into typed values (std/wifi, std/ble).
 *
 * The broker is a pthread on both hosts (the watcher, os_watch.c, is the
 * same shape).  On ESP-IDF it takes what a FreeRTOS task would have been
 * given: an internal stack, since IDF calls that reach flash require one,
 * and priority 5, above the harts (1) and well below lwIP and the SDIO
 * transport.  Jobs run one at a time, in order (docs/2026-09-19-BOUNDS.md). */
#include "os_value.h"
#include "os_job.h"
#include <stdio.h>
#include <stdarg.h>
#include <pthread.h>
#ifdef FPR_ESP_IDF
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_pthread.h"
#include "esp_heap_caps.h"
#endif

void hal_irq_raise(uw src);
void hal_irq_open(uw src);
void fpr_set_tp(fpr_hart_t *h);

/* a job slot IS an interrupt source (hal_irq_host_alloc), so jobs in flight
 * are bounded by the source space shared with the watchers, not by a count
 * of their own.  The table is indexed from the top of that space, where
 * sources are handed out, and grows to the deepest one in use. */
typedef struct { char *result; uint8_t used; } job_slot_t;
static job_slot_t *slots;
static size_t nslots;
static size_t jslot(uw irq) { return FPR_HOST_IRQ_MAX - 1 - irq; }
static pthread_mutex_t job_mu = PTHREAD_MUTEX_INITIALIZER; /* the slots and the queue */
static pthread_cond_t job_cv = PTHREAD_COND_INITIALIZER;
static fpr_job_t *jobq; /* a ring that grows: running out of memory is the only refusal */
static size_t qhead, qlen, qcap;
static pthread_once_t broker_once = PTHREAD_ONCE_INIT;

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
  va_list ap2;
  va_copy(ap2, ap);
  int n = vsnprintf(0, 0, fmt, ap);
  va_end(ap);
  char *p = n < 0 ? 0 : malloc((size_t)n + 1);
  if (p) vsnprintf(p, (size_t)n + 1, fmt, ap2);
  va_end(ap2);
  return p ? p : strdup("error\tout of memory\n");
}

static void *broker(void *arg) {
  (void)arg;
  fpr_set_tp(0); /* not a hart: anything asking which one hears "none" */
  for (;;) {
    pthread_mutex_lock(&job_mu);
    while (!qlen) pthread_cond_wait(&job_cv, &job_mu);
    fpr_job_t j = jobq[qhead];
    qhead = (qhead + 1) % qcap;
    qlen--;
    pthread_mutex_unlock(&job_mu);
    /* refused at submission: answer why, run nothing */
    char *text = j.bad ? fpr_job_printf("error\t%s\n", j.bad) : j.run(&j);
    pthread_mutex_lock(&job_mu);
    slots[jslot((uw)j.slot)].result = text;
    pthread_mutex_unlock(&job_mu);
    hal_irq_raise((uw)j.slot);
  }
  return 0;
}

static void broker_start(void) {
  pthread_t t;
  pthread_attr_t a;
  int bad = pthread_attr_init(&a);
  if (!bad) bad = pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
#ifdef FPR_ESP_IDF
  /* IDF's pthread reads the stack size from the attribute, and the rest of a
   * task's shape from a configuration the creating thread carries: set it
   * for this one create, then put the defaults back for the caller's later
   * threads (the watchers) */
  esp_pthread_cfg_t cfg = esp_pthread_get_default_config();
  cfg.stack_size = 8192;
  cfg.prio = 5;
  cfg.thread_name = "fpr-broker";
  cfg.pin_to_core = tskNO_AFFINITY;
  cfg.stack_alloc_caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
  cfg.inherit_cfg = false;
  if (esp_pthread_set_cfg(&cfg) != ESP_OK) fpr_cpanic("job: the broker's thread configuration was refused");
  if (!bad) bad = pthread_attr_setstacksize(&a, 8192);
#else
  if (!bad) bad = pthread_attr_setstacksize(&a, 256 * 1024);
#endif
  if (!bad) bad = pthread_create(&t, &a, broker, 0);
  pthread_attr_destroy(&a);
#ifdef FPR_ESP_IDF
  esp_pthread_cfg_t d = esp_pthread_get_default_config();
  esp_pthread_set_cfg(&d);
#endif
  if (bad) fpr_cpanic("job: the broker thread could not be started");
}

static V j_new(V u) {
  (void)u;
  pthread_once(&broker_once, broker_start);
  pthread_mutex_lock(&job_mu);
  uw irq = hal_irq_host_alloc();
  if (!irq) { pthread_mutex_unlock(&job_mu); fpr_cpanic("JobHost.new: no interrupt source left for a job"); }
  size_t i = jslot(irq);
  if (i >= nslots) {
    size_t n = nslots ? nslots : 8;
    while (n <= i) n *= 2;
    job_slot_t *t = realloc(slots, n * sizeof *t);
    if (!t) { hal_irq_host_free(irq); pthread_mutex_unlock(&job_mu); fpr_cpanic("JobHost.new: out of memory"); }
    memset(t + nslots, 0, (n - nslots) * sizeof *t);
    slots = t; nslots = n;
  }
  slots[i].used = 1;
  slots[i].result = 0;
  pthread_mutex_unlock(&job_mu);
  hal_irq_open(irq);
  return TAG((sw)irq);
}
FPR_FN(fpr_g_JobHost_x2enew, j_new, 1);

int fpr_job_slot(V s) {
  if (!ISINT(s) || UNTAG(s) <= 0 || (uw)UNTAG(s) >= FPR_HOST_IRQ_MAX || jslot((uw)UNTAG(s)) >= nslots || !slots[jslot((uw)UNTAG(s))].used)
    fpr_cpanic("job: not a job slot");
  return (int)UNTAG(s);
}

static V j_result(V s) {
  uw irq = (uw)fpr_job_slot(s);
  pthread_mutex_lock(&job_mu);
  char *r = slots[jslot(irq)].result;
  slots[jslot(irq)].result = 0;
  slots[jslot(irq)].used = 0;
  pthread_mutex_unlock(&job_mu);
  hal_irq_host_free(irq); /* the source is free for the next job or watcher */
  V out = (V)fpr_mkstr((const uint8_t *)(r ? r : ""), r ? (uw)strlen(r) : 0);
  free(r);
  return out;
}
FPR_FN(fpr_g_JobHost_x2eresult, j_result, 1);

V fpr_job_submit(const fpr_job_t *j) {
  pthread_mutex_lock(&job_mu);
  if (qlen == qcap) {
    size_t cap = qcap ? qcap * 2 : 16;
    fpr_job_t *q = malloc(cap * sizeof *q);
    if (!q) { pthread_mutex_unlock(&job_mu); return TAG(1); }
    for (size_t i = 0; i < qlen; i++) q[i] = jobq[(qhead + i) % qcap];
    free(jobq);
    jobq = q; qcap = cap; qhead = 0;
  }
  jobq[(qhead + qlen) % qcap] = *j;
  qlen++;
  pthread_cond_signal(&job_cv);
  pthread_mutex_unlock(&job_mu);
  return TAG(0);
}
