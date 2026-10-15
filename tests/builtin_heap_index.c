/* Public heap contracts, hostile pointers, fragmentation, and allocation work.
 * The same fixture executes natively under sanitizers and on RV32/RV64 QEMU.
 * Tests do not decode private headers, bins, bitmap, or neighbour links.
 * The two words in the established 16-byte object metadata are public ABI.
 */
#include "builtin.h"
#include <stdint.h>
#ifndef HEAP_FREESTANDING
#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
static jmp_buf oom_target;
static int expected_oom;
#endif

#ifndef HEAP_TEST_ARENA_BYTES
#define HEAP_TEST_ARENA_BYTES (2*1024*1024)
#endif
static _Alignas(16) unsigned char arena[HEAP_TEST_ARENA_BYTES];
static V slots[96];
static uw lengths[96];
#ifdef FPR_BUILTIN_HEAP_TEST
extern uw fpr_builtin_heap_lookup_steps, fpr_builtin_heap_allocation_steps;
#endif
#ifdef HEAP_FREESTANDING
extern void heap_test_putc(char c);
extern void heap_test_exit(int code) __attribute__((noreturn));
#define put_character heap_test_putc
#else
static void put_character(char c) { putchar(c); }
static __attribute__((noreturn)) void heap_test_exit(int code) { exit(code); }
#endif
static void put_text(const char *s) { while (*s) put_character(*s++); }
static int same(const char *a, const char *b);
static void put_number(uw n) {
  char digits[32]; unsigned count = 0;
  do { digits[count++] = (char)('0' + n % 10); n /= 10; } while (n);
  while (count) put_character(digits[--count]);
}
void fpr_cpanic(const char *s) {
#ifndef HEAP_FREESTANDING
  if (expected_oom && same(s,"Builtin: out of memory")) longjmp(oom_target,1);
#endif
  put_text(s); put_character('\n'); heap_test_exit(3);
}
static void check(int ok, const char *s) {
  if (!ok) { put_text("HEAP CHECK FAILED: "); put_text(s); put_character('\n'); heap_test_exit(1); }
}
static int same(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static void fill(V p, uw n, unsigned char value) { for (uw i=0;i<n;i++) ((unsigned char *)p)[i]=value; }
static void expect(V p, uw n, unsigned char value) {
  for (uw i=0;i<n;i++) check(((unsigned char *)p)[i]==value,"payload contents");
}
static uw capacity(V p) { return *(uw *)(p-16)-16; }
static uw cycles(void) {
#ifdef HEAP_FREESTANDING
  uw value; __asm__ volatile("csrr %0,mcycle" : "=r"(value) :: "memory"); return value;
#else
  return 0;
#endif
}
static void initialize(void) { fpr_builtin_heap_init(arena,arena+sizeof arena); }

static void negative(const char *which) {
#ifdef FPR_BUILTIN_HEAP_MAX_BYTES
  if (same(which,"configured-max")) {
    /* Rejection must happen before the allocator touches this fake RAM range. */
    fpr_builtin_heap_init((void *)16,(void *)((uw)FPR_BUILTIN_HEAP_MAX_BYTES+32));
  }
#endif
  if (same(which,"overflow")) fpr_alloc(UINTPTR_MAX);
  if (same(which,"init-overflow")) fpr_builtin_heap_init((void *)(UINTPTR_MAX-7),(void *)UINTPTR_MAX);
  if (same(which,"small-heap")) fpr_builtin_heap_init(arena,arena+64);
  if (same(which,"out-of-memory")) fpr_alloc(sizeof arena);
  V p=fpr_alloc(512);
  if (same(which,"double-free")) { fpr_free(p); fpr_free(p); }
  if (same(which,"coalesced-double-free")) {
    V q=fpr_alloc(16); fpr_free(p); fpr_free(q); fpr_free(q);
  }
  if (same(which,"interior")) fpr_free(p+16);
  if (same(which,"unaligned")) fpr_free(p+2);
  if (same(which,"outside")) fpr_free((V)arena-16);
  if (same(which,"past-end")) fpr_free((V)(arena+sizeof arena));
  if (same(which,"retain-interior")) fpr_builtin_retain(p+16);
  if (same(which,"release-interior")) fpr_builtin_release(p+16);
  if (same(which,"forged-interior")) {
    /* A plausible copy of the real allocation header inside its own payload.
     * Header-only validation would accept it; an exact-start check must not. */
    uw prefix=p-(V)arena;
    V fake=p+128;
    for (uw i=0;i<prefix;i++) ((unsigned char *)(fake-prefix))[i]=arena[i];
    fpr_free(fake);
  }
  if (same(which,"shared-free")) { fpr_builtin_retain(p); fpr_free(p); }
  if (same(which,"shared-realloc")) { fpr_builtin_retain(p); fpr_realloc(p,1024); }
  if (same(which,"realloc-overflow")) fpr_realloc(p,UINTPTR_MAX);
  if (same(which,"rc-overflow")) { ((uw *)(p-16))[1]=UINTPTR_MAX; fpr_builtin_retain(p); }
  if (same(which,"field-index")) fpr_builtin_field_kind(p,0);
  if (same(which,"adt-layout")) fpr_builtin_alloc_adt(8,1);
  check(0,"negative case was accepted");
}
static void contracts(void) {
  V a=fpr_alloc(0);
  check(!(a&15) && capacity(a)>=16,"minimum capacity/alignment");
  expect(a,capacity(a),0); fpr_free(a); fpr_free(0);
  check(!fpr_realloc(0,0),"null realloc");
  a=fpr_alloc(16); V b=fpr_alloc(128), guard=fpr_alloc(16);
  uw old=capacity(a); fill(a,old,0xa5); fill(b,capacity(b),0xcc); fpr_free(b);
  V grown=fpr_realloc(a,old+64);
  check(grown==a,"adjacent free block grows in place");
  expect(grown,old,0xa5); expect(grown+old,capacity(grown)-old,0);
  check(fpr_realloc(grown,1)==grown,"shrinking preserves pointer");
  fpr_free(grown); fpr_free(guard);
  a=fpr_alloc(16); guard=fpr_alloc(16); old=capacity(a); fill(a,old,0x75);
  grown=fpr_realloc(a,4096); check(grown!=a,"guarded allocation moves");
  expect(grown,old,0x75); expect(grown+old,capacity(grown)-old,0);
  fpr_free(guard); fpr_free(grown);
  /* After varied sizes, freeing both neighbours must recover contiguous RAM. */
  for (unsigned i=0;i<96;i++) { slots[i]=fpr_alloc(i*17+1); fill(slots[i],capacity(slots[i]),0xff); }
  for (unsigned i=0;i<96;i+=2) fpr_free(slots[i]);
  for (unsigned i=1;i<96;i+=2) fpr_free(slots[i]);
  a=fpr_alloc(sizeof arena*99/100-256); expect(a,capacity(a),0); fpr_free(a);
  check(fpr_builtin_live_allocations()==0,"coalesced heap empty");
}
static unsigned random_state=17;
static unsigned next(void) { random_state=random_state*1664525u+1013904223u; return random_state; }
static void randomized(void) {
  for (unsigned round=0;round<12000;round++) {
    unsigned i=next()%96; uw n=next()%8192;
    expect(slots[i],lengths[i],(unsigned char)i);
    V p=fpr_realloc(slots[i],n);
    uw kept=n<lengths[i]?n:lengths[i]; expect(p,kept,(unsigned char)i);
    /* New allocations and all growth beyond the old rounded capacity are
     * zeroed; contents beyond the old requested length may already be live. */
    if (!slots[i] && n) expect(p,capacity(p),0);
    if (n) fill(p,n,(unsigned char)i);
    slots[i]=p; lengths[i]=n;
    if (round%3==0) { fpr_free(p); slots[i]=0; lengths[i]=0; }
  }
  for (unsigned i=0;i<96;i++) { fpr_free(slots[i]); slots[i]=0; lengths[i]=0; }
  check(fpr_builtin_live_allocations()==0,"randomized heap empty");
}
static void exact_layout(void) {
  static const struct { uint32_t tid,var; uw len; unsigned char bytes[2]; }
    descriptor={T_STR,0,2,{'t','w'}};
  V child=fpr_builtin_alloc_adt(8+sizeof(V),1);
  ((V *)(child+8))[0]=TAG(7);
  V root=fpr_builtin_alloc_adt(8+2*sizeof(V),2), guard=fpr_alloc(16);
  ((V *)(root+8))[0]=child; ((V *)(root+8))[1]=child;
  fpr_builtin_set_layout(root,(V)&descriptor);
  root=fpr_realloc(root,4096);
  check(fpr_builtin_field_count(root)==2,"realloc preserves exact field count");
  check(fpr_builtin_field_kind(root,0)=='t' && fpr_builtin_field_kind(root,1)=='w',"realloc preserves descriptor");
  fpr_free(guard); fpr_builtin_release(root);
  check(fpr_builtin_live_allocations()==0,"raw pointer field not released");
}
#ifndef HEAP_FREESTANDING
/* Exhaustion is recoverable only in this native test harness. Keeping all other
 * blocks live forces the allocator to reuse one of two unequal holes, with the
 * smaller hole freed last. There must be no false OOM from free-list ordering. */
static V try_allocate(uw n) {
  expected_oom=1;
  if (!setjmp(oom_target)) {
    V p=fpr_alloc(n); expected_oom=0; return p;
  }
  expected_oom=0; return 0;
}
static void exhaustion(void) {
  V larger=fpr_alloc(4000), guard1=fpr_alloc(16);
  V smaller=fpr_alloc(3900), guard2=fpr_alloc(16), rest=0, p;
  while ((p=try_allocate(16))) { *(V *)p=rest; rest=p; }
  fpr_free(larger); fpr_free(smaller);
  p=fpr_alloc(4000); check(p==larger,"fitting hole is found despite free ordering");
  fpr_free(p); fpr_free(guard1); fpr_free(guard2);
  while (rest) { p=rest; rest=*(V *)rest; fpr_free(p); }
  check(fpr_builtin_live_allocations()==0,"exhaustion recovery/coalescing");
}
#endif
static void work(unsigned count) {
#ifdef FPR_BUILTIN_HEAP_TEST
  fpr_builtin_heap_lookup_steps=fpr_builtin_heap_allocation_steps=0;
#endif
  uw start=cycles();
  V list=TAG(0);
  for (unsigned i=0;i<count;i++) {
    V node=fpr_builtin_alloc_adt(8+2*sizeof(V),2);
    ((V *)(node+8))[0]=TAG(i); ((V *)(node+8))[1]=list; list=node;
  }
  check(fpr_builtin_live_allocations()==count,"live list count");
  V alias=fpr_builtin_retain(list); fpr_builtin_release(list);
  check(fpr_builtin_live_allocations()==count,"shared root survives");
  fpr_builtin_release(alias);
  uw elapsed=cycles()-start;
  check(fpr_builtin_live_allocations()==0,"deep iterative release");
  put_text("HEAP WORK nodes="); put_number(count);
#ifdef FPR_BUILTIN_HEAP_TEST
  check(fpr_builtin_heap_allocation_steps<=2*(uw)count,"allocation work scales with operations");
  check(fpr_builtin_heap_lookup_steps<=4*(uw)count+16,"checked lookup work scales with operations");
  put_text(" allocations="); put_number(fpr_builtin_heap_allocation_steps);
  put_text(" lookups="); put_number(fpr_builtin_heap_lookup_steps);
#endif
  put_text(" cycles="); put_number(elapsed); put_character('\n');
}
#ifdef HEAP_CONFIG_ONLY
static void configured_arena(void) {
  for (unsigned round=0;round<1024;round++) {
    unsigned slot=round%32;
    if (slots[slot]) { expect(slots[slot],lengths[slot],(unsigned char)slot); fpr_free(slots[slot]); }
    uw n=(round%31)*16+1;
    slots[slot]=fpr_alloc(n); lengths[slot]=n;
    expect(slots[slot],capacity(slots[slot]),0); fill(slots[slot],n,(unsigned char)slot);
  }
  for (unsigned i=0;i<32;i++) { fpr_free(slots[i]); slots[i]=0; lengths[i]=0; }
  V large=fpr_alloc(sizeof arena*99/100-256);
  expect(large,capacity(large),0); fpr_free(large);
  check(fpr_builtin_live_allocations()==0,"configured-size coalescing");
  put_text("CONFIGURED BUILTIN HEAP HOLDS\n");
}
#endif
int main(int argc,char **argv) {
  initialize();
#ifdef HEAP_CASE
  (void)argc; (void)argv;
  negative(HEAP_CASE);
#else
  if (argc>1) negative(argv[1]);
#endif
#ifdef HEAP_CONFIG_ONLY
  configured_arena();
#else
#ifndef HEAP_WORK_ONLY
  contracts();
  /* contracts intentionally left stale pointers in the slot array. */
  for (unsigned i=0;i<96;i++) slots[i]=0;
  randomized(); exact_layout();
#ifndef HEAP_FREESTANDING
  exhaustion();
#endif
#endif
  work(512); work(2048); work(8192);
  put_text("INDEXED BUILTIN HEAP HOLDS\n"); return 0;
#endif
  return 0;
}
