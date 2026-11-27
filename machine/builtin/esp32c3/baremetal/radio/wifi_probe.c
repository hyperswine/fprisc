#include "wifi_probe.h"
#include "task.h"

#include <stdbool.h>

enum { WIFI_IF_STA = 0, ESP_ERR_NO_MEM = 0x101, QUEUE_CAPACITY = 4 };
typedef int (*wifi_rx_callback)(void *frame, uint16_t bytes, void *owner);

extern int esp_wifi_internal_reg_rxcb(unsigned interface, wifi_rx_callback callback);
extern void esp_wifi_internal_free_rx_buffer(void *owner);
extern int esp_wifi_internal_tx(unsigned interface, void *frame, uint16_t bytes);

static struct packet {
    const uint8_t *bytes;
    void *owner;
    uint16_t length;
} packets[QUEUE_CAPACITY];
static unsigned head, count;
static struct c3_probe_address local;
static struct c3_probe_stats stats;
static bool running;
static uint8_t response[C3_ETH_FRAME_MAX];

static int receive(void *frame, uint16_t length, void *owner) {
    ++stats.received;
    if (!running || !frame || length > C3_ETH_FRAME_MAX || count == QUEUE_CAPACITY) {
        ++stats.dropped;
        if (owner) esp_wifi_internal_free_rx_buffer(owner);
        return ESP_ERR_NO_MEM;
    }
    unsigned tail = (head + count++) % QUEUE_CAPACITY;
    packets[tail] = (struct packet){frame, owner, length};
    c3_tasks_wake(packets);
    return 0;
}

static struct packet pop(void) {
    struct packet packet = packets[head];
    head = (head + 1) % QUEUE_CAPACITY;
    --count;
    return packet;
}

int c3_wifi_probe_start(const struct c3_probe_address *address) {
    if (!address || running) return -1;
    local = *address;
    stats = (struct c3_probe_stats){0};
    running = true;
    int rc = esp_wifi_internal_reg_rxcb(WIFI_IF_STA, receive);
    if (rc) running = false;
    return rc;
}

int c3_wifi_probe_stop(void) {
    if (!running) return 0;
    int rc = esp_wifi_internal_reg_rxcb(WIFI_IF_STA, NULL);
    if (rc) return rc;
    running = false;
    while (count) {
        struct packet packet = pop();
        if (packet.owner) esp_wifi_internal_free_rx_buffer(packet.owner);
    }
    return 0;
}

void c3_wifi_probe_poll(uint64_t deadline_us) {
    if (!running) return;
    while (!count && c3_tasks_now_us() < deadline_us) c3_task_park(packets, deadline_us);
    if (!count) return;
    struct packet packet = pop();
    size_t size = c3_probe_reply(&local, packet.bytes, packet.length, response, sizeof(response));
    if (packet.owner) esp_wifi_internal_free_rx_buffer(packet.owner);
    if (!size) return;
    if (esp_wifi_internal_tx(WIFI_IF_STA, response, size)) ++stats.tx_errors;
    else ++stats.replies;
}

struct c3_probe_stats c3_wifi_probe_stats(void) {
    return stats;
}
