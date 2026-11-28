#include "flash_region.h"

#include <errno.h>
#include <string.h>

extern int c3_rom_flash_read(uint32_t, uint32_t *, int32_t);
extern int c3_rom_flash_write(uint32_t, const uint32_t *, int32_t);
extern int c3_rom_flash_erase_sector(uint32_t);
extern int c3_rom_flash_unlock(void);
extern uint32_t c3_rom_cache_suspend(void);
extern void c3_rom_cache_resume(uint32_t);

enum { TRANSFER_BYTES = 128 };

static bool contains(const c3_flash_region *region, size_t at, size_t len) {
    return region->base <= C3_FLASH_BYTES &&
           region->bytes <= C3_FLASH_BYTES - region->base &&
           at <= region->bytes && len <= region->bytes - at;
}

static bool can_transfer(const c3_flash_region *region, size_t at, size_t len) {
    return len <= TRANSFER_BYTES && contains(region, at, len) &&
           (((region->base + at) | len) & 3u) == 0;
}

int c3_flash_read(const c3_flash_region *region, size_t at, void *out, size_t len) {
    if (!can_transfer(region, at, len)) return -EINVAL;
    if (!len) return 0;

    uint32_t words[TRANSFER_BYTES / sizeof(uint32_t)];
    uint32_t cache = c3_rom_cache_suspend();
    int rc = c3_rom_flash_read(region->base + at, words, len);
    c3_rom_cache_resume(cache);
    if (rc != 0) return -EIO;
    memcpy(out, words, len);
    return 0;
}

int c3_flash_program(const c3_flash_region *region, size_t at, const void *src, size_t len) {
    if (!can_transfer(region, at, len)) return -EINVAL;
    if (!len) return 0;

    uint32_t words[TRANSFER_BYTES / sizeof(uint32_t)];
    memcpy(words, src, len);
    uint32_t cache = c3_rom_cache_suspend();
    int rc = c3_rom_flash_unlock();
    if (rc == 0) rc = c3_rom_flash_write(region->base + at, words, len);
    c3_rom_cache_resume(cache);
    return rc == 0 ? 0 : -EIO;
}

int c3_flash_erase_sector(const c3_flash_region *region, size_t at) {
    if (!region->erase_allowed) return -ENOTSUP;
    if (!contains(region, at, C3_FLASH_SECTOR_BYTES)) return -EINVAL;

    uint32_t address = region->base + at;
    if (address % C3_FLASH_SECTOR_BYTES != 0) return -EINVAL;
    uint32_t cache = c3_rom_cache_suspend();
    int rc = c3_rom_flash_unlock();
    if (rc == 0) rc = c3_rom_flash_erase_sector(address / C3_FLASH_SECTOR_BYTES);
    c3_rom_cache_resume(cache);
    return rc == 0 ? 0 : -EIO;
}
