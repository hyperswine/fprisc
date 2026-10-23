/* Real actor runtime: sized grants, returning to the original segment,
 * warm reuse, ceiling/overflow refusal and the versioned plane method. */
#include "fpr.h"
#define CHECK(c) do{if(!(c))fpr_cpanic("sized stack runtime oracle failed: " #c);}while(0)
static uw delegated_sp,delegated_bytes;
static uw delegated(uw sp,uw n){delegated_sp=sp;delegated_bytes=n;return 0x1230;}
static V exercise(V mv){
 int mode=(int)UNTAG(mv);uw sp;
#if defined(__aarch64__)
 __asm__ volatile("mov %0,sp":"=r"(sp));
#elif defined(__x86_64__)
 __asm__ volatile("mov %%rsp,%0":"=r"(sp));
#else
 __asm__ volatile("mv %0,sp":"=r"(sp));
#endif
 uw id,size;void *original=fpr_current_stack(&id,&size);CHECK(original && id==0);
 if(mode==1){fpr_stack_reserve(sp,~(uw)0);fpr_cpanic("overflow reservation unexpectedly returned");}
 if(mode==3){fpr_stack_max=size+65536;fpr_stack_reserve(sp,1024*1024);fpr_cpanic("stack ceiling unexpectedly returned");}
 if(mode==4){fpr_stack_reserve(1,4096);fpr_cpanic("foreign stack unexpectedly returned");}
 fpr_plane_memory_t fake={0};fake.abi=mode==2?FPR_PLANE_MEMORY_ABI-1:FPR_PLANE_MEMORY_ABI;
 fake.stack_reserve=mode==5?0:delegated;
 CHECK(fpr_plane_memory==0);fpr_plane_memory=&fake;
 uw answer=fpr_stack_reserve(sp,1234);
 fpr_plane_memory=0;
 CHECK(answer==0x1230 && delegated_sp==sp && delegated_bytes==1234);
 CHECK(mode==0);
 const uw request=1024*1024;uw first=0;
 for(unsigned i=0;i<32;i++){
  uw top=fpr_stack_reserve(sp,request);CHECK(top && !(top&15));
  if(!i)first=top;else CHECK(top==first);
  fpr_hart_t *h=fpr_hart();CHECK(top>=request && top-request>=h->stk_lo && top-request-h->stk_lo<h->stk_span);
  void *grown=fpr_current_stack(&id,&size);CHECK(grown && grown!=original && top>(uw)grown && top<(uw)grown+size);
  CHECK(fpr_stack_grow()==0);CHECK(fpr_current_stack(&id,&size)==original);
 }
 return TAG(32);
}
FPR_FN(fpr_g_Reserve_x2eexercise,exercise,1);
static V tick(V u){(void)u;fpr_hart()->fuel=1;return (V)&fpr_unit;}
FPR_FN(fpr_g_Reserve_x2etick,tick,1);
