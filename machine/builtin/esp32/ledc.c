#include <errno.h>
#include <stdbool.h>
#include "builtin.h"

#define REG(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#define BIT(n) (UINT32_C(1) << (n))

/* Low-speed LEDC, GPIO matrix and IO MUX from the C3 and P4 TRMs.
 * Both backends select the 40 MHz crystal and use divider units of 1/256. */
#ifdef FPR_LEDC_P4
enum {
    LEDC = 0x500d3000, GPIO = 0x500e0000, IOMUX = 0x500e1004,
    OUT_SELECT = 0x558, OUTPUT_ENABLE_SOURCE = BIT(10), GPIO_SIGNAL = 256,
    CHANNELS = 8, FIRST_SIGNAL = 126, MAX_RESOLUTION = 20,
    DIV_SHIFT = 5, TIMER_RESET = BIT(24), TIMER_UPDATE = BIT(26),
};

static bool valid_pin(sw pin) {
    /* SDIO and companion enable belong to the qualified C6 board profile. */
    return pin >= 0 && pin < 54 && (pin < 14 || pin > 19);
}

static void enable_ledc(void) {
    REG(0x500e6020) |= BIT(0);
    REG(0x500e609c) = (REG(0x500e609c) & ~3u) | BIT(2);
    REG(0x500e60c4) |= BIT(29);
    REG(0x500e60c4) &= ~BIT(29);
    REG(LEDC + 0x170) |= BIT(31);
}

static void start_duty(unsigned channel, unsigned conf1) {
    /* One gamma range with one cycle and no duty ramp. */
    REG(LEDC + 0x400 + 0x40 * channel) = BIT(21) | BIT(1);
    REG(LEDC + 0x100 + 4 * channel) = 1;
    REG(conf1) = BIT(31);
}
#else
enum {
    LEDC = 0x60019000, GPIO = 0x60004000, IOMUX = 0x60009004,
    OUT_SELECT = 0x554, OUTPUT_ENABLE_SOURCE = BIT(9), GPIO_SIGNAL = 128,
    CHANNELS = 6, FIRST_SIGNAL = 45, MAX_RESOLUTION = 14,
    DIV_SHIFT = 4, TIMER_RESET = BIT(23), TIMER_UPDATE = BIT(25),
};

static bool valid_pin(sw pin) {
    return (pin >= 0 && pin <= 10) || pin == 20 || pin == 21;
}

static void enable_ledc(void) {
    REG(0x600c0010) |= BIT(11);
    REG(0x600c0018) |= BIT(11);
    REG(0x600c0018) &= ~BIT(11);
    REG(LEDC + 0xd0) = BIT(31) | 3u;
}

static void start_duty(unsigned channel, unsigned conf1) {
    (void)channel;
    REG(conf1) = BIT(31) | BIT(20) | BIT(10);
}
#endif

enum {
    TIMERS = 4, TICKS_PER_US_Q8 = 10240,
    MAX_DIVIDER = 0x3ffff, MIN_DIVIDER = 256,
    TIMER0 = LEDC + 0xa0, CHANNEL_STRIDE = 0x14,
    HPOINT = 4, DUTY = 8, CONF1 = 12,
    SIGNAL_ENABLE = BIT(2), CHANNEL_UPDATE = BIT(4),
};

static struct {
    unsigned frequency, divider, resolution, users;
} timers[TIMERS];

static struct {
    bool active;
    unsigned pin, timer;
} channels[CHANNELS];

static bool initialized;
static const uint64_t CLOCK_Q8 = UINT64_C(40000000) * 256;

static void route_pin(unsigned pin, unsigned signal) {
    unsigned bank = pin / 32;
    uint32_t mask = BIT(pin % 32);
    unsigned mux = IOMUX + 4 * pin;
    REG(GPIO + 0x28 + 12 * bank) = mask;
    REG(GPIO + 0x0c + 12 * bank) = mask;
    REG(GPIO + 0x74 + 4 * pin) &= ~BIT(2);  /* push-pull */
    REG(GPIO + OUT_SELECT + 4 * pin) = signal | OUTPUT_ENABLE_SOURCE;
    /* GPIO matrix function, input enabled to allow reading back the pad. */
    REG(mux) = (REG(mux) & ~(7u << 12 | BIT(8) | BIT(7) | BIT(1))) | BIT(12) | BIT(9);
    REG(GPIO + 0x24 + 12 * bank) = mask;
}

static V open_pwm(V channel, V timer, V pin, V frequency) {
    if (!ISINT(channel) || !ISINT(timer) || !ISINT(pin) || !ISINT(frequency))
        return TAG(-EINVAL);
    unsigned c = UNTAG(channel), t = UNTAG(timer), hz = UNTAG(frequency);
    sw p = UNTAG(pin);
    if (c >= CHANNELS || t >= TIMERS || !valid_pin(p) || UNTAG(frequency) <= 0)
        return TAG(-EINVAL);
    if (channels[c].active || (timers[t].users && timers[t].frequency != hz))
        return TAG(-EBUSY);
    for (unsigned i = 0; i < CHANNELS; ++i)
        if (channels[i].active && channels[i].pin == (unsigned)p) return TAG(-EBUSY);

    if (!timers[t].users) {
        unsigned bits = MAX_RESOLUTION;
        uint64_t divider;
        do {
            uint64_t counts_per_second = (uint64_t)hz << bits;
            divider = (CLOCK_Q8 + counts_per_second / 2) / counts_per_second;
            if (divider >= MIN_DIVIDER) break;
        } while (--bits);
        if (!bits || divider > MAX_DIVIDER) return TAG(-ERANGE);
        if (!initialized) {
            enable_ledc();
            initialized = true;
        }
        unsigned reg = TIMER0 + 8 * t;
        uint32_t config = ((uint32_t)divider << DIV_SHIFT) | bits | TIMER_UPDATE;
        REG(reg) = config | TIMER_RESET;
        REG(reg) = config;
        timers[t].frequency = hz;
        timers[t].divider = (unsigned)divider;
        timers[t].resolution = bits;
    }
    unsigned base = LEDC + CHANNEL_STRIDE * c;
    REG(base) = t | CHANNEL_UPDATE;  /* disabled output, idle low */
    REG(base + HPOINT) = 0;
    REG(base + DUTY) = 0;
    route_pin((unsigned)p, FIRST_SIGNAL + c);
    channels[c].active = true;
    channels[c].pin = (unsigned)p;
    channels[c].timer = t;
    ++timers[t].users;
    return TAG(0);
}

static V pulse_us(V channel, V width) {
    if (!ISINT(channel) || !ISINT(width)) return TAG(-EINVAL);
    unsigned c = UNTAG(channel);
    if (c >= CHANNELS || !channels[c].active || UNTAG(width) < 0) return TAG(-EINVAL);
    unsigned t = channels[c].timer, us = UNTAG(width);
    if ((uint64_t)us * timers[t].frequency >= 1000000) return TAG(-ERANGE);
    unsigned divider = timers[t].divider;
    unsigned duty = (unsigned)(((uint64_t)us * TICKS_PER_US_Q8 + divider / 2) / divider);
    unsigned counts = 1u << timers[t].resolution;
    if (duty >= counts) duty = counts - 1;
    unsigned base = LEDC + CHANNEL_STRIDE * c;
    REG(base + DUTY) = duty << 4;
    start_duty(c, base + CONF1);
    REG(base) = t | SIGNAL_ENABLE | CHANNEL_UPDATE;
    return TAG(0);
}

static V stop_pwm(V channel) {
    if (!ISINT(channel)) return TAG(-EINVAL);
    unsigned c = UNTAG(channel);
    if (c >= CHANNELS || !channels[c].active) return TAG(-EINVAL);
    unsigned t = channels[c].timer;
    REG(LEDC + CHANNEL_STRIDE * c) = t | CHANNEL_UPDATE;
    route_pin(channels[c].pin, GPIO_SIGNAL);
    channels[c].active = false;
    --timers[t].users;
    return TAG(0);
}

FPR_FN(fpr_g_EspPWM_x2eopen, open_pwm, 4);
FPR_FN(fpr_g_EspPWM_x2epulseUs, pulse_us, 2);
FPR_FN(fpr_g_EspPWM_x2estop, stop_pwm, 1);
