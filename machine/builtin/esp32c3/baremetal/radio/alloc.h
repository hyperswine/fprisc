#pragma once

#include <stddef.h>

void *c3_radio_alloc(size_t bytes);
void c3_radio_free(void *ptr);
size_t c3_radio_allocated(void);
size_t c3_radio_peak(void);
