#include <stdio.h>
#include "esp_heap_caps.h"
#include "driver/usb_serial_jtag.h"
#include "freertos/task.h"
#include <stdarg.h>
#include <stdlib.h>
#include "builtin.h"
#include "i32.h"

static unsigned char heap[8192] __attribute__((aligned(16)));
extern V fpr_fn_main(void);

void fpr_cpanic(const char *message) {
    printf("C3 BUILTIN PANIC: %s\n", message);
    fflush(stdout);
    abort();
}

static void serial_line(const char *format, ...) {
    char line[128];
    va_list args;
    va_start(args, format);
    int n = vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (n < 0 || (size_t)n >= sizeof(line) ||
        usb_serial_jtag_write_bytes(line, n, portMAX_DELAY) != n) abort();
}

static V serial_result(V value, V passed) {
    serial_line("C3 BUILTIN integer self-check: 12345 * 67 + 89 = %ld [%s]\n",
           (long)(int32_t)fpr_i32_bits(value), UNTAG(passed) ? "PASS" : "FAIL");
    return V_UNIT;
}
FPR_FN(fpr_g_Serial_x2eresult, serial_result, 2);

void app_main(void) {
    /* IDF owns tp. Runtime primitives find the sole Builtin hart through task TLS. */
    fpr_set_tp(&fpr_harts[0]);
    fpr_builtin_heap_init(heap, heap + sizeof(heap));
    usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&config));
    serial_line("FPR READY free_heap=%u\n", (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT));
    V status = fpr_fn_main();
    serial_line("FPR DONE %ld\n", ISINT(status) ? (long)UNTAG(status) : 0L);
    vTaskDelete(NULL);
}
