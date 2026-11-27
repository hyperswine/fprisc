#include "os_timer.h"

enum { TIMER_LIMIT = 24, TIMER_STACK_BYTES = 2048 };
static struct timer {
    void *handle;
    c3_task_entry callback;
    void *arg;
    uint64_t deadline, period;
    bool armed;
} timers[TIMER_LIMIT];
static _Alignas(16) uint8_t timer_stack[TIMER_STACK_BYTES];
static c3_task_id worker;

static struct timer *find(void *handle) {
    if (!handle) return NULL;
    for (unsigned i = 0; i < TIMER_LIMIT; ++i)
        if (timers[i].handle == handle) return &timers[i];
    return NULL;
}

static void run_timers(void *unused) {
    (void)unused;
    for (;;) {
        uint64_t now = c3_tasks_now_us();
        struct timer *next = NULL;
        for (unsigned i = 0; i < TIMER_LIMIT; ++i) {
            struct timer *t = &timers[i];
            if (t->armed && (!next || t->deadline < next->deadline)) next = t;
        }
        if (!next || next->deadline > now) {
            c3_task_park(timers, next ? next->deadline : C3_WAIT_FOREVER);
            continue;
        }
        if (next->period) {
            uint64_t elapsed_periods = (now - next->deadline) / next->period;
            next->deadline += (elapsed_periods + 1) * next->period;
        } else {
            next->armed = false;
        }
        next->callback(next->arg);
    }
}

bool c3_timers_start(unsigned priority) {
    if (worker) return true;
    worker = c3_task_create(run_timers, NULL, priority, timer_stack, sizeof(timer_stack));
    return worker != C3_TASK_INVALID;
}

void c3_timer_set_callback(void *handle, void *function, void *arg) {
    if (!handle || !function) __builtin_trap();
    struct timer *t = find(handle);
    if (!t) {
        for (unsigned i = 0; i < TIMER_LIMIT; ++i) {
            if (!timers[i].handle) {
                t = &timers[i];
                break;
            }
        }
    }
    if (!t) __builtin_trap();
    t->handle = handle;
    t->callback = (c3_task_entry)function;
    t->arg = arg;
    t->armed = false;
    c3_tasks_wake(timers);
}

static void arm(void *handle, uint64_t us, bool repeat) {
    struct timer *t = find(handle);
    if (!t) __builtin_trap();
    if (!us && repeat) us = 1;
    t->period = repeat ? us : 0;
    t->deadline = c3_tasks_now_us() + us;
    t->armed = true;
    c3_tasks_wake(timers);
}

void c3_timer_arm_ms(void *handle, uint32_t ms, bool repeat) {
    arm(handle, (uint64_t)ms * 1000u, repeat);
}

void c3_timer_arm_us(void *handle, uint32_t us, bool repeat) {
    arm(handle, us, repeat);
}

void c3_timer_disarm(void *handle) {
    struct timer *t = find(handle);
    if (t) {
        t->armed = false;
        c3_tasks_wake(timers);
    }
}

void c3_timer_done(void *handle) {
    struct timer *t = find(handle);
    if (t) {
        t->armed = false;
        t->handle = NULL;
        c3_tasks_wake(timers);
    }
}
