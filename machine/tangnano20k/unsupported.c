/* Explicit unavailable Base capabilities; no success-shaped stubs. */
#include "fpr.h"
#include <stddef.h>
#include <string.h>
static V unavailable(const char *name){
 uw n=strlen(name);str_t *s=(str_t *)fpr_alloc(sizeof(str_t)+n);s->tid=T_STR;s->var=0;s->len=n;memcpy(s->bytes,name,n);
 hdr_t *r=(hdr_t *)fpr_alloc(8+sizeof(V));r->tid=T_RESULT;r->var=1;*(V *)((char *)r+8)=(V)s;return (V)r;
}
fpr_sched_t *fpr_sched;
volatile int fpr_is_process;
int fpr_mem_own;
uw fpr_stack_grow(void){fpr_cpanic("Base: 64 KiB stack exhausted");return 0;}
void fpr_actor_fail(const char *why){fpr_cpanic(why);for(;;){}}
void fpr_mem_give(void *p){(void)p;fpr_cpanic("Base: process memory grants unavailable");}
void buddy_free(void *p){(void)p;fpr_cpanic("Base: buddy allocator unavailable");}
void fpr_drop_park(fpr_slab_t *p){(void)p;fpr_cpanic("Base: cross-actor drops unavailable");}
void fpr_drop_drain_current(void){fpr_cpanic("Base: actor drop queue unavailable");}
fpr_pool_t *fpr_acb_pool(struct fpr_acb *p){(void)p;fpr_cpanic("Base: actor pool unavailable");return 0;}
struct fpr_pool **fpr_acb_override_slot(struct fpr_acb *p){(void)p;fpr_cpanic("Base: actor arenas unavailable");return 0;}
size_t strlen(const char *p){size_t n=0;while(p[n])n++;return n;}
// GCC's libatomic fallback, valid only for this single core without interrupts.
int single_cas(volatile void *p,void *expected,unsigned long long value,int success,int failure) __asm__("__atomic_compare_exchange_8");
int single_cas(volatile void *p,void *expected,unsigned long long value,int success,int failure){
 (void)success;(void)failure;volatile unsigned long long *v=p;unsigned long long *e=expected;
 if(*v==*e){*v=value;return 1;}*e=*v;return 0;
}
static V h_fpr_g_Os_x2eclose(V a0){(void)a0;return unavailable("Base: Os.close unavailable");}
FPR_FN(fpr_g_Os_x2eclose,h_fpr_g_Os_x2eclose,1);
static V h_fpr_g_Os_x2ecwd(V a0){(void)a0;fpr_cpanic("Base: Os.cwd unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Os_x2ecwd,h_fpr_g_Os_x2ecwd,1);
static V h_fpr_g_Os_x2elistDir(V a0){(void)a0;return unavailable("Base: Os.listDir unavailable");}
FPR_FN(fpr_g_Os_x2elistDir,h_fpr_g_Os_x2elistDir,1);
static V h_fpr_g_Os_x2emkdir(V a0){(void)a0;return unavailable("Base: Os.mkdir unavailable");}
FPR_FN(fpr_g_Os_x2emkdir,h_fpr_g_Os_x2emkdir,1);
static V h_fpr_g_Os_x2eopen(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: Os.open unavailable");}
FPR_FN(fpr_g_Os_x2eopen,h_fpr_g_Os_x2eopen,2);
static V h_fpr_g_Os_x2epoll(V a0){(void)a0;fpr_cpanic("Base: Os.poll unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Os_x2epoll,h_fpr_g_Os_x2epoll,1);
static V h_fpr_g_Os_x2eread(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: Os.read unavailable");}
FPR_FN(fpr_g_Os_x2eread,h_fpr_g_Os_x2eread,2);
static V h_fpr_g_Os_x2eready(V a0){(void)a0;fpr_cpanic("Base: Os.ready unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Os_x2eready,h_fpr_g_Os_x2eready,1);
static V h_fpr_g_Os_x2eremove(V a0){(void)a0;return unavailable("Base: Os.remove unavailable");}
FPR_FN(fpr_g_Os_x2eremove,h_fpr_g_Os_x2eremove,1);
static V h_fpr_g_Os_x2erename(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: Os.rename unavailable");}
FPR_FN(fpr_g_Os_x2erename,h_fpr_g_Os_x2erename,2);
static V h_fpr_g_Os_x2eseek(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: Os.seek unavailable");}
FPR_FN(fpr_g_Os_x2eseek,h_fpr_g_Os_x2eseek,2);
static V h_fpr_g_Os_x2estat(V a0){(void)a0;return unavailable("Base: Os.stat unavailable");}
FPR_FN(fpr_g_Os_x2estat,h_fpr_g_Os_x2estat,1);
static V h_fpr_g_Os_x2ewatchArm(V a0,V a1){(void)a0;(void)a1;fpr_cpanic("Base: Os.watchArm unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Os_x2ewatchArm,h_fpr_g_Os_x2ewatchArm,2);
static V h_fpr_g_Os_x2ewatchClose(V a0){(void)a0;fpr_cpanic("Base: Os.watchClose unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Os_x2ewatchClose,h_fpr_g_Os_x2ewatchClose,1);
static V h_fpr_g_Os_x2ewatchOpen(V a0){(void)a0;return unavailable("Base: Os.watchOpen unavailable");}
FPR_FN(fpr_g_Os_x2ewatchOpen,h_fpr_g_Os_x2ewatchOpen,1);
static V h_fpr_g_Os_x2ewatchTake(V a0){(void)a0;fpr_cpanic("Base: Os.watchTake unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Os_x2ewatchTake,h_fpr_g_Os_x2ewatchTake,1);
static V h_fpr_g_Os_x2ewrite(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: Os.write unavailable");}
FPR_FN(fpr_g_Os_x2ewrite,h_fpr_g_Os_x2ewrite,2);
static V h_fpr_g_Sys_x2eirqAck(V a0){(void)a0;fpr_cpanic("Base: Sys.irqAck unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Sys_x2eirqAck,h_fpr_g_Sys_x2eirqAck,1);
static V h_fpr_g_Sys_x2eirqDeliver(V a0,V a1){(void)a0;(void)a1;fpr_cpanic("Base: Sys.irqDeliver unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Sys_x2eirqDeliver,h_fpr_g_Sys_x2eirqDeliver,2);
static V h_fpr_g_Sys_x2eirqInstall(V a0){(void)a0;fpr_cpanic("Base: Sys.irqInstall unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Sys_x2eirqInstall,h_fpr_g_Sys_x2eirqInstall,1);
static V h_fpr_g_Sys_x2eirqOpen(V a0){(void)a0;fpr_cpanic("Base: Sys.irqOpen unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Sys_x2eirqOpen,h_fpr_g_Sys_x2eirqOpen,1);
static V h_fpr_g_Sys_x2eirqRouter(V a0){(void)a0;fpr_cpanic("Base: Sys.irqRouter unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Sys_x2eirqRouter,h_fpr_g_Sys_x2eirqRouter,1);
static V h_fpr_g_Sys_x2eirqTarget(V a0){(void)a0;fpr_cpanic("Base: Sys.irqTarget unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Sys_x2eirqTarget,h_fpr_g_Sys_x2eirqTarget,1);
static V h_fpr_g_myself(V a0){(void)a0;fpr_cpanic("Base: myself unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_myself,h_fpr_g_myself,1);
static V h_fpr_g_receiveFromRes(V a0,V a1){(void)a0;(void)a1;fpr_cpanic("Base: receiveFromRes unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_receiveFromRes,h_fpr_g_receiveFromRes,2);
static V h_fpr_g_receiveFrom(V a0,V a1){(void)a0;(void)a1;fpr_cpanic("Base: receiveFrom unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_receiveFrom,h_fpr_g_receiveFrom,2);
static V h_fpr_g_receiveNow(V a0){(void)a0;fpr_cpanic("Base: receiveNow unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_receiveNow,h_fpr_g_receiveNow,1);
static V h_fpr_g_receiveRes(V a0){(void)a0;fpr_cpanic("Base: receiveRes unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_receiveRes,h_fpr_g_receiveRes,1);
static V h_fpr_g_receive(V a0){(void)a0;fpr_cpanic("Base: receive unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_receive,h_fpr_g_receive,1);
static V h_fpr_g_send(V a0,V a1){(void)a0;(void)a1;fpr_cpanic("Base: send unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_send,h_fpr_g_send,2);
static V h_fpr_g_spawnCapOn(V a0,V a1,V a2,V a3){(void)a0;(void)a1;(void)a2;(void)a3;fpr_cpanic("Base: spawnCapOn unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_spawnCapOn,h_fpr_g_spawnCapOn,4);
static V h_fpr_g_spawnCap(V a0,V a1,V a2){(void)a0;(void)a1;(void)a2;fpr_cpanic("Base: spawnCap unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_spawnCap,h_fpr_g_spawnCap,3);
static V h_fpr_g_spawnHeap(V a0,V a1){(void)a0;(void)a1;fpr_cpanic("Base: spawnHeap unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_spawnHeap,h_fpr_g_spawnHeap,2);
static V h_fpr_g_spawnOn(V a0,V a1){(void)a0;(void)a1;fpr_cpanic("Base: spawnOn unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_spawnOn,h_fpr_g_spawnOn,2);
static V h_fpr_g_spawn(V a0){(void)a0;fpr_cpanic("Base: spawn unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_spawn,h_fpr_g_spawn,1);
static V h_fpr_g_yield(V a0){(void)a0;fpr_cpanic("Base: yield unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_yield,h_fpr_g_yield,1);
