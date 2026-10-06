/* GCC soft-float ABI bridge to Berkeley SoftFloat 3e (RISCV specialization).
 * No hardware F/D, A or C instructions are needed. Rounding is nearest-even;
 * SoftFloat exception flags are internal, with no architectural fcsr on IM.
 */
#include <stdint.h>
#include "softfloat.h"
static float64_t d64(double x){union {double d;uint64_t u;}v={.d=x};return (float64_t){v.u};}
static double from64(float64_t x){union {double d;uint64_t u;}v={.u=x.v};return v.d;}
static float32_t d32(float x){union {float f;uint32_t u;}v={.f=x};return (float32_t){v.u};}
static float from32(float32_t x){union {float f;uint32_t u;}v={.u=x.v};return v.f;}
#define B64(name,op) double name(double a,double b){return from64(op(d64(a),d64(b)));}
#define B32(name,op) float name(float a,float b){return from32(op(d32(a),d32(b)));}
B64(__adddf3,f64_add) B64(__subdf3,f64_sub) B64(__muldf3,f64_mul) B64(__divdf3,f64_div)
B32(__addsf3,f32_add) B32(__subsf3,f32_sub) B32(__mulsf3,f32_mul) B32(__divsf3,f32_div)
double sqrt(double x){return from64(f64_sqrt(d64(x)));}
float sqrtf(float x){return from32(f32_sqrt(d32(x)));}
static int nan64(float64_t a){return (a.v&UINT64_C(0x7ff0000000000000))==UINT64_C(0x7ff0000000000000) && (a.v&UINT64_C(0xfffffffffffff));}
static int nan32(float32_t a){return (a.v&0x7f800000)==0x7f800000 && (a.v&0x7fffff);}
static int cmp64(double a,double b,int unordered){float64_t x=d64(a),y=d64(b);if(nan64(x)||nan64(y))return unordered;return f64_eq(x,y)?0:(f64_lt(x,y)?-1:1);}
static int cmp32(float a,float b,int unordered){float32_t x=d32(a),y=d32(b);if(nan32(x)||nan32(y))return unordered;return f32_eq(x,y)?0:(f32_lt(x,y)?-1:1);}
int __eqdf2(double a,double b){return cmp64(a,b,1);}int __nedf2(double a,double b){return cmp64(a,b,1);}
int __ledf2(double a,double b){return cmp64(a,b,1);}int __ltdf2(double a,double b){return cmp64(a,b,1);}
int __gedf2(double a,double b){return cmp64(a,b,-1);}int __gtdf2(double a,double b){return cmp64(a,b,-1);}
int __unorddf2(double a,double b){return nan64(d64(a))||nan64(d64(b));}
int __eqsf2(float a,float b){return cmp32(a,b,1);}int __nesf2(float a,float b){return cmp32(a,b,1);}
int __lesf2(float a,float b){return cmp32(a,b,1);}int __ltsf2(float a,float b){return cmp32(a,b,1);}
int __gesf2(float a,float b){return cmp32(a,b,-1);}int __gtsf2(float a,float b){return cmp32(a,b,-1);}
int __unordsf2(float a,float b){return nan32(d32(a))||nan32(d32(b));}
double __floatsidf(int32_t x){return from64(i32_to_f64(x));}
double __floatdidf(int64_t x){return from64(i64_to_f64(x));}
double __floatunsidf(uint32_t x){return from64(ui32_to_f64(x));}
double __floatundidf(uint64_t x){return from64(ui64_to_f64(x));}
float __floatsisf(int32_t x){return from32(i32_to_f32(x));}
float __floatdisf(int64_t x){return from32(i64_to_f32(x));}
float __floatunsisf(uint32_t x){return from32(ui32_to_f32(x));}
float __floatundisf(uint64_t x){return from32(ui64_to_f32(x));}
int32_t __fixdfsi(double x){return f64_to_i32_r_minMag(d64(x),0);}
int64_t __fixdfdi(double x){return f64_to_i64_r_minMag(d64(x),0);}
uint32_t __fixunsdfsi(double x){return f64_to_ui32_r_minMag(d64(x),0);}
uint64_t __fixunsdfdi(double x){return f64_to_ui64_r_minMag(d64(x),0);}
int32_t __fixsfsi(float x){return f32_to_i32_r_minMag(d32(x),0);}
int64_t __fixsfdi(float x){return f32_to_i64_r_minMag(d32(x),0);}
uint32_t __fixunssfsi(float x){return f32_to_ui32_r_minMag(d32(x),0);}
uint64_t __fixunssfdi(float x){return f32_to_ui64_r_minMag(d32(x),0);}
double __extendsfdf2(float x){return from64(f32_to_f64(d32(x)));}
float __truncdfsf2(double x){return from32(f64_to_f32(d64(x)));}
int __clzdi2(uint64_t x){int n=0;while(n<64 && !(x>>63)){n++;x<<=1;}return n;}
int __clzsi2(uint32_t x){int n=0;while(n<32 && !(x>>31)){n++;x<<=1;}return n;}
int __ctzdi2(uint64_t x){int n=0;while(n<64 && !(x&1)){n++;x>>=1;}return n;}
int __ctzsi2(uint32_t x){int n=0;while(n<32 && !(x&1)){n++;x>>=1;}return n;}
int __popcountdi2(uint64_t x){int n=0;while(x){n+=x&1;x>>=1;}return n;}
int __popcountsi2(uint32_t x){return __popcountdi2(x);}
