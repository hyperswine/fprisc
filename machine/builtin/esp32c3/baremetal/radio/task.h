#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The controller adapter owns the stacks. Call task services on one hart
 * with interrupts masked. Only wake is callable from interrupt context. */
typedef void (*c3_task_entry)(void *);
typedef unsigned c3_task_id;
enum { C3_TASK_INVALID = 0, C3_TASK_LIMIT = 8 };
#define C3_WAIT_FOREVER UINT64_MAX

void c3_tasks_init(unsigned main_priority);
c3_task_id c3_task_create(c3_task_entry entry, void *arg, unsigned priority,
                          void *stack, size_t bytes);
bool c3_task_delete(c3_task_id id);
void c3_task_yield(void);
/* The caller checks its queue/semaphore before sleeping and rechecks after
 * wake. A wake at the deadline can race timeout, so availability wins. */
void c3_task_park(const void *channel, uint64_t deadline_us);
bool c3_tasks_wake(const void *channel);
c3_task_id c3_task_current(void);

/* The platform clock and idle functions use the same unit and epoch.
 * Idle returns after a pending interrupt or the requested deadline. */
uint64_t c3_tasks_now_us(void);
void c3_tasks_idle_until(uint64_t deadline_us);
