/* Tang Nano pin 76 HAL: one register write and nothing else. What the pin
 * does (servo pulse widths, on/off levels for a transistor-switched load)
 * and every timing decision live in FP-RISC (std/tangnano20k/pin76.fpr).
 * Only simple-risc's SDRAM_SERVO=1 image maps the register: on any other
 * image the store faults as an unmapped access.
 */
#include "fpr.h"

#define PIN76_WRITE(value) (*(volatile uint32_t *)0x10001010u = (value))

/* The hardware ignores values outside 0, 1 and 1000-2000; the FP-RISC
 * module never sends them, and the HAL refuses rather than passes them. */
static V h_store(V v) {
  if (!ISINT(v)) fpr_cpanic("Pin76.store: expected Int");
  sw n = UNTAG(v);
  if (n != 0 && n != 1 && (n < 1000 || n > 2000)) fpr_cpanic("Pin76.store: outside 0, 1, 1000..2000");
  PIN76_WRITE((uint32_t)n);
  return V_UNIT;
}

FPR_FN(fpr_g_Pin76_x2estore, h_store, 1);
