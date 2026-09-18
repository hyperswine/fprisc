/* Exact layouts and iterative destruction, independently of compiler lowering. */
#include "builtin.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static _Alignas(16) unsigned char arena[2*1024*1024];
void fpr_cpanic(const char *m){fprintf(stderr,"%s\n",m);exit(3);}
int main(void) {
  fpr_builtin_heap_init(arena,arena+sizeof arena);
  for(int round=0;round<4;round++) {
    V list=TAG(0);
    for(int i=0;i<12000;i++) {
      V node=fpr_builtin_alloc_adt(24,2);
      ((hdr_t *)node)->tid=T_LIST;
      ((V *)(node+8))[0]=TAG(i);
      ((V *)(node+8))[1]=list; /* transfer */
      list=node;
    }
    assert(fpr_builtin_live_allocations()==12000);
    V alias=fpr_builtin_retain(list);
    fpr_builtin_release(list);
    assert(fpr_builtin_live_allocations()==12000);
    fpr_builtin_release(alias);
    assert(fpr_builtin_live_allocations()==0);
  }
  V child=fpr_builtin_alloc_adt(16,1);
  ((V *)(child+8))[0]=TAG(4);
  V root=fpr_builtin_alloc_adt(32,1);
  ((V *)(root+8))[0]=child;
  ((V *)(root+8))[1]=child; /* outside declared layout: MUST NOT be traversed */
  fpr_builtin_release(root);
  assert(fpr_builtin_live_allocations()==0);
  child=fpr_builtin_alloc_adt(16,1);
  ((V *)(child+8))[0]=TAG(1);
  root=fpr_builtin_alloc_adt(24,2);
  ((V *)(root+8))[0]=child;
  ((V *)(root+8))[1]=fpr_builtin_retain(child);
  fpr_builtin_release(root);
  assert(fpr_builtin_live_allocations()==0);
  /* Raw bits equal to an actual heap pointer MUST NOT become owning edges. */
  static const struct { uint32_t tid,var; uw len; unsigned char bytes[5]; }
    layout={T_STR,0,5,{'t','w','a','d','f'}};
  child=fpr_builtin_alloc_adt(16,1);
  ((V *)(child+8))[0]=TAG(7);
  root=fpr_builtin_alloc_adt(48,5);
  for(int i=0;i<5;i++) ((V *)(root+8))[i]=child;
  fpr_builtin_set_layout(root,(V)&layout);
  fpr_builtin_release(root);
  assert(fpr_builtin_live_allocations()==0);
  puts("ARC LAYOUT AND DEEP RELEASE HOLD");
}
