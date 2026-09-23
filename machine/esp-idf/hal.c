/* hal.c (esp-idf) -- the machine layer on ESP-IDF: FreeRTOS is the board.
 *
 * A hart is a FreeRTOS task pinned to a core (main.c), and everything the
 * runtime needs from a machine maps onto the RTOS:
 *
 *   hal_wfi / hal_ipi_send     wait on / give the hart task's notification
 *   hal_timer_arm / _park      the next deadline that wait honours
 *   hal_mtime                  esp_timer (microseconds) in virt's 10 MHz units
 *   hal_heap_span              one large block from the IDF heap: PSRAM when
 *                              the board has it, internal RAM otherwise
 *   hal_irq_*                  interrupts raised by IDF tasks, callbacks and
 *                              ISRs (hal_irq_raise), claimed by the IRQ hart
 *                              and delivered to an actor bound with Sys.irqBind
 *
 * tp is the running hart's pointer, as on bare metal.  IDF gives every task
 * a thread-local area in tp and saves and restores the LIVE tp with the task,
 * so a hart task that sets its own keeps it across preemption.  The price: C
 * code with `__thread` variables must not run on a hart task (IDF 5.3 has
 * none on this chip's path).
 */
#include "fpr.h"
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"
#include "esp_cpu.h"

TaskHandle_t fpr_esp_hart_task[FPR_NHARTS];

void hal_putc(char c) {
  fputc(c, stdout);
  if (c == '\n') fflush(stdout);
}

/* a board does not power off: say so, and let the caller park */
void hal_poweroff(int code) {
  fflush(stdout);
  printf("[fpr] program ended (status %d)\n", code);
  fflush(stdout);
}

uint64_t hal_mtime(void) { return (uint64_t)esp_timer_get_time() * 10u; }

int fpr_hal_sleep_us(uw us) {
  if (us >= 1000 * portTICK_PERIOD_MS) vTaskDelay(pdMS_TO_TICKS(us / 1000));
  else esp_rom_delay_us(us);
  return 1;
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

/* ---- interrupts from IDF: tasks, callbacks and ISRs raise, the IRQ hart claims ---- */
#define ESP_IRQ_MAX 1024
static uint8_t irq_pending[ESP_IRQ_MAX];
static uw irq_open_list[ESP_IRQ_MAX];
static uw irq_open_n;
static portMUX_TYPE irq_mux = portMUX_INITIALIZER_UNLOCKED;
void hal_irq_open(uw src) {
  if (src == 0 || src >= ESP_IRQ_MAX) return;
  taskENTER_CRITICAL(&irq_mux);
  int have = 0;
  for (uw i = 0; i < irq_open_n; i++) if (irq_open_list[i] == src) have = 1;
  if (!have) { irq_open_list[irq_open_n] = src; __atomic_store_n(&irq_open_n, irq_open_n + 1, __ATOMIC_RELEASE); }
  taskEXIT_CRITICAL(&irq_mux);
}
sw hal_irq_claim(void) {
  uw n = __atomic_load_n(&irq_open_n, __ATOMIC_ACQUIRE);
  for (uw i = 0; i < n; i++) {
    uw s = irq_open_list[i];
    if (__atomic_exchange_n(&irq_pending[s], 0, __ATOMIC_ACQ_REL)) return (sw)s;
  }
  return 0;
}
void hal_irq_ack(uw src) { (void)src; }
void hal_irq_raise(uw src) {
  if (src == 0 || src >= ESP_IRQ_MAX) return;
  __atomic_store_n(&irq_pending[src], 1, __ATOMIC_RELEASE);
  hal_ipi_send(fpr_irq_hart);
}
