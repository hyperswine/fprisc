/* Real RISC-V register/stack/static-root integration using the board adapter. */
#include "builtin.h"
#include <stdint.h>
extern char _heap_start[],_heap_end[];
extern int gc_register_probe(void);
static volatile V kept;
static void text(const char *s) { volatile uint8_t *u=(void *)0x10000000;while(*s){while(!(u[5]&0x20)){}u[0]=(uint8_t)*s++;} }
static __attribute__((noreturn)) void finish(int code) { *(volatile uint32_t *)0x100000=code?0x13333:0x5555;for(;;){} }
void fpr_cpanic(const char *s) {text(s);text("\n");finish(1);}
static void check(int ok) {if(!ok)fpr_cpanic("GC ROOT CHECK FAILED");}
__attribute__((noinline)) static V graph(void) {
  V child=fpr_alloc(32);((uw *)child)[0]=0x12345678;
  V parent=fpr_alloc(32);((V *)parent)[0]=child;return parent;
}
__attribute__((noinline)) static void pressure(void) {
  for(unsigned i=0;i<200;i++) {V p=fpr_alloc(1024);((uw *)p)[0]=i;}
}
int main(void) {
  fpr_builtin_heap_init(_heap_start,_heap_end);
  check(gc_register_probe()==0);
  kept=graph();
  for(unsigned i=0;i<10;i++) {
    pressure();fpr_builtin_gc_collect();
    check(*(uw *)*(V *)kept==0x12345678);
    check(fpr_builtin_live_allocations()<32);
  }
  V p=fpr_alloc(256);((uw *)p)[0]=0x654321;
  /* Keep p live across an allocation/collection inside realloc. */
  (void)fpr_alloc(256);p=fpr_realloc(p,4096);check(*(uw *)p==0x654321);
  fpr_free(p);text("RISCV GC ROOTS HOLD\n");finish(0);return 0;
}
