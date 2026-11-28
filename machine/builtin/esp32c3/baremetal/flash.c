#include <errno.h>
#include <stdint.h>
#include <string.h>
#include "../main/log.h"
#include "flash_region.h"

enum {
    TABLE = 0x8000, TABLE_BYTES = 0xc00,
    JOURNAL = 0x280000, JOURNAL_BYTES = 0x10000,
    ENTRY_MAGIC = 0x50aa, TABLE_DIGEST = 0xebeb
};

static const c3_flash_region journal_region = { .base = JOURNAL, .bytes = JOURNAL_BYTES };
static const c3_flash_region table_region = { .base = TABLE, .bytes = TABLE_BYTES };

typedef struct {
    uint16_t magic;
    uint8_t type, subtype;
    uint32_t offset, size;
    char label[16];
    uint32_t flags;
} partition;
_Static_assert(sizeof(partition) == 32, "ESP partition table entry");

static int read_at(void *ctx, size_t at, void *out, size_t len) {
    (void)ctx;
    return c3_flash_read(&journal_region, at, out, len);
}

#ifdef C3_TEST_CUT
_Noreturn void c3_test_cut_ready(void);
#endif

static int program_at(void *ctx, size_t at, const void *src, size_t len) {
    (void)ctx;
#ifdef C3_TEST_CUT
    /* c3log_append has already written and read back the body. */
    if (at < JOURNAL_BYTES && at % C3LOG_SLOT_BYTES == C3LOG_SLOT_BYTES - 4 && len == 4)
        c3_test_cut_ready();
#endif
    return c3_flash_program(&journal_region, at, src, len);
}

static int check_layout(void) {
    uint32_t security1 = *(const volatile uint32_t *)0x60008834u;
    uint32_t security2 = *(const volatile uint32_t *)0x60008838u;
    if (__builtin_parity((security1 >> 18) & 7u) || (security2 & (1u << 20)))
        return -ENOTSUP;
    bool found = false;
    for (uint32_t at = 0; at < TABLE_BYTES; at += sizeof(partition)) {
        partition entry;
        int rc = c3_flash_read(&table_region, at, &entry, sizeof(entry));
        if (rc != 0) return rc;
        const partition *p = &entry;
        if (p->magic == TABLE_DIGEST || p->magic == UINT16_MAX)
            return found ? 0 : -ENODEV;
        if (p->magic != ENTRY_MAGIC || p->offset < 0x9000 ||
            p->offset > C3_FLASH_BYTES || p->size > C3_FLASH_BYTES - p->offset)
            return -EINVAL;
        if (p->offset >= JOURNAL + JOURNAL_BYTES || p->offset + p->size <= JOURNAL)
            continue;
        if (found || p->offset != JOURNAL || p->size != JOURNAL_BYTES ||
            p->type != 1 || p->subtype != 0x40 || p->flags != 0 ||
            memcmp(p->label, "fprjournal\0\0\0\0\0", sizeof(p->label)) != 0)
            return -EINVAL;
        found = true;
    }
    return -EINVAL;
}

extern uint32_t c3_rom_crc32_le(uint32_t, const void *, uint32_t);
static uint32_t checksum(const void *data, size_t len) {
    return c3_rom_crc32_le(0, data, len);
}

int c3_bare_journal_mount(c3log *log) {
    int rc = check_layout();
    if (rc) {
        log->ready = false;
        return rc;
    }
    *log = (c3log){
        .bytes = JOURNAL_BYTES, .read = read_at, .program = program_at, .crc = checksum
    };
    return c3log_mount(log);
}
