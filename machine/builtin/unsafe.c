/* Machine-sized addresses and unsafe memory/CSR primitives.
 * Addr values are raw bits in the checked ARC ABI and boxed leaves (T_BITS var 3)
 * in the legacy manual ABI. I64 values are raw 64-bit bits on RV64 in ARC/raw mode
 * and boxed fpr_num64_t (T_BITS var 4) otherwise. I32 values use runtime/i32.h.
 * Calls are unsafe: addresses, lifetimes and device permissions are caller
 * obligations. Volatile accesses do not imply hardware memory barriers.
 */
#include "builtin.h"
#include "i32.h"
#include "machine.h"
#define WIDTH (sizeof(uw) * 8)
static V box_addr(uw n) {
#ifdef FPR_BUILTIN_RAW
  return n;
#else
  bits_t *p = (bits_t *)fpr_alloc(sizeof(bits_t));
  *p = (bits_t){T_BITS, 3, WIDTH, n}; return (V)p;
#endif
}
static uw unbox_addr(V v) {
#ifdef FPR_BUILTIN_RAW
  return v;
#else
  if (!v || ISINT(v) || TID(v) != T_BITS || ((bits_t *)v)->var != 3)
    fpr_cpanic("Builtin: expected Addr");
  return ((bits_t *)v)->val;
#endif
}
static V box_i64(uint64_t x) {
#if defined(FPR_BUILTIN_RAW) && UINTPTR_MAX > 0xFFFFFFFFu
  return (V)x;
#else
  fpr_num64_t *p = (fpr_num64_t *)fpr_alloc(sizeof(fpr_num64_t));
  *p = (fpr_num64_t){T_BITS, 4, 64, x}; return (V)p;
#endif
}
static uint64_t unbox_i64(V v) {
#if defined(FPR_BUILTIN_RAW) && UINTPTR_MAX > 0xFFFFFFFFu
  return (uint64_t)v;
#else
  if (!v || ISINT(v) || TID(v) != T_BITS || ((hdr_t *)v)->var != 4)
    fpr_cpanic("Builtin: expected I64");
  return ((fpr_num64_t *)v)->val;
#endif
}
#define A(v) unbox_addr(v)
#define I64V(v) unbox_i64(v)
#define EXPORT(name, fn, ar) FPR_FN(fpr_g_##name, fn, ar)

static V addr_ofI64(V a) {
  uint64_t u = I64V(a);
#if UINTPTR_MAX <= 0xFFFFFFFFu
  if (u > (uint64_t)UINTPTR_MAX) fpr_cpanic("Addr.ofI64: address exceeds 32-bit pointer range");
#endif
  return box_addr((uw)u);
}
static V addr_toI64(V a) { return box_i64((uint64_t)A(a)); }
static V offset(V a,V n){return box_addr(A(a)+(uw)UNTAG(n));}
static V nulladdr(V u){(void)u;return box_addr(0);}
static V aeq(V a,V b){return A(a)==A(b)?V_TRUE:V_FALSE;}
EXPORT(Addr_x2eofI64,addr_ofI64,1); EXPORT(Addr_x2etoI64,addr_toI64,1); EXPORT(Addr_x2eadd,offset,2); EXPORT(Addr_x2enull,nulladdr,1); EXPORT(Addr_x2eeq,aeq,2);

static uw aligned(V a, uw size){uw p=A(a);if(p%size)fpr_cpanic("Builtin: unaligned access");return p;}
#define SMALL(n,t) static V read##n(V a){return TAG(fpr_machine_read##n(aligned(a,sizeof(t))));} \
 static V write##n(V a,V v){fpr_machine_write##n(aligned(a,sizeof(t)),(t)UNTAG(v));return V_UNIT;} \
 EXPORT(Mem_x2eread##n,read##n,1); EXPORT(Mem_x2ewrite##n,write##n,2)
SMALL(8,uint8_t); SMALL(16,uint16_t);

static V read32(V a){return fpr_i32_pack((uint32_t)fpr_machine_read32(aligned(a,4)));}
static V write32(V a,V v){fpr_machine_write32(aligned(a,4),fpr_i32_bits(v));return V_UNIT;}
EXPORT(Mem_x2eread32,read32,1); EXPORT(Mem_x2ewrite32,write32,2);

static uint64_t machine_read64(uw p) {
#if UINTPTR_MAX > 0xFFFFFFFFu
  return (uint64_t)fpr_machine_readWord(p);
#else
  uint64_t lo = (uint32_t)fpr_machine_read32(p);
  uint64_t hi = (uint32_t)fpr_machine_read32(p + 4);
  return lo | (hi << 32);
#endif
}
static void machine_write64(uw p, uint64_t v) {
#if UINTPTR_MAX > 0xFFFFFFFFu
  fpr_machine_writeWord(p, (uw)v);
#else
  fpr_machine_write32(p, (uint32_t)v);
  fpr_machine_write32(p + 4, (uint32_t)(v >> 32));
#endif
}
static V read64(V a){return box_i64(machine_read64(aligned(a,8)));}
static V write64(V a,V v){machine_write64(aligned(a,8),I64V(v));return V_UNIT;}
EXPORT(Mem_x2eread64,read64,1); EXPORT(Mem_x2ewrite64,write64,2);

/* Private compiler fusion entries. These keep the same unboxing/alignment,
 * volatile HAL operation and result representation as Addr.add + Mem.*,
 * without allocating an address that is immediately Rc.release'd. */
static uw indexed(V a,V offset,uw alignment) {
  uw p=A(a)+(uw)UNTAG(offset);
  if(p%alignment)fpr_cpanic("Builtin: unaligned access");
  return p;
}
#define INDEX_SMALL(n,t) \
 V fpr_prim_fn__x24mem_x2eread##n##at(V a,V off){return TAG(fpr_machine_read##n(indexed(a,off,sizeof(t))));} \
 V fpr_prim_fn__x24mem_x2ewrite##n##at(V a,V off,V v){fpr_machine_write##n(indexed(a,off,sizeof(t)),(t)UNTAG(v));return V_UNIT;}
INDEX_SMALL(8,uint8_t)
INDEX_SMALL(16,uint16_t)
V fpr_prim_fn__x24mem_x2eread32at(V a,V off){return fpr_i32_pack((uint32_t)fpr_machine_read32(indexed(a,off,4)));}
V fpr_prim_fn__x24mem_x2ewrite32at(V a,V off,V v){uw p=indexed(a,off,4);uint32_t value=fpr_i32_bits(v);fpr_machine_write32(p,value);return V_UNIT;}
V fpr_prim_fn__x24mem_x2eread64at(V a,V off){return box_i64(machine_read64(indexed(a,off,8)));}
V fpr_prim_fn__x24mem_x2ewrite64at(V a,V off,V v){uw p=indexed(a,off,8);uint64_t value=I64V(v);machine_write64(p,value);return V_UNIT;}

static uw size(V n){sw v=UNTAG(n);if(v<0)fpr_cpanic("Builtin: negative size");return (uw)v;}
static V alloc(V n){uw k=size(n);return box_addr(k?fpr_alloc(k):0);}
static V resize(V a,V n){return box_addr(fpr_realloc(A(a),size(n)));}
static V release(V a){fpr_free(A(a));return V_UNIT;}
static V fence_(V u){(void)u;fpr_machine_fence();return V_UNIT;}
static V rc_release(V v){fpr_builtin_release(v);return V_UNIT;}
EXPORT(Mem_x2ealloc,alloc,1); EXPORT(Mem_x2erealloc,resize,2); EXPORT(Mem_x2efree,release,1); EXPORT(Mem_x2efence,fence_,1);
EXPORT(Rc_x2eretain,fpr_builtin_retain,1); EXPORT(Rc_x2erelease,rc_release,1);

static V live(V u){(void)u;return TAG(fpr_builtin_live_allocations());}
EXPORT(Mem_x2eliveAllocations,live,1);

static V csrread(V n){return box_i64((uint64_t)fpr_machine_csr_read((uw)UNTAG(n)));}
static V csrwrite(V n,V w){fpr_machine_csr_write((uw)UNTAG(n),(uw)I64V(w));return V_UNIT;}
static V irqsave(V u){(void)u;return TAG(fpr_machine_irq_save());}
static V irqrestore(V v){sw n=UNTAG(v);if(n!=0 && n!=8)fpr_cpanic("Builtin: invalid IRQ token");fpr_machine_irq_restore((uw)n);return V_UNIT;}
static V irqenable(V u){(void)u;fpr_machine_irq_enable();return V_UNIT;}
static V waitirq(V u){(void)u;fpr_machine_wait();return V_UNIT;}
static V fencei(V u){(void)u;fpr_machine_fence_i();return V_UNIT;}
static V exchange(V a,V w){return box_i64((uint64_t)fpr_machine_exchange(aligned(a,8),(uw)I64V(w)));}
static V cas(V a,V expected,V desired){return box_i64((uint64_t)fpr_machine_compare_exchange(aligned(a,8),(uw)I64V(expected),(uw)I64V(desired)));}
EXPORT(CPU_x2ecsrRead,csrread,1); EXPORT(CPU_x2ecsrWrite,csrwrite,2);
EXPORT(CPU_x2eirqSave,irqsave,1); EXPORT(CPU_x2eirqRestore,irqrestore,1); EXPORT(CPU_x2eirqEnable,irqenable,1);
EXPORT(CPU_x2ewait,waitirq,1); EXPORT(CPU_x2einstructionFence,fencei,1);
EXPORT(Mem_x2eatomicExchange,exchange,2); EXPORT(Mem_x2ecompareExchange,cas,3);
