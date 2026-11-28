#include <errno.h>
#include "bytes.h"
#include "log.h"
#ifndef FPR_C3_BAREMETAL
#include "flash_access.h"
#include "esp_rom_crc.h"
#endif

static c3log journal;
static V enabled(V unit) {
#ifdef FPR_RAW_JOURNAL
    return V_TRUE;
#else
    return V_FALSE;
#endif
}
#ifdef FPR_C3_BAREMETAL
int c3_bare_journal_mount(c3log *log);
static V mount_log(V unit) { return TAG(c3_bare_journal_mount(&journal)); }
#else
static int read_at(void *ctx, size_t at, void *out, size_t n) {
    return esp_partition_read(ctx, at, out, n) == ESP_OK ? 0 : -EIO;
}
static int write_at(void *ctx, size_t at, const void *data, size_t n) {
    return esp_partition_write(ctx, at, data, n) == ESP_OK ? 0 : -EIO;
}
static uint32_t checksum(const void *data, size_t n) { return esp_rom_crc32_le(0, data, n); }
static V mount_log(V unit) {
    const esp_partition_t *part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, 0x40, "fprjournal");
    if (!part) return TAG(-ENODEV);
    int rc = fpr_c3_partition_access(part);
    if (rc) return TAG(rc);
    journal = (c3log){.context=(void *)part, .bytes=part->size, .read=read_at,
        .program=write_at, .crc=checksum};
    return TAG(c3log_mount(&journal));
}
#endif
static V append_log(V name, V ptr, V length) {
    if (!ISPTR(name) || TID(name) != T_STR || !ISINT(length) || UNTAG(length)<1) return TAG(-EINVAL);
    str_t *s=(str_t *)name;
    return TAG(c3log_append(&journal,(const char *)s->bytes,s->len,buffer_ptr(ptr),UNTAG(length)));
}
/* The record workspace is 72 bytes. Bytes 0..63 hold payload, byte 64
 * holds its length. Return the next slot index, or zero at EOF. */
static V next_log(V name, V position, V ptr) {
    if (!ISPTR(name) || TID(name) != T_STR || !ISINT(position) || UNTAG(position)<0) return TAG(-EINVAL);
    str_t *s=(str_t *)name;
    size_t cursor=UNTAG(position);
    uint8_t *buffer = buffer_ptr(ptr);
    int n = c3log_next(&journal, (const char *)s->bytes, s->len, &cursor, buffer);
    if (n <= 0) return TAG(n);
    buffer[64] = (uint8_t)n;
    return TAG(cursor);
}
FPR_FN(fpr_g_EspFlashLog_x2eenabled, enabled, 1);
FPR_FN(fpr_g_EspFlashLog_x2emount, mount_log, 1);
FPR_FN(fpr_g_EspFlashLog_x2eappend, append_log, 3);
FPR_FN(fpr_g_EspFlashLog_x2enext, next_log, 3);
