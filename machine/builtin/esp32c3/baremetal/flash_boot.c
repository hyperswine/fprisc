#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))
enum {
    SYSTEM_CLOCK_ENABLE = 0x600c0010, SYSTEM_RESET_ENABLE = 0x600c0018,
    USB_CLOCK = 1u << 23, TIMER_CLOCK = 1u << 29,
    TIMER_CONFIG = 0x60023000, UNIT0_RUN = 1u << 30, UNIT0_STALL = 1u << 28,
    USB_CONFIG = 0x60043018, USB_PAD_ENABLE = 1u << 14, USB_PULL_OVERRIDE = 1u << 8,
    RTC_WDT_CONFIG = 0x60008090, RTC_WDT_PROTECT = 0x600080a8,
    WDT_KEY = 0x50d83aa1u, WDT_ENABLE = 1u << 31
};

/* The installed second-stage bootloader handles system clocks, SPI flash,
 * cache, and the super watchdog before handing off to this image. */
void c3_flash_init(void) {
    REG(SYSTEM_CLOCK_ENABLE) |= USB_CLOCK | TIMER_CLOCK;
    REG(SYSTEM_RESET_ENABLE) &= ~(USB_CLOCK | TIMER_CLOCK);
    REG(TIMER_CONFIG) = (REG(TIMER_CONFIG) & ~UNIT0_STALL) | UNIT0_RUN;
    REG(USB_CONFIG) = (REG(USB_CONFIG) & ~USB_PULL_OVERRIDE) | USB_PAD_ENABLE;
    REG(RTC_WDT_PROTECT) = WDT_KEY;
    REG(RTC_WDT_CONFIG) &= ~WDT_ENABLE;
    REG(RTC_WDT_PROTECT) = 0;
}

/* ESP application descriptor consumed by the existing bootloader and OTA
 * tools. The 256-byte format reserves the fields we do not populate. */
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
    .project = "fprisc-c3-" C3_EXAMPLE,
    .framework = "fp-risc-builtin",
    .max_efuse_revision = UINT16_MAX,
};
