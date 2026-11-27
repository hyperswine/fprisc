#include <errno.h>
#include "builtin.h"
#include "i32.h"

/* C3 TRM, USB Serial/JTAG EP1 and EP1_CONF. The ROM downloader leaves
 * the peripheral and PHY enabled. Submit short packets explicitly. */
static volatile uint32_t *const fifo = (volatile uint32_t *)0x60043000;
static volatile uint32_t *const config = (volatile uint32_t *)0x60043004;
static void write_bytes(const char *s, uw n) {
    while (n) {
        while (!(*config & 2)) {}
        uw packet = n < 64 ? n : 64;
        for (uw i = 0; i < packet; ++i) *fifo = (unsigned char)*s++;
        *config = 1;
        n -= packet;
    }
}
static void puts_usb(const char *s) {
    uw n = 0;
    while (s[n]) ++n;
    write_bytes(s, n);
}
static void put_hex(uint32_t value) {
    char digits[8];
    for (unsigned i = 0; i < sizeof(digits); ++i)
        digits[i] = "0123456789abcdef"[(value >> (28 - 4 * i)) & 15];
    write_bytes(digits, sizeof(digits));
}

_Noreturn void c3_fatal_trap(uint32_t cause, uint32_t pc) {
    puts_usb("C3 trap cause=0x");
    put_hex(cause);
    puts_usb(" pc=0x");
    put_hex(pc);
    puts_usb("\n");
    for (;;) __asm__ volatile("wfi");
}

void fpr_cpanic_n(const char *s, uw n) {
    puts_usb("C3 PANIC: ");
    write_bytes(s, n);
    puts_usb("\n");
    for (;;) {}
}
void fpr_cpanic(const char *s) {
    uw n = 0;
    while (s[n]) ++n;
    fpr_cpanic_n(s, n);
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
    puts_usb("C3 BARE METAL integer self-check: ");
    write_bytes(digits + index, sizeof(digits) - index);
    puts_usb(UNTAG(passed) ? " [PASS]\n" : " [FAIL]\n");
    return V_UNIT;
}
FPR_FN(fpr_g_Serial_x2eresult, serial_result, 2);

static V write_byte(V byte) {
    if (!ISINT(byte) || UNTAG(byte) < 0 || UNTAG(byte) > 255) return TAG(-EINVAL);
    char value = (char)UNTAG(byte);
    write_bytes(&value, 1);
    return TAG(1);
}
FPR_FN(fpr_g_EspIO_x2ewriteByte, write_byte, 1);

extern V fpr_fn_main(void);
void c3_main(void) {
    static unsigned char heap[8192] __attribute__((aligned(16)));
    fpr_set_tp(&fpr_harts[0]);
    fpr_builtin_heap_init(heap, heap + sizeof(heap));
    fpr_fn_main();
    puts_usb("FPR DONE\n");
}
