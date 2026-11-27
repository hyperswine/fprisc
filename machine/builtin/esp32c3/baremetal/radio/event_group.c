#include "event_group.h"

enum { EVENT_GROUPS = 4, TICK_US = 1000 };

struct waiter {
    uint32_t wanted, result;
    bool all, clear, ready;
};

struct event_group {
    uint32_t bits;
    bool used;
    struct waiter *waiting[C3_TASK_LIMIT];
};

static struct event_group groups[EVENT_GROUPS];

static bool matches(uint32_t bits, const struct waiter *waiter) {
    uint32_t overlap = bits & waiter->wanted;
    return waiter->all ? overlap == waiter->wanted : overlap != 0;
}

void *c3_events_create(void) {
    for (unsigned i = 0; i < EVENT_GROUPS; ++i) {
        struct event_group *group = &groups[i];
        if (group->used) continue;
        group->bits = 0;
        for (unsigned j = 0; j < C3_TASK_LIMIT; ++j) group->waiting[j] = NULL;
        group->used = true;
        return group;
    }
    return NULL;
}

void c3_events_delete(void *handle) {
    struct event_group *group = handle;
    if (!group || !group->used) return;
    for (unsigned i = 0; i < C3_TASK_LIMIT; ++i) {
        struct waiter *waiter = group->waiting[i];
        if (!waiter) continue;
        waiter->result = 0;
        waiter->ready = true;
        group->waiting[i] = NULL;
        c3_tasks_wake(waiter);
    }
    group->used = false;
}

uint32_t c3_events_set(void *handle, uint32_t bits) {
    struct event_group *group = handle;
    if (!group || !group->used) return 0;
    uint32_t snapshot = group->bits | bits;
    uint32_t clear = 0;
    for (unsigned i = 0; i < C3_TASK_LIMIT; ++i) {
        struct waiter *waiter = group->waiting[i];
        if (!waiter || !matches(snapshot, waiter)) continue;
        waiter->result = snapshot;
        waiter->ready = true;
        group->waiting[i] = NULL;
        if (waiter->clear) clear |= waiter->wanted;
        c3_tasks_wake(waiter);
    }
    group->bits = snapshot & ~clear;
    return group->bits;
}

uint32_t c3_events_clear(void *handle, uint32_t bits) {
    struct event_group *group = handle;
    if (!group || !group->used) return 0;
    uint32_t previous = group->bits;
    group->bits &= ~bits;
    return previous;
}

uint32_t c3_events_wait(void *handle, uint32_t wanted, int clear, int all,
                       uint32_t ticks) {
    struct event_group *group = handle;
    if (!group || !group->used || !wanted) return 0;
    struct waiter waiter = {.wanted = wanted, .clear = clear != 0, .all = all != 0};
    uint32_t snapshot = group->bits;
    if (matches(snapshot, &waiter)) {
        if (clear) group->bits &= ~wanted;
        return snapshot;
    }
    if (!ticks) return snapshot;
    uint64_t deadline = ticks == UINT32_MAX
        ? C3_WAIT_FOREVER : c3_tasks_now_us() + (uint64_t)ticks * TICK_US;
    unsigned slot = c3_task_current() - 1;
    group->waiting[slot] = &waiter;
    while (!waiter.ready && c3_tasks_now_us() < deadline)
        c3_task_park(&waiter, deadline);
    if (waiter.ready) return waiter.result;
    group->waiting[slot] = NULL;
    return group->bits;
}
void c3_events_cancel(c3_task_id id) {
    if (!id || id > C3_TASK_LIMIT) return;
    for (unsigned i = 0; i < EVENT_GROUPS; ++i) groups[i].waiting[id - 1] = NULL;
}
