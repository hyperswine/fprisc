/* board-host: the host side of FP-RISC runs on Simple-Risc boards and in QEMU.
 *
 * machine/tangnano20k/examples.sol builds and drives this; it does the parts
 * Sol cannot: a serial port at a non-standard baud, the boot ROM upload, and
 * the interactive virtual device a running guest calls over its UART.
 *
 *   board-host board IMAGE --port P --mhz M [--settle S] [--isa rv32im|rv32imc]
 *              [--mem-mhz N] [--build-id HEX] [--root DIR] [--timeout S]
 *              [--arg A]... [--input LINE]... [--env NAME=VALUE]...
 *       Query the ROM identity ('I') and check it, upload with 'U' (CRC-32
 *       header and payload), verify with 'C', start with 'G', then serve the
 *       guest's @FPR1 requests until the ROM prints DONE. Guest output goes
 *       to stdout. Exit 0 only for one "FPR EXIT 0" followed by DONE.
 *   board-host qemu ELF [--xlen 32|64] [--root DIR] [--timeout S] [...as above]
 *       The same virtual device for qemu-system-riscvXLEN -machine virt.
 *   board-host dtree TRAIN TEST BINS DEPTH MIN_LEAF [LOG REPEATS]
 *       The classifier's independent reference (libm log2, as the Python
 *       reference used) as JSON; with LOG, also check every run in the guest
 *       log against it and report elapsed times and heap samples.
 *
 * The protocols are Simple-Risc's boards/tangnano20k/rom_protocol.py (SRID1,
 * SRU1) and FP-RISC's UART virtual device (@FPR1 frames, one '+' ACK per
 * reply byte, because the board's receiver holds one byte).
 * Exit status: 0 pass, 1 guest or check failure, 2 usage, 3 timeout.
 */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <IOKit/serial/ioss.h>
#else
#include <asm/termbits.h>
#endif

#define MAX_PAYLOAD (1024 * 1024)
#define MAX_ARGS 256
#define MAX_ARGS_BYTES 65536

static void die(int code, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("board-host: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(code);
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

/* ---- growable byte buffers ---------------------------------------------- */
typedef struct { unsigned char *p; size_t n, cap; } buf_t;
static void buf_add(buf_t *b, const void *data, size_t n) {
  if (b->n + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 256;
    while (b->n + n + 1 > cap) cap *= 2;
    b->p = realloc(b->p, cap);
    if (!b->p) die(1, "out of memory");
    b->cap = cap;
  }
  memcpy(b->p + b->n, data, n);
  b->n += n;
  b->p[b->n] = 0;
}
static void buf_drop(buf_t *b, size_t n) {
  memmove(b->p, b->p + n, b->n - n);
  b->n -= n;
  if (b->p) b->p[b->n] = 0;
}
static int buf_has(const buf_t *b, const char *needle) {
  size_t k = strlen(needle);
  if (b->n < k) return 0;
  for (size_t i = 0; i + k <= b->n; i++)
    if (!memcmp(b->p + i, needle, k)) return 1;
  return 0;
}

/* ---- options shared by board and qemu ----------------------------------- */
typedef struct {
  const char *image, *port, *root, *isa, *build_id;
  double mhz, settle, timeout;
  int mem_mhz, xlen;
  const char *args[MAX_ARGS]; int nargs;
  const char **inputs; int ninputs, next_input;
  const char **env; int nenv;
} opts_t;

static double number(const char *flag, const char *s) {
  char *end;
  double v = strtod(s, &end);
  if (!*s || *end || !isfinite(v) || v < 0) die(2, "%s needs a finite non-negative number, got '%s'", flag, s);
  return v;
}

static void parse_opts(opts_t *o, int argc, char **argv) {
  memset(o, 0, sizeof *o);
  o->root = ".";
  o->timeout = 120;
  o->xlen = 32;
  o->inputs = calloc((size_t)argc + 1, sizeof *o->inputs);
  o->env = calloc((size_t)argc + 1, sizeof *o->env);
  for (int i = 0; i < argc; i++) {
    const char *a = argv[i];
    const char *v = 0;
    const char *eq = strchr(a, '=');
    char flag[64] = {0};
    if (a[0] == '-' && a[1] == '-') {
      size_t n = eq ? (size_t)(eq - a) : strlen(a);
      if (n >= sizeof flag) die(2, "unknown option %s", a);
      memcpy(flag, a, n);
      if (eq) v = eq + 1;
      else if (i + 1 < argc) v = argv[++i];
      else die(2, "%s needs a value", a);
    } else {
      if (o->image) die(2, "unexpected argument %s", a);
      o->image = a;
      continue;
    }
    if (!strcmp(flag, "--port")) o->port = v;
    else if (!strcmp(flag, "--mhz")) o->mhz = number(flag, v);
    else if (!strcmp(flag, "--settle")) o->settle = number(flag, v);
    else if (!strcmp(flag, "--timeout")) o->timeout = number(flag, v);
    else if (!strcmp(flag, "--root")) o->root = v;
    else if (!strcmp(flag, "--isa")) o->isa = v;
    else if (!strcmp(flag, "--build-id")) o->build_id = v;
    else if (!strcmp(flag, "--mem-mhz")) o->mem_mhz = (int)number(flag, v);
    else if (!strcmp(flag, "--xlen")) o->xlen = (int)number(flag, v);
    else if (!strcmp(flag, "--arg")) {
      if (o->nargs == MAX_ARGS) die(2, "at most %d program arguments", MAX_ARGS);
      o->args[o->nargs++] = v;
    } else if (!strcmp(flag, "--input")) o->inputs[o->ninputs++] = v;
    else if (!strcmp(flag, "--env")) {
      if (!strchr(v, '=') || v[0] == '=') die(2, "--env requires a nonempty NAME=VALUE");
      o->env[o->nenv++] = v;
    } else die(2, "unknown option %s", flag);
  }
  if (!o->image) die(2, "an image is required");
  if (o->timeout <= 0) die(2, "--timeout must be positive");
  if (o->xlen != 32 && o->xlen != 64) die(2, "--xlen must be 32 or 64");
}

/* ---- the virtual device ------------------------------------------------- */
static buf_t encoded_args(const opts_t *o) {
  buf_t b = {0};
  uint32_t n = (uint32_t)o->nargs;
  unsigned char le[4] = {n, n >> 8, n >> 16, n >> 24};
  buf_add(&b, le, 4);
  for (int i = 0; i < o->nargs; i++) {
    uint32_t len = (uint32_t)strlen(o->args[i]);
    if (len > MAX_ARGS_BYTES - b.n - 4) die(2, "program arguments exceed %d encoded bytes", MAX_ARGS_BYTES);
    unsigned char l[4] = {len, len >> 8, len >> 16, len >> 24};
    buf_add(&b, l, 4);
    buf_add(&b, o->args[i], len);
  }
  return b;
}

/* A request path is relative, has no NUL, and stays inside the root both
 * lexically and after following symlinks of whatever already exists. */
static int device_path(const opts_t *o, const unsigned char *data, size_t n, char *out, size_t cap,
                       const char **why) {
  char root[PATH_MAX];
  if (!realpath(o->root, root)) { *why = "virtual root is missing"; return 0; }
  if (n == 0 || memchr(data, 0, n) || data[0] == '/') { *why = "virtual path must be relative"; return 0; }
  char rel[PATH_MAX];
  if (n >= sizeof rel) { *why = "virtual path too long"; return 0; }
  memcpy(rel, data, n);
  rel[n] = 0;
  char norm[PATH_MAX] = "";
  size_t depth = 0, len = 0;
  size_t marks[PATH_MAX / 2];
  for (char *save = 0, *part = strtok_r(rel, "/", &save); part; part = strtok_r(0, "/", &save)) {
    if (!strcmp(part, ".")) continue;
    if (!strcmp(part, "..")) {
      if (!depth) { *why = "virtual path escapes root"; return 0; }
      len = marks[--depth];
      norm[len] = 0;
      continue;
    }
    marks[depth++] = len;
    len += (size_t)snprintf(norm + len, sizeof norm - len, "/%s", part);
    if (len >= sizeof norm) { *why = "virtual path too long"; return 0; }
  }
  if (snprintf(out, cap, "%s%s", root, norm) >= (int)cap) { *why = "virtual path too long"; return 0; }
  /* follow symlinks of the deepest existing ancestor */
  char probe[PATH_MAX], real[PATH_MAX];
  snprintf(probe, sizeof probe, "%s", out);
  for (;;) {
    if (realpath(probe, real)) {
      size_t r = strlen(root);
      if (strncmp(real, root, r) || (real[r] && real[r] != '/')) { *why = "virtual path escapes root"; return 0; }
      return 1;
    }
    char *slash = strrchr(probe, '/');
    if (!slash || slash == probe) return 1;
    *slash = 0;
  }
}

static int dispatch(opts_t *o, int op, const unsigned char *data, size_t n, buf_t *reply) {
  char path[PATH_MAX];
  const char *why = 0;
  char text[128];
  reply->n = 0;
  switch (op) {
  case 1: { /* read a file */
    if (!device_path(o, data, n, path, sizeof path, &why)) goto fail;
    FILE *f = fopen(path, "rb");
    if (!f) { why = strerror(errno); goto fail; }
    unsigned char chunk[65536];
    size_t k;
    while ((k = fread(chunk, 1, sizeof chunk, f)) > 0) {
      buf_add(reply, chunk, k);
      if (reply->n > MAX_PAYLOAD) break;
    }
    fclose(f);
    break;
  }
  case 2: { /* exists */
    if (!device_path(o, data, n, path, sizeof path, &why)) goto fail;
    struct stat st;
    buf_add(reply, stat(path, &st) == 0 ? "1" : "0", 1);
    break;
  }
  case 3: case 4: { /* write / append: NAME \0 CONTENTS */
    const unsigned char *sep = memchr(data, 0, n);
    if (!sep) { why = "write request has no path separator"; goto fail; }
    if (!device_path(o, data, (size_t)(sep - data), path, sizeof path, &why)) goto fail;
    FILE *f = fopen(path, op == 3 ? "wb" : "ab");
    if (!f) { why = strerror(errno); goto fail; }
    size_t len = n - (size_t)(sep - data) - 1;
    if (fwrite(sep + 1, 1, len, f) != len || fclose(f)) { why = "write failed"; goto fail; }
    break;
  }
  case 5: { /* environment */
    for (int i = 0; i < o->nenv; i++) {
      const char *eq = strchr(o->env[i], '=');
      if ((size_t)(eq - o->env[i]) == n && !memcmp(o->env[i], data, n)) {
        buf_add(reply, eq + 1, strlen(eq + 1));
        return 0;
      }
    }
    buf_add(reply, "unset", 5);
    return 1;
  }
  case 6: { /* monotonic clock, microseconds */
    if (n) { why = "clock payload must be empty"; goto fail; }
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    int k = snprintf(text, sizeof text, "%lld", (long long)t.tv_sec * 1000000LL + t.tv_nsec / 1000);
    buf_add(reply, text, (size_t)k);
    break;
  }
  case 8: /* next input line */
    if (n) { why = "input payload must be empty"; goto fail; }
    if (o->next_input >= o->ninputs) { buf_add(reply, "eof", 3); return 1; }
    buf_add(reply, o->inputs[o->next_input], strlen(o->inputs[o->next_input]));
    o->next_input++;
    break;
  case 9: { /* arguments */
    if (n) { why = "arguments payload must be empty"; goto fail; }
    buf_t a = encoded_args(o);
    buf_add(reply, a.p, a.n);
    free(a.p);
    break;
  }
  default:
    why = "virtual operation unavailable";
    goto fail;
  }
  if (reply->n > MAX_PAYLOAD) { reply->n = 0; why = "virtual reply too large"; goto fail; }
  return 0;
fail:
  reply->n = 0;
  buf_add(reply, why, strlen(why) > 4096 ? 4096 : strlen(why));
  return 1;
}

static int hexval(int c) {
  return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}
static int hexfield(const char *s, size_t n, unsigned long *v) {
  *v = 0;
  for (size_t i = 0; i < n; i++) {
    int d = hexval((unsigned char)s[i]);
    if (d < 0) return 0;
    *v = *v * 16 + (unsigned long)d;
  }
  return n > 0;
}

/* "@FPR1 SSSSSSSS OO NNNNNNNN HEX CC" without the newline */
static void parse_frame(const char *line, size_t n, unsigned long *seq, int *op, buf_t *payload) {
  if (n < 30 || memcmp(line, "@FPR1 ", 6) || line[14] != ' ' || line[17] != ' ' || line[26] != ' ')
    die(1, "malformed RPC header");
  unsigned long o = 0, len = 0, sum = 0;
  if (!hexfield(line + 6, 8, seq) || !hexfield(line + 15, 2, &o) || !hexfield(line + 18, 8, &len))
    die(1, "RPC hex");
  if (len > MAX_PAYLOAD || n != 27 + 2 * len + 3 || line[27 + 2 * len] != ' ') die(1, "RPC length");
  if (!hexfield(line + 28 + 2 * len, 2, &sum)) die(1, "RPC hex");
  payload->n = 0;
  unsigned x = 0;
  for (unsigned long i = 0; i < len; i++) {
    int hi = hexval((unsigned char)line[27 + 2 * i]), lo = hexval((unsigned char)line[28 + 2 * i]);
    if (hi < 0 || lo < 0) die(1, "RPC hex");
    unsigned char c = (unsigned char)(hi * 16 + lo);
    x ^= c;
    buf_add(payload, &c, 1);
  }
  if (x != sum) die(1, "RPC checksum");
  if (*seq == 0) die(1, "RPC sequence");
  *op = (int)o;
}

static buf_t make_frame(unsigned long seq, int code, const buf_t *payload) {
  buf_t f = {0};
  char head[64];
  int k = snprintf(head, sizeof head, "@FPR1 %08lx %02x %08lx ", seq, code, (unsigned long)payload->n);
  buf_add(&f, head, (size_t)k);
  unsigned x = 0;
  for (size_t i = 0; i < payload->n; i++) {
    snprintf(head, sizeof head, "%02x", payload->p[i]);
    buf_add(&f, head, 2);
    x ^= payload->p[i];
  }
  k = snprintf(head, sizeof head, " %02x\n", x & 0xff);
  buf_add(&f, head, (size_t)k);
  return f;
}

/* ---- byte transport ------------------------------------------------------ */
typedef struct { int in, out; } link_t;

static int wait_readable(int fd, double seconds) {
  fd_set r;
  FD_ZERO(&r);
  FD_SET(fd, &r);
  struct timeval tv = {(time_t)seconds, (suseconds_t)((seconds - (time_t)seconds) * 1e6)};
  int k = select(fd + 1, &r, 0, 0, &tv);
  return k > 0;
}

static void send_all(int fd, const void *data, size_t n) {
  const unsigned char *p = data;
  while (n) {
    fd_set w;
    FD_ZERO(&w);
    FD_SET(fd, &w);
    struct timeval tv = {5, 0};
    if (select(fd + 1, 0, &w, 0, &tv) <= 0) die(1, "write timeout");
    ssize_t k = write(fd, p, n);
    if (k < 0) {
      if (errno == EAGAIN || errno == EINTR) continue;
      die(1, "write: %s", strerror(errno));
    }
    p += k;
    n -= (size_t)k;
  }
}

/* Stop-and-wait per byte protects the board's one-byte receiver while the
 * guest allocates the reply or parses its header. */
static void respond(link_t *l, const buf_t *f) {
  for (size_t i = 0; i < f->n; i++) {
    send_all(l->out, f->p + i, 1);
    if (!wait_readable(l->in, 5)) die(1, "virtual device ACK timeout");
    unsigned char ack;
    ssize_t k = read(l->in, &ack, 1);
    if (k != 1 || ack != '+') die(1, "virtual device expected ACK, got 0x%02x", k == 1 ? ack : 0);
  }
}

/* Serve the guest until the ROM's DONE (board) or end of stream (qemu).
 * Returns 0 for a pass; prints guest lines as they arrive. */
static int serve(opts_t *o, link_t *l, buf_t *pending, int board, buf_t *output) {
  double deadline = now() + o->timeout;
  unsigned long sequence = 0;
  buf_t payload = {0}, reply = {0};
  for (;;) {
    char *nl;
    while (pending->n && (nl = memchr(pending->p, '\n', pending->n))) {
      size_t len = (size_t)(nl - (char *)pending->p);
      if (len >= 6 && !memcmp(pending->p, "@FPR1 ", 6)) {
        unsigned long seq;
        int op;
        parse_frame((char *)pending->p, len, &seq, &op, &payload);
        if (seq != sequence + 1) die(1, "guest sequence out of order");
        sequence = seq;
        buf_drop(pending, len + 1);
        int status = dispatch(o, op, payload.p, payload.n, &reply);
        buf_t f = make_frame(seq, status, &reply);
        respond(l, &f);
        free(f.p);
      } else {
        fwrite(pending->p, 1, len + 1, stdout);
        fflush(stdout);
        buf_add(output, pending->p, len + 1);
        buf_drop(pending, len + 1);
      }
    }
    if (board && pending->n >= 4 && !memcmp(pending->p + pending->n - 4, "DONE", 4)) {
      fwrite(pending->p, 1, pending->n, stdout);
      fputc('\n', stdout);
      fflush(stdout);
      buf_add(output, pending->p, pending->n);
      if (!buf_has(output, "FPR EXIT 0\n")) { fprintf(stderr, "board-host: CPU halted without a successful runtime exit\n"); return 1; }
      return 0;
    }
    if (pending->n > 2 * MAX_PAYLOAD + 128) die(1, "oversized guest frame");
    double left = deadline - now();
    if (left <= 0) {
      fprintf(stderr, "board-host: timeout; no successful exit (pending %.80s)\n", pending->n ? (char *)pending->p : "");
      return 3;
    }
    if (!wait_readable(l->in, left < 0.05 ? left : 0.05)) continue;
    unsigned char chunk[4096];
    ssize_t k = read(l->in, chunk, sizeof chunk);
    if (k < 0 && (errno == EAGAIN || errno == EINTR)) continue;
    if (k <= 0) {
      if (board) die(1, "serial port closed");
      if (pending->n) { fwrite(pending->p, 1, pending->n, stdout); buf_add(output, pending->p, pending->n); pending->n = 0; }
      fflush(stdout);
      return 0; /* qemu: end of stream; the caller checks the exit */
    }
    buf_add(pending, chunk, (size_t)k);
  }
}

/* ---- boot ROM ------------------------------------------------------------ */
static uint32_t crc32(uint32_t crc, const unsigned char *p, size_t n) {
  crc = ~crc;
  while (n--) {
    crc ^= *p++;
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1)));
  }
  return ~crc;
}

static int open_serial(const char *port, double mhz, double settle) {
  int fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0) die(1, "open %s: %s", port, strerror(errno));
  unsigned long baud = (unsigned long)llround(mhz * 1e6 / 868);
#ifdef __APPLE__
  struct termios t;
  if (tcgetattr(fd, &t)) die(1, "tcgetattr: %s", strerror(errno));
  t.c_iflag = t.c_oflag = t.c_lflag = 0;
  t.c_cflag = CS8 | CREAD | CLOCAL;
  cfsetispeed(&t, B115200);
  cfsetospeed(&t, B115200);
  if (tcsetattr(fd, TCSANOW, &t)) die(1, "tcsetattr: %s", strerror(errno));
  speed_t speed = (speed_t)baud;
  if (ioctl(fd, IOSSIOSPEED, &speed)) die(1, "IOSSIOSPEED %lu: %s", baud, strerror(errno));
#else
  struct termios2 t;
  if (ioctl(fd, TCGETS2, &t)) die(1, "TCGETS2: %s", strerror(errno));
  t.c_iflag = t.c_oflag = t.c_lflag = 0;
  t.c_cflag = CS8 | CREAD | CLOCAL | BOTHER;
  t.c_ispeed = t.c_ospeed = (speed_t)baud;
  if (ioctl(fd, TCSETS2, &t)) die(1, "TCSETS2: %s", strerror(errno));
#endif
  tcflush(fd, TCIOFLUSH);
  /* Some USB bridges (the Arty S7's FTDI) drop what is written in roughly
   * the first second after the port opens. */
  if (settle > 0) {
    struct timespec ts = {(time_t)settle, (long)((settle - (time_t)settle) * 1e9)};
    nanosleep(&ts, 0);
    tcflush(fd, TCIFLUSH);
  }
  return fd;
}

/* Read until a full line arrives (or timeout); returns the last non-empty line. */
static int read_line(int fd, double seconds, char *line, size_t cap) {
  buf_t b = {0};
  double end = now() + seconds;
  while (now() < end) {
    if (!wait_readable(fd, 0.05)) continue;
    unsigned char c[256];
    ssize_t k = read(fd, c, sizeof c);
    if (k > 0) buf_add(&b, c, (size_t)k);
    if (b.n && memchr(b.p, '\n', b.n)) break;
  }
  int ok = 0;
  line[0] = 0;
  if (b.n) {
    char *s = (char *)b.p, *save = 0;
    for (char *part = strtok_r(s, "\r\n", &save); part; part = strtok_r(0, "\r\n", &save))
      if (*part) { snprintf(line, cap, "%s", part); ok = 1; }
  }
  free(b.p);
  return ok;
}

typedef struct { char isa[16], cap[32], id[17]; unsigned long cpu, mem, ram, max; } identity_t;

static identity_t query_identity(int fd) {
  identity_t id;
  char line[512];
  for (int attempt = 0; attempt < 3; attempt++) {
    send_all(fd, "I", 1);
    if (!read_line(fd, 1.0, line, sizeof line)) { send_all(fd, "\x03", 1); usleep(150000); tcflush(fd, TCIFLUSH); continue; }
    char *srid = strstr(line, "SRID");
    if (!srid) continue;
    memset(&id, 0, sizeof id);
    if (sscanf(srid, "SRID1 isa=%15[a-z0-9_] cpu=%8lx mem=%8lx ram=%8lx max=%8lx cap=%31[A-Z0-9] id=%16[0-9a-f]",
               id.isa, &id.cpu, &id.mem, &id.ram, &id.max, id.cap, id.id) == 7 && strlen(id.id) == 16)
      return id;
    if (strncmp(srid, "SRID1 ", 6)) die(1, "unsupported ROM identity protocol: %s", srid);
    die(1, "malformed ROM identity reply: %s", srid);
  }
  die(1, "no response from the boot ROM on %s", "the UART (check the bitstream, port and clock)");
  return id;
}

static void check_identity(const opts_t *o, const identity_t *id, size_t image_bytes) {
  if (strcmp(id->isa, "rv32im") && strcmp(id->isa, "rv32imc")) die(1, "unsupported board ISA %s", id->isa);
  if (o->isa && strcmp(id->isa, o->isa)) die(1, "board ISA mismatch: board reports %s, expected %s", id->isa, o->isa);
  if ((long)id->cpu != llround(o->mhz)) die(1, "CPU clock mismatch: board reports %lu MHz, expected %.0f MHz", id->cpu, o->mhz);
  if (o->mem_mhz && (int)id->mem != o->mem_mhz) die(1, "memory clock mismatch: board reports %lu MHz, expected %d MHz", id->mem, o->mem_mhz);
  if (o->build_id && strcasecmp(id->id, o->build_id)) die(1, "bitstream build id mismatch: board reports %s, expected %s", id->id, o->build_id);
  for (const char *c = "UICG"; *c; c++)
    if (!strchr(id->cap, *c)) die(1, "board loader lacks capability %c (cap=%s)", *c, id->cap);
  size_t padded = (image_bytes + 3) & ~(size_t)3;
  if (!padded || padded > id->max) die(1, "program image is %zu bytes; the loader takes 1..%lu", padded, id->max);
}

static void upload(int fd, const unsigned char *image, size_t n, double mhz) {
  size_t padded = (n + 3) & ~(size_t)3;
  unsigned char *words = calloc(1, padded);
  memcpy(words, image, n);
  uint32_t count = (uint32_t)(padded / 4);
  unsigned char head[8] = {'S', 'R', 'U', '1', count, count >> 8, count >> 16, count >> 24};
  uint32_t hcrc = crc32(0, head, 8), pcrc = crc32(0, words, padded);
  unsigned char hc[4] = {hcrc, hcrc >> 8, hcrc >> 16, hcrc >> 24}, pc[4] = {pcrc, pcrc >> 8, pcrc >> 16, pcrc >> 24};
  send_all(fd, "U", 1);
  send_all(fd, head, 8);
  send_all(fd, hc, 4);
  send_all(fd, words, padded);
  send_all(fd, pc, 4);
  free(words);
  char line[256], want[32];
  double seconds = padded * 8680.0 / (mhz * 1e6) + 5;
  if (seconds < 15) seconds = 15;
  snprintf(want, sizeof want, "OK %08x", pcrc);
  if (!read_line(fd, seconds, line, sizeof line)) die(1, "timed out waiting for the ROM upload acknowledgement");
  if (strcmp(line, want)) die(1, "upload rejected: got '%s', expected '%s'", line, want);
  send_all(fd, "C", 1);
  snprintf(want, sizeof want, "%08x", pcrc);
  if (!read_line(fd, seconds, line, sizeof line) || strcmp(line, want))
    die(1, "readback 'C' CRC mismatch: got '%s', expected '%s'", line, want);
}

static unsigned char *slurp(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  if (!f) die(2, "%s: %s", path, strerror(errno));
  buf_t b = {0};
  unsigned char chunk[65536];
  size_t k;
  while ((k = fread(chunk, 1, sizeof chunk, f)) > 0) buf_add(&b, chunk, k);
  fclose(f);
  *n = b.n;
  return b.p;
}

static int board_fd = -1, board_started = 0;
static void board_abort(void) {
  if (board_fd >= 0 && board_started) { (void)!write(board_fd, "\x03", 1); usleep(200000); }
}

static int cmd_board(int argc, char **argv) {
  opts_t o;
  parse_opts(&o, argc, argv);
  if (!o.port || o.mhz <= 0) die(2, "board needs --port and a positive --mhz");
  buf_t args = encoded_args(&o); /* refuse bad arguments before touching the board */
  free(args.p);
  size_t n;
  unsigned char *image = slurp(o.image, &n);
  if (n == 0 || n > 2 * 1024 * 1024) die(2, "image must contain 1..2 MiB");
  int fd = open_serial(o.port, o.mhz, o.settle);
  board_fd = fd;
  atexit(board_abort);
  identity_t id = query_identity(fd);
  fprintf(stderr, "board-host: SRID1 isa=%s cpu=%lu mem=%lu ram=%lu max=%lu cap=%s id=%s\n",
          id.isa, id.cpu, id.mem, id.ram, id.max, id.cap, id.id);
  check_identity(&o, &id, n);
  upload(fd, image, n, o.mhz);
  free(image);
  send_all(fd, "G", 1);
  board_started = 1;
  buf_t pending = {0}, output = {0};
  /* 'G' answers ERR NOIMG at once when no verified image is held */
  double end = now() + 0.02;
  while (now() < end) {
    if (!wait_readable(fd, 0.005)) continue;
    unsigned char c[256];
    ssize_t k = read(fd, c, sizeof c);
    if (k > 0) buf_add(&pending, c, (size_t)k);
  }
  if (pending.n >= 9 && !memcmp(pending.p, "ERR NOIMG", 9)) die(1, "ROM refused guarded execution ('G'): ERR NOIMG");
  int rc = serve(&o, &(link_t){fd, fd}, &pending, 1, &output);
  if (rc == 0) board_started = 0;
  return rc;
}

static int cmd_qemu(int argc, char **argv) {
  opts_t o;
  parse_opts(&o, argc, argv);
  buf_t args = encoded_args(&o);
  free(args.p);
  int to_child[2], from_child[2];
  if (pipe(to_child) || pipe(from_child)) die(1, "pipe: %s", strerror(errno));
  char exe[32];
  snprintf(exe, sizeof exe, "qemu-system-riscv%d", o.xlen);
  pid_t pid = fork();
  if (pid < 0) die(1, "fork: %s", strerror(errno));
  if (pid == 0) {
    dup2(to_child[0], 0);
    dup2(from_child[1], 1);
    close(to_child[1]);
    close(from_child[0]);
    execlp(exe, exe, "-machine", "virt", "-m", "8M", "-bios", "none", "-kernel", o.image,
           "-display", "none", "-monitor", "none", "-serial", "stdio", (char *)0);
    fprintf(stderr, "board-host: exec %s: %s\n", exe, strerror(errno));
    _exit(127);
  }
  close(to_child[0]);
  close(from_child[1]);
  signal(SIGPIPE, SIG_IGN);
  buf_t pending = {0}, output = {0};
  int rc = serve(&o, &(link_t){from_child[0], to_child[1]}, &pending, 0, &output);
  if (rc != 0) { kill(pid, SIGKILL); waitpid(pid, 0, 0); return rc; }
  int status = 0;
  double end = now() + 5;
  while (waitpid(pid, &status, WNOHANG) == 0) {
    if (now() > end) { kill(pid, SIGKILL); waitpid(pid, &status, 0); die(1, "QEMU did not exit"); }
    usleep(10000);
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) { fprintf(stderr, "board-host: QEMU exit status %d\n", status); return 1; }
  if (!buf_has(&output, "FPR EXIT 0\n")) { fprintf(stderr, "board-host: no successful runtime exit\n"); return 1; }
  return 0;
}

/* ---- classifier reference ---------------------------------------------- */
typedef struct node { int leaf, value, col; double threshold; struct node *lo, *hi; } node_t;
typedef struct { int n; double *x, *z; int *y; } data_t;
static int BINS, MAX_DEPTH, MIN_LEAF;
static data_t TRAIN;
static double LO[2], WIDTH[2];
static int *CODES[2];

static data_t dataset(long seed, int n) {
  data_t d = {n, malloc(sizeof(double) * n), malloc(sizeof(double) * n), malloc(sizeof(int) * n)};
  double *v = malloc(sizeof(double) * 3 * n);
  for (int i = 0; i < 3 * n; i++) {
    seed = (1103515245L * seed + 12345) % 2147483648L;
    v[i] = seed / 2147483648.0;
  }
  for (int i = 0; i < n; i++) {
    d.x[i] = v[i] * 2 - 1;
    d.z[i] = v[n + i] * 2 - 1;
    d.y[i] = ((d.x[i] > 0) != (d.z[i] > 0)) ^ (v[2 * n + i] < .05);
  }
  free(v);
  return d;
}

static double entropy(const int c[2]) {
  int n = c[0] + c[1];
  if (!n) return 0.0;
  double s = 0;
  for (int k = 0; k < 2; k++)
    if (c[k]) s += ((double)c[k] / n) * log2((double)c[k] / n);
  return -s;
}

static node_t *build(const int *rows, int n, int depth) {
  int counts[2] = {0, 0};
  for (int i = 0; i < n; i++) counts[TRAIN.y[rows[i]]]++;
  node_t *leaf = calloc(1, sizeof *leaf);
  leaf->leaf = 1;
  leaf->value = counts[1] > counts[0];
  double parent = entropy(counts);
  if (depth >= MAX_DEPTH || n < 2 * MIN_LEAF || parent == 0) return leaf;
  int found = 0, bcol = 0, bthr = 0;
  double bgain = 0;
  int (*hist)[2] = calloc((size_t)BINS, sizeof *hist);
  for (int col = 0; col < 2; col++) {
    memset(hist, 0, sizeof(*hist) * BINS);
    for (int i = 0; i < n; i++) hist[CODES[col][rows[i]]][TRAIN.y[rows[i]]]++;
    int left[2] = {0, 0};
    for (int t = 0; t < BINS - 1; t++) {
      left[0] += hist[t][0];
      left[1] += hist[t][1];
      int nl = left[0] + left[1];
      if (nl < MIN_LEAF || n - nl < MIN_LEAF) continue;
      int right[2] = {counts[0] - left[0], counts[1] - left[1]};
      double gain = parent - (((double)nl / n) * entropy(left) + ((double)(n - nl) / n) * entropy(right));
      /* equal gains keep the earlier bin, then the earlier column */
      if (!found || gain > bgain) { found = 1; bgain = gain; bcol = col; bthr = t; }
    }
  }
  free(hist);
  if (!found || bgain < .001) return leaf;
  free(leaf);
  node_t *s = calloc(1, sizeof *s);
  s->col = bcol;
  s->threshold = LO[bcol] + (bthr + 1) * WIDTH[bcol];
  int *a = malloc(sizeof(int) * n), *b = malloc(sizeof(int) * n), na = 0, nb = 0;
  for (int i = 0; i < n; i++) {
    if (CODES[bcol][rows[i]] <= bthr) a[na++] = rows[i];
    else b[nb++] = rows[i];
  }
  s->lo = build(a, na, depth + 1);
  s->hi = build(b, nb, depth + 1);
  free(a);
  free(b);
  return s;
}

static int predict(const node_t *t, double x, double z) {
  while (!t->leaf) t = ((t->col ? z : x) < t->threshold) ? t->lo : t->hi;
  return t->value;
}
static void shape(const node_t *t, int *nodes, int *depth) {
  if (t->leaf) { *nodes = 1; *depth = 0; return; }
  int an, ad, bn, bd;
  shape(t->lo, &an, &ad);
  shape(t->hi, &bn, &bd);
  *nodes = 1 + an + bn;
  *depth = 1 + (ad > bd ? ad : bd);
}

/* SHA-256 of the prediction bytes, for the report only */
static void sha256(const unsigned char *msg, size_t len, char out[65]) {
  static const uint32_t k[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,
    0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
    0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,
    0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,
    0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
    0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
  uint32_t h[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  size_t total = ((len + 9 + 63) / 64) * 64;
  unsigned char *m = calloc(1, total);
  memcpy(m, msg, len);
  m[len] = 0x80;
  uint64_t bits = (uint64_t)len * 8;
  for (int i = 0; i < 8; i++) m[total - 1 - i] = (unsigned char)(bits >> (8 * i));
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
  for (size_t off = 0; off < total; off += 64) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
      w[i] = (uint32_t)m[off + 4 * i] << 24 | (uint32_t)m[off + 4 * i + 1] << 16 | (uint32_t)m[off + 4 * i + 2] << 8 | m[off + 4 * i + 3];
    for (int i = 16; i < 64; i++) {
      uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
      uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      uint32_t t1 = hh + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
      uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
#undef ROR
  free(m);
  for (int i = 0; i < 8; i++) snprintf(out + 8 * i, 9, "%08x", h[i]);
}

typedef struct { int hits, rows; long digest; char sha[65]; } score_t;
static score_t score(const node_t *t, const data_t *d) {
  score_t s = {0, d->n, 0, ""};
  unsigned char *p = malloc((size_t)d->n + 1);
  for (int i = 0; i < d->n; i++) {
    p[i] = (unsigned char)predict(t, d->x[i], d->z[i]);
    s.digest = (s.digest * 257 + p[i] + 1) % 1000003;
    s.hits += p[i] == d->y[i];
  }
  sha256(p, (size_t)d->n, s.sha);
  free(p);
  return s;
}

/* Every "DTREE BEGIN" run in the log must carry the reference lines exactly
 * once, the root split, and an elapsed time. */
static int check_runs(const char *log, int repeats, char **want, int nwant, const node_t *tree,
                      long *elapsed, buf_t *heap_json) {
  size_t n;
  char *text = (char *)slurp(log, &n);
  text = realloc(text, n + 1);
  text[n] = 0;
  int runs = 0;
  char *run = strstr(text, "DTREE BEGIN ");
  while (run) {
    if (run != text && run[-1] != '\n') { run = strstr(run + 1, "DTREE BEGIN "); continue; }
    char *next = strstr(run + 1, "\nDTREE BEGIN ");
    size_t len = next ? (size_t)(next + 1 - run) : strlen(run);
    char *chunk = strndup(run, len);
    if (runs >= repeats) die(1, "classifier: more than %d runs in the log", repeats);
    for (int i = 0; i < nwant; i++) {
      int count = 0;
      char *dup = strdup(chunk), *save = 0;
      for (char *l = strtok_r(dup, "\n", &save); l; l = strtok_r(0, "\n", &save)) count += !strcmp(l, want[i]);
      free(dup);
      if (count != 1) die(1, "classifier run %d: expected exactly one '%s'", runs + 1, want[i]);
    }
    if (tree->leaf) {
      if (!strstr(chunk, "root: leaf\n")) die(1, "classifier run %d: expected a leaf root", runs + 1);
    } else {
      char *r = strstr(chunk, "root split: col ");
      int col;
      double thr;
      if (!r || sscanf(r, "root split: col %d @ %lf", &col, &thr) != 2 || col != tree->col ||
          fabs(thr - tree->threshold) > fmax(1e-12 * fmax(fabs(thr), fabs(tree->threshold)), 1e-12))
        die(1, "classifier run %d: root split differs from the reference", runs + 1);
    }
    char *e = strstr(chunk, "DTREE elapsed_us=");
    if (!e || sscanf(e, "DTREE elapsed_us=%ld", &elapsed[runs]) != 1) die(1, "classifier run %d: no elapsed time", runs + 1);
    runs++;
    free(chunk);
    run = next ? next + 1 : 0;
  }
  if (runs != repeats) die(1, "classifier: %d runs in the log, expected %d", runs, repeats);
  /* heap samples: lines starting "HEAP " or "GC HEAP ", key=value integers */
  buf_add(heap_json, "[", 1);
  int first = 1;
  for (char *save = 0, *l = strtok_r(text, "\n", &save); l; l = strtok_r(0, "\n", &save)) {
    if (strncmp(l, "HEAP ", 5) && strncmp(l, "GC HEAP ", 8)) continue;
    buf_add(heap_json, first ? "{" : ",{", first ? 1 : 2);
    first = 0;
    int firstkv = 1;
    for (char *p = l; *p;) {
      char *eq = strchr(p, '=');
      if (!eq) break;
      char *k0 = eq;
      while (k0 > p && (k0[-1] == '_' || (k0[-1] >= 'a' && k0[-1] <= 'z') || (k0[-1] >= 'A' && k0[-1] <= 'Z') || (k0[-1] >= '0' && k0[-1] <= '9'))) k0--;
      char *v = eq + 1, *ve = v;
      while (*ve >= '0' && *ve <= '9') ve++;
      if (k0 < eq && ve > v) {
        char item[256];
        int k = snprintf(item, sizeof item, "%s\"%.*s\":%.*s", firstkv ? "" : ",", (int)(eq - k0), k0, (int)(ve - v), v);
        buf_add(heap_json, item, (size_t)k);
        firstkv = 0;
      }
      p = *ve ? ve + 1 : ve;
    }
    buf_add(heap_json, "}", 1);
  }
  buf_add(heap_json, "]", 1);
  free(text);
  return runs;
}

static int cmd_dtree(int argc, char **argv) {
  if (argc != 5 && argc != 7) die(2, "dtree TRAIN TEST BINS DEPTH MIN_LEAF [LOG REPEATS]");
  int train = atoi(argv[0]), test = atoi(argv[1]);
  BINS = atoi(argv[2]);
  MAX_DEPTH = atoi(argv[3]);
  MIN_LEAF = atoi(argv[4]);
  if (train < 1 || test < 1 || MIN_LEAF < 1 || BINS < 2 || MAX_DEPTH < 1 || MAX_DEPTH > 12)
    die(2, "positive sizes, bins >= 2 and depth 1..12 required");
  TRAIN = dataset(42, train);
  data_t testset = dataset(7, test);
  double *cols[2] = {TRAIN.x, TRAIN.z};
  for (int c = 0; c < 2; c++) {
    double lo = cols[c][0], hi = cols[c][0];
    for (int i = 1; i < train; i++) { if (cols[c][i] < lo) lo = cols[c][i]; if (cols[c][i] > hi) hi = cols[c][i]; }
    double width = (hi - lo) / BINS;
    if (width == 0) width = 1.0;
    LO[c] = lo;
    WIDTH[c] = width;
    CODES[c] = malloc(sizeof(int) * train);
    for (int i = 0; i < train; i++) {
      int code = (int)((cols[c][i] - lo) / width);
      CODES[c][i] = code < BINS - 1 ? code : BINS - 1;
    }
  }
  int *rows = malloc(sizeof(int) * train);
  for (int i = 0; i < train; i++) rows[i] = i;
  node_t *tree = build(rows, train, 0);
  int nodes, depth;
  shape(tree, &nodes, &depth);
  score_t tr = score(tree, &TRAIN), te = score(tree, &testset);
  char *want[5];
  char lines[5][160];
  snprintf(lines[0], 160, "DTREE BEGIN train=%d test=%d bins=%d depth=%d minLeaf=%d", train, test, BINS, MAX_DEPTH, MIN_LEAF);
  snprintf(lines[1], 160, "DTREE DATA READY");
  snprintf(lines[2], 160, "DTREE nodes=%d depth=%d", nodes, depth);
  snprintf(lines[3], 160, "DTREE train hits=%d/%d digest=%ld", tr.hits, tr.rows, tr.digest);
  snprintf(lines[4], 160, "DTREE test hits=%d/%d digest=%ld", te.hits, te.rows, te.digest);
  for (int i = 0; i < 5; i++) want[i] = lines[i];
  printf("{\"reference\":{\"train_rows\":%d,\"test_rows\":%d,\"bins\":%d,\"max_depth\":%d,\"min_leaf\":%d,"
         "\"nodes\":%d,\"depth\":%d,"
         "\"train\":{\"hits\":%d,\"rows\":%d,\"digest\":%ld,\"predictions_sha256\":\"%s\"},"
         "\"test\":{\"hits\":%d,\"rows\":%d,\"digest\":%ld,\"predictions_sha256\":\"%s\"},",
         train, test, BINS, MAX_DEPTH, MIN_LEAF, nodes, depth, tr.hits, tr.rows, tr.digest, tr.sha,
         te.hits, te.rows, te.digest, te.sha);
  if (tree->leaf) printf("\"root\":{\"leaf\":%d},", tree->value);
  else printf("\"root\":{\"column\":%d,\"threshold\":%.17g},", tree->col, tree->threshold);
  printf("\"entropy\":\"libm log2; the classifier uses its own 48-step log2\"}");
  if (argc == 7) {
    int repeats = atoi(argv[6]);
    if (repeats < 1 || repeats > 100) die(2, "REPEATS must be 1..100");
    long *elapsed = calloc((size_t)repeats, sizeof *elapsed);
    buf_t heap = {0};
    check_runs(argv[5], repeats, want, 5, tree, elapsed, &heap);
    printf(",\"elapsed_us_runs\":[");
    for (int i = 0; i < repeats; i++) printf("%s%ld", i ? "," : "", elapsed[i]);
    printf("],\"heap_samples\":%s", heap.p);
  }
  printf("}\n");
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && !strcmp(argv[1], "board")) return cmd_board(argc - 2, argv + 2);
  if (argc >= 2 && !strcmp(argv[1], "qemu")) return cmd_qemu(argc - 2, argv + 2);
  if (argc >= 2 && !strcmp(argv[1], "dtree")) return cmd_dtree(argc - 2, argv + 2);
  fprintf(stderr, "usage: board-host board IMAGE --port P --mhz M [...] | qemu ELF [...] | dtree ...\n");
  return 2;
}
