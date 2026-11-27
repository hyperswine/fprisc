#pragma once

void c3_timer_ack(void);
void c3_gpio_irq(void);

/* Main runs with MIE clear. A pending local interrupt wakes WFI even
 * with MIE clear, so the condition check and idle have no lost-wakeup gap.
 * Open the interrupt window after WFI to dispatch and acknowledge it. */
static inline void c3_wait_interrupt(void) {
    __asm__ volatile("wfi\ncsrsi mstatus, 8\ncsrci mstatus, 8" ::: "memory");
}
