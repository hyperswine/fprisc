/* Independent raw-word oracle for captured maps. The harness speaks the
 * generated word ABI; C's own ABI does not pass doubles to these entries. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef intptr_t V;
struct Bool { uint32_t tid,var; } fpr_unit={0,0},fpr_false={1,0},fpr_true={1,1};
static V hart[64];
void *probe_hart=hart;
V probe_a6,probe_a7;
static unsigned yields,fallbacks;
#ifndef TRAP_CASE
#define TRAP_CASE 0
#endif
#define CHECK(x) do { if(!(x)) {fprintf(stderr,"captured SIMD oracle line %d\n",__LINE__);exit(1);} } while(0)
static V tag(V n){return (V)(((uintptr_t)n<<1)|1);}
void fpr_fuel_exhausted(void){
 hart[0]=1;yields++;
 /* A hostile C call destroys caller-saved lane/scratch registers. Captures
  * must survive in preserved registers or spill slots across this call. */
#ifdef __aarch64__
 __asm__ volatile("movi v16.16b,#0; movi v17.16b,#0; movi v18.16b,#0; movi v19.16b,#0; movi v20.16b,#0; movi v21.16b,#0; movi v22.16b,#0; movi v23.16b,#0; movi v24.16b,#0; movi v25.16b,#0; movi v26.16b,#0; movi v27.16b,#0; movi v28.16b,#0; movi v29.16b,#0; movi v30.16b,#0; movi v31.16b,#0" ::: "v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31");
#else
 __asm__ volatile("pxor %%xmm8,%%xmm8; pxor %%xmm9,%%xmm9; pxor %%xmm10,%%xmm10; pxor %%xmm11,%%xmm11; pxor %%xmm12,%%xmm12; pxor %%xmm13,%%xmm13; pxor %%xmm14,%%xmm14; pxor %%xmm15,%%xmm15" ::: "xmm8","xmm9","xmm10","xmm11","xmm12","xmm13","xmm14","xmm15");
#endif
}
void *fpr_stack_grow(void){abort();}
void fpr_int_overflow_kernel(void){if(TRAP_CASE){puts("CAPTURED_SIMD_TRAP_PASS");exit(0);}abort();}
void fpr_div_zero_kernel(void){abort();}
V fpr_panic(V v){(void)v;abort();}
V fpr_apply(V h,V a){(void)a;return h;}
V fpr_applyN(V h,V n,V *a){(void)n;(void)a;return h;}
V fpr_vec_map(V f,V v){(void)f;(void)v;fallbacks++;return 123;}
V fpr_prim_fn__x2b(V a,V b){return tag((a>>1)+(b>>1));}
V fpr_prim_fn__x2d(V a,V b){return tag((a>>1)-(b>>1));}
V fpr_prim_fn_F64_x2eofInt(V a){union{double d;V v;}u={.d=(double)(a>>1)};return u.v;}
typedef struct{V cap,*base;}Col;
typedef struct{uint32_t tid,rep;V len,tidEl,varEl,ncols;uint8_t*kinds;Col**cols;}Vec;
extern V fpr_fn_probeAdd(V,V),fpr_fn_probeSub(V,V),fpr_fn_probeRsub(V,V),fpr_fn_probeLong(V,V);
extern V fpr_fn_probeAffine(V,V,V),fpr_fn_probeWide(V,V,V,V,V,V,V,V);
static V bits(double d){union{double d;V v;}u={.d=d};return u.v;}
static double num(V v){union{double d;V v;}u={.v=v};return u.d;}
static int equal(V got,V want){double a=num(got),b=num(want);return got==want||(a!=a&&b!=b);}
static uint64_t next(uint64_t*s){*s^=*s<<13;*s^=*s>>7;*s^=*s<<17;return *s;}
static V affine(V x,V a,V b){volatile double m=num(x)*num(a),v=m+num(b);return bits(v);}
static V wide(V x,V*c){volatile double m=num(x)*num(c[0]),a=m+num(c[1]),b=a-num(c[2]),d=b+num(c[3]),e=d-num(c[4]),f=e+num(c[5]),g=f-num(c[6]);return bits(g);}
int main(void){
#ifdef __aarch64__
 V old;__asm__ volatile("mov %0,x28":"=r"(old));__asm__ volatile("mov x28,%0"::"r"(hart):"memory");
#endif
 hart[57]=0;hart[58]=(V)UINTPTR_MAX;hart[0]=1;
 V cells[130],original[130];uint8_t kinds[]={1};Col col={128,cells+1};Col*cols[]={&col};Vec v={9006,1,0,0,0,1,kinds,cols};
 if(TRAP_CASE){
  V top=INTPTR_MAX/2,bottom=-top-1;v.len=2;cells[1]=0;cells[2]=0;
  if(TRAP_CASE<=2){cells[TRAP_CASE]=top;fpr_fn_probeAdd(tag(1),(V)&v);}
  else if(TRAP_CASE<=4){cells[TRAP_CASE-2]=bottom;fpr_fn_probeSub(tag(1),(V)&v);}
  else {cells[TRAP_CASE-4]=bottom;fpr_fn_probeRsub(tag(0),(V)&v);}
  CHECK(0);
 }
 unsigned cases=0;
 for(int n=0;n<66;n++)for(int c=-4;c<=4;c++)for(int op=0;op<4;op++){
  v.len=n;v.cols=n?cols:0;hart[0]=1;
  for(int i=0;i<130;i++)cells[i]=original[i]=i-30;
  V answer=op==0?fpr_fn_probeAdd(tag(c),(V)&v):op==1?fpr_fn_probeSub(tag(c),(V)&v):op==2?fpr_fn_probeRsub(tag(c),(V)&v):fpr_fn_probeLong(tag(c),(V)&v);
  CHECK(answer==(V)&v&&v.len==n);
  for(int i=0;i<130;i++){V x=original[i],want=i>=1&&i<=n?(op==0?x+c:op==1?x-c:op==2?c-x:x):x;CHECK(cells[i]==want);}cases++;
 }
 /* Captures near both tagged-Int limits must be untagged without losing
  * their upper bits. Choose lane signs so each checked result fits. */
 V limits[]={INTPTR_MAX/2,-INTPTR_MAX/2-1,INTPTR_MAX/2-1,-INTPTR_MAX/2,0};
 for(unsigned c=0;c<5;c++)for(int op=0;op<3;op++){
  V cap=limits[c];v.len=3;v.cols=cols;hart[0]=1;
  V x=cap>0?1:-1;
  if(op==0)x=-x;
  for(int i=0;i<3;i++)cells[i+1]=x;
  V answer=op==0?fpr_fn_probeAdd(tag(cap),(V)&v):op==1?fpr_fn_probeSub(tag(cap),(V)&v):fpr_fn_probeRsub(tag(cap),(V)&v);
  CHECK(answer==(V)&v);
  V want=op==0?x+cap:op==1?x-cap:cap-x;
  for(int i=0;i<3;i++)CHECK(cells[i+1]==want);
  cases++;
 }
 /* Aggregating two lane ticks must preserve the scalar logical charge,
  * even though forced-yield counts differ between pair and scalar loops. */
 for(int n=0;n<66;n++){
  v.len=n;v.cols=n?cols:0;hart[0]=1000000;
  for(int i=0;i<130;i++)cells[i]=0;
  unsigned before=yields;
  CHECK(fpr_fn_probeAdd(tag(3),(V)&v)==(V)&v);
  CHECK(hart[0]==1000000-n-2&&yields==before);
 }
 uint64_t edges[]={0,UINT64_C(0x8000000000000000),1,UINT64_C(0x0010000000000000),UINT64_C(0x7fefffffffffffff),UINT64_C(0x3ff0000000000000),UINT64_C(0xbff0000000000000),UINT64_C(0x7ff0000000000000),UINT64_C(0xfff0000000000000),UINT64_C(0x7ff8000000000001),UINT64_C(0x7ff0000000000001)};
 uint64_t seed=UINT64_C(0x123456789abcdef);
 for(int trial=0;trial<11*11+2048;trial++)for(int op=0;op<2;op++){
  int n=trial<121?trial%34:2+trial%3;v.len=n;v.cols=n?cols:0;v.rep=4;kinds[0]=3;hart[0]=1;
  V c[7];for(int j=0;j<7;j++)c[j]=trial<121?(V)edges[(trial/11+j)%11]:(V)next(&seed);
  for(int i=0;i<130;i++)cells[i]=original[i]=trial<121?(V)edges[(trial+i)%11]:(V)next(&seed);
  probe_a6=c[6];probe_a7=(V)&v; /* generated x64 parameters 7/8 use these cells */
  CHECK((op==0?fpr_fn_probeAffine(c[0],c[1],(V)&v):fpr_fn_probeWide(c[0],c[1],c[2],c[3],c[4],c[5],c[6],(V)&v))==(V)&v);
  CHECK(v.len==n);
  for(int i=0;i<130;i++){V want=i>=1&&i<=n?(op==0?affine(original[i],c[0],c[1]):wide(original[i],c)):original[i];CHECK(equal(cells[i],want));}cases++;
 }
 v.rep=1;v.len=2;v.cols=cols;kinds[0]=1;
 CHECK(fpr_fn_probeAdd((V)&fpr_unit,(V)&v)==123);
 kinds[0]=3;CHECK(fpr_fn_probeAdd(tag(1),(V)&v)==123);
 CHECK(fallbacks==2&&yields>1000);
#ifdef __aarch64__
 __asm__ volatile("mov x28,%0"::"r"(old):"memory");
#endif
 printf("CAPTURED_SIMD_PASS %u cases: Int/F64, seven captures, tails, canaries, IEEE edges/randoms, fallbacks, %u hostile yields\n",cases,yields);
}
