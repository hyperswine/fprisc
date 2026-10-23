/* Real actor runtime beside the independently emitted 9000-field IR frame.
 * Recursing from the last callback holds 8999 earlier values across each
 * nested generated call. Only one actor accesses these oracle counters. */
#include "fpr.h"
#if defined(__x86_64__)
extern V fpr_fn_large(V,V,V,V,V,V);
extern FPR_TLS uw fpr_x64_a6,fpr_x64_a7;
#else
extern V fpr_fn_large(V,V,V,V,V,V,V,V);
#endif
static unsigned depth,calls;
static void check(V p){
 if(TID(p)!=42 || ((hdr_t*)p)->var!=9000)fpr_cpanic("large actor frame object header");
 for(unsigned i=0;i<9000;i++)
  if(*(V*)((char*)p+8+i*sizeof(V))!=TAG(100+(i%64)+i))fpr_cpanic("large actor frame held value");
}
static V invoke(void){
 V*cells=(V*)fpr_hart();
 for(unsigned i=8;i<64;i++)cells[1+i-8]=TAG(100+i);
 cells[0]=1;calls++;
#if defined(__x86_64__)
 fpr_x64_a6=TAG(106);fpr_x64_a7=TAG(107);
 return fpr_fn_large(TAG(100),TAG(101),TAG(102),TAG(103),TAG(104),TAG(105));
#else
 return fpr_fn_large(TAG(100),TAG(101),TAG(102),TAG(103),TAG(104),TAG(105),TAG(106),TAG(107));
#endif
}
V oracle_id(V x,V n){
 if(UNTAG(n)==8999 && depth){depth--;V child=invoke();check(child);fpr_hart()->fuel=1;}
 return TAG(UNTAG(x)+UNTAG(n));
}
V oracle_tail(V p){return p;}
static V deep(V u){(void)u;depth=8;calls=0;V p=invoke();check(p);
 if(depth || calls!=9)fpr_cpanic("large actor frame recursion");return TAG(9);}
FPR_FN(fpr_g_Reserve_x2edeep,deep,1);
