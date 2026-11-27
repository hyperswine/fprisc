#include "station_config.h"
#include <assert.h>
#include <string.h>

struct reader {
    const uint8_t *input;
    size_t length, offset;
};

static int read_byte(void *context) {
    struct reader *r = context;
    return r->offset == r->length ? -1 : r->input[r->offset++];
}

int main(void) {
    uint8_t frame[] = {3, 8, 192, 0, 2, 10, 'l', 'a', 'b',
                       'd', 'e', 'm', 'o', 'p', 'a', 's', 's'};
    struct reader reader = {frame, sizeof(frame), 0};
    struct c3_probe_address address = {{0}, {0}};
    wifi_config_t config;
    assert(c3_station_read_config(read_byte, &reader, &address, &config) == 0);
    assert(!memcmp(address.ipv4, frame + 2, 4));
    assert(!memcmp(config.sta.ssid, "lab", 4));
    assert(!memcmp(config.sta.password, "demopass", 9));
    assert(config.sta.threshold.authmode == 3 && config.sta.pmf_cfg.capable);
    c3_station_clear_password(&config);
    for (size_t i = 0; i < sizeof(config.sta.password); ++i)
        assert(config.sta.password[i] == 0);

    for (size_t i = 0; i < sizeof(frame); ++i) {
        reader = (struct reader){frame, i, 0};
        assert(c3_station_read_config(read_byte, &reader, &address, &config) != 0);
        for (size_t j = 0; j < sizeof(config.sta.password); ++j)
            assert(config.sta.password[j] == 0);
    }

    frame[1] = 0;
    reader = (struct reader){frame, 9, 0};
    assert(c3_station_read_config(read_byte, &reader, &address, &config) == 0);
    assert(config.sta.threshold.authmode == 0);
    frame[2] = 224;
    reader.offset = 0;
    assert(c3_station_read_config(read_byte, &reader, &address, &config) != 0);
}
