/* Host sanitizer regression for the standalone heap and explicit RC ABI. */
#include "builtin.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static _Alignas(16) unsigned char arena[1024*1024];
void fpr_cpanic(const char *m) { fprintf(stderr,"%s\n",m); exit(3); }
static unsigned rng=17;
static unsigned next(void){rng=rng*1664525u+1013904223u;return rng;}
int main(int argc,char **argv) {
  fpr_builtin_heap_init(arena,arena+sizeof arena);
  if(argc>1) {
    if(!strcmp(argv[1],"overflow"))fpr_alloc(UINTPTR_MAX);
    V p=fpr_alloc(32);
    if(!strcmp(argv[1],"double-free")){fpr_free(p);fpr_free(p);}
    if(!strcmp(argv[1],"shared-realloc")){fpr_builtin_retain(p);fpr_realloc(p,64);}
    return 1;
  }
  V slots[96]={0}; size_t lengths[96]={0};
  for(unsigned iteration=0;iteration<20000;iteration++) {
    unsigned i=next()%96;
    for(size_t j=0;j<lengths[i];j++)assert(((unsigned char *)slots[i])[j]==i);
    size_t n=next()%2048;
    V p=fpr_realloc(slots[i],n);
    for(size_t j=0;j<(n<lengths[i]?n:lengths[i]);j++)assert(((unsigned char *)p)[j]==i);
    if(n)memset((void *)p,i,n);
    slots[i]=p;lengths[i]=n;
    if(iteration%3==0){fpr_free(p);slots[i]=0;lengths[i]=0;}
  }
  for(unsigned i=0;i<96;i++)fpr_free(slots[i]);
  V large=fpr_alloc(sizeof arena-128); fpr_free(large); /* coalesced */
  for(int i=0;i<20000;i++) {
    V child=fpr_alloc(16); ((hdr_t *)child)->tid=100;
    ((V *)(child+8))[0]=TAG(-5);
    V root=fpr_alloc(24); ((hdr_t *)root)->tid=T_TUP2;
    ((V *)(root+8))[0]=child;
    ((V *)(root+8))[1]=fpr_builtin_retain(child);
    V alias=fpr_builtin_retain(root);
    fpr_builtin_release(root);
    assert(((V *)(child+8))[0]==TAG(-5));
    fpr_builtin_release(alias); /* both edges release; child freed once */
  }
  large=fpr_alloc(sizeof arena-128);fpr_free(large);
  puts("BUILTIN HEAP HOLDS");
}
