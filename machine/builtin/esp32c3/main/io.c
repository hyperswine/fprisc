#include <errno.h>
#include "driver/usb_serial_jtag.h"
#include "bytes.h"

static V transfer(V addr, V count, bool writing, bool exact) {
    if (!ISINT(count) || UNTAG(count) < 0) return TAG(-EINVAL);
    unsigned char *p = buffer_ptr(addr);
    int size = UNTAG(count), done = 0;
    if (!p && size) return TAG(-EINVAL);
    while (done < size) {
        int n = writing ? usb_serial_jtag_write_bytes(p + done, size - done, portMAX_DELAY)
                        : usb_serial_jtag_read_bytes(p + done, size - done, portMAX_DELAY);
        if (n <= 0) return TAG(done ? done : -EIO);
        done += n;
        if (!exact) break;
    }
    return TAG(done);
}
static V read_some(V p, V n) { return transfer(p, n, false, false); }
static V read_exact(V p, V n) { return transfer(p, n, false, true); }
static V write_bytes(V p, V n) { return transfer(p, n, true, true); }
static V read_byte(V ignored) {
    unsigned char byte;
    return TAG(usb_serial_jtag_read_bytes(&byte, 1, portMAX_DELAY) == 1 ? (int)byte : -EIO);
}
FPR_FN(fpr_g_EspIO_x2eread, read_some, 2);
FPR_FN(fpr_g_EspIO_x2ereadExact, read_exact, 2);
FPR_FN(fpr_g_EspIO_x2ewrite, write_bytes, 2);
FPR_FN(fpr_g_EspIO_x2ereadByte, read_byte, 1);

static V write_byte(V n) {
    if (!ISINT(n) || UNTAG(n) < 0 || UNTAG(n) > 255) return TAG(-EINVAL);
    unsigned char byte = UNTAG(n);
    return TAG(usb_serial_jtag_write_bytes(&byte, 1, portMAX_DELAY) == 1 ? 1 : -EIO);
}
FPR_FN(fpr_g_EspIO_x2ewriteByte, write_byte, 1);
