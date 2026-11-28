#include "btdm_services.h"
#include "os_queue.h"

#ifndef C3_RADIO_QUEUE_BYTES
#define C3_RADIO_QUEUE_BYTES 1024
#endif

enum {
    QUEUES = 4, SEMAPHORES = 8, MUTEXES = 4,
    CONTROLLER_TASKS = 2, STACK_BYTES = 8192, TICK_US = 1000,
};
static struct queue_slot {
    c3_os_queue queue;
    unsigned waiters;
    bool used;
    uint8_t storage[C3_RADIO_QUEUE_BYTES];
} queues[QUEUES];

static struct semaphore_slot {
    c3_os_semaphore sem;
    unsigned waiters;
    bool used;
} semaphores[SEMAPHORES];

static struct mutex_slot {
    c3_task_id owner;
    unsigned depth, waiters;
    bool used;
} mutexes[MUTEXES];

static struct task_slot {
    c3_task_id id;
    c3_task_entry entry;
    void *arg;
    _Alignas(16) uint8_t stack[STACK_BYTES];
} task_slots[CONTROLLER_TASKS];

static unsigned irq_depth;
static bool scheduler_started;
static unsigned main_task_handle;
static void (*task_cleanup)(c3_task_id);

void c3_services_set_task_cleanup(void (*cleanup)(c3_task_id)) {
    task_cleanup = cleanup;
}

void *c3_services_current_task(void) {
    c3_task_id id = c3_task_current();
    for (unsigned i = 0; i < CONTROLLER_TASKS; ++i)
        if (task_slots[i].id == id) return &task_slots[i];
    return &main_task_handle;
}

static unsigned *task_waiters[C3_TASK_LIMIT];

static void begin_wait(unsigned *waiters) {
    task_waiters[c3_task_current() - 1] = waiters;
    ++*waiters;
}

static void end_wait(c3_task_id id) {
    unsigned **waiters = &task_waiters[id - 1];
    if (*waiters) {
        --**waiters;
        *waiters = NULL;
    }
}

static uint64_t deadline(uint32_t ticks) {
    if (ticks == UINT32_MAX) return C3_WAIT_FOREVER;
    return c3_tasks_now_us() + (uint64_t)ticks * TICK_US;
}

static void *create_queue(uint32_t count, uint32_t item_bytes) {
    for (unsigned i = 0; i < QUEUES; ++i) {
        struct queue_slot *s = &queues[i];
        if (s->used) continue;
        if (!c3_queue_init(&s->queue, s->storage, sizeof(s->storage), count, item_bytes))
            return NULL;
        s->used = true;
        return s;
    }
    return NULL;
}

static void delete_queue(void *handle) {
    struct queue_slot *s = handle;
    if (s && s->waiters) __builtin_trap();
    if (s) s->used = false;
}

static int32_t send(void *handle, void *item, uint32_t ticks) {
    struct queue_slot *s = handle;
    if (!s || !s->used || !item || irq_depth) return 0;
    begin_wait(&s->waiters);
    bool ok = c3_queue_send(&s->queue, item, deadline(ticks));
    end_wait(c3_task_current());
    return ok;
}

int32_t c3_services_queue_send_front(void *handle, void *item, uint32_t ticks) {
    struct queue_slot *s = handle;
    if (!s || !s->used || !item || irq_depth) return 0;
    begin_wait(&s->waiters);
    bool ok = c3_queue_send_front(&s->queue, item, deadline(ticks));
    end_wait(c3_task_current());
    return ok;
}

uint32_t c3_services_queue_waiting(void *handle) {
    const struct queue_slot *s = handle;
    return s && s->used ? s->queue.count : 0;
}

static int32_t receive(void *handle, void *item, uint32_t ticks) {
    struct queue_slot *s = handle;
    if (!s || !s->used || !item || irq_depth) return 0;
    begin_wait(&s->waiters);
    bool ok = c3_queue_receive(&s->queue, item, deadline(ticks));
    end_wait(c3_task_current());
    return ok;
}

static int32_t send_from_isr(void *handle, void *item, void *higher) {
    struct queue_slot *s = handle;
    return s && s->used && item && c3_queue_try_send(&s->queue, item, higher);
}

static int32_t receive_from_isr(void *handle, void *item, void *higher) {
    struct queue_slot *s = handle;
    return s && s->used && item && c3_queue_try_receive(&s->queue, item, higher);
}

static void *create_semaphore(uint32_t limit, uint32_t count) {
    for (unsigned i = 0; i < SEMAPHORES; ++i) {
        struct semaphore_slot *s = &semaphores[i];
        if (s->used) continue;
        if (!c3_semaphore_init(&s->sem, limit, count)) return NULL;
        s->used = true;
        return s;
    }
    return NULL;
}

static void delete_semaphore(void *handle) {
    struct semaphore_slot *s = handle;
    if (s && s->waiters) __builtin_trap();
    if (s) s->used = false;
}

static int32_t semaphore_take(void *handle, uint32_t ticks) {
    struct semaphore_slot *s = handle;
    if (!s || !s->used || irq_depth) return 0;
    begin_wait(&s->waiters);
    bool ok = c3_semaphore_take(&s->sem, deadline(ticks));
    end_wait(c3_task_current());
    return ok;
}

static int32_t semaphore_take_from_isr(void *handle, bool *higher) {
    struct semaphore_slot *s = handle;
    (void)higher;
    return s && s->used && c3_semaphore_try_take(&s->sem);
}

static int32_t semaphore_give_from_isr(void *handle, bool *higher) {
    struct semaphore_slot *s = handle;
    return s && s->used && c3_semaphore_give(&s->sem, higher);
}

static int32_t semaphore_give(void *handle) {
    return semaphore_give_from_isr(handle, NULL);
}

static const void *create_mutex(void) {
    for (unsigned i = 0; i < MUTEXES; ++i) {
        struct mutex_slot *s = &mutexes[i];
        if (!s->used) {
            s->used = true;
            return s;
        }
    }
    return NULL;
}

static void delete_mutex(const void *handle) {
    struct mutex_slot *s = (struct mutex_slot *)handle;
    if (s && (s->waiters || s->depth)) __builtin_trap();
    if (s) s->used = false;
}

static int32_t mutex_lock(const void *handle) {
    struct mutex_slot *s = (struct mutex_slot *)handle;
    if (!s || !s->used || irq_depth) return 0;
    c3_task_id current = c3_task_current();
    while (s->owner && s->owner != current) {
        begin_wait(&s->waiters);
        c3_task_park(s, C3_WAIT_FOREVER);
        end_wait(c3_task_current());
    }
    s->owner = current;
    ++s->depth;
    return 1;
}

static int32_t mutex_unlock(const void *handle) {
    struct mutex_slot *s = (struct mutex_slot *)handle;
    if (!s || !s->used || s->owner != c3_task_current() || irq_depth) return 0;
    if (!--s->depth) {
        s->owner = C3_TASK_INVALID;
        c3_tasks_wake(s);
    }
    return 1;
}

static void run_task(void *arg) {
    struct task_slot *s = arg;
    s->entry(s->arg);
    if (task_cleanup) task_cleanup(s->id);
    s->id = C3_TASK_INVALID;
}

static int32_t create_task(void *entry, const char *name, uint32_t bytes,
                           void *arg, uint32_t priority, void *handle, uint32_t core) {
    (void)name;
    if (!entry || irq_depth || bytes > STACK_BYTES || (core != 0 && core != INT32_MAX && core != UINT32_MAX))
        return 0;
    for (unsigned i = 0; i < CONTROLLER_TASKS; ++i) {
        struct task_slot *s = &task_slots[i];
        if (s->id != C3_TASK_INVALID) continue;
        s->entry = (c3_task_entry)entry;
        s->arg = arg;
        s->id = c3_task_create(run_task, s, priority, s->stack, bytes);
        if (s->id == C3_TASK_INVALID) return 0;
        if (handle) *(void **)handle = s;
        return 1;
    }
    return 0;
}

static void delete_task(void *handle) {
    if (irq_depth) __builtin_trap();
    for (unsigned i = 0; i < CONTROLLER_TASKS; ++i) {
        struct task_slot *s = &task_slots[i];
        c3_task_id id = s->id;
        if (id != C3_TASK_INVALID && (handle == s || (!handle && id == c3_task_current()))) {
            for (unsigned j = 0; j < MUTEXES; ++j)
                if (mutexes[j].owner == id) __builtin_trap();
            end_wait(id);
            if (task_cleanup) task_cleanup(id);
            s->id = C3_TASK_INVALID;
            c3_task_delete(id);
            return;
        }
    }
}

static int32_t is_in_isr(void) { return irq_depth != 0; }

void c3_btdm_isr_enter(void) { ++irq_depth; }
void c3_btdm_isr_leave(void) { --irq_depth; }

/* Scheduling happens after dispatch returns to the scheduler's idle loop
 * or when the current task reaches a cooperative scheduling point. */
static void yield_from_isr(void) {}

void c3_btdm_install_services(struct c3_btdm_osi *table, unsigned priority) {
    if (!scheduler_started) {
        c3_tasks_init(priority);
        scheduler_started = true;
    }
    table->magic = C3_BTDM_OSI_MAGIC;
    table->version = C3_BTDM_OSI_VERSION;
    table->task_yield = c3_task_yield;
    table->task_yield_from_isr = yield_from_isr;
    table->task_create = create_task;
    table->task_delete = delete_task;
    table->is_in_isr = is_in_isr;
    table->queue_create = create_queue;
    table->queue_delete = delete_queue;
    table->queue_send = send;
    table->queue_recv = receive;
    table->queue_send_from_isr = send_from_isr;
    table->queue_recv_from_isr = receive_from_isr;
    table->semphr_create = create_semaphore;
    table->semphr_delete = delete_semaphore;
    table->semphr_take = semaphore_take;
    table->semphr_give = semaphore_give;
    table->semphr_take_from_isr = semaphore_take_from_isr;
    table->semphr_give_from_isr = semaphore_give_from_isr;
    table->mutex_create = create_mutex;
    table->mutex_delete = delete_mutex;
    table->mutex_lock = mutex_lock;
    table->mutex_unlock = mutex_unlock;
    table->get_time_us = c3_tasks_now_us;
}
