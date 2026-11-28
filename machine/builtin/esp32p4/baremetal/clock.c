#include "platform.h"

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))
#define TIMER(offset) REG(0x500e2000u + (offset))

enum {
    CLOCK_APB = 0x500e601c, CLOCK_ROOT = 0x500e6098,
    TIMER_APB_EN = 1u << 23, TIMER_ROOT_EN = 1u << 30, TIMER_RC_FAST = 1u << 29,
    CONF = 0x00, UNIT0_OP = 0x04, TARGET0_HI = 0x1c, TARGET0_LO = 0x20,
    TARGET0_CONF = 0x34, UNIT0_HI = 0x40, UNIT0_LO = 0x44,
    COMP0_LOAD = 0x50, INT_ENABLE = 0x64, INT_CLEAR = 0x6c,
    CLK_FORCE = 1u << 31, UNIT0_WORK = 1u << 30, UNIT0_STALL = 3u << 27,
    TARGET0_ENABLE = 1u << 24, TARGET0_INT = 1u,
    VALUE_VALID = 1u << 29, UPDATE = 1u << 30, TICKS_PER_US = 16
};

static const uint64_t max_us = ((UINT64_C(1) << 52) - 1) / TICKS_PER_US;
static volatile unsigned alarms;
extern void p4_puts(const char *);
extern void p4_hex(uint32_t);

static void timer_ack(void) {
    TIMER(CONF) &= ~TARGET0_ENABLE;
    TIMER(INT_ENABLE) &= ~TARGET0_INT;
    TIMER(INT_CLEAR) = TARGET0_INT;
}

void p4_clock_init(void) {
    REG(CLOCK_APB) |= TIMER_APB_EN;
    REG(CLOCK_ROOT) = (REG(CLOCK_ROOT) & ~TIMER_RC_FAST) | TIMER_ROOT_EN;
    /* Unit0 must keep running while either CPU is parked. */
    TIMER(CONF) = (TIMER(CONF) & ~UNIT0_STALL) | CLK_FORCE | UNIT0_WORK;
    timer_ack();
}

static uint64_t ticks(void) {
    TIMER(UNIT0_OP) = UPDATE;
    while (!(TIMER(UNIT0_OP) & VALUE_VALID)) {}
    uint64_t high = TIMER(UNIT0_HI) & 0xfffffu;
    return (high << 32) | TIMER(UNIT0_LO);
}

uint64_t p4_clock_now_us(void) { return ticks() / TICKS_PER_US; }

void p4_timer_irq(void) {
    timer_ack();
    ++alarms;
}

void p4_clock_wait_until(uint64_t deadline) {
    if (deadline > max_us || p4_clock_now_us() >= deadline) return;
    uint64_t target = deadline * TICKS_PER_US;
    TIMER(TARGET0_CONF) = 0;
    TIMER(TARGET0_HI) = (uint32_t)(target >> 32);
    TIMER(TARGET0_LO) = (uint32_t)target;
    TIMER(COMP0_LOAD) = 1;
    TIMER(INT_ENABLE) |= TARGET0_INT;
    TIMER(CONF) |= TARGET0_ENABLE;
    if (ticks() < target) p4_wait_interrupt();
    timer_ack();
}

void p4_clock_sleep_until(uint64_t deadline) {
    while (deadline <= max_us && p4_clock_now_us() < deadline) p4_clock_wait_until(deadline);
}

bool p4_clock_check(void) {
    uint64_t begin = p4_clock_now_us();
    for (unsigned i = 1; i <= 3; ++i) p4_clock_sleep_until(begin + i * 50000u);
    uint64_t elapsed = p4_clock_now_us() - begin;
    p4_puts("P4 timer elapsed us ");
    p4_hex((uint32_t)elapsed);
    p4_puts(", IRQs ");
    p4_hex(alarms);
    p4_puts("\n");
    return elapsed >= 150000 && elapsed < 160000 && alarms == 3;
}
