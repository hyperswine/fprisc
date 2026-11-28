#pragma once

#include "task.h"

/* Event groups are single-hart objects. Call with interrupts masked.
 * Only setting bits is supported in ISR context. */
void *c3_events_create(void);
void c3_events_delete(void *handle);
uint32_t c3_events_set(void *handle, uint32_t bits);
uint32_t c3_events_clear(void *handle, uint32_t bits);
uint32_t c3_events_wait(void *handle, uint32_t wanted, int clear, int all,
                       uint32_t ticks);
void c3_events_cancel(c3_task_id task);
