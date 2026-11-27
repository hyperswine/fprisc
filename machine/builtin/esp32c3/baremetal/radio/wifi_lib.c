#include "alloc.h"
#include "task.h"

void *malloc(size_t bytes) { return c3_radio_alloc(bytes); }
void free(void *buffer) { c3_radio_free(buffer); }
void *realloc(void *buffer, size_t bytes) { return c3_radio_realloc(buffer, bytes); }
void *calloc(size_t count, size_t bytes) { return c3_radio_calloc(count, bytes); }

/* Vendor diagnostics remain disabled to avoid blocking in an ISR. */
int puts(const char *text) { (void)text; return 0; }
