/* Time the same emitted maps as the correctness oracle; descriptor setup
 * and answer checking are outside the clock. Large fuel prevents yields. */
#define main captured_oracle_main
#include "captured_simd_oracle.c"
#undef main
#include <time.h>
static uint64_t now_ns(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
int main(int argc,char**argv){
 int floating=argc>1&&argv[1][0]=='f';
 V cells[128];for(int i=0;i<128;i++)cells[i]=floating?bits(i+0.25):i;
 uint8_t kinds[]={floating?3:1};Col col={128,cells};Col*cols[]={&col};Vec v={9006,floating?4:1,128,0,0,1,kinds,cols};
 hart[57]=0;hart[58]=(V)UINTPTR_MAX;hart[0]=INTPTR_MAX/2;
 uint64_t start=now_ns();
 for(int i=0;i<100000;i++){
  V result=floating?fpr_fn_probeAffine(bits(1),bits(0),(V)&v):fpr_fn_probeAdd(tag(0),(V)&v);
  CHECK(result==(V)&v);
 }
 uint64_t took=now_ns()-start;
 for(int i=0;i<128;i++)CHECK(cells[i]==(floating?bits(i+0.25):i));
 CHECK(yields==0&&fallbacks==0);
 printf("%llu\n",(unsigned long long)took);
}
