#include "builtin.h"
#include "task.h"
#include "wifi_config.h"
#include "wifi_hw.h"
#include "wifi_irq.h"
#include "wifi_services.h"

enum {
    WIFI_MODE_STA = 1, WIFI_SCAN_PASSIVE = 1, WIFI_EVENT_SCAN_DONE = 1,
    WIFI_PS_NONE = 0, SCAN_TIMEOUT_US = 6000000
};
extern const wpa_crypto_funcs_t g_wifi_default_wpa_crypto_funcs;
extern int esp_wifi_init_internal(const wifi_init_config_t *);
extern int esp_wifi_deinit_internal(void);
extern int esp_wifi_set_mode(unsigned);
extern int esp_wifi_set_ps(unsigned);
extern int esp_wifi_set_country(const wifi_country_t *);
extern int esp_wifi_start(void), esp_wifi_stop(void), esp_wifi_scan_stop(void);
extern int esp_wifi_scan_start(const wifi_scan_config_t *, bool block);
extern int esp_wifi_scan_get_ap_num(uint16_t *);
extern int esp_wifi_clear_ap_list(void);
extern void c3_console_text(const char *);
extern void c3_console_unsigned(uint32_t);

const char *WIFI_EVENT = "WIFI_EVENT";
static wifi_osi_funcs_t callbacks;
static bool scan_done;
static uint32_t scan_status;

static int32_t event_post(const char *base, int32_t id, void *data, size_t bytes,
                          uint32_t wait) {
    (void)wait;
    if (base == WIFI_EVENT && id == WIFI_EVENT_SCAN_DONE) {
        scan_done = true;
        scan_status = UINT32_MAX;
        if (data && bytes >= sizeof(scan_status)) {
            const uint8_t *p = data;
            scan_status = (uint32_t)p[0] | (uint32_t)p[1] << 8 |
                          (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
        }
        c3_tasks_wake(&scan_done);
    }
    return 0;
}

static void check(int result, const char *phase) {
    if (!result) return;
    c3_console_text("Wi-Fi error ");
    c3_console_unsigned((uint32_t)result);
    c3_console_text("\n");
    fpr_cpanic(phase);
}

static V run_scan(V unit) {
    (void)unit;
    static wifi_init_config_t config = {
        .osi_funcs = &callbacks, .magic = WIFI_INIT_CONFIG_MAGIC,
        .static_rx_buf_num = 4, .dynamic_rx_buf_num = 8, .tx_buf_type = 1,
        .dynamic_tx_buf_num = 8, .rx_mgmt_buf_num = 5, .mgmt_sbuf_num = 8,
        .beacon_max_len = 752, .tx_hetb_queue_num = 3,
    };
    static const wifi_country_t country = {.cc = "01", .schan = 1, .nchan = 11, .policy = 1};
    static const wifi_scan_config_t scan = {
        .scan_type = WIFI_SCAN_PASSIVE, .scan_time.passive = 120,
        .channel_bitmap.ghz_2_channels = 0x7ff,
    };

    if (!c3_wifi_install_services(&callbacks)) fpr_cpanic("Wi-Fi task services");
    c3_wifi_install_interrupts(&callbacks);
    c3_wifi_install_platform(&callbacks);
    c3_wifi_install_single_radio(&callbacks);
    callbacks._event_post = event_post;
    config.wpa_crypto_funcs = g_wifi_default_wpa_crypto_funcs;
    c3_console_text("Wi-Fi controller init\n");
    check(esp_wifi_init_internal(&config), "Wi-Fi controller init");
    check(esp_wifi_set_mode(WIFI_MODE_STA), "Wi-Fi station mode");
    check(esp_wifi_set_country(&country), "Wi-Fi world country");
    check(esp_wifi_start(), "Wi-Fi start");
    check(esp_wifi_set_ps(WIFI_PS_NONE), "Wi-Fi power save off");

    c3_console_text("Wi-Fi passive scan\n");
    scan_done = false;
    check(esp_wifi_scan_start(&scan, false), "Wi-Fi scan start");
    uint64_t deadline = c3_tasks_now_us() + SCAN_TIMEOUT_US;
    while (!scan_done && c3_tasks_now_us() < deadline) c3_task_park(&scan_done, deadline);
    if (!scan_done) {
        esp_wifi_scan_stop();
        fpr_cpanic("Wi-Fi scan timeout");
    }
    check(scan_status, "Wi-Fi scan completion");
    uint16_t count;
    check(esp_wifi_scan_get_ap_num(&count), "Wi-Fi scan result count");
    check(esp_wifi_clear_ap_list(), "Wi-Fi scan list release");
    c3_console_text("FPR WIFI SCAN APs=");
    c3_console_unsigned(count);
    c3_console_text("\n");
    check(esp_wifi_stop(), "Wi-Fi stop");
    check(esp_wifi_deinit_internal(), "Wi-Fi controller deinit");
    return V_UNIT;
}
FPR_FN(fpr_g_EspWiFi_x2escan, run_scan, 1);
