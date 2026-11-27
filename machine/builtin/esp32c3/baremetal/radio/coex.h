#pragma once

#include "btdm_abi.h"
#include "wifi_config.h"

int c3_coex_prepare(void);
void c3_coex_install_wifi(wifi_osi_funcs_t *table);
void c3_coex_install_ble(struct c3_btdm_osi *table);
int coex_init(void);
int coex_enable(void);
void coex_update_lpclk_interval(void);
