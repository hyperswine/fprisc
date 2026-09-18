#include "builtin.h"
extern char _heap_start[], _heap_end[];
extern V fpr_fn_main(void);
void hal_putc(char c) {
  volatile uint8_t *uart=(volatile uint8_t *)0x10000000;
  while (!(uart[5]&0x20)) {} uart[0]=(uint8_t)c;
}
void hal_poweroff(int code) {
  *(volatile uint32_t *)0x100000=code?((uint32_t)code<<16)|0x3333:0x5555;
}
void fpr_cpanic(const char *s) {
  const char *prefix="Builtin panic: ";
  while(*prefix)hal_putc(*prefix++);
  while(*s)hal_putc(*s++);
  hal_putc('\n');hal_poweroff(1);
  for(;;)__asm__ volatile("wfi");
}
void fpr_builtin_main(void) {
  /* tp remains the calling-convention spill/render context, not an actor. */
  fpr_set_tp(&fpr_harts[0]);
#ifdef FPR_BUILTIN_HEAP_BYTES
  if ((uw)FPR_BUILTIN_HEAP_BYTES > (uw)_heap_end - (uw)_heap_start)
    fpr_cpanic("Builtin: configured heap exceeds RAM");
  fpr_builtin_heap_init(_heap_start, _heap_start + FPR_BUILTIN_HEAP_BYTES);
#else
  fpr_builtin_heap_init(_heap_start,_heap_end);
#endif
  V result = fpr_fn_main();
#ifdef FPR_BUILTIN_ARC
  fpr_builtin_release(result);
#ifdef FPR_ARC_CHECK
  if (fpr_builtin_live_allocations()) fpr_cpanic("ARC: live allocations after main");
#endif
#else
  (void)result;
#endif
  hal_poweroff(0);
  for(;;)__asm__ volatile("wfi");
}

/* Fatal fallback only: allocation-free, no ARC or language callbacks in traps. */
static void trap_hex(uw v) {
  const char *digits="0123456789abcdef";
  for (int shift=60; shift>=0; shift-=4) hal_putc(digits[(v>>shift)&15]);
}
void fpr_builtin_fatal_trap(uw cause,uw pc,uw value) {
  const char *p="Builtin trap: mcause=0x";
  while(*p)hal_putc(*p++);
  trap_hex(cause);
  p=" mepc=0x";while(*p)hal_putc(*p++);trap_hex(pc);
  p=" mtval=0x";while(*p)hal_putc(*p++);trap_hex(value);hal_putc('\n');
  hal_poweroff(1);
  for(;;)__asm__ volatile("wfi");
}
