/* Profiling fixture only: linked explicitly, never a production primitive. */
#include "fpr.h"
#include <stdio.h>
#include <sys/resource.h>
extern uw fpr_spawns, fpr_stk_pushes, fpr_stk_misses, fpr_chb_carves;
extern uw fpr_grow_count, fpr_grow_bytes;
static V snapshot(V unit) {
  (void)unit;
  uint64_t a[5] = {0};
#ifdef FPR_COST_PROBE
  for (uw i=0;i<fpr_live_harts;i++) {
    fpr_hart_t *h=&fpr_harts[i];
    a[0]+=__atomic_load_n(&h->cost_alloc_requests,__ATOMIC_RELAXED);
    a[1]+=__atomic_load_n(&h->cost_alloc_bytes,__ATOMIC_RELAXED);
    a[2]+=__atomic_load_n(&h->cost_copies,__ATOMIC_RELAXED);
    a[3]+=__atomic_load_n(&h->cost_copy_bytes,__ATOMIC_RELAXED);
    a[4]+=__atomic_load_n(&h->cost_msg_slabs,__ATOMIC_RELAXED);
  }
#endif
  struct rusage ru; getrusage(RUSAGE_SELF,&ru);
  uint64_t rss=(uint64_t)ru.ru_maxrss;
#ifdef __APPLE__
  rss/=1024;
#endif
  char b[768];
  int n=snprintf(b,sizeof b,"session-probe:{\"alloc_requests\":%llu,\"alloc_bytes\":%llu,\"copies\":%llu,\"copy_bytes\":%llu,\"message_slabs\":%llu,\"arena_reserved_kib\":%llu,\"grow_bytes\":%llu,\"spawns\":%llu,\"stack_misses\":%llu,\"channel_carves\":%llu,\"peak_rss_kib\":%llu}",
    (unsigned long long)a[0],(unsigned long long)a[1],(unsigned long long)a[2],(unsigned long long)a[3],(unsigned long long)a[4],
    (unsigned long long)((buddy_arena_size()-buddy_free_bytes())>>10),
    (unsigned long long)__atomic_load_n(&fpr_grow_bytes,__ATOMIC_RELAXED),
    (unsigned long long)__atomic_load_n(&fpr_spawns,__ATOMIC_RELAXED),
    (unsigned long long)__atomic_load_n(&fpr_stk_misses,__ATOMIC_RELAXED),
    (unsigned long long)__atomic_load_n(&fpr_chb_carves,__ATOMIC_RELAXED),
    (unsigned long long)rss);
  if (n<0 || (size_t)n>=sizeof b) fpr_cpanic("sessionprobe: report overflow");
  return (V)fpr_mkstr((const uint8_t*)b,(uw)n);
}
FPR_FN(fpr_g_SessionProbe_x2esnapshot,snapshot,1);
