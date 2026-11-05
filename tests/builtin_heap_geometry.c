/* Independent observations of the allocator's public geometry contract.
 * No private block/bin headers are decoded. The queries must agree with real
 * payload addresses, statistics, guards and failure behavior on both XLENs. */
#include "builtin.h"
#include <stdint.h>
#ifndef HEAP_FREESTANDING
#include <stdio.h>
#include <stdlib.h>
#endif
static _Alignas(16) unsigned char storage[16416];
static unsigned char *const arena=storage+16;
static V held[7];
static unsigned live;
static int short_trace;
static uw trace_span;
#ifdef HEAP_FREESTANDING
extern void heap_test_putc(char c);
extern void heap_test_exit(int n) __attribute__((noreturn));
#else
static void heap_test_putc(char c) { putchar(c); }
static __attribute__((noreturn)) void heap_test_exit(int n) { exit(n); }
#endif
static void say(const char *s) { while (*s) heap_test_putc(*s++); }
static int same(const char *a,const char *b) { while (*a && *a==*b) {a++;b++;} return *a==*b; }
static void check(int yes,const char *s) { if (!yes) {say("GEOMETRY FAIL: ");say(s);say("\n");heap_test_exit(1);} }
static void fill(unsigned char *p,uw n,unsigned char c) { for(uw i=0;i<n;i++)p[i]=c; }
static void guard(uw span) {
  for(unsigned i=0;i<16;i++)check(storage[i]==0xa5 && arena[span+i]==0xa5,"arena guards");
}
void fpr_cpanic(const char *s) {
  if(short_trace && same(s,"Builtin: out of memory")) {
    check(live==6 && fpr_builtin_live_allocations()==6,"short trace fails at last request");
    for(unsigned i=0;i<live;i++)check(*(unsigned char *)held[i]==i+1,"short trace preserves earlier payloads");
    guard(trace_span);
    say("SHORT ARENA REFUSED WITHOUT LOST PAYLOADS\n");
  }
  say(s);say("\n");heap_test_exit(3);
}
static uw rounded(uw n) { while(n%16)n++; return n; }
static uw used(void) { fpr_builtin_heap_stats s;fpr_builtin_heap_get_stats(&s);return s.live_bytes; }
static void plans(void) {
  fpr_builtin_heap_plan p;
  check(fpr_builtin_heap_plan_range(arena,arena+16384,&p)==0,"ordinary plan");
  uw prefix=sizeof(uw)==8?80:48;
  check(p.block_prefix_bytes==prefix && p.minimum_block_bytes==prefix+16,"physical ABI prefix");
  /* Alignment and bitmap oracle uses division by bytes-per-bit, independently
   * of the implementation's slot arithmetic. Planning never writes RAM. */
  fill(storage,sizeof storage,0xa5);
  for(unsigned offset=0;offset<32;offset++)for(unsigned span=0;span<512;span++) {
    uw lo=(uw)(arena+offset),hi=(uw)(arena+offset+span);
    while(lo%16)lo++;
    while(hi%16)hi--;
    uw bytes=hi>lo?hi-lo:0,bitmap=rounded((bytes+127)/128);
    int fits=bytes>=bitmap+prefix+16;
    fpr_builtin_heap_plan q={1,2,3,4,5};
    int result=fpr_builtin_heap_plan_range(arena+offset,arena+offset+span,&q);
    check((result==0)==fits,"alignment/minimum arena oracle");
    if(fits)check(q.block_start==lo && q.block_end==hi-bitmap && q.bitmap_bytes==bitmap,"planned physical extent");
    else check(q.block_start==1 && q.block_end==2 && q.bitmap_bytes==3 && q.block_prefix_bytes==4 && q.minimum_block_bytes==5,"failed plan unchanged");
  }
  for(unsigned i=0;i<sizeof storage;i++)check(storage[i]==0xa5,"planning writes no heap bytes");
  /* Bitmap rounding changes at each 2 KiB of aligned supplied range. Query
   * arithmetic addresses only; the planner must not dereference them. */
  for(uw boundary=2048;boundary<=16384;boundary+=2048)
    for(int delta=-16;delta<=16;delta++)for(unsigned offset=0;offset<16;offset++) {
      uw start=(uw)arena+offset,end=start+boundary+delta,lo=rounded(start),hi=end-end%16;
      uw bytes=hi-lo,bitmap=rounded(bytes/128+(bytes%128!=0));
      fpr_builtin_heap_plan q;
      check(!fpr_builtin_heap_plan_range((void *)start,(void *)end,&q),"bitmap boundary plan");
      check(q.block_start==lo && q.block_end==hi-bitmap && q.bitmap_bytes==bitmap,"bitmap boundary oracle");
    }
#ifndef FPR_BUILTIN_HEAP_MAX_BYTES
  {
    fpr_builtin_heap_plan q;
    uw hi=UINTPTR_MAX-15,bitmap=rounded(hi/128+(hi%128!=0));
    check(!fpr_builtin_heap_plan_range((void *)0,(void *)UINTPTR_MAX,&q),"full-width range arithmetic");
    check(q.bitmap_bytes==bitmap && q.block_end==hi-bitmap,"full-width bitmap without overflow");
  }
#endif
  for(uw n=0;n<16;n++) {
    fpr_builtin_heap_plan q={1,2,3,4,5};
    check(fpr_builtin_heap_plan_range((void *)(UINTPTR_MAX-n),(void *)UINTPTR_MAX,&q)!=0,"end-of-address-space refusal");
    check(q.block_start==1 && q.minimum_block_bytes==5,"overflow plan unchanged");
  }
  check(fpr_builtin_heap_plan_range(arena+512,arena,&p)!=0,"reversed range");
#ifdef FPR_BUILTIN_HEAP_MAX_BYTES
  p=(fpr_builtin_heap_plan){1,2,3,4,5};
  check(fpr_builtin_heap_plan_range((void *)0,(void *)(FPR_BUILTIN_HEAP_MAX_BYTES+16),&p)==FPR_BUILTIN_HEAP_PLAN_EXCEEDS_MAX,"configured maximum query");
  check(p.block_start==1 && p.block_end==2 && p.bitmap_bytes==3 && p.block_prefix_bytes==4 && p.minimum_block_bytes==5,"oversized plan unchanged");
#endif
  say("GEOMETRY alignment, bitmap, overflow and dry-run purity PASS\n");
}
static void requests(void) {
  fpr_builtin_heap_plan p;
  check(fpr_builtin_heap_plan_range(arena,arena+16384,&p)==0,"request plan");
  for(uw n=0;n<=4096;n++) {
    uw size=0;
    check(fpr_builtin_heap_request_size(n,&size),"small request size");
    uw want=p.block_prefix_bytes+rounded(n?n:1);
    check(size==want,"request rounding oracle");
    fill(storage,sizeof storage,0xa5);
    fpr_builtin_heap_init(arena,arena+16384);
    V a=fpr_alloc(n);
    check(a==p.block_start+p.block_prefix_bytes,"first payload start");
    check(used()==size,"observed minimum physical block");
    for(uw i=0;i<size-p.block_prefix_bytes;i++)check(((unsigned char *)a)[i]==0,"payload zeroed");
    *(unsigned char *)a=0x37;
    fpr_builtin_heap_plan q;
    check(fpr_builtin_heap_plan_range(arena+3,arena+1024,&q)==0,"query during allocation");
    check(*(unsigned char *)a==0x37 && used()==size && fpr_builtin_live_allocations()==1,"query preserves heap state");
    V b=fpr_alloc(0);
    check(b-a==size,"observed block stride");
    fpr_free(b);fpr_free(a);guard(16384);
  }
  uw ceiling=UINTPTR_MAX-p.block_prefix_bytes-15, result=0;
  check(fpr_builtin_heap_request_size(ceiling,&result),"last arithmetic-safe request");
  for(uw n=0;n<p.block_prefix_bytes+15;n++) {
    result=17;
    check(!fpr_builtin_heap_request_size(UINTPTR_MAX-n,&result) && result==17,"overflow request unchanged");
  }
  /* A split remainder smaller than a minimum block is part of the allocated
   * block, even though the minimum request-size query excludes it. */
  uw capacity=p.block_end-p.block_start;
  for(uw tail=0;tail<=p.block_prefix_bytes;tail+=16) {
    fpr_builtin_heap_init(arena,arena+16384);
    uw n=capacity-p.block_prefix_bytes-tail, minimum;
    check(fpr_builtin_heap_request_size(n,&minimum),"tail request");
    V a=fpr_alloc(n);
    check(used()==capacity && used()-minimum==tail,"unsplittable tail counted physically");
    fpr_free(a);
  }
  fpr_builtin_heap_init(arena,arena+16384);
  V a=fpr_alloc(4096);uw before=used(),minimum;
  check(fpr_builtin_heap_request_size(1,&minimum),"small realloc query");
  check(fpr_realloc(a,1)==a && used()==before && used()>minimum,"shrink retains previous capacity");
  fpr_free(a);
  say("GEOMETRY 4097 executed request sizes, split tails and retained realloc capacity PASS\n");
}
static void trace(int short_by_one) {
  const uw sizes[]={0,1,16,17,31,32,33};
  fpr_builtin_heap_plan p;
  check(fpr_builtin_heap_plan_range(arena,arena+16384,&p)==0,"trace plan");
  uw blocks=7*p.block_prefix_bytes+192,span=0;
  do {span+=16;} while(span-rounded((span+127)/128)<blocks);
  check(span-rounded((span+127)/128)==blocks,"exact trace arena");
  fill(storage,sizeof storage,0xa5);
  trace_span=span-short_by_one;
  fpr_builtin_heap_init(arena,arena+span-short_by_one);
  live=0;short_trace=short_by_one;
  for(unsigned i=0;i<7;i++) {held[i]=fpr_alloc(sizes[i]);live++;*(unsigned char *)held[i]=(unsigned char)(i+1);}
  check(!short_by_one,"short arena must refuse");
  check(used()==blocks,"exact trace consumes all block storage");
  for(unsigned i=0;i<7;i++) {check(*(unsigned char *)held[i]==i+1,"trace payload");fpr_free(held[i]);}
  check(!used() && !fpr_builtin_live_allocations(),"exact trace reclaimed");guard(span);
  say("GEOMETRY exact fixed arena with seven simultaneous allocations PASS\n");
}
int main(int argc,char **argv) {
#ifdef HEAP_CASE
  (void)argc;(void)argv;
  trace(1);
#else
  if(argc>1 && same(argv[1],"short"))trace(1);
#endif
  plans();requests();trace(0);
  say("BUILTIN HEAP GEOMETRY HOLDS\n");return 0;
}
