#include "builtin.h"

extern char _heap_start[], _heap_end[];
extern V fpr_fn_main(void);

void hal_putc(char c) {
  volatile uint32_t *uart = (volatile uint32_t *)0x10000000;
  while (!(uart[1] & 1)) {}
  uart[0] = (uint8_t)c;
}
static void puts_raw(const char *s) { while (*s) hal_putc(*s++); }
void hal_poweroff(int code) {
  /* ECALL is SimpleRisc's halt instruction. Its loader then emits DONE.
   * Print status first: DONE alone also follows an illegal instruction. */
  puts_raw(code ? "FPR EXIT 1\n" : "FPR EXIT 0\n");
  __asm__ volatile("ecall" ::: "memory");
  for (;;) {}
}
/* (bytes, length): fpr_panic prints an `error` String from its own bytes */
void fpr_cpanic_n(const char *s, uw n) {
  puts_raw("Builtin panic: ");
  for (uw i = 0; i < n; i++) hal_putc(s[i]);
  hal_putc('\n');
  hal_poweroff(1);
  for (;;) {}
}
void fpr_cpanic(const char *s) { uw n = 0; while (s[n]) n++; fpr_cpanic_n(s, n); }
void fpr_builtin_main(void) {
  fpr_set_tp(&fpr_harts[0]);
#ifdef FPR_BUILTIN_HEAP_BYTES
  if ((uw)FPR_BUILTIN_HEAP_BYTES > (uw)_heap_end - (uw)_heap_start)
    fpr_cpanic("Builtin: configured heap exceeds RAM");
  fpr_builtin_heap_init(_heap_start, _heap_start + FPR_BUILTIN_HEAP_BYTES);
#else
  fpr_builtin_heap_init(_heap_start, _heap_end);
#endif
  (void)fpr_fn_main();
  hal_poweroff(0);
}
