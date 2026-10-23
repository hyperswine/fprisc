/* Custom-ABI oracle: 64 incoming values, >64KiB RV64 frame, SP restoration,
 * a foreign tail and self-loop. The substitute reserve has explicit windows
 * and clobbers every hart argument cell; production runtime is tested apart. */
#include <stdint.h>
typedef intptr_t V;
typedef uintptr_t U;
static V hart[64];
static V heap[131072], expected[64];
static _Alignas(16) unsigned char chunks[8][256*1024];
static unsigned used,reserves,ticks,chunk,mode,loop_probe;
static U min_sp,max_sp;
U oracle_entry_sp;
V (*oracle_target)(V,V,V,V,V,V,V,V);
extern V fpr_fn_large(V,V,V,V,V,V,V,V),fpr_fn_tailLarge(V,V,V,V,V,V,V,V),fpr_fn_loopLarge(V,V,V,V,V,V,V,V);
extern V oracle_invoke(V,V,V,V,V,V,V,V);
static V tag(V n){return (V)(((U)n<<1)|1);}
static void say(const char *s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
__attribute__((noreturn)) void oracle_finish(int code){
 if(code){char b[16];unsigned n=0,x=code;do{b[n++]='0'+x%10;x/=10;}while(x);while(n){char q[]={b[--n],0};say(q);}say("\n");}
 *(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){}
}
#define CHECK(x) do{if(!(x))oracle_finish(__LINE__);}while(0)
U fpr_stack_grow(void){oracle_finish(__LINE__);}
U oracle_reserve(U sp,U bytes){
 CHECK(sp==oracle_entry_sp && bytes>1024 && bytes<sizeof(chunks[0])-65536);
 reserves++;
 for(int i=1;i<=56;i++)hart[i]=tag(-999);
 if(mode==1){hart[57]=sp-bytes-65536;hart[58]=bytes+131072;return 0;}
 CHECK(chunk<8);unsigned char *base=chunks[chunk++];
 for(unsigned i=0;i<65536;i++)base[i]=0xa7;
 hart[57]=(V)(base+65536);hart[58]=sizeof(chunks[0])-65536;
 return (U)(base+sizeof(chunks[0]));
}
void oracle_tick(void){hart[0]=1;ticks++;for(int i=1;i<=56;i++)hart[i]=tag(-777);}
V oracle_id(V x,V n){
 if(loop_probe){U sp=(U)__builtin_frame_address(0);if(sp<min_sp)min_sp=sp;if(sp>max_sp)max_sp=sp;}
 return tag((x>>1)+(n>>1));
}
V fpr_alloc(V bytes){CHECK(bytes>=8 && used+(bytes+sizeof(V)-1)/sizeof(V)<131072);V p=(V)&heap[used];used+=(bytes+sizeof(V)-1)/sizeof(V);return p;}
void fpr_int_overflow_kernel(void){oracle_finish(__LINE__);}
void fpr_div_zero_kernel(void){oracle_finish(__LINE__);}
V oracle_tail(V p){CHECK((U)__builtin_frame_address(0)==oracle_entry_sp);return p;}
static void check_object(V p,int n){
 CHECK(((uint32_t*)p)[0]==42 && ((uint32_t*)p)[1]==(unsigned)n);
 for(int i=0;i<n;i++)CHECK(*(V*)((char*)p+8+i*sizeof(V))==tag((expected[i%64]>>1)+i));
}
int main(void){
 __asm__ volatile("mv tp,%0"::"r"(hart):"memory");
 for(int phase=0;phase<5;phase++){
  for(int i=0;i<64;i++)expected[i]=tag(100+i);
  if(phase==4)expected[0]=tag(3);
  for(int i=8;i<64;i++)hart[i-7]=expected[i];
  hart[0]=1;mode=phase==1?1:0;
  U sp;__asm__ volatile("mv %0,sp":"=r"(sp));
  if(phase==2){hart[57]=sp-1024*1024;hart[58]=1024*1024+65536;}else{hart[57]=sp+1024;hart[58]=1;}
  unsigned before=reserves;
  oracle_target=phase==3?fpr_fn_tailLarge:phase==4?fpr_fn_loopLarge:fpr_fn_large;
  loop_probe=phase==4;min_sp=UINTPTR_MAX;max_sp=0;
  V p=oracle_invoke(expected[0],expected[1],expected[2],expected[3],expected[4],expected[5],expected[6],expected[7]);
  U after;__asm__ volatile("mv %0,sp":"=r"(after));CHECK(after==sp);
#ifdef SELF_LOOPS
  CHECK(reserves==before+(phase!=2));
#else
  CHECK(reserves==before+(phase==4?4:phase!=2));
#endif
  if(phase==4){expected[0]=tag(0);
#ifdef SELF_LOOPS
   CHECK(min_sp==max_sp);
#else
   CHECK(max_sp-min_sp>1024);
#endif
  }
  check_object(p,phase>=3?512:9000);
  for(unsigned c=0;c<chunk;c++)for(unsigned i=0;i<65536;i++)CHECK(chunks[c][i]==0xa7);
 }
#ifdef SELF_LOOPS
 CHECK(ticks>=5 && reserves==4 && chunk==3);
#else
 CHECK(ticks>=8 && reserves==7 && chunk==6);
#endif
 say("RV_SIZED_FRAMES_PASS 64 arguments, fast/same/new stacks, return/tail, callee saves, self loop\n");return 0;
}
