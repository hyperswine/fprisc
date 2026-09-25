/* radio.c (platform/esp-idf) -- the link to the board's radio chip, started
 * on first use instead of at boot.
 *
 * ESP-Hosted links itself WHOLE (its CMakeLists sets WHOLE_ARCHIVE) and starts
 * from a C constructor, so every image -- a program with no radio code at all
 * -- used to reset the ESP32-C6 and bring up the SDIO link before app_main,
 * when only ~110 KiB of internal RAM is usable (docs/ESP-IDF.md).  The build
 * wraps its esp_hosted_init (-Wl,--wrap, project/main/CMakeLists.txt): the
 * constructor's call, made before the scheduler runs, does nothing, and
 * wifi.c and bluetooth.c start the link here, from the broker task, the first
 * time a program uses the radio.  A program that never imports std/wifi or
 * std/ble never touches the C6.
 *
 * The link is up when ESP-Hosted posts ESP_HOSTED_EVENT_TRANSPORT_UP;
 * fpr_radio_up waits for that, bounded and named. */
#include "fpr.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_event.h"
#include "esp_hosted.h"
#include "esp_hosted_event.h"

int __real_esp_hosted_init(void);

int __wrap_esp_hosted_init(void) {
  if (xTaskGetSchedulerState() == taskSCHEDULER_NOT_STARTED)
    return 0; /* ESP-Hosted's own constructor: deferred to fpr_radio_up */
  return __real_esp_hosted_init();
}

static void on_transport_up(void *arg, esp_event_base_t base, int32_t id, void *data) {
  (void)base; (void)id; (void)data;
  xSemaphoreGive((SemaphoreHandle_t)arg);
}

/* the link up, once; 0 or why not.  Radio jobs all run on the broker task,
 * one at a time, so this needs no lock. */
const char *fpr_radio_up(void) {
  static int up;
  static const char *failed;
  if (up) return 0;
  if (failed) return failed;
  esp_err_t e = esp_event_loop_create_default();
  if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) return failed = "the default event loop could not be created";
  SemaphoreHandle_t ready = xSemaphoreCreateBinary();
  esp_event_handler_instance_t h;
  if (!ready || esp_event_handler_instance_register(ESP_HOSTED_EVENT, ESP_HOSTED_EVENT_TRANSPORT_UP,
                                                    on_transport_up, ready, &h) != ESP_OK)
    return failed = "could not wait for the radio link";
  /* init only sets the transport up; connect resets the C6, initialises the
   * SDIO card and waits until the C6 answers (transport_drv_reconfigure).
   * At boot the first esp_wifi_* call used to reach that on its own; a
   * deferred start has to make it.  A second call is a no-op ("Transport is
   * already up"), so bluetooth.c's own call stays harmless. */
  __real_esp_hosted_init();
  esp_hosted_connect_to_slave();
  int ok = xSemaphoreTake(ready, pdMS_TO_TICKS(10000)) == pdTRUE;
  esp_event_handler_instance_unregister(ESP_HOSTED_EVENT, ESP_HOSTED_EVENT_TRANSPORT_UP, h);
  vSemaphoreDelete(ready);
  if (!ok) return failed = "the link to the radio chip (ESP-Hosted over SDIO) did not come up within 10 s";
  up = 1;
  return 0;
}
