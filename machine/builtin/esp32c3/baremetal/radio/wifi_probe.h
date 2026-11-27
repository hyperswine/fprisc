#pragma once

#include "net_probe.h"

struct c3_probe_stats {
    uint32_t received, dropped, replies, tx_errors;
};

/* Register the responder after station setup. The same task owns start,
 * poll and stop. Polling and RX handoff use the masked-IRQ radio runtime. */
int c3_wifi_probe_start(const struct c3_probe_address *address);
int c3_wifi_probe_stop(void);
void c3_wifi_probe_poll(uint64_t deadline_us);
struct c3_probe_stats c3_wifi_probe_stats(void);
