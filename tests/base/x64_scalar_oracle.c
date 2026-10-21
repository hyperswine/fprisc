/* Independent arithmetic/ABI oracle. Runtime hooks are test substitutes. */
#include <assert.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef intptr_t V;
typedef void (*Fn)(void);
static uintptr_t hart[64];
void *probe_hart = hart;
V probe_a6, probe_a7;
struct Bool { uint32_t tid, var; } fpr_false = {1, 0}, fpr_true = {1, 1};
static unsigned yields, traps, cases;
static unsigned fallbacks[5];
static jmp_buf failure;
static int expected_trap, trap_kind;
static V trap_a, trap_b;
static const int64_t lo = -INT64_C(4611686018427387904), hi = INT64_C(4611686018427387903);

static V tag(int64_t x) { return (V)(((uint64_t)x << 1) | 1); }
static int64_t untag(V x) { return x >> 1; }
void probe_fuel_reset(void) {
    ++yields; hart[0] = 3;
    /* Entry must copy private argument cells before a scheduling boundary. */
    probe_a6=probe_a7=tag(-777);
    for (unsigned i=1;i<=56;i++) hart[i]=(uintptr_t)tag(-777);
}
uintptr_t fpr_stack_grow(void) { fputs("unexpected stack growth\n", stderr); abort(); }
static V fail(int kind, V a, V b) {
    assert(expected_trap);
    trap_kind = kind; trap_a = a; trap_b = b; ++traps;
    longjmp(failure, 1);
}
static V arithmetic(int op, V a, V b) {
    ++fallbacks[op];
    __int128 x = untag(a), y = untag(b), result;
    if (op == 4 && y == 0) return fail(5, a, b);
    result = op == 1 ? x+y : op == 2 ? x-y : op == 3 ? x*y : x/y;
    if (result < lo || result > hi) return fail(op, a, b);
    /* Legacy guards deliberately delegate e.g. division by -1 to C. */
    return tag((int64_t)result);
}
V fpr_prim_fn__x2b(V a, V b) { return arithmetic(1,a,b); }
V fpr_prim_fn__x2d(V a, V b) { return arithmetic(2,a,b); }
V fpr_prim_fn__x2a(V a, V b) { return arithmetic(3,a,b); }
V fpr_prim_fn__x2f(V a, V b) { return arithmetic(4,a,b); }
V fpr_g_BITSHIFTL_call2(V a, V b) {
    assert(untag(b) < 0 || untag(b) > 63);
    return fail(6,a,b);
}
/* a dead arm reached: the reason is a String object {tid 9000, var, len, bytes} */
struct Str { uint32_t tid, var; uint64_t len; unsigned char bytes[]; };
static const char *dead_reason = "case: no matching pattern; arms were [PCon \"Unit\" []]";
V fpr_panic(V s) {
    const struct Str *t = (const void *)s;
    assert(t->tid == 9000 && t->len == strlen(dead_reason) && memcmp(t->bytes, dead_reason, t->len) == 0);
    return fail(7, s, 0);
}
struct Bool fpr_unit = {0, 0};
/* the generic application's staging: head at 16n(rargs), argument i at
   16(n-1-i)(rargs); this substitute applies a saturated static PAP only */
struct Pap { uint32_t tid, var; V (*fn)(V); intptr_t arity, nargs; };
static V inc(V x) { return tag(untag(x) + 1); }
static struct Pap incPap = {9001, 0, inc, 1, 0};
static unsigned applies;
V fpr_applyN(V f, uintptr_t n, V *rargs) {
    struct Pap *p = (struct Pap *)f;
    assert(p->tid == 9001 && p->nargs == 0 && n == (uintptr_t)p->arity && n == 1);
    ++applies;
    return p->fn(rargs[0]);
}
static int equal(V a,V b) {
    if ((a&1) || (b&1)) return a==b;
    struct Bool *x=(void *)a, *y=(void *)b;
    assert(x->tid==1 && y->tid==1);
    return x->var==y->var;
}
V fpr_prim_fn__x3d_x3d(V a,V b) { return (V)(equal(a,b) ? &fpr_true : &fpr_false); }
V fpr_prim_fn__x21_x3d(V a,V b) { return (V)(equal(a,b) ? &fpr_false : &fpr_true); }
V fpr_prim_fn__x3c(V a,V b) { assert(0); return 0; }
V fpr_prim_fn__x3e(V a,V b) { assert(0); return 0; }
extern V probe_call(Fn, const V *);
#define DECL(name) extern void fpr_fn_##name(void)
DECL(add); DECL(sub); DECL(mul); DECL(divide); DECL(shift); DECL(branch);
DECL(hot); DECL(calls); DECL(boolResult); DECL(boolEq); DECL(boolNe);
DECL(call7); DECL(call8); DECL(rotate6); DECL(rotate7); DECL(rotate8); DECL(rotate63);
DECL(pressure); DECL(wide);
DECL(answer); DECL(useCaf); DECL(tick); DECL(applyLocal);

static V invoke(Fn fn, const V *args, unsigned count) {
    V first[6] = {0};
    for (unsigned i=0;i<count && i<6;i++) first[i]=args[i];
    probe_a6=count>6 ? args[6] : 0; probe_a7=count>7 ? args[7] : 0;
    for (unsigned i=8;i<count;i++) hart[i-7]=(uintptr_t)args[i];
    hart[0]=1; hart[57]=0; hart[58]=UINTPTR_MAX;
    ++cases;
    return probe_call(fn,first);
}
static void binary(Fn fn, int64_t a, int64_t b, int64_t want) {
    V args[]={tag(a),tag(b)};
    assert(invoke(fn,args,2)==tag(want));
}
static void trap(Fn fn, int kind, int64_t a, int64_t b) {
    V args[]={tag(a),tag(b)};
    expected_trap=1;
    if (!setjmp(failure)) { invoke(fn,args,2); assert(!"missing trap"); }
    assert(trap_kind==kind && trap_a==args[0] && trap_b==args[1]);
    expected_trap=0;
}
static int64_t hot(int64_t a,int64_t b,int64_t c,int64_t d,int64_t e) {
    return a*b+c*d+e*a+b*c+d*e+a*c+b*d+c*e+d*a+e*b;
}
int main(void) {
    for (int64_t a=-40;a<=40;a++) for (int64_t b=-31;b<=31;b++) {
        binary(fpr_fn_add,a,b,a+b); binary(fpr_fn_sub,a,b,a-b);
        binary(fpr_fn_mul,a,b,a*b);
        if (b) binary(fpr_fn_divide,a,b,a/b);
        binary(fpr_fn_branch,a,b,a<b ? a-b : a+b);
        V args[]={tag(a),tag(b),tag(13),tag(-3),tag(6)};
        int64_t want=hot(a,b,13,-3,6)+hot(6,-3,13,b,a)+a+b+16;
        assert(invoke(fpr_fn_calls,args,5)==tag(want));
    }
    assert(fallbacks[1]==0 && fallbacks[2]==0 && fallbacks[3]==0 && fallbacks[4]<1000);
    /* M3: twelve values across a generated call (more than the five-register
       budget) and twenty-four live at once in straight-line code */
    for (int64_t n=-50;n<=50;n++) {
        V arg[]={tag(n)};
        assert(invoke(fpr_fn_pressure,arg,1)==tag(12*n+78+hot(n,n,n,n,n)));
        assert(invoke(fpr_fn_wide,arg,1)==tag(n*324));
    }
    int64_t edges[]={lo,lo+1,-2147483648LL,-1,0,1,2147483647LL,hi-1,hi};
    for (unsigned i=0;i<sizeof edges/sizeof *edges;i++) {
        int64_t x=edges[i];
        binary(fpr_fn_add,x,0,x); binary(fpr_fn_sub,x,0,x);
        binary(fpr_fn_mul,x,1,x); binary(fpr_fn_divide,x,1,x);
        for(int k=0;k<64;k++) {
            uint64_t u=(uint64_t)x << k;
            V args[]={tag(x),tag(k)};
            assert((uint64_t)invoke(fpr_fn_shift,args,2)==((u<<1)|1));
        }
    }
    trap(fpr_fn_add,1,hi,1); trap(fpr_fn_add,1,lo,-1);
    trap(fpr_fn_sub,2,lo,1); trap(fpr_fn_sub,2,hi,-1);
    trap(fpr_fn_mul,3,2147483648LL,2147483648LL);
    trap(fpr_fn_mul,3,lo,lo); trap(fpr_fn_mul,3,hi,hi);
    trap(fpr_fn_mul,3,lo,-1); trap(fpr_fn_divide,4,lo,-1);
    trap(fpr_fn_divide,5,7,0);
    trap(fpr_fn_shift,6,7,-1); trap(fpr_fn_shift,6,7,64);
    for(int n=0;n<12;n++) for(int flag=-1;flag<=1;flag++) {
        binary(fpr_fn_boolResult,n,flag,flag>0 ? 10 : 1);
        struct Bool foreign={1,flag>0};
        V args[]={tag(n),(V)&foreign};
        struct Bool *eq=(void *)invoke(fpr_fn_boolEq,args,2);
        struct Bool *ne=(void *)invoke(fpr_fn_boolNe,args,2);
        assert(eq->tid==1 && eq->var==(unsigned)(flag>0));
        assert(ne->tid==1 && ne->var==(unsigned)(flag<=0));
    }
    Fn rotations[]={fpr_fn_rotate6,fpr_fn_rotate7,fpr_fn_rotate8,fpr_fn_rotate63};
    unsigned widths[]={6,7,8,63};
    for(unsigned w=0;w<4;w++) for(unsigned n=0;n<70;n++) {
        V args[64]; unsigned width=widths[w]; args[0]=tag(n);
        for(unsigned i=0;i<width;i++) args[i+1]=tag((int)i-30);
        int64_t want=0;
        for(unsigned i=0;i<width;i++) want+=(int64_t)(i+1)*((int)((i+n)%width)-30);
        assert(invoke(rotations[w],args,width+1)==tag(want));
        if (width <= 7) {
            int64_t next=0;
            for(unsigned i=0;i<width;i++) next+=(int64_t)(i+1)*((int)((i+n+1)%width)-30);
            assert(invoke(width==6 ? fpr_fn_call7 : fpr_fn_call8,args,width+1)==tag(want+next-30));
        }
    }
    /* a nullary definition evaluated by a call, and a case on Unit: the
       live arm, then the dead arm reached with an Int (the legacy trap) */
    { V none[1]={0}; assert(invoke(fpr_fn_answer,none,0)==tag(42)); }
    for (int64_t n=-3;n<=3;n++) { V args[]={tag(n)}; assert(invoke(fpr_fn_useCaf,args,1)==tag(n+42)); }
    { V args[]={(V)&fpr_unit}; assert(invoke(fpr_fn_tick,args,1)==tag(7)); }
    { V args[]={tag(5)}; expected_trap=1;
      if (!setjmp(failure)) { invoke(fpr_fn_tick,args,1); assert(!"missing trap"); }
      assert(trap_kind==7); expected_trap=0; }
    /* a function parameter applied twice through fpr_applyN's stack staging */
    for (int64_t x=-5;x<=5;x++) { V args[]={(V)&incPap,tag(x)}; assert(invoke(fpr_fn_applyLocal,args,2)==tag(2*x+3)); }
    assert(applies==22);
    assert(yields>cases && traps==13);
    printf("%u C-reference cases, 13 exact slow-path traps, foreign Bools, 7/8-argument non-tail calls, 7/8/9/64-argument rotations, register pressure across calls and in straight lines, a nullary definition, a dead arm reached, 22 generic applications, callee saves/alignment/volatile clobbers PASS\n",cases);
    return 0;
}
