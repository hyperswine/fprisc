#include <errno.h>
#include "builtin.h"

/* ESP32-C3 TRM, GPIO Matrix and IO MUX. The ROM enables the GPIO clock.
 * Single-hart polling backend; only expose the same header pins as the IDF port. */
#define GPIO_REG(offset) (*(volatile uint32_t *)(uintptr_t)(0x60004000u + (offset)))
#define PAD_MUX(pin) (*(volatile uint32_t *)(uintptr_t)(0x60009004u + 4u * (pin)))
enum {
    OUT_SET = 0x08, OUT_CLEAR = 0x0c, ENABLE_SET = 0x24, ENABLE_CLEAR = 0x28,
    IN = 0x3c, PIN0 = 0x74, OUT_SELECT0 = 0x554,
    PAD_OPEN_DRAIN = 1u << 2, GPIO_OUT_SIGNAL = 128, SOFTWARE_ENABLE = 1u << 9,
    MUX_SLEEP = 1u << 1, MUX_PULLDOWN = 1u << 7, MUX_PULLUP = 1u << 8,
    MUX_INPUT = 1u << 9, MUX_FUNCTION_MASK = 7u << 12, MUX_GPIO = 1u << 12
};
static uint32_t inputs, outputs;

static int header_pin(V pin) {
    if (!ISINT(pin)) return 0;
    sw n = UNTAG(pin);
    return (n >= 0 && n <= 10) || n == 20 || n == 21;
}
enum mode { INPUT, OUTPUT, OPEN_DRAIN };
static V configure(V pin, V option, enum mode mode) {
    if (!header_pin(pin) || !ISBOOL(option)) return TAG(-EINVAL);
    unsigned n = UNTAG(pin);
    uint32_t mask = 1u << n;
    uint32_t mux = PAD_MUX(n) & ~(MUX_FUNCTION_MASK | MUX_SLEEP | MUX_PULLUP |
                                  MUX_PULLDOWN | MUX_INPUT);
    GPIO_REG(ENABLE_CLEAR) = mask;
    if (mode == INPUT) {
        mux |= MUX_INPUT;
        if (BOOL_VAL(option)) mux |= MUX_PULLUP;
    } else {
        GPIO_REG(BOOL_VAL(option) ? OUT_SET : OUT_CLEAR) = mask;
    }
    uint32_t pad = GPIO_REG(PIN0 + 4 * n) & ~PAD_OPEN_DRAIN;
    GPIO_REG(PIN0 + 4 * n) = mode == OPEN_DRAIN ? pad | PAD_OPEN_DRAIN : pad;
    GPIO_REG(OUT_SELECT0 + 4 * n) = GPIO_OUT_SIGNAL | SOFTWARE_ENABLE;
    PAD_MUX(n) = mux | MUX_GPIO;
    if (mode != INPUT) GPIO_REG(ENABLE_SET) = mask;
    inputs = (inputs & ~mask) | (mode == INPUT ? mask : 0);
    outputs = (outputs & ~mask) | (mode == INPUT ? 0 : mask);
    return TAG(0);
}
static V input(V pin, V pull_up) { return configure(pin, pull_up, INPUT); }
static V output(V pin, V high) { return configure(pin, high, OUTPUT); }
static V open_drain(V pin, V released) { return configure(pin, released, OPEN_DRAIN); }
static V read_pin(V pin) {
    if (!header_pin(pin)) return TAG(-EINVAL);
    uint32_t mask = 1u << UNTAG(pin);
    if (!(inputs & mask)) return TAG(-EINVAL);
    return TAG((GPIO_REG(IN) & mask) != 0);
}
static V write_pin(V pin, V high) {
    if (!header_pin(pin) || !ISBOOL(high)) return TAG(-EINVAL);
    uint32_t mask = 1u << UNTAG(pin);
    if (!(outputs & mask)) return TAG(-EINVAL);
    GPIO_REG(BOOL_VAL(high) ? OUT_SET : OUT_CLEAR) = mask;
    return TAG(0);
}
FPR_FN(fpr_g_EspGPIO_x2einput, input, 2);
FPR_FN(fpr_g_EspGPIO_x2eoutput, output, 2);
FPR_FN(fpr_g_EspGPIO_x2eopenDrain, open_drain, 2);
FPR_FN(fpr_g_EspGPIO_x2eread, read_pin, 1);
FPR_FN(fpr_g_EspGPIO_x2ewrite, write_pin, 2);
