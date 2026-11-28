#pragma once

#include "wifi_config.h"

/* Install task and timer callbacks from an initialized shared service layer. */
bool c3_wifi_install_services(wifi_osi_funcs_t *table);
