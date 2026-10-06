#include <stdint.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
extern double __adddf3(double,double),__subdf3(double,double),__muldf3(double,double),__divdf3(double,double),__floatdidf(int64_t),__extendsfdf2(float),sqrt(double);
extern int64_t __fixdfdi(double);
extern float __truncdfsf2(double);
extern int __ledf2(double,double),__gedf2(double,double),__unorddf2(double,double);
static uint64_t bits(double x){uint64_t u;memcpy(&u,&x,8);return u;}
static double val(uint64_t u){double x;memcpy(&x,&u,8);return x;}
int main(void){
 assert(bits(__adddf3(1.5,2.25))==UINT64_C(0x400e000000000000));
 assert(bits(__subdf3(1.0,1.5))==UINT64_C(0xbfe0000000000000));
 assert(bits(__muldf3(1.5,2.0))==UINT64_C(0x4008000000000000));
 assert(bits(__divdf3(1.0,0.0))==UINT64_C(0x7ff0000000000000));
 assert(bits(__floatdidf(INT64_C(4294967297)))==UINT64_C(0x41f0000000100000));
 assert(__fixdfdi(-7.5)==-7);
 assert(bits(__extendsfdf2(.5f))==UINT64_C(0x3fe0000000000000));
 float f=__truncdfsf2(.1);uint32_t u;memcpy(&u,&f,4);assert(u==0x3dcccccd);
 assert(bits(sqrt(81.0))==UINT64_C(0x4022000000000000));
 double nan=val(UINT64_C(0x7ff8000000000000));assert(__ledf2(nan,1.0)>0 && __gedf2(nan,1.0)<0 && __unorddf2(nan,1.0));
 puts("PASS: software float ABI, arithmetic, conversions, NaN comparison and sqrt");
}
