#include "flash.h"
#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))
/* The existing ROM and second-stage bootloader set up SPI flash and caches.
   The Builtin program takes over the boot watchdog when it enters SRAM. */
void p4_flash_init(void) {
    enum { RTC_WDT = 0x50116000, PROTECT = RTC_WDT + 0x18 };
    REG(PROTECT) = 0x50d83aa1;
    REG(RTC_WDT) &= ~(1u << 31);
    REG(PROTECT) = 0;
}

struct app_descriptor {
    uint32_t magic, secure_version, reserved[2];
    char version[32], project[32], time[16], date[16], framework[32];
    uint8_t elf_sha256[32];
    uint16_t min_efuse_revision, max_efuse_revision;
    uint32_t reserved_tail[19];
};
_Static_assert(sizeof(struct app_descriptor) == 256, "ESP image descriptor layout");
__attribute__((section(".appdesc"), used))
static const struct app_descriptor descriptor = {
    .magic = 0xabcd5432u,
    .version = "1",
    .project = "fprisc-p4-journal-check",
    .framework = "fp-risc-builtin",
    .max_efuse_revision = UINT16_MAX,
};
