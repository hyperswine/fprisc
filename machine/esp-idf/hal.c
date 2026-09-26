/* hal.c (esp-idf) -- the posix system's esp-idf HOST: FreeRTOS is the board.
 *
 * A hart is a FreeRTOS task pinned to a core (main.c), and what the runtime
 * needs from a machine that the shared machine/posix/hal.c does not give
 * (the console, the clock, the host sleep and the IRQ bridge are there,
 * over the POSIX subset IDF has) maps onto the RTOS here:
 *
 *   hal_wfi / hal_ipi_send     wait on / give the hart task's notification
 *   hal_timer_arm / _park      the next deadline that wait honours
 *   hal_heap_span              one large block from the IDF heap: PSRAM when
 *                              the board has it, internal RAM otherwise
 *   hal_poweroff               a board has nothing to exit to
 *   fpr_esp_cstack             C calls that must leave the actor's PSRAM stack
 *   hal_actor_stack            the opt-in watchpoint stack guard
 *
 * IDF's tp remains its C TLS pointer. The runtime stores the current hart
 * in fpr_esp_hart, a real TLS slot, and loads it afresh across actor switches.
 */
#include "fpr.h"
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "esp_cpu.h"

TaskHandle_t fpr_esp_hart_task[FPR_NHARTS];

/* A board has nothing to exit to.  The program ends here for good: the other
 * harts are suspended and this one sleeps forever (it used to return, so a
 * Sys.exit in the middle of a program printed "ended" and carried on).
 * IDF's own tasks -- the radio, lwIP -- keep running; a reset starts over. */
void hal_poweroff(int code) {
  fflush(stdout);
  printf("[fpr] program ended (status %d)\n", code);
  fflush(stdout);
  TaskHandle_t self = xTaskGetCurrentTaskHandle();
  for (int i = 0; i < FPR_NHARTS; i++)
    if (fpr_esp_hart_task[i] && fpr_esp_hart_task[i] != self) vTaskSuspend(fpr_esp_hart_task[i]);
  for (;;) vTaskDelay(portMAX_DELAY);
}

/* ---- sleep and wake ----------------------------------------------------- */
static uint64_t deadline[FPR_NHARTS]; /* mtime; 0 = none.  Only its own hart touches it */
#define PARK_CAP_MS 20                /* no wake source may be load-bearing: see machine/posix */

void hal_wfi_enable(void) {}
void hal_wfi(void) {
  uw id = fpr_hart()->id;
  TickType_t wait = pdMS_TO_TICKS(PARK_CAP_MS);
  if (deadline[id]) {
    uint64_t now = hal_mtime();
    uint64_t left_us = deadline[id] > now ? (deadline[id] - now) / 10 : 0;
    TickType_t t = (TickType_t)((left_us + 999) / 1000 / portTICK_PERIOD_MS);
    if (t < wait) wait = t;
  }
  if (wait) ulTaskNotifyTake(pdTRUE, wait);
  if (deadline[id] && hal_mtime() >= deadline[id]) deadline[id] = 0;
}
void hal_ipi_send(uw hart) {
  TaskHandle_t t = hart < FPR_NHARTS ? fpr_esp_hart_task[hart] : 0;
  if (!t) return; /* not up yet: its loop checks its rings before it first waits */
  if (xPortInIsrContext()) {
    BaseType_t woke = pdFALSE;
    vTaskNotifyGiveFromISR(t, &woke);
    portYIELD_FROM_ISR(woke);
  } else {
    xTaskNotifyGive(t);
  }
}
/* the hart's own: drop a pending bell (the loop re-checks after this) */
void hal_ipi_clear(uw hart) { (void)hart; ulTaskNotifyTake(pdTRUE, 0); }
void hal_timer_park(uw hart) { if (hart < FPR_NHARTS) deadline[hart] = 0; }
void hal_timer_arm(uw hart, uint64_t delta) {
  if (hart < FPR_NHARTS) deadline[hart] = hal_mtime() + (delta ? delta : 1);
}
int hal_timer_native(void) { return 0; }

/* ---- the heap ----------------------------------------------------------------
 * One block from IDF's heap, taken once: PSRAM when the board has it, else
 * internal RAM.  What is left is IDF's (lwIP, Wi-Fi, drivers): FPR_ESP_KEEP_KB
 * of it at least. */
#ifndef FPR_ESP_KEEP_KB
#define FPR_ESP_KEEP_KB 192
#endif
static char *heap_lo, *heap_hi;
void hal_heap_span(char **lo, char **hi, char **span_hi) {
  if (!heap_lo) {
    uint32_t caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    size_t big = heap_caps_get_largest_free_block(caps);
    if (big < 1024 * 1024) { caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT; big = heap_caps_get_largest_free_block(caps); }
    size_t keep = (size_t)FPR_ESP_KEEP_KB * 1024;
    size_t want = (caps & MALLOC_CAP_SPIRAM) ? big - (big / 16) : (big > keep * 2 ? big - keep : big / 2);
    heap_lo = heap_caps_malloc(want, caps);
    if (!heap_lo) fpr_cpanic("esp: no heap block for the runtime");
    heap_hi = heap_lo + want;
    printf("[fpr] heap: %u KiB of %s\n", (unsigned)(want >> 10), (caps & MALLOC_CAP_SPIRAM) ? "PSRAM" : "internal RAM");
  }
  *lo = heap_lo;
  *hi = heap_hi;
  *span_hi = heap_hi;
}
void hal_heap_release(void *p, uw bytes) { (void)p; (void)bytes; }

/* no guard pages yet: the P4's PMP is the natural place for them */
void hal_stack_guard(void *lo, uw size) { (void)lo; (void)size; }
void hal_stack_unguard(void *lo, uw size) { (void)lo; (void)size; }

/* interrupts from IDF tasks, callbacks and ISRs: the shared bridge in
 * machine/posix/hal.c (hal_irq_raise is atomics only, so an ISR may call it;
 * hal_irq_open takes a mutex and is called from hart and broker tasks) */

/* ---- C calls that must not run on an actor's stack ------------------------
 * Actor stacks are in PSRAM (hal_heap_span).  IDF asserts that a flash
 * operation runs on an internal stack -- the write disables the cache PSRAM
 * is read through -- and every FAT file operation can reach flash.  So those
 * primitives (FPR_FN_CSTACK in fpr.h) run on the HART TASK's own stack: while
 * an actor runs, that FreeRTOS stack is idle below the hart loop's saved sp
 * (sched_ctx[1]).  The call is synchronous and never yields, so nothing else
 * uses that region meanwhile; preemption by IDF tasks saves onto it, which is
 * what FreeRTOS's own stack checks expect anyway. */
#include "esp_memory_utils.h"
#include "freertos/idf_additions.h"
V fpr_cstack_call(void *fn, V a, V b, V c, void *top);
#ifndef FPR_ESP_CSTACK_NEED
#define FPR_ESP_CSTACK_NEED 8192 /* FAT + wear levelling + esp_flash, with margin */
#endif
V fpr_esp_cstack(void *fn, V a, V b, V c) {
  fpr_hart_t *h = fpr_hart();
  void *sp = __builtin_frame_address(0);
  if (!h || !h->current || esp_ptr_internal(sp)) /* already on an internal stack */
    return ((V (*)(V, V, V))fn)(a, b, c);
  uintptr_t top = ((uintptr_t)h->sched_ctx[1] - 256) & ~(uintptr_t)15; /* below the hart loop's frame */
  uintptr_t low = (uintptr_t)pxTaskGetStackStart(fpr_esp_hart_task[h->id]);
  if (!esp_ptr_internal((void *)top) || top < low + FPR_ESP_CSTACK_NEED)
    fpr_cpanic("esp: no internal stack room for a file operation (raise FPR_ESP_HART_STACK)");
  return fpr_cstack_call(fn, a, b, c, (void *)top);
}

/* ---- the running actor's stack bottom, watched ----------------------------
 * No MMU, so no guard pages: FP-RISC code keeps FPR_STACK_HEADROOM below
 * itself and grows the stack before reaching it, but C code that uses more
 * (deep recursion in a primitive, a large local array) used to run straight
 * past the segment into the neighbouring heap block, silently.  Each core's
 * watchpoint 0 covers the lowest 32 bytes of the segment its actor runs on
 * (FreeRTOS keeps the last watchpoint for its own optional stack check), so
 * such a write is a named fault and a reset -- "fpr run" reports the board
 * reset -- instead of corruption.  Best effort, as guard pages are: a frame
 * that skips the 32 bytes without writing them is not seen.
 *
 * OPT-IN (FPR_ESP_STACK_GUARD=1 at build): measured on the P4, an armed store
 * watchpoint slows every store on its core -- fib 27 took 251 ms with it and
 * 160 ms without, cross-core round trips 340 ms against 293.  A development
 * build turns it on; the runtime's 64 KiB headroom stands in otherwise. */
#define FPR_STACK_WATCHPOINT 0
void hal_actor_stack(void *lo) {
#ifndef FPR_ESP_STACK_GUARD
  (void)lo; /* opt-in: an armed store watchpoint slows every store on the core */
#else
  if (!lo) { esp_cpu_clear_watchpoint(FPR_STACK_WATCHPOINT); return; }
  uintptr_t a = ((uintptr_t)lo + 31) & ~(uintptr_t)31;
  esp_cpu_set_watchpoint(FPR_STACK_WATCHPOINT, (void *)a, 32, ESP_CPU_WATCHPOINT_STORE);
#endif
}
