/* bits.c — bitwise primitives on Int.
 *
 * Mechanism only: each is one or two machine instructions.  Codegen inlines
 * band/bor/bxor and the shifts behind a range guard (Codegen.hs shiftOk);
 * these C bodies are what a closure, a generic call and the guard's slow
 * path reach, so the range check that makes the inline code safe is here
 * too: an index or shift outside 0..63 is a named panic, never C's
 * undefined behaviour.  The Array Bit tier (bitsLE/bitsBE/bitlen/toInt)
 * had no users and is gone.
 */
#include "fpr.h"

static uw bit_index(V i, const char *who) {
  sw k = UNTAG(i);
  if (k < 0 || k > 63) fpr_cpanic(who);
  return (uw)k;
}

static V h_bittest(V b, V i) {
  uw k = bit_index(i, "BITTEST: bit index must be 0..63");
  if (!ISINT(b)) fpr_cpanic("BITTEST: not an Int");
  return BOOL(((uw)UNTAG(b) >> k) & 1);
}
static V h_bitset(V b, V i) {
  uw k = bit_index(i, "BITSET: bit index must be 0..63");
  if (!ISINT(b)) fpr_cpanic("BITSET: not an Int");
  return TAG((sw)((uw)UNTAG(b) | ((uw)1 << k)));
}
static V h_bitclear(V b, V i) {
  uw k = bit_index(i, "BITCLEAR: bit index must be 0..63");
  if (!ISINT(b)) fpr_cpanic("BITCLEAR: not an Int");
  return TAG((sw)((uw)UNTAG(b) & ~((uw)1 << k)));
}
static V h_bitmask(V w, V o) {
  sw width = UNTAG(w), off = UNTAG(o);
  if (width < 0 || width > (sw)(sizeof(uw) * 8 - 1) || off < 0 || off > 63) fpr_cpanic("BITMASK: bad width/offset");
  return TAG((sw)(((width == (sw)(sizeof(uw) * 8 - 1) ? ~(uw)0 >> 1 : ((uw)1 << width) - 1)) << off));
}
static V h_shiftl(V v, V k) {
  uw n = bit_index(k, "BITSHIFTL: shift must be 0..63");
  return TAG((sw)((uw)UNTAG(v) << n));
}
static V h_shiftr(V v, V k) {
  uw n = bit_index(k, "BITSHIFTR: shift must be 0..63");
  return TAG((sw)((uw)UNTAG(v) >> n));
}
static V h_band(V a, V b) { return TAG(UNTAG(a) & UNTAG(b)); }
static V h_bor(V a, V b) { return TAG(UNTAG(a) | UNTAG(b)); }
static V h_bxor(V a, V b) { return TAG(UNTAG(a) ^ UNTAG(b)); }

FPR_FN(fpr_g_BITTEST, h_bittest, 2);
FPR_FN(fpr_g_BITSET, h_bitset, 2);
FPR_FN(fpr_g_BITCLEAR, h_bitclear, 2);
FPR_FN(fpr_g_BITMASK, h_bitmask, 2);
FPR_FN(fpr_g_BITSHIFTL, h_shiftl, 2);
FPR_FN(fpr_g_BITSHIFTR, h_shiftr, 2);
FPR_FN(fpr_g_band, h_band, 2);
FPR_FN(fpr_g_bor, h_bor, 2);
FPR_FN(fpr_g_bxor, h_bxor, 2);
