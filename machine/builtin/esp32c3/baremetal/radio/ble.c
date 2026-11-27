#include <errno.h>
#include "builtin.h"
#include "alloc.h"
#include "ble_hw.h"
#include "btdm_irq.h"
#include "btdm_services.h"
#include "hci.h"
#include "task.h"
#include "ble_config.h"

enum { BLE_MODE = 1, COMMAND_TIMEOUT_US = 2000000 };
static const uint8_t service_uuid[16] = {
    0x43, 0xaa, 0x9e, 0x7e, 0x1e, 0xa0, 0x4a, 0xb4,
    0xa7, 0xc2, 0x1a, 0x28, 0x0b, 0x18, 0xb1, 0x3c
};
static struct c3_btdm_osi callbacks;
static uint8_t command[C3_HCI_MAX_COMMAND];
static unsigned pending_step = C3_HCI_ADV_STEPS;
static int pending_result;
static bool in_flight;

extern int btdm_controller_init(struct c3_btdm_config *config);
extern int btdm_controller_enable(unsigned mode);
extern void coex_pti_v2(void);
extern void c3_console_text(const char *message);

static void send_available(void) {
    in_flight = false;
    c3_tasks_wake(&pending_step);
}

static int32_t receive_event(uint8_t *data, uint16_t length) {
    int rc = c3_hci_adv_complete(pending_step, data, length);
    if (rc) {
        pending_result = rc;
        c3_tasks_wake(&pending_step);
    }
    return 0;
}

static const struct c3_vhci_host host = {send_available, receive_event};

static int advertise(void) {
    for (unsigned step = 0; step < C3_HCI_ADV_STEPS; ++step) {
        uint64_t deadline = c3_tasks_now_us() + COMMAND_TIMEOUT_US;
        while (in_flight || !API_vhci_host_check_send_available()) {
            if (c3_tasks_now_us() >= deadline) return -ETIMEDOUT;
            c3_task_park(&pending_step, deadline);
        }
        pending_step = step;
        pending_result = 0;
        in_flight = true;
        size_t length = c3_hci_adv_command(step, service_uuid, command);
        API_vhci_host_send_packet(command, length);
        while (!pending_result) {
            if (c3_tasks_now_us() >= deadline) return -ETIMEDOUT;
            c3_task_park(&pending_step, deadline);
        }
        if (pending_result < 0) return pending_result;
    }
    pending_step = C3_HCI_ADV_STEPS;
    return 0;
}

static V run_ble(V unit) {
    (void)unit;
    static struct c3_btdm_config config = {
        .magic = 0x5a5aa5a5, .version = 0x02509280,
        .controller_task_stack_size = 8192, .controller_task_prio = 3,
        .bluetooth_mode = BLE_MODE, .ble_max_act = 3,
        .ble_adv_dup_filt_max = 30, .hci_tl_type = 1, .txpwr_dft = 11,
        .cfg_mask = 1, .normal_adv_size = 20, .hw_target_code = 0x01010000,
        .slave_ce_len_min = 5, .cca_thresh = 75,
        .ble_50_feat_supp = true, .ble_chan_ass_en = 1,
        .ble_ping_en = 1, .dtm_en = true, .enc_en = true,
        .connect_en = true, .scan_en = true, .ble_aa_check = true, .adv_en = true,
    };
    c3_btdm_install_services(&callbacks, 1);
    c3_btdm_install_interrupts(&callbacks);
    c3_ble_install_platform(&callbacks);
    c3_console_text("BLE power\n");
    if (c3_ble_power_up()) fpr_cpanic("BLE clock or ROM data init");
    c3_console_text("BLE OSI\n");
    if (btdm_osi_funcs_register(&callbacks)) fpr_cpanic("BLE OSI registration");
    c3_console_text("BLE controller init\n");
    if (btdm_controller_init(&config)) fpr_cpanic("BLE controller init");
    c3_console_text("BLE PHY calibration\n");
    if (c3_ble_calibrate()) fpr_cpanic("BLE PHY calibration");
    coex_pti_v2();
    c3_console_text("BLE controller enable\n");
    if (btdm_controller_enable(BLE_MODE)) fpr_cpanic("BLE controller enable");
    if (API_vhci_host_register_callback(&host)) fpr_cpanic("BLE VHCI registration");
    if (advertise()) fpr_cpanic("BLE advertising HCI");
    c3_console_text("FPR BLE ADVERTISING 43AA9E7E-1EA0-4AB4-A7C2-1A280B18B13C\n");
    for (;;) c3_task_park(&pending_step, C3_WAIT_FOREVER);
}
FPR_FN(fpr_g_EspBLE_x2eadvertise, run_ble, 1);
