/* Test-only SPI SDHC model. The production HAL talks to these same four
 * registers under FPR_SD_HAL_TEST. All media are explicit regular files;
 * this model never opens a physical disk or an FPGA connection. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static FILE *media;
static const char *fault, *log_path;
static uint32_t blocks, control, command_arg, last_byte = 255;
static unsigned initialized, idle = 1, application, crc_enabled, match_inspected;
static unsigned command_count[64], read_count, write_count, crc_errors;
static unsigned deselected_clocks, commands_before_clock_train;
static unsigned selected, command_at, reply_at, reply_len;
static unsigned write_state, write_at, write_crc_at, write_crc;
static unsigned busy_remaining;
static uint32_t write_block, written[4096];
static unsigned char command_bytes[6], reply[1024], write_data[512];

static int is_fault(const char *name) { return strcmp(fault, name) == 0; }

static void die(const char *why) {
  fprintf(stderr, "SD model: %s\n", why);
  exit(90);
}

static uint16_t crc16(const unsigned char *p, unsigned n) {
  uint16_t crc = 0;
  while (n--) {
    crc ^= (uint16_t)*p++ << 8;
    for (unsigned bit = 0; bit < 8; ++bit)
      crc = (uint16_t)((crc << 1) ^ ((crc & 0x8000) ? 0x1021 : 0));
  }
  return crc;
}

static unsigned crc7(const unsigned char *p, unsigned n) {
  unsigned crc = 0;
  while (n--) {
    unsigned v = *p++;
    for (unsigned bit = 0; bit < 8; ++bit) {
      crc <<= 1;
      if (((v ^ crc) & 0x80) != 0) crc ^= 9;
      v <<= 1;
    }
  }
  return ((crc & 127) << 1) | 1;
}

static void save_log(void) {
  if (!log_path || !*log_path) return;
  FILE *out = fopen(log_path, "w");
  if (!out) return;
  fprintf(out, "{\"blocks\":%u,\"reads\":%u,\"writes\":%u,\"crc_errors\":%u,"
               "\"commands_before_clock_train\":%u,\"commands\":{",
          blocks, read_count, write_count, crc_errors, commands_before_clock_train);
  unsigned comma = 0;
  for (unsigned i = 0; i < 64; ++i) {
    if (!command_count[i]) continue;
    fprintf(out, "%s\"%u\":%u", comma++ ? "," : "", i, command_count[i]);
  }
  fputs("},\"written_blocks\":[", out);
  for (unsigned i = 0; i < write_count && i < 4096; ++i)
    fprintf(out, "%s%u", i ? "," : "", written[i]);
  fputs("]}\n", out);
  fclose(out);
  if (media) fclose(media);
  media = NULL;
}

static void init(void) {
  if (initialized) return;
  initialized = 1;
  fault = getenv("FPR_SD_FAULT");
  if (!fault) fault = "none";
  log_path = getenv("FPR_SD_MODEL_LOG");
  const char *path = getenv("FPR_SD_IMAGE");
  if (!path || !*path) die("FPR_SD_IMAGE must name a disposable test image");
  struct stat st;
  if (stat(path, &st) || !S_ISREG(st.st_mode) || st.st_size < 1024 * 512 ||
      st.st_size % (1024 * 512) || (uint64_t)st.st_size / 512 > UINT32_MAX || sizeof(long) < 8)
    die("media must be a regular image with whole 512KiB units and uint32 sector count, on a 64-bit host");
  blocks = (uint32_t)(st.st_size / 512);
  const char *match = getenv("FPR_SD_MATCH_INSPECTED");
  match_inspected = match && strcmp(match, "1") == 0 && blocks == 122152960;
  media = fopen(path, "r+b");
  if (!media) die("cannot open image");
  atexit(save_log);
}

static void enqueue(unsigned v) {
  if (reply_len >= sizeof(reply)) die("reply overflow");
  reply[reply_len++] = (unsigned char)v;
}

static void data_reply(const unsigned char *p, unsigned n, int sector) {
  enqueue(0);
  enqueue(255);
  if (sector && is_fault("read-timeout")) return;
  if (sector && is_fault("read-token")) { enqueue(13); return; }
  enqueue(254);
  for (unsigned i = 0; i < n; ++i) enqueue(p[i]);
  uint16_t crc = crc16(p, n);
  if (sector && is_fault("read-crc")) crc ^= 1;
  enqueue(crc >> 8);
  enqueue(crc & 255);
}

static void read_sector(uint32_t block, unsigned char *p) {
  if (block >= blocks) die("model read beyond card capacity");
  if (fseek(media, (long)block * 512, SEEK_SET) || fread(p, 1, 512, media) != 512)
    die("image read failed");
}

static void handle_command(void) {
  unsigned cmd = command_bytes[0] & 63;
  ++command_count[cmd];
  command_arg = ((uint32_t)command_bytes[1] << 24) |
                ((uint32_t)command_bytes[2] << 16) |
                ((uint32_t)command_bytes[3] << 8) | command_bytes[4];
  reply_at = reply_len = 0;
  if (deselected_clocks < 74) ++commands_before_clock_train;
  if ((cmd == 0 || cmd == 8 || crc_enabled) && command_bytes[5] != crc7(command_bytes, 5)) {
    ++crc_errors; enqueue((idle ? 1 : 0) | 8); return;
  }
  unsigned was_application = application;
  application = 0;
  switch (cmd) {
  case 0: idle = 1; crc_enabled = 0; enqueue(1); break;
  case 8:
    enqueue(1); enqueue(0); enqueue(0); enqueue(1);
    enqueue(is_fault("cmd8") ? 0xab : 0xaa); break;
  case 55: application = 1; enqueue(idle ? 1 : 0); break;
  case 41:
    if (!was_application) { enqueue(5); break; }
    if (!is_fault("init-timeout")) idle = 0;
    enqueue(idle ? 1 : 0); break;
  case 58:
    enqueue(idle ? 1 : 0); enqueue(0xc0); enqueue(0xff); enqueue(0x80); enqueue(0); break;
  case 59: crc_enabled = command_arg & 1; enqueue(idle ? 1 : 0); break;
  case 16: enqueue(command_arg == 512 ? 0 : 64); break;
  case 9: {
    unsigned char csd[16] = {0};
    uint32_t csize = blocks / 1024 - 1;
    csd[0] = 0x40; csd[5] = 9;
    csd[7] = (unsigned char)((csize >> 16) & 63);
    csd[8] = (unsigned char)(csize >> 8); csd[9] = (unsigned char)csize;
    csd[15] = 1;
    if (match_inspected) {
      const unsigned char inspected[16] = {0x40, 0x0e, 0x00, 0x32, 0x5b, 0x59, 0x00, 0x01,
                                            0xd1, 0xf9, 0x7f, 0x80, 0x0a, 0x40, 0x40, 0x01};
      memcpy(csd, inspected, 16);
    }
    data_reply(csd, sizeof(csd), 0); break;
  }
  case 10: {
    const unsigned char cid[16] = {0x42, 'F', 'P', 'F', 'P', 'R', 'S', 'D', 0x10, 1, 2, 3, 4, 1, 0xa1, 1};
    const unsigned char inspected[16] = {0x6f, 0x03, 0x03, 0x53, 0x44, 0x41, 0x42, 0x43,
                                         0x10, 0xaa, 0x00, 0x01, 0xa1, 0x01, 0x81, 0x01};
    data_reply(match_inspected ? inspected : cid, sizeof(cid), 0); break;
  }
  case 17: {
    if (command_arg >= blocks) { enqueue(32); break; }
    unsigned char p[512]; read_sector(command_arg, p); ++read_count;
    data_reply(p, 512, 1); break;
  }
  case 24:
    if (command_arg >= blocks) { enqueue(32); break; }
    write_block = command_arg; write_state = 1; write_at = write_crc_at = write_crc = 0;
    enqueue(0); break;
  case 13: enqueue(0); enqueue(is_fault("status") ? 0x20 : 0); break;
  default: enqueue((idle ? 1 : 0) | 4); break;
  }
}

static unsigned transfer(unsigned out) {
  if (!selected) { deselected_clocks += 8; return 255; }
  if (reply_at < reply_len) return reply[reply_at++];
  reply_at = reply_len = 0;
  if (busy_remaining) {
    if (!is_fault("write-busy")) --busy_remaining;
    return 0;
  }
  if (write_state == 1) {
    if (out == 254) write_state = 2;
    return 255;
  }
  if (write_state == 2) {
    write_data[write_at++] = (unsigned char)out;
    if (write_at == 512) write_state = 3;
    return 255;
  }
  if (write_state == 3) {
    write_crc = (write_crc << 8) | out;
    if (++write_crc_at == 2) {
      unsigned expected = crc16(write_data, 512);
      int bad_crc = expected != write_crc;
      if (bad_crc) ++crc_errors;
      if (is_fault("write-reject")) enqueue(13);
      else if (bad_crc) enqueue(11);
      else {
        if (fseek(media, (long)write_block * 512, SEEK_SET) ||
            fwrite(write_data, 1, 512, media) != 512 || fflush(media)) die("image write failed");
        if (write_count < 4096) written[write_count] = write_block;
        ++write_count;
        enqueue(5); busy_remaining = 3;
      }
      write_state = 0;
    }
    return 255;
  }
  if (!command_at && (out & 0xc0) != 0x40) return 255;
  command_bytes[command_at++] = (unsigned char)out;
  if (command_at == 6) { command_at = 0; handle_command(); }
  return 255;
}

uint32_t fpr_sd_hal_test_read(unsigned reg) {
  init();
  switch (reg) {
  case 0: return last_byte;
  case 1: return is_fault("spi-timeout") ? 1 : 0;
  case 2: return control;
  case 3: return is_fault("missing") ? 0 : 0x53445031u;
  default: die("invalid register read"); return 0;
  }
}

void fpr_sd_hal_test_write(unsigned reg, uint32_t value) {
  init();
  switch (reg) {
  case 0: last_byte = transfer(value & 255); break;
  case 2:
    control = value;
    if (!(value & 1)) {
      selected = command_at = reply_at = reply_len = write_state = 0;
    } else selected = 1;
    break;
  default: die("invalid register write");
  }
}
