#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { C3_FLASH_BYTES = 0x400000, C3_FLASH_SECTOR_BYTES = 4096 };

/* Define regions from a verified flash layout. The caller serializes
 * operations and keeps all code and data used during ROM calls in SRAM. */
typedef struct {
    uint32_t base, bytes;
    bool erase_allowed;
} c3_flash_region;

int c3_flash_read(const c3_flash_region *region, size_t at, void *out, size_t len);
int c3_flash_program(const c3_flash_region *region, size_t at, const void *src, size_t len);
int c3_flash_erase_sector(const c3_flash_region *region, size_t at);
