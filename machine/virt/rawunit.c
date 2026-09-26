/* rawunit.c -- what an FP-RISC RAW LIBRARY UNIT needs from the image it joins.
 *
 * machine/virt's PLIC and CLINT drivers are FP-RISC (plic.fpr, clint.fpr): raw
 * library units over typed layouts (docs/2026-09-19-LAYOUTS.md), compiled
 * `--arc --raw --lib` so their exports are the C symbols the runtime calls.
 * Such a unit was only ever linked into the builtin runtime, which supplies
 * two things the core image does not:
 *
 *  - the SLOW PATHS of the guarded raw primitives.  The compiler inlines
 *    `Mem.read32` as an alignment check and a load; a failed check branches to
 *    an out-of-line adapter.  Every one of them is an error -- a misaligned
 *    access, a shift of 64 or more -- so here each is that error, by name.
 *  - fpr_builtin_alloc_adt, which the constructor stubs every unit carries
 *    (Cons, Ok, Tup2, ...) refer to.  A raw unit is checked allocation-free and
 *    never calls them; if one ever did, it says so.
 */
#include "fpr.h"

#define RAW1(name, why) V fpr_fn__x24arc_x2e##name(V a) { (void)a; fpr_cpanic(why); }
#define RAW2(name, why) V fpr_fn__x24arc_x2e##name(V a, V b) { (void)a; (void)b; fpr_cpanic(why); }

RAW1(memreadWord, "raw unit: unaligned 64-bit read")
RAW1(memread32, "raw unit: unaligned 32-bit read")
RAW1(memread16, "raw unit: unaligned 16-bit read")
RAW2(memwriteWord, "raw unit: unaligned 64-bit write")
RAW2(memwrite32, "raw unit: unaligned 32-bit write")
RAW2(memwrite16, "raw unit: unaligned 16-bit write")
RAW2(wordshl, "raw unit: shift out of range")
RAW2(wordshr, "raw unit: shift out of range")
RAW2(wordbitSet, "raw unit: bit index out of range")
RAW2(wordbitClear, "raw unit: bit index out of range")
RAW2(wordbitTest, "raw unit: bit index out of range")

V fpr_builtin_alloc_adt(V bytes, uw fields) {
  (void)bytes; (void)fields;
  fpr_cpanic("raw unit: tried to allocate (it is linked without an allocator of its own)");
}
