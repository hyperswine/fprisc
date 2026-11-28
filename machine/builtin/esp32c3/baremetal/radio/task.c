#include "task.h"

enum task_state { UNUSED, READY, BLOCKED };

struct context {
    uintptr_t sp, ra, saved[12];
};

struct task {
    struct context registers;
    c3_task_entry entry;
    void *arg;
    const void *channel;
    uint64_t deadline;
    unsigned priority;
    enum task_state state;
};

_Static_assert(offsetof(struct context, saved) == 8, "RV32 assembly context");
_Static_assert(sizeof(struct context) == 56, "RV32 assembly context");

static struct task tasks[C3_TASK_LIMIT];
static unsigned current;

extern void c3_task_switch(struct context *old, const struct context *next);

void c3_tasks_init(unsigned priority) {
    current = 0;
    for (unsigned i = 1; i < C3_TASK_LIMIT; ++i) tasks[i].state = UNUSED;
    tasks[0].priority = priority;
    tasks[0].state = READY;
}

static void schedule(void) {
    for (;;) {
        uint64_t now = c3_tasks_now_us();
        uint64_t next_deadline = C3_WAIT_FOREVER;
        unsigned best = C3_TASK_LIMIT;
        for (unsigned offset = 1; offset <= C3_TASK_LIMIT; ++offset) {
            unsigned i = (current + offset) % C3_TASK_LIMIT;
            struct task *t = &tasks[i];
            if (t->state == BLOCKED && t->deadline != C3_WAIT_FOREVER) {
                if (t->deadline <= now) {
                    t->state = READY;
                    t->channel = NULL;
                } else if (t->deadline < next_deadline) {
                    next_deadline = t->deadline;
                }
            }
            if (t->state == READY && (best == C3_TASK_LIMIT || t->priority > tasks[best].priority))
                best = i;
        }
        if (best != C3_TASK_LIMIT) {
            if (best != current) {
                unsigned prior = current;
                current = best;
                c3_task_switch(&tasks[prior].registers, &tasks[best].registers);
            }
            return;
        }
        c3_tasks_idle_until(next_deadline);
    }
}

static _Noreturn void task_entry(void) {
    struct task *t = &tasks[current];
    t->entry(t->arg);
    c3_task_delete(c3_task_current());
    __builtin_trap();
}

c3_task_id c3_task_create(c3_task_entry entry, void *arg, unsigned priority,
                          void *stack, size_t bytes) {
    uintptr_t base = (uintptr_t)stack;
    if (!entry || !stack || bytes > UINTPTR_MAX - base) return C3_TASK_INVALID;
    uintptr_t top = (base + bytes) & ~(uintptr_t)15;
    if (top < base || top - base < 256) return C3_TASK_INVALID;
    for (unsigned i = 1; i < C3_TASK_LIMIT; ++i) {
        struct task *t = &tasks[i];
        if (t->state != UNUSED) continue;
        t->registers.sp = top;
        t->registers.ra = (uintptr_t)task_entry;
        for (unsigned r = 0; r < 12; ++r) t->registers.saved[r] = 0;
        t->entry = entry;
        t->arg = arg;
        t->priority = priority;
        t->state = READY;
        return i + 1;
    }
    return C3_TASK_INVALID;
}

bool c3_task_delete(c3_task_id id) {
    if (id <= 1 || id > C3_TASK_LIMIT || tasks[id - 1].state == UNUSED) return false;
    tasks[id - 1].state = UNUSED;
    tasks[id - 1].channel = NULL;
    if (id - 1 == current) schedule();
    return true;
}

void c3_task_yield(void) {
    schedule();
}

void c3_task_park(const void *channel, uint64_t deadline_us) {
    struct task *t = &tasks[current];
    t->channel = channel;
    t->deadline = deadline_us;
    t->state = BLOCKED;
    schedule();
}

bool c3_tasks_wake(const void *channel) {
    bool higher = false;
    for (unsigned i = 0; i < C3_TASK_LIMIT; ++i) {
        struct task *t = &tasks[i];
        if (t->state == BLOCKED && t->channel == channel) {
            t->state = READY;
            t->channel = NULL;
            higher |= t->priority > tasks[current].priority;
        }
    }
    return higher;
}

c3_task_id c3_task_current(void) {
    return current + 1;
}
