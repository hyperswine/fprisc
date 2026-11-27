#pragma once

#include "btdm_abi.h"

/* BLE-only bring-up. RF calibration data is held in SRAM. */
int c3_ble_power_up(void);
int c3_ble_calibrate(void);
void c3_ble_install_platform(struct c3_btdm_osi *table);
