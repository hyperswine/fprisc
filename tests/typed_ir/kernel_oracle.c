/* Independent integer-column oracle, with hostile fuel calls. This runs on
   native/Rosetta x64 and bare RV32/RV64; hosted scheduler checks are separate. */
#include <stdint.h>
#ifndef __riscv
#include <stdio.h>
#include <stdlib.h>
#endif
typedef intptr_t V;
static V hart[64];
void *probe_hart=hart;
V probe_a6,probe_a7;
static unsigned yields,used,fallbacks;
#ifndef TRAP_CASE
#define TRAP_CASE 0
#endif
static void say(const char *msg) {
#ifdef __riscv
    volatile unsigned char *uart=(void*)0x10000000;
    for(;*msg;msg++) { while(!(uart[5]&32)) {} uart[0]=*msg; }
#else
    fputs(msg,stdout);
#endif
}
static void expected_trap(int division) {
    if(TRAP_CASE && division==(TRAP_CASE==4)) {
        say("TYPED_KERNEL_TRAP_PASS\n");
#ifdef __riscv
        *(volatile unsigned *)0x100000=0x5555; for(;;) {}
#else
        exit(0);
#endif
    }
}
static uintptr_t heap[4096];
#ifdef __riscv
__attribute__((noreturn)) void oracle_finish(int code) {
    *(volatile unsigned *)0x100000 = code ? ((unsigned)code<<16)|0x3333 : 0x5555;
    for (;;) {}
}
#else
__attribute__((noreturn)) void oracle_finish(int code) { fprintf(stderr,"oracle failure %d\n",code); exit(code?code:1); }
#endif
#define CHECK(ok) do { if (!(ok)) oracle_finish(__LINE__); } while (0)
static V tag(V x) { return (V)(((uintptr_t)x<<1)|1); }
void oracle_tick(void) { hart[0]=1; yields++; for(int i=1;i<=56;i++) hart[i]=tag(-777); }
#ifndef __riscv
void fpr_fuel_exhausted(void) {
    oracle_tick();
    __asm__ volatile("xor %%rax,%%rax; xor %%rcx,%%rcx; xor %%rdx,%%rdx; xor %%rsi,%%rsi; xor %%rdi,%%rdi; xor %%r8,%%r8; xor %%r9,%%r9; xor %%r10,%%r10; xor %%r11,%%r11" ::: "rax","rcx","rdx","rsi","rdi","r8","r9","r10","r11","cc");
}
#endif
uintptr_t fpr_stack_grow(void) { oracle_finish(__LINE__); }
V fpr_prim_fn__x2b(V a,V b) { return tag((a>>1)+(b>>1)); }
V fpr_prim_fn__x2d(V a,V b) { return tag((a>>1)-(b>>1)); }
V fpr_prim_fn__x2f(V a,V b) { CHECK(b>>1); return tag((a>>1)/(b>>1)); }
V fpr_prim_fn__x2a(V a,V b) { return tag((a>>1)*(b>>1)); }
struct Bool { uint32_t tid,var; } fpr_unit={0,0},fpr_false={1,0},fpr_true={1,1};
V fpr_alloc(V n) { CHECK(used+(n+sizeof(V)-1)/sizeof(V)<4096); V p=(V)(heap+used); used+=(n+sizeof(V)-1)/sizeof(V); return p; }
void fpr_int_overflow_kernel(void) { expected_trap(0); oracle_finish(__LINE__); }
void fpr_div_zero_kernel(void) { expected_trap(1); oracle_finish(__LINE__); }
V fpr_panic(V x) { (void)x; oracle_finish(__LINE__); }
/* Guard probes deliberately return a sentinel without reading invalid layout.
   A real-runtime test separately checks the generic fallback's actual result. */
V fpr_applyN(V h,V n,V *xs) { (void)n; (void)xs; return h; }
V fpr_apply(V h,V x) { (void)x; return h; }
V fpr_vec_map(V h,V v) { (void)h; (void)v; fallbacks++; return 123; }
V fpr_vec_filter(V h,V v) { (void)h; (void)v; fallbacks++; return 123; }
V fpr_vec_fold(V h,V z,V v) { (void)h; (void)z; (void)v; fallbacks++; return 123; }
typedef struct { V cap,*base; } Col;
typedef struct { uint32_t tid,rep; V len,tidEl,varEl,ncols; uint8_t *kinds; Col **cols; } Vec;
extern V fpr_fn_probeDiv(V,V),fpr_fn_probeMap(V,V),fpr_fn_probeFilter(V,V),fpr_fn_probeFold(V,V,V),fpr_fn_probePipe(V,V,V,V,V),fpr_fn_probeWfold(V,V);
int main(void) {
#ifdef __riscv
    __asm__ volatile("mv tp,%0" :: "r"(hart) : "memory");
#endif
    hart[57]=0; hart[58]=(V)UINTPTR_MAX;
    V cells[128]; uint8_t kinds[8]={1}; Col col={128,cells}; Col *cols[]={&col};
    if(TRAP_CASE) {
        Vec v={9006,1,1,0,0,1,kinds,cols};
        const V top=INTPTR_MAX/2, bottom=-top-1;
        hart[0]=1;
        if(TRAP_CASE==1) { cells[0]=1; fpr_fn_probeFold(tag(1),tag(top),(V)&v); }
        if(TRAP_CASE==2) { cells[0]=top; fpr_fn_probeFold(tag(top),tag(0),(V)&v); }
        if(TRAP_CASE==3) { cells[0]=bottom; fpr_fn_probeDiv(tag(-1),(V)&v); }
        if(TRAP_CASE==4) { cells[0]=7; fpr_fn_probeDiv(tag(0),(V)&v); }
        oracle_finish(__LINE__);
    }
    for(int n=0;n<100;n++) for(int cap=-3;cap<=3;cap++) {
        used=0; hart[0]=1;
        Vec v={9006,1,n,0,0,1,kinds,n?cols:0};
        for(int i=0;i<n;i++) cells[i]=i-20;
        CHECK(fpr_fn_probeMap(tag(cap),(V)&v)==(V)&v);
        for(int i=0;i<n;i++) CHECK(cells[i]==i-20+cap);
        CHECK(fpr_fn_probeFilter(tag(7),(V)&v)==(V)&v);
        int kept=0; V sum=7;
        for(int i=0;i<n;i++) if(i-20+cap>7) { CHECK(cells[kept++]==i-20+cap); sum+=2*(i-20+cap); }
        CHECK(v.len==kept);
        V pair=fpr_fn_probeFold(tag(2),tag(7),(V)&v);
        CHECK(*(V*)((char*)pair+8)==tag(sum));
        CHECK(*(V*)((char*)pair+8+sizeof(V))==(V)&v);
        v.len=n; for(int i=0;i<n;i++) cells[i]=i-20;
        pair=fpr_fn_probePipe(tag(cap),tag(7),tag(2),tag(7),(V)&v);
        CHECK(v.len==kept && *(V*)((char*)pair+8)==tag(sum));
        CHECK(*(V*)((char*)pair+8+sizeof(V))==(V)&v);
        kept=0; for(int i=0;i<n;i++) if(i-20+cap>7) CHECK(cells[kept++]==i-20+cap);
        v.len=n; for(int i=0;i<n;i++) cells[i]=i-20;
        CHECK(fpr_fn_probeDiv(tag(-3),(V)&v)==(V)&v);
        for(int i=0;i<n;i++) CHECK(cells[i]==(i-20)/-3);
        /* the write-back fold: the map's stores stay, the fold sees them */
        v.len=n; for(int i=0;i<n;i++) cells[i]=i-20;
        pair=fpr_fn_probeWfold(tag(7),(V)&v);
        sum=7; for(int i=0;i<n;i++) { CHECK(cells[i]==i-19); sum+=i-19; }
        CHECK(v.len==n && *(V*)((char*)pair+8)==tag(sum) && *(V*)((char*)pair+8+sizeof(V))==(V)&v);
    }
    Vec bad={9006,2,5,0,0,1,0,0};
    CHECK(fpr_fn_probeMap(tag(1),(V)&bad)==123);
    bad.rep=1; bad.kinds=kinds; kinds[0]=3;
    CHECK(fpr_fn_probeMap(tag(1),(V)&bad)==123);
    CHECK(fpr_fn_probeFilter((V)&fpr_unit,(V)&bad)==123);
    CHECK(fpr_fn_probeFold(tag(2),(V)&fpr_unit,(V)&bad)==123);
    CHECK(fallbacks==4 && yields>1000);
    say("TYPED_KERNEL_PASS 700 cases: map/filter/fold/fusion/write-back fold, empty columns, guard fallbacks, hostile yields\n");
    return 0;
}
