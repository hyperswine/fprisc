/* The actual emitted narrow entry constructs a wide call. At each fuel reset
 * another actor may use every hart argument cell before the first resumes. */
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
#define FUEL_SET(n) (state.hart[0]=(n))
#define fuel_left() ((intptr_t)state.hart[0])
#endif

static struct { uintptr_t guard0; intptr_t hart[64]; uintptr_t guard1; } state = {
    .guard0 = 0xbad123, .hart = {[58] = -1}, .guard1 = 0x456bad
};
struct tag { uint32_t type, variant; } fpr_true = {1,1}, fpr_false = {1,0};
static unsigned ticks;
__attribute__((noreturn)) void oracle_finish(int code) {
    *(volatile unsigned *)0x100000 = code ? 0x13333 : 0x5555;
    for (;;) {}
}
void oracle_tick(void) {
    ++ticks;
    FUEL_SET(3);
    for (int i = 1; i <= 56; ++i) state.hart[i] = 0xdead0000 + i;
}
void *fpr_stack_grow(void) { oracle_finish(1); }
/* Every oracle input fits. Taking a generic arithmetic slow path indicates
 * this fixture violated the positive-path contract. */
intptr_t fpr_prim_fn__x2a(intptr_t a, intptr_t b) { (void)a; (void)b; oracle_finish(1); }
intptr_t fpr_prim_fn__x2b(intptr_t a, intptr_t b) { (void)a; (void)b; oracle_finish(1); }
intptr_t fpr_prim_fn__x3d_x3d(intptr_t a, intptr_t b) { (void)a; (void)b; oracle_finish(1); }
#define ENTRY(w) extern intptr_t fpr_fn_start##w(intptr_t)
ENTRY(6); ENTRY(7); ENTRY(8); ENTRY(9); ENTRY(16); ENTRY(63); ENTRY(64);
static const struct { int width; intptr_t (*entry)(intptr_t); } cases[] = {
    {6,fpr_fn_start6},{7,fpr_fn_start7},{8,fpr_fn_start8},{9,fpr_fn_start9},
    {16,fpr_fn_start16},{63,fpr_fn_start63},{64,fpr_fn_start64}
};
static intptr_t answer(int width,int n) {
    intptr_t sum = 0;
    for (int bit = 0; bit <= 1; ++bit) {
        int lanes[64], count = 0;
        for (int i = 1; i < width; ++i) if ((i % 4 == 0) == bit) lanes[count++] = i;
        for (int j = 0; j < count; ++j) {
            int src = lanes[(j+n) % count];
            int value = bit ? ((src+1)%3==0 ? 11 : -13) : src*7-2;
            sum += lanes[j]*value;
        }
    }
    return sum;
}
int main(void) {
    __asm__ volatile ("mv tp, %0" :: "r"(state.hart) : "memory");
    for (unsigned k = 0; k < sizeof(cases)/sizeof(cases[0]); ++k) {
        for (int n = 0; n <= 512; ++n) {
            FUEL_SET(1); ticks=0;
            intptr_t got = cases[k].entry(2*n+1);
            if (got != 2*answer(cases[k].width,n)+1 || !ticks ||
                state.guard0!=0xbad123 || state.guard1!=0x456bad) oracle_finish(1);
        }
    }
    volatile unsigned char *uart=(void*)0x10000000;
    for (const char *p="3591 wide scalar answers and fuel clobbers PASS\n";*p;++p) {
        while (!(uart[5]&32)) {} uart[0]=*p;
    }
    return 0;
}
