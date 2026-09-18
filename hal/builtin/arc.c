/* Owned-call ABI adapters. Existing primitives borrow inputs; these adapters
 * consume them. A top-level alias result gets retained before input release.
 * No primitive returning a borrowed interior pointer is admitted here.
 */
#include "builtin.h"
#ifdef FPR_BUILTIN_ARC
V fpr_fn__x24arc_x2eretain(V v) { return fpr_builtin_retain(v); }
V fpr_fn__x24arc_x2erelease(V v) { fpr_builtin_release(v); return (V)&fpr_unit; }
#define FINISH1(r,a) do { if((r)==(a))fpr_builtin_retain(r); fpr_builtin_release(a); return r; } while(0)
#define FINISH2(r,a,b) do { if((r)==(a)||(r)==(b))fpr_builtin_retain(r); fpr_builtin_release(a); fpr_builtin_release(b); return r; } while(0)
#define PRIM1(name,sym) extern V sym(V); V fpr_fn__x24arc_x2e##name(V a){V r=sym(a);FINISH1(r,a);}
#define PRIM2(name,sym) extern V sym(V,V); V fpr_fn__x24arc_x2e##name(V a,V b){V r=sym(a,b);FINISH2(r,a,b);}
PRIM2(add,fpr_prim_fn__x2b)
PRIM2(sub,fpr_prim_fn__x2d)
PRIM2(mul,fpr_prim_fn__x2a)
PRIM2(div,fpr_prim_fn__x2f)
PRIM2(eq,fpr_prim_fn__x3d_x3d)
PRIM2(ne,fpr_prim_fn__x21_x3d)
PRIM2(lt,fpr_prim_fn__x3c)
PRIM2(gt,fpr_prim_fn__x3e)
PRIM2(le,fpr_prim_fn__x3c_x3d)
PRIM2(ge,fpr_prim_fn__x3e_x3d)
PRIM1(print,fpr_prim_fn_print)
PRIM1(str,fpr_prim_fn_str)
PRIM1(strlen,fpr_prim_fn_String_x2elen)
PRIM2(strcat,fpr_prim_fn_strcat)
V fpr_fn__x24arc_x2eerror(V s) { fpr_panic(s); }
#define HAL1(name,sym) extern const pap0_t sym; V fpr_fn__x24arc_x2e##name(V a){V r=((V(*)(V))sym.fn)(a);FINISH1(r,a);}
#define HAL2(name,sym) extern const pap0_t sym; V fpr_fn__x24arc_x2e##name(V a,V b){V r=((V(*)(V,V))sym.fn)(a,b);FINISH2(r,a,b);}
HAL1(wordfromInt,fpr_g_Word_x2efromInt)
HAL1(wordtoInt,fpr_g_Word_x2etoInt)
HAL1(wordbits,fpr_g_Word_x2ebits)
HAL1(wordnot,fpr_g_Word_x2enot)
HAL2(wordand,fpr_g_Word_x2eand)
HAL2(wordor,fpr_g_Word_x2eor)
HAL2(wordxor,fpr_g_Word_x2exor)
HAL2(wordadd,fpr_g_Word_x2eadd)
HAL2(wordsub,fpr_g_Word_x2esub)
HAL2(wordshl,fpr_g_Word_x2eshl)
HAL2(wordshr,fpr_g_Word_x2eshr)
HAL2(wordmask,fpr_g_Word_x2emask)
HAL2(wordeq,fpr_g_Word_x2eeq)
HAL1(addrfromWord,fpr_g_Addr_x2efromWord)
HAL1(addrtoWord,fpr_g_Addr_x2etoWord)
HAL1(addrnull,fpr_g_Addr_x2enull)
HAL2(addradd,fpr_g_Addr_x2eadd)
HAL2(addreq,fpr_g_Addr_x2eeq)
HAL1(memread8,fpr_g_Mem_x2eread8)
HAL1(memread16,fpr_g_Mem_x2eread16)
HAL1(memread32,fpr_g_Mem_x2eread32)
HAL1(memreadWord,fpr_g_Mem_x2ereadWord)
HAL2(memwrite8,fpr_g_Mem_x2ewrite8)
HAL2(memwrite16,fpr_g_Mem_x2ewrite16)
HAL2(memwrite32,fpr_g_Mem_x2ewrite32)
HAL2(memwriteWord,fpr_g_Mem_x2ewriteWord)
HAL1(memalloc,fpr_g_Mem_x2ealloc)
HAL2(memrealloc,fpr_g_Mem_x2erealloc)
HAL1(memfree,fpr_g_Mem_x2efree)
HAL1(memfence,fpr_g_Mem_x2efence)
HAL1(memliveAllocations,fpr_g_Mem_x2eliveAllocations)

HAL2(wordbitSet,fpr_g_Word_x2ebitSet)
HAL2(wordbitClear,fpr_g_Word_x2ebitClear)
HAL2(wordbitTest,fpr_g_Word_x2ebitTest)
HAL1(cpucsrRead,fpr_g_CPU_x2ecsrRead)
HAL2(cpucsrWrite,fpr_g_CPU_x2ecsrWrite)
HAL1(cpuirqSave,fpr_g_CPU_x2eirqSave)
HAL1(cpuirqRestore,fpr_g_CPU_x2eirqRestore)
HAL1(cpuirqEnable,fpr_g_CPU_x2eirqEnable)
HAL1(cpuwait,fpr_g_CPU_x2ewait)
HAL1(cpuinstructionFence,fpr_g_CPU_x2einstructionFence)
HAL2(mematomicExchange,fpr_g_Mem_x2eatomicExchange)
extern const pap0_t fpr_g_Mem_x2ecompareExchange;
V fpr_fn__x24arc_x2ememcompareExchange(V a,V expected,V desired) {
  V r=((V(*)(V,V,V))fpr_g_Mem_x2ecompareExchange.fn)(a,expected,desired);
  /* Contract: fresh Word result, all three arguments borrowed by the primitive. */
  fpr_builtin_release(a);fpr_builtin_release(expected);fpr_builtin_release(desired);
  return r;
}
#endif
