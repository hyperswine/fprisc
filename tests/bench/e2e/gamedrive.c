/* gamedrive: play a QOS Portable game from a script, and read what it cost.
 *
 *   gamedrive feed FIFO INTERVAL_MS SECONDS QUIT_CODE FIRST_CODE CODE...
 *   gamedrive summary GAME_LOG RSS_SAMPLES
 *
 * feed writes Linux evdev key events (press, then release) into the fifo the
 * game reads as FPR_EVDEV: FIRST_CODE once (the key that starts a game), then
 * the remaining codes in a cycle, one every INTERVAL_MS, for SECONDS; then
 * QUIT_CODE, repeated until the game has stopped reading the fifo. The codes are evdev key codes (28 Enter, 103/108/105/106 arrows,
 * 57 Space, 16 Q, 1 Escape).
 *
 * summary reads the host's log, written with FPR_GFX_PROFILE=1, where every
 * frame is a line
 *   [gfx-profile] frame start_us=.. drawn_us=.. submitted_us=.. end_us=.. ..
 * and prints one JSON line: the frames the app drew (its own count, printed
 * when it ends), frames a second over the profiled span, the host's time in
 * a frame (start to end; draw is start to drawn) as percentiles in
 * microseconds over the frames that have a line (the console echo is
 * rate-limited, so they are a sample), and the resident memory samples (KiB,
 * one a second) at the start, the peak and the end.
 */
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void die(const char *why) { fprintf(stderr, "gamedrive: %s\n", why); exit(1); }
static void pause_ms(long ms) {
  struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
  nanosleep(&t, 0);
}
/* press and release; 0 once nobody reads the fifo any more (the game has gone) */
static int try_key(int fd, int code) {
  for (int value = 1; value >= 0; value--) {
    unsigned char e[24] = {0};
    e[16] = 1; /* EV_KEY */
    e[18] = (unsigned char)(code & 255); e[19] = (unsigned char)(code >> 8);
    e[20] = (unsigned char)value;
    if (write(fd, e, sizeof e) != (ssize_t)sizeof e) return 0;
    pause_ms(15);
  }
  return 1;
}
static void key(int fd, int code) { if (!try_key(fd, code)) die("the game stopped reading keys"); }
static int feed(int argc, char **argv) {
  if (argc < 8) die("usage: gamedrive feed FIFO INTERVAL_MS SECONDS QUIT_CODE FIRST_CODE CODE...");
  int fd = open(argv[2], O_WRONLY);
  if (fd < 0) die("cannot open the key fifo");
  long interval = atol(argv[3]), seconds = atol(argv[4]);
  int quit = atoi(argv[5]), ncodes = argc - 7;
  if (interval < 40 || seconds < 1) die("INTERVAL_MS is at least 40 and SECONDS at least 1");
  key(fd, atoi(argv[6]));
  pause_ms(500);
  time_t until = time(0) + seconds;
  long sent = 0;
  for (int i = 0; time(0) < until; i = (i + 1) % ncodes) {
    key(fd, atoi(argv[7 + i]));
    sent++;
    pause_ms(interval - 30);
  }
  /* a game may ignore keys while it animates a turn: ask until it has gone */
  signal(SIGPIPE, SIG_IGN);
  for (int tries = 0; tries < 40; tries++) {
    pause_ms(700);
    if (!try_key(fd, quit)) break;
  }
  close(fd);
  fprintf(stderr, "gamedrive: %ld keys sent\n", sent);
  return 0;
}

static int cmp(const void *a, const void *b) {
  int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
  return x < y ? -1 : x > y;
}
static int64_t pct(int64_t *v, size_t n, double p) { return n ? v[(size_t)((double)(n - 1) * p)] : 0; }
static int64_t after(const char *line, const char *key) {
  const char *p = strstr(line, key);
  return p ? strtoll(p + strlen(key), 0, 10) : -1;
}
static void series(const char *name, int64_t *v, size_t n) {
  qsort(v, n, sizeof *v, cmp);
  printf("\"%s\":{\"p50\":%lld,\"p90\":%lld,\"p99\":%lld,\"max\":%lld}", name,
         (long long)pct(v, n, 0.50), (long long)pct(v, n, 0.90), (long long)pct(v, n, 0.99), (long long)pct(v, n, 1.0));
}
static int summary(int argc, char **argv) {
  if (argc != 4) die("usage: gamedrive summary GAME_LOG RSS_SAMPLES");
  FILE *f = fopen(argv[2], "r");
  if (!f) die("cannot read the game log");
  size_t cap = 1 << 16, n = 0;
  int64_t *host = malloc(cap * sizeof *host), *draw = malloc(cap * sizeof *draw);
  char line[4096];
  int64_t first = -1, last = -1;
  long mvu_frames = -1;
  while (fgets(line, sizeof line, f)) {
    const char *m = strstr(line, "[mvu: ");
    if (m) mvu_frames = atol(m + 6);
    /* the console echo is rate-limited, so only some frames have a line: these are samples */
    if (strncmp(line, "[host] [gfx-profile] frame", 26)) continue;
    int64_t start = after(line, "start_us="), drawn = after(line, "drawn_us="), end = after(line, "end_us=");
    if (start < 0 || drawn < 0 || end < 0) continue;
    if (n == cap) {
      cap *= 2;
      host = realloc(host, cap * sizeof *host); draw = realloc(draw, cap * sizeof *draw);
    }
    if (first < 0) first = start;
    host[n] = end - start; draw[n] = drawn - start;
    last = end;
    n++;
  }
  fclose(f);
  if (n < 2) die("the log has no frames (was FPR_GFX_PROFILE set?)");
  long rss_first = 0, rss_peak = 0, rss_last = 0, samples = 0, v;
  FILE *r = fopen(argv[3], "r");
  if (r) {
    while (fscanf(r, "%ld", &v) == 1) {
      if (!samples) rss_first = v;
      if (v > rss_peak) rss_peak = v;
      rss_last = v; samples++;
    }
    fclose(r);
  }
  double seconds = (double)(last - first) / 1e6;
  if (mvu_frames < 0) die("the log has no frame count (the game did not end with its summary line)");
  printf("{\"frames\":%ld,\"seconds\":%.1f,\"frames_per_second\":%.1f,\"profiled_frames\":%zu,", mvu_frames, seconds, (double)mvu_frames / seconds, n);
  series("host_frame_us", host, n); printf(",");
  series("host_draw_us", draw, n);
  printf(",\"rss_kib\":{\"first\":%ld,\"peak\":%ld,\"last\":%ld,\"samples\":%ld}}\n", rss_first, rss_peak, rss_last, samples);
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "feed")) return feed(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "summary")) return summary(argc, argv);
  die("usage: gamedrive feed ... | gamedrive summary GAME_LOG RSS_SAMPLES");
  return 1;
}
