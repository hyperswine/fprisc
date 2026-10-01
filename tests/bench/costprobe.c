/* Benchmark-only surface: no new language primitives or default counters. */
#include "fpr.h"
#include <stdio.h>
static uint64_t baseline[5];
static void snapshot(uint64_t out[5]) {
  for (unsigned k=0;k<5;k++) out[k]=0;
#ifdef FPR_COST_PROBE
  for (uw i=0;i<fpr_live_harts;i++) {
    fpr_hart_t *h=&fpr_harts[i];
    out[0]+=__atomic_load_n(&h->cost_alloc_requests,__ATOMIC_RELAXED);
    out[1]+=__atomic_load_n(&h->cost_alloc_bytes,__ATOMIC_RELAXED);
    out[2]+=__atomic_load_n(&h->cost_copies,__ATOMIC_RELAXED);
    out[3]+=__atomic_load_n(&h->cost_copy_bytes,__ATOMIC_RELAXED);
    out[4]+=__atomic_load_n(&h->cost_msg_slabs,__ATOMIC_RELAXED);
  }
#endif
}
static V begin(V u) { (void)u; snapshot(baseline); return (V)&fpr_unit; }
static V report(V u) {
  (void)u; uint64_t a[5]; snapshot(a);
  for (unsigned k=0;k<5;k++) a[k]-=baseline[k];
  char b[320]; int n=snprintf(b,sizeof b,
    "{\"alloc_requests\":%llu,\"alloc_bytes\":%llu,\"copies\":%llu,\"copy_bytes\":%llu,\"message_slabs\":%llu}",
    (unsigned long long)a[0],(unsigned long long)a[1],(unsigned long long)a[2],
    (unsigned long long)a[3],(unsigned long long)a[4]);
  return (V)fpr_mkstr((const uint8_t*)b,(uw)n);
}
static V allocs(V nv,V sizev) {
  uw n=(uw)UNTAG(nv),size=(uw)UNTAG(sizev),sum=0;
  for (uw i=0;i<n;i++) { V p=fpr_alloc(size); ((uint8_t*)p)[0]=(uint8_t)i; sum+=((uint8_t*)p)[0]; fpr_free(p); }
  return TAG((sw)sum);
}
static V payload(V sizev) {
  uw size=(uw)UNTAG(sizev); uint8_t b[4096];
  if (size>sizeof b) fpr_cpanic("costprobe: payload too large");
  for(uw i=0;i<size;i++) b[i]='x';
  return (V)fpr_mkstr(b,size);
}
FPR_FN(fpr_g_Cost_x2ebegin,begin,1);
FPR_FN(fpr_g_Cost_x2ereport,report,1);
FPR_FN(fpr_g_Cost_x2eallocs,allocs,2);
FPR_FN(fpr_g_Cost_x2epayload,payload,1);
