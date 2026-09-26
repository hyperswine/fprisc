/* main.c (esp-idf) -- boot: one hart per core.
 *
 * ESP-IDF's bootloader and startup bring up flash, PSRAM, clocks and
 * FreeRTOS; app_main then starts hart 0 pinned to core 0.  Hart 0 runs
 * the runtime's boot (buddy, hart blocks, actor 0), starts hart 1 pinned
 * to core 1, and becomes the hart loop.  The program's `main` is actor 0.
 *
 * The harts run at priority 1, just above IDLE: every IDF task (lwIP,
 * esp_hosted's SDIO transport, the event loop) outranks them, so the
 * tasks that produce what actors wait for are never starved by them.
 * An idle hart parks (hal_wfi), so IDLE runs and the watchdog is fed.
 */
#include "fpr.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_rom_sys.h"
#include "esp_log.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"

extern TaskHandle_t fpr_esp_hart_task[FPR_NHARTS];

/* machine/posix/base.c's command line: a board is started with none, so
 * Sys.args is the empty list (Sys.env answers Err "unset": newlib's
 * environment is empty too) */
int fpr_posix_argc = 0;
char **fpr_posix_argv = 0;
void fpr_rt_init(void);
void fpr_hart_main(int id);
void fpr_hart_secondary(int id);
void fpr_set_tp(fpr_hart_t *h);

/* bytes; also the internal stack file operations borrow (hal.c fpr_esp_cstack) */
#ifndef FPR_ESP_HART_STACK
#define FPR_ESP_HART_STACK 32768
#endif
#ifndef FPR_ESP_HART_PRIO
#define FPR_ESP_HART_PRIO 1
#endif

static void hart_task(void *arg) {
  int id = (int)(uintptr_t)arg;
  fpr_esp_hart_task[id] = xTaskGetCurrentTaskHandle();
  fpr_hart_secondary(id); /* sets the TLS hart slot, waits for hart 0's boot, joins the loop */
  vTaskDelete(NULL);
}

#ifdef FPR_ESP_DEBUG
#include "esp_heap_caps.h"
/* a failed allocation names its size, caps and caller; and the internal free
 * RAM is shown before the other constructors run (ESP-Hosted starts in one) */
static void fpr_alloc_failed(size_t n, uint32_t caps, const char *fn) {
    esp_rom_printf("[alloc] %s: %u bytes caps 0x%x failed; internal free %u largest %u\n", fn, (unsigned)n, (unsigned)caps,
                   (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL), (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
}
static void __attribute__((constructor(101))) fpr_early(void) {
    heap_caps_register_failed_alloc_callback(fpr_alloc_failed);
    esp_rom_printf("[boot] internal free %u before constructors\n", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    heap_caps_print_heap_info(MALLOC_CAP_INTERNAL);
}
#endif
#ifdef FPR_ESP_DEBUG
/* FPR_ESP_DEBUG: once a second, each hart's state, straight to the ROM UART
 * (no stdout, no locks: it must speak even when everything else is stuck) */
static void watch_task(void *arg) {
  (void)arg;
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(1000));
    for (int i = 0; i < FPR_NHARTS; i++) {
      fpr_hart_t *h = &fpr_harts[i];
      struct fpr_acb *c = h->current;
      esp_rom_printf("[watch] hart %d: epoch %u idle %u current %p\n", i, (unsigned)h->epoch, (unsigned)h->idle, (void *)c);
    }
  }
}
#endif

static void hart0_task(void *arg) {
  (void)arg;
  fpr_esp_hart_task[0] = xTaskGetCurrentTaskHandle();
#ifdef FPR_ESP_DEBUG
  xTaskCreatePinnedToCore(watch_task, "fpr-watch", 4096, NULL, 20, NULL, 1);
  esp_rom_printf("[boot] rt_init\n");
#endif
  extern void fpr_esp_fs_mount(void);
  fpr_esp_fs_mount(); /* before the runtime: a first-boot format needs this internal stack */
  fpr_rt_init();
#ifdef FPR_ESP_DEBUG
  esp_rom_printf("[boot] rt_init done; starting harts\n");
#endif
  for (int i = 1; i < FPR_NHARTS && i < portNUM_PROCESSORS; i++)
    xTaskCreatePinnedToCore(hart_task, "fpr-hart", FPR_ESP_HART_STACK, (void *)(uintptr_t)i, FPR_ESP_HART_PRIO, NULL, i);
#ifdef FPR_ESP_DEBUG
  esp_rom_printf("[boot] entering hart 0's loop\n");
#endif
  fpr_hart_main(0); /* the program's main is actor 0; returns only at its end */
  for (;;) vTaskDelay(portMAX_DELAY);
}

void app_main(void) {
#ifdef FPR_ESP_IO_SMOKE
  extern void fpr_esp_io_probe_init(void);
  fpr_esp_io_probe_init();
#endif
  /* IDF 5.3's SDMMC host driver assumes no SDIO (its own comment says so): the
   * C6 link's late DMA receive-complete interrupts land between transfers and
   * are logged as errors, dozens a second, though every transfer completes.
   * Newer IDF handles them; here that one tag is quieted. */
  esp_log_level_set("sdmmc_req", ESP_LOG_NONE);
  /* console input for Sys.readLine: without the UART driver IDF's stdin does
   * not wait -- every read is end-of-input at once.  With it, a read blocks
   * the calling hart until a line arrives, as reading stdin blocks a hart
   * thread on posix.  A terminal's Enter (CR) becomes "\n" (sdkconfig
   * NEWLIB_STDIN_LINE_ENDING_CR). */
  if (uart_driver_install(CONFIG_ESP_CONSOLE_UART_NUM, 1024, 0, 0, NULL, 0) == ESP_OK) {
    uart_vfs_dev_use_driver(CONFIG_ESP_CONSOLE_UART_NUM);
    /* the receive line glitches during reset: a 0xFF waits in the FIFO and
     * would lead the first line the program reads */
    uart_flush_input(CONFIG_ESP_CONSOLE_UART_NUM);
  }
  xTaskCreatePinnedToCore(hart0_task, "fpr-hart", FPR_ESP_HART_STACK, NULL, FPR_ESP_HART_PRIO, NULL, 0);
}
