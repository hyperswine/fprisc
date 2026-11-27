#pragma once

#include "task.h"

/* Owner supplies storage and keeps objects alive until waiters return.
 * Task calls and ISR operations run with interrupts masked. */
typedef struct {
    uint8_t *buffer;
    unsigned capacity, item_bytes, head, count;
} c3_os_queue;

bool c3_queue_init(c3_os_queue *queue, void *buffer, size_t bytes,
                   unsigned capacity, unsigned item_bytes);
bool c3_queue_send(c3_os_queue *queue, const void *item, uint64_t deadline_us);
bool c3_queue_receive(c3_os_queue *queue, void *item, uint64_t deadline_us);
bool c3_queue_try_send(c3_os_queue *queue, const void *item, bool *higher_priority_woken);
bool c3_queue_try_receive(c3_os_queue *queue, void *item, bool *higher_priority_woken);

typedef struct {
    unsigned count, limit;
} c3_os_semaphore;

bool c3_semaphore_init(c3_os_semaphore *sem, unsigned limit, unsigned count);
bool c3_semaphore_take(c3_os_semaphore *sem, uint64_t deadline_us);
bool c3_semaphore_try_take(c3_os_semaphore *sem);
bool c3_semaphore_give(c3_os_semaphore *sem, bool *higher_priority_woken);
