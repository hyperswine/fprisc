#include "task.h"

#include <errno.h>
#include <reent.h>
#include <sys/time.h>
#include <time.h>

extern uint32_t phy_enter_critical(void);
extern void phy_exit_critical(uint32_t);

/* The archive has a few atomic operations. On this single-hart RV32IMC
 * target, masking interrupts protects each operation from task and ISR
 * interference. A context switch only occurs in an explicit wait. */
/* GCC emits five arguments for the out-of-line entry point. */
bool c3_compare_exchange_1(volatile void *, void *, unsigned char, int, int)
    __asm__("__atomic_compare_exchange_1");
bool c3_compare_exchange_1(volatile void *ptr, void *expected,
                                 unsigned char desired, int success, int failure) {
    (void)success;
    (void)failure;
    uint32_t irq = phy_enter_critical();
    volatile uint8_t *byte = ptr;
    uint8_t actual = *byte;
    bool changed = actual == *(uint8_t *)expected;
    if (changed) *byte = desired;
    else *(uint8_t *)expected = actual;
    phy_exit_critical(irq);
    return changed;
}

unsigned int __atomic_exchange_4(volatile void *ptr, unsigned int value, int order) {
    (void)order;
    uint32_t irq = phy_enter_critical();
    volatile unsigned int *word = ptr;
    unsigned int old = *word;
    *word = value;
    phy_exit_critical(irq);
    return old;
}

unsigned int __atomic_fetch_add_4(volatile void *ptr, unsigned int value, int order) {
    (void)order;
    uint32_t irq = phy_enter_critical();
    volatile unsigned int *word = ptr;
    unsigned int old = *word;
    *word = old + value;
    phy_exit_critical(irq);
    return old;
}

unsigned int __atomic_fetch_sub_4(volatile void *ptr, unsigned int value, int order) {
    return __atomic_fetch_add_4(ptr, 0u - value, order);
}

struct _reent *__getreent(void) {
    static struct _reent reent = _REENT_INIT(reent);
    return &reent;
}

int _gettimeofday(struct timeval *tv, void *zone) {
    (void)zone;
    if (!tv) return 0;
    uint64_t us = c3_tasks_now_us();
    tv->tv_sec = us / 1000000u;
    tv->tv_usec = us % 1000000u;
    return 0;
}

void vTaskDelay(uint32_t ticks) {
    if (!ticks) c3_task_yield();
    else c3_task_park(NULL, c3_tasks_now_us() + (uint64_t)ticks * 1000u);
}

int nanosleep(const struct timespec *request, struct timespec *remaining) {
    if (!request || request->tv_sec < 0 || request->tv_nsec < 0 ||
        request->tv_nsec >= 1000000000L) return -1;
    uint64_t now = c3_tasks_now_us();
    uint64_t fraction = ((uint64_t)request->tv_nsec + 999u) / 1000u;
    if ((uint64_t)request->tv_sec > (UINT64_MAX - now - fraction) / 1000000u) return -1;
    uint64_t deadline = now + (uint64_t)request->tv_sec * 1000000u + fraction;
    while (c3_tasks_now_us() < deadline) c3_task_park(NULL, deadline);
    if (remaining) *remaining = (struct timespec){0};
    return 0;
}

/* Archive allocation is confined to c3_radio_alloc. */
void *_sbrk(ptrdiff_t delta) {
    (void)delta;
    *__errno() = ENOMEM;
    return (void *)-1;
}
