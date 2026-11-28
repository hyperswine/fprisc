#pragma once

#include <stddef.h>

void *c3_radio_alloc(size_t bytes);
void *c3_radio_calloc(size_t count, size_t bytes);
void *c3_radio_realloc(void *ptr, size_t bytes);
size_t c3_radio_available(void);
void c3_radio_free(void *ptr);
size_t c3_radio_allocated(void);
size_t c3_radio_peak(void);
