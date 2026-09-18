#ifndef FPR_MACHINE_H
#define FPR_MACHINE_H
#include <stdint.h>
/* RV64 raw integer ABI: no tagged values, boxes, allocation, or ARC here.
 * Bit indices/shifts must be <64; memory addresses must be naturally aligned,
 * mapped and permitted. CSR IDs must be <4096 and supported by the hardware.
 * Memory, CSR, interrupt and fence calls are observable effects.
 */
uintptr_t fpr_machine_shl(uintptr_t, uintptr_t);
uintptr_t fpr_machine_shr(uintptr_t, uintptr_t);
uintptr_t fpr_machine_and(uintptr_t, uintptr_t);
uintptr_t fpr_machine_or(uintptr_t, uintptr_t);
uintptr_t fpr_machine_xor(uintptr_t, uintptr_t);
uintptr_t fpr_machine_not(uintptr_t);
uintptr_t fpr_machine_bit_set(uintptr_t, uintptr_t);
uintptr_t fpr_machine_bit_clear(uintptr_t, uintptr_t);
uintptr_t fpr_machine_bit_test(uintptr_t, uintptr_t);
#define MEM_DECL(n) uintptr_t fpr_machine_read##n(uintptr_t); \
 void fpr_machine_write##n(uintptr_t, uintptr_t)
MEM_DECL(8); MEM_DECL(16); MEM_DECL(32); MEM_DECL(Word);
#undef MEM_DECL
void fpr_machine_fence(void);
void fpr_machine_fence_i(void);
uintptr_t fpr_machine_csr_read(uintptr_t);
void fpr_machine_csr_write(uintptr_t, uintptr_t);
/* Save/restore ONLY mstatus.MIE. Tokens are 0 or 8; nested masking is supported. */
uintptr_t fpr_machine_irq_save(void);
void fpr_machine_irq_restore(uintptr_t);
void fpr_machine_irq_enable(void);
void fpr_machine_wait(void);
/* Ordinary RAM, 8-byte alignment. Exchange: aqrl. CAS: acquire on read,
 * release on successful store; returns observed old value in both cases.
 * These do not make the allocator or language runtime interrupt/thread safe.
 */
uintptr_t fpr_machine_exchange(uintptr_t, uintptr_t);
uintptr_t fpr_machine_compare_exchange(uintptr_t, uintptr_t, uintptr_t);
#endif
