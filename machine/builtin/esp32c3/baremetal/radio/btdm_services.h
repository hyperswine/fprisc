#pragma once

#include "btdm_abi.h"

/* Start the task services and add their entries to the caller's BTDM table.
 * Hardware, allocation, PHY, coexistence and critical-section entries are
 * supplied by the platform adapter before controller registration. */
void c3_btdm_install_services(struct c3_btdm_osi *table, unsigned main_priority);
void c3_btdm_isr_enter(void);
void c3_btdm_isr_leave(void);
