#include <errno.h>
#include "bytes.h"
#include "log.h"

int p4_journal_mount(c3log *journal);
static c3log journal;

static V mount(V unit) {
    (void)unit;
    return TAG(p4_journal_mount(&journal));
}
FPR_FN(fpr_g_EspFlashLog_x2emount, mount, 1);

static V append(V name, V buffer, V length) {
    if (!ISPTR(name) || TID(name) != T_STR || !ISINT(length) || UNTAG(length) <= 0)
        return TAG(-EINVAL);
    const str_t *label = (const str_t *)name;
    return TAG(c3log_append(&journal, (const char *)label->bytes, label->len,
                           buffer_ptr(buffer), UNTAG(length)));
}
FPR_FN(fpr_g_EspFlashLog_x2eappend, append, 3);

static V next(V name, V position, V buffer) {
    if (!ISPTR(name) || TID(name) != T_STR || !ISINT(position) || UNTAG(position) < 0)
        return TAG(-EINVAL);
    const str_t *label = (const str_t *)name;
    uint8_t *payload = buffer_ptr(buffer);
    size_t cursor = UNTAG(position);
    int size = c3log_next(&journal, (const char *)label->bytes, label->len, &cursor, payload);
    if (size <= 0) return TAG(size);
    payload[C3LOG_PAYLOAD_MAX] = (uint8_t)size;
    return TAG(cursor);
}
FPR_FN(fpr_g_EspFlashLog_x2enext, next, 3);
