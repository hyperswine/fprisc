#include "task.h"
#include "btdm_services.h"
#include "event_group.h"
#include "btdm_irq.h"
#include "../../interrupt.h"
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
    CHECK(c3_queue_send(&queue, &second, now));
    CHECK(c3_queue_send_front(&queue, &first, now));
    CHECK(!c3_queue_send_front(&queue, &first, now));
    CHECK(c3_queue_try_receive(&queue, &value, NULL) && value == first);
    CHECK(c3_queue_try_receive(&queue, &value, NULL) && value == second);
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

#define IRQ_REG(offset) (*(volatile uint32_t *)(C3_INTERRUPT_MATRIX + (offset)))
static unsigned timer_hits, gpio_hits, radio_hits;
void c3_timer_ack(void) { ++timer_hits; }
void c3_gpio_irq(void) { ++gpio_hits; }
_Noreturn void c3_fatal_trap(uint32_t cause, uint32_t pc) {
    (void)cause;
    (void)pc;
    fail(__LINE__);
}

static void controller_irq(const void *arg) {
    CHECK(arg == &radio_hits && osi.is_in_isr());
    ++radio_hits;
}

static void interrupt_vectors(void) {
    c3_irq_init();
    CHECK(c3_irq_dispatch(1) && timer_hits == 2);
    CHECK(c3_irq_dispatch(2) && gpio_hits == 1);
    c3_btdm_install_interrupts(&osi);
    const void *handle = NULL;
    CHECK(osi.interrupt_alloc(1, 5, controller_irq, &radio_hits, NULL) != 0);
    CHECK(osi.interrupt_alloc(0, 5, controller_irq, &radio_hits, &handle) == 0 && handle);
    CHECK(osi.interrupt_alloc(0, 5, controller_irq, &radio_hits, NULL) != 0);
    unsigned bb = IRQ_REG(5 * 4), rwbt = IRQ_REG(7 * 4);
    CHECK(bb != rwbt && bb > 2 && rwbt > 2);
    CHECK(c3_irq_dispatch(bb) && c3_irq_dispatch(rwbt) && radio_hits == 2);
    CHECK(!osi.is_in_isr());
    uint32_t mask = (1u << bb) | (1u << rwbt);
    CHECK((IRQ_REG(0x104) & mask) == mask);
    CHECK(osi.interrupt_off(5) == 0 && !(IRQ_REG(0x104) & mask));
    CHECK(osi.interrupt_on(5) == 0 && (IRQ_REG(0x104) & mask) == mask);
    CHECK(osi.interrupt_free(handle) == 0 && !IRQ_REG(5 * 4) && !IRQ_REG(7 * 4));
    CHECK(!c3_irq_dispatch(bb) && !c3_irq_dispatch(rwbt));
    CHECK(osi.interrupt_free(handle) != 0);
    osi.interrupt_handler_set(8, controller_irq, &radio_hits);
    CHECK(c3_irq_dispatch(IRQ_REG(8 * 4)) && radio_hits == 3);
}

static unsigned notified;
static void event_waiter(void *arg) {
    CHECK(c3_events_wait(arg, 3, 1, 1, UINT32_MAX) == 7);
    ++notified;
}
static void event_deleted(void *arg) {
    CHECK(c3_events_wait(arg, 8, 0, 0, UINT32_MAX) == 0);
    ++notified;
}
static void event_vectors(void) {
    void *event = c3_events_create();
    CHECK(event);
    CHECK(c3_task_create(event_waiter, event, 3, stacks[0], sizeof(stacks[0])) == 2);
    CHECK(c3_task_create(event_waiter, event, 2, stacks[1], sizeof(stacks[1])) == 3);
    c3_task_yield();
    CHECK(c3_events_set(event, 1) == 1);
    c3_task_yield();
    CHECK(notified == 0);
    CHECK(c3_events_set(event, 6) == 4);
    c3_task_yield();
    CHECK(notified == 2);
    CHECK(c3_events_clear(event, 4) == 4 && c3_events_wait(event, 4, 0, 0, 0) == 0);
    uint64_t start = now;
    CHECK(c3_events_wait(event, 8, 0, 0, 2) == 0 && now == start + 2000);

    CHECK(c3_task_create(event_deleted, event, 3, stacks[0], sizeof(stacks[0])) == 2);
    c3_task_yield();
    c3_events_delete(event);
    CHECK(c3_events_create() == event);
    c3_task_yield();
    CHECK(notified == 3);

    CHECK(c3_task_create(event_waiter, event, 3, stacks[0], sizeof(stacks[0])) == 2);
    c3_task_yield();
    c3_events_cancel(2);
    CHECK(c3_task_delete(2));
    CHECK(c3_events_set(event, 3) == 3);
    c3_events_delete(event);
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
    c3_tasks_init(1);
    event_vectors();
    callback_vectors();
    interrupt_vectors();
    for (const char *s = "RV32 task services PASS\n"; *s; ++s) UART = (uint8_t)*s;
    FINISH = 0x5555;
    for (;;) {}
}
