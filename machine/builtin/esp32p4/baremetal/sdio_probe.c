#include <stdbool.h>
#include <errno.h>
#include "hci.h"
#include "platform.h"
#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(uintptr_t)(address))
#define BIT(n) (UINT32_C(1) << (n))
enum {
    GPIO = 0x500e0000, IOMUX = 0x500e1000, GPIO_IN = GPIO + 0x158,
    GPIO_OUT = GPIO + 0x558, CLKRST = 0x500e6000, LP_RESET = 0x5011104c,
    SD = 0x50083000, CTRL = SD, DIV = SD + 8, SOURCE = SD + 12,
    CLOCK = SD + 16, TIMEOUT = SD + 20, WIDTH = SD + 24, IMASK = SD + 36,
    ARG = SD + 40, CMD = SD + 44, RESP = SD + 48, RAW = SD + 68,
    SLOT1 = BIT(16), SHORT_RESPONSE = BIT(6), CHECK_CRC = BIT(8),
    WAIT_DATA = BIT(13), INIT_CLOCKS = BIT(15), CLOCK_ONLY = BIT(21),
    COMMAND_DONE = BIT(2), RESPONSE_ERRORS = BIT(1) | BIT(6) | BIT(8) | BIT(12),
};
#define START BIT(31)
#define CARD_READY BIT(31)

static void delay(unsigned us) {
    ((void (*)(uint32_t))(uintptr_t)0x4fc0003c)(us);
}

extern void p4_puts(const char *);
extern void p4_hex(uint32_t);

static bool wait_clear(uint32_t address, uint32_t mask) {
    for (unsigned i = 0; i < 10000; ++i) {
        if (!(REG(address) & mask)) return true;
        delay(10);
    }
    return false;
}

static void pin(unsigned io, unsigned signal, bool input) {
    uint32_t pad = IOMUX + (io + 1) * 4;
    REG(pad) = (REG(pad) & ~(7u << 12)) | BIT(12) | (input ? BIT(8) | BIT(9) : 0);
    REG(GPIO + 0x24) = BIT(io);
    REG(GPIO_OUT + io * 4) = signal;
    if (input) REG(GPIO_IN + signal * 4) = BIT(7) | io;
}

static bool update_clock(void) {
    REG(CMD) = START | SLOT1 | WAIT_DATA | CLOCK_ONLY;
    return wait_clear(CMD, START);
}

static int init_host(void) {
    pin(18, 0, false);
    pin(19, 1, true);
    for (unsigned lane = 0; lane < 4; ++lane) pin(14 + lane, 2 + lane, true);
    REG((CLKRST + 0x18)) |= BIT(14);
    REG(LP_RESET) |= BIT(28);
    REG(LP_RESET) &= ~BIT(28);
    REG((CLKRST + 0x18) + 0x1c) =
        (REG((CLKRST + 0x18) + 0x1c) & ~BIT(23)) | BIT(24);
    /* PLL160M / 2, then controller divider 100 gives 400 kHz. */
    uint32_t edges = REG((CLKRST + 0x18) + 0x20) & ~((0xfffu << 9) | BIT(8));
    edges |= BIT(9) | BIT(17) | BIT(23) | BIT(27) | BIT(28) | BIT(29);
    REG((CLKRST + 0x18) + 0x20) = edges;
    REG((CLKRST + 0x18) + 0x20) = edges | BIT(8);
    REG((CLKRST + 0x18) + 0x20) = edges;

    REG(CTRL) = 7;
    if (!wait_clear(CTRL, 7)) return 1;
    REG(IMASK) = 0;
    REG(RAW) = UINT32_MAX;
    REG(TIMEOUT) = UINT32_MAX;
    REG(WIDTH) = 0;
    REG(CLOCK) = 0;
    if (!update_clock()) return 2;
    /* CLKSRC selects which of the controller dividers serves each slot. */
    REG(SOURCE) = 1u << 2;
    REG(DIV) = 100u << 8;
    if (!update_clock()) return 3;
    REG(CLOCK) = BIT(1);
    return update_clock() ? 0 : 4;
}

static bool command(unsigned index, uint32_t arg, uint32_t flags, uint32_t *response) {
    REG(RAW) = UINT32_MAX;
    REG(ARG) = arg;
    REG(CMD) = START | SLOT1 | flags | index;
    for (unsigned i = 0; i < 10000; ++i) {
        uint32_t status = REG(RAW);
        if (status & RESPONSE_ERRORS) return false;
        if (status & COMMAND_DONE) {
            if (response) *response = REG(RESP);
            return true;
        }
        delay(10);
    }
    return false;
}

static bool read_direct(unsigned address, uint32_t *response) {
    return command(52, address << 9, SHORT_RESPONSE | CHECK_CRC | WAIT_DATA, response) &&
           !(*response & 0xcb00u);
}

static void line(const char *label, uint32_t value) {
    p4_puts(label);
    p4_hex(value);
    p4_puts("\n");
}

enum {
    BLKSIZ = SD + 0x1c, BYTCNT = SD + 0x20, STATUS = SD + 0x48,
    DATA_EXPECTED = BIT(9), WRITE_DATA = BIT(10), TRANSFER_OVER = BIT(3),
    DATA_ERRORS = BIT(7) | BIT(9) | BIT(10) | BIT(11) | BIT(12) | BIT(13) | BIT(15),
    SDIO_FN1 = BIT(28), INCREMENT = BIT(26),
    TOKEN = 0x44, PACKET_LEN = 0x60, OPEN_PATH = 0x8c, PACKET_END = 0x1f800,
    HOSTED_HEADER = 12, IF_HCI = 4, IF_PRIVATE = 5
};

static bool enable_function(void) {
    uint32_t response;
    uint32_t enable = START | (2u << 9) | 2u;
    if (!command(52, enable, SHORT_RESPONSE | CHECK_CRC | WAIT_DATA, &response) ||
        (response & 0xcb00u)) return false;
    for (unsigned i = 0; i < 100; ++i) {
        if (!read_direct(3, &response)) return false;
        if (response & 2) return true;
        delay(10000);
    }
    return false;
}

static _Alignas(64) volatile uint32_t dma_desc[16];
static _Alignas(64) volatile uint8_t dma_data[512];

/* ESP32-P4 ROM cache API. SDMMC's DMA accesses internal SRAM directly. */
typedef int (*CacheRange)(uint32_t cache_mask, uint32_t address, uint32_t bytes);
enum { DCACHE_AND_L2 = BIT(4) | BIT(5), CACHE_WB = 0x4fc003f4, CACHE_INV = 0x4fc003e4 };

static void sync_dma(uintptr_t operation) {
    CacheRange sync = (CacheRange)operation;
    sync(DCACHE_AND_L2, (uintptr_t)dma_desc, sizeof(dma_desc));
    sync(DCACHE_AND_L2, (uintptr_t)dma_data, sizeof(dma_data));
}

static bool transfer(bool write, unsigned address, uint8_t *bytes, unsigned size) {
    enum { BMOD = SD + 0x80, POLL = SD + 0x84, DESC = SD + 0x88, IDSTS = SD + 0x8c };
    if (!size || size > sizeof(dma_data)) return false;
    REG(CTRL) |= BIT(1) | BIT(2);
    if (!wait_clear(CTRL, BIT(1) | BIT(2))) return false;
    REG(BMOD) = 1;
    if (!wait_clear(BMOD, 1)) return false;
    for (unsigned i = 0; i < size; ++i) dma_data[i] = write ? bytes[i] : 0;
    dma_desc[0] = START | BIT(4) | BIT(3) | BIT(2);
    dma_desc[1] = size;
    dma_desc[2] = (uintptr_t)dma_data;
    dma_desc[3] = 0;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    sync_dma(CACHE_WB);
    /* Request DMA with one word in the RX FIFO, including short byte transfers. */
    REG(SD + 0x4c) = 1;
    REG(BLKSIZ) = size;
    REG(BYTCNT) = size;
    REG(IDSTS) = UINT32_MAX;
    REG(SD + 0x90) = 0x337;
    REG(DESC) = (uintptr_t)dma_desc;
    REG(CTRL) |= BIT(5) | BIT(25);
    REG(BMOD) = BIT(7) | BIT(1);
    REG(POLL) = 1;
    uint32_t arg = SDIO_FN1 | INCREMENT | (address << 9) | (size & 0x1ffu);
    uint32_t flags = SHORT_RESPONSE | CHECK_CRC | WAIT_DATA | DATA_EXPECTED;
    if (write) {
        arg |= START;
        flags |= WRITE_DATA;
    }
    uint32_t response;
    if (!command(53, arg, flags, &response) || (response & 0xcb00u)) return false;
    for (unsigned i = 0; i < 30000; ++i) {
        uint32_t dma = REG(IDSTS), raw = REG(RAW);
        if ((raw & DATA_ERRORS) || (dma & (BIT(2) | BIT(4) | BIT(5)))) break;
        if ((raw & TRANSFER_OVER) && !(dma & (15u << 13))) {
            sync_dma(CACHE_INV);
        }
        if ((raw & TRANSFER_OVER) && !(dma_desc[0] & START)) {
            __asm__ volatile("fence iorw, iorw" ::: "memory");
            if (!write) for (unsigned j = 0; j < size; ++j) bytes[j] = dma_data[j];
            return true;
        }
        delay(10);
    }
    line("P4 SDIO DMA status ", REG(IDSTS));
    line("P4 SDIO descriptor status ", dma_desc[0]);
    line("P4 SDIO CTRL ", REG(CTRL));
    line("P4 SDIO STATUS ", REG(STATUS));
    line("P4 SDIO TCBCNT ", REG(SD + 0x5c));
    line("P4 SDIO TBBCNT ", REG(SD + 0x60));
    line("P4 SDIO curr desc ", REG(SD + 0x94));
    line("P4 SDIO curr buf ", REG(SD + 0x98));
    return false;
}

static bool read_register(unsigned address, uint32_t *value) {
    *value = 0;
    for (unsigned i = 0; i < 4; ++i) {
        uint32_t response;
        uint32_t arg = SDIO_FN1 | ((address + i) << 9);
        if (!command(52, arg, SHORT_RESPONSE | CHECK_CRC | WAIT_DATA, &response) ||
            (response & 0xcb00u)) return false;
        *value |= (response & 255u) << (8 * i);
    }
    return true;
}

static bool open_data_path(void) {
    uint32_t arg = START | SDIO_FN1 | (OPEN_PATH << 9) | 1u;
    uint32_t response;
    return command(52, arg, SHORT_RESPONSE | CHECK_CRC | WAIT_DATA, &response) &&
           !(response & 0xcb00u);
}

static bool receive_packet(uint8_t *bytes, unsigned *count, unsigned *read_count) {
    uint32_t published;
    if (!read_register(PACKET_LEN, &published)) return false;
    unsigned pending = (published - *read_count) & 0xfffffu;
    *count = pending;
    if (!pending) return true;
    line("P4 SDIO RX bytes ", pending);
    if (pending > 512 ||
        !transfer(false, PACKET_END - pending, bytes, (pending + 3u) & ~3u)) {
        line("P4 SDIO RX status ", REG(RAW));
        return false;
    }
    *read_count = published & 0xfffffu;
    return true;
}

static bool identify_companion(const uint8_t *packet, unsigned count) {
    if (count < HOSTED_HEADER + 2 || (packet[0] & 15) != IF_PRIVATE ||
        packet[11] != 0x33 || packet[HOSTED_HEADER] != 0x22 ||
        packet[4] != HOSTED_HEADER || packet[5] != 0) return false;
    unsigned payload = packet[2] | (packet[3] << 8);
    unsigned tlv_end = HOSTED_HEADER + 2u + packet[HOSTED_HEADER + 1];
    if (payload < 2 || payload > count - HOSTED_HEADER ||
        tlv_end > HOSTED_HEADER + payload) return false;
    for (unsigned i = HOSTED_HEADER + 2; i + 2 <= tlv_end;) {
        unsigned tag = packet[i++];
        unsigned len = packet[i++];
        if (len > tlv_end - i) return false;
        if (tag == 0x12 && len == 1) {
            line("P4 SDIO companion chip ID ", packet[i]);
            return packet[i] == 0x0d;  /* ESP-Hosted's ESP32-C6 chip ID. */
        }
        i += len;
    }
    return false;
}

static unsigned read_count, write_count;
static bool linked;

static bool startup_frame(void) {
    if (!enable_function() || !open_data_path()) {
        line("P4 SDIO function or data path status ", REG(RAW));
        return false;
    }
    unsigned count;
    uint8_t bytes[512];
    for (unsigned tries = 0; tries < 50; ++tries) {
        delay(20000);
        if (!receive_packet(bytes, &count, &read_count)) return false;
        if (count) return identify_companion(bytes, count);
    }
    p4_puts("P4 SDIO expected ESP32-C6 startup frame\n");
    return false;
}

/* Command type is in the host TX header and in the companion RX payload. */
int p4_sdio_hci(unsigned step, const uint8_t *command_packet, unsigned command_size) {
    if (!linked || command_size < 4 || command_size > C3_HCI_MAX_COMMAND) return -EINVAL;
    uint32_t token;
    bool ready = false;
    for (unsigned tries = 0; tries < 50; ++tries) {
        if (!read_register(TOKEN, &token)) return -EIO;
        unsigned available = ((token >> 16) - write_count) & 0xfffu;
        if (available && available <= 0x7ffu) {
            ready = true;
            break;
        }
        delay(2000);
    }
    if (!ready) return -ETIMEDOUT;
    unsigned payload = command_size - 1;
    unsigned size = HOSTED_HEADER + payload;
    uint8_t frame[HOSTED_HEADER + C3_HCI_MAX_COMMAND + 3] = {IF_HCI, 0};
    frame[2] = payload;
    frame[4] = HOSTED_HEADER;
    frame[11] = command_packet[0];
    for (unsigned i = 0; i < payload; ++i) frame[HOSTED_HEADER + i] = command_packet[i + 1];
    if (!transfer(true, PACKET_END - size, frame, (size + 3u) & ~3u)) {
        line("P4 SDIO HCI TX status ", REG(RAW));
        return -EIO;
    }
    write_count = (write_count + 1) & 0xfffu;

    uint8_t bytes[512];
    for (unsigned tries = 0; tries < 150; ++tries) {
        unsigned count;
        if (!receive_packet(bytes, &count, &read_count)) return -EIO;
        for (unsigned at = 0; at + HOSTED_HEADER <= count;) {
            const uint8_t *p = bytes + at;
            unsigned length = p[2] | (p[3] << 8);
            unsigned offset = p[4] | (p[5] << 8);
            if (offset < HOSTED_HEADER || offset > count - at ||
                length > count - at - offset) return -EIO;
            const uint8_t *event = p + offset;
            if ((p[0] & 15) == IF_HCI) {
                int rc = c3_hci_adv_complete(step, event, length);
                if (rc) {
                    if (rc == 1 && step == 0) {
                        p4_puts("P4 HCI RX 04 0e 04 ");
                        p4_hex(event[3]);
                        p4_puts(" 03 0c 00\n");
                    }
                    return rc == 1 ? 0 : rc;
                }
            }
            at += offset + length;
        }
        delay(20000);
    }
    return -ETIMEDOUT;
}

void p4_sdio_pulse_companion_en(void) {
    enum { ENABLE_PIN = 54 };
    uint32_t pad = IOMUX + (ENABLE_PIN + 1) * 4;
    REG(pad) = (REG(pad) & ~(7u << 12)) | BIT(12);
    REG(GPIO_OUT + 4 * ENABLE_PIN) = 256 | BIT(10);
    REG(GPIO + 0x14) = BIT(ENABLE_PIN - 32);
    REG(GPIO + 0x30) = BIT(ENABLE_PIN - 32);
    delay(10000);
    REG(GPIO + 0x18) = BIT(ENABLE_PIN - 32);
    delay(10000);
    REG(GPIO + 0x14) = BIT(ENABLE_PIN - 32);
    delay(1500000);
}

void p4_sdio_reset_companion(void) {
    linked = false;
    p4_sdio_pulse_companion_en();
}

bool p4_sdio_start(void) {
    p4_sdio_reset_companion();
    read_count = write_count = 0;
    int init = init_host();
    if (init) {
        line("P4 SDIO init phase ", init);
        line("P4 SDIO CTRL ", REG(CTRL));
        line("P4 SDIO CMD ", REG(CMD));
        line("P4 SDIO bus clock gate ", REG(CLKRST + 0x18));
        line("P4 SDIO root ", REG(CLKRST + 0x34));
        line("P4 SDIO divider ", REG(CLKRST + 0x38));
        return false;
    }
    if (!command(0, 0, INIT_CLOCKS, 0)) {
        line("P4 SDIO CMD0 status ", REG(RAW));
        return false;
    }
    uint32_t ocr;
    if (!command(5, 0, SHORT_RESPONSE, &ocr)) {
        line("P4 SDIO CMD5 status ", REG(RAW));
        return false;
    }
    line("P4 SDIO OCR ", ocr);
    uint32_t voltage = ocr & 0x00ff8000u;
    for (unsigned tries = 0; tries < 100 && !(ocr & CARD_READY); ++tries) {
        delay(10000);
        if (!command(5, voltage, SHORT_RESPONSE, &ocr)) break;
    }
    if (!(ocr & CARD_READY)) {
        line("P4 SDIO card ready timeout ", ocr);
        return false;
    }
    uint32_t rca, revision;
    if (!command(3, 0, SHORT_RESPONSE | CHECK_CRC, &rca) ||
        !command(7, rca & 0xffff0000u, SHORT_RESPONSE | CHECK_CRC | WAIT_DATA, 0) ||
        !read_direct(0, &revision)) {
        line("P4 SDIO select or CCCR status ", REG(RAW));
        return false;
    }
    line("P4 SDIO CCCR revision ", revision & 0xff);
    linked = startup_frame();
    return linked;
}

bool p4_sdio_ready(void) {
    uint32_t ready;
    return linked && read_direct(3, &ready) && (ready & 2);
}

void p4_sdio_probe(void) {
    const uint8_t reset[] = {1, 3, 0x0c, 0};
    bool passed = p4_sdio_start() && !p4_sdio_hci(0, reset, sizeof(reset));
    p4_puts(passed ? "P4 SDIO HCI Reset Command Complete PASS\n" :
                     "P4 SDIO HCI Reset failed\n");
}
