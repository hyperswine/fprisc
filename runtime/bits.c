/* bits.c — the Array Bit tier: constructors and bit ops.
 *
 * Pure value manipulation with NO machine dependence -- it only lived
 * in the virt HAL because that is where it was born.  Moved to core
 * when the posix HAL needed BITTEST for programs that poll device
 * status registers (the ops work on plain Ints too).
 */
#include "fpr.h"

static V mkbits(uint32_t endian, uw len, uw val) {
  if (len == 0 || len > 64) fpr_cpanic("bits: length must be 1..64");
  bits_t *b = (bits_t *)fpr_alloc(sizeof(bits_t));
  b->tid = T_BITS;
  b->var = endian;
  b->len = len;
  b->val = (len >= (sw)(sizeof(uw) * 8)) ? val : (val & (((uw)1 << len) - 1));
  return (V)b;
}
static V h_bitsLE(V l, V v) { return mkbits(0, (uw)UNTAG(l), (uw)UNTAG(v)); }
static V h_bitsBE(V l, V v) { return mkbits(1, (uw)UNTAG(l), (uw)UNTAG(v)); }
static V h_toInt(V b) {
  if (ISINT(b)) return b;
  if (TID(b) != T_BITS) fpr_cpanic("toInt: not Array Bit");
  return TAG(((bits_t *)b)->val);
}
static V h_bitlen(V b) {
  if (ISINT(b) || TID(b) != T_BITS) fpr_cpanic("bitlen: not Array Bit");
  return TAG(((bits_t *)b)->len);
}

static uw bitpos(bits_t *b, sw i) {
  if (i < 0 || (uw)i >= b->len) fpr_cpanic("bit index out of range");
  return b->var ? (b->len - 1 - (uw)i) : (uw)i;
}

static V h_bittest(V b, V i) {
  sw k = UNTAG(i);
  if (ISINT(b)) return BOOL((UNTAG(b) >> k) & 1);
  if (TID(b) != T_BITS) fpr_cpanic("BITTEST: not Int/Array Bit");
  bits_t *t = (bits_t *)b;
  return BOOL((t->val >> bitpos(t, k)) & 1);
}
static V h_bitset(V b, V i) {
  sw k = UNTAG(i);
  if (ISINT(b)) return TAG(UNTAG(b) | (1L << k));
  if (TID(b) != T_BITS) fpr_cpanic("BITSET: not Int/Array Bit");
  bits_t *t = (bits_t *)b;
  return mkbits(t->var, t->len, t->val | ((uw)1 << bitpos(t, k)));
}
static V h_bitclear(V b, V i) {
  sw k = UNTAG(i);
  if (ISINT(b)) return TAG(UNTAG(b) & ~(1L << k));
  if (TID(b) != T_BITS) fpr_cpanic("BITCLEAR: not Int/Array Bit");
  bits_t *t = (bits_t *)b;
  return mkbits(t->var, t->len, t->val & ~((uw)1 << bitpos(t, k)));
}
static V h_bitmask(V w, V o) {
  sw width = UNTAG(w), off = UNTAG(o);
  if (width < 0 || width > (sw)(sizeof(uw) * 8 - 1) || off < 0) fpr_cpanic("BITMASK: bad width/offset");
  return TAG(((width == (sw)(sizeof(uw) * 8 - 1) ? ~(uw)0 >> 1 : ((uw)1 << width) - 1)) << off);
}
static V h_shiftl(V v, V k) { return TAG(UNTAG(v) << UNTAG(k)); }
static V h_shiftr(V v, V k) { return TAG((uw)UNTAG(v) >> UNTAG(k)); }
static V h_band(V a, V b) { return TAG(UNTAG(a) & UNTAG(b)); }
static V h_bor(V a, V b) { return TAG(UNTAG(a) | UNTAG(b)); }
static V h_bxor(V a, V b) { return TAG(UNTAG(a) ^ UNTAG(b)); }


FPR_FN(fpr_g_bitsLE, h_bitsLE, 2);
FPR_FN(fpr_g_bitsBE, h_bitsBE, 2);
FPR_FN(fpr_g_toInt, h_toInt, 1);
FPR_FN(fpr_g_bitlen, h_bitlen, 1);
FPR_FN(fpr_g_BITTEST, h_bittest, 2);
FPR_FN(fpr_g_BITSET, h_bitset, 2);
FPR_FN(fpr_g_BITCLEAR, h_bitclear, 2);
FPR_FN(fpr_g_BITMASK, h_bitmask, 2);
FPR_FN(fpr_g_BITSHIFTL, h_shiftl, 2);
FPR_FN(fpr_g_BITSHIFTR, h_shiftr, 2);
FPR_FN(fpr_g_band, h_band, 2);
FPR_FN(fpr_g_bor, h_bor, 2);
FPR_FN(fpr_g_bxor, h_bxor, 2);
