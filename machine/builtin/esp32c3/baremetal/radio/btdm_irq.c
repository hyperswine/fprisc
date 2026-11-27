#include "btdm_irq.h"
#include "btdm_services.h"
#include "../interrupt.h"

#include <errno.h>

enum { BT_BB = 5, RWBT = 7, RWBLE = 8 };
static struct controller_irq {
    c3_btdm_isr handler;
    const void *arg;
    unsigned source;
} irqs[] = {{.source = BT_BB}, {.source = RWBLE}};

static struct controller_irq *find_irq(int32_t source) {
    for (unsigned i = 0; i < sizeof(irqs) / sizeof(irqs[0]); ++i)
        if ((int32_t)irqs[i].source == source) return &irqs[i];
    return NULL;
}

static void dispatch(const void *arg) {
    const struct controller_irq *irq = arg;
    c3_btdm_isr_enter();
    irq->handler(irq->arg);
    c3_btdm_isr_leave();
}

static int32_t set_enabled(int32_t source, bool enabled) {
    struct controller_irq *irq = find_irq(source);
    if (!irq || !irq->handler) return -EINVAL;
    if (!c3_irq_enable(irq->source, enabled)) return -EINVAL;
    if (irq->source == BT_BB && !c3_irq_enable(RWBT, enabled)) return -EINVAL;
    return 0;
}

static int32_t install(int32_t cpu, int32_t source, c3_btdm_isr handler,
                       const void *arg, const void **handle) {
    struct controller_irq *irq = find_irq(source);
    if (cpu != 0 || !irq || !handler || irq->handler) return -EINVAL;
    if (!c3_irq_bind(irq->source, dispatch, irq)) return -EBUSY;
    if (irq->source == BT_BB && !c3_irq_bind(RWBT, dispatch, irq)) {
        c3_irq_unbind(BT_BB);
        return -EBUSY;
    }
    irq->arg = arg;
    irq->handler = handler;
    int32_t rc = set_enabled(source, true);
    if (!rc && handle) *handle = irq;
    return rc;
}

static int32_t release(const void *handle) {
    for (unsigned i = 0; i < sizeof(irqs) / sizeof(irqs[0]); ++i) {
        struct controller_irq *irq = &irqs[i];
        if (handle != irq || !irq->handler) continue;
        c3_irq_unbind(irq->source);
        if (irq->source == BT_BB) c3_irq_unbind(RWBT);
        irq->handler = NULL;
        return 0;
    }
    return -EINVAL;
}

static void replace(int32_t source, c3_btdm_isr handler, const void *arg) {
    struct controller_irq *irq = find_irq(source);
    if (!irq || !handler) __builtin_trap();
    if (!irq->handler) {
        if (install(0, source, handler, arg, NULL)) __builtin_trap();
        return;
    }
    irq->arg = arg;
    irq->handler = handler;
}

static int32_t enable(int32_t source) { return set_enabled(source, true); }
static int32_t disable(int32_t source) { return set_enabled(source, false); }

void c3_btdm_install_interrupts(struct c3_btdm_osi *table) {
    table->interrupt_alloc = install;
    table->interrupt_free = release;
    table->interrupt_handler_set = replace;
    table->interrupt_on = enable;
    table->interrupt_off = disable;
}
