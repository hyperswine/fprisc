#include <errno.h>
#include <stdbool.h>
#include "builtin.h"
#include "interrupt.h"

/* ESP32-C3 TRM, GPIO Matrix and IO MUX. The ROM enables the GPIO clock.
 * Single-hart polling backend; only expose the same header pins as the IDF port. */
#define GPIO_REG(offset) (*(volatile uint32_t *)(uintptr_t)(0x60004000u + (offset)))
#define PAD_MUX(pin) (*(volatile uint32_t *)(uintptr_t)(0x60009004u + 4u * (pin)))
enum {
    OUT_SET = 0x08, OUT_CLEAR = 0x0c, ENABLE_SET = 0x24, ENABLE_CLEAR = 0x28,
    IN = 0x3c, STATUS = 0x44, STATUS_CLEAR = 0x4c, PIN0 = 0x74, OUT_SELECT0 = 0x554,
    ANY_EDGE = 3u << 7, INT_TYPE_MASK = 7u << 7,
    CPU_INT_ENABLE = 1u << 13, INT_ENABLE_MASK = 31u << 13,
    PAD_OPEN_DRAIN = 1u << 2, GPIO_OUT_SIGNAL = 128, SOFTWARE_ENABLE = 1u << 9,
    MUX_SLEEP = 1u << 1, MUX_PULLDOWN = 1u << 7, MUX_PULLUP = 1u << 8,
    MUX_INPUT = 1u << 9, MUX_FUNCTION_MASK = 7u << 12, MUX_GPIO = 1u << 12
};
static uint32_t inputs, outputs, watched;
enum { QUEUE_SIZE = 8 };
static volatile uint8_t events[QUEUE_SIZE];
static volatile unsigned head, tail;
static volatile bool overflow;

static void disarm(unsigned pin) {
    GPIO_REG(PIN0 + 4 * pin) &= ~(INT_TYPE_MASK | INT_ENABLE_MASK);
    GPIO_REG(STATUS_CLEAR) = 1u << pin;
}

void c3_gpio_irq(void) {
    uint32_t pending = GPIO_REG(STATUS);
    GPIO_REG(STATUS_CLEAR) = pending;
    if (!(pending & watched)) return;
    unsigned next = (head + 1) % QUEUE_SIZE;
    if (next == tail) {
        overflow = true;
        return;
    }
    events[head] = (GPIO_REG(IN) & watched) != 0;
    head = next;
}

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
    if (watched == mask) {
        watched = 0;
        disarm(n);
    }
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

/* A single watched pin keeps RAM bounded. A hardware status bit can
 * coalesce multiple transitions before dispatch. The queue holds samples
 * accepted by the ISR, and overflow is reported to the caller. */
static V watch(V pin) {
    if (!header_pin(pin)) return TAG(-EINVAL);
    unsigned n = UNTAG(pin);
    uint32_t mask = 1u << n;
    if (!(inputs & mask)) return TAG(-EINVAL);
    if (watched) disarm(__builtin_ctz(watched));
    disarm(n);
    head = tail = 0;
    overflow = false;
    watched = mask;
    GPIO_REG(PIN0 + 4 * n) |= ANY_EDGE | CPU_INT_ENABLE;
    return TAG(0);
}

static V wait_edge(V pin) {
    if (!header_pin(pin) || watched != (1u << UNTAG(pin))) return TAG(-EINVAL);
    while (head == tail && !overflow) c3_wait_interrupt();
    if (overflow) {
        tail = head;
        overflow = false;
        return TAG(-EOVERFLOW);
    }
    unsigned level = events[tail];
    tail = (tail + 1) % QUEUE_SIZE;
    return TAG(level);
}
FPR_FN(fpr_g_EspGPIO_x2ewatch, watch, 1);
FPR_FN(fpr_g_EspGPIO_x2ewaitEdge, wait_edge, 1);
