/* Hardware-only regression: real compiler TLS and the current hart agree. */
#include "fpr.h"
#include "esp_cpu.h"
#include "esp_netif.h"
#include "esp_err.h"
#include "esp_rom_sys.h"
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

/* Probe.deepC n: n nested C frames of 1 KiB each, every byte written -- more
 * stack than an actor's headroom, to show the stack-bottom watchpoint turns
 * the overrun into a named fault (examples/stack-guard.fpr). */
static uintptr_t deepest;
static __attribute__((noinline)) unsigned deep_c(int n) {
  volatile unsigned char buf[1024];
  for (int i = 0; i < (int)sizeof buf; i++) buf[i] = (unsigned char)(n + i);
  if (n <= 0) deepest = (uintptr_t)buf;
  return n <= 0 ? buf[0] : buf[n % sizeof buf] + deep_c(n - 1);
}
static V probe_deep(V n) {
  uintptr_t top = (uintptr_t)__builtin_frame_address(0);
  unsigned r = deep_c((int)UNTAG(n));
  esp_rom_printf("[probe] deepC %d: from sp %p down to %p (%u KiB)\n", (int)UNTAG(n), (void *)top, (void *)deepest, (unsigned)((top - deepest) >> 10));
  return TAG((sw)(r & 0xffff));
}
FPR_FN(fpr_g_Probe_x2edeepC, probe_deep, 1);

/* Probe.stackInfo: the running actor's current segment and where sp is in it */
void *fpr_current_stack(uw *id, uw *size);
static V probe_stack_info(V u) {
  (void)u;
  uw id = 0, size = 0;
  char *lo = fpr_current_stack(&id, &size);
  uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
  esp_rom_printf("[probe] actor %u: stack segment %p, %u KiB, sp %u KiB above its bottom\n",
                 (unsigned)id, lo, (unsigned)(size >> 10), (unsigned)((sp - (uintptr_t)lo) >> 10));
  return TAG(0);
}
FPR_FN(fpr_g_Probe_x2estackInfo, probe_stack_info, 1);
