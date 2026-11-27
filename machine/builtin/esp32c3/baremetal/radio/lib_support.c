#include <stddef.h>

size_t strlen(const char *s) {
    size_t length = 0;
    while (s[length]) ++length;
    return length;
}

/* Radio libraries may log from an interrupt. The first bring-up uses
 * phase markers from the application and leaves blob logging disabled. */
int __esp_radio_printf(const char *format, ...) {
    (void)format;
    return 0;
}

void _putchar(char byte) { (void)byte; }

int *__errno(void) {
    static int error;
    return &error;
}
