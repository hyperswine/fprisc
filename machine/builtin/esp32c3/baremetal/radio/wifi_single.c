#include "wifi_config.h"

/* Single-radio profiles leave the coexistence arbiter and NVS disabled.
 * The controller still calls several of their callback slots. */
static int success(void) { return 0; }
static void idle(void) {}
static uint32_t zero(void) { return 0; }
static uint8_t zero_period(void) { return 0; }
static void *no_phase(void) { return NULL; }

static int request(uint32_t event, uint32_t latency, uint32_t duration) {
    (void)event; (void)latency; (void)duration;
    return 0;
}
static int release(uint32_t event) { (void)event; return 0; }
static int channel(uint8_t primary, uint8_t secondary) { (void)primary; (void)secondary; return 0; }
static int duration(uint32_t event, uint32_t *value) { (void)event; if (value) *value = 0; return 0; }
static int pti(uint32_t event, uint8_t *value) { (void)event; if (value) *value = 0; return 0; }
static void status(uint32_t type, uint32_t bits) { (void)type; (void)bits; }
static int interval(uint32_t value) { (void)value; return 0; }
static int flexible_period(uint8_t period) { (void)period; return 0; }
static void *phase(int idx) { (void)idx; return NULL; }
static int register_phase(int type, int (*callback)(int)) { (void)type; (void)callback; return 0; }
static int register_start(int (*callback)(void)) { (void)callback; return 0; }

enum { NVS_UNAVAILABLE = 0x1101 };
static int nvs_open(const char *name, unsigned mode, uint32_t *handle) {
    (void)name; (void)mode;
    if (handle) *handle = 0;
    return NVS_UNAVAILABLE;
}
static void nvs_close(uint32_t handle) { (void)handle; }
static int nvs_commit(uint32_t handle) { (void)handle; return NVS_UNAVAILABLE; }
static int nvs_erase(uint32_t handle, const char *key) {
    (void)handle; (void)key;
    return NVS_UNAVAILABLE;
}

/* NVS callbacks share the same failure contract for each typed value. */
#define NVS_CALLBACKS(name, type) \
    static int set_##name(uint32_t handle, const char *key, type value) { \
        (void)value; return nvs_erase(handle, key); \
    } \
    static int get_##name(uint32_t handle, const char *key, type *value) { \
        (void)value; return nvs_erase(handle, key); \
    }
NVS_CALLBACKS(i8, int8_t)
NVS_CALLBACKS(u8, uint8_t)
NVS_CALLBACKS(u16, uint16_t)

static int set_blob(uint32_t handle, const char *key, const void *bytes, size_t size) {
    (void)bytes; (void)size;
    return nvs_erase(handle, key);
}
static int get_blob(uint32_t handle, const char *key, void *bytes, size_t *size) {
    (void)bytes; (void)size;
    return nvs_erase(handle, key);
}

void c3_wifi_install_single_radio(wifi_osi_funcs_t *table) {
    table->_coex_init = success;
    table->_coex_deinit = idle;
    table->_coex_enable = success;
    table->_coex_disable = idle;
    table->_coex_status_get = zero;
    table->_coex_wifi_request = request;
    table->_coex_wifi_release = release;
    table->_coex_wifi_channel_set = channel;
    table->_coex_event_duration_get = duration;
    table->_coex_pti_get = pti;
    table->_coex_schm_status_bit_clear = status;
    table->_coex_schm_status_bit_set = status;
    table->_coex_schm_interval_set = interval;
    table->_coex_schm_interval_get = zero;
    table->_coex_schm_curr_period_get = zero_period;
    table->_coex_schm_curr_phase_get = no_phase;
    table->_coex_schm_process_restart = success;
    table->_coex_schm_register_cb = register_phase;
    table->_coex_register_start_cb = register_start;
    table->_coex_schm_flexible_period_set = flexible_period;
    table->_coex_schm_flexible_period_get = zero_period;
    table->_coex_schm_get_phase_by_idx = phase;

    table->_nvs_open = nvs_open;
    table->_nvs_close = nvs_close;
    table->_nvs_commit = nvs_commit;
    table->_nvs_erase_key = nvs_erase;
    table->_nvs_set_i8 = set_i8;
    table->_nvs_get_i8 = get_i8;
    table->_nvs_set_u8 = set_u8;
    table->_nvs_get_u8 = get_u8;
    table->_nvs_set_u16 = set_u16;
    table->_nvs_get_u16 = get_u16;
    table->_nvs_set_blob = set_blob;
    table->_nvs_get_blob = get_blob;
}
