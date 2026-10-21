/* Independent oracle for direct typed RV32/RV64. Runtime calls are substitutes;
   Linux CI separately exercises TLS, actor scheduling and real allocation. */
#include <stdint.h>
typedef intptr_t V;
static V hart[64];
static unsigned yields;
static uintptr_t heap[65536];
static unsigned used;
__attribute__((noreturn)) void oracle_finish(int code) {
    if (code) {
        volatile unsigned char *uart=(void *)0x10000000;
        char buf[24]; unsigned n=0, x=(unsigned)code;
        do { buf[n++]=(char)('0'+x%10); x/=10; } while(x);
        while(n) { while (!(uart[5]&32)) {} uart[0]=buf[--n]; }
        while (!(uart[5]&32)) {} uart[0]='\n';
    }
    *(volatile unsigned *)0x100000 = code ? 0x13333 : 0x5555;
    for (;;) {}
}
#define CHECK(ok) do { if (!(ok)) oracle_finish(__LINE__); } while (0)
static V tag(V x) { return (V)(((uintptr_t)x << 1) | 1); }
static V untag(V x) { return x >> 1; }
void oracle_tick(void) {
    hart[0] = 3; yields++;
    for (int i=1; i<=56; i++) hart[i]=tag(-777);
}
uintptr_t fpr_stack_grow(void) { oracle_finish(1); }
V fpr_prim_fn__x2b(V a,V b) { return tag(untag(a)+untag(b)); }
V fpr_prim_fn__x2d(V a,V b) { return tag(untag(a)-untag(b)); }
V fpr_prim_fn__x2a(V a,V b) { return tag(untag(a)*untag(b)); }
V fpr_prim_fn__x2f(V a,V b) { CHECK(untag(b)); return tag(untag(a)/untag(b)); }
struct Bool { uint32_t tid,var; } fpr_unit={0,0}, fpr_false={1,0}, fpr_true={1,1};
V fpr_prim_fn__x3d_x3d(V a,V b) { return (V)(a==b ? &fpr_true : &fpr_false); }
V fpr_alloc(V bytes) {
    CHECK(bytes>=8 && used+(bytes+sizeof(uintptr_t)-1)/sizeof(uintptr_t) < 65536);
    V result=(V)&heap[used]; used+=(bytes+sizeof(uintptr_t)-1)/sizeof(uintptr_t); return result;
}
struct Str { uint32_t tid,var; uintptr_t len; unsigned char bytes[]; };
V fpr_g_strlen_call1(V x) { struct Str *s=(void *)x; CHECK(s->tid==9000); return tag(s->len); }
V fpr_g_charAt_call2(V x,V n) { struct Str *s=(void *)x; CHECK(s->tid==9000 && untag(n)>=0 && (uintptr_t)untag(n)<s->len); return tag(s->bytes[untag(n)]); }
V fpr_panic(V x) { (void)x; oracle_finish(1); }
extern V fpr_fn_rvArith(V,V), fpr_fn_rvDiv(V,V), fpr_fn_rvChoose(V,V), fpr_fn_rvLoop(V,V,V);
extern V fpr_fn_rvNested(V), fpr_fn_rvString(V), fpr_fn_rvLen(V), fpr_fn_rvByte(V,V), fpr_fn_rvWideCall(V);
int main(void) {
    __asm__ volatile("mv tp, %0" :: "r"(hart) : "memory");
    hart[57]=0; hart[58]=(V)UINTPTR_MAX;
    unsigned count=0;
    for (V a=-20;a<=20;a++) for(V b=-10;b<=10;b++) {
        hart[0]=1;
        CHECK(fpr_fn_rvArith(tag(a),tag(b))==tag(a*b+a-b)); count++;
        CHECK(fpr_fn_rvChoose(tag(a),tag(b))==tag(a<b?a:b)); count++;
        if(b) { CHECK(fpr_fn_rvDiv(tag(a),tag(b))==tag(a/b)); count++; }
    }
    for (V n=0;n<100;n++) for(V a=-10;a<=10;a++) {
        V b=31-a; hart[0]=1;
        CHECK(fpr_fn_rvLoop(tag(n),tag(a),tag(b))==tag(n%2 ? b+2*a : a+2*b)); count++;
    }
    for (V n=-20;n<=20;n++) {
        hart[0]=1;
        CHECK(fpr_fn_rvNested(tag(n))==tag(4*n+6)); count++;
        CHECK(fpr_fn_rvWideCall(tag(n))==tag(n+44)); count++;
    }
    V s=fpr_fn_rvString((V)&fpr_unit);
    CHECK(fpr_fn_rvLen(s)==tag(3));
    for (V i=0;i<3;i++) CHECK(fpr_fn_rvByte(s,tag(i))==tag(65+i));
    CHECK(count==4724 && yields>1000 && used>0);
    volatile unsigned char *uart=(void *)0x10000000;
    const char *msg="TYPED_RV_PASS 4724 reference results, forced fuel clobbers, nine arguments, aggregates, strings\n";
    for (;*msg;msg++) { while (!(uart[5]&32)) {} uart[0]=*msg; }
    return 0;
}
