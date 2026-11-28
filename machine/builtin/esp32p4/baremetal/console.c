#include "builtin.h"
#include "i32.h"
#include "platform.h"
#if P4_FLASH_CHECK
#include "flash.h"
#endif

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

static uint8_t wait_for_query(void) {
    const volatile uint32_t *const fifo = (const volatile uint32_t *)UART0;
    const volatile uint32_t *const status = (const volatile uint32_t *)STATUS;
    for (;;) {
        while (!(*status & 0xffu)) {}
        uint8_t key = (uint8_t)*fifo;
        if (key == '?' || key == 'B' || key == 'T' || key == 'G') return key;
    }
}

int p4_uart_read_byte(void) {
    const volatile uint32_t *const fifo = (const volatile uint32_t *)UART0;
    const volatile uint32_t *const status = (const volatile uint32_t *)STATUS;
    return (*status & 0xffu) ? (int)(uint8_t)*fifo : -1;
}

static V try_read_byte(V unit) {
    (void)unit;
    return TAG(p4_uart_read_byte());
}
FPR_FN(fpr_g_EspIO_x2etryReadByte, try_read_byte, 1);

static V reset_companion(V unit) {
    (void)unit;
    /* Exercise recovery by pulsing EN without changing host transport state. */
    p4_sdio_pulse_companion_en();
    return V_UNIT;
}
FPR_FN(fpr_g_P4Test_x2eresetCompanion, reset_companion, 1);

static V stats(V unit) {
    (void)unit;
    fpr_builtin_heap_stats heap;
    fpr_builtin_heap_get_stats(&heap);
    p4_puts("FPR P4 BLE STATS ms=");
    p4_hex((uint32_t)(p4_clock_now_us() / 1000));
    p4_puts(" live=");
    p4_hex(heap.live_bytes);
    p4_puts(" peak=");
    p4_hex(heap.peak_bytes);
    p4_puts("\n");
    return V_UNIT;
}
FPR_FN(fpr_g_P4Test_x2estats, stats, 1);

extern V fpr_fn_main(void);
void p4_main(void) {
    static _Alignas(16) unsigned char heap[8192];
    fpr_set_tp(&fpr_harts[0]);
    fpr_builtin_heap_init(heap, heap + sizeof(heap));
#if P4_FLASH_CHECK
    p4_flash_init();
    p4_clock_init();
    p4_irq_init();
    p4_puts("FPR P4 FLASH BOOT\n");
    fpr_fn_main();
    p4_flash_check();
#else
    uint8_t query = wait_for_query();
    if (query != 'B') {
        p4_clock_init();
        p4_irq_init();
    }
    V result = fpr_fn_main();
    if (ISINT(result) && UNTAG(result) != 0) {
        p4_puts("P4 Builtin main failed ");
        p4_hex((uint32_t)UNTAG(result));
        p4_puts("\n");
    }
    if (query == 'B') p4_sdio_probe();
    if (query == 'T' || query == 'G') {
        write_string(p4_trap_check() ? "P4 machine trap PASS\n" : "P4 machine trap FAIL\n");
        write_string(p4_clock_check() ? "P4 monotonic deadline IRQ PASS\n" :
                                       "P4 monotonic deadline IRQ FAIL\n");
        if (query == 'G')
            write_string(p4_button_check() ? "P4 GPIO debounce PASS\n" : "P4 GPIO debounce FAIL\n");
    }
#endif
    write_string("FPR DONE\n");
}
