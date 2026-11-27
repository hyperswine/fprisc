#include "builtin.h"
#include "task.h"
#include "wifi_config.h"
#include "wifi_hw.h"
#include "wifi_irq.h"
#include "wifi_services.h"
#ifdef C3_WIFI_STATION
#include "station_config.h"
#include "wifi_probe.h"
#endif

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
wifi_osi_funcs_t g_wifi_osi_funcs;
#ifdef C3_WIFI_STATION
enum { WIFI_IF_STA = 0, WIFI_STORAGE_RAM = 1, WIFI_EVENT_CONNECTED = 4,
       WIFI_EVENT_DISCONNECTED = 5, ASSOCIATION_TIMEOUT_US = 12000000,
       RETRY_US = 2000000, POLL_US = 100000 };
enum link_state { LINK_CONNECTING, LINK_CONNECTED, LINK_DISCONNECTED };
static enum link_state link;
extern int esp_supplicant_init(void), esp_supplicant_deinit(void);
extern int esp_wifi_set_storage(unsigned);
extern int esp_wifi_set_config(unsigned, wifi_config_t *);
extern int esp_wifi_get_mac(unsigned, uint8_t *);
extern int esp_wifi_connect_internal(void), esp_wifi_disconnect_internal(void);
extern int c3_console_read(void *);
extern int c3_console_try_read(void);
#else
static bool scan_done;
static uint32_t scan_status;
#endif

int32_t esp_event_post(const char *base, int32_t id, void *data, size_t bytes,
                          uint32_t wait) {
    (void)wait;
    if (base != WIFI_EVENT) return 0;
#ifdef C3_WIFI_STATION
    (void)data;
    (void)bytes;
    if (id == WIFI_EVENT_CONNECTED || id == WIFI_EVENT_DISCONNECTED) {
        link = id == WIFI_EVENT_CONNECTED ? LINK_CONNECTED : LINK_DISCONNECTED;
        c3_tasks_wake(&link);
    }
#else
    if (id == WIFI_EVENT_SCAN_DONE) {
        scan_done = true;
        scan_status = UINT32_MAX;
        if (data && bytes >= sizeof(scan_status)) {
            const uint8_t *p = data;
            scan_status = (uint32_t)p[0] | (uint32_t)p[1] << 8 |
                          (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
        }
        c3_tasks_wake(&scan_done);
    }
#endif
    return 0;
}

static void check(int result, const char *phase) {
    if (!result) return;
    c3_console_text("Wi-Fi error ");
    c3_console_unsigned((uint32_t)result);
    c3_console_text("\n");
    fpr_cpanic(phase);
}

static void start_controller(void) {
    static wifi_init_config_t config = {
        .osi_funcs = &g_wifi_osi_funcs, .magic = WIFI_INIT_CONFIG_MAGIC,
        .static_rx_buf_num = 4, .dynamic_rx_buf_num = 8, .tx_buf_type = 1,
        .dynamic_tx_buf_num = 8, .rx_mgmt_buf_num = 5, .mgmt_sbuf_num = 8,
        .beacon_max_len = 752, .tx_hetb_queue_num = 3,
    };
    static const wifi_country_t country = {.cc = "01", .schan = 1, .nchan = 11, .policy = 1};
    if (!c3_wifi_install_services(&g_wifi_osi_funcs)) fpr_cpanic("Wi-Fi task services");
    c3_wifi_install_interrupts(&g_wifi_osi_funcs);
    c3_wifi_install_platform(&g_wifi_osi_funcs);
    c3_wifi_install_single_radio(&g_wifi_osi_funcs);
    g_wifi_osi_funcs._event_post = esp_event_post;
    config.wpa_crypto_funcs = g_wifi_default_wpa_crypto_funcs;
    c3_console_text("Wi-Fi controller init\n");
    check(esp_wifi_init_internal(&config), "Wi-Fi controller init");
    check(esp_wifi_set_mode(WIFI_MODE_STA), "Wi-Fi station mode");
    check(esp_wifi_set_country(&country), "Wi-Fi world country");
#ifdef C3_WIFI_STATION
    check(esp_supplicant_init(), "Wi-Fi supplicant init");
    check(esp_wifi_set_storage(WIFI_STORAGE_RAM), "Wi-Fi SRAM config");
#endif
    check(esp_wifi_start(), "Wi-Fi start");
    check(esp_wifi_set_ps(WIFI_PS_NONE), "Wi-Fi power save off");

}

static void stop_controller(void) {
    check(esp_wifi_stop(), "Wi-Fi stop");
    check(esp_wifi_deinit_internal(), "Wi-Fi controller deinit");
#ifdef C3_WIFI_STATION
    check(esp_supplicant_deinit(), "Wi-Fi supplicant deinit");
#endif
}

#ifndef C3_WIFI_STATION
static V run_scan(V unit) {
    (void)unit;
    static const wifi_scan_config_t scan = {
        .scan_type = WIFI_SCAN_PASSIVE, .scan_time.passive = 120,
        .channel_bitmap.ghz_2_channels = 0x7ff,
    };

    start_controller();

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
    stop_controller();
    return V_UNIT;
}
FPR_FN(fpr_g_EspWiFi_x2escan, run_scan, 1);

#else
static bool quitting;
static bool quit_requested(void) {
    if (!quitting) quitting = c3_console_try_read() == 'Q';
    return quitting;
}

static bool wait_until(uint64_t deadline) {
    while (!quit_requested()) {
        uint64_t now = c3_tasks_now_us();
        if (now >= deadline) return true;
        uint64_t slice = now + POLL_US;
        c3_task_park(NULL, slice < deadline ? slice : deadline);
    }
    return false;
}

static bool associate(void) {
    link = LINK_CONNECTING;
    int rc = esp_wifi_connect_internal();
    if (rc) return false;
    uint64_t deadline = c3_tasks_now_us() + ASSOCIATION_TIMEOUT_US;
    while (link == LINK_CONNECTING) {
        uint64_t now = c3_tasks_now_us();
        if (now >= deadline || quit_requested()) break;
        uint64_t slice = now + POLL_US;
        c3_task_park(&link, slice < deadline ? slice : deadline);
    }
    if (link == LINK_CONNECTED) return true;
    if (link == LINK_CONNECTING) esp_wifi_disconnect_internal();
    return false;
}

static bool serve_link(const struct c3_probe_address *address, unsigned generation) {
    check(c3_wifi_probe_start(address), "Wi-Fi RX registration");
    c3_console_text("FPR WIFI CONNECTED ");
    c3_console_unsigned(generation);
    c3_console_text("\n");
    uint32_t reported = 0;
    bool quit = false;
    while (link == LINK_CONNECTED && !(quit = quit_requested())) {
        c3_wifi_probe_poll(c3_tasks_now_us() + POLL_US);
        struct c3_probe_stats stats = c3_wifi_probe_stats();
        if (stats.echo_replies != reported) {
            reported = stats.echo_replies;
            c3_console_text("FPR WIFI ECHO ");
            c3_console_unsigned(reported);
            c3_console_text("\n");
        }
    }
    check(c3_wifi_probe_stop(), "Wi-Fi RX unregister");
    c3_console_text("FPR WIFI LINK ENDED\n");
    return !quit;
}

static V run_station(V unit) {
    (void)unit;
    wifi_config_t config;
    struct c3_probe_address address = {0};
    start_controller();
    c3_console_text("FPR WIFI CONFIG\n");
    check(c3_station_read_config(c3_console_read, NULL, &address, &config), "Wi-Fi config");
    int configured = esp_wifi_set_config(WIFI_IF_STA, &config);
    c3_station_clear_password(&config);
    check(configured, "Wi-Fi station config");
    check(esp_wifi_get_mac(WIFI_IF_STA, address.mac), "Wi-Fi station address");
    unsigned generation = 0;
    while (!quit_requested()) {
        if (associate() && !serve_link(&address, ++generation)) break;
        if (quit_requested()) break;
        c3_console_text("FPR WIFI RETRY\n");
        if (!wait_until(c3_tasks_now_us() + RETRY_US)) break;
    }
    stop_controller();
    return V_UNIT;
}
FPR_FN(fpr_g_EspWiFi_x2estation, run_station, 1);
#endif
