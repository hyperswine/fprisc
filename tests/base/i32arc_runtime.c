/* Owned I32 adapters and Result metadata, independently of FP lowering. */
#include "builtin.h"
#include "i32.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(V)==8,"I32 ARC currently requires a 64-bit target");
static _Alignas(16) unsigned char arena[2*1024*1024];
const hdr_t fpr_true={T_BOOL,1},fpr_false={T_BOOL,0},fpr_unit={T_UNIT,0};
void fpr_cpanic(const char *m) { fprintf(stderr,"%s\n",m);exit(3); }
void fpr_trap(const char *m) { fpr_cpanic(m); }
str_t *fpr_mkstr(const uint8_t *s,uw n) {
  str_t *r=(str_t *)fpr_alloc(sizeof(str_t)+n);
  r->tid=T_STR;r->var=0;r->len=n;memcpy(r->bytes,s,n);return r;
}
extern V fpr_fn__x24arc_x2eI32parse(V);
extern V fpr_fn__x24arc_x2eI32toInt(V);
extern V fpr_fn__x24arc_x2eI32toIntU(V);
extern V fpr_fn__x24arc_x2eI32str(V);

static V text(const char *s) { return (V)fpr_mkstr((const uint8_t *)s,strlen(s)); }
static void metadata(V r) {
  assert(TID(r)==T_RESULT);
  assert(fpr_builtin_field_count(r)==1);
  assert(fpr_builtin_field_kind(r,0)=='t');
}
int main(void) {
  fpr_builtin_heap_init(arena,arena+sizeof arena);
  for(unsigned round=0;round<10000;round++) {
    V input=text("invalid"),r=fpr_fn__x24arc_x2eI32parse(input);
    metadata(r);assert(((hdr_t *)r)->var==1);
    /* The three allocated cells become two after the consuming adapter
     * releases its input: only the Result and fresh error String remain. */
    assert(fpr_builtin_live_allocations()==2);
    assert(FPR_FLD(r,0)!=input && TID(FPR_FLD(r,0))==T_STR);
    fpr_builtin_release(r);assert(fpr_builtin_live_allocations()==0);

    input=text("0xffff_ffff");r=fpr_fn__x24arc_x2eI32parse(input);
    metadata(r);assert(((hdr_t *)r)->var==0);
    assert(fpr_i32_bits(FPR_FLD(r,0))==UINT32_MAX);
    assert(fpr_builtin_live_allocations()==1);
    fpr_builtin_release(r);assert(fpr_builtin_live_allocations()==0);

    r=fpr_fn__x24arc_x2eI32toInt(fpr_i32_pack(0x80000000u));
    metadata(r);assert(UNTAG(FPR_FLD(r,0))==-2147483648LL);
    fpr_builtin_release(r);
    r=fpr_fn__x24arc_x2eI32toIntU(fpr_i32_pack(UINT32_MAX));
    metadata(r);assert(UNTAG(FPR_FLD(r,0))==4294967295LL);
    fpr_builtin_release(r);
    r=fpr_fn__x24arc_x2eI32str(fpr_i32_pack(UINT32_MAX));
    assert(((str_t *)r)->len==2 && !memcmp(((str_t *)r)->bytes,"-1",2));
    fpr_builtin_release(r);assert(fpr_builtin_live_allocations()==0);

    input=text("bad");fpr_builtin_retain(input);
    r=fpr_fn__x24arc_x2eI32parse(input);metadata(r);
    assert(fpr_in_heap(input) && fpr_builtin_live_allocations()==3);
    fpr_builtin_release(r);assert(fpr_builtin_live_allocations()==1);
    fpr_builtin_release(input);assert(fpr_builtin_live_allocations()==0);
  }
  puts("I32 ARC: 10000 rounds, Result layouts and consuming adapters, zero live allocations");
}
