#pragma once

#include "btdm_abi.h"
#include "task.h"

/* Start the task services and add their entries to the caller's BTDM table.
 * Hardware, allocation, PHY, coexistence and critical-section entries are
 * supplied by the platform adapter before controller registration. */
void c3_btdm_install_services(struct c3_btdm_osi *table, unsigned main_priority);
void c3_btdm_isr_enter(void);
void c3_btdm_isr_leave(void);

void c3_services_set_task_cleanup(void (*cleanup)(c3_task_id));
void *c3_services_current_task(void);
int32_t c3_services_queue_send_front(void *handle, void *item, uint32_t ticks);
uint32_t c3_services_queue_waiting(void *handle);
