/* Plain RV32 machine ABI for SimpleRisc. No synthetic CSR or IRQ state. */
#include "builtin.h"
#include "machine.h"
uintptr_t fpr_machine_shl(uintptr_t a, uintptr_t n) { return a << n; }
uintptr_t fpr_machine_shr(uintptr_t a, uintptr_t n) { return a >> n; }
uintptr_t fpr_machine_and(uintptr_t a, uintptr_t b) { return a & b; }
uintptr_t fpr_machine_or(uintptr_t a, uintptr_t b) { return a | b; }
uintptr_t fpr_machine_xor(uintptr_t a, uintptr_t b) { return a ^ b; }
uintptr_t fpr_machine_not(uintptr_t a) { return ~a; }
uintptr_t fpr_machine_bit_set(uintptr_t a, uintptr_t n) { return a | ((uintptr_t)1 << n); }
uintptr_t fpr_machine_bit_clear(uintptr_t a, uintptr_t n) { return a & ~((uintptr_t)1 << n); }
uintptr_t fpr_machine_bit_test(uintptr_t a, uintptr_t n) { return (a >> n) & 1; }
#define ACCESS(name, type) \
 uintptr_t fpr_machine_read##name(uintptr_t p) { return *(volatile type *)p; } \
 void fpr_machine_write##name(uintptr_t p, uintptr_t v) { *(volatile type *)p = (type)v; }
ACCESS(8, uint8_t)
ACCESS(16, uint16_t)
ACCESS(32, uint32_t)
ACCESS(Word, uintptr_t)
void fpr_machine_fence(void) { __asm__ volatile("fence iorw, iorw" ::: "memory"); }
static uintptr_t unsupported(void) {
  fpr_cpanic("SimpleRisc: CSR, IRQ and atomic operations are unsupported");
  return 0;
}
uintptr_t fpr_machine_csr_read(uintptr_t n) { (void)n; return unsupported(); }
void fpr_machine_csr_write(uintptr_t n, uintptr_t v) { (void)n; (void)v; (void)unsupported(); }
uintptr_t fpr_machine_irq_save(void) { return unsupported(); }
void fpr_machine_irq_restore(uintptr_t v) { (void)v; (void)unsupported(); }
void fpr_machine_irq_enable(void) { (void)unsupported(); }
void fpr_machine_wait(void) { (void)unsupported(); }
void fpr_machine_fence_i(void) { __asm__ volatile("fence.i" ::: "memory"); }
uintptr_t fpr_machine_exchange(uintptr_t p, uintptr_t v) { (void)p; (void)v; return unsupported(); }
uintptr_t fpr_machine_compare_exchange(uintptr_t p, uintptr_t old, uintptr_t v) {
  (void)p; (void)old; (void)v; return unsupported();
}
