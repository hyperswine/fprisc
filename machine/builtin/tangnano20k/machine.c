/* RV32IM + Zicsr machine ABI for SimpleRisc. No interrupt sources yet. */
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
  fpr_cpanic("SimpleRisc: IRQ and atomic operations are unsupported");
  return 0;
}
/* CSR numbers are instruction immediates: dispatch only implemented addresses.
 * Unknown runtime addresses fail loudly; raw guest instructions trap in hardware.
 */
#define SIMPLE_CSRS(X) \
 X(0x300) X(0x301) X(0x304) X(0x305) X(0x310) X(0x340) \
 X(0x341) X(0x342) X(0x343) X(0x344) \
 X(0xb00) X(0xb80) X(0xb02) X(0xb82) X(0xc00) X(0xc80) X(0xc02) X(0xc82) \
 X(0xf11) X(0xf12) X(0xf13) X(0xf14)
uintptr_t fpr_machine_csr_read(uintptr_t n) {
  uintptr_t value;
  switch (n) {
#define READ_CSR(number) case number: __asm__ volatile("csrr %0, " #number : "=r"(value) :: "memory"); return value;
    SIMPLE_CSRS(READ_CSR)
#undef READ_CSR
    default: fpr_cpanic("SimpleRisc: unknown CSR"); return 0;
  }
}
void fpr_machine_csr_write(uintptr_t n, uintptr_t v) {
  switch (n) {
#define WRITE_CSR(number) case number: __asm__ volatile("csrw " #number ", %0" :: "r"(v) : "memory"); return;
    SIMPLE_CSRS(WRITE_CSR)
#undef WRITE_CSR
    default: fpr_cpanic("SimpleRisc: unknown CSR");
  }
}
#undef SIMPLE_CSRS
uintptr_t fpr_machine_irq_save(void) { return unsupported(); }
void fpr_machine_irq_restore(uintptr_t v) { (void)v; (void)unsupported(); }
void fpr_machine_irq_enable(void) { (void)unsupported(); }
void fpr_machine_wait(void) { (void)unsupported(); }
void fpr_machine_fence_i(void) { __asm__ volatile("fence.i" ::: "memory"); }
uintptr_t fpr_machine_exchange(uintptr_t p, uintptr_t v) { (void)p; (void)v; return unsupported(); }
uintptr_t fpr_machine_compare_exchange(uintptr_t p, uintptr_t old, uintptr_t v) {
  (void)p; (void)old; (void)v; return unsupported();
}
