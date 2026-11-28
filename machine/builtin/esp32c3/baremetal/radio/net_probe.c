#include "net_probe.h"

#include <stdbool.h>
#include <string.h>

enum {
    ETHERNET = 14, ARP = 28, IP = 20, ICMP = 8,
    ARP_TYPE = 0x0806, IPV4_TYPE = 0x0800, ICMP_PROTOCOL = 1,
    ARP_REQUEST = 1, ARP_REPLY = 2, ECHO_REQUEST = 8, ECHO_REPLY = 0
};

static uint16_t read_be16(const uint8_t *p) {
    return ((uint16_t)p[0] << 8) | p[1];
}

static void write_be16(uint8_t *p, uint16_t word) {
    p[0] = (uint8_t)(word >> 8);
    p[1] = (uint8_t)word;
}

static uint16_t checksum(const uint8_t *p, size_t length) {
    uint32_t sum = 0;
    while (length >= 2) {
        sum += read_be16(p);
        p += 2;
        length -= 2;
    }
    if (length) sum += (uint16_t)*p << 8;
    while (sum > 0xffffu) sum = (sum & 0xffffu) + (sum >> 16);
    return (uint16_t)~sum;
}

static size_t arp_reply(const struct c3_probe_address *addr, const uint8_t *frame,
                        size_t length, uint8_t *reply, size_t capacity) {
    const uint8_t *a = frame + ETHERNET;
    if (length < ETHERNET + ARP || capacity < ETHERNET + ARP ||
        read_be16(a) != 1 || read_be16(a + 2) != IPV4_TYPE ||
        a[4] != 6 || a[5] != 4 || read_be16(a + 6) != ARP_REQUEST ||
        memcmp(a + 8, frame + 6, 6) || memcmp(a + 24, addr->ipv4, 4)) return 0;
    uint8_t *b = reply + ETHERNET;
    memcpy(b, a, 8);
    write_be16(b + 6, ARP_REPLY);
    memcpy(b + 8, addr->mac, 6);
    memcpy(b + 14, addr->ipv4, 4);
    memcpy(b + 18, a + 8, 10);
    return ETHERNET + ARP;
}

static size_t icmp_reply(const struct c3_probe_address *addr, const uint8_t *frame,
                         size_t length, uint8_t *reply, size_t capacity) {
    if (length < ETHERNET + IP + ICMP) return 0;
    const uint8_t *ip = frame + ETHERNET;
    const uint8_t *icmp = ip + IP;
    size_t total = read_be16(ip + 2);
    if (ip[0] != 0x45 || ip[8] == 0 || ip[9] != ICMP_PROTOCOL ||
        (read_be16(ip + 6) & 0xbfffu) ||
        total < IP + ICMP || total > length - ETHERNET || total + ETHERNET > capacity ||
        memcmp(ip + 16, addr->ipv4, 4) || ip[12] >= 224 || ip[12] == 0 ||
        icmp[0] != ECHO_REQUEST || icmp[1] != 0 ||
        checksum(ip, IP) || checksum(icmp, total - IP)) return 0;

    uint8_t *out = reply + ETHERNET;
    uint8_t *payload = out + IP;
    memcpy(out, ip, total);
    out[1] = 0;
    write_be16(out + 4, 0);
    write_be16(out + 6, 0x4000);
    out[8] = 64;
    memcpy(out + 12, addr->ipv4, 4);
    memcpy(out + 16, ip + 12, 4);
    write_be16(out + 10, 0);
    write_be16(out + 10, checksum(out, IP));
    payload[0] = ECHO_REPLY;
    write_be16(payload + 2, 0);
    write_be16(payload + 2, checksum(payload, total - IP));
    return total + ETHERNET;
}

size_t c3_probe_reply(const struct c3_probe_address *addr, const uint8_t *frame,
                      size_t length, uint8_t *reply, size_t capacity) {
    static const uint8_t broadcast[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    static const uint8_t zero[6];
    if (length < ETHERNET || length > C3_ETH_FRAME_MAX ||
        frame[6] & 1u || !memcmp(frame + 6, zero, 6)) return 0;
    bool directed = memcmp(frame, addr->mac, 6) == 0;
    uint16_t type = read_be16(frame + 12);
    size_t bytes;
    if (type == ARP_TYPE && (directed || !memcmp(frame, broadcast, 6))) {
        bytes = arp_reply(addr, frame, length, reply, capacity);
    } else if (type == IPV4_TYPE && directed) {
        bytes = icmp_reply(addr, frame, length, reply, capacity);
    } else {
        return 0;
    }
    if (!bytes) return 0;
    memcpy(reply, frame + 6, 6);
    memcpy(reply + 6, addr->mac, 6);
    write_be16(reply + 12, type);
    return bytes;
}
