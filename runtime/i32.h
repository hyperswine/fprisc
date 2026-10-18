#ifndef FPR_I32_H
#define FPR_I32_H
#include "fpr.h"

/* A tagged, sign-extended int32 on 64-bit machines; an opaque numeric leaf
 * on RV32. This preserves all 32 bits, even outside the tagged Int range. */
static inline V fpr_i32_pack(uint32_t bits) {
#if UINTPTR_MAX > 0xFFFFFFFFu
  return TAG((sw)(int32_t)bits);
#else
  bits_t *p = (bits_t *)fpr_alloc(sizeof(bits_t));
  *p = (bits_t){T_BITS, 7, 32, (uw)bits};
  return (V)p;
#endif
}

static inline uint32_t fpr_i32_bits(V value) {
#if UINTPTR_MAX > 0xFFFFFFFFu
  if (!ISINT(value)) fpr_cpanic("I32: invalid tagged value");
  return (uint32_t)UNTAG(value);
#else
  if (!value || ISINT(value) || TID(value) != T_BITS || ((hdr_t *)value)->var != 7)
    fpr_cpanic("I32: invalid boxed value");
  return (uint32_t)((bits_t *)value)->val;
#endif
}
#endif
