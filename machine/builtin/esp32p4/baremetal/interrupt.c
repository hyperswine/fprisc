#include "platform.h"

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))

enum {
    MATRIX = 0x500d6000, TIMER_MAP = MATRIX + 0xd4, GPIO_MAP = MATRIX + 0x128,
    CLIC = 0x20800000, CLIC_CONFIG = CLIC, CLIC_THRESHOLD = CLIC + 8,
    CLIC_LINES = CLIC + 0x1000, EXTERNAL_OFFSET = 16,
    TIMER_IRQ = EXTERNAL_OFFSET + 1, GPIO_IRQ = EXTERNAL_OFFSET + 2,
    CLIC_ENABLED = 1u << 8, CLIC_MACHINE = 3u << 22,
    CLIC_LEVEL_ONE = 1u << 29, MACHINE_ECALL = 11,
};

static volatile unsigned trap_check_state;
extern void p4_puts(const char *);
extern void p4_hex(uint32_t);

void p4_irq_init(void) {
    for (unsigned i = 0; i < EXTERNAL_OFFSET + 32; ++i)
        REG(CLIC_LINES + i * 4) &= ~CLIC_ENABLED;
    REG(CLIC_CONFIG) = 3u << 1;
    REG(CLIC_THRESHOLD) = 0;
    /* The P4 matrix register takes the CLIC interrupt ID (16 through 47). */
    REG(TIMER_MAP) = TIMER_IRQ;
    REG(GPIO_MAP) = GPIO_IRQ;
    REG(CLIC_LINES + TIMER_IRQ * 4) = CLIC_MACHINE | CLIC_LEVEL_ONE | CLIC_ENABLED;
    REG(CLIC_LINES + GPIO_IRQ * 4) = CLIC_MACHINE | CLIC_LEVEL_ONE | CLIC_ENABLED;
}

bool p4_trap_check(void) {
    trap_check_state = 1;
    __asm__ volatile("ecall" ::: "memory");
    return trap_check_state == 2;
}

__attribute__((aligned(64), interrupt("machine"))) void p4_trap(void) {
    uint32_t cause;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    unsigned code = cause & 0xfff;
    if ((cause & (1u << 31)) && code == TIMER_IRQ) {
        p4_timer_irq();
        return;
    }
    if ((cause & (1u << 31)) && code == GPIO_IRQ) {
        p4_gpio_irq();
        return;
    }
    uint32_t pc;
    __asm__ volatile("csrr %0, mepc" : "=r"(pc));
    if (!(cause & (1u << 31)) && code == MACHINE_ECALL && trap_check_state == 1) {
        trap_check_state = 2;
        __asm__ volatile("csrw mepc, %0" :: "r"(pc + 4));
        return;
    }
    p4_puts("P4 unexpected trap cause ");
    p4_hex(cause);
    p4_puts(" PC ");
    p4_hex(pc);
    p4_puts("\n");
    for (;;) __asm__ volatile("wfi");
}
