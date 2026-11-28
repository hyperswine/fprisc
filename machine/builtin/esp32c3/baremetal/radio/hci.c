#include "hci.h"

enum {
    H4_COMMAND = 1, H4_EVENT = 4, CMD_COMPLETE = 0x0e,
    RESET = 0x0c03, ADV_PARAMETERS = 0x2006, ADV_DATA = 0x2008, ADV_ENABLE = 0x200a,
    INTERVAL_MIN = 0x00a0, INTERVAL_MAX = 0x00c0, /* 100–120 ms */
    ADV_NONCONNECTABLE = 3, ADV_CHANNELS = 7,
    AD_FLAGS = 1, AD_UUID128_COMPLETE = 7, LE_GENERAL_NO_BREDR = 6,
};

static const uint16_t opcodes[C3_HCI_ADV_STEPS] = {
    RESET, ADV_PARAMETERS, ADV_DATA, ADV_ENABLE,
};
static const uint8_t parameters[C3_HCI_ADV_STEPS] = { 0, 15, 32, 1 };

size_t c3_hci_adv_command(unsigned step, const uint8_t uuid[16],
                          uint8_t packet[C3_HCI_MAX_COMMAND]) {
    if (step >= C3_HCI_ADV_STEPS) return 0;
    size_t length = parameters[step] + 4u;
    for (size_t i = 0; i < length; ++i) packet[i] = 0;
    packet[0] = H4_COMMAND;
    packet[1] = (uint8_t)opcodes[step];
    packet[2] = (uint8_t)(opcodes[step] >> 8);
    packet[3] = parameters[step];
    switch (opcodes[step]) {
    case ADV_PARAMETERS:
        packet[4] = (uint8_t)INTERVAL_MIN;
        packet[6] = (uint8_t)INTERVAL_MAX;
        packet[5] = (uint8_t)(INTERVAL_MIN >> 8);
        packet[7] = (uint8_t)(INTERVAL_MAX >> 8);
        packet[8] = ADV_NONCONNECTABLE;
        packet[17] = ADV_CHANNELS;
        break;
    case ADV_DATA:
        packet[4] = 21;
        packet[5] = 2;
        packet[6] = AD_FLAGS;
        packet[7] = LE_GENERAL_NO_BREDR;
        packet[8] = 17;
        packet[9] = AD_UUID128_COMPLETE;
        for (size_t i = 0; i < 16; ++i) packet[10 + i] = uuid[15 - i];
        break;
    case ADV_ENABLE:
        packet[4] = 1;
        break;
    }
    return length;
}

int c3_hci_adv_complete(unsigned step, const uint8_t *packet, size_t length) {
    if (step >= C3_HCI_ADV_STEPS || length < 7 ||
        packet[0] != H4_EVENT || packet[1] != CMD_COMPLETE ||
        packet[2] < 4 || length != (size_t)packet[2] + 3u) return 0;
    uint16_t opcode = (uint16_t)packet[4] | (uint16_t)packet[5] << 8;
    if (opcode != opcodes[step]) return 0;
    return packet[6] == 0 ? 1 : -(int)packet[6];
}
