#include <stdint.h>
#ifndef __riscv
#include <stdio.h>
#include <stdlib.h>
#endif
struct boolean {uint32_t tid,var;} fpr_true={1,1},fpr_false={1,0};
static uintptr_t hart[64]={[0]=1000000,[58]=UINTPTR_MAX};
uintptr_t *probe_hart=hart;
#ifdef __riscv
void oracle_tick(void) { hart[0]=1000000; }
void oracle_finish(int code) { *(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){} }
#else
void fpr_fuel_exhausted(void) { hart[0]=1000000; }
#endif
void *fpr_stack_grow(void) { __builtin_trap(); }
#define DECL(n) extern uintptr_t fpr_fn_##n(uintptr_t,uintptr_t,uintptr_t)
DECL(chain64); DECL(chain32);
#define CMPS(b) DECL(cmp##b##lt); DECL(cmp##b##le); DECL(cmp##b##gt); DECL(cmp##b##ge); DECL(cmp##b##eq); DECL(cmp##b##ne)
CMPS(64); CMPS(32);
static double d(uint64_t u){ union {uint64_t u;double d;} x={u}; return x.d; }
static float f(uint32_t u){ union {uint32_t u;float f;} x={u};return x.f; }
static uint64_t bd(double d){union {double d;uint64_t u;} x={d};return x.u;}
static uint32_t bf(float f){union {float f;uint32_t u;} x={f};return x.u;}
static int nan64(uint64_t u){return (u&UINT64_C(0x7ff0000000000000))==UINT64_C(0x7ff0000000000000)&&(u&UINT64_C(0xfffffffffffff));}
static int nan32(uint32_t u){return (u&0x7f800000)==0x7f800000&&(u&0x7fffff);}
static int boolean(uintptr_t p){return ((struct boolean*)p)->var;}
#define COMPARE(b,x,y) (boolean(fpr_fn_cmp##b##lt(a,bb,c))!=(x<y)) + (boolean(fpr_fn_cmp##b##le(a,bb,c))!=(x<=y)) + (boolean(fpr_fn_cmp##b##gt(a,bb,c))!=(x>y)) + (boolean(fpr_fn_cmp##b##ge(a,bb,c))!=(x>=y)) + (boolean(fpr_fn_cmp##b##eq(a,bb,c))!=(x==y)) + (boolean(fpr_fn_cmp##b##ne(a,bb,c))!=(x!=y))
static int check64(uint64_t a,uint64_t bb,uint64_t c){
 volatile double m=d(a)*d(bb), x=m+d(c), sub=d(bb)-d(c), answer=x/sub;
 volatile double sub2=d(c)-d(a), add=d(bb)+d(c), y=sub2/add;
 uint64_t want=bd(answer),got=fpr_fn_chain64(a,bb,c);
 return !(want==got||(nan64(want)&&nan64(got))) + COMPARE(64,x,y);
}
static int check32(uint32_t a,uint32_t bb,uint32_t c){
 volatile float m=f(a)*f(bb), x=m+f(c), sub=f(bb)-f(c), answer=x/sub;
 volatile float sub2=f(c)-f(a), add=f(bb)+f(c), y=sub2/add;
 uint32_t want=bf(answer),got=fpr_fn_chain32(a,bb,c);
 return !(want==got||(nan32(want)&&nan32(got))) + COMPARE(32,x,y);
}
static uint64_t next(uint64_t *s){*s^=*s<<13;*s^=*s>>7;*s^=*s<<17;return *s;}
int main(void){
#ifdef __aarch64__
 uintptr_t old; __asm__ volatile("mov %0,x28":"=r"(old));
 __asm__ volatile("mov x28,%0"::"r"(hart):"memory");
#endif
#ifdef __riscv
 __asm__ volatile("mv tp,%0"::"r"(hart):"memory");
#endif
 uint64_t edges[]={0,UINT64_C(0x8000000000000000),1,UINT64_C(0x0010000000000000),UINT64_C(0x7fefffffffffffff),UINT64_C(0x3ff0000000000000),UINT64_C(0xbff0000000000000),UINT64_C(0x7ff0000000000000),UINT64_C(0xfff0000000000000),UINT64_C(0x7ff8000000000001),UINT64_C(0x7ff0000000000001)};
 uint32_t e32[]={0,0x80000000,1,0x00800000,0x7f7fffff,0x3f800000,0xbf800000,0x7f800000,0xff800000,0x7fc00001,0x7f800001};
 int bad=0;unsigned count=0;
 for(unsigned i=0;i<11;i++)for(unsigned j=0;j<11;j++)for(unsigned k=0;k<11;k++){bad+=check64(edges[i],edges[j],edges[k]);bad+=check32(e32[i],e32[j],e32[k]);count++;}
 uint64_t seed=UINT64_C(0x6a09e667f3bcc909);
 for(unsigned i=0;i<4096;i++){uint64_t a=next(&seed),b=next(&seed),c=next(&seed);bad+=check64(a,b,c);bad+=check32(a,b,c);count++;}
#ifdef __aarch64__
 __asm__ volatile("mov x28,%0"::"r"(old):"memory");
#endif
#ifdef __riscv
 const char *msg=bad?"FLOAT_TREE_FAIL\n":"FLOAT_TREE_PASS\n";volatile unsigned char *uart=(void*)0x10000000;
 for(;*msg;msg++){while(!(uart[5]&32)){}uart[0]=*msg;}
 *(volatile unsigned*)0x100000=bad?0x13333:0x5555;for(;;){}
#else
 printf("float trees: %u F64/F32 triples, six comparisons, exact rounding/signed-zero and NaN rules: %d mismatches\n",count,bad);return bad!=0;
#endif
}
