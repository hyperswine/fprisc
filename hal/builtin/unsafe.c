/* Machine-sized values are boxed leaves, NOT tagged Ints. T_BITS variants
 * 2 and 3 distinguish Word/Addr from legacy bit arrays (variants 0 and 1).
 * Calls are unsafe: addresses, lifetimes and device permissions are caller
 * obligations. Volatile accesses do not imply hardware memory barriers.
 */
#include "builtin.h"
#include "machine.h"
#define WIDTH (sizeof(uw) * 8)
static V box(uw n, unsigned kind) {
  bits_t *p = (bits_t *)fpr_alloc(sizeof(bits_t));
  *p = (bits_t){T_BITS, kind, WIDTH, n}; return (V)p;
}
static uw unbox(V v, unsigned kind) {
  if (!v || ISINT(v) || TID(v) != T_BITS || ((bits_t *)v)->var != kind)
    fpr_cpanic("Builtin: expected Word/Addr");
  return ((bits_t *)v)->val;
}
#define W(v) unbox(v,2)
#define A(v) unbox(v,3)
#define EXPORT(name, fn, ar) FPR_FN(fpr_g_##name, fn, ar)
static V fromInt(V v) { return box((uw)UNTAG(v),2); }
static V toInt(V v) { return TAG(W(v)); }
static V width(V u) { (void)u; return TAG(WIDTH); }
EXPORT(Word_x2efromInt,fromInt,1); EXPORT(Word_x2etoInt,toInt,1); EXPORT(Word_x2ebits,width,1);
#define BIN(name,op) static V w_##name(V a,V b){return box(W(a) op W(b),2);} EXPORT(Word_x2e##name,w_##name,2)
BIN(add,+); BIN(sub,-);
#define RAWBIN(name) static V w_##name(V a,V b){return box(fpr_machine_##name(W(a),W(b)),2);} EXPORT(Word_x2e##name,w_##name,2)
RAWBIN(and); RAWBIN(or); RAWBIN(xor);
static V w_not(V a) { return box(fpr_machine_not(W(a)),2); }
static uw shift(V n) { sw k=UNTAG(n); if(k<0 || (uw)k>=WIDTH) fpr_cpanic("Builtin: shift out of range"); return (uw)k; }
static V shl(V a,V n) { return box(fpr_machine_shl(W(a),shift(n)),2); }
static V shr(V a,V n) { return box(fpr_machine_shr(W(a),shift(n)),2); }
static V mask(V count,V offset) {
  sw n=UNTAG(count), k=UNTAG(offset);
  if(n<0 || k<0 || (uw)n>WIDTH || (uw)k>WIDTH-(uw)n) fpr_cpanic("Builtin: mask out of range");
  return box(!n ? 0 : ((~(uw)0 >> (WIDTH-(uw)n)) << k),2);
}
static V weq(V a,V b){return W(a)==W(b)?(V)&fpr_true:(V)&fpr_false;}
EXPORT(Word_x2enot,w_not,1); EXPORT(Word_x2eshl,shl,2); EXPORT(Word_x2eshr,shr,2); EXPORT(Word_x2emask,mask,2); EXPORT(Word_x2eeq,weq,2);
static V address(V a){return box(W(a),3);}
static V word(V a){return box(A(a),2);}
static V offset(V a,V n){return box(A(a)+(uw)UNTAG(n),3);}
static V nulladdr(V u){(void)u;return box(0,3);}
static V aeq(V a,V b){return A(a)==A(b)?(V)&fpr_true:(V)&fpr_false;}
EXPORT(Addr_x2efromWord,address,1); EXPORT(Addr_x2etoWord,word,1); EXPORT(Addr_x2eadd,offset,2); EXPORT(Addr_x2enull,nulladdr,1); EXPORT(Addr_x2eeq,aeq,2);
static uw aligned(V a, uw size){uw p=A(a);if(p%size)fpr_cpanic("Builtin: unaligned access");return p;}
#define SMALL(n,t) static V read##n(V a){return TAG(fpr_machine_read##n(aligned(a,sizeof(t))));} \
 static V write##n(V a,V v){fpr_machine_write##n(aligned(a,sizeof(t)),(t)UNTAG(v));return (V)&fpr_unit;} \
 EXPORT(Mem_x2eread##n,read##n,1); EXPORT(Mem_x2ewrite##n,write##n,2)
SMALL(8,uint8_t); SMALL(16,uint16_t);
#define LARGE(n,t) static V read##n(V a){return box(fpr_machine_read##n(aligned(a,sizeof(t))),2);} \
 static V write##n(V a,V v){fpr_machine_write##n(aligned(a,sizeof(t)),(t)W(v));return (V)&fpr_unit;} \
 EXPORT(Mem_x2eread##n,read##n,1); EXPORT(Mem_x2ewrite##n,write##n,2)
LARGE(32,uint32_t); LARGE(Word,uw);
static uw size(V n){sw v=UNTAG(n);if(v<0)fpr_cpanic("Builtin: negative size");return (uw)v;}
static V alloc(V n){uw k=size(n);return box(k?fpr_alloc(k):0,3);}
static V resize(V a,V n){return box(fpr_realloc(A(a),size(n)),3);}
static V release(V a){fpr_free(A(a));return (V)&fpr_unit;}
static V fence_(V u){(void)u;fpr_machine_fence();return (V)&fpr_unit;}
static V rc_release(V v){fpr_builtin_release(v);return (V)&fpr_unit;}
EXPORT(Mem_x2ealloc,alloc,1); EXPORT(Mem_x2erealloc,resize,2); EXPORT(Mem_x2efree,release,1); EXPORT(Mem_x2efence,fence_,1);
EXPORT(Rc_x2eretain,fpr_builtin_retain,1); EXPORT(Rc_x2erelease,rc_release,1);

static V live(V u){(void)u;return TAG(fpr_builtin_live_allocations());}
EXPORT(Mem_x2eliveAllocations,live,1);

static V bitset(V w,V n){return box(fpr_machine_bit_set(W(w),shift(n)),2);}
static V bitclear(V w,V n){return box(fpr_machine_bit_clear(W(w),shift(n)),2);}
static V bittest(V w,V n){return fpr_machine_bit_test(W(w),shift(n))?(V)&fpr_true:(V)&fpr_false;}
EXPORT(Word_x2ebitSet,bitset,2); EXPORT(Word_x2ebitClear,bitclear,2); EXPORT(Word_x2ebitTest,bittest,2);
static V csrread(V n){return box(fpr_machine_csr_read((uw)UNTAG(n)),2);}
static V csrwrite(V n,V w){fpr_machine_csr_write((uw)UNTAG(n),W(w));return (V)&fpr_unit;}
static V irqsave(V u){(void)u;return TAG(fpr_machine_irq_save());}
static V irqrestore(V v){sw n=UNTAG(v);if(n!=0 && n!=8)fpr_cpanic("Builtin: invalid IRQ token");fpr_machine_irq_restore((uw)n);return (V)&fpr_unit;}
static V irqenable(V u){(void)u;fpr_machine_irq_enable();return (V)&fpr_unit;}
static V waitirq(V u){(void)u;fpr_machine_wait();return (V)&fpr_unit;}
static V fencei(V u){(void)u;fpr_machine_fence_i();return (V)&fpr_unit;}
static V exchange(V a,V w){return box(fpr_machine_exchange(aligned(a,8),W(w)),2);}
static V cas(V a,V expected,V desired){return box(fpr_machine_compare_exchange(aligned(a,8),W(expected),W(desired)),2);}
EXPORT(CPU_x2ecsrRead,csrread,1); EXPORT(CPU_x2ecsrWrite,csrwrite,2);
EXPORT(CPU_x2eirqSave,irqsave,1); EXPORT(CPU_x2eirqRestore,irqrestore,1); EXPORT(CPU_x2eirqEnable,irqenable,1);
EXPORT(CPU_x2ewait,waitirq,1); EXPORT(CPU_x2einstructionFence,fencei,1);
EXPORT(Mem_x2eatomicExchange,exchange,2); EXPORT(Mem_x2ecompareExchange,cas,3);
