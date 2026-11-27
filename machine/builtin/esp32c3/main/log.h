#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define C3LOG_SLOT_BYTES 128
#define C3LOG_NAME_MAX 32
#define C3LOG_PAYLOAD_MAX 64

/* Backing storage is a dedicated, initially erased NOR partition.
 * read/program return zero or a negative error. program is synchronous.
 * All API calls are serialized by the single Builtin main task. */
typedef struct {
    void *context;
    size_t bytes;
    int (*read)(void *, size_t, void *, size_t);
    int (*program)(void *, size_t, const void *, size_t);
    uint32_t (*crc)(const void *, size_t);
    size_t next;
    bool ready;
} c3log;

int c3log_mount(c3log *log);
int c3log_append(c3log *log, const char *name, size_t name_len, const void *payload, size_t len);
/* Return payload length, zero at EOF or a negative error. Cursor is a slot index. */
int c3log_next(c3log *log, const char *name, size_t name_len, size_t *cursor, void *payload);
