/* Independent RV64 oracle: source products have field i = n+i and the caller
   accumulates weight i+1. C never calls the private product ABI directly. */
#include <stdint.h>
/* The fuel counter: x27 on AArch64 and s11 on RISC-V (runtime/fpr.h
   fpr_fuel_set; this file is then built -ffixed-x27), the hart block's
   first word on x86-64. */
#if defined(__aarch64__)
#define FUEL_SET(n) __asm__ volatile("mov x27,%0"::"r"((uintptr_t)(n)))
static inline intptr_t fuel_left(void){intptr_t n;__asm__ volatile("mov %0,x27":"=r"(n));return n;}
#elif defined(__riscv)
#define FUEL_SET(n) __asm__ volatile("mv s11,%0"::"r"((uintptr_t)(n)))
static inline intptr_t fuel_left(void){intptr_t n;__asm__ volatile("mv %0,s11":"=r"(n));return n;}
#else
#define FUEL_SET(n) (hart[0]=(n))
#define fuel_left() ((intptr_t)hart[0])
#endif
static intptr_t hart[64] = {[58] = -1};
static unsigned ticks;
__attribute__((noreturn)) void oracle_finish(int code) {
    *(volatile unsigned *)0x100000 = code ? 0x13333 : 0x5555;
    for (;;) {}
}
static void require(int ok) { if (!ok) oracle_finish(1); }
static void puts(const char *p) {
    volatile unsigned char *uart = (void *)0x10000000;
    for (; *p; ++p) { while (!(uart[5] & 32)) {} uart[0] = *p; }
    while (!(uart[5] & 32)) {} uart[0] = '\n';
}
void oracle_tick(void) { ++ticks; FUEL_SET(3); }
void *fpr_stack_grow(void) { oracle_finish(1); }
void *fpr_stack_reserve(void) { oracle_finish(1); }
static struct { uint32_t tid, var; } truth = {1,1}, falsity = {1,0};
/* All oracle inputs and their closed-form results are inside the Int domain. */
intptr_t fpr_prim_fn__x2b(intptr_t a, intptr_t b) { return 2*((a>>1)+(b>>1))+1; }
intptr_t fpr_prim_fn__x2d(intptr_t a, intptr_t b) { return 2*((a>>1)-(b>>1))+1; }
intptr_t fpr_prim_fn__x2a(intptr_t a, intptr_t b) { return 2*((a>>1)*(b>>1))+1; }
intptr_t fpr_prim_fn__x3c(intptr_t a, intptr_t b) { return (intptr_t)(a<b?&truth:&falsity); }
intptr_t fpr_prim_fn__x3d_x3d(intptr_t a, intptr_t b) { return (intptr_t)(a==b?&truth:&falsity); }
extern intptr_t fpr_fn_loop(intptr_t, intptr_t);
int main(void) {
    __asm__ volatile ("mv tp, %0" :: "r"(hart) : "memory");
    for (intptr_t n=0; n<100; ++n) for (intptr_t acc=-10; acc<=10; ++acc) {
        intptr_t want = acc;
        for (intptr_t i=0; i<PRODUCT_WIDTH; ++i)
            want += (n*(n+1)/2 + i*n)*(i+1);
        FUEL_SET(3); ticks=0;
        require(fpr_fn_loop(2*n+1, 2*acc+1) == 2*want+1);
        if (n>2) require(ticks>0);
    }
    puts("product return: 2100 C-reference results with volatile-register clobbering fuel resets PASS");
    return 0;
}
