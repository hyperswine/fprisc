/* Hardware-only regression: real compiler TLS and the current hart agree. */
#include "fpr.h"
#include "esp_cpu.h"
#include "esp_netif.h"
#include "esp_err.h"
static __thread volatile unsigned marker = 0x12345678;
static uintptr_t task_tp[FPR_NHARTS];
void fpr_esp_io_probe_init(void) { ESP_ERROR_CHECK(esp_netif_init()); }
static V tls_check(V u) {
  (void)u;
  unsigned core = esp_cpu_get_core_id();
  uintptr_t tp = (uintptr_t)__builtin_thread_pointer();
  if (marker != 0x12345678 || core >= FPR_NHARTS || !tp ||
      fpr_hart() != &fpr_harts[core]) fpr_cpanic("probe: TLS/hart mismatch");
  if (task_tp[core] && task_tp[core] != tp) fpr_cpanic("probe: TLS changed");
  __atomic_store_n(&task_tp[core], tp, __ATOMIC_RELEASE);
  for (unsigned i = 0; i < FPR_NHARTS; i++)
    if (i != core && __atomic_load_n(&task_tp[i], __ATOMIC_ACQUIRE) == tp)
      fpr_cpanic("probe: TLS shared between harts");
  return TAG(core);
}
FPR_FN(fpr_g_Probe_x2etls, tls_check, 1);

extern unsigned fpr_watch_raised;
static V watcher_wakes(V u) {
  (void)u;
  return TAG(__atomic_load_n(&fpr_watch_raised, __ATOMIC_RELAXED));
}
FPR_FN(fpr_g_Probe_x2ewakes, watcher_wakes, 1);
