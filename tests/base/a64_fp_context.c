#include "fpr.h"
#include <assert.h>
#include <stdio.h>
_Static_assert(FPR_CTX_WORDS==24,"hosted A64 context includes d8..d15");
static uw a[24],b[24],stack[16384];
static uint64_t seed_a[8],seed_b[8],out_a[8],out_b[8];
extern void fp_context_probe(uw*,uw*,uint64_t*,uint64_t*);
static void other(void){for(unsigned i=0;;i++){for(unsigned k=0;k<8;k++)seed_b[k]=UINT64_C(0xfff0000000000000)^(uint64_t)(i*31+k);fp_context_probe(b,a,seed_b,out_b);for(unsigned k=0;k<8;k++)assert(seed_b[k]==out_b[k]);}}
int main(void){b[0]=(uw)other;b[1]=(uw)(stack+16384);for(unsigned i=0;i<10000;i++){for(unsigned k=0;k<8;k++)seed_a[k]=UINT64_C(0x7ff8000000000000)^(uint64_t)(i*17+k);fp_context_probe(a,b,seed_a,out_a);for(unsigned k=0;k<8;k++)assert(seed_a[k]==out_a[k]);}puts("A64 FP context: 10000 round trips preserve all d8-d15 bit patterns PASS");}
