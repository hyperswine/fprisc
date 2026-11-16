/* posdrive: scripted cashiers against a running examples/pos1.fpr.
 *
 *   posdrive PORT SESSIONS SALES [quit]
 *
 * Each session is what one browser tab does, on the wire the page uses
 * (std/livejs): a websocket to /ws?lv=3, text frames {"msg":..,"arg":..}.
 * A cashier signs in, then for every sale mirrors a cart (ClientState) and
 * pays (Card, or Cash on every third sale); every eighth sale it looks at the
 * Receipts tab first. All sessions run at once, each in a closed loop: the
 * next sale is sent when the previous one is acknowledged. The acknowledgement
 * is the frame the server sends to that session alone when its cart empties
 * ({"emit":"locals",...}), so a broadcast caused by another cashier is never
 * mistaken for it. Every frame the server sends is read and counted.
 *
 * Prints one JSON line: sales, wall seconds, sales a second, the latency of a
 * sale (mirror sent to acknowledgement received) and bytes received.
 * `quit` asks the server to save and stop afterwards.
 * Exit 0 only if every sale was acknowledged.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static const char *SKU[6] = {"FW", "LB", "CT", "BR", "CC", "SW"};

typedef struct {
  int fd;
  uint8_t *buf; /* unread bytes from the server */
  size_t len, cap;
  uint64_t rng, sent_at;
  int done, signed_in, waiting;
} session_t;

static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static void die(const char *why) { fprintf(stderr, "posdrive: %s\n", why); exit(1); }
static uint64_t lcg(uint64_t x) { return (x * 1103515245ull + 12345ull) % 2147483648ull; }

static void write_all(int fd, const void *p, size_t n) {
  const uint8_t *b = p;
  while (n) {
    ssize_t w = write(fd, b, n);
    if (w < 0 && (errno == EINTR || errno == EAGAIN)) {
      struct pollfd pf = {fd, POLLOUT, 0};
      poll(&pf, 1, 1000);
      continue;
    }
    if (w <= 0) die("write failed");
    b += w; n -= (size_t)w;
  }
}

/* one masked text frame (a client must mask, RFC 6455) */
static void send_text(int fd, const char *text) {
  size_t n = strlen(text);
  uint8_t head[14], mask[4] = {0x12, 0x34, 0x56, 0x78};
  size_t h = 0;
  head[h++] = 0x81;
  if (n < 126) head[h++] = (uint8_t)(0x80 | n);
  else if (n < 65536) { head[h++] = 0x80 | 126; head[h++] = (uint8_t)(n >> 8); head[h++] = (uint8_t)n; }
  else { head[h++] = 0x80 | 127; for (int i = 7; i >= 0; i--) head[h++] = (uint8_t)((uint64_t)n >> (8 * i)); }
  memcpy(head + h, mask, 4); h += 4;
  uint8_t *out = malloc(h + n);
  if (!out) die("out of memory");
  memcpy(out, head, h);
  for (size_t i = 0; i < n; i++) out[h + i] = (uint8_t)text[i] ^ mask[i & 3];
  write_all(fd, out, h + n);
  free(out);
}

/* {"msg":MSG,"arg":ARG} with both given as plain text and escaped here */
static void send_event(int fd, const char *msg, const char *arg) {
  char out[2048];
  size_t o = 0;
  const char *parts[2] = {msg, arg};
  const char *keys[2] = {"{\"msg\":\"", "\",\"arg\":\""};
  for (int k = 0; k < 2; k++) {
    o += (size_t)snprintf(out + o, sizeof out - o, "%s", keys[k]);
    for (const char *p = parts[k]; *p; p++) {
      if (o + 4 >= sizeof out) die("event too long");
      if (*p == '"' || *p == '\\') out[o++] = '\\';
      out[o++] = *p;
    }
  }
  o += (size_t)snprintf(out + o, sizeof out - o, "\"}");
  send_text(fd, out);
}

static int connect_session(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) die("socket failed");
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&a, sizeof a)) die("connect failed (is pos1 running?)");
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  char req[512];
  int n = snprintf(req, sizeof req,
                   "GET /ws?lv=3 HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: cG9zZHJpdmUtYmVuY2gtMDE=\r\nSec-WebSocket-Version: 13\r\n\r\n", port);
  write_all(fd, req, (size_t)n);
  return fd;
}

/* the mirror the page sends: its Client record, the cart as [sku, quantity] pairs */
static void send_cart(session_t *s, const char *tab, int with_cart) {
  char arg[512];
  size_t o = (size_t)snprintf(arg, sizeof arg,
      "[{\"tab\":\"%s\",\"open\":\"0\",\"tender\":\"\",\"delta\":\"10\",\"cmd\":\"\",\"name\":\"\",\"pin\":\"\",\"cart\":[", tab);
  int lines = 0;
  for (int i = 0; i < 6; i++) {
    int q = 0;
    if (with_cart) { s->rng = lcg(s->rng); q = (int)((s->rng >> 8) % 4); }
    if (with_cart && i == 5 && lines == 0) q = 1; /* never an empty cart */
    if (q > 0) lines++;
    o += (size_t)snprintf(arg + o, sizeof arg - o, "%s[\"%s\",\"%d\"]", i ? "," : "", SKU[i], q);
  }
  snprintf(arg + o, sizeof arg - o, "]}]");
  send_event(s->fd, "*[\"ClientState\"]", arg);
}

static void next_sale(session_t *s) {
  if ((s->done & 7) == 7) { send_cart(s, "Receipts", 0); }
  s->sent_at = now_ns();
  send_cart(s, "Register", 1);
  if (s->done % 3 == 2) send_event(s->fd, "*[\"Cash\"]", "[\"500.00\"]");
  else send_event(s->fd, "=[\"Card\"]", "");
  s->waiting = 1;
}

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
  if (argc < 4) die("usage: posdrive PORT SESSIONS SALES [quit]");
  int port = atoi(argv[1]), nsess = atoi(argv[2]), sales = atoi(argv[3]);
  int quit = argc > 4 && !strcmp(argv[4], "quit");
  if (port <= 0 || nsess <= 0 || sales <= 0) die("PORT, SESSIONS and SALES must be positive");
  session_t *ss = calloc((size_t)nsess, sizeof *ss);
  struct pollfd *pf = calloc((size_t)nsess, sizeof *pf);
  uint64_t *lat = malloc(sizeof *lat * (size_t)nsess * (size_t)sales);
  if (!ss || !pf || !lat) die("out of memory");
  size_t nlat = 0;
  uint64_t bytes = 0, frames = 0;
  for (int i = 0; i < nsess; i++) {
    ss[i].fd = connect_session(port);
    ss[i].rng = 12345u + 7919u * (uint64_t)i;
    pf[i].fd = ss[i].fd; pf[i].events = POLLIN;
  }
  uint64_t start = 0;
  int open = nsess, finished = 0, http = 0;
  while (finished < nsess) {
    if (poll(pf, (nfds_t)nsess, 30000) <= 0) die("no frame from the server for 30 s");
    for (int i = 0; i < nsess; i++) {
      session_t *s = &ss[i];
      if (!(pf[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      if (s->cap - s->len < 65536) {
        s->cap = s->cap ? s->cap * 2 : 1 << 18;
        if (!(s->buf = realloc(s->buf, s->cap))) die("out of memory");
      }
      ssize_t r = read(s->fd, s->buf + s->len, s->cap - s->len);
      if (r <= 0) die("the server closed a session");
      s->len += (size_t)r; bytes += (uint64_t)r;
      size_t at = 0;
      if (!s->signed_in && s->sent_at == 0) { /* the 101 response comes first */
        char *end = NULL;
        for (size_t k = 0; k + 3 < s->len; k++)
          if (!memcmp(s->buf + k, "\r\n\r\n", 4)) { end = (char *)s->buf + k + 4; break; }
        if (!end) continue;
        if (memcmp(s->buf, "HTTP/1.1 101", 12)) die("the server refused the websocket");
        at = (size_t)(end - (char *)s->buf);
        s->sent_at = 1;
        if (++http == nsess) start = now_ns();
        send_event(s->fd, "*[\"Login\"]", "[\"ana\",\"1234\"]");
      }
      for (;;) { /* whole frames */
        if (s->len - at < 2) break;
        uint8_t *f = s->buf + at;
        uint64_t n = f[1] & 127;
        size_t h = 2;
        if (n == 126) { if (s->len - at < 4) break; n = ((uint64_t)f[2] << 8) | f[3]; h = 4; }
        else if (n == 127) { if (s->len - at < 10) break; n = 0; for (int k = 0; k < 8; k++) n = (n << 8) | f[2 + k]; h = 10; }
        if (s->len - at < h + n) break;
        frames++;
        int op = f[0] & 15;
        if (op == 8) die("the server closed a session");
        /* the per-session acknowledgement: {"detail":...,"emit":"locals"} */
        int ack = op == 1 && n < 4096 && n >= 15 && memmem(f + h, (size_t)n, "\"emit\":\"locals\"", 15) != NULL;
        at += h + (size_t)n;
        if (!ack) continue;
        if (!s->signed_in) { s->signed_in = 1; next_sale(s); continue; }
        if (!s->waiting) continue;
        lat[nlat++] = now_ns() - s->sent_at;
        s->waiting = 0;
        if (++s->done == sales) { finished++; continue; }
        next_sale(s);
      }
      memmove(s->buf, s->buf + at, s->len - at);
      s->len -= at;
    }
  }
  uint64_t wall = now_ns() - start;
  (void)open;
  if (quit) { send_event(ss[0].fd, "=[\"Quit\"]", ""); usleep(200000); }
  for (int i = 0; i < nsess; i++) close(ss[i].fd);
  qsort(lat, nlat, sizeof *lat, cmp_u64);
  double secs = (double)wall / 1e9;
#define PCT(p) ((double)lat[(size_t)((double)(nlat - 1) * (p))] / 1000.0)
  printf("{\"sessions\":%d,\"sales\":%zu,\"seconds\":%.3f,\"sales_per_second\":%.1f,"
         "\"latency_us\":{\"p50\":%.0f,\"p90\":%.0f,\"p99\":%.0f,\"max\":%.0f},"
         "\"frames\":%llu,\"bytes_received\":%llu,\"bytes_per_sale\":%.0f}\n",
         nsess, nlat, secs, (double)nlat / secs, PCT(0.50), PCT(0.90), PCT(0.99), PCT(1.0),
         (unsigned long long)frames, (unsigned long long)bytes, (double)bytes / (double)nlat);
  return nlat == (size_t)nsess * (size_t)sales ? 0 : 1;
}
