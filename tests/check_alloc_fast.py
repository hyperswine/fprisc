#!/usr/bin/env python3
"""Exercise real allocator paths, including poisoned padding and accounting.

A temporary runtime copy exposes the probe and counts slow-path entries.
Production code has no test hooks. The normal native runtime is still linked.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = r'''
static _Thread_local unsigned char alloc_test_storage[32768] __attribute__((aligned(16)));
#define ALLOC_CHECK(ok, why) do { if (!(ok)) fpr_cpanic("allocator contract: " why); } while (0)
static void alloc_test_check(V v, uw raw, fpr_slab_t *sl) {
  uw total = ((raw + 15) & ~(uw)15) + 16;
  ALLOC_CHECK(*(uw *)((char *)v - 16) == total, "size header");
  ALLOC_CHECK(*(fpr_slab_t **)((char *)v - 8) == sl, "slab header");
  ALLOC_CHECK(!((uw)v & (sizeof(uw) - 1)), "payload word alignment");
  for (uw i = raw; i < total - 16; i++) ALLOC_CHECK(((unsigned char *)v)[i] == 0, "nonzero rounding pad");
}
static V alloc_test_request(fpr_hart_t *h, uw raw, int bulk) {
#ifdef FPR_COST
  uint64_t requests = __atomic_load_n(&h->cost_alloc_requests, __ATOMIC_RELAXED);
  uint64_t bytes = __atomic_load_n(&h->cost_alloc_bytes, __ATOMIC_RELAXED);
#endif
  V v = bulk ? fpr_alloc_bulk(raw) : fpr_alloc(raw);
#ifdef FPR_COST
  ALLOC_CHECK(__atomic_load_n(&h->cost_alloc_requests, __ATOMIC_RELAXED) == requests + 1, "request counter");
  ALLOC_CHECK(__atomic_load_n(&h->cost_alloc_bytes, __ATOMIC_RELAXED) == bytes + ((raw + 15) & ~(uw)15) + 16, "byte counter");
#endif
  return v;
}
static V alloc_test_probe(V unused) {
  (void)unused;
  fpr_hart_t *h = fpr_hart();
  struct fpr_pool **slot = override_slot(h), *saved = *slot;
  uw clock = h->region_bytes;
  fpr_pool_t pool;
  void *buckets[FPR_NBUCKETS];
  uw sizes[] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
                16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
                40,56,63,64,127,255,16*FPR_NBUCKETS-17,
                16*FPR_NBUCKETS-16,16*FPR_NBUCKETS-15,
                16*FPR_NBUCKETS+8,16*FPR_NBUCKETS+9};
  for (uw bucketed = 0; bucketed < 2; bucketed++) {
    for (uw i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
      uw raw = sizes[i], total = ((raw + 15) & ~(uw)15) + 16;
      __builtin_memset(buckets, 0, sizeof buckets);
      __builtin_memset(alloc_test_storage, 0xa5, sizeof alloc_test_storage);
      fpr_pool_init(&pool, bucketed ? buckets : 0);
      fpr_slab_t *sl = (fpr_slab_t *)alloc_test_storage;
      __builtin_memset(sl, 0, sizeof *sl);
      sl->owner = &pool; sl->hp = (char *)(sl + 1);
      sl->end = (char *)alloc_test_storage + sizeof alloc_test_storage;
      /* Exact fits as well as spare space; a fixed pool can still bump. */
      if (!bucketed && (raw & 1)) sl->end = sl->hp + total;
      pool.cur = sl; pool.fixed_heap = 1; *slot = &pool;
      char *start = sl->hp;
      uw before = h->region_bytes, slow = alloc_test_slow_calls;
      V v = alloc_test_request(h, raw, 0);
      int fast = !bucketed && total <= (uw)16 * FPR_NBUCKETS;
      ALLOC_CHECK(alloc_test_slow_calls == slow + (fast ? 0 : 1), "small bucketless allocation missed fast path");
      ALLOC_CHECK((char *)v == start + 16 && sl->hp == start + total, "bump extent");
      ALLOC_CHECK(pool.allocated == total && h->region_bytes == before + total, "bump gauges");
      alloc_test_check(v, raw, sl);
      for (uw n = 0; n < raw; n++) ALLOC_CHECK(((unsigned char *)v)[n] == 0xa5, "payload was zeroed");
      if (bucketed || total > (uw)16 * FPR_NBUCKETS) {
        __builtin_memset((void *)v, 0xa5, total - 16);
        fpr_free(v); slow = alloc_test_slow_calls; before = h->region_bytes;
        V reused = alloc_test_request(h, raw, 0);
        ALLOC_CHECK(reused == v && sl->hp == start + total, "freed block not reused");
        ALLOC_CHECK(pool.allocated == total && h->region_bytes == before, "reuse charged bump gauges");
        ALLOC_CHECK(alloc_test_slow_calls == slow + 1, "reuse bypassed slow path");
        alloc_test_check(reused, raw, sl);
      }
    }
  }
  /* Bulk/vector storage ignores the override and never charges its clock. */
  *slot = saved;
  V warm = fpr_alloc_bulk(32); (void)warm;
  fpr_pool_t *base = base_pool(h);
  *slot = &pool;
  uw before = h->region_bytes, slow = alloc_test_slow_calls;
  V bulk = alloc_test_request(h, 24, 1);
  fpr_slab_t *bulk_slab = *(fpr_slab_t **)((char *)bulk - 8);
  ALLOC_CHECK(bulk_slab->owner == base && bulk_slab->owner != &pool, "bulk followed region override");
  ALLOC_CHECK(h->region_bytes == before && alloc_test_slow_calls == slow + 1, "bulk accounting/path");
  alloc_test_check(bulk, 24, bulk_slab);
  *slot = saved;
  /* Actual managed slabs: first allocation and a full slab must refill;
   * ordinary in-slab allocations take the shortcut. */
  struct fpr_scope *scope = region_open(h, 0);
  h = fpr_hart(); slow = alloc_test_slow_calls;
  V first = fpr_alloc(8);
  ALLOC_CHECK(alloc_test_slow_calls == slow + 1, "empty region did not use refill path");
  fpr_pool_t *region = cur_pool(h); fpr_slab_t *old = region->cur;
  alloc_test_check(first, 8, old);
  slow = alloc_test_slow_calls;
  V second = alloc_test_request(h, 8, 0);
  ALLOC_CHECK(alloc_test_slow_calls == slow, "real region missed fast path");
  alloc_test_check(second, 8, old);
  uw room = old->end - old->hp;
  uw usable = room & ~(uw)15;
  ALLOC_CHECK(usable >= 16, "unexpected slab extent");
  (void)fpr_alloc(usable - 16);
  ALLOC_CHECK((uw)(old->end - old->hp) < 16, "allocation did not consume usable slab space");
  slow = alloc_test_slow_calls;
  V refill = fpr_alloc(8);
  ALLOC_CHECK(alloc_test_slow_calls == slow + 1 && region->cur != old, "full region skipped refill");
  alloc_test_check(refill, 8, region->cur);
  (void)region_close(fpr_hart(), scope, TAG(0));
  h = fpr_hart(); h->region_bytes = clock;
  return TAG(1);
}
FPR_FN(fpr_g_Alloc_x2echeck, alloc_test_probe, 1);
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--runtime-source', type=Path, default=ROOT / 'runtime/runtime.c')
    ap.add_argument('--sanitize-alignment', action='store_true')
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='fpr-alloc-fast-') as directory:
        tmp = Path(directory)
        source = args.runtime_source.read_text()
        marker = 'static V alloc_in(fpr_hart_t *h, fpr_pool_t *pool, V raw_bytes, int bulk) {'
        assert source.count(marker) == 1
        source = source.replace(marker, 'static _Thread_local uw alloc_test_slow_calls;\n' + marker + '\n  alloc_test_slow_calls++;')
        (tmp / 'runtime.c').write_text(source + '\n' + PROBE)
        cc = tmp / 'cc'
        cc.write_text('#!/usr/bin/env python3\nimport os,sys\na=[' + repr(str(tmp / 'runtime.c'))
                      + ' if x.endswith("/runtime/runtime.c") else x for x in sys.argv[1:]]\n'
                      # --cflag does not apply to cached runtime objects.
                      # Instrument this translation unit, not unrelated runtime C.
                      + 'if ' + repr(str(tmp / 'runtime.c')) + ' in a: a += '
                      + repr(['-fsanitize=alignment'] if args.sanitize_alignment else [])
                      + '\nos.execvp("cc",["cc",*a])\n')
        cc.chmod(0o755)
        program = tmp / 'probe.fpr'
        program.write_text('unsafe base.\nAlloc.check : Unit -> Int.\nmain = print (Alloc.check Unit).\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')))
        for cost in ('0', '1'):
            mode = dict(env, FPR_COST_PROBE=cost)
            exe = tmp / ('probe-' + cost)
            extra = ['--link', '-fsanitize=alignment'] if args.sanitize_alignment else []
            mode.update(UBSAN_OPTIONS='halt_on_error=1')
            built = subprocess.run([ROOT / 'fpr', 'build', program, '--harts', '4', '--cc', cc, *extra, '-o', exe],
                                   cwd=ROOT, env=mode, capture_output=True, text=True, timeout=180)
            assert built.returncode == 0, built.stdout + built.stderr
            for harts in ('1', '4'):
                p = subprocess.run([exe], cwd=ROOT, env=dict(mode, FPR_HARTS=harts), capture_output=True, text=True, timeout=30)
                assert p.returncode == 0 and p.stdout == '1\n' and not p.stderr, (cost, harts, p.stdout, p.stderr)
            print(f'allocator cost={cost}: byte/word pads, exact fits, fixed pools, buckets, big-free reuse, bulk isolation, real refills and gauges on 1/4 harts PASS', flush=True)


if __name__ == '__main__':
    main()
