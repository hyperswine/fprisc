/* Callback layout adapted from esp-radio's C3/S3 BTDM OS adapter.
 * SPDX-License-Identifier: MIT
 * Copyright 2021 esp-rs
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define C3_BTDM_OSI_MAGIC UINT32_C(0xfadebead)
#define C3_BTDM_OSI_VERSION UINT32_C(0x0001000b)

typedef void (*c3_btdm_isr)(const void *);

struct c3_btdm_osi {
    uint32_t magic, version;
    int32_t (*interrupt_alloc)(int32_t, int32_t, c3_btdm_isr, const void *, const void **);
    int32_t (*interrupt_free)(const void *);
    void (*interrupt_handler_set)(int32_t, c3_btdm_isr, const void *);
    void (*interrupt_disable)(void);
    void (*interrupt_restore)(void);
    void (*task_yield)(void);
    void (*task_yield_from_isr)(void);
    void *(*semphr_create)(uint32_t, uint32_t);
    void (*semphr_delete)(void *);
    int32_t (*semphr_take_from_isr)(void *, bool *);
    int32_t (*semphr_give_from_isr)(void *, bool *);
    int32_t (*semphr_take)(void *, uint32_t);
    int32_t (*semphr_give)(void *);
    const void *(*mutex_create)(void);
    void (*mutex_delete)(const void *);
    int32_t (*mutex_lock)(const void *);
    int32_t (*mutex_unlock)(const void *);
    void *(*queue_create)(uint32_t, uint32_t);
    void (*queue_delete)(void *);
    int32_t (*queue_send)(void *, void *, uint32_t);
    int32_t (*queue_send_from_isr)(void *, void *, void *);
    int32_t (*queue_recv)(void *, void *, uint32_t);
    int32_t (*queue_recv_from_isr)(void *, void *, void *);
    int32_t (*task_create)(void *, const char *, uint32_t, void *, uint32_t, void *, uint32_t);
    void (*task_delete)(void *);
    int32_t (*is_in_isr)(void);
    int32_t (*cause_sw_intr_to_core)(int32_t, int32_t);
    void *(*malloc)(uint32_t);
    void *(*malloc_internal)(uint32_t);
    void (*free)(void *);
    int32_t (*read_efuse_mac)(const void *);
    void (*srand)(uint32_t);
    int32_t (*rand)(void);
    uint32_t (*btdm_lpcycles_2_hus)(uint32_t, uint32_t);
    uint32_t (*btdm_hus_2_lpcycles)(uint32_t);
    int32_t (*btdm_sleep_check_duration)(int32_t);
    void (*btdm_sleep_enter_phase1)(int32_t);
    void (*btdm_sleep_enter_phase2)(void);
    void (*btdm_sleep_exit_phase1)(void);
    void (*btdm_sleep_exit_phase2)(void);
    void (*btdm_sleep_exit_phase3)(void);
    void (*coex_wifi_sleep_set)(int32_t);
    int32_t (*coex_core_ble_conn_dyn_prio_get)(int32_t *, int32_t *);
    int32_t (*coex_schm_register_btdm_callback)(void *);
    void (*coex_schm_status_bit_set)(uint32_t, uint32_t);
    void (*coex_schm_status_bit_clear)(uint32_t, uint32_t);
    uint32_t (*coex_schm_interval_get)(void);
    uint8_t (*coex_schm_curr_period_get)(void);
    void *(*coex_schm_curr_phase_get)(void);
    int32_t (*interrupt_on)(int32_t);
    int32_t (*interrupt_off)(int32_t);
    void (*esp_hw_power_down)(void);
    void (*esp_hw_power_up)(void);
    void (*ets_backup_dma_copy)(uint32_t, uint32_t, uint32_t, int32_t);
    void *(*malloc_retention)(uint32_t);
    void (*ets_delay_us)(uint32_t);
    void (*btdm_rom_table_ready)(void);
    bool (*coex_bt_wakeup_request)(void);
    void (*coex_bt_wakeup_request_end)(void);
    uint64_t (*get_time_us)(void);
    void (*assert_failure)(void);
};

struct c3_vhci_host {
    void (*send_available)(void);
    int32_t (*receive)(uint8_t *, uint16_t);
};

_Static_assert(sizeof(void (*)(void)) == 4, "BTDM callbacks require RV32");
_Static_assert(sizeof(struct c3_btdm_osi) == 252, "C3 BTDM callback table size");
_Static_assert(offsetof(struct c3_btdm_osi, task_create) == 100, "C3 task table offset");
_Static_assert(offsetof(struct c3_btdm_osi, get_time_us) == 244, "C3 time table offset");
_Static_assert(sizeof(struct c3_vhci_host) == 8, "C3 VHCI callback layout");

int32_t btdm_osi_funcs_register(const struct c3_btdm_osi *functions);
bool API_vhci_host_check_send_available(void);
void API_vhci_host_send_packet(const uint8_t *data, uint16_t length);
int32_t API_vhci_host_register_callback(const struct c3_vhci_host *callbacks);
