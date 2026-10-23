/* Actual heap and register/root scanner; generated frames carry the roots. */
#include "builtin.h"
#include <stdint.h>
extern char _heap_start[],_heap_end[];
extern V fpr_fn_main(void);
const hdr_t fpr_unit={0,0},fpr_false={1,0},fpr_true={1,1};
static uw hart[64];
static unsigned reports;
static void text(const char*s){
#ifdef PHYSICAL_BOARD
 volatile uint32_t*u=(void*)0x10000000;for(;*s;s++){while(!(u[1]&1)){}u[0]=(uint8_t)*s;}
#else
 volatile uint8_t*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}
#endif
}
static __attribute__((noreturn)) void finish(int code){
#ifdef PHYSICAL_BOARD
 text(code?"FPR EXIT 1\n":"FPR EXIT 0\n");
#endif
 *(volatile uint32_t*)0x100000=code?0x13333:0x5555;for(;;){};}
void fpr_cpanic(const char*s){text(s);text("\n");finish(1);}
void fpr_panic(V s){(void)s;fpr_cpanic("GENERATED GC FAILURE");__builtin_unreachable();}
#define CHECK(x) do{if(!(x))fpr_cpanic("GENERATED GC CHECK FAILED");}while(0)
V fpr_prim_fn__x2b(V a,V b){return TAG(UNTAG(a)+UNTAG(b));}
V fpr_prim_fn__x2d(V a,V b){return TAG(UNTAG(a)-UNTAG(b));}
V fpr_prim_fn__x3d_x3d(V a,V b){return a==b?(V)&fpr_true:(V)&fpr_false;}
static V stress(V u){(void)u;for(int i=0;i<24;i++){V p=fpr_alloc(512);((uw*)p)[0]=i;}fpr_builtin_gc_collect();return (V)&fpr_unit;}
static V report(V n){CHECK(UNTAG(n)==6290);reports++;return (V)&fpr_unit;}
FPR_FN(fpr_g_GC_x2estress,stress,1);
FPR_FN(fpr_g_GC_x2ereport,report,1);
#ifdef BENCH_GUEST
static uw retired(void){uw n;__asm__ volatile("rdinstret %0":"=r"(n)::"memory");return n;}
static void hex(uw n){static const char digits[]="0123456789abcdef";char out[2*sizeof(uw)+1];for(unsigned i=0;i<2*sizeof(uw);i++)out[i]=digits[(n>>(4*(2*sizeof(uw)-i-1)))&15];out[2*sizeof(uw)]=0;text(out);}
#endif
int main(void){
 __asm__ volatile("mv tp,%0"::"r"(hart):"memory");
 fpr_builtin_heap_init(_heap_start,_heap_start+65536);
#ifdef BENCH_GUEST
 uw began=retired();
#endif
 CHECK(fpr_fn_main()==(V)&fpr_unit&&reports==1);
#ifdef BENCH_GUEST
 uw instructions=retired()-began;
#endif
 fpr_builtin_heap_stats stats;fpr_builtin_heap_get_stats(&stats);
 CHECK(stats.collections>2000&&stats.reclaimed_bytes>1000000&&stats.peak_bytes<65536);
#ifdef BENCH_GUEST
 text("GUEST_INSNS=");hex(instructions);text("\n");
#endif
 text("TYPED_BUILTIN_GC_PASS: 12 live roots, recursive frames, 12 arguments, allocation-stress collection\n");finish(0);
}
