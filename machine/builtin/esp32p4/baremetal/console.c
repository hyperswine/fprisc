#include "builtin.h"
#include "i32.h"
#include "platform.h"

enum { UART0 = 0x500ca000, STATUS = UART0 + 0x1c, FIFO_CAPACITY = 128 };

static void write_bytes(const char *text, uw count) {
    volatile uint32_t *const fifo = (volatile uint32_t *)UART0;
    const volatile uint32_t *const status = (const volatile uint32_t *)STATUS;
    while (count--) {
        while (((*status >> 16) & 0xffu) >= FIFO_CAPACITY) {}
        *fifo = (uint8_t)*text++;
    }
}

static void write_string(const char *text) {
    uw count = 0;
    while (text[count]) ++count;
    write_bytes(text, count);
}

void fpr_cpanic_n(const char *message, uw count) {
    write_string("P4 PANIC: ");
    write_bytes(message, count);
    write_string("\n");
    for (;;) __asm__ volatile("wfi");
}

void fpr_cpanic(const char *message) {
    uw count = 0;
    while (message[count]) ++count;
    fpr_cpanic_n(message, count);
}

static V serial_result(V value, V passed) {
    int32_t number = (int32_t)fpr_i32_bits(value);
    uint32_t magnitude = number < 0 ? 0u - (uint32_t)number : (uint32_t)number;
    char digits[11];
    unsigned index = sizeof(digits);
    do {
        digits[--index] = '0' + magnitude % 10;
        magnitude /= 10;
    } while (magnitude);
    if (number < 0) digits[--index] = '-';
    write_string("P4 BARE METAL integer self-check: ");
    write_bytes(digits + index, sizeof(digits) - index);
    write_string(UNTAG(passed) ? " [PASS]\n" : " [FAIL]\n");
    return V_UNIT;
}
FPR_FN(fpr_g_Serial_x2eresult, serial_result, 2);

void p4_puts(const char *message) { write_string(message); }

void p4_hex(uint32_t value) {
    char output[8];
    for (unsigned i = 0; i < sizeof(output); ++i)
        output[i] = "0123456789abcdef"[(value >> (28 - i * 4)) & 15];
    write_bytes(output, sizeof(output));
}

extern void p4_sdio_probe(void);
static uint8_t wait_for_query(void) {
    const volatile uint32_t *const fifo = (const volatile uint32_t *)UART0;
    const volatile uint32_t *const status = (const volatile uint32_t *)STATUS;
    for (;;) {
        while (!(*status & 0xffu)) {}
        uint8_t key = (uint8_t)*fifo;
        if (key == '?' || key == 'B' || key == 'T' || key == 'G') return key;
    }
}

extern V fpr_fn_main(void);
void p4_main(void) {
    static _Alignas(16) unsigned char heap[8192];
    fpr_set_tp(&fpr_harts[0]);
    fpr_builtin_heap_init(heap, heap + sizeof(heap));
    uint8_t query = wait_for_query();
    fpr_fn_main();
    if (query == 'B') p4_sdio_probe();
    if (query == 'T' || query == 'G') {
        p4_clock_init();
        p4_irq_init();
        write_string(p4_trap_check() ? "P4 machine trap PASS\n" : "P4 machine trap FAIL\n");
        write_string(p4_clock_check() ? "P4 monotonic deadline IRQ PASS\n" :
                                       "P4 monotonic deadline IRQ FAIL\n");
        if (query == 'G')
            write_string(p4_button_check() ? "P4 GPIO debounce PASS\n" : "P4 GPIO debounce FAIL\n");
    }
    write_string("FPR DONE\n");
}
