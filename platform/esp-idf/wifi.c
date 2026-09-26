/* wifi.c (platform/esp-idf) -- Wi-Fi, for std/wifi: esp_wifi on this platform.
 *
 * The ESP32-P4 has no radio.  ESP-Hosted carries esp_wifi_* calls over SDIO
 * to the board's ESP32-C6 (esp_wifi_remote), so each is a round trip that can
 * take hundreds of milliseconds -- a scan, seconds.  They run as jobs on the
 * broker (machine/posix/os_job.c), never on a hart.  Each answers rows of tab-separated
 * fields, which std/wifi parses into records:
 *
 *   WifiHost.info slot          station MAC, AP MAC, mode (off|station|ap|station+ap)
 *   WifiHost.scan slot          per network: ssid, rssi, channel, auth
 *   WifiHost.ap slot ssid pass  ssid, channel, auth, ip, bssid -- once the interface is up
 *   WifiHost.stations slot      per joined station: mac, rssi
 *   WifiHost.stop slot          nothing
 *
 * Another platform provides the same five primitives to give std/wifi a
 * radio (nl80211 on Linux, say); where none does, a program importing it
 * fails at link time by name. */
#include "os_job.h"
const char *fpr_radio_up(void);
int fpr_esp_net_up(void);
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
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

/* ---- the radio, brought up once ------------------------------------------ */
static int wifi_up;
static esp_netif_t *netif_sta, *netif_ap;
static const char *up(void) {
  if (wifi_up) return 0;
  esp_err_t e = nvs_flash_init();
  if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) { nvs_flash_erase(); e = nvs_flash_init(); }
  if (e != ESP_OK) return "nvs_flash_init failed";
  const char *link = fpr_radio_up(); /* radio.c: the C6, on first use */
  if (link) return link;
  if (!fpr_esp_net_up()) return "the network stack (lwIP) could not be started"; /* machine/posix/os_net.c */
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
  if (why) return fpr_job_printf("error\t%s", why);
  wifi_mode_t m = mode_now();
  esp_err_t e = esp_wifi_set_mode(m == WIFI_MODE_AP || m == WIFI_MODE_APSTA ? WIFI_MODE_APSTA : WIFI_MODE_STA);
  if (e == ESP_OK) e = esp_wifi_start();
  if (e != ESP_OK && e != ESP_ERR_WIFI_CONN) return fpr_job_printf("error\tstart: %s", esp_err_to_name(e));
  e = esp_wifi_scan_start(NULL, true);
  if (e != ESP_OK) return fpr_job_printf("error\tscan: %s", esp_err_to_name(e));
  uint16_t n = 0;
  esp_wifi_scan_get_ap_num(&n); /* every record the driver kept: no cap of ours */
  wifi_ap_record_t *r = calloc(n ? n : 1, sizeof *r);
  if (!r) return fpr_job_printf("error\tout of memory");
  esp_wifi_scan_get_ap_records(&n, r);
  size_t cap = 64 + (size_t)n * 80, len = 0;
  char *out = malloc(cap);
  if (!out) { free(r); return fpr_job_printf("error\tout of memory"); }
  out[0] = 0;
  for (int i = 0; i < n; i++) {
    char ssid[33];
    snprintf(ssid, sizeof ssid, "%s", (char *)r[i].ssid);
    fpr_job_field_safe(ssid);
    len += snprintf(out + len, cap - len, "%s\t%d\t%d\t%s\n", ssid, r[i].rssi, r[i].primary, auth_name(r[i].authmode));
  }
  free(r);
  return out;
}

static char *do_ap(const char *ssid, const char *pass, int channel) {
  const char *why = up();
  if (why) return fpr_job_printf("error\t%s", why);
  wifi_mode_t m = mode_now();
  esp_err_t e = esp_wifi_set_mode(m == WIFI_MODE_STA || m == WIFI_MODE_APSTA ? WIFI_MODE_APSTA : WIFI_MODE_AP);
  if (e != ESP_OK) return fpr_job_printf("error\tset_mode: %s", esp_err_to_name(e));
  wifi_config_t c = {0};
  /* both fields are exactly the protocol's size and need no NUL: a 32-byte
   * SSID and a 64-hex-digit key fill them (w_ap checked the lengths) */
  memcpy(c.ap.ssid, ssid, strlen(ssid));
  c.ap.ssid_len = (uint8_t)strlen(ssid);
  memcpy(c.ap.password, pass, strlen(pass));
  c.ap.channel = channel > 0 ? channel : 6;
  c.ap.max_connection = 4;
  /* w_ap already refused every other length: "" is open by request, never by accident */
  c.ap.authmode = pass[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
  e = esp_wifi_set_config(WIFI_IF_AP, &c);
  if (e != ESP_OK) return fpr_job_printf("error\tset_config: %s", esp_err_to_name(e));
  e = esp_wifi_start();
  if (e != ESP_OK && e != ESP_ERR_WIFI_CONN) return fpr_job_printf("error\tstart: %s", esp_err_to_name(e));
  /* esp_wifi_start returns before the access point exists: its interface comes
   * up when the C6's AP_START event reaches the default handler.  Answering
   * before that gave a caller an address that was not reachable yet (a
   * connect to 192.168.4.1 failed "host is unreachable").  Answer when it is
   * up -- the SDIO round trip takes tens of ms -- or say that it never came. */
  for (int waited = 0; !esp_netif_is_netif_up(netif_ap); waited += 20) {
    if (waited >= 10000) return fpr_job_printf("error\tthe access point did not come up within 10 s");
    vTaskDelay(pdMS_TO_TICKS(20));
  }
  esp_netif_ip_info_t ip = {0};
  if (netif_ap) esp_netif_get_ip_info(netif_ap, &ip);
  uint8_t mac[6] = {0};
  esp_wifi_get_mac(WIFI_IF_AP, mac);
  return fpr_job_printf("%s\t%d\t%s\t" IPSTR "\t%02x:%02x:%02x:%02x:%02x:%02x\n", ssid, c.ap.channel,
              auth_name(c.ap.authmode), IP2STR(&ip.ip), mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static char *do_ap_clients(void) {
  if (!wifi_up) return fpr_job_printf("error\tWi-Fi is not up");
  wifi_sta_list_t l = {0};
  esp_err_t e = esp_wifi_ap_get_sta_list(&l);
  if (e != ESP_OK) return fpr_job_printf("error\tsta_list: %s", esp_err_to_name(e));
  char *out = malloc(32 + (size_t)l.num * 48);
  if (!out) return fpr_job_printf("error\tout of memory");
  size_t len = 0;
  out[0] = 0;
  for (int i = 0; i < l.num; i++)
    len += sprintf(out + len, "%02x:%02x:%02x:%02x:%02x:%02x\t%d\n", l.sta[i].mac[0], l.sta[i].mac[1], l.sta[i].mac[2],
                   l.sta[i].mac[3], l.sta[i].mac[4], l.sta[i].mac[5], l.sta[i].rssi);
  return out;
}

static char *do_info(void) {
  const char *why = up();
  if (why) return fpr_job_printf("error\t%s", why);
  uint8_t sta[6] = {0}, ap[6] = {0};
  esp_wifi_get_mac(WIFI_IF_STA, sta);
  esp_wifi_get_mac(WIFI_IF_AP, ap);
  wifi_mode_t m = mode_now();
  const char *mode = m == WIFI_MODE_STA ? "station" : m == WIFI_MODE_AP ? "ap" : m == WIFI_MODE_APSTA ? "station+ap" : "off";
  return fpr_job_printf("%02x:%02x:%02x:%02x:%02x:%02x\t%02x:%02x:%02x:%02x:%02x:%02x\t%s\n",
              sta[0], sta[1], sta[2], sta[3], sta[4], sta[5], ap[0], ap[1], ap[2], ap[3], ap[4], ap[5], mode);
}

/* ---- the jobs, and the primitives that submit them ---------------------------- */
static char *run_scan(const fpr_job_t *j) { (void)j; return do_scan(); }
static char *run_ap(const fpr_job_t *j) { return do_ap(j->a, j->b, j->n); }
static char *run_stations(const fpr_job_t *j) { (void)j; return do_ap_clients(); }
static char *run_info(const fpr_job_t *j) { (void)j; return do_info(); }
static char *run_stop(const fpr_job_t *j) {
  (void)j;
  return wifi_up && esp_wifi_stop() == ESP_OK ? strdup("") : fpr_job_printf("error\tWi-Fi is not running\n");
}

static V w_scan(V s) { fpr_job_t j = {.run = run_scan, .slot = fpr_job_slot(s)}; return fpr_job_submit(&j); }
FPR_FN(fpr_g_WifiHost_x2escan, w_scan, 1);
static V w_stations(V s) { fpr_job_t j = {.run = run_stations, .slot = fpr_job_slot(s)}; return fpr_job_submit(&j); }
FPR_FN(fpr_g_WifiHost_x2estations, w_stations, 1);
static V w_info(V s) { fpr_job_t j = {.run = run_info, .slot = fpr_job_slot(s)}; return fpr_job_submit(&j); }
FPR_FN(fpr_g_WifiHost_x2einfo, w_info, 1);
static V w_stop(V s) { fpr_job_t j = {.run = run_stop, .slot = fpr_job_slot(s)}; return fpr_job_submit(&j); }
FPR_FN(fpr_g_WifiHost_x2estop, w_stop, 1);

static V w_ap(V s, V ssid, V pass) {
  fpr_job_t j = {.run = run_ap, .slot = fpr_job_slot(s), .n = 6};
  size_t ns = fpr_job_text(ssid, j.a, sizeof j.a), np = fpr_job_text(pass, j.b, sizeof j.b);
  /* the protocol's limits, refused by name, never truncated or downgraded:
   * an SSID is 1-32 bytes; a WPA2 passphrase is 8-63 characters, or the raw
   * key as 64 hex digits; "" asks for an OPEN network, and nothing else does
   * (a short password used to give an open one without a word) */
  int hex = np == 64;
  for (size_t i = 0; hex && i < 64; i++) hex = isxdigit((unsigned char)j.b[i]) != 0;
  if (ns == 0 || ns > 32) j.bad = "an SSID is 1 to 32 bytes";
  else if (memchr(j.a, 0, ns)) j.bad = "an SSID may not contain a NUL byte";
  else if (np != 0 && (np < 8 || np > 64 || (np == 64 && !hex)))
    j.bad = "a WPA2 password is 8 to 63 characters (or 64 hex digits); \"\" is an open network";
  else if (memchr(j.b, 0, np)) j.bad = "a password may not contain a NUL byte";
  return fpr_job_submit(&j);
}
FPR_FN(fpr_g_WifiHost_x2eap, w_ap, 3);
