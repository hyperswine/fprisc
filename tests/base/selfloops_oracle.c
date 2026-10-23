#include <stdint.h>
#ifdef FPR_ORACLE_RV64
__attribute__((noreturn)) void oracle_finish(int code) {
    *(volatile unsigned *)0x100000 = code ? 0x13333 : 0x5555;
    for (;;) {}
}
#define assert(ok) do { if (!(ok)) oracle_finish(1); } while (0)
static void puts(const char *p) {
    volatile unsigned char *uart = (void *)0x10000000;
    for (; *p; ++p) { while (!(uart[5] & 32)) {} uart[0] = *p; }
    while (!(uart[5] & 32)) {} uart[0] = '\n';
}
#else
#include <assert.h>
#include <stdio.h>
#endif
static intptr_t hart[64] = {[58] = -1};
void *fpr_stack_grow(void) { __builtin_trap(); }
void *probe_hart = hart;
static unsigned yields;
static uintptr_t first_sp;
void fpr_fuel_exhausted(void) {
    uintptr_t sp = (uintptr_t)&sp;
    if (yields++) assert(first_sp == sp);
    else first_sp = sp;
    hart[0] = 7;
}
#ifdef FPR_ORACLE_RV64
/* The RV selector uses checked C primitives for these operations. The
   fixture's bounded inputs cannot overflow, so reference arithmetic is exact. */
static struct { uint32_t tid,var; } truth={1,1}, falsity={1,0};
intptr_t fpr_prim_fn__x2b(intptr_t a,intptr_t b) { return 2*((a>>1)+(b>>1))+1; }
intptr_t fpr_prim_fn__x2d(intptr_t a,intptr_t b) { return 2*((a>>1)-(b>>1))+1; }
intptr_t fpr_prim_fn__x2a(intptr_t a,intptr_t b) { return 2*((a>>1)*(b>>1))+1; }
intptr_t fpr_prim_fn__x3d_x3d(intptr_t a,intptr_t b) { return (intptr_t)(a==b?&truth:&falsity); }
#else
#define TRAP(name) intptr_t name(intptr_t a, intptr_t b) { (void)a; (void)b; __builtin_trap(); }
TRAP(fpr_prim_fn__x2b)
TRAP(fpr_prim_fn__x2d)
TRAP(fpr_prim_fn__x2a)
TRAP(fpr_prim_fn__x3d_x3d)
#endif
extern intptr_t fpr_fn_rotate2(intptr_t, intptr_t, intptr_t);
int main(void) {
#ifdef FPR_ORACLE_RV64
    __asm__ volatile ("mv tp, %0" :: "r"(hart) : "memory");
#endif
    for (intptr_t n=0; n<100; ++n) for (intptr_t a=-10; a<=10; ++a) {
        intptr_t b=31-a, want=n%2 ? b+2*a : a+2*b;
        hart[0]=7; yields=0; first_sp=0;
        assert(fpr_fn_rotate2(2*n+1, 2*a+1, 2*b+1) == 2*want+1);
        assert(yields == (unsigned)(n+1)/7);
        assert(hart[0] == 7-(n+1)%7);
    }
    puts("self loop: 2100 C-reference argument permutations, exact fuel resets and flat stack PASS");
    return 0;
}
