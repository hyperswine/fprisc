/* Explicit unavailable Base capabilities; no success-shaped stubs. */
#include "fpr.h"
#include <stddef.h>
#include <string.h>
static V unavailable(const char *name){
 uw n=strlen(name);str_t *s=(str_t *)fpr_alloc(sizeof(str_t)+n);s->tid=T_STR;s->var=0;s->len=n;memcpy(s->bytes,name,n);
 hdr_t *r=(hdr_t *)fpr_alloc(8+sizeof(V));r->tid=T_RESULT;r->var=1;*(V *)((char *)r+8)=(V)s;return (V)r;
}
fpr_plane_actors_t *fpr_plane_actors;
fpr_plane_memory_t *fpr_plane_memory;
volatile int fpr_is_process;
int fpr_mem_own;
uw fpr_stack_grow(void){fpr_cpanic("Base: 64 KiB stack exhausted");return 0;}
void fpr_actor_fail(const char *why){fpr_cpanic(why);for(;;){}}
uw fpr_actor_is_program(void){return 1;}
/* Same identities as the shared runtime's bootstrap thread, not actors. */
uw fpr_current_pid(void){return 0;}
uw fpr_current_id(void){return 900;}
/* These shared-runtime entries can be retained by a module's export table.
 * This host has no process budget, scheduler or system logger to operate. */
void *fpr_charge(void *p){(void)p;fpr_cpanic("Base: process budgets unavailable");return 0;}
void fpr_exhausted(const char *why){fpr_cpanic(why);for(;;){}}
int fpr_actor_confined(void){fpr_cpanic("Base: actor confinement unavailable");return 0;}
void fpr_confined_refuse(const char *what){(void)what;fpr_cpanic("Base: system service unavailable");}
V fpr_ended_actor(void){fpr_cpanic("Base: actor handles unavailable");return 0;}
void fpr_mem_give(void *p){(void)p;fpr_cpanic("Base: process memory grants unavailable");}
void *fpr_mem_take(uw bytes){(void)bytes;fpr_cpanic("Base: process memory grants unavailable");return 0;}
void buddy_free(void *p){(void)p;fpr_cpanic("Base: buddy allocator unavailable");}
uw buddy_block_usable_size(void *p){(void)p;fpr_cpanic("Base: buddy allocator unavailable");return 0;}
void fpr_drop_park(fpr_slab_t *p){(void)p;fpr_cpanic("Base: cross-actor drops unavailable");}
void fpr_drop_drain_current(void){fpr_cpanic("Base: actor drop queue unavailable");}
fpr_pool_t *fpr_acb_pool(struct fpr_acb *p){(void)p;fpr_cpanic("Base: actor pool unavailable");return 0;}
struct fpr_pool **fpr_acb_override_slot(struct fpr_acb *p){(void)p;fpr_cpanic("Base: actor arenas unavailable");return 0;}
struct fpr_scope **fpr_acb_scope_slot(struct fpr_acb *p){(void)p;fpr_cpanic("Base: actor scopes unavailable");return 0;}
fpr_slab_t **fpr_acb_msg_slot(struct fpr_acb *p){(void)p;fpr_cpanic("Base: actor message slabs unavailable");return 0;}
size_t strlen(const char *p){size_t n=0;while(p[n])n++;return n;}
// GCC's libatomic fallback, valid only for this single core without interrupts.
int single_cas(volatile void *p,void *expected,unsigned long long value,int success,int failure) __asm__("__atomic_compare_exchange_8");
int single_cas(volatile void *p,void *expected,unsigned long long value,int success,int failure){
 (void)success;(void)failure;volatile unsigned long long *v=p;unsigned long long *e=expected;
 if(*v==*e){*v=value;return 1;}*e=*v;return 0;
}
unsigned long long single_fetch_add(volatile void *p,unsigned long long value,int order) __asm__("__atomic_fetch_add_8");
unsigned long long single_fetch_add(volatile void *p,unsigned long long value,int order){
 (void)order;volatile unsigned long long *v=p;unsigned long long old=*v;*v=old+value;return old;
}
int single_cas32(volatile void *p,void *expected,uint32_t value,int success,int failure) __asm__("__atomic_compare_exchange_4");
int single_cas32(volatile void *p,void *expected,uint32_t value,int success,int failure){
 (void)success;(void)failure;volatile uint32_t *v=p;uint32_t *e=expected;
 if(*v==*e){*v=value;return 1;}*e=*v;return 0;
}
uint32_t single_fetch_add32(volatile void *p,uint32_t value,int order) __asm__("__atomic_fetch_add_4");
uint32_t single_fetch_add32(volatile void *p,uint32_t value,int order){
 (void)order;volatile uint32_t *v=p;uint32_t old=*v;*v=old+value;return old;
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
static V h_fpr_g_Os_x2ereadyFor(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: Os.readyFor unavailable");}
FPR_FN(fpr_g_Os_x2ereadyFor,h_fpr_g_Os_x2ereadyFor,2);
static V h_fpr_g_Os_x2eprepareSocket(V a0){(void)a0;return unavailable("Base: Os.prepareSocket unavailable");}
FPR_FN(fpr_g_Os_x2eprepareSocket,h_fpr_g_Os_x2eprepareSocket,1);
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
static V h_fpr_g_Os_x2ewatchArmEvents(V a0,V a1,V a2){(void)a0;(void)a1;(void)a2;return unavailable("Base: Os.watchArmEvents unavailable");}
FPR_FN(fpr_g_Os_x2ewatchArmEvents,h_fpr_g_Os_x2ewatchArmEvents,3);
static V h_fpr_g_Os_x2ewatchTakeEvents(V a0){(void)a0;fpr_cpanic("Base: Os.watchTakeEvents unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_Os_x2ewatchTakeEvents,h_fpr_g_Os_x2ewatchTakeEvents,1);
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
static V h_receive_from_now(V me,V from){(void)me;(void)from;return unavailable("Base: receiveFromNow unavailable");}
FPR_FN(fpr_g_receiveFromNow,h_receive_from_now,2);
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
static V h_kill(V actor){(void)actor;fpr_cpanic("Base: kill unavailable");return (V)&fpr_unit;}
FPR_FN(fpr_g_kill,h_kill,1);

/* Checked native connection, resolver and TLS capabilities. */
static V unavailable_ConnHost_adopt(V a0){(void)a0;return unavailable("Base: ConnHost.adopt unavailable");}
FPR_FN(fpr_g_ConnHost_x2eadopt,unavailable_ConnHost_adopt,1);
static V unavailable_ConnHost_begin(V a0,V a1,V a2){(void)a0;(void)a1;(void)a2;return unavailable("Base: ConnHost.begin unavailable");}
FPR_FN(fpr_g_ConnHost_x2ebegin,unavailable_ConnHost_begin,3);
static V unavailable_ConnHost_fd(V a0){(void)a0;return unavailable("Base: ConnHost.fd unavailable");}
FPR_FN(fpr_g_ConnHost_x2efd,unavailable_ConnHost_fd,1);
static V unavailable_ConnHost_status(V a0){(void)a0;return unavailable("Base: ConnHost.status unavailable");}
FPR_FN(fpr_g_ConnHost_x2estatus,unavailable_ConnHost_status,1);
static V unavailable_ConnHost_read(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: ConnHost.read unavailable");}
FPR_FN(fpr_g_ConnHost_x2eread,unavailable_ConnHost_read,2);
static V unavailable_ConnHost_write(V a0,V a1){(void)a0;(void)a1;return unavailable("Base: ConnHost.write unavailable");}
FPR_FN(fpr_g_ConnHost_x2ewrite,unavailable_ConnHost_write,2);
static V unavailable_ConnHost_close(V a0){(void)a0;return unavailable("Base: ConnHost.close unavailable");}
FPR_FN(fpr_g_ConnHost_x2eclose,unavailable_ConnHost_close,1);
static V unavailable_DnsHost_pool(V a0){(void)a0;return unavailable("Base: DnsHost.pool unavailable");}
FPR_FN(fpr_g_DnsHost_x2epool,unavailable_DnsHost_pool,1);
static V unavailable_DnsHost_begin(V a0,V a1,V a2){(void)a0;(void)a1;(void)a2;return unavailable("Base: DnsHost.begin unavailable");}
FPR_FN(fpr_g_DnsHost_x2ebegin,unavailable_DnsHost_begin,3);
static V unavailable_DnsHost_poll(V a0){(void)a0;return unavailable("Base: DnsHost.poll unavailable");}
FPR_FN(fpr_g_DnsHost_x2epoll,unavailable_DnsHost_poll,1);
static V unavailable_DnsHost_abandon(V a0){(void)a0;return unavailable("Base: DnsHost.abandon unavailable");}
FPR_FN(fpr_g_DnsHost_x2eabandon,unavailable_DnsHost_abandon,1);
static V unavailable_DnsHost_close(V a0){(void)a0;return unavailable("Base: DnsHost.close unavailable");}
FPR_FN(fpr_g_DnsHost_x2eclose,unavailable_DnsHost_close,1);
static V unavailable_TlsHost_start(V a0,V a1,V a2,V a3,V a4){(void)a0;(void)a1;(void)a2;(void)a3;(void)a4;return unavailable("Base: TlsHost.start unavailable");}
FPR_FN(fpr_g_TlsHost_x2estart,unavailable_TlsHost_start,5);
static V unavailable_TlsHost_fd(V a0){(void)a0;return unavailable("Base: TlsHost.fd unavailable");}
FPR_FN(fpr_g_TlsHost_x2efd,unavailable_TlsHost_fd,1);
static V unavailable_TlsHost_step(V a0,V a1,V a2,V a3){(void)a0;(void)a1;(void)a2;(void)a3;return unavailable("Base: TlsHost.step unavailable");}
FPR_FN(fpr_g_TlsHost_x2estep,unavailable_TlsHost_step,4);
static V unavailable_TlsHost_pending(V a0){(void)a0;return unavailable("Base: TlsHost.pending unavailable");}
FPR_FN(fpr_g_TlsHost_x2epending,unavailable_TlsHost_pending,1);
static V unavailable_TlsHost_close(V a0){(void)a0;return unavailable("Base: TlsHost.close unavailable");}
FPR_FN(fpr_g_TlsHost_x2eclose,unavailable_TlsHost_close,1);
