/* Single-core Base host for SimpleRisc RV32IM/RV64IM. UART services are explicit RPCs.
 * Supported services return values/errors; unavailable actor/device facilities
 * trap through named stubs. The host driver supplies a rooted file device.
 */
#include "builtin.h"
#include <string.h>
#if FPR_CPU_MHZ <= 0
#error "FPR_CPU_MHZ must be positive"
#endif
extern char _heap_start[],_heap_end[];
extern V fpr_fn_main(void);
#define UART ((volatile uint32_t *)0x10000000)
#define MAX_REPLY (1024*1024)
static uint32_t sequence;
#ifdef FPR_TANGNANO_QEMU
/* QEMU's virt UART is a 16550; the FPGA has a word-register UART. The
 * transport protocol, heap, startup and runtime are identical in this probe. */
static int rx_ready(void){return ((volatile uint8_t *)UART)[5]&1;}
static unsigned rx_byte(void){return ((volatile uint8_t *)UART)[0];}
void hal_putc(char c){while(!(((volatile uint8_t *)UART)[5]&0x20)){}((volatile uint8_t *)UART)[0]=(uint8_t)c;}
#else
static int rx_ready(void){return UART[1]&2;}
static unsigned rx_byte(void){return UART[2]&255;}
void hal_putc(char c){while(!(UART[1]&1)){}UART[0]=(uint8_t)c;}
#endif
static void raw(const char *s){while(*s)hal_putc(*s++);}
static void heap_report(void) {
#ifdef FPR_HEAP_REPORT
 fpr_builtin_heap_stats s;fpr_builtin_heap_get_stats(&s);
 const char *names[]={" live="," peak="," requests="," requested="," collections="," reclaimed="};
 uw values[]={s.live_bytes,s.peak_bytes,s.requests,s.requested_bytes,s.collections,s.reclaimed_bytes};
 raw("HEAP");
 for(unsigned i=0;i<6;i++){char buf[24];unsigned n=0;uw v=values[i];raw(names[i]);do{buf[n++]=(char)('0'+v%10);v/=10;}while(v);while(n)hal_putc(buf[--n]);}
 raw("\n");
#endif
}
__attribute__((noreturn)) void hal_poweroff(int code){heap_report();raw(code?"FPR EXIT 1\n":"FPR EXIT 0\n");*(volatile uint32_t *)0x100000=code?0x13333:0x5555;for(;;){}}
void fpr_cpanic_n(const char *s,uw n){raw("Base panic: ");for(uw i=0;i<n;i++)hal_putc(s[i]);hal_putc('\n');hal_poweroff(1);}
void fpr_cpanic(const char *s){fpr_cpanic_n(s,strlen(s));}
void fpr_builtin_main(void){
 fpr_set_tp(&fpr_harts[0]);fpr_harts[0].fuel=1000000;fpr_harts[0].stk_lo=(uw)_heap_end+4096;fpr_harts[0].stk_span=65536-4096;
 fpr_builtin_heap_init(_heap_start,_heap_end);(void)fpr_fn_main();hal_poweroff(0);
}
void fpr_fuel_exhausted(void){fpr_harts[0].fuel=1000000;}
#ifdef FPR_BUILTIN_GC
void fpr_tangnano_gc_report(void) { raw("GC "); heap_report(); }
#endif
static uint64_t cycles(void){
#if __riscv_xlen == 32
 uint32_t hi,lo,end;
 do{__asm__ volatile("csrr %0,mcycleh":"=r"(hi));__asm__ volatile("csrr %0,mcycle":"=r"(lo));__asm__ volatile("csrr %0,mcycleh":"=r"(end));}while(hi!=end);
 return ((uint64_t)hi<<32)|lo;
#else
 uint64_t v;__asm__ volatile("csrr %0,mcycle":"=r"(v));return v;
#endif
}
/* Sys.mtime's shared contract is 10 MHz ticks, not microseconds. Divide
 * before multiplying so a long-running cycle counter cannot wrap silently. */
static V h_mtime(V u){
 (void)u;uint64_t c=cycles(),whole=c/FPR_CPU_MHZ,limit=UINTPTR_MAX>>2;
#if UINTPTR_MAX > UINT32_MAX
 if(whole>limit/10)fpr_cpanic("Sys.mtime exceeds Int range");
#endif
 uint64_t ticks=whole*10+(c%FPR_CPU_MHZ)*10/FPR_CPU_MHZ;
#if UINTPTR_MAX == UINT32_MAX
 /* Match the RV32 host contract: positive ticks modulo 2^30. */
 return TAG((uw)ticks & (uw)limit);
#else
 if(ticks>limit)fpr_cpanic("Sys.mtime exceeds Int range");
 return TAG(ticks);
#endif
}
FPR_FN(fpr_g_Sys_x2emtime,h_mtime,1);
static uint64_t deadline;
static unsigned byte(void){
 deadline=cycles()+(uint64_t)FPR_CPU_MHZ*1000000*5;
 while(!rx_ready()){if(cycles()>deadline)fpr_cpanic("virtual device response timeout");}
 unsigned v=rx_byte();hal_putc('+');return v;
}
static void hex(uint32_t x,unsigned n){static const char digits[]="0123456789abcdef";while(n){n--;hal_putc(digits[(x>>(4*n))&15]);}}
static unsigned nibble(void){unsigned c=byte();if(c>='0' && c<='9')return c-'0';if(c>='a' && c<='f')return c-'a'+10;fpr_cpanic("virtual device invalid hex");return 0;}
static uint32_t number(unsigned n){uint32_t v=0;while(n--)v=(v<<4)|nibble();return v;}
static void expect(unsigned c){if(byte()!=c)fpr_cpanic("virtual device invalid frame");}
static const str_t *string(V v){if(ISINT(v)||TID(v)!=T_STR)fpr_cpanic("virtual device expected String");return (str_t *)v;}
static str_t *mktext(const char *s,uw n){str_t *v=(str_t *)fpr_alloc(sizeof(str_t)+n);v->tid=T_STR;v->var=0;v->len=n;if(n)memcpy(v->bytes,s,n);return v;}
// Request payload is a path, optionally followed by NUL and file bytes.
static V rpc(unsigned op,const uint8_t *data,uint32_t n,const uint8_t *tail,uint32_t tn,unsigned *status){
 uint32_t seq=++sequence;unsigned crc=0;
 if(n>MAX_REPLY || tn>MAX_REPLY || n+tn>MAX_REPLY)fpr_cpanic("virtual device request too large");
 raw("@FPR1 ");hex(seq,8);hal_putc(' ');hex(op,2);hal_putc(' ');hex(n+tn,8);hal_putc(' ');
 for(uint32_t i=0;i<n;i++){hex(data[i],2);crc^=data[i];}
 for(uint32_t i=0;i<tn;i++){hex(tail[i],2);crc^=tail[i];}
 hal_putc(' ');hex(crc,2);hal_putc('\n');
 const char *prefix="@FPR1 ";while(*prefix)expect(*prefix++);
 if(number(8)!=seq)fpr_cpanic("virtual device sequence mismatch");expect(' ');
 *status=number(2);if(*status>1)fpr_cpanic("virtual device invalid status");expect(' ');uint32_t len=number(8);expect(' ');
 if(len>MAX_REPLY)fpr_cpanic("virtual device reply too large");
 str_t *reply=mktext("",0);reply=(str_t *)fpr_realloc((V)reply,sizeof(str_t)+len);reply->len=len;
 crc=0;for(uint32_t i=0;i<len;i++){reply->bytes[i]=number(2);crc^=reply->bytes[i];}
 expect(' ');if(number(2)!=crc)fpr_cpanic("virtual device checksum mismatch");expect('\n');
 return (V)reply;
}
static V result(unsigned err,V payload){hdr_t *v=(hdr_t *)fpr_alloc(8+sizeof(V));v->tid=T_RESULT;v->var=err?1:0;*(V *)((char *)v+8)=payload;return (V)v;}
static V h_read(V p){const str_t *s=string(p);unsigned e;V v=rpc(1,s->bytes,s->len,0,0,&e);if(e)fpr_panic(v);return v;}
static V h_exists(V p){const str_t *s=string(p);unsigned e;V v=rpc(2,s->bytes,s->len,0,0,&e);const str_t *r=string(v);return BOOL(!e && r->len==1 && r->bytes[0]=='1');}
static V file_put(V p,V d,unsigned op){
 const str_t *s=string(p),*t=string(d);uint8_t *path=(uint8_t *)fpr_alloc(s->len+1);
 memcpy(path,s->bytes,s->len);path[s->len]=0;unsigned e;V v=rpc(op,path,s->len+1,t->bytes,t->len,&e);
 fpr_free((V)path);return result(e,e?v:(V)&fpr_unit);
}
static V h_write(V p,V d){return file_put(p,d,3);}
static V h_append(V p,V d){return file_put(p,d,4);}
static V h_env(V p){const str_t *s=string(p);unsigned e;V v=rpc(5,s->bytes,s->len,0,0,&e);return result(e,v);}
static V h_time(V u){
 (void)u;unsigned e;V v=rpc(6,0,0,0,0,&e);if(e)fpr_panic(v);const str_t *s=string(v);uint64_t n=0;
 if(!s->len)fpr_cpanic("virtual clock invalid");
 for(uw i=0;i<s->len;i++){
  unsigned d=s->bytes[i]-'0';
  if(d>9 || n>(UINT64_MAX-d)/10)fpr_cpanic("virtual clock invalid");
  n=n*10+d;
 }
#if UINTPTR_MAX == UINT32_MAX
 return TAG((uw)n & (UINTPTR_MAX>>2));
#else
 if(n>(UINTPTR_MAX>>2))fpr_cpanic("Sys.timeUs exceeds Int range");
 return TAG(n);
#endif
}
static V h_args(V u){(void)u;static const hdr_t nil={T_LIST,0};return (V)&nil;}
static V h_exit(V code){if(!ISINT(code))fpr_cpanic("Sys.exit expected Int");hal_poweroff(UNTAG(code));return (V)&fpr_unit;}
static V h_stderr(V text){const str_t *s=string(text);for(uw i=0;i<s->len;i++)hal_putc(s->bytes[i]);return (V)&fpr_unit;}
static V h_line(V u){(void)u;unsigned e;V v=rpc(8,0,0,0,0,&e);return result(e,v);}
FPR_FN(fpr_g_fileRead,h_read,1);
FPR_FN(fpr_g_fileExists,h_exists,1);
FPR_FN(fpr_g_fileWrite,h_write,2);
FPR_FN(fpr_g_fileAppend,h_append,2);
FPR_FN(fpr_g_Sys_x2eenv,h_env,1);
FPR_FN(fpr_g_Sys_x2etimeUs,h_time,1);
FPR_FN(fpr_g_Sys_x2eargs,h_args,1);
FPR_FN(fpr_g_Sys_x2eexit,h_exit,1);
FPR_FN(fpr_g_Sys_x2estderr,h_stderr,1);
FPR_FN(fpr_g_Sys_x2ereadLine,h_line,1);

static V h_osread(V p){const str_t *s=string(p);unsigned e;V v=rpc(1,s->bytes,s->len,0,0,&e);return result(e,v);}
FPR_FN(fpr_g_Os_x2ereadFile,h_osread,1);
static V h_sleep(V us){if(!ISINT(us)||UNTAG(us)<0)fpr_cpanic("Sys.sleepUs expected nonnegative Int");uint64_t end=cycles()+(uint64_t)UNTAG(us)*FPR_CPU_MHZ;while(cycles()<end){}return (V)&fpr_unit;}
FPR_FN(fpr_g_Sys_x2esleepUs,h_sleep,1);
static V h_next(V u){(void)u;static sw id;return TAG(++id);}
FPR_FN(fpr_g_Sys_x2enextId,h_next,1);
