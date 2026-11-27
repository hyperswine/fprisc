#pragma once

#include <stdint.h>

/* SYSTIMER UNIT0 in microseconds since hardware reset. */
uint64_t c3_clock_now_us(void);

/* With interrupts masked, idle until an interrupt or a finite deadline.
 * UINT64_MAX waits for an interrupt alone. */
void c3_clock_wait_us(uint64_t deadline_us);
