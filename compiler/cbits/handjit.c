/* handjit.c — executable memory for the hand-rolled JIT tier.
 * One job: take emitted bytes, return a callable address.
 * W^X honored: RW during copy, RX after. */
#include <string.h>
#include <sys/mman.h>
#include <stdint.h>

void *hj_alloc(const uint8_t *buf, long n) {
  long sz = (n + 4095) & ~4095L;
  void *p = mmap(0, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) return 0;
  memcpy(p, buf, n);
  if (mprotect(p, sz, PROT_READ | PROT_EXEC) != 0) return 0;
  /* A64 has separate I/D caches: freshly written code must be flushed
   * before the first fetch (a no-op on x86-64) */
  __builtin___clear_cache((char *)p, (char *)p + sz);
  return p;
}

/* the x86-64 emitter uses roundsd (SSE4.1) for floor / round; refuse
 * the tier on a CPU without it rather than trap. Other ISAs: 1. */
#if defined(__x86_64__)
#include <cpuid.h>
int hj_has_sse41(void) {
  unsigned a, b, c, d;
  if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
  return (c & bit_SSE4_1) ? 1 : 0;
}
#else
int hj_has_sse41(void) { return 1; }
#endif
