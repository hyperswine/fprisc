/* Conservative heap tests with exact, explicitly supplied root sets. Native
 * sanitizers can check these roots without walking sanitizer stack redzones. */
#include "builtin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static _Alignas(16) unsigned char arena[256*1024];
static uw roots[8];
static int header_roots;
void fpr_cpanic(const char *s) { fprintf(stderr,"%s\n",s); exit(3); }
static void check(int ok,const char *s) { if(!ok){fprintf(stderr,"GC CHECK: %s\n",s);exit(1);} }
void fpr_builtin_gc_collect(void) {
  fpr_builtin_gc_begin(); fpr_builtin_gc_roots(roots,roots+8,header_roots); fpr_builtin_gc_end();
}
static void init(void) { memset(roots,0,sizeof roots); fpr_builtin_heap_init(arena,arena+sizeof arena); }
static uw capacity(V p) { return *(uw *)(p-16)-16; }
int main(int argc,char **argv) {
  init();
  if(argc>1 && !strcmp(argv[1],"live-oom")) {
    for(;;){V p=fpr_alloc(16384);*(V *)p=roots[0];roots[0]=p;}
  }
  V a=fpr_alloc(32),b=fpr_alloc(32);
  ((V *)a)[0]=b;((V *)b)[0]=a;((uw *)b)[1]=12345;
  roots[0]=a+3; /* odd byte-interior pointer, not a tagged-value filter */
  fpr_builtin_gc_collect();
  check(fpr_builtin_live_allocations()==2,"reachable cycle retained through interior root");
  check(((uw *)b)[1]==12345,"cycle data survives");
  roots[0]=0;fpr_builtin_gc_collect();
  a=fpr_alloc(32);b=fpr_alloc(32);roots[0]=a+capacity(a);header_roots=1;
  fpr_builtin_gc_collect();
  check(fpr_builtin_live_allocations()==2,"ambiguous one-past pointer retains previous payload and next header");
  header_roots=0;roots[0]=0;fpr_builtin_gc_collect();
  a=fpr_alloc(32);roots[0]=a-8;header_roots=1;
  fpr_builtin_gc_collect();check(fpr_builtin_live_allocations()==1,"C metadata-field root retained");
  header_roots=0;roots[0]=0;fpr_builtin_gc_collect();
  check(fpr_builtin_live_allocations()==0,"unreachable cycle collected");
  a=fpr_alloc(65);roots[0]=a+capacity(a);
  fpr_builtin_gc_collect();check(fpr_builtin_live_allocations()==1,"one-past-end root retained");
  roots[0]=0;fpr_builtin_gc_collect();
  for(unsigned i=0;i<2000;i++) {a=fpr_alloc(2*sizeof(uw));((V *)a)[0]=roots[0];((uw *)a)[1]=i;roots[0]=a;}
  fpr_builtin_gc_collect();
  a=roots[0];for(unsigned i=2000;i;i--){check(((uw *)a)[1]==i-1,"deep graph content");a=*(V *)a;}
  check(!a && fpr_builtin_live_allocations()==2000,"iterative tracing");
  roots[0]=0;fpr_builtin_gc_collect();
  check(fpr_builtin_live_allocations()==0,"deep graph reclaimed");
  a=fpr_alloc(4096);roots[0]=a;
  for(unsigned i=0;i<4096;i++)((unsigned char *)a)[i]=0x75;
  for(unsigned i=0;i<100;i++)(void)fpr_alloc(8192);
  for(unsigned i=0;i<4096;i++)check(((unsigned char *)a)[i]==0x75,"root survives automatic pressure collection");
  a=fpr_realloc(a,8192);roots[0]=a;
  for(unsigned i=0;i<4096;i++)check(((unsigned char *)a)[i]==0x75,"realloc contents");
  for(unsigned i=4096;i<8192;i++)check(((unsigned char *)a)[i]==0,"realloc zero tail");
  fpr_free(a);roots[0]=0;fpr_builtin_gc_collect();
  check(fpr_builtin_live_allocations()==0,"manual free and GC coexist");
  /* False-looking headers and stale roots must never authenticate storage. */
  a=fpr_alloc(512);V fake=a+128;((uw *)fake)[-2]=128;((uw *)fake)[-1]=1;
  roots[0]=fake;roots[1]=(uw)arena+sizeof arena+32;roots[2]=1;
  fpr_builtin_gc_collect();check(fpr_builtin_live_allocations()==1,"forged interior is only parent retention");
  memset(roots,0,sizeof roots);fpr_builtin_gc_collect();
  a=fpr_alloc(240*1024); /* requires coalescing many swept neighbours */
  check(a!=0,"sweep coalesces reusable extent");fpr_free(a);
  fpr_builtin_heap_stats s;fpr_builtin_heap_get_stats(&s);
  check(!s.live_bytes && s.collections>5 && s.reclaimed_bytes>sizeof arena,"collection accounting");
  puts("CONSERVATIVE HEAP HOLDS");return 0;
}
