/* Calls every exported entry of tests/builtin_export.fpr from C, with the
 * plain RV64 ABI, before the program's own main runs. */
#include <stdint.h>
#include <stdbool.h>
uintptr_t mix(uintptr_t, intptr_t, int);
intptr_t wide12(intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t,
                intptr_t, intptr_t, int, intptr_t);
intptr_t half(intptr_t);
int isEven(intptr_t);
double scale(double, intptr_t);
void poke(uintptr_t, uintptr_t);
uintptr_t peek(uintptr_t);
uintptr_t where(void);
intptr_t sumCell(intptr_t, intptr_t);
void hal_putc(char);
extern char _heap_state[];
extern uintptr_t __real_fpr_fn_main(void);
static void say(const char *s) { while (*s) hal_putc(*s++); }
static void fail(const char *s) { say("EXPORT FAIL: "); say(s); say("\n"); *(volatile uint32_t *)0x100000 = (1u << 16) | 0x3333; for (;;) {} }
uintptr_t __wrap_fpr_fn_main(void) {
  if (mix(0xff00, 0x0f, 1) != ((0xff00u + 0x0f) ^ 1)) fail("mix (Word, Int, Bool)");
  if (mix(1, -1, 0) != 0) fail("mix negative Int");
  if (wide12(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1, 12) != 1529) fail("wide12: four arguments from C's stack");
  if (wide12(0, 0, 0, 0, 0, 0, 0, 0, -1, 0, 0, 1) != 3) fail("wide12: negative stacked Int, False");
  if (half(21) != 10 || half(-9) != -4) fail("half (Int -> Int)");
  if (!isEven(4) || isEven(7)) fail("isEven (Int -> Bool)");
  if (scale(1.5, 4) != 6.0) fail("scale (F64, Int -> F64)");
  static uint64_t cell;
  poke((uintptr_t)&cell, 0x1234567887654321ull);
  if (cell != 0x1234567887654321ull || peek((uintptr_t)&cell) != cell) fail("poke/peek (Addr)");
  if (where() != (uintptr_t)_heap_state) fail("Addr.symbol");
  if (sumCell(40, 2) != 42) fail("managed data inside the library");
  say("EXPORTS HOLD\n");
  return __real_fpr_fn_main();
}
