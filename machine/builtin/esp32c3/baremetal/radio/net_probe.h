#pragma once

#include <stddef.h>
#include <stdint.h>

enum { C3_ETH_FRAME_MAX = 1514 };

struct c3_probe_address {
    uint8_t mac[6];
    uint8_t ipv4[4];
};

/* Handle an Ethernet II ARP request or IPv4 ICMP echo to this station.
 * Input and output are separate buffers. Neither includes an Ethernet FCS.
 * Return the number of bytes to send, or zero if the frame is ignored. */
size_t c3_probe_reply(const struct c3_probe_address *address,
                      const uint8_t *frame, size_t length,
                      uint8_t *reply, size_t capacity);
