/* Owned-call ABI adapters. Existing primitives borrow inputs; these adapters
 * consume them. A top-level alias result gets retained before input release.
 * No primitive returning a borrowed interior pointer is admitted here.
 */
#include "builtin.h"
#ifdef FPR_BUILTIN_ARC
V fpr_fn__x24arc_x2eretain(V v) { return fpr_builtin_retain(v); }
V fpr_fn__x24arc_x2erelease(V v) { fpr_builtin_release(v); return (V)&fpr_unit; }
V fpr_fn__x24arc_x2esetLayout(V v,V layout) { fpr_builtin_set_layout(v,layout); return (V)&fpr_unit; }
V fpr_fn__x24arc_x2erawEq(V a,V b) { return a==b?(V)&fpr_true:(V)&fpr_false; }
V fpr_fn__x24arc_x2erawNe(V a,V b) { return a!=b?(V)&fpr_true:(V)&fpr_false; }
extern V fpr_prim_fn_str(V), fpr_prim_fn_print(V);
V fpr_fn__x24arc_x2ewordStr(V a) { bits_t b={T_BITS,2,64,a}; return fpr_prim_fn_str((V)&b); }
V fpr_fn__x24arc_x2ewordPrint(V a) { bits_t b={T_BITS,2,64,a}; return fpr_prim_fn_print((V)&b); }
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
#ifdef FPR_BUILTIN_RAW
#undef FINISH1
#undef FINISH2
#define FINISH1(r,a) return r
#define FINISH2(r,a,b) return r
#endif
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
#ifndef FPR_BUILTIN_RAW
  fpr_builtin_release(a);fpr_builtin_release(expected);fpr_builtin_release(desired);
#endif
  return r;
}
#endif

#ifdef FPR_BUILTIN_RAW
extern V fpr_prim_fn_F64_x2e_x2b(V a,V b);
V fpr_fn__x24arc_x2eF64add(V a,V b) { return fpr_prim_fn_F64_x2e_x2b(a,b); }
extern V fpr_prim_fn_F64_x2e_x2d(V a,V b);
V fpr_fn__x24arc_x2eF64sub(V a,V b) { return fpr_prim_fn_F64_x2e_x2d(a,b); }
extern V fpr_prim_fn_F64_x2e_x2a(V a,V b);
V fpr_fn__x24arc_x2eF64mul(V a,V b) { return fpr_prim_fn_F64_x2e_x2a(a,b); }
extern V fpr_prim_fn_F64_x2e_x2f(V a,V b);
V fpr_fn__x24arc_x2eF64div(V a,V b) { return fpr_prim_fn_F64_x2e_x2f(a,b); }
extern V fpr_prim_fn_F64_x2e_x3c(V a,V b);
V fpr_fn__x24arc_x2eF64lt(V a,V b) { return fpr_prim_fn_F64_x2e_x3c(a,b); }
extern V fpr_prim_fn_F64_x2e_x3e(V a,V b);
V fpr_fn__x24arc_x2eF64gt(V a,V b) { return fpr_prim_fn_F64_x2e_x3e(a,b); }
extern V fpr_prim_fn_F64_x2e_x3c_x3d(V a,V b);
V fpr_fn__x24arc_x2eF64le(V a,V b) { return fpr_prim_fn_F64_x2e_x3c_x3d(a,b); }
extern V fpr_prim_fn_F64_x2e_x3e_x3d(V a,V b);
V fpr_fn__x24arc_x2eF64ge(V a,V b) { return fpr_prim_fn_F64_x2e_x3e_x3d(a,b); }
extern V fpr_prim_fn_F64_x2e_x3d_x3d(V a,V b);
V fpr_fn__x24arc_x2eF64eq(V a,V b) { return fpr_prim_fn_F64_x2e_x3d_x3d(a,b); }
extern V fpr_prim_fn_F64_x2e_x21_x3d(V a,V b);
V fpr_fn__x24arc_x2eF64ne(V a,V b) { return fpr_prim_fn_F64_x2e_x21_x3d(a,b); }
extern V fpr_prim_fn_F64_x2esqrt(V a);
V fpr_fn__x24arc_x2eF64sqrt(V a) { return fpr_prim_fn_F64_x2esqrt(a); }
extern V fpr_prim_fn_F64_x2eofInt(V a);
V fpr_fn__x24arc_x2eF64ofInt(V a) { return fpr_prim_fn_F64_x2eofInt(a); }
extern V fpr_prim_fn_F64_x2etoInt(V a);
V fpr_fn__x24arc_x2eF64toInt(V a) { return fpr_prim_fn_F64_x2etoInt(a); }
extern V fpr_prim_fn_F64_x2estr(V a);
V fpr_fn__x24arc_x2eF64str(V a) { return fpr_prim_fn_F64_x2estr(a); }
extern V fpr_prim_fn_F64_x2elog(V a);
V fpr_fn__x24arc_x2eF64log(V a) { return fpr_prim_fn_F64_x2elog(a); }
extern V fpr_prim_fn_F64_x2elog2(V a);
V fpr_fn__x24arc_x2eF64log2(V a) { return fpr_prim_fn_F64_x2elog2(a); }
extern V fpr_prim_fn_F64_x2eexp(V a);
V fpr_fn__x24arc_x2eF64exp(V a) { return fpr_prim_fn_F64_x2eexp(a); }
extern V fpr_prim_fn_F64_x2epow(V a,V b);
V fpr_fn__x24arc_x2eF64pow(V a,V b) { return fpr_prim_fn_F64_x2epow(a,b); }
extern V fpr_prim_fn_F64_x2esin(V a);
V fpr_fn__x24arc_x2eF64sin(V a) { return fpr_prim_fn_F64_x2esin(a); }
extern V fpr_prim_fn_F64_x2ecos(V a);
V fpr_fn__x24arc_x2eF64cos(V a) { return fpr_prim_fn_F64_x2ecos(a); }
extern V fpr_prim_fn_F32_x2e_x2b(V a,V b);
V fpr_fn__x24arc_x2eF32add(V a,V b) { return fpr_prim_fn_F32_x2e_x2b(a,b); }
extern V fpr_prim_fn_F32_x2e_x2d(V a,V b);
V fpr_fn__x24arc_x2eF32sub(V a,V b) { return fpr_prim_fn_F32_x2e_x2d(a,b); }
extern V fpr_prim_fn_F32_x2e_x2a(V a,V b);
V fpr_fn__x24arc_x2eF32mul(V a,V b) { return fpr_prim_fn_F32_x2e_x2a(a,b); }
extern V fpr_prim_fn_F32_x2e_x2f(V a,V b);
V fpr_fn__x24arc_x2eF32div(V a,V b) { return fpr_prim_fn_F32_x2e_x2f(a,b); }
extern V fpr_prim_fn_F32_x2e_x3c(V a,V b);
V fpr_fn__x24arc_x2eF32lt(V a,V b) { return fpr_prim_fn_F32_x2e_x3c(a,b); }
extern V fpr_prim_fn_F32_x2e_x3e(V a,V b);
V fpr_fn__x24arc_x2eF32gt(V a,V b) { return fpr_prim_fn_F32_x2e_x3e(a,b); }
extern V fpr_prim_fn_F32_x2e_x3c_x3d(V a,V b);
V fpr_fn__x24arc_x2eF32le(V a,V b) { return fpr_prim_fn_F32_x2e_x3c_x3d(a,b); }
extern V fpr_prim_fn_F32_x2e_x3e_x3d(V a,V b);
V fpr_fn__x24arc_x2eF32ge(V a,V b) { return fpr_prim_fn_F32_x2e_x3e_x3d(a,b); }
extern V fpr_prim_fn_F32_x2e_x3d_x3d(V a,V b);
V fpr_fn__x24arc_x2eF32eq(V a,V b) { return fpr_prim_fn_F32_x2e_x3d_x3d(a,b); }
extern V fpr_prim_fn_F32_x2e_x21_x3d(V a,V b);
V fpr_fn__x24arc_x2eF32ne(V a,V b) { return fpr_prim_fn_F32_x2e_x21_x3d(a,b); }
extern V fpr_prim_fn_F32_x2esqrt(V a);
V fpr_fn__x24arc_x2eF32sqrt(V a) { return fpr_prim_fn_F32_x2esqrt(a); }
extern V fpr_prim_fn_F32_x2eofInt(V a);
V fpr_fn__x24arc_x2eF32ofInt(V a) { return fpr_prim_fn_F32_x2eofInt(a); }
extern V fpr_prim_fn_F32_x2etoInt(V a);
V fpr_fn__x24arc_x2eF32toInt(V a) { return fpr_prim_fn_F32_x2etoInt(a); }
extern V fpr_prim_fn_F32_x2estr(V a);
V fpr_fn__x24arc_x2eF32str(V a) { return fpr_prim_fn_F32_x2estr(a); }
extern V fpr_prim_fn_F32_x2elog(V a);
V fpr_fn__x24arc_x2eF32log(V a) { return fpr_prim_fn_F32_x2elog(a); }
extern V fpr_prim_fn_F32_x2elog2(V a);
V fpr_fn__x24arc_x2eF32log2(V a) { return fpr_prim_fn_F32_x2elog2(a); }
extern V fpr_prim_fn_F32_x2eexp(V a);
V fpr_fn__x24arc_x2eF32exp(V a) { return fpr_prim_fn_F32_x2eexp(a); }
extern V fpr_prim_fn_F32_x2epow(V a,V b);
V fpr_fn__x24arc_x2eF32pow(V a,V b) { return fpr_prim_fn_F32_x2epow(a,b); }
extern V fpr_prim_fn_F32_x2esin(V a);
V fpr_fn__x24arc_x2eF32sin(V a) { return fpr_prim_fn_F32_x2esin(a); }
extern V fpr_prim_fn_F32_x2ecos(V a);
V fpr_fn__x24arc_x2eF32cos(V a) { return fpr_prim_fn_F32_x2ecos(a); }
extern V fpr_prim_fn_f64frombits(V a,V b);
V fpr_fn__x24arc_x2ef64frombits(V a,V b) { return fpr_prim_fn_f64frombits(a,b); }
extern V fpr_prim_fn_f32frombits(V a);
V fpr_fn__x24arc_x2ef32frombits(V a) { return fpr_prim_fn_f32frombits(a); }
extern V fpr_prim_fn_F64_x2eofF32(V a);
V fpr_fn__x24arc_x2eF64ofF32(V a) { return fpr_prim_fn_F64_x2eofF32(a); }
extern V fpr_prim_fn_F32_x2eofF64(V a);
V fpr_fn__x24arc_x2eF32ofF64(V a) { return fpr_prim_fn_F32_x2eofF64(a); }
#endif
