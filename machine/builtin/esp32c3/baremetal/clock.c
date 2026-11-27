#include <errno.h>
#include "../main/bytes.h"
#include "interrupt.h"

/* ESP32-C3 TRM, SYSTIMER UNIT0. CNT_CLK averages 16 MHz. */
#define TIMER_REG(offset) (*(volatile uint32_t *)(uintptr_t)(0x60023000u + (offset)))
enum {
    CONF = 0x00, UNIT0_OP = 0x04, TARGET0_HI = 0x1c, TARGET0_LO = 0x20,
    TARGET0_CONF = 0x34, UNIT0_HI = 0x40, UNIT0_LO = 0x44,
    COMP0_LOAD = 0x50, INT_ENABLE = 0x64, INT_CLEAR = 0x6c,
    TARGET0_ENABLE = 1u << 24, TARGET0_INT = 1u,
    VALUE_VALID = 1u << 29, UPDATE = 1u << 30,
    TICKS_PER_MS = 16000
};

static uint64_t ticks(void) {
    TIMER_REG(UNIT0_OP) = UPDATE;
    while (!(TIMER_REG(UNIT0_OP) & VALUE_VALID)) {}
    uint64_t high = TIMER_REG(UNIT0_HI) & 0xfffffu;
    return (high << 32) | TIMER_REG(UNIT0_LO);
}

static uint64_t milliseconds(void) {
    return ticks() / TICKS_PER_MS;
}

void c3_timer_ack(void) {
    TIMER_REG(CONF) &= ~TARGET0_ENABLE;
    TIMER_REG(INT_ENABLE) &= ~TARGET0_INT;
    TIMER_REG(INT_CLEAR) = TARGET0_INT;
}

static uint64_t load_stamp(V addr) {
    const uint8_t *bytes = buffer_ptr(addr);
    uint64_t stamp = 0;
    for (unsigned i = 0; i < 8; ++i) stamp |= (uint64_t)bytes[i] << (8 * i);
    return stamp;
}

static void store_stamp(V addr, uint64_t stamp) {
    uint8_t *bytes = buffer_ptr(addr);
    for (unsigned i = 0; i < 8; ++i) {
        bytes[i] = (uint8_t)stamp;
        stamp >>= 8;
    }
}

static V now_ms(V addr) {
    store_stamp(addr, milliseconds());
    return V_UNIT;
}

static V after_ms(V addr, V delta, V dest) {
    if (!ISINT(delta) || UNTAG(delta) < 0) return TAG(-EINVAL);
    uint64_t stamp = load_stamp(addr);
    if (stamp > (uint64_t)INT64_MAX - UNTAG(delta)) return TAG(-EINVAL);
    store_stamp(dest, stamp + UNTAG(delta));
    return TAG(0);
}

static V sleep_until(V addr) {
    uint64_t deadline = load_stamp(addr);
    const uint64_t max_ms = ((UINT64_C(1) << 52) - 1) / TICKS_PER_MS;
    if (deadline > max_ms || milliseconds() >= deadline) return V_UNIT;

    uint64_t target = deadline * TICKS_PER_MS;
    c3_timer_ack();
    TIMER_REG(TARGET0_CONF) = 0;
    TIMER_REG(TARGET0_HI) = (uint32_t)(target >> 32);
    TIMER_REG(TARGET0_LO) = (uint32_t)target;
    TIMER_REG(COMP0_LOAD) = 1;
    TIMER_REG(INT_ENABLE) |= TARGET0_INT;
    TIMER_REG(CONF) |= TARGET0_ENABLE;
    while (ticks() < target) c3_wait_interrupt();
    c3_timer_ack();
    return V_UNIT;
}

FPR_FN(fpr_g_EspClock_x2enowMs, now_ms, 1);
FPR_FN(fpr_g_EspClock_x2eafterMs, after_ms, 3);
FPR_FN(fpr_g_EspClock_x2esleepUntil, sleep_until, 1);
