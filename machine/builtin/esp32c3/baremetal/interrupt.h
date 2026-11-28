#pragma once

#include <stdbool.h>

void c3_irq_init(void);
void c3_timer_ack(void);
void c3_gpio_irq(void);

/* Configured with machine interrupts masked. Each source owns a separate
 * level-triggered CPU line. Handlers must acknowledge the peripheral. */
typedef void (*c3_irq_handler)(const void *);
bool c3_irq_bind(unsigned source, c3_irq_handler handler, const void *arg);
bool c3_irq_enable(unsigned source, bool enabled);
bool c3_irq_unbind(unsigned source);
bool c3_irq_dispatch(unsigned line);

/* Main runs with MIE clear. A pending local interrupt wakes WFI even
 * with MIE clear, so the condition check and idle have no lost-wakeup gap.
 * Open the interrupt window after WFI to dispatch and acknowledge it. */
static inline void c3_wait_interrupt(void) {
    __asm__ volatile("wfi\ncsrsi mstatus, 8\ncsrci mstatus, 8" ::: "memory");
}
