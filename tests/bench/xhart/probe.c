/* probe.c -- the cross-hart profile's C side (tools/xhart-profile.py,
 * docs/2026-10-01-XHART.md): a nanosecond clock, a latency histogram, and
 * the FPR_COST_PROBE cross-hart ledger summed over the harts.  Benchmark
 * code only; nothing here is a language primitive. */
#include "fpr.h"
#include <stdio.h>
#include <time.h>
static uint64_t ns(void) {
#ifdef __APPLE__
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
#endif
}
static V xh_now(V u) { (void)u; return TAG((sw)ns()); }
/* latency samples: 64 log2-ns buckets, each split in 8 linear sub-buckets */
static uint64_t hist[64][8], nsamp;
static V xh_lat(V dv) {
  uint64_t d = (uint64_t)UNTAG(dv);
  int b = d ? 63 - __builtin_clzll(d) : 0;
  int sub = b >= 3 ? (int)((d >> (b - 3)) & 7) : 0;
  hist[b][sub]++; nsamp++;
  return (V)&fpr_unit;
}
static uint64_t pct(double q) {
  uint64_t want = (uint64_t)(q * (double)nsamp), seen = 0;
  for (int b = 0; b < 64; b++)
    for (int s = 0; s < 8; s++) {
      seen += hist[b][s];
      if (seen > want) return b >= 3 ? ((uint64_t)(8 + s) << (b - 3)) : (1ull << b);
    }
  return 0;
}
#define NF 22
static uint64_t base[NF];
static void snap(uint64_t o[NF]) {
  for (int k = 0; k < NF; k++) o[k] = 0;
#ifdef FPR_COST_PROBE
  for (uw i = 0; i < fpr_live_harts; i++) {
    fpr_hart_t *h = &fpr_harts[i];
    uint64_t v[NF] = {h->xs_send_n, h->xs_send_ns, h->xs_copy_ns, h->xs_arc_ns, h->xs_push_ns, h->xs_wake_ns,
                      h->xs_xship_n, h->xs_xpush_ns, h->xs_ipi_ns, h->xs_lship_n,
                      h->xr_recv_n, h->xr_scan_ns, h->xr_block_n, h->xr_drop_ns,
                      h->xl_drain_n, h->xl_drain_ns, h->xl_run_n, h->xl_run_ns,
                      h->xp_park_n, h->xp_park_ns, h->xp_bell_n, h->xp_bell_ns};
    for (int k = 0; k < NF; k++) o[k] += v[k];
  }
#endif
}
static const char *names[NF] = {"send_n", "send_ns", "copy_ns", "arc_incref_ns", "ring_push_ns", "wake_ns",
                                "xship_n", "xpush_ns", "ipi_ns", "local_ship_n",
                                "recv_n", "recv_scan_ns", "recv_block_n", "drop_ns",
                                "drain_n", "ship_to_drain_ns", "run_n", "drain_to_run_ns",
                                "park_n", "park_ns", "bell_n", "bell_to_wake_ns"};
static V xh_begin(V u) { (void)u; snap(base); nsamp = 0; for (int b = 0; b < 64; b++) for (int s = 0; s < 8; s++) hist[b][s] = 0; return (V)&fpr_unit; }
static V xh_report(V u) {
  (void)u; uint64_t a[NF]; snap(a);
  char b[1400]; int n = snprintf(b, sizeof b, "{");
  for (int k = 0; k < NF; k++) n += snprintf(b + n, sizeof b - n, "\"%s\":%llu,", names[k], (unsigned long long)(a[k] - base[k]));
  n += snprintf(b + n, sizeof b - n, "\"lat_n\":%llu,\"lat_p50_ns\":%llu,\"lat_p99_ns\":%llu,\"lat_p999_ns\":%llu}",
                (unsigned long long)nsamp, (unsigned long long)pct(0.5), (unsigned long long)pct(0.99), (unsigned long long)pct(0.999));
  return (V)fpr_mkstr((const uint8_t *)b, (uw)n);
}
FPR_FN(fpr_g_XH_x2enow, xh_now, 1);
FPR_FN(fpr_g_XH_x2elat, xh_lat, 1);
FPR_FN(fpr_g_XH_x2ebegin, xh_begin, 1);
FPR_FN(fpr_g_XH_x2ereport, xh_report, 1);
