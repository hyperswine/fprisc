#include "hci.h"
#include <assert.h>

int main(void) {
    const uint8_t uuid[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
    uint8_t out[C3_HCI_MAX_COMMAND];
    assert(c3_hci_adv_command(0, uuid, out) == 4 && out[1] == 3 && out[2] == 12);
    assert(c3_hci_adv_command(1, uuid, out) == 19 && out[8] == 3 && out[17] == 7);
    assert(c3_hci_adv_command(2, uuid, out) == 36 && out[4] == 21 && out[9] == 7);
    for (unsigned i = 0; i < 16; ++i) assert(out[10 + i] == 15 - i);
    assert(c3_hci_adv_command(3, uuid, out) == 5 && out[4] == 1);
    assert(c3_hci_adv_command(4, uuid, out) == 0);
    uint8_t complete[] = {4, 14, 4, 1, 10, 32, 0};
    assert(c3_hci_adv_complete(3, complete, sizeof(complete)) == 1);
    assert(c3_hci_adv_complete(1, complete, sizeof(complete)) == 0);
    assert(c3_hci_adv_complete(3, complete, sizeof(complete)-1) == 0);
    complete[6] = 12;
    assert(c3_hci_adv_complete(3, complete, sizeof(complete)) == -12);
}
