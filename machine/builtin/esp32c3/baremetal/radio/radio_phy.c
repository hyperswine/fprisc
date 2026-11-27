#include "radio_phy.h"

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))
enum {
    EFUSE_MAC_LOW = 0x60008844, EFUSE_MAC_HIGH = 0x60008848,
    RNG_DATA = 0x600260b0, MIE = 8, PHY_RF_CAL_FULL = 2,
};
static unsigned users;
static _Alignas(4) uint8_t calibration[1904];

extern const uint8_t c3_phy_init_data[128];
extern int register_chipv7_phy(const void *, void *, unsigned);
extern void phy_bbpll_en_usb(bool);
extern void phy_close_rf(void);

uint32_t phy_enter_critical(void) {
    uint32_t state;
    __asm__ volatile("csrrci %0, mstatus, 8" : "=r"(state) :: "memory");
    return state & MIE;
}

void phy_exit_critical(uint32_t state) {
    if (state & MIE) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
}

int c3_radio_phy_acquire(void) {
    if (!users) {
        phy_bbpll_en_usb(true);
        int rc = register_chipv7_phy(c3_phy_init_data, calibration, PHY_RF_CAL_FULL);
        if (rc) return rc;
    }
    ++users;
    return 0;
}

void c3_radio_phy_release(void) {
    if (!users) __builtin_trap();
    if (!--users) phy_close_rf();
}

int c3_radio_read_mac(uint8_t *mac, unsigned offset) {
    if (!mac || offset > 2) return -1;
    uint32_t hi = REG(EFUSE_MAC_HIGH), lo = REG(EFUSE_MAC_LOW);
    mac[0] = (uint8_t)(hi >> 8);
    mac[1] = (uint8_t)hi;
    for (unsigned i = 0; i < 4; ++i) mac[2 + i] = (uint8_t)(lo >> (24 - 8 * i));
    mac[5] += offset;
    return 0;
}

uint32_t c3_radio_random(void) {
    return REG(RNG_DATA);
}
