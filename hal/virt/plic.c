/* plic.c -- the rv32 PLIC driver.
 *
 * On rv64 the driver is plic.fpr: FP-RISC over typed layouts, a raw library
 * unit whose exports are hal_irq_open / hal_irq_claim / hal_irq_ack (virt.mk,
 * docs/LAYOUTS.md) -- the design essay lives there now.  The raw ABI has no
 * rv32 lowering, so an rv32 image keeps this C; on rv64 this file is empty. */
#include "fpr.h"
#if __riscv_xlen == 32

#define PLIC_BASE 0x0c000000UL
#define PLIC_PRIO(src) ((volatile uint32_t *)(PLIC_BASE + 4u * (src)))
/* hart h's M-mode context is 2h on virt */
#define PLIC_ENABLE(ctx, src) \
  ((volatile uint32_t *)(PLIC_BASE + 0x2000UL + 0x80UL * (ctx) + 4UL * ((src) / 32)))
#define PLIC_THRESH(ctx) ((volatile uint32_t *)(PLIC_BASE + 0x200000UL + 0x1000UL * (ctx)))
#define PLIC_CLAIM(ctx) ((volatile uint32_t *)(PLIC_BASE + 0x200004UL + 0x1000UL * (ctx)))

#define IRQ_CTX (2 * fpr_irq_hart) /* the irq hart's M-mode context */

static void plic_set_enable(uw src, int on) {
  volatile uint32_t *e = PLIC_ENABLE(IRQ_CTX, src);
  uint32_t bit = 1u << (src % 32);
  if (on) *e |= bit;
  else *e &= ~bit;
}

void hal_irq_open(uw src) {
  *PLIC_PRIO(src) = 1;
  *PLIC_THRESH(IRQ_CTX) = 0;
  plic_set_enable(src, 1);
}

/* claim AND mask (see the essay); 0 = nothing pending */
sw hal_irq_claim(void) {
  uint32_t src = *PLIC_CLAIM(IRQ_CTX);
  if (!src) return 0;
  plic_set_enable(src, 0);
  *PLIC_CLAIM(IRQ_CTX) = src; /* complete now; the mask holds it off */
  return (sw)src;
}

/* the actor serviced the device: re-arm the source */
void hal_irq_ack(uw src) { plic_set_enable(src, 1); }
#endif
