#include <stdint.h>
#include "interrupt.h"

#define MATRIX(offset) (*(volatile uint32_t *)(uintptr_t)(0x600c2000u + (offset)))
enum {
    GPIO_MAP = 0x040, TIMER_MAP = 0x094, CPU_ENABLE = 0x104, CPU_TYPE = 0x108,
    CPU_PRIORITY0 = 0x114, CPU_THRESHOLD = 0x194,
    TIMER_LINE = 1, GPIO_LINE = 2
};

void c3_irq_init(void) {
    MATRIX(CPU_ENABLE) = 0;
    c3_timer_ack();
    MATRIX(TIMER_MAP) = TIMER_LINE;
    MATRIX(GPIO_MAP) = GPIO_LINE;
    MATRIX(CPU_TYPE) &= ~((1u << TIMER_LINE) | (1u << GPIO_LINE));
    MATRIX(CPU_PRIORITY0 + TIMER_LINE * 4) = 1;
    MATRIX(CPU_PRIORITY0 + GPIO_LINE * 4) = 1;
    MATRIX(CPU_THRESHOLD) = 1;
    MATRIX(CPU_ENABLE) = (1u << TIMER_LINE) | (1u << GPIO_LINE);
}

_Noreturn void c3_fatal_trap(uint32_t cause, uint32_t pc);

__attribute__((interrupt("machine"))) void c3_trap(void) {
    uint32_t cause, pc;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if (cause == (UINT32_C(0x80000000) | TIMER_LINE)) {
        c3_timer_ack();
        return;
    }
    if (cause == (UINT32_C(0x80000000) | GPIO_LINE)) {
        c3_gpio_irq();
        return;
    }
    __asm__ volatile("csrr %0, mepc" : "=r"(pc));
    c3_fatal_trap(cause, pc);
}
