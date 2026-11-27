#pragma once

#include <stddef.h>
#include <stdint.h>

enum { C3_HCI_ADV_STEPS = 4, C3_HCI_MAX_COMMAND = 36 };

/* UUID bytes are in canonical display order. A controller's H4 command
 * buffer needs to remain alive until VHCI reports it can accept more data. */
size_t c3_hci_adv_command(unsigned step, const uint8_t uuid[16],
                          uint8_t packet[C3_HCI_MAX_COMMAND]);

/* A matching successful Command Complete returns 1. Unrelated events
 * return zero. Matching controller failures return the negated status. */
int c3_hci_adv_complete(unsigned step, const uint8_t *packet, size_t length);
