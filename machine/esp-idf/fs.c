/* fs.c (esp-idf) -- files: FAT on the flash's "storage" partition, at /data.
 *
 * machine/posix/os_fs.c and base_file.c are the file primitives here too:
 * newlib's stdio and ESP-IDF's VFS give them open, stat, opendir, rename and
 * the rest once a filesystem is mounted.  This file only mounts one, through
 * wear levelling (flash sectors wear out; FAT rewrites the same ones).
 *
 * Paths are absolute: IDF's VFS routes by prefix and has no working
 * directory, so "notes.txt" is not found where "/data/notes.txt" is.
 * The first boot on a blank partition formats it, which takes a few seconds.
 * Every file call runs on the hart task's internal stack (FPR_FN_CSTACK):
 * flash operations assert that, and actor stacks are in PSRAM. */
#include "fpr.h"
#include <stdio.h>
#include "esp_vfs_fat.h"
#include "wear_levelling.h"

/* open FILES at once, a table the FAT VFS sizes when mounting; past it an open
 * answers Err "Too many open files" (docs/BOUNDS.md) */
#ifndef FPR_ESP_FS_MAX_FILES
#define FPR_ESP_FS_MAX_FILES 16
#endif

static wl_handle_t wl = WL_INVALID_HANDLE;

void fpr_esp_fs_mount(void) {
  esp_vfs_fat_mount_config_t cfg = {
      .format_if_mount_failed = true,
      .max_files = FPR_ESP_FS_MAX_FILES,
      .allocation_unit_size = CONFIG_WL_SECTOR_SIZE,
  };
  esp_err_t e = esp_vfs_fat_spiflash_mount_rw_wl("/data", "storage", &cfg, &wl);
  if (e != ESP_OK) {
    printf("[fpr] files: not mounted (%s); file operations will fail\n", esp_err_to_name(e));
    return;
  }
  uint64_t total = 0, avail = 0;
  esp_vfs_fat_info("/data", &total, &avail);
  printf("[fpr] files: /data, FAT on flash, %u of %u KiB free\n", (unsigned)(avail >> 10), (unsigned)(total >> 10));
}
