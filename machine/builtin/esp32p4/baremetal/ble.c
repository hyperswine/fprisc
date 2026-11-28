#include <errno.h>
#include <string.h>
#include "builtin.h"
#include "hci.h"
#include "platform.h"

enum { UUID_BYTES = 16, UUID_TEXT = 36, ADV_ENABLE_STEP = C3_HCI_ADV_STEPS - 1 };

static bool running;
static uint8_t active_uuid[UUID_BYTES];

extern void p4_puts(const char *);
extern void p4_hex(uint32_t);

static int advertise(const uint8_t uuid[UUID_BYTES]) {
    uint8_t command[C3_HCI_MAX_COMMAND];
    for (unsigned step = 0; step < C3_HCI_ADV_STEPS; ++step) {
        size_t count = c3_hci_adv_command(step, uuid, command);
        int rc = p4_sdio_hci(step, command, count);
        if (rc) {
            p4_puts("P4 BLE failed HCI step ");
            p4_hex(step);
            p4_puts(", result ");
            p4_hex((uint32_t)rc);
            p4_puts("\n");
            return rc;
        }
    }
    return 0;
}

static int start(const uint8_t uuid[UUID_BYTES]) {
    if (running) {
        for (unsigned i = 0; i < UUID_BYTES; ++i)
            if (active_uuid[i] != uuid[i]) return -EBUSY;
        return 0;
    }
    if (!p4_sdio_ready() && !p4_sdio_start()) return -ENODEV;
    int rc = advertise(uuid);
    if (rc) {
        p4_sdio_reset_companion();
        return rc;
    }
    memcpy(active_uuid, uuid, UUID_BYTES);
    running = true;
    p4_puts("FPR P4 BLE ADVERTISING\n");
    return 0;
}

static int hex_digit(uint8_t byte) {
    if (byte >= '0' && byte <= '9') return byte - '0';
    byte |= 32u;
    return byte >= 'a' && byte <= 'f' ? byte - 'a' + 10 : -1;
}

static V ble_start(V value) {
    if (!ISPTR(value) || TID(value) != T_STR) return TAG(-EINVAL);
    const str_t *text = (const str_t *)value;
    if (text->len != UUID_TEXT) return TAG(-EINVAL);
    uint8_t uuid[UUID_BYTES];
    const uint8_t *p = (const uint8_t *)text->bytes;
    for (unsigned i = 0; i < UUID_BYTES; ++i) {
        if ((i == 4 || i == 6 || i == 8 || i == 10) && *p++ != '-') return TAG(-EINVAL);
        int hi = hex_digit(*p++);
        int lo = hex_digit(*p++);
        if (hi < 0 || lo < 0) return TAG(-EINVAL);
        uuid[i] = (uint8_t)((hi << 4) | lo);
    }
    return TAG(start(uuid));
}
FPR_FN(fpr_g_EspBLE_x2estart, ble_start, 1);

static V ble_stop(V unit) {
    (void)unit;
    if (!running) return V_UNIT;
    uint8_t command[C3_HCI_MAX_COMMAND];
    size_t count = c3_hci_adv_command(ADV_ENABLE_STEP, active_uuid, command);
    command[4] = 0;
    if (p4_sdio_hci(ADV_ENABLE_STEP, command, count)) p4_sdio_reset_companion();
    running = false;
    p4_puts("FPR P4 BLE STOPPED\n");
    return V_UNIT;
}
FPR_FN(fpr_g_EspBLE_x2estop, ble_stop, 1);

static V ble_service(V unit) {
    (void)unit;
    if (running && !p4_sdio_ready()) {
        if (p4_sdio_start() && !advertise(active_uuid))
            p4_puts("FPR P4 BLE RECOVERED\n");
        else {
            p4_sdio_reset_companion();
            p4_puts("FPR P4 BLE RECOVERY RETRY\n");
        }
    }
    p4_clock_sleep_until(p4_clock_now_us() + 100000);
    return V_UNIT;
}
FPR_FN(fpr_g_EspBLE_x2eservice, ble_service, 1);
