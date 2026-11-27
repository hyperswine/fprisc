#pragma once

#include "task.h"

bool c3_timers_start(unsigned priority);
void c3_timer_set_callback(void *handle, void *function, void *arg);
void c3_timer_arm_ms(void *handle, uint32_t ms, bool repeat);
void c3_timer_arm_us(void *handle, uint32_t us, bool repeat);
void c3_timer_disarm(void *handle);
void c3_timer_done(void *handle);
