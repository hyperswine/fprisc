/* asm.h — XLEN-neutral assembly helpers.  .S files are preprocessed, so
 * __riscv_xlen selects the load/store width and word size once, here. */
#ifndef FPR_ASM_H
#define FPR_ASM_H

#if __riscv_xlen == 64
#define REG_S sd
#define REG_L ld
#define WSZ 8
#else
#define REG_S sw
#define REG_L lw
#define WSZ 4
#endif

#endif
