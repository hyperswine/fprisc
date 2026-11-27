#include "wifi_probe.h"
#include "task.h"
#include <assert.h>
#include <stdbool.h>
#include <string.h>

#include "net_fixtures.h"

static const struct c3_probe_address local = {{2, 0, 0, 0, 0, 1}, {192, 0, 2, 10}};
static unsigned released, transmitted;
static bool fail_tx;
static int (*rx)(void *, uint16_t, void *);

int esp_wifi_internal_reg_rxcb(unsigned interface, int (*callback)(void *, uint16_t, void *)) {
    assert(interface == 0);
    rx = callback;
    return 0;
}
void esp_wifi_internal_free_rx_buffer(void *owner) {
    assert(owner);
    ++released;
}
int esp_wifi_internal_tx(unsigned interface, void *frame, uint16_t length) {
    assert(interface == 0 && length == sizeof(ping_response));
    assert(memcmp(frame, ping_response, length) == 0);
    ++transmitted;
    return fail_tx ? -1 : 0;
}
uint64_t c3_tasks_now_us(void) { return 0; }
void c3_task_park(const void *channel, uint64_t deadline) {
    (void)channel;
    (void)deadline;
    assert(false);
}
bool c3_tasks_wake(const void *channel) { return channel != NULL; }

static void packet_vectors(void) {
    uint8_t result[C3_ETH_FRAME_MAX];
    assert(c3_probe_reply(&local, arp_request, sizeof(arp_request), result, sizeof(result))
           == sizeof(arp_response));
    assert(memcmp(result, arp_response, sizeof(arp_response)) == 0);
    assert(c3_probe_reply(&local, ping_request, sizeof(ping_request), result, sizeof(result))
           == sizeof(ping_response));
    assert(memcmp(result, ping_response, sizeof(ping_response)) == 0);

    for (size_t i = 0; i < sizeof(ping_request); ++i)
        assert(!c3_probe_reply(&local, ping_request, i, result, sizeof(result)));
    for (size_t i = 0; i < sizeof(arp_request); ++i)
        assert(!c3_probe_reply(&local, arp_request, i, result, sizeof(result)));
    assert(!c3_probe_reply(&local, ping_request, sizeof(ping_request), result, 42));
    uint8_t bad[sizeof(ping_request)];
    memcpy(bad, ping_request, sizeof(bad));
    bad[sizeof(bad) - 1] ^= 1;
    assert(!c3_probe_reply(&local, bad, sizeof(bad), result, sizeof(result)));
    memcpy(bad, ping_request, sizeof(bad));
    bad[24] ^= 1;
    assert(!c3_probe_reply(&local, bad, sizeof(bad), result, sizeof(result)));
}

static void ownership_vectors(void) {
    uint8_t frame[sizeof(ping_request)];
    memcpy(frame, ping_request, sizeof(frame));
    assert(c3_wifi_probe_start(&local) == 0);
    assert(c3_wifi_probe_start(&local) < 0);
    for (unsigned i = 0; i < 4; ++i) assert(rx(frame, sizeof(frame), frame) == 0);
    assert(rx(frame, sizeof(frame), frame) != 0);
    assert(released == 1);
    c3_wifi_probe_poll(0);
    assert(released == 2 && transmitted == 1);
    fail_tx = true;
    c3_wifi_probe_poll(0);
    assert(released == 3 && transmitted == 2);
    struct c3_probe_stats stats = c3_wifi_probe_stats();
    assert(stats.received == 5 && stats.dropped == 1 && stats.replies == 1 && stats.tx_errors == 1 &&
           stats.echo_replies == 1);
    assert(c3_wifi_probe_stop() == 0 && !rx && released == 5);
    assert(c3_wifi_probe_stop() == 0 && released == 5);
}

int main(void) {
    packet_vectors();
    ownership_vectors();
}
