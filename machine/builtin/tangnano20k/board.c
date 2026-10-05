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
  /* The finisher stops execution independently of the guest trap vector.
   * Print status first: the existing DONE protocol has no exit-code payload. */
  puts_raw(code ? "FPR EXIT 1\n" : "FPR EXIT 0\n");
  *(volatile uint32_t *)0x00100000 = code
      ? (((uint32_t)code << 16) | 0x3333) : 0x5555;
  for (;;) {}
}
void fpr_cpanic(const char *s) {
  puts_raw("Builtin panic: "); puts_raw(s); hal_putc('\n');
  hal_poweroff(1);
  for (;;) {}
}
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
