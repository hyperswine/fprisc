#include "platform.h"

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))

enum {
    GPIO = 0x500e0000, IOMUX = 0x500e1000,
    BOOT_PIN = 35, BOOT_BIT = 1u << (BOOT_PIN - 32),
    OUTPUT_DISABLE = GPIO + 0x34, INPUT = GPIO + 0x40, CLEAR = GPIO + 0x58,
    PIN_CONTROL = GPIO + 0x74 + 4 * BOOT_PIN,
    PAD = IOMUX + (BOOT_PIN + 1) * 4,
    IN_ENABLE = 1u << 9, PULL_UP = 1u << 8, PULL_DOWN = 1u << 7, GPIO_FUNCTION = 1u << 12,
    GPIO_INTR0 = 1u << 13, ANY_EDGE = 3u << 7,
    DEBOUNCE_US = 25000, CHECK_TIMEOUT_US = 10000000,
};

static volatile unsigned edges;
extern void p4_puts(const char *);
extern void p4_hex(uint32_t);

static bool pressed(void) { return !(REG(INPUT) & BOOT_BIT); }

static void init_boot_input(void) {
    REG(OUTPUT_DISABLE) = BOOT_BIT;
    REG(PAD) = (REG(PAD) & ~((7u << 12) | PULL_DOWN)) | GPIO_FUNCTION | IN_ENABLE | PULL_UP;
    REG(CLEAR) = BOOT_BIT;
    REG(PIN_CONTROL) = (REG(PIN_CONTROL) & ~((31u << 13) | (7u << 7))) |
                       GPIO_INTR0 | ANY_EDGE;
}

void p4_gpio_irq(void) {
    REG(CLEAR) = BOOT_BIT;
    ++edges;
}

bool p4_button_check(void) {
    init_boot_input();
    if (pressed()) {
        p4_puts("P4 GPIO35 needs to start released\n");
        return false;
    }
    unsigned seen = edges;
    p4_puts("P4 GPIO35 ready\n");
    uint64_t end = p4_clock_now_us() + CHECK_TIMEOUT_US;
    unsigned stable_edges = 0;
    bool stable = false;
    uint64_t debounce_until = end;
    while (p4_clock_now_us() < end && stable_edges < 2) {
        p4_clock_wait_until(debounce_until < end ? debounce_until : end);
        uint64_t now = p4_clock_now_us();
        if (edges != seen) {
            seen = edges;
            debounce_until = now + DEBOUNCE_US;
        } else if (now >= debounce_until && now < end) {
            bool input = pressed();
            if (input != stable) {
                stable = input;
                ++stable_edges;
                p4_puts(stable ? "P4 GPIO35 pressed at us " : "P4 GPIO35 released at us ");
                p4_hex((uint32_t)now);
                p4_puts("\n");
            }
            debounce_until = end;
        }
    }
    REG(PIN_CONTROL) &= ~(GPIO_INTR0 | ANY_EDGE);
    REG(CLEAR) = BOOT_BIT;
    p4_puts("P4 GPIO35 IRQs ");
    p4_hex(edges);
    p4_puts("\n");
    return stable_edges == 2 && edges >= 2;
}
