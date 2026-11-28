#include <errno.h>
#include <stdbool.h>
#include "builtin.h"
#include "i32.h"
#include "../main/bytes.h"

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

_Noreturn void c3_fatal_trap(uint32_t cause, uint32_t pc, uint32_t value, uint32_t saved_ra) {
    puts_usb("C3 trap cause=0x");
    put_hex(cause);
    puts_usb(" pc=0x");
    put_hex(pc);
    puts_usb(" mtval=0x");
    put_hex(value);
    puts_usb(" ra=0x");
    put_hex(saved_ra);
    puts_usb("\n");
    for (;;) __asm__ volatile("wfi");
}

void c3_console_text(const char *message) {
    puts_usb(message);
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
static void put_decimal(uint32_t magnitude, bool negative) {
    char digits[11];
    unsigned index = sizeof(digits);
    do {
        digits[--index] = '0' + magnitude % 10;
        magnitude /= 10;
    } while (magnitude);
    if (negative) digits[--index] = '-';
    write_bytes(digits + index, sizeof(digits) - index);
}

void c3_console_unsigned(uint32_t number) {
    put_decimal(number, false);
}

static V serial_result(V value, V passed) {
    int32_t number = (int32_t)fpr_i32_bits(value);
    uint32_t magnitude = number < 0 ? 0u - (uint32_t)number : (uint32_t)number;
    puts_usb("C3 BARE METAL integer self-check: ");
    put_decimal(magnitude, number < 0);
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

static unsigned read_usb_byte(void) {
    while (!(*config & (1u << 2))) {}
    return (uint8_t)*fifo;
}

int c3_console_read(void *context) {
    (void)context;
    return read_usb_byte();
}

int c3_console_try_read(void) {
    return (*config & (1u << 2)) ? (uint8_t)*fifo : -1;
}

static V read_byte(V unit) {
    (void)unit;
    return TAG(read_usb_byte());
}

static V read_exact(V addr, V length) {
    if (!ISINT(length) || UNTAG(length) < 0) return TAG(-EINVAL);
    uint8_t *bytes = buffer_ptr(addr);
    uw n = UNTAG(length);
    for (uw i = 0; i < n; ++i) bytes[i] = read_usb_byte();
    return length;
}

static V read_buffer(V addr, V length) {
    if (!ISINT(length) || UNTAG(length) < 0) return TAG(-EINVAL);
    uw capacity = UNTAG(length);
    if (!capacity) return length;
    uint8_t *bytes = buffer_ptr(addr);
    uw n = 0;
    bytes[n++] = read_usb_byte();
    while (n < capacity && (*config & (1u << 2))) bytes[n++] = (uint8_t)*fifo;
    return TAG(n);
}

static V write_buffer(V addr, V length) {
    if (!ISINT(length) || UNTAG(length) < 0) return TAG(-EINVAL);
    write_bytes(buffer_ptr(addr), UNTAG(length));
    return length;
}
FPR_FN(fpr_g_EspIO_x2eread, read_buffer, 2);
FPR_FN(fpr_g_EspIO_x2ereadByte, read_byte, 1);
FPR_FN(fpr_g_EspIO_x2ereadExact, read_exact, 2);
FPR_FN(fpr_g_EspIO_x2ewrite, write_buffer, 2);

_Noreturn void c3_test_cut_ready(void) {
    puts_usb("C3 CUT READY\n");
    for (;;) __asm__ volatile("wfi");
}

static V report_stats(V checkpoint) {
    fpr_builtin_heap_stats stats;
    fpr_builtin_heap_get_stats(&stats);
    puts_usb("FPR STATS ");
    put_decimal(UNTAG(checkpoint), false);
    puts_usb(" blocks=");
    put_decimal(fpr_builtin_live_allocations(), false);
    puts_usb(" live=");
    put_decimal(stats.live_bytes, false);
    puts_usb(" peak=");
    put_decimal(stats.peak_bytes, false);
    puts_usb("\n");
    return V_UNIT;
}
FPR_FN(fpr_g_EspStats_x2ereport, report_stats, 1);

extern V fpr_fn_main(void);
void c3_main(void) {
    static unsigned char heap[8192] __attribute__((aligned(16)));
    fpr_set_tp(&fpr_harts[0]);
    fpr_builtin_heap_init(heap, heap + sizeof(heap));
#ifdef C3_FLASH_BOOT
    /* The host queries the image after USB re-enumeration on cold boot. */
    while (read_usb_byte() != '?') {}
    puts_usb("FPR C3 FLASH " C3_EXAMPLE "\n");
#endif
    fpr_fn_main();
    puts_usb("FPR DONE\n");
}
