#include <stdint.h>
#include <stdbool.h>

#define FINISH (*(volatile uint32_t *)0x100000)
#define UART (*(volatile uint8_t *)0x10000000)
#define CHECK(condition) do { if (!(condition)) fail(__LINE__); } while (0)

static volatile unsigned char byte = 1;
static volatile unsigned int word = 15;
static unsigned mask;

static _Noreturn void fail(unsigned line) {
    FINISH = (line << 16) | 0x3333u;
    for (;;) {}
}

uint32_t phy_enter_critical(void) {
    CHECK(mask == 0);
    return ++mask;
}

void phy_exit_critical(uint32_t saved) {
    CHECK(saved == 1 && mask == 1);
    mask = 0;
}

void main(void) {
    unsigned char expected = 1;
    CHECK(__atomic_compare_exchange_n(&byte, &expected, 3, false, 5, 5));
    CHECK(byte == 3);
    CHECK(!__atomic_compare_exchange_n(&byte, &expected, 4, false, 5, 5));
    CHECK(expected == 3 && byte == 3);
    CHECK(__atomic_exchange_n(&word, 37, 5) == 15);
    CHECK(__atomic_fetch_add(&word, 4, 5) == 37);
    CHECK(__atomic_fetch_sub(&word, 6, 5) == 41);
    CHECK(word == 35 && mask == 0);
    for (const char *s = "RV32 station atomics PASS\n"; *s; ++s) UART = (uint8_t)*s;
    FINISH = 0x5555;
    for (;;) {}
}
