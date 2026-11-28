#include "wifi_services.h"
#include "alloc.h"
#include "btdm_services.h"
#include "event_group.h"
#include "os_timer.h"

enum { WIFI_TIMER_PRIORITY = 24, WIFI_MAX_PRIORITY = 25 };
static struct c3_btdm_osi shared;
static void *thread_semaphores[C3_TASK_LIMIT];

static void *thread_semaphore(void) {
    if (shared.is_in_isr()) return NULL;
    unsigned slot = c3_task_current() - 1;
    if (!thread_semaphores[slot]) thread_semaphores[slot] = shared.semphr_create(1, 0);
    return thread_semaphores[slot];
}

static void cleanup_task(c3_task_id task) {
    c3_events_cancel(task);
    void **sem = &thread_semaphores[task - 1];
    if (*sem) {
        shared.semphr_delete(*sem);
        *sem = NULL;
    }
}

static int32_t create_task(void *entry, const char *name, uint32_t bytes,
                           void *arg, uint32_t priority, void *handle) {
    return shared.task_create(entry, name, bytes, arg, priority, handle, 0);
}

static void delay(uint32_t ticks) {
    if (shared.is_in_isr()) return;
    if (!ticks) {
        c3_task_yield();
        return;
    }
    c3_task_park(NULL, c3_tasks_now_us() + (uint64_t)ticks * 1000u);
}

static int32_t ms_to_tick(uint32_t ms) {
    return ms <= INT32_MAX ? (int32_t)ms : INT32_MAX;
}

static int32_t max_priority(void) { return WIFI_MAX_PRIORITY; }
static bool is_from_isr(void) { return shared.is_in_isr() != 0; }
static int64_t time_us(void) { return (int64_t)c3_tasks_now_us(); }

static void *mutex_create(void) { return (void *)shared.mutex_create(); }
static void mutex_delete(void *handle) { shared.mutex_delete(handle); }
static int32_t mutex_lock(void *handle) { return shared.mutex_lock(handle); }
static int32_t mutex_unlock(void *handle) { return shared.mutex_unlock(handle); }

static uint32_t free_heap(void) { return c3_radio_available(); }
static void *allocate_zero(size_t bytes) { return c3_radio_calloc(1, bytes); }

static void *create_static_queue(int count, int bytes) {
    if (count <= 0 || bytes <= 0) return NULL;
    void **slot = c3_radio_alloc(sizeof(*slot));
    if (!slot) return NULL;
    *slot = shared.queue_create(count, bytes);
    if (!*slot) {
        c3_radio_free(slot);
        return NULL;
    }
    return slot;
}

static void delete_static_queue(void *handle) {
    if (!handle) return;
    void **slot = handle;
    shared.queue_delete(*slot);
    c3_radio_free(slot);
}

bool c3_wifi_install_services(wifi_osi_funcs_t *table) {
    c3_btdm_install_services(&shared, 1);
    if (!c3_timers_start(WIFI_TIMER_PRIORITY)) return false;
    c3_services_set_task_cleanup(cleanup_task);
    table->_version = ESP_WIFI_OS_ADAPTER_VERSION;
    table->_magic = ESP_WIFI_OS_ADAPTER_MAGIC;
    table->_is_from_isr = is_from_isr;
    table->_task_yield_from_isr = shared.task_yield_from_isr;
    table->_semphr_create = shared.semphr_create;
    table->_semphr_delete = shared.semphr_delete;
    table->_semphr_take = shared.semphr_take;
    table->_semphr_give = shared.semphr_give;
    table->_wifi_thread_semphr_get = thread_semaphore;
    table->_mutex_create = mutex_create;
    table->_recursive_mutex_create = mutex_create;
    table->_mutex_delete = mutex_delete;
    table->_mutex_lock = mutex_lock;
    table->_mutex_unlock = mutex_unlock;
    table->_queue_create = shared.queue_create;
    table->_queue_delete = shared.queue_delete;
    table->_queue_send = shared.queue_send;
    table->_queue_send_from_isr = shared.queue_send_from_isr;
    table->_queue_send_to_back = shared.queue_send;
    table->_queue_send_to_front = c3_services_queue_send_front;
    table->_queue_recv = shared.queue_recv;
    table->_queue_msg_waiting = c3_services_queue_waiting;
    table->_event_group_create = c3_events_create;
    table->_event_group_delete = c3_events_delete;
    table->_event_group_set_bits = c3_events_set;
    table->_event_group_clear_bits = c3_events_clear;
    table->_event_group_wait_bits = c3_events_wait;
    table->_task_create_pinned_to_core = shared.task_create;
    table->_task_create = create_task;
    table->_task_delete = shared.task_delete;
    table->_task_delay = delay;
    table->_task_ms_to_tick = ms_to_tick;
    table->_task_get_current_task = c3_services_current_task;
    table->_task_get_max_priority = max_priority;
    table->_malloc = c3_radio_alloc;
    table->_free = c3_radio_free;
    table->_get_free_heap_size = free_heap;
    table->_malloc_internal = c3_radio_alloc;
    table->_realloc_internal = c3_radio_realloc;
    table->_calloc_internal = c3_radio_calloc;
    table->_zalloc_internal = allocate_zero;
    table->_wifi_malloc = c3_radio_alloc;
    table->_wifi_realloc = c3_radio_realloc;
    table->_wifi_calloc = c3_radio_calloc;
    table->_wifi_zalloc = allocate_zero;
    table->_wifi_create_queue = create_static_queue;
    table->_wifi_delete_queue = delete_static_queue;
    table->_timer_arm = c3_timer_arm_ms;
    table->_timer_arm_us = c3_timer_arm_us;
    table->_timer_disarm = c3_timer_disarm;
    table->_timer_done = c3_timer_done;
    table->_timer_setfn = c3_timer_set_callback;
    table->_esp_timer_get_time = time_us;
    return true;
}
