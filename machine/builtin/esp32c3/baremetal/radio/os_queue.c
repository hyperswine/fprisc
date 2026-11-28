#include "os_queue.h"

bool c3_queue_init(c3_os_queue *q, void *buffer, size_t bytes,
                   unsigned capacity, unsigned item_bytes) {
    if (!buffer || !capacity || !item_bytes || bytes / item_bytes < capacity) return false;
    q->buffer = buffer;
    q->capacity = capacity;
    q->item_bytes = item_bytes;
    q->head = q->count = 0;
    return true;
}

static void copy_bytes(void *destination, const void *source, unsigned bytes) {
    uint8_t *out = destination;
    const uint8_t *in = source;
    for (unsigned i = 0; i < bytes; ++i) out[i] = in[i];
}

static void signal(const void *channel, bool *higher_priority_woken) {
    bool higher = c3_tasks_wake(channel);
    if (higher_priority_woken && higher) *higher_priority_woken = true;
}

bool c3_queue_try_send(c3_os_queue *q, const void *item, bool *higher_priority_woken) {
    if (q->count == q->capacity) return false;
    unsigned to_end = q->capacity - q->head;
    unsigned tail = q->count < to_end ? q->head + q->count : q->count - to_end;
    copy_bytes(q->buffer + (size_t)tail * q->item_bytes, item, q->item_bytes);
    ++q->count;
    signal(&q->count, higher_priority_woken);
    return true;
}

bool c3_queue_try_receive(c3_os_queue *q, void *item, bool *higher_priority_woken) {
    if (q->count == 0) return false;
    copy_bytes(item, q->buffer + (size_t)q->head * q->item_bytes, q->item_bytes);
    q->head = (q->head + 1) % q->capacity;
    --q->count;
    signal(&q->head, higher_priority_woken);
    return true;
}

bool c3_queue_send(c3_os_queue *q, const void *item, uint64_t deadline) {
    while (!c3_queue_try_send(q, item, NULL)) {
        if (c3_tasks_now_us() >= deadline) return false;
        c3_task_park(&q->head, deadline);
    }
    return true;
}

bool c3_queue_send_front(c3_os_queue *q, const void *item, uint64_t deadline) {
    while (q->count == q->capacity) {
        if (c3_tasks_now_us() >= deadline) return false;
        c3_task_park(&q->head, deadline);
    }
    q->head = q->head ? q->head - 1 : q->capacity - 1;
    copy_bytes(q->buffer + (size_t)q->head * q->item_bytes, item, q->item_bytes);
    ++q->count;
    signal(&q->count, NULL);
    return true;
}

bool c3_queue_receive(c3_os_queue *q, void *item, uint64_t deadline) {
    while (!c3_queue_try_receive(q, item, NULL)) {
        if (c3_tasks_now_us() >= deadline) return false;
        c3_task_park(&q->count, deadline);
    }
    return true;
}

bool c3_semaphore_init(c3_os_semaphore *sem, unsigned limit, unsigned count) {
    if (!limit || count > limit) return false;
    sem->count = count;
    sem->limit = limit;
    return true;
}

bool c3_semaphore_try_take(c3_os_semaphore *sem) {
    if (sem->count == 0) return false;
    --sem->count;
    return true;
}

bool c3_semaphore_take(c3_os_semaphore *sem, uint64_t deadline) {
    while (!c3_semaphore_try_take(sem)) {
        if (c3_tasks_now_us() >= deadline) return false;
        c3_task_park(sem, deadline);
    }
    return true;
}

bool c3_semaphore_give(c3_os_semaphore *sem, bool *higher_priority_woken) {
    if (sem->count == sem->limit) return false;
    ++sem->count;
    signal(sem, higher_priority_woken);
    return true;
}
