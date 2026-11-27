#include "coex.h"
#include "alloc.h"
#include "btdm_services.h"
#include "os_timer.h"
#include "task.h"

enum { COEX_TIMER_PRIORITY = 24, WIFI_BITMAP = 1, COEX_BT_CALLBACK = 1 };
static struct c3_btdm_osi shared;
static coex_adapter_funcs_t adapter;
static bool prepared;

extern int esp_coex_adapter_register(coex_adapter_funcs_t *);
extern int coex_pre_init(void);
extern void coex_deinit(void), coex_disable(void);
extern uint32_t coex_status_get(uint8_t);
extern int coex_wifi_request(uint32_t, uint32_t, uint32_t);
extern int coex_wifi_release(uint32_t), coex_wifi_channel_set(uint8_t, uint8_t);
extern int coex_event_duration_get(uint32_t, uint32_t *), coex_pti_get(uint32_t, uint8_t *);
extern void coex_schm_status_bit_clear(uint32_t, uint32_t);
extern void coex_schm_status_bit_set(uint32_t, uint32_t);
extern int coex_schm_interval_set(uint32_t), coex_schm_process_restart(void);
extern uint32_t coex_schm_interval_get(void);
extern uint8_t coex_schm_curr_period_get(void), coex_schm_flexible_period_get(void);
extern void *coex_schm_curr_phase_get(void), *coex_schm_get_phase_by_idx(int);
extern int coex_schm_register_callback(unsigned, void *);
extern int coex_register_start_cb(int (*)(void)), coex_schm_flexible_period_set(uint8_t);
extern int32_t coex_core_ble_conn_dyn_prio_get(int32_t *, int32_t *);

static int32_t take_from_isr(void *sem, void *higher) {
    return shared.semphr_take_from_isr(sem, higher);
}

static int32_t give_from_isr(void *sem, void *higher) {
    return shared.semphr_give_from_isr(sem, higher);
}

static int is_in_isr(void) { return shared.is_in_isr(); }
static bool is_chip(void) { return true; }
static int64_t time_us(void) { return (int64_t)c3_tasks_now_us(); }
static int xtal_mhz(void) { return 40; }

int c3_coex_prepare(void) {
    if (prepared) return 0;
    c3_btdm_install_services(&shared, 1);
    if (!c3_timers_start(COEX_TIMER_PRIORITY)) return -1;
    adapter = (coex_adapter_funcs_t){
        ._version = COEX_ADAPTER_VERSION,
        ._task_yield_from_isr = shared.task_yield_from_isr,
        ._semphr_create = shared.semphr_create,
        ._semphr_delete = shared.semphr_delete,
        ._semphr_take_from_isr = take_from_isr,
        ._semphr_give_from_isr = give_from_isr,
        ._semphr_take = shared.semphr_take,
        ._semphr_give = shared.semphr_give,
        ._is_in_isr = is_in_isr,
        ._malloc_internal = c3_radio_alloc,
        ._free = c3_radio_free,
        ._esp_timer_get_time = time_us,
        ._env_is_chip = is_chip,
        ._timer_disarm = c3_timer_disarm,
        ._timer_done = c3_timer_done,
        ._timer_setfn = c3_timer_set_callback,
        ._timer_arm_us = c3_timer_arm_us,
        ._xtal_freq_get = xtal_mhz,
        ._magic = COEX_ADAPTER_MAGIC,
    };
    int rc = esp_coex_adapter_register(&adapter);
    if (!rc) rc = coex_pre_init();
    prepared = rc == 0;
    return rc;
}

static uint32_t wifi_status(void) { return coex_status_get(WIFI_BITMAP); }

static int register_phase(int type, int (*callback)(int)) {
    return coex_schm_register_callback(type, (void *)callback);
}

void c3_coex_install_wifi(wifi_osi_funcs_t *table) {
    table->_coex_init = coex_init;
    table->_coex_deinit = coex_deinit;
    table->_coex_enable = coex_enable;
    table->_coex_disable = coex_disable;
    table->_coex_status_get = wifi_status;
    table->_coex_wifi_request = coex_wifi_request;
    table->_coex_wifi_release = coex_wifi_release;
    table->_coex_wifi_channel_set = coex_wifi_channel_set;
    table->_coex_event_duration_get = coex_event_duration_get;
    table->_coex_pti_get = coex_pti_get;
    table->_coex_schm_status_bit_clear = coex_schm_status_bit_clear;
    table->_coex_schm_status_bit_set = coex_schm_status_bit_set;
    table->_coex_schm_interval_set = coex_schm_interval_set;
    table->_coex_schm_interval_get = coex_schm_interval_get;
    table->_coex_schm_curr_period_get = coex_schm_curr_period_get;
    table->_coex_schm_curr_phase_get = coex_schm_curr_phase_get;
    table->_coex_schm_process_restart = coex_schm_process_restart;
    table->_coex_schm_register_cb = register_phase;
    table->_coex_register_start_cb = coex_register_start_cb;
    table->_coex_schm_flexible_period_set = coex_schm_flexible_period_set;
    table->_coex_schm_flexible_period_get = coex_schm_flexible_period_get;
    table->_coex_schm_get_phase_by_idx = coex_schm_get_phase_by_idx;
}

static int32_t register_bt_phase(void *callback) {
    return coex_schm_register_callback(COEX_BT_CALLBACK, callback);
}

static void wifi_sleep(int32_t state) { (void)state; }

void c3_coex_install_ble(struct c3_btdm_osi *table) {
    table->coex_wifi_sleep_set = wifi_sleep;
    table->coex_core_ble_conn_dyn_prio_get = coex_core_ble_conn_dyn_prio_get;
    table->coex_schm_register_btdm_callback = register_bt_phase;
    table->coex_schm_status_bit_set = coex_schm_status_bit_set;
    table->coex_schm_status_bit_clear = coex_schm_status_bit_clear;
    table->coex_schm_interval_get = coex_schm_interval_get;
    table->coex_schm_curr_period_get = coex_schm_curr_period_get;
    table->coex_schm_curr_phase_get = coex_schm_curr_phase_get;
}
