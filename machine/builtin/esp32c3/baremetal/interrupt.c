#include <stdint.h>
#include <stddef.h>
#include "interrupt.h"

#ifndef C3_INTERRUPT_MATRIX
#define C3_INTERRUPT_MATRIX 0x600c2000u
#endif
#define MATRIX(offset) (*(volatile uint32_t *)(uintptr_t)(C3_INTERRUPT_MATRIX + (offset)))
enum {
    GPIO_MAP = 0x040, TIMER_MAP = 0x094, CPU_ENABLE = 0x104, CPU_TYPE = 0x108,
    CPU_PRIORITY0 = 0x114, CPU_THRESHOLD = 0x194,
    TIMER_LINE = 1, GPIO_LINE = 2, RADIO_LINE_BASE = 3,
    WIFI_MAC = 0, WIFI_POWER = 2, WIFI_BB = 3,
    BT_BB = 5, RWBT = 7, RWBLE = 8
};

static struct radio_irq {
    unsigned source;
    c3_irq_handler handler;
    const void *arg;
} radio_irqs[] = {
    {.source = WIFI_MAC}, {.source = WIFI_POWER}, {.source = WIFI_BB},
    {.source = BT_BB}, {.source = RWBT}, {.source = RWBLE},
};
enum { RADIO_LINES = sizeof(radio_irqs) / sizeof(radio_irqs[0]) };

static unsigned find_source(unsigned source) {
    for (unsigned i = 0; i < RADIO_LINES; ++i)
        if (radio_irqs[i].source == source) return i;
    return RADIO_LINES;
}

bool c3_irq_bind(unsigned source, c3_irq_handler handler, const void *arg) {
    unsigned index = find_source(source);
    if (index == RADIO_LINES || !handler || radio_irqs[index].handler) return false;
    unsigned line = RADIO_LINE_BASE + index;
    MATRIX(CPU_TYPE) &= ~(1u << line);
    MATRIX(CPU_PRIORITY0 + line * 4) = 1;
    radio_irqs[index].arg = arg;
    radio_irqs[index].handler = handler;
    MATRIX(source * 4) = line;
    return true;
}

bool c3_irq_enable(unsigned source, bool enabled) {
    unsigned index = find_source(source);
    if (index == RADIO_LINES || !radio_irqs[index].handler) return false;
    uint32_t mask = 1u << (RADIO_LINE_BASE + index);
    if (enabled) MATRIX(CPU_ENABLE) |= mask;
    else MATRIX(CPU_ENABLE) &= ~mask;
    return true;
}

bool c3_irq_unbind(unsigned source) {
    if (!c3_irq_enable(source, false)) return false;
    MATRIX(source * 4) = 0;
    radio_irqs[find_source(source)].handler = NULL;
    return true;
}

void c3_irq_init(void) {
    MATRIX(CPU_ENABLE) = 0;
    c3_timer_ack();
    for (unsigned i = 0; i < RADIO_LINES; ++i) MATRIX(radio_irqs[i].source * 4) = 0;
    MATRIX(TIMER_MAP) = TIMER_LINE;
    MATRIX(GPIO_MAP) = GPIO_LINE;
    MATRIX(CPU_TYPE) &= ~((1u << TIMER_LINE) | (1u << GPIO_LINE));
    MATRIX(CPU_PRIORITY0 + TIMER_LINE * 4) = 1;
    MATRIX(CPU_PRIORITY0 + GPIO_LINE * 4) = 1;
    MATRIX(CPU_THRESHOLD) = 1;
    MATRIX(CPU_ENABLE) = (1u << TIMER_LINE) | (1u << GPIO_LINE);
}

_Noreturn void c3_fatal_trap(uint32_t cause, uint32_t pc);

bool c3_irq_dispatch(unsigned line) {
    if (line == TIMER_LINE) {
        c3_timer_ack();
        return true;
    }
    if (line == GPIO_LINE) {
        c3_gpio_irq();
        return true;
    }
    unsigned index = line - RADIO_LINE_BASE;
    if (index >= RADIO_LINES || !radio_irqs[index].handler) return false;
    radio_irqs[index].handler(radio_irqs[index].arg);
    return true;
}

__attribute__((interrupt("machine"))) void c3_trap(void) {
    uint32_t cause, pc;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    uint32_t irq = UINT32_C(0x80000000);
    if ((cause & irq) && c3_irq_dispatch(cause & ~irq)) return;
    __asm__ volatile("csrr %0, mepc" : "=r"(pc));
    c3_fatal_trap(cause, pc);
}
