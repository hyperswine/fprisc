#include "wifi_hw.h"
#include "task.h"

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))
enum {
    WIFI_CLOCKS = 0x60026014, WIFI_RESET = 0x60026018, WIFI_CLK_MASK = 0x00fb9fcf, WIFI_I2C_CLK = 1u << 5,
    WIFI_MAC_RESET = 1u << 2, RTC_POWER = 0x60008088, RTC_ISO = 0x6000808c,
    WIFI_FORCE_PD = 1u << 17, WIFI_FORCE_ISO = 1u << 28,
    EFUSE_MAC_LOW = 0x60008844, EFUSE_MAC_HIGH = 0x60008848, RNG = 0x600260b0,
    RTC_SLOWCLK_CAL = 0x60008054, MIE = 8
};
static unsigned phy_users;
static _Alignas(4) uint8_t calibration[1904];
static unsigned lock_cookie;
extern const uint8_t c3_phy_init_data[128];
extern int register_chipv7_phy(const void *, void *, unsigned);
extern void phy_bbpll_en_usb(bool);
extern void phy_close_rf(void);

static bool env_is_chip(void) { return true; }
static void noop(void) {}
static void *lock_create(void) { return &lock_cookie; }
static void lock_delete(void *cookie) { (void)cookie; }

uint32_t phy_enter_critical(void) {
    uint32_t state;
    __asm__ volatile("csrrci %0, mstatus, 8" : "=r"(state) :: "memory");
    return state & MIE;
}

void phy_exit_critical(uint32_t state) {
    if (state & MIE) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
}

static uint32_t lock(void *cookie) { (void)cookie; return phy_enter_critical(); }
static void unlock(void *cookie, uint32_t state) { (void)cookie; phy_exit_critical(state); }

static void power_up(void) {
    REG(RTC_POWER) &= ~WIFI_FORCE_PD;
    REG(RTC_ISO) &= ~WIFI_FORCE_ISO;
    REG(WIFI_CLOCKS) = (REG(WIFI_CLOCKS) | WIFI_CLK_MASK) & ~WIFI_I2C_CLK;
}

static void reset_mac(void) {
    REG(WIFI_RESET) |= WIFI_MAC_RESET;
    REG(WIFI_RESET) &= ~WIFI_MAC_RESET;
}

static int read_mac(uint8_t *out, unsigned type) {
    if (!out || type > 2) return -1;
    uint32_t hi = REG(EFUSE_MAC_HIGH), lo = REG(EFUSE_MAC_LOW);
    out[0] = (uint8_t)(hi >> 8);
    out[1] = (uint8_t)hi;
    for (unsigned i = 0; i < 4; ++i) out[2 + i] = (uint8_t)(lo >> (24 - 8 * i));
    out[5] += type;
    return 0;
}

uint32_t esp_random(void) { return REG(RNG); }

void esp_fill_random(void *buffer, size_t length) {
    uint8_t *out = buffer;
    while (length) {
        uint32_t word = esp_random();
        for (unsigned byte = 0; byte < 4 && length; ++byte, --length, word >>= 8)
            *out++ = (uint8_t)word;
    }
}

static uint32_t random_word(void) { return esp_random(); }
static unsigned long random_long(void) { return esp_random(); }
static int random_bytes(uint8_t *out, size_t size) { esp_fill_random(out, size); return 0; }

static void phy_enable(void) {
    if (phy_users++) return;
    power_up();
    phy_bbpll_en_usb(true);
    if (register_chipv7_phy(c3_phy_init_data, calibration, 2) != 0) __builtin_trap();
}

static void phy_disable(void) {
    if (phy_users && !--phy_users) phy_close_rf();
}

static uint32_t timestamp(void) { return (uint32_t)(c3_tasks_now_us() / 1000u); }

static int get_time(void *output) {
    (void)output;
    return -1; /* No wall clock source. */
}
static int regulatory_info(const char *country) {
    (void)country;
    return 0; /* Passive scan with the controller's world limits. */
}

static uint32_t slow_clock_calibration(void) { return REG(RTC_SLOWCLK_CAL) >> 7; }

void c3_wifi_install_platform(wifi_osi_funcs_t *table) {
    power_up();
    table->_env_is_chip = env_is_chip;
    table->_spin_lock_create = lock_create;
    table->_spin_lock_delete = lock_delete;
    table->_wifi_int_disable = lock;
    table->_wifi_int_restore = unlock;
    table->_dport_access_stall_other_cpu_start_wrap = noop;
    table->_dport_access_stall_other_cpu_end_wrap = noop;
    table->_wifi_pm_sleep_lock_acquire = noop;
    table->_wifi_pm_sleep_lock_release = noop;
    table->_phy_enable = phy_enable;
    table->_phy_disable = phy_disable;
    table->_phy_update_country_info = regulatory_info;
    table->_wifi_clock_enable = power_up;
    table->_wifi_clock_disable = noop;
    table->_wifi_rtc_enable_iso = noop;
    table->_wifi_rtc_disable_iso = power_up;
    table->_slowclk_cal_get = slow_clock_calibration;
    table->_wifi_reset_mac = reset_mac;
    table->_read_mac = read_mac;
    table->_rand = random_word;
    table->_random = random_long;
    table->_get_random = random_bytes;
    table->_get_time = get_time;
    table->_log_timestamp = timestamp;
}
