#include "flash.h"
#include "log.h"
#include "platform.h"
#include <errno.h>
#include <stdint.h>
#include <string.h>

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))

enum {
    TABLE = 0x8000, TABLE_BYTES = 0xc00, FLASH_BYTES = 32 * 1024 * 1024,
    JOURNAL = 0xe20000, JOURNAL_BYTES = 0x10000,
    SCRATCH = 0xe30000, SECTOR = 0x1000, DATA_PARTITION = 1,
    ENTRY_MAGIC = 0x50aa, TABLE_DIGEST = 0xebeb,
    CHUNK = C3LOG_SLOT_BYTES, L2_CACHE = 1u << 5
};

extern int p4_rom_flash_read(uint32_t address, uint32_t *dst, int32_t size);
extern int p4_rom_flash_write(uint32_t address, const uint32_t *src, int32_t size);
extern int p4_rom_flash_unlock(void);
extern int p4_rom_flash_erase(uint32_t sector);
extern uint32_t p4_rom_cache_suspend(void);
extern void p4_rom_cache_resume(uint32_t autoload);
extern void p4_rom_cache_invalidate(uint32_t map);
extern uint32_t p4_rom_crc(uint32_t crc, const void *data, uint32_t size);

extern void p4_puts(const char *);
extern void p4_hex(uint32_t);
extern int p4_uart_read_byte(void);

typedef struct {
    uint16_t magic;
    uint8_t type, subtype;
    uint32_t offset, size;
    char name[16];
    uint32_t flags;
} partition;

_Static_assert(sizeof(partition) == 32, "ESP flash partition descriptor");

static const char journal_label[16] = "fprjournal";
static const char scratch_label[16] = "fprscratch";
static const char record_name[] = "p4check";
static bool cut_pending;

static bool match_bytes(const void *left, const void *right, unsigned bytes) {
    const uint8_t *a = left, *b = right;
    for (unsigned i = 0; i < bytes; ++i)
        if (a[i] != b[i]) return false;
    return true;
}

static bool bounded(unsigned region, unsigned capacity, size_t at, size_t size) {
    return region <= FLASH_BYTES && capacity <= FLASH_BYTES - region &&
           at <= capacity && size <= capacity - at &&
           size <= CHUNK && !(((region + at) | size) & 3);
}

static int read_flash(unsigned region, unsigned capacity, size_t at, void *dst, size_t size) {
    if (!bounded(region, capacity, at, size)) return -EINVAL;
    uint32_t words[CHUNK / 4];
    uint32_t cache = p4_rom_cache_suspend();
    int rc = p4_rom_flash_read(region + at, words, size);
    p4_rom_cache_resume(cache);
    if (rc) return -EIO;
    memcpy(dst, words, size);
    return 0;
}

static int program_flash(unsigned region, unsigned capacity, size_t at,
                         const void *src, size_t size) {
    if (!bounded(region, capacity, at, size)) return -EINVAL;
    uint32_t words[CHUNK / 4];
    memcpy(words, src, size);
    uint32_t cache = p4_rom_cache_suspend();
    int rc = p4_rom_flash_unlock();
    if (!rc) rc = p4_rom_flash_write(region + at, words, size);
    p4_rom_cache_invalidate(L2_CACHE);
    p4_rom_cache_resume(cache);
    return rc ? -EIO : 0;
}

static int erase_scratch(void) {
    uint32_t cache = p4_rom_cache_suspend();
    int rc = p4_rom_flash_unlock();
    if (!rc) rc = p4_rom_flash_erase(SCRATCH / SECTOR);
    p4_rom_cache_invalidate(L2_CACHE);
    p4_rom_cache_resume(cache);
    return rc ? -EIO : 0;
}

static bool overlaps(const partition *p, unsigned base, unsigned bytes) {
    return p->offset < base + bytes && base < p->offset + p->size;
}

static bool is_data(const partition *p, unsigned base, unsigned bytes,
                    unsigned subtype, const char name[16]) {
    return p->offset == base && p->size == bytes && p->type == DATA_PARTITION &&
           p->subtype == subtype && !p->flags && match_bytes(p->name, name, sizeof(p->name));
}

static int check_layout(void) {
    uint32_t efuse1 = REG(0x5012d034), efuse2 = REG(0x5012d038);
    if (__builtin_parity((efuse1 >> 18) & 7u) || (efuse2 & (1u << 20))) return -ENOTSUP;
    bool journal = false, scratch = false;
    for (size_t at = 0; at < TABLE_BYTES; at += sizeof(partition)) {
        partition p;
        int rc = read_flash(TABLE, TABLE_BYTES, at, &p, sizeof(p));
        if (rc) return rc;
        if (p.magic == TABLE_DIGEST) return journal && scratch ? 0 : -ENODEV;
        if (p.magic != ENTRY_MAGIC || p.offset < 0x9000 || p.offset > FLASH_BYTES ||
            !p.size || p.size > FLASH_BYTES - p.offset) return -EINVAL;
        if (overlaps(&p, JOURNAL, JOURNAL_BYTES)) {
            if (journal || !is_data(&p, JOURNAL, JOURNAL_BYTES, 0x40, journal_label)) return -EINVAL;
            journal = true;
        }
        if (overlaps(&p, SCRATCH, SECTOR)) {
            if (scratch || !is_data(&p, SCRATCH, SECTOR, 0x41, scratch_label)) return -EINVAL;
            scratch = true;
        }
    }
    return -EINVAL;
}

static int journal_read(void *ctx, size_t at, void *dst, size_t size) {
    (void)ctx;
    return read_flash(JOURNAL, JOURNAL_BYTES, at, dst, size);
}

static int journal_program(void *ctx, size_t at, const void *src, size_t size) {
    (void)ctx;
    if (cut_pending && at % C3LOG_SLOT_BYTES == C3LOG_SLOT_BYTES - 4 && size == 4) {
        p4_puts("FPR P4 CUT READY\n");
        for (;;) __asm__ volatile("wfi");
    }
    return program_flash(JOURNAL, JOURNAL_BYTES, at, src, size);
}

static uint32_t checksum(const void *data, size_t bytes) {
    return p4_rom_crc(0, data, bytes);
}

static int readback_scratch(bool programmed) {
    uint32_t words[CHUNK / 4];
    for (size_t at = 0; at < SECTOR; at += sizeof(words)) {
        int rc = read_flash(SCRATCH, SECTOR, at, words, sizeof(words));
        if (rc) return rc;
        for (unsigned i = 0; i < sizeof(words) / sizeof(words[0]); ++i) {
            uint32_t expected = programmed && !at && !i ? 0x5a5aa5a5 : UINT32_MAX;
            if (words[i] != expected) return -EIO;
        }
    }
    return 0;
}

static int check_scratch(void) {
    uint32_t word = 0x5a5aa5a5;
    int rc = readback_scratch(false);
    if (!rc) rc = program_flash(SCRATCH, SECTOR, 0, &word, sizeof(word));
    if (!rc) rc = readback_scratch(true);
    if (!rc) rc = erase_scratch();
    if (!rc) rc = readback_scratch(false);
    return rc;
}

static int show_records(c3log *journal) {
    size_t cursor = 0;
    uint8_t data[C3LOG_PAYLOAD_MAX];
    unsigned count = 0;
    for (;;) {
        int size = c3log_next(journal, record_name, sizeof(record_name) - 1, &cursor, data);
        if (!size) break;
        if (size != 4) return size < 0 ? size : -EBADMSG;
        uint32_t value = (uint32_t)data[0] | (uint32_t)data[1] << 8 |
                         (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
        p4_puts("FPR P4 RECORD ");
        p4_hex(value);
        p4_puts("\n");
        ++count;
    }
    p4_puts("FPR P4 JOURNAL records ");
    p4_hex(count);
    p4_puts("\n");
    return 0;
}

static void print_result(const char *operation, int rc) {
    p4_puts(operation);
    p4_hex((uint32_t)rc);
    p4_puts("\n");
}

int p4_journal_mount(c3log *journal) {
    journal->ready = false;
    int rc = check_layout();
    if (rc) return rc;
    *journal = (c3log){
        .bytes = JOURNAL_BYTES, .read = journal_read, .program = journal_program, .crc = checksum,
    };
    return c3log_mount(journal);
}

void p4_flash_check(void) {
    c3log journal = {0};
    int rc = p4_journal_mount(&journal);
    if (!rc) p4_puts("FPR P4 FLASH LAYOUT 00000000\n");
    print_result("FPR P4 JOURNAL MOUNT ", rc);
    if (rc) return;
    uint32_t dummy = 0;
    if (read_flash(JOURNAL, JOURNAL_BYTES, JOURNAL_BYTES, &dummy, 4) != -EINVAL ||
        program_flash(JOURNAL, JOURNAL_BYTES, 1, &dummy, 4) != -EINVAL) {
        p4_puts("FPR P4 FLASH BOUNDS FAIL\n");
        return;
    }
    p4_puts("FPR P4 FLASH BOUNDS PASS\n");
    p4_puts("FPR P4 FLASH READY\n");
    for (;;) {
        int key = p4_uart_read_byte();
        if (key == 'Q') return;
        if (key == 'E') print_result("FPR P4 SCRATCH ", check_scratch());
        if (key == 'L') print_result("FPR P4 LIST ", show_records(&journal));
        if (key == '1' || key == '2' || key == '3' || key == 'W') {
            cut_pending = key == '2';
            uint32_t value = key == 'W' ? 4u : (unsigned)(key - '0');
            rc = c3log_append(&journal, record_name, sizeof(record_name) - 1, &value, sizeof(value));
            cut_pending = false;
            print_result("FPR P4 APPEND ", rc);
        }
        if (key == 'H') {
            p4_puts("FPR P4 UPTIME ms ");
            p4_hex((uint32_t)(p4_clock_now_us() / 1000));
            p4_puts("\n");
        }
        if (key < 0) p4_clock_sleep_until(p4_clock_now_us() + 10000);
    }
}
