#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "esp_spiffs.h"
#include "esp_rom_crc.h"
#include "esp_flash.h"
#include "esp_idf_version.h"
#include "esp_partition.h"

#include "bytes.h"

#define MOUNT_DIR "/fpr"
static bool mounted;

/* Format only new, erased storage. Never format a failed existing mount. */
static int is_erased(const esp_partition_t *part) {
    uint8_t block[256];
    for (size_t at = 0; at < part->size; at += sizeof(block)) {
        esp_err_t err = esp_partition_read(part, at, block, sizeof(block));
        if (err != ESP_OK) {
            printf("flash read at 0x%lx failed: %s\n", (unsigned long)(part->address + at), esp_err_to_name(err));
            fflush(stdout);
            return -EIO;
        }
        for (size_t i = 0; i < sizeof(block); i++)
            if (block[i] != 0xff) return 0;
    }
    return 1;
}

static V mount_files(V unit) {
    if (mounted) return TAG(0);
    const esp_partition_t *part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, FPR_FLASH_LABEL);
    if (!part) return TAG(-ENODEV);
#if CONFIG_APP_BUILD_TYPE_RAM && CONFIG_ESPTOOLPY_FLASHSIZE_4MB && ESP_IDF_VERSION == ESP_IDF_VERSION_VAL(5, 3, 2)
    /* IDF 5.3.2 C3 RAM startup fabricates a 2 MiB boot header even when the
     * build selects 4 MiB. Its flash driver enforces that header for reads.
     * Extend only as far as this partition and only after probing the chip. */
    uint32_t limit, physical;
    if (esp_flash_get_size(NULL, &limit) != ESP_OK) return TAG(-EIO);
    if (part->address > UINT32_MAX - part->size) return TAG(-EINVAL);
    uint32_t end = part->address + part->size;
    if (end > limit) {
        if (limit != 2 * 1024 * 1024 || end > 4 * 1024 * 1024 ||
            esp_flash_get_physical_size(NULL, &physical) != ESP_OK || end > physical)
            return TAG(-EFBIG);
        esp_flash_default_chip->size = end;
    }
#endif
    int erased = is_erased(part);
    if (erased < 0) return TAG(erased);
    esp_vfs_spiffs_conf_t config = {
        .base_path = MOUNT_DIR, .partition_label = FPR_FLASH_LABEL, .max_files = 4,
        .format_if_mount_failed = erased == 1
    };
    esp_err_t err = esp_vfs_spiffs_register(&config);
    if (err != ESP_OK) {
        printf("SPIFFS mount %s failed: %s (erased=%d)\n", FPR_FLASH_LABEL, esp_err_to_name(err), erased);
        fflush(stdout);
        return TAG(-EIO);
    }
    mounted = true;
    return TAG(0);
}

static V open_file(V name, int flags) {
    if (!mounted) return TAG(-ENODEV);
    if (!ISPTR(name) || TID(name) != T_STR) return TAG(-EINVAL);
    const str_t *s = (const str_t *)name;
    char path[sizeof(MOUNT_DIR "/") + CONFIG_SPIFFS_OBJ_NAME_LEN];
    if (s->len > CONFIG_SPIFFS_OBJ_NAME_LEN - 2) return TAG(-ENAMETOOLONG);
    if (!s->len || s->bytes[0] == '.' ||
        memchr(s->bytes, '/', s->len) || memchr(s->bytes, '\\', s->len) ||
        memchr(s->bytes, 0, s->len)) return TAG(-EINVAL);
    memcpy(path, MOUNT_DIR "/", sizeof(MOUNT_DIR));
    memcpy(path + sizeof(MOUNT_DIR), s->bytes, s->len);
    path[sizeof(MOUNT_DIR) + s->len] = 0;
    int fd = open(path, flags, 0600);
    return TAG(fd < 0 ? -errno : fd);
}
static V open_read(V name) { return open_file(name, O_RDONLY); }
static V create_new(V name) { return open_file(name, O_WRONLY | O_CREAT | O_EXCL); }
static V open_append(V name) { return open_file(name, O_WRONLY | O_CREAT | O_APPEND); }

static V flush_file(V fd) {
    if (!ISINT(fd) || UNTAG(fd) < 0) return TAG(-EBADF);
#if CONFIG_SPIFFS_CACHE_WR
    /* IDF 5.3.2's SPIFFS VFS lacks fsync. Neither fstat nor lseek
     * propagates a write-cache flush failure. Never acknowledge one. */
    return TAG(-ENOTSUP);
#else
    /* Writes reach SPIFFS synchronously. Check the still-open descriptor. */
    struct stat st;
    return TAG(fstat(UNTAG(fd), &st) < 0 ? -errno : 0);
#endif
}
static V file_io(V fd, V p, V count, bool writing) {
    if (!ISINT(fd) || UNTAG(fd) < 0 || !ISINT(count) || UNTAG(count) < 0) return TAG(-EINVAL);
    void *buf = buffer_ptr(p);
    if (!buf && UNTAG(count)) return TAG(-EINVAL);
    ssize_t n = writing ? write(UNTAG(fd), buf, UNTAG(count)) : read(UNTAG(fd), buf, UNTAG(count));
    return TAG(n < 0 ? -errno : n);
}
static V read_file(V fd, V p, V n) { return file_io(fd, p, n, false); }
static V write_file(V fd, V p, V n) { return file_io(fd, p, n, true); }
static V close_file(V fd) {
    if (!ISINT(fd) || UNTAG(fd) < 0) return TAG(-EBADF);
    return TAG(close(UNTAG(fd)) < 0 ? -errno : 0);
}
FPR_FN(fpr_g_EspFile_x2emount, mount_files, 1);
FPR_FN(fpr_g_EspFile_x2ecreate, create_new, 1);
FPR_FN(fpr_g_EspFile_x2eopen, open_read, 1);
FPR_FN(fpr_g_EspFile_x2eread, read_file, 3);
FPR_FN(fpr_g_EspFile_x2ewrite, write_file, 3);
FPR_FN(fpr_g_EspFile_x2eclose, close_file, 1);
FPR_FN(fpr_g_EspFile_x2eappend, open_append, 1);
FPR_FN(fpr_g_EspFile_x2eflush, flush_file, 1);

/* One fixed-size record: version tag, length, padded payload, then CRC32.
 * Encode/decode in the caller's 72-byte workspace. A partial final write
 * cannot be mistaken for a shorter valid record. */
static V pack_record(V addr, V length) {
    if (!ISINT(length) || UNTAG(length) < 1 || UNTAG(length) > 64) return TAG(-EINVAL);
    unsigned n = UNTAG(length);
    uint8_t *b = buffer_ptr(addr);
    memmove(b + 4, b, n);
    b[0] = 'F'; b[1] = 'J'; b[2] = 1; b[3] = n;
    memset(b + 4 + n, 0, 64 - n);
    uint32_t crc = esp_rom_crc32_le(0, b, 68);
    memcpy(b + 68, &crc, sizeof(crc));
    return TAG(72);
}

static V unpack_record(V addr) {
    uint8_t *b = buffer_ptr(addr);
    uint32_t stored;
    memcpy(&stored, b + 68, sizeof(stored));
    unsigned n = b[3];
    if (b[0] != 'F' || b[1] != 'J' || b[2] != 1 || n < 1 || n > 64 ||
        stored != esp_rom_crc32_le(0, b, 68)) return TAG(-EBADMSG);
    memmove(b, b + 4, n);
    return TAG(n);
}
FPR_FN(fpr_g_EspRecord_x2epack, pack_record, 2);
FPR_FN(fpr_g_EspRecord_x2eunpack, unpack_record, 1);
