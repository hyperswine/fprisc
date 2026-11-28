#include "log.h"
#include <errno.h>
#include <string.h>

enum { BODY = 124, CRC = 120, NAME = 4, PAYLOAD = 36 };
static const uint8_t commit[] = {0x46, 0x4a, 0xa5, 0x5a};
static const uint8_t signature[16] = "FPR-C3-LOG-v1";

static bool erased(const uint8_t *data, size_t len) {
    for (size_t i = 0; i < len; i++) if (data[i] != 0xff) return false;
    return true;
}
static uint32_t load_le(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void store_le(uint8_t *p, uint32_t v) {
    for (unsigned i = 0; i < 4; i++) p[i] = v >> (8*i);
}
/* Uncommitted slots are spent. A committed slot with an invalid body is
 * storage damage and must never be silently skipped. */
static int state(c3log *log, const uint8_t *slot) {
    if (memcmp(slot + BODY, commit, sizeof(commit))) return 0;
    if (slot[0] != 1 || !slot[1] || slot[1] > C3LOG_NAME_MAX ||
        !slot[2] || slot[2] > C3LOG_PAYLOAD_MAX ||
        load_le(slot + CRC) != log->crc(slot, CRC)) return -EBADMSG;
    return 1;
}
static int write_checked(c3log *log, size_t at, const uint8_t *data, size_t len) {
    uint8_t check[C3LOG_SLOT_BYTES];
    int rc = log->program(log->context, at, data, len);
    if (!rc) rc = log->read(log->context, at, check, len);
    if (!rc && memcmp(check, data, len)) rc = -EIO;
    return rc;
}
int c3log_mount(c3log *log) {
    uint8_t slot[C3LOG_SLOT_BYTES];
    log->ready = false;
    if (log->bytes < 2*sizeof(slot) || log->bytes % sizeof(slot)) return -EINVAL;
    int rc = log->read(log->context, 0, slot, sizeof(slot));
    if (rc) return rc;
    if (!erased(slot + sizeof(signature), sizeof(slot) - sizeof(signature))) return -EINVAL;
    bool initialize = memcmp(slot, signature, sizeof(signature)) != 0;
    if (initialize) {
        /* A partially programmed initial signature may be completed if all
         * other storage remains erased. Never erase an unfamiliar volume. */
        for (size_t i=0; i<sizeof(signature); i++)
            if ((slot[i] & signature[i]) != signature[i]) return -EINVAL;
    }
    log->next = 1;
    for (size_t i=1; i < log->bytes/sizeof(slot); i++) {
        rc = log->read(log->context, i*sizeof(slot), slot, sizeof(slot));
        if (rc) return rc;
        if (erased(slot,sizeof(slot))) continue;
        if (initialize) return -EINVAL;
        rc = state(log,slot);
        if (rc < 0) return rc;
        log->next = i+1;
    }
    if (initialize) {
        rc = write_checked(log,0,signature,sizeof(signature));
        if (rc) return rc;
    }
    log->ready = true;
    return 0;
}
int c3log_append(c3log *log, const char *name, size_t name_len, const void *payload, size_t len) {
    if (!log->ready) return -ENODEV;
    if (!name_len || name_len > C3LOG_NAME_MAX || !len || len > C3LOG_PAYLOAD_MAX) return -EINVAL;
    if (log->next >= log->bytes/C3LOG_SLOT_BYTES) return -ENOSPC;
    size_t at = log->next*C3LOG_SLOT_BYTES;
    uint8_t slot[C3LOG_SLOT_BYTES] = {1, (uint8_t)name_len, (uint8_t)len};
    memcpy(slot+NAME, name, name_len);
    memcpy(slot+PAYLOAD, payload, len);
    store_le(slot+CRC, log->crc(slot,CRC));
    int rc = write_checked(log,at,slot,BODY);
    if (!rc) rc = write_checked(log,at+BODY,commit,sizeof(commit));
    if (rc) {
        /* A failed program may have partially consumed the slot. Remount
         * before assigning a slot to a subsequent append. */
        log->ready = false;
        return rc;
    }
    log->next++;
    return 0;
}
int c3log_next(c3log *log, const char *name, size_t name_len, size_t *cursor, void *payload) {
    if (!log->ready) return -ENODEV;
    if (!name_len || name_len > C3LOG_NAME_MAX) return -EINVAL;
    uint8_t slot[C3LOG_SLOT_BYTES];
    for (size_t i=*cursor ? *cursor : 1; i<log->next; i++) {
        int rc=log->read(log->context,i*sizeof(slot),slot,sizeof(slot));
        if (rc) return rc;
        rc=state(log,slot);
        if (rc<0) return rc;
        if (rc && slot[1]==name_len && !memcmp(slot+NAME,name,name_len)) {
            memcpy(payload, slot+PAYLOAD, slot[2]);
            *cursor=i+1;
            return slot[2];
        }
    }
    *cursor=log->next;
    return 0;
}
