#include "station_config.h"

#include <errno.h>

enum { WIFI_AUTH_OPEN = 0, WIFI_AUTH_WPA2_PSK = 3 };

void c3_station_clear_password(wifi_config_t *config) {
    volatile uint8_t *password = config->sta.password;
    for (size_t i = 0; i < sizeof(config->sta.password); ++i) password[i] = 0;
}

static int octet(c3_station_read_byte read_byte, void *context) {
    int value = read_byte(context);
    return value >= 0 && value <= 255 ? value : -EIO;
}

int c3_station_read_config(c3_station_read_byte read_byte, void *context,
                           struct c3_probe_address *address, wifi_config_t *config) {
    *config = (wifi_config_t){0};
    int ssid = octet(read_byte, context);
    int password = octet(read_byte, context);
    if (ssid < 0 || password < 0) return -EIO;
    if (ssid == 0 || (size_t)ssid > sizeof(config->sta.ssid) ||
        (password && (password < 8 || (size_t)password >= sizeof(config->sta.password))))
        return -EINVAL;

    uint8_t ip[4];
    for (size_t i = 0; i < sizeof(ip); ++i) {
        int byte = octet(read_byte, context);
        if (byte < 0) return byte;
        ip[i] = byte;
    }
    if (ip[0] == 0 || ip[0] == 127 || ip[0] >= 224) return -EINVAL;

    for (int i = 0; i < ssid; ++i) {
        int byte = octet(read_byte, context);
        if (byte <= 0) return byte ? byte : -EINVAL;
        config->sta.ssid[i] = byte;
    }
    for (int i = 0; i < password; ++i) {
        int byte = octet(read_byte, context);
        if (byte < 32 || byte > 126) {
            c3_station_clear_password(config);
            return byte < 0 ? byte : -EINVAL;
        }
        config->sta.password[i] = byte;
    }
    for (size_t i = 0; i < sizeof(ip); ++i) address->ipv4[i] = ip[i];
    config->sta.threshold.authmode = password ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    config->sta.pmf_cfg.capable = true;
    return 0;
}
