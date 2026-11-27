#include <errno.h>
#include <stdint.h>
#include <string.h>
#include "../main/log.h"

enum {
    TABLE = 0x8000, TABLE_BYTES = 0xc00, FLASH_BYTES = 0x400000,
    JOURNAL = 0x280000, JOURNAL_BYTES = 0x10000,
    ENTRY_MAGIC = 0x50aa, TABLE_DIGEST = 0xebeb
};

/* C3 ROM exports. All executable code, data and the stack for this
 * application are in SRAM while the SPI flash cache is suspended. */
extern int c3_rom_flash_read(uint32_t, uint32_t *, int32_t);
extern int c3_rom_flash_write(uint32_t, const uint32_t *, int32_t);
extern int c3_rom_flash_unlock(void);
extern uint32_t c3_rom_cache_suspend(void);
extern void c3_rom_cache_resume(uint32_t);

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
    if (at > JOURNAL_BYTES || len > JOURNAL_BYTES - at ||
        ((at | len) & 3u) || len > C3LOG_SLOT_BYTES) return -EINVAL;
    uint32_t words[C3LOG_SLOT_BYTES / 4];
    uint32_t cache = c3_rom_cache_suspend();
    int rc = c3_rom_flash_read(JOURNAL + at, words, len);
    c3_rom_cache_resume(cache);
    if (rc != 0) return -EIO;
    memcpy(out, words, len);
    return 0;
}

#ifdef C3_TEST_CUT
_Noreturn void c3_test_cut_ready(void);
#endif

static int program_at(void *ctx, size_t at, const void *src, size_t len) {
    (void)ctx;
    if (at > JOURNAL_BYTES || len > JOURNAL_BYTES - at ||
        ((at | len) & 3u) || len > C3LOG_SLOT_BYTES) return -EINVAL;
    uint32_t words[C3LOG_SLOT_BYTES / 4];
#ifdef C3_TEST_CUT
    /* c3log_append has already written and read back the body. */
    if (at % C3LOG_SLOT_BYTES == C3LOG_SLOT_BYTES - 4 && len == 4)
        c3_test_cut_ready();
#endif
    memcpy(words, src, len);
    uint32_t cache = c3_rom_cache_suspend();
    int rc = c3_rom_flash_unlock();
    if (rc == 0) rc = c3_rom_flash_write(JOURNAL + at, words, len);
    c3_rom_cache_resume(cache);
    return rc == 0 ? 0 : -EIO;
}

static int check_layout(void) {
    uint32_t security1 = *(const volatile uint32_t *)0x60008834u;
    uint32_t security2 = *(const volatile uint32_t *)0x60008838u;
    if (__builtin_parity((security1 >> 18) & 7u) || (security2 & (1u << 20)))
        return -ENOTSUP;
    bool found = false;
    for (uint32_t at = TABLE; at < TABLE + TABLE_BYTES; at += sizeof(partition)) {
        union { partition entry; uint32_t words[8]; } raw;
        uint32_t cache = c3_rom_cache_suspend();
        int rc = c3_rom_flash_read(at, raw.words, sizeof(raw));
        c3_rom_cache_resume(cache);
        if (rc != 0) return -EIO;
        const partition *p = &raw.entry;
        if (p->magic == TABLE_DIGEST || p->magic == UINT16_MAX)
            return found ? 0 : -ENODEV;
        if (p->magic != ENTRY_MAGIC || p->offset < 0x9000 ||
            p->offset > FLASH_BYTES || p->size > FLASH_BYTES - p->offset)
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
