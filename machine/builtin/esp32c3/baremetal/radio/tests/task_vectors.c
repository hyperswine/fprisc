#include "task.h"
#include "btdm_abi.h"
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
    for (const char *s = "RV32 task services PASS\n"; *s; ++s) UART = (uint8_t)*s;
    FINISH = 0x5555;
    for (;;) {}
}
