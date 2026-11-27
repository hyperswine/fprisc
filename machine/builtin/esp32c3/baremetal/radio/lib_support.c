#include <stddef.h>

size_t strlen(const char *s) {
    size_t length = 0;
    while (s[length]) ++length;
    return length;
}

/* Radio libraries may log from an interrupt. The first bring-up uses
 * phase markers from the application and leaves blob logging disabled. */
void __esp_radio_printf(const char *tag, const char *message) {
    (void)tag;
    (void)message;
}

void _putchar(char byte) { (void)byte; }

int *__errno(void) {
    static int error;
    return &error;
}
