#pragma once

#include "net_probe.h"
#include "wifi_config.h"

/* Serial message: one-byte SSID length, one-byte passphrase length, four
 * IPv4 octets, then SSID and passphrase bytes. Inputs stay in SRAM. */
typedef int (*c3_station_read_byte)(void *context);
int c3_station_read_config(c3_station_read_byte read_byte, void *context,
                           struct c3_probe_address *address, wifi_config_t *config);
void c3_station_clear_password(wifi_config_t *config);
