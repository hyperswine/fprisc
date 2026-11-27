#include "ble_hw.h"
#include "alloc.h"
#include "radio_phy.h"

#define REG(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
enum {
    WIFI_CLOCKS = 0x60026014, RADIO_COMMON_CLOCKS = 0x0078078f,
    RADIO_POWER = 0x60008088, RADIO_ISOLATION = 0x6000808c,
    BT_FORCE_PD = 1u << 11, BT_FORCE_ISO = 1u << 22,
    XTAL_MHZ = 40,
};
static unsigned critical_depth;
static uint32_t saved_irq;
extern bool btdm_lpclk_select_src(uint32_t source);
extern bool btdm_lpclk_set_div(uint32_t divider);
extern int btdm_controller_rom_data_init(void);
extern void ets_delay_us(uint32_t);
extern void ble_base_funcs_reset(void), ble_42_adv_funcs_reset(void);
extern void ble_ext_adv_funcs_reset(void), ble_dtm_funcs_reset(void);
extern void ble_scan_funcs_reset(void), ble_ext_scan_funcs_reset(void);
extern void ble_enc_funcs_reset(void), ble_init_funcs_reset(void), ble_con_funcs_reset(void);

static void disable_irq(void) {
    uint32_t prior = phy_enter_critical();
    if (critical_depth++ == 0) saved_irq = prior;
}

static void restore_irq(void) {
    if (!critical_depth) __builtin_trap();
    if (--critical_depth == 0) phy_exit_critical(saved_irq);
}

static void power_on(void) {
    REG(RADIO_POWER) &= ~BT_FORCE_PD;
    REG(RADIO_ISOLATION) &= ~BT_FORCE_ISO;
}

static void power_off(void) {
    REG(RADIO_ISOLATION) |= BT_FORCE_ISO;
    REG(RADIO_POWER) |= BT_FORCE_PD;
}

static int32_t read_ble_mac(const void *output) {
    return c3_radio_read_mac((uint8_t *)output, 2);
}

static void seed(uint32_t ignored) { (void)ignored; }
static int32_t random_word(void) { return (int32_t)(c3_radio_random() & INT32_MAX); }
static uint32_t cycles_to_half_us(uint32_t cycles, uint32_t correction) {
    (void)correction; /* The selected 1 MHz clock has no fractional correction. */
    return cycles * 2;
}
static uint32_t half_us_to_cycles(uint32_t half_us) { return half_us / 2; }
static void reset_rom_dispatch(void) {
    ble_base_funcs_reset();
    ble_42_adv_funcs_reset();
    ble_ext_adv_funcs_reset();
    ble_dtm_funcs_reset();
    ble_scan_funcs_reset();
    ble_ext_scan_funcs_reset();
    ble_enc_funcs_reset();
    ble_init_funcs_reset();
    ble_con_funcs_reset();
}

int c3_ble_power_up(void) {
    REG(WIFI_CLOCKS) |= RADIO_COMMON_CLOCKS;
    power_on();
    if (!btdm_lpclk_select_src(0) || !btdm_lpclk_set_div(XTAL_MHZ)) return -1;
    return btdm_controller_rom_data_init();
}

int c3_ble_calibrate(void) {
    return c3_radio_phy_acquire();
}

static void *allocate(uint32_t bytes) { return c3_radio_alloc(bytes); }
static void assertion_failed(void) { __builtin_trap(); }

void c3_ble_install_platform(struct c3_btdm_osi *table) {
    table->interrupt_disable = disable_irq;
    table->interrupt_restore = restore_irq;
    table->malloc = allocate;
    table->malloc_internal = allocate;
    table->free = c3_radio_free;
    table->read_efuse_mac = read_ble_mac;
    table->srand = seed;
    table->rand = random_word;
    table->btdm_lpcycles_2_hus = cycles_to_half_us;
    table->btdm_hus_2_lpcycles = half_us_to_cycles;
    table->esp_hw_power_down = power_off;
    table->esp_hw_power_up = power_on;
    table->ets_delay_us = ets_delay_us;
    table->btdm_rom_table_ready = reset_rom_dispatch;
    table->assert_failure = assertion_failed;
}
