/* bluetooth.c (platform/esp-idf) -- Bluetooth LE, for std/ble: NimBLE here.
 *
 * The board's ESP32-C6 runs the BLE controller; the P4 runs the NimBLE host,
 * and ESP-Hosted carries HCI between them over the SDIO link Wi-Fi also uses
 * (its "VHCI" transport).  Calls are jobs on the broker (machine/posix/os_job.c); NimBLE's
 * callbacks arrive on its own host task, and the job waits for the one that
 * ends it.  Rows of tab-separated fields, parsed by std/ble:
 *
 *   BleHost.scan slot ms            per device heard: address, rssi, name ("" if none)
 *   BleHost.advertise slot name ms  name, own address -- once advertising has begun
 *
 * Nothing else in the tree names this file: a program that does not import
 * std/ble does not link it, or NimBLE. */
#include "os_job.h"
const char *fpr_radio_up(void);
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs_flash.h"
#include "esp_hosted.h"
#include "esp_hosted_misc.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"

static int ble_ready;
static uint8_t own_type;
static SemaphoreHandle_t synced, done;

static void on_sync(void) { xSemaphoreGive(synced); }
static void on_reset(int reason) { (void)reason; }
static void host_task(void *arg) {
  (void)arg;
  nimble_port_run(); /* returns only after nimble_port_stop */
  nimble_port_freertos_deinit();
}

/* the controller on the C6, the host here; once */
static const char *up_once(void);
static const char *up(void) {
  static const char *failed;
  if (ble_ready) return 0;
  if (!failed) failed = up_once();
  return failed;
}
static const char *up_once(void) {
  esp_err_t e = nvs_flash_init(); /* NimBLE keeps its bonds there */
  if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) { nvs_flash_erase(); e = nvs_flash_init(); }
  if (e != ESP_OK) return "nvs_flash_init failed";
  const char *link = fpr_radio_up(); /* radio.c: the C6, on first use */
  if (link) return link;
  esp_hosted_connect_to_slave();
  /* Current co-processor firmware starts its controller when asked (an RPC,
   * FeatureControl).  Older firmware -- this board's C6 reports 0.0.0 -- does
   * not know that RPC (it times out after 5 s) but started the controller at
   * its own boot.  So a failure here is not final: the host's sync below is
   * the real test, and a controller that is not there fails it. */
  if (esp_hosted_bt_controller_init() == ESP_OK) esp_hosted_bt_controller_enable();
  if (nimble_port_init() != ESP_OK) return "nimble_port_init failed";
  synced = xSemaphoreCreateBinary();
  done = xSemaphoreCreateBinary();
  ble_hs_cfg.sync_cb = on_sync;
  ble_hs_cfg.reset_cb = on_reset;
  nimble_port_freertos_init(host_task);
  if (xSemaphoreTake(synced, pdMS_TO_TICKS(8000)) != pdTRUE) return "the NimBLE host never synced with the C6's controller (no controller answered HCI)";
  if (ble_hs_util_ensure_addr(0) != 0) return "no usable Bluetooth address";
  if (ble_hs_id_infer_auto(0, &own_type) != 0) return "no usable address type";
  ble_ready = 1;
  return 0;
}

static void addr_text(const uint8_t *a, char *out) { /* NimBLE stores it little-endian */
  sprintf(out, "%02x:%02x:%02x:%02x:%02x:%02x", a[5], a[4], a[3], a[2], a[1], a[0]);
}

/* ---- scan -------------------------------------------------------------------
 * One entry per address heard, in a table that GROWS (it had a fixed 96 and
 * reported the rest as a count).  A legacy advertisement is 31 bytes, so a
 * name in it is at most 29: the 32-byte field holds any. */
typedef struct { uint8_t addr[6]; int8_t rssi; char name[32]; } seen_t;
static seen_t *seen;
static int nseen, seen_cap, seen_oom;

static int disc_cb(struct ble_gap_event *ev, void *arg) {
  (void)arg;
  if (ev->type == BLE_GAP_EVENT_DISC_COMPLETE) {
    xSemaphoreGive(done);
    return 0;
  }
  if (ev->type != BLE_GAP_EVENT_DISC) return 0;
  const struct ble_gap_disc_desc *d = &ev->disc;
  int i = 0;
  while (i < nseen && memcmp(seen[i].addr, d->addr.val, 6) != 0) i++;
  if (i == nseen) {
    if (nseen == seen_cap) {
      int cap = seen_cap ? seen_cap * 2 : 64;
      seen_t *g = realloc(seen, (size_t)cap * sizeof *g);
      if (!g) { seen_oom = 1; return 0; } /* reported as the scan's error */
      seen = g;
      seen_cap = cap;
    }
    memcpy(seen[i].addr, d->addr.val, 6);
    seen[i].name[0] = 0;
    nseen++;
  }
  seen[i].rssi = d->rssi;
  struct ble_hs_adv_fields f;
  if (ble_hs_adv_parse_fields(&f, d->data, d->length_data) == 0 && f.name && f.name_len) {
    size_t n = f.name_len < sizeof seen[i].name - 1 ? f.name_len : sizeof seen[i].name - 1;
    memcpy(seen[i].name, f.name, n);
    seen[i].name[n] = 0;
    fpr_job_field_safe(seen[i].name);
  }
  return 0;
}
static int by_rssi(const void *a, const void *b) { return ((const seen_t *)b)->rssi - ((const seen_t *)a)->rssi; }

static char *do_scan(int ms) {
  const char *why = up();
  if (why) return fpr_job_printf("error\t%s\n", why);
  if (ms < 100) ms = 100;
  nseen = 0;
  seen_oom = 0;
  struct ble_gap_disc_params dp;
  memset(&dp, 0, sizeof dp);
  dp.passive = 0;           /* active: ask for scan responses, where names often are */
  dp.filter_duplicates = 0; /* keep the rssi fresh; the table dedups by address */
  xSemaphoreTake(done, 0);
  int rc = ble_gap_disc(own_type, ms, &dp, disc_cb, NULL);
  if (rc != 0) return fpr_job_printf("error\tble_gap_disc failed (%d)\n", rc);
  if (xSemaphoreTake(done, pdMS_TO_TICKS(ms + 3000)) != pdTRUE) {
    ble_gap_disc_cancel();
    return fpr_job_printf("error\tthe scan never completed\n");
  }
  if (seen_oom) return fpr_job_printf("error\tout of memory for the devices heard\n");
  qsort(seen, nseen, sizeof seen[0], by_rssi);
  size_t cap = (size_t)nseen * 64 + 64, len = 0;
  char *out = malloc(cap);
  if (!out) return fpr_job_printf("error\tout of memory\n");
  out[0] = 0;
  for (int i = 0; i < nseen; i++) {
    char a[18];
    addr_text(seen[i].addr, a);
    len += snprintf(out + len, cap - len, "%s\t%d\t%s\n", a, seen[i].rssi, seen[i].name);
  }
  return out;
}

/* ---- advertise ------------------------------------------------------------- */
static int adv_cb(struct ble_gap_event *ev, void *arg) {
  (void)ev;
  (void)arg;
  return 0; /* BLE_GAP_EVENT_ADV_COMPLETE when the duration ends: nothing to do */
}

static char *do_advertise(const char *nm, int ms) {
  const char *why = up();
  if (why) return fpr_job_printf("error\t%s\n", why);
  if (ble_gap_adv_active()) ble_gap_adv_stop();
  ble_svc_gap_device_name_set(nm);
  struct ble_hs_adv_fields f;
  memset(&f, 0, sizeof f);
  f.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
  f.name = (uint8_t *)(uintptr_t)nm;
  f.name_len = strlen(nm);
  f.name_is_complete = 1;
  int rc = ble_gap_adv_set_fields(&f);
  if (rc != 0) return fpr_job_printf("error\tble_gap_adv_set_fields failed (%d)\n", rc);
  struct ble_gap_adv_params ap;
  memset(&ap, 0, sizeof ap);
  ap.conn_mode = BLE_GAP_CONN_MODE_NON;
  ap.disc_mode = BLE_GAP_DISC_MODE_GEN;
  rc = ble_gap_adv_start(own_type, NULL, ms > 0 ? ms : BLE_HS_FOREVER, &ap, adv_cb, NULL);
  if (rc != 0) return fpr_job_printf("error\tble_gap_adv_start failed (%d)\n", rc);
  uint8_t a[6];
  char at[18] = "?";
  if (ble_hs_id_copy_addr(own_type, a, NULL) == 0) addr_text(a, at);
  return fpr_job_printf("%s\t%s\n", nm, at);
}

/* ---- the jobs, and the primitives that submit them ---------------------------- */
static char *run_scan(const fpr_job_t *j) { return do_scan(j->n); }
static char *run_advertise(const fpr_job_t *j) { return do_advertise(j->a, j->n); }

static V b_scan(V s, V ms) {
  if (!ISINT(ms)) fpr_cpanic("BleHost.scan: milliseconds must be an Int");
  fpr_job_t j = {.run = run_scan, .slot = fpr_job_slot(s), .n = (int)UNTAG(ms)};
  return fpr_job_submit(&j);
}
FPR_FN(fpr_g_BleHost_x2escan, b_scan, 2);

static V b_advertise(V s, V name, V ms) {
  if (!ISINT(ms)) fpr_cpanic("BleHost.advertise: milliseconds must be an Int");
  fpr_job_t j = {.run = run_advertise, .slot = fpr_job_slot(s), .n = (int)UNTAG(ms)};
  /* a legacy advertisement is 31 bytes: flags (3) + the name's header (2)
   * leave 26 for the name -- refused past that, never cut */
  size_t n = fpr_job_text(name, j.a, sizeof j.a);
  if (n == 0 || n > 26) j.bad = "a BLE advertising name is 1 to 26 bytes";
  else if (memchr(j.a, 0, n) || strpbrk(j.a, "\t\n\r")) j.bad = "a BLE advertising name may not contain NUL, tab or newline";
  return fpr_job_submit(&j);
}
FPR_FN(fpr_g_BleHost_x2eadvertise, b_advertise, 3);
