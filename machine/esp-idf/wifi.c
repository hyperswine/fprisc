/* wifi.c (esp-idf) -- Wi-Fi through the board's ESP32-C6, as FP-RISC primitives.
 *
 * The P4 has no radio.  ESP-Hosted carries esp_wifi_* calls over SDIO to the
 * C6 (esp_wifi_remote), so each one is a round trip that can take hundreds of
 * milliseconds -- a scan, seconds.  None may run on a hart: it would stall
 * every actor on that core.  So they are JOBS, run by one broker task that is
 * allowed to block, and each finishes by raising an interrupt (hal_irq_raise)
 * that the runtime delivers to the actor bound to it:
 *
 *   slot = Esp.jobNew Unit          a job slot: its number is an IRQ source
 *   Sys.irqBind slot self           bind BEFORE starting (an unbound raise is lost)
 *   Esp.wifiScan slot               start the job; answers 0, or why not
 *   receive self                    ... the interrupt: the job is done
 *   Esp.jobResult slot              its result, as text; the slot is free again
 *
 * std/esp wraps that as a call that blocks only the calling actor.
 * Results are text, one line per item, fields separated by tabs. */
#include "fpr.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
/* esp_wifi_remote 1.6.3 on ESP-IDF 5.3.2: its headers come from idf_tag_v5.3.2
 * but its Kconfig from idf_v5.3, which lacks this one setting that
 * WIFI_INIT_CONFIG_DEFAULT reads when PSRAM is on.  Its own default: */
#if !defined(CONFIG_WIFI_RMT_CACHE_TX_BUFFER_NUM)
#define CONFIG_WIFI_RMT_CACHE_TX_BUFFER_NUM 32
#endif
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "esp_mac.h"

void hal_irq_raise(uw src);
void hal_irq_open(uw src);

#define JOB_BASE 900
#define JOB_SLOTS 64
static char *job_result[JOB_SLOTS];
static uint8_t job_used[JOB_SLOTS];
static portMUX_TYPE job_mux = portMUX_INITIALIZER_UNLOCKED;

typedef enum { J_SCAN, J_AP, J_AP_CLIENTS, J_STOP, J_INFO, J_BLE_SCAN, J_BLE_ADV } job_kind_t;
/* ble.c: Bluetooth LE through the same C6, the same broker */
char *fpr_ble_scan(int ms);
char *fpr_ble_adv(const char *name, int ms);
typedef struct { job_kind_t kind; int slot; char a[33]; char b[65]; int n; } job_t;
static QueueHandle_t jobq;

static char *text_of(V s, char *dst, size_t cap) {
  if (ISINT(s) || TID(s) != T_STR) fpr_cpanic("Esp: expected a String");
  str_t *t = (str_t *)s;
  size_t n = t->len < cap - 1 ? t->len : cap - 1;
  memcpy(dst, t->bytes, n);
  dst[n] = 0;
  return dst;
}

static void finish(int slot, char *text) {
  job_result[slot - JOB_BASE] = text;
  hal_irq_raise((uw)slot);
}
static char *dupf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  char *p = 0;
  if (vasprintf(&p, fmt, ap) < 0) p = 0;
  va_end(ap);
  return p ? p : strdup("error\tout of memory");
}

/* ---- the radio, brought up once ------------------------------------------ */
static int wifi_up;
static esp_netif_t *netif_sta, *netif_ap;
static const char *up(void) {
  if (wifi_up) return 0;
  esp_err_t e = nvs_flash_init();
  if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) { nvs_flash_erase(); e = nvs_flash_init(); }
  if (e != ESP_OK) return "nvs_flash_init failed";
  if (esp_netif_init() != ESP_OK) return "esp_netif_init failed";
  e = esp_event_loop_create_default();
  if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) return "event loop failed";
  netif_sta = esp_netif_create_default_wifi_sta();
  netif_ap = esp_netif_create_default_wifi_ap();
  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  if (esp_wifi_init(&cfg) != ESP_OK) return "esp_wifi_init failed (is the C6 answering?)";
  esp_wifi_set_storage(WIFI_STORAGE_RAM);
  wifi_up = 1;
  return 0;
}
static wifi_mode_t mode_now(void) { wifi_mode_t m = WIFI_MODE_NULL; esp_wifi_get_mode(&m); return m; }
static const char *auth_name(wifi_auth_mode_t a) {
  switch (a) {
    case WIFI_AUTH_OPEN: return "open"; case WIFI_AUTH_WEP: return "wep";
    case WIFI_AUTH_WPA_PSK: return "wpa"; case WIFI_AUTH_WPA2_PSK: return "wpa2";
    case WIFI_AUTH_WPA_WPA2_PSK: return "wpa/wpa2"; case WIFI_AUTH_WPA3_PSK: return "wpa3";
    case WIFI_AUTH_WPA2_WPA3_PSK: return "wpa2/wpa3"; case WIFI_AUTH_WPA2_ENTERPRISE: return "wpa2-enterprise";
    default: return "other";
  }
}

static char *do_scan(void) {
  const char *why = up();
  if (why) return dupf("error\t%s", why);
  wifi_mode_t m = mode_now();
  esp_err_t e = esp_wifi_set_mode(m == WIFI_MODE_AP || m == WIFI_MODE_APSTA ? WIFI_MODE_APSTA : WIFI_MODE_STA);
  if (e == ESP_OK) e = esp_wifi_start();
  if (e != ESP_OK && e != ESP_ERR_WIFI_CONN) return dupf("error\tstart: %s", esp_err_to_name(e));
  e = esp_wifi_scan_start(NULL, true);
  if (e != ESP_OK) return dupf("error\tscan: %s", esp_err_to_name(e));
  uint16_t n = 0;
  esp_wifi_scan_get_ap_num(&n);
  if (n > 40) n = 40;
  wifi_ap_record_t *r = calloc(n ? n : 1, sizeof *r);
  if (!r) return dupf("error\tout of memory");
  esp_wifi_scan_get_ap_records(&n, r);
  size_t cap = 64 + (size_t)n * 80, len = 0;
  char *out = malloc(cap);
  if (!out) { free(r); return dupf("error\tout of memory"); }
  out[0] = 0;
  for (int i = 0; i < n; i++)
    len += snprintf(out + len, cap - len, "%s\t%d\t%d\t%s\n", (char *)r[i].ssid, r[i].rssi, r[i].primary, auth_name(r[i].authmode));
  free(r);
  return out;
}

static char *do_ap(const char *ssid, const char *pass, int channel) {
  const char *why = up();
  if (why) return dupf("error\t%s", why);
  wifi_mode_t m = mode_now();
  esp_err_t e = esp_wifi_set_mode(m == WIFI_MODE_STA || m == WIFI_MODE_APSTA ? WIFI_MODE_APSTA : WIFI_MODE_AP);
  if (e != ESP_OK) return dupf("error\tset_mode: %s", esp_err_to_name(e));
  wifi_config_t c = {0};
  strncpy((char *)c.ap.ssid, ssid, sizeof c.ap.ssid - 1);
  c.ap.ssid_len = (uint8_t)strlen(ssid);
  strncpy((char *)c.ap.password, pass, sizeof c.ap.password - 1);
  c.ap.channel = channel > 0 ? channel : 6;
  c.ap.max_connection = 4;
  c.ap.authmode = strlen(pass) >= 8 ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
  e = esp_wifi_set_config(WIFI_IF_AP, &c);
  if (e != ESP_OK) return dupf("error\tset_config: %s", esp_err_to_name(e));
  e = esp_wifi_start();
  if (e != ESP_OK && e != ESP_ERR_WIFI_CONN) return dupf("error\tstart: %s", esp_err_to_name(e));
  esp_netif_ip_info_t ip = {0};
  if (netif_ap) esp_netif_get_ip_info(netif_ap, &ip);
  uint8_t mac[6] = {0};
  esp_wifi_get_mac(WIFI_IF_AP, mac);
  return dupf("ap\t%s\tchannel %d\t%s\tip " IPSTR "\tbssid %02x:%02x:%02x:%02x:%02x:%02x\n", ssid, c.ap.channel,
              auth_name(c.ap.authmode), IP2STR(&ip.ip), mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static char *do_ap_clients(void) {
  if (!wifi_up) return dupf("error\tWi-Fi is not up");
  wifi_sta_list_t l = {0};
  esp_err_t e = esp_wifi_ap_get_sta_list(&l);
  if (e != ESP_OK) return dupf("error\tsta_list: %s", esp_err_to_name(e));
  char *out = malloc(32 + (size_t)l.num * 48);
  if (!out) return dupf("error\tout of memory");
  size_t len = 0;
  out[0] = 0;
  for (int i = 0; i < l.num; i++)
    len += sprintf(out + len, "%02x:%02x:%02x:%02x:%02x:%02x\t%d\n", l.sta[i].mac[0], l.sta[i].mac[1], l.sta[i].mac[2],
                   l.sta[i].mac[3], l.sta[i].mac[4], l.sta[i].mac[5], l.sta[i].rssi);
  return out;
}

static char *do_info(void) {
  const char *why = up();
  if (why) return dupf("error\t%s", why);
  uint8_t sta[6] = {0}, ap[6] = {0};
  esp_wifi_get_mac(WIFI_IF_STA, sta);
  esp_wifi_get_mac(WIFI_IF_AP, ap);
  return dupf("radio\tsta %02x:%02x:%02x:%02x:%02x:%02x\tap %02x:%02x:%02x:%02x:%02x:%02x\tmode %d\n",
              sta[0], sta[1], sta[2], sta[3], sta[4], sta[5], ap[0], ap[1], ap[2], ap[3], ap[4], ap[5], (int)mode_now());
}

static void broker(void *arg) {
  (void)arg;
  job_t j;
  for (;;) {
    if (xQueueReceive(jobq, &j, portMAX_DELAY) != pdTRUE) continue;
    char *r = 0;
    switch (j.kind) {
      case J_SCAN: r = do_scan(); break;
      case J_AP: r = do_ap(j.a, j.b, j.n); break;
      case J_AP_CLIENTS: r = do_ap_clients(); break;
      case J_INFO: r = do_info(); break;
      case J_STOP: r = wifi_up && esp_wifi_stop() == ESP_OK ? strdup("stopped\n") : strdup("error\tnot running\n"); break;
      case J_BLE_SCAN: r = fpr_ble_scan(j.n); break;
      case J_BLE_ADV: r = fpr_ble_adv(j.a, j.n); break;
    }
    finish(j.slot, r);
  }
}

static void jobs_start(void) {
  static int started;
  taskENTER_CRITICAL(&job_mux);
  int go = !started;
  started = 1;
  taskEXIT_CRITICAL(&job_mux);
  if (!go) return;
  jobq = xQueueCreate(16, sizeof(job_t));
  /* priority 5: above the harts (1), well below lwIP and the SDIO transport */
  xTaskCreate(broker, "fpr-broker", 8192, NULL, 5, NULL);
}

static V j_new(V u) {
  (void)u;
  jobs_start();
  taskENTER_CRITICAL(&job_mux);
  int k = -1;
  for (int i = 0; i < JOB_SLOTS; i++) if (!job_used[i]) { job_used[i] = 1; job_result[i] = 0; k = i; break; }
  taskEXIT_CRITICAL(&job_mux);
  if (k < 0) fpr_cpanic("Esp.jobNew: every job slot is in use");
  hal_irq_open((uw)(JOB_BASE + k));
  return TAG((sw)(JOB_BASE + k));
}
FPR_FN(fpr_g_Esp_x2ejobNew, j_new, 1);

static int slot_of(V s) {
  if (!ISINT(s) || UNTAG(s) < JOB_BASE || UNTAG(s) >= JOB_BASE + JOB_SLOTS || !job_used[UNTAG(s) - JOB_BASE])
    fpr_cpanic("Esp: not a job slot");
  return (int)UNTAG(s);
}
static V j_result(V s) {
  int k = slot_of(s) - JOB_BASE;
  char *r = job_result[k];
  V out = (V)fpr_mkstr((const uint8_t *)(r ? r : ""), r ? (uw)strlen(r) : 0);
  free(r);
  job_result[k] = 0;
  job_used[k] = 0;
  return out;
}
FPR_FN(fpr_g_Esp_x2ejobResult, j_result, 1);

static V submit(job_t *j) { return TAG(xQueueSend(jobq, j, 0) == pdTRUE ? 0 : 1); }
static V w_scan(V s) { job_t j = {.kind = J_SCAN, .slot = slot_of(s)}; return submit(&j); }
FPR_FN(fpr_g_Esp_x2ewifiScan, w_scan, 1);
static V w_ap(V s, V ssid, V pass) {
  job_t j = {.kind = J_AP, .slot = slot_of(s), .n = 6};
  text_of(ssid, j.a, sizeof j.a);
  text_of(pass, j.b, sizeof j.b);
  return submit(&j);
}
FPR_FN(fpr_g_Esp_x2ewifiAp, w_ap, 3);
static V w_ap_clients(V s) { job_t j = {.kind = J_AP_CLIENTS, .slot = slot_of(s)}; return submit(&j); }
FPR_FN(fpr_g_Esp_x2ewifiApClients, w_ap_clients, 1);
static V w_info(V s) { job_t j = {.kind = J_INFO, .slot = slot_of(s)}; return submit(&j); }
FPR_FN(fpr_g_Esp_x2ewifiInfo, w_info, 1);
static V w_stop(V s) { job_t j = {.kind = J_STOP, .slot = slot_of(s)}; return submit(&j); }
FPR_FN(fpr_g_Esp_x2ewifiStop, w_stop, 1);

/* Esp.bleScan slot ms: the devices heard in ms milliseconds (active scan, so
 * names in scan responses count), one per line: address, rssi, name */
static V b_scan(V s, V ms) {
  if (!ISINT(ms)) fpr_cpanic("Esp.bleScan: milliseconds must be an Int");
  job_t j = {.kind = J_BLE_SCAN, .slot = slot_of(s), .n = (int)UNTAG(ms)};
  return submit(&j);
}
FPR_FN(fpr_g_Esp_x2ebleScan, b_scan, 2);
/* Esp.bleAdvertise slot name ms: advertise as `name` (non-connectable,
 * general discoverable) for ms milliseconds; answers once it has started */
static V b_adv(V s, V name, V ms) {
  if (!ISINT(ms)) fpr_cpanic("Esp.bleAdvertise: milliseconds must be an Int");
  job_t j = {.kind = J_BLE_ADV, .slot = slot_of(s), .n = (int)UNTAG(ms)};
  text_of(name, j.a, 30);
  return submit(&j);
}
FPR_FN(fpr_g_Esp_x2ebleAdvertise, b_adv, 3);
