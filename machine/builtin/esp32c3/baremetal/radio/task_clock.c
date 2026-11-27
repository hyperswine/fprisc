#include "../clock_hw.h"
#include "task.h"

uint64_t c3_tasks_now_us(void) {
    return c3_clock_now_us();
}

void c3_tasks_idle_until(uint64_t deadline_us) {
    c3_clock_wait_us(deadline_us);
}
