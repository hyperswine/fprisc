#include "task.h"
#include "btdm_services.h"
#include "os_queue.h"

#define FINISH (*(volatile uint32_t *)0x100000)
#define UART (*(volatile uint8_t *)0x10000000)
#define CHECK(condition) do { if (!(condition)) fail(__LINE__); } while (0)

static uint8_t stacks[C3_TASK_LIMIT][1024] __attribute__((aligned(16)));
static uint64_t now;
static unsigned order;
static unsigned channel;

static _Noreturn void fail(unsigned line) {
    FINISH = (line << 16) | 0x3333u;
    for (;;) {}
}

uint64_t c3_tasks_now_us(void) { return now; }

void c3_tasks_idle_until(uint64_t deadline) {
    if (deadline == C3_WAIT_FOREVER) {
        c3_tasks_wake(&channel);
    } else {
        CHECK(deadline > now);
        now = deadline;
    }
}

static void reader(void *arg) {
    CHECK(arg == &channel && c3_task_current() == 2 && order++ == 0);
    c3_task_park(&channel, 30);
    CHECK(now == 0 && order++ == 2);
    c3_task_park(&channel, 45);
    CHECK(now == 45 && order++ == 4);
}

static void writer(void *arg) {
    (void)arg;
    CHECK(c3_task_current() == 3 && order++ == 1);
    CHECK(c3_tasks_wake(&channel));
    c3_task_yield();
    CHECK(order++ == 3);
}

static void forever_reader(void *arg) {
    (void)arg;
    c3_task_park(&channel, C3_WAIT_FOREVER);
    CHECK(now == 60);
    c3_tasks_wake(&now);
}

static c3_os_queue queue;
static c3_os_semaphore sem;
static uint32_t buffer[2];

static void consumer(void *arg) {
    (void)arg;
    uint32_t value;
    CHECK(c3_queue_receive(&queue, &value, C3_WAIT_FOREVER) && value == 47);
    CHECK(c3_queue_receive(&queue, &value, C3_WAIT_FOREVER) && value == 48);
    CHECK(c3_semaphore_give(&sem, NULL));
}

static void queue_vectors(void) {
    uint32_t first = 47, second = 48, value;
    bool higher = false;
    CHECK(!c3_queue_init(&queue, buffer, sizeof(buffer), 3, sizeof(buffer[0])));
    CHECK(c3_queue_init(&queue, buffer, sizeof(buffer), 2, sizeof(buffer[0])));
    CHECK(c3_semaphore_init(&sem, 2, 0));
    CHECK(!c3_queue_try_receive(&queue, &value, NULL));
    CHECK(c3_task_create(consumer, NULL, 3, stacks[0], sizeof(stacks[0])) == 2);
    c3_task_yield();
    CHECK(c3_queue_try_send(&queue, &first, &higher) && higher);
    CHECK(c3_queue_send(&queue, &second, now));
    CHECK(!c3_queue_send(&queue, &first, now));
    CHECK(c3_semaphore_take(&sem, C3_WAIT_FOREVER));
    CHECK(c3_queue_send(&queue, &first, now));
    CHECK(c3_queue_try_receive(&queue, &value, NULL) && value == first);
    CHECK(!c3_queue_receive(&queue, &value, now + 3));
    CHECK(!c3_semaphore_take(&sem, now + 2));
    CHECK(c3_semaphore_give(&sem, NULL));
    CHECK(c3_semaphore_give(&sem, NULL));
    CHECK(!c3_semaphore_give(&sem, NULL));
}

static struct c3_btdm_osi osi;

static void blocked_controller(void *sem) {
    CHECK(osi.semphr_take(sem, UINT32_MAX));
    fail(__LINE__);
}

static void callback_vectors(void) {
    c3_btdm_install_services(&osi, 1);
    CHECK(osi.magic == C3_BTDM_OSI_MAGIC && osi.version == C3_BTDM_OSI_VERSION);
    CHECK(osi.get_time_us() == now);
    void *sem = osi.semphr_create(1, 0);
    CHECK(sem && !osi.semphr_take(sem, 0));
    uint64_t start = now;
    CHECK(!osi.semphr_take(sem, 2) && now == start + 2000);
    void *task = NULL;
    CHECK(osi.task_create((void *)blocked_controller, "probe", 1024, sem, 3, &task, 0));
    osi.task_yield();
    c3_btdm_isr_enter();
    CHECK(osi.is_in_isr() && !osi.semphr_take(sem, 0));
    bool higher = false;
    CHECK(osi.semphr_give_from_isr(sem, &higher) && higher);
    c3_btdm_isr_leave();
    CHECK(!osi.is_in_isr());
    osi.task_delete(task);
    osi.semphr_delete(sem);
    CHECK(osi.semphr_create(1, 0) == sem);

    const void *mutex = osi.mutex_create();
    CHECK(mutex && osi.mutex_lock(mutex) && osi.mutex_lock(mutex));
    CHECK(osi.mutex_unlock(mutex) && osi.mutex_unlock(mutex));
    CHECK(!osi.mutex_unlock(mutex));
    osi.mutex_delete(mutex);
    CHECK(osi.mutex_create() == mutex);
    void *queue_slot = osi.queue_create(2, sizeof(unsigned));
    CHECK(queue_slot);
    unsigned sent = 42, received = 0;
    CHECK(osi.queue_send(queue_slot, &sent, 0));
    CHECK(osi.queue_recv_from_isr(queue_slot, &received, NULL) && received == sent);
    osi.queue_delete(queue_slot);
}

void main(void) {
    c3_tasks_init(1);
    CHECK(c3_task_create(reader, &channel, 3, stacks[0], sizeof(stacks[0])) == 2);
    CHECK(c3_task_create(writer, NULL, 2, stacks[1], sizeof(stacks[1])) == 3);
    c3_task_yield();
    CHECK(order == 4);
    c3_task_park(&now, 60);
    CHECK(order == 5 && now == 60);
    CHECK(c3_task_create(forever_reader, NULL, 4, stacks[0], sizeof(stacks[0])) == 2);
    c3_task_park(&now, C3_WAIT_FOREVER);
    CHECK(c3_task_current() == 1);
    queue_vectors();
    CHECK(c3_task_create(NULL, NULL, 1, stacks[0], sizeof(stacks[0])) == 0);
    CHECK(c3_task_create(writer, NULL, 1, stacks[0], 16) == 0);
    for (unsigned i = 1; i < C3_TASK_LIMIT; ++i)
        CHECK(c3_task_create(writer, NULL, 1, stacks[i], sizeof(stacks[i])) == i+1);
    CHECK(c3_task_create(writer, NULL, 1, stacks[0], sizeof(stacks[0])) == 0);
    CHECK(c3_task_delete(2));
    CHECK(!c3_task_delete(2) && !c3_task_delete(1));
    CHECK(c3_task_create(writer, NULL, 1, stacks[0], sizeof(stacks[0])) == 2);
    callback_vectors();
    for (const char *s = "RV32 task services PASS\n"; *s; ++s) UART = (uint8_t)*s;
    FINISH = 0x5555;
    for (;;) {}
}
