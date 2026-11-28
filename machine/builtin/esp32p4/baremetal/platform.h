#pragma once

#include <stdbool.h>
#include <stdint.h>

void p4_clock_init(void);
uint64_t p4_clock_now_us(void);
void p4_clock_sleep_until(uint64_t deadline);
void p4_clock_wait_until(uint64_t deadline);
void p4_timer_irq(void);
void p4_gpio_irq(void);
bool p4_button_check(void);
void p4_irq_init(void);
bool p4_trap_check(void);
bool p4_clock_check(void);

static inline void p4_wait_interrupt(void) {
    /* With MIE masked, a pending local interrupt still wakes WFI. Open
       the interrupt window after WFI to dispatch it. */
    __asm__ volatile("wfi\ncsrsi mstatus, 8\ncsrci mstatus, 8" ::: "memory");
}

void p4_sdio_probe(void);
bool p4_sdio_start(void);
bool p4_sdio_ready(void);
void p4_sdio_reset_companion(void);
void p4_sdio_pulse_companion_en(void);
int p4_sdio_hci(unsigned step, const uint8_t *command, unsigned size);
