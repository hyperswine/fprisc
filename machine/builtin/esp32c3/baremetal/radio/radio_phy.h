#pragma once

#include <stdbool.h>
#include <stdint.h>

int c3_radio_phy_acquire(void);
void c3_radio_phy_release(void);
int c3_radio_read_mac(uint8_t *mac, unsigned offset);
uint32_t c3_radio_random(void);
uint32_t phy_enter_critical(void);
void phy_exit_critical(uint32_t state);
