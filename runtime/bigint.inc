/* bigint.inc — exact arbitrary-precision Int arithmetic (T_BIGINT).
 *
 * Included directly by runtime/runtime.c so every link profile gets exact
 * Int promotion without link-graph changes.
 *
 * Invariant (normalization):
 *   - Every integer in [INT_MIN_TAGGED, INT_MAX_TAGGED] is represented as a
 *     tagged immediate TAG((sw)n), NEVER as a T_BIGINT.
 *   - Every T_BIGINT has len >= 1, limbs[len - 1] != 0 (little-endian base
 *     2^64 magnitude), var == 0 (positive) or var == 1 (negative), and value
 *     strictly outside [INT_MIN_TAGGED, INT_MAX_TAGGED].
 */

#define BI_STACK_LIMBS 16u

static inline uint64_t bi_min_tagged_mag(void) {
  return (uint64_t)1 << (sizeof(sw) * 8 - 2);
}

static inline uint64_t bi_max_tagged_mag(void) {
  return ((uint64_t)1 << (sizeof(sw) * 8 - 2)) - 1u;
}

static V bi_from_mag(int neg, const uint64_t *limbs, uw len) {
  while (len > 0 && limbs[len - 1] == 0) len--;
  if (len == 0) return TAG(0);
  if (len == 1) {
    uint64_t m = limbs[0];
    if (!neg && m <= bi_max_tagged_mag()) return TAG((sw)m);
    if (neg && m <= bi_min_tagged_mag()) return TAG((sw)((uw)0 - (uw)m));
  }
  if (len > (~(uw)0 - sizeof(bigint_t)) / sizeof(uint64_t))
    fpr_trap("Int: bignum size overflow");
  bigint_t *b = (bigint_t *)fpr_alloc(sizeof(bigint_t) + len * sizeof(uint64_t));
  b->tid = T_BIGINT;
  b->var = (uint32_t)(neg ? 1 : 0);
  b->len = len;
  for (uw i = 0; i < len; i++) b->limbs[i] = limbs[i];
  return (V)b;
}

static V bi_from_i64(int64_t x) {
  if (x == 0) return TAG(0);
  if (x > 0) {
    uint64_t m = (uint64_t)x;
    return bi_from_mag(0, &m, 1);
  }
  uint64_t m = (uint64_t)0 - (uint64_t)x;
  return bi_from_mag(1, &m, 1);
}

static V bi_from_u64(uint64_t x) {
  if (x == 0) return TAG(0);
  return bi_from_mag(0, &x, 1);
}

static inline void bi_view(V v, int *neg, const uint64_t **limbs, uw *len, uint64_t *tmp) {
  if (ISINT(v)) {
    sw n = UNTAG(v);
    if (n == 0) {
      *neg = 0; *limbs = tmp; *len = 0;
    } else if (n < 0) {
      *neg = 1;
      tmp[0] = (uint64_t)0 - (uint64_t)(int64_t)n;
      *limbs = tmp; *len = 1;
    } else {
      *neg = 0;
      tmp[0] = (uint64_t)n;
      *limbs = tmp; *len = 1;
    }
    return;
  }
  if (!v || TID(v) != T_BIGINT) fpr_cpanic("Int: expected Int or BigInt");
  const bigint_t *b = (const bigint_t *)v;
  *neg = b->var != 0;
  *limbs = b->limbs;
  *len = b->len;
}

static int bi_cmp_mag(const uint64_t *a, uw an, const uint64_t *b, uw bn) {
  if (an != bn) return an < bn ? -1 : 1;
  for (uw i = an; i-- > 0;) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

static int bi_cmp(V av, V bv) {
  if (ISINT(av) && ISINT(bv)) {
    sw x = UNTAG(av), y = UNTAG(bv);
    return (x > y) - (x < y);
  }
  int aneg, bneg;
  const uint64_t *a, *b;
  uw an, bn;
  uint64_t atmp, btmp;
  bi_view(av, &aneg, &a, &an, &atmp);
  bi_view(bv, &bneg, &b, &bn, &btmp);
  if (an == 0 && bn == 0) return 0;
  if (aneg != bneg) return aneg ? -1 : 1;
  int c = bi_cmp_mag(a, an, b, bn);
  return aneg ? -c : c;
}

static uw bi_add_mag(uint64_t *dst, const uint64_t *a, uw an, const uint64_t *b, uw bn) {
  uw n = an > bn ? an : bn;
  uint64_t carry = 0;
  for (uw i = 0; i < n; i++) {
    uint64_t x = i < an ? a[i] : 0;
    uint64_t y = i < bn ? b[i] : 0;
    uint64_t s1 = x + y;
    uint64_t c1 = s1 < x ? 1u : 0u;
    uint64_t s2 = s1 + carry;
    uint64_t c2 = s2 < s1 ? 1u : 0u;
    dst[i] = s2;
    carry = c1 + c2;
  }
  if (carry) dst[n++] = carry;
  return n;
}

/* Requires a >= b in magnitude. */
static uw bi_sub_mag(uint64_t *dst, const uint64_t *a, uw an, const uint64_t *b, uw bn) {
  uint64_t borrow = 0;
  for (uw i = 0; i < an; i++) {
    uint64_t x = a[i];
    uint64_t y = i < bn ? b[i] : 0;
    uint64_t d1 = x - y;
    uint64_t b1 = x < y ? 1u : 0u;
    uint64_t d2 = d1 - borrow;
    uint64_t b2 = d1 < borrow ? 1u : 0u;
    dst[i] = d2;
    borrow = b1 + b2;
  }
  while (an > 0 && dst[an - 1] == 0) an--;
  return an;
}

static inline void bi_mul64(uint64_t a, uint64_t b, uint64_t *hi, uint64_t *lo) {
#if defined(__SIZEOF_INT128__)
  unsigned __int128 p = (unsigned __int128)a * (unsigned __int128)b;
  *lo = (uint64_t)p;
  *hi = (uint64_t)(p >> 64);
#else
  uint64_t a0 = (uint32_t)a, a1 = a >> 32;
  uint64_t b0 = (uint32_t)b, b1 = b >> 32;
  uint64_t p00 = a0 * b0;
  uint64_t p01 = a0 * b1;
  uint64_t p10 = a1 * b0;
  uint64_t p11 = a1 * b1;
  uint64_t mid = (p00 >> 32) + (uint32_t)p01 + (uint32_t)p10;
  *lo = (p00 & 0xFFFFFFFFULL) | (mid << 32);
  *hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
#endif
}

static uw bi_mul_mag(uint64_t *dst, const uint64_t *a, uw an, const uint64_t *b, uw bn) {
  uw rn = an + bn;
  for (uw i = 0; i < rn; i++) dst[i] = 0;
  for (uw i = 0; i < an; i++) {
    uint64_t carry = 0;
    uint64_t ai = a[i];
    for (uw j = 0; j < bn; j++) {
      uint64_t hi, lo;
      bi_mul64(ai, b[j], &hi, &lo);
      uint64_t s1 = dst[i + j] + lo;
      uint64_t c1 = s1 < lo ? 1u : 0u;
      uint64_t s2 = s1 + carry;
      uint64_t c2 = s2 < s1 ? 1u : 0u;
      dst[i + j] = s2;
      carry = hi + c1 + c2;
    }
    dst[i + bn] += carry;
  }
  while (rn > 0 && dst[rn - 1] == 0) rn--;
  return rn;
}

static V bi_add_sub(V av, V bv, int sub_b) {
  int aneg, bneg;
  const uint64_t *a, *b;
  uw an, bn;
  uint64_t atmp, btmp;
  bi_view(av, &aneg, &a, &an, &atmp);
  bi_view(bv, &bneg, &b, &bn, &btmp);
  if (sub_b && bn > 0) bneg = !bneg;
  if (an == 0) return bi_from_mag(bneg, b, bn);
  if (bn == 0) return bi_from_mag(aneg, a, an);
  uw maxn = (an > bn ? an : bn) + 1u;
  uint64_t stack[BI_STACK_LIMBS];
  uint64_t *buf = maxn <= BI_STACK_LIMBS ? stack : (uint64_t *)fpr_alloc_raw((V)(maxn * sizeof(uint64_t)));
  int rneg;
  uw rn;
  if (aneg == bneg) {
    rneg = aneg;
    rn = bi_add_mag(buf, a, an, b, bn);
  } else {
    int c = bi_cmp_mag(a, an, b, bn);
    if (c == 0) {
      if (buf != stack) fpr_free_raw((V)buf);
      return TAG(0);
    } else if (c > 0) {
      rneg = aneg;
      rn = bi_sub_mag(buf, a, an, b, bn);
    } else {
      rneg = bneg;
      rn = bi_sub_mag(buf, b, bn, a, an);
    }
  }
  V res = bi_from_mag(rneg, buf, rn);
  if (buf != stack) fpr_free_raw((V)buf);
  return res;
}

static V bi_add(V a, V b) { return bi_add_sub(a, b, 0); }
static V bi_sub(V a, V b) { return bi_add_sub(a, b, 1); }

static V bi_mul(V av, V bv) {
  int aneg, bneg;
  const uint64_t *a, *b;
  uw an, bn;
  uint64_t atmp, btmp;
  bi_view(av, &aneg, &a, &an, &atmp);
  bi_view(bv, &bneg, &b, &bn, &btmp);
  if (an == 0 || bn == 0) return TAG(0);
  if (an > (~(uw)0 - bn)) fpr_trap("Int: multiplication size overflow");
  uw maxn = an + bn;
  uint64_t stack[BI_STACK_LIMBS];
  uint64_t *buf = maxn <= BI_STACK_LIMBS ? stack : (uint64_t *)fpr_alloc_raw((V)(maxn * sizeof(uint64_t)));
  uw rn = bi_mul_mag(buf, a, an, b, bn);
  V res = bi_from_mag(aneg ^ bneg, buf, rn);
  if (buf != stack) fpr_free_raw((V)buf);
  return res;
}

static unsigned bi_clz32(uint32_t x) {
  unsigned n = 0;
  if (!x) return 32;
  while (!(x & 0x80000000u)) { x <<= 1; n++; }
  return n;
}

/* Single 32-bit divisor over base-2^32 limbs: returns remainder. */
static uint32_t bi_divmod_u32(uint32_t *q, const uint32_t *u, uw un, uint32_t d) {
  uint64_t rem = 0;
  for (uw i = un; i-- > 0;) {
    uint64_t cur = (rem << 32) | (uint64_t)u[i];
    q[i] = (uint32_t)(cur / d);
    rem = cur % d;
  }
  return (uint32_t)rem;
}

/* Portable Knuth Algorithm D in base 2^32: computes q = floor(|a| / |b|) and
 * returns nonzero iff remainder != 0. Works identically on 32-bit and 64-bit. */
static int bi_divmod_mag(uint64_t *qout, uw *qnout,
                         const uint64_t *a, uw an,
                         const uint64_t *b, uw bn) {
  int cmp = bi_cmp_mag(a, an, b, bn);
  if (cmp < 0) {
    *qnout = 0;
    return an > 0;
  }
  if (cmp == 0) {
    qout[0] = 1;
    *qnout = 1;
    return 0;
  }
#if defined(__SIZEOF_INT128__)
  if (bn == 1) {
    uint64_t d = b[0];
    uint64_t rem = 0;
    for (uw i = an; i-- > 0;) {
      unsigned __int128 cur = ((unsigned __int128)rem << 64) | (unsigned __int128)a[i];
      qout[i] = (uint64_t)(cur / d);
      rem = (uint64_t)(cur % d);
    }
    uw qn = an;
    while (qn > 0 && qout[qn - 1] == 0) qn--;
    *qnout = qn;
    return rem != 0;
  }
#endif
  /* Unpack 64-bit limbs to base-2^32 limbs. */
  uw un = an * 2u;
  uw vn = bn * 2u;
  uint32_t ustack[BI_STACK_LIMBS * 2u + 2u];
  uint32_t vstack[BI_STACK_LIMBS * 2u];
  uint32_t qstack[BI_STACK_LIMBS * 2u + 2u];
  uint32_t *u = (un + 1u) <= (BI_STACK_LIMBS * 2u + 2u)
                  ? ustack : (uint32_t *)fpr_alloc_raw((V)((un + 1u) * sizeof(uint32_t)));
  uint32_t *v = vn <= (BI_STACK_LIMBS * 2u)
                  ? vstack : (uint32_t *)fpr_alloc_raw((V)(vn * sizeof(uint32_t)));
  uint32_t *q32 = (un + 1u) <= (BI_STACK_LIMBS * 2u + 2u)
                  ? qstack : (uint32_t *)fpr_alloc_raw((V)((un + 1u) * sizeof(uint32_t)));
  for (uw i = 0; i < an; i++) {
    u[2u * i] = (uint32_t)a[i];
    u[2u * i + 1u] = (uint32_t)(a[i] >> 32);
  }
  while (un > 0 && u[un - 1] == 0) un--;
  for (uw i = 0; i < bn; i++) {
    v[2u * i] = (uint32_t)b[i];
    v[2u * i + 1u] = (uint32_t)(b[i] >> 32);
  }
  while (vn > 0 && v[vn - 1] == 0) vn--;

  int rem_nonzero = 0;
  uw q32n = 0;
  if (vn == 1) {
    uint32_t rem = bi_divmod_u32(q32, u, un, v[0]);
    q32n = un;
    rem_nonzero = rem != 0;
  } else {
    unsigned s = bi_clz32(v[vn - 1]);
    if (s > 0) {
      for (uw i = vn - 1; i > 0; i--) v[i] = (v[i] << s) | (v[i - 1] >> (32 - s));
      v[0] <<= s;
      u[un] = u[un - 1] >> (32 - s);
      for (uw i = un - 1; i > 0; i--) u[i] = (u[i] << s) | (u[i - 1] >> (32 - s));
      u[0] <<= s;
    } else {
      u[un] = 0;
    }
    uw m = un - vn;
    q32n = m + 1u;
    const uint64_t base = (uint64_t)1 << 32;
    for (uw jj = m + 1u; jj-- > 0;) {
      uw j = jj;
      uint64_t num = ((uint64_t)u[j + vn] << 32) | (uint64_t)u[j + vn - 1];
      uint64_t qhat = num / (uint64_t)v[vn - 1];
      uint64_t rhat = num % (uint64_t)v[vn - 1];
      while (qhat >= base || qhat * (uint64_t)v[vn - 2] > (rhat << 32) + (uint64_t)u[j + vn - 2]) {
        qhat--;
        rhat += (uint64_t)v[vn - 1];
        if (rhat >= base) break;
      }
      int64_t borrow = 0;
      for (uw i = 0; i < vn; i++) {
        uint64_t p = qhat * (uint64_t)v[i];
        int64_t t = (int64_t)(uint64_t)u[j + i] - (int64_t)(uint32_t)p - borrow;
        u[j + i] = (uint32_t)t;
        borrow = (int64_t)(p >> 32) - (t >> 32);
      }
      int64_t t = (int64_t)(uint64_t)u[j + vn] - borrow;
      u[j + vn] = (uint32_t)t;
      if (t < 0) {
        qhat--;
        uint64_t carry = 0;
        for (uw i = 0; i < vn; i++) {
          uint64_t sum = (uint64_t)u[j + i] + (uint64_t)v[i] + carry;
          u[j + i] = (uint32_t)sum;
          carry = sum >> 32;
        }
        u[j + vn] = (uint32_t)((uint64_t)u[j + vn] + carry);
      }
      q32[j] = (uint32_t)qhat;
    }
    for (uw i = 0; i < vn; i++) {
      if (u[i] != 0) { rem_nonzero = 1; break; }
    }
  }
  while (q32n > 0 && q32[q32n - 1] == 0) q32n--;
  uw qn = (q32n + 1u) / 2u;
  for (uw i = 0; i < qn; i++) {
    uint64_t lo = (uint64_t)q32[2u * i];
    uint64_t hi = (2u * i + 1u < q32n) ? (uint64_t)q32[2u * i + 1u] : 0;
    qout[i] = lo | (hi << 32);
  }
  while (qn > 0 && qout[qn - 1] == 0) qn--;
  *qnout = qn;
  if (u != ustack) fpr_free_raw((V)u);
  if (v != vstack) fpr_free_raw((V)v);
  if (q32 != qstack) fpr_free_raw((V)q32);
  return rem_nonzero;
}

static V bi_div_floor(V av, V bv) {
  int aneg, bneg;
  const uint64_t *a, *b;
  uw an, bn;
  uint64_t atmp, btmp;
  bi_view(av, &aneg, &a, &an, &atmp);
  bi_view(bv, &bneg, &b, &bn, &btmp);
  if (bn == 0) fpr_trap("division by zero");
  if (an == 0) return TAG(0);
  uw maxq = an + 1u;
  uint64_t stack[BI_STACK_LIMBS];
  uint64_t *q = maxq <= BI_STACK_LIMBS ? stack : (uint64_t *)fpr_alloc_raw((V)(maxq * sizeof(uint64_t)));
  uw qn = 0;
  int rem_nonzero = bi_divmod_mag(q, &qn, a, an, b, bn);
  int qneg = aneg ^ bneg;
  if (qneg && rem_nonzero) {
    uint64_t one = 1u;
    qn = bi_add_mag(q, q, qn, &one, 1);
  }
  V res = bi_from_mag(qneg, q, qn);
  if (q != stack) fpr_free_raw((V)q);
  return res;
}

/* Convert a T_BIGINT to a decimal String (unbounded length; never uses rbuf). */
static str_t *bi_to_str(const bigint_t *b) {
  uw n = b->len;
  uint64_t stack_work[BI_STACK_LIMBS];
  uint64_t *work = n <= BI_STACK_LIMBS ? stack_work : (uint64_t *)fpr_alloc_raw((V)(n * sizeof(uint64_t)));
  for (uw i = 0; i < n; i++) work[i] = b->limbs[i];
  /* Each 64-bit limb produces at most 20 decimal digits, i.e. <= 3 chunks of 9 digits. */
  uw max_chunks = n * 3u + 1u;
  uint32_t stack_chunks[BI_STACK_LIMBS * 3u + 1u];
  uint32_t *chunks = max_chunks <= (BI_STACK_LIMBS * 3u + 1u)
                       ? stack_chunks : (uint32_t *)fpr_alloc_raw((V)(max_chunks * sizeof(uint32_t)));
  uw nc = 0;
  while (n > 0) {
    uint64_t rem = 0;
    for (uw i = n; i-- > 0;) {
      uint64_t w = work[i];
      uint64_t hi_in = (rem << 32) | (w >> 32);
      uint64_t qhi = hi_in / 1000000000ULL;
      rem = hi_in % 1000000000ULL;
      uint64_t lo_in = (rem << 32) | (w & 0xFFFFFFFFULL);
      uint64_t qlo = lo_in / 1000000000ULL;
      rem = lo_in % 1000000000ULL;
      work[i] = (qhi << 32) | qlo;
    }
    chunks[nc++] = (uint32_t)rem;
    while (n > 0 && work[n - 1] == 0) n--;
  }
  if (work != stack_work) fpr_free_raw((V)work);
  /* Measure exact output length. */
  uint32_t top = nc ? chunks[nc - 1] : 0;
  uw top_digits = 1;
  for (uint32_t t = top; t >= 10u; t /= 10u) top_digits++;
  uw total = (b->var ? 1u : 0u) + top_digits + (nc > 1 ? (nc - 1u) * 9u : 0u);
  str_t *s = (str_t *)fpr_alloc(sizeof(str_t) + total);
  s->tid = T_STR;
  s->var = 0;
  s->len = total;
  uw pos = 0;
  if (b->var) s->bytes[pos++] = '-';
  /* Write top chunk. */
  {
    char d[12];
    uw k = 0;
    uint32_t t = top;
    do { d[k++] = (char)('0' + (t % 10u)); t /= 10u; } while (t);
    while (k) s->bytes[pos++] = (uint8_t)d[--k];
  }
  /* Write remaining 9-digit chunks. */
  for (uw ci = nc > 1 ? nc - 1u : 0u; ci-- > 0;) {
    uint32_t c = chunks[ci];
    for (uw k = 9; k-- > 0;) {
      s->bytes[pos + k] = (uint8_t)('0' + (c % 10u));
      c /= 10u;
    }
    pos += 9u;
  }
  if (chunks != stack_chunks) fpr_free_raw((V)chunks);
  return s;
}

static double bi_to_double(V v) {
  if (ISINT(v)) return (double)UNTAG(v);
  if (!v || TID(v) != T_BIGINT) fpr_cpanic("F64.ofInt: not an Int");
  const bigint_t *b = (const bigint_t *)v;
  double d = 0.0;
  for (uw i = b->len; i-- > 0;) d = d * 18446744073709551616.0 + (double)b->limbs[i];
  return b->var ? -d : d;
}

static float bi_to_float(V v) {
  return (float)bi_to_double(v);
}

static int bi_to_i64_checked(V v, int64_t *out) {
  if (ISINT(v)) { *out = (int64_t)UNTAG(v); return 1; }
  if (!v || TID(v) != T_BIGINT) return 0;
  const bigint_t *b = (const bigint_t *)v;
  if (b->len != 1) return 0;
  uint64_t m = b->limbs[0];
  if (!b->var) {
    if (m > 0x7FFFFFFFFFFFFFFFULL) return 0;
    *out = (int64_t)m;
    return 1;
  }
  if (m > 0x8000000000000000ULL) return 0;
  *out = (int64_t)(0ULL - m);
  return 1;
}

static int bi_to_u64_checked(V v, uint64_t *out) {
  if (ISINT(v)) {
    sw n = UNTAG(v);
    if (n < 0) return 0;
    *out = (uint64_t)n;
    return 1;
  }
  if (!v || TID(v) != T_BIGINT) return 0;
  const bigint_t *b = (const bigint_t *)v;
  if (b->var || b->len != 1) return 0;
  *out = b->limbs[0];
  return 1;
}

static uint64_t bi_trunc_u64(V v) {
  if (ISINT(v)) return (uint64_t)(int64_t)UNTAG(v);
  if (!v || TID(v) != T_BIGINT) fpr_cpanic("I64.trunc: not an Int");
  const bigint_t *b = (const bigint_t *)v;
  uint64_t lo = b->limbs[0];
  return b->var ? (0ULL - lo) : lo;
}
