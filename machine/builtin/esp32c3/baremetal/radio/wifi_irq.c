#include "wifi_irq.h"
#include "btdm_services.h"
#include "../interrupt.h"

enum { WIFI_MAC = 0, WIFI_POWER = 2, DEFAULT_DRIVER_LINE = 1 };

static struct wifi_route {
    unsigned source, driver_line;
    bool bound;
} routes[] = {
    {.source = WIFI_MAC, .driver_line = DEFAULT_DRIVER_LINE},
    {.source = WIFI_POWER, .driver_line = DEFAULT_DRIVER_LINE},
};
static c3_irq_handler handler;
static void *handler_arg;

static struct wifi_route *route_for(uint32_t source) {
    for (unsigned i = 0; i < sizeof(routes) / sizeof(routes[0]); ++i)
        if (routes[i].source == source) return &routes[i];
    return NULL;
}

static void dispatch(const void *ignored) {
    (void)ignored;
    c3_btdm_isr_enter();
    handler(handler_arg);
    c3_btdm_isr_leave();
}

static void bind(struct wifi_route *route) {
    if (!route->bound) {
        if (!c3_irq_bind(route->source, dispatch, NULL)) __builtin_trap();
        route->bound = true;
    }
    c3_irq_enable(route->source, true);
}

static void unbind(struct wifi_route *route) {
    if (route->bound) {
        c3_irq_unbind(route->source);
        route->bound = false;
    }
}

static void set_intr(int32_t cpu, uint32_t source, uint32_t line, int32_t priority) {
    struct wifi_route *route = route_for(source);
    if (!route || cpu != 0 || line >= 32 || priority != 1) __builtin_trap();
    route->driver_line = line;
    if (handler) bind(route);
}

static void clear_intr(uint32_t source, uint32_t line) {
    struct wifi_route *route = route_for(source);
    if (route && route->driver_line == line) unbind(route);
}

static void set_isr(int32_t line, void *function, void *arg) {
    if (line != 0 && line != DEFAULT_DRIVER_LINE) __builtin_trap();
    handler = (c3_irq_handler)function;
    handler_arg = arg;
    for (unsigned i = 0; i < sizeof(routes) / sizeof(routes[0]); ++i) {
        if (handler) bind(&routes[i]);
        else unbind(&routes[i]);
    }
}

static void enable_mask(uint32_t mask, bool enabled) {
    for (unsigned i = 0; i < sizeof(routes) / sizeof(routes[0]); ++i) {
        struct wifi_route *route = &routes[i];
        if (route->bound && (mask & (UINT32_C(1) << route->driver_line)))
            c3_irq_enable(route->source, enabled);
    }
}

static void enable(uint32_t mask) { enable_mask(mask, true); }
static void disable(uint32_t mask) { enable_mask(mask, false); }

void c3_wifi_install_interrupts(wifi_osi_funcs_t *table) {
    table->_set_intr = set_intr;
    table->_clear_intr = clear_intr;
    table->_set_isr = set_isr;
    table->_ints_on = enable;
    table->_ints_off = disable;
}
