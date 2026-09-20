/* sstr.c — SString: a fixed 128-byte inline string.
 *
 * Unlike str_t (heap string, variable length, ARC-managed), an SString is
 * a fixed SSTR_CAP-byte buffer with a live length. Its width is hardcoded
 * system-wide (SSTR_CAP = 128); an indexed `SString n` (per-value width,
 * bordering on dependent types) is a deliberate future step.
 *
 * It is declared `SString 1 = Type Int.` in the prelude, i.e. LINEAR, so
 * the checker enforces single ownership — the same discipline that lets a
 * Vector be mutated in place licenses SString's put/push to mutate the
 * buffer and return the same reference as the "new" value. All ops are
 * 1-indexed, matching the rest of the FPRISC string surface (charAt etc.).
 *
 * Char codes are Ints (TAG'd). fromStr/toStr bridge to heap str_t.
 */
#include "fpr.h"

static sstr_t *as_sstr(V s, const char *who) {
  if (ISINT(s) || ((sstr_t *)s)->tid != T_SSTR) fpr_cpanic(who);
  return (sstr_t *)s;
}

/* new : Unit -> SString — a fresh empty 128-byte buffer */
static V g_sstrNew(V u) {
  (void)u;
  sstr_t *s = (sstr_t *)fpr_alloc(sizeof(sstr_t));
  s->tid = T_SSTR;
  s->var = 0;
  s->len = 0;
  return (V)s;
}

/* a (value, handle) pair: linear READS thread the handle back, the
 * same convention Vec.len/Vec.get follow -- a read that consumed the
 * handle without returning a successor would be unusable under the
 * exactly-once discipline the checker now enforces for SString. */
static V sstr_pair(V a, V sv) {
  hdr_t *t = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
  t->tid = T_TUP2;
  t->var = 0;
  *(V *)((char *)t + 8) = a;
  *(V *)((char *)t + 8 + sizeof(uw)) = sv;
  return (V)t;
}

/* len : SString -> (Int, SString) */
static V g_sstrLen(V sv) {
  return sstr_pair(TAG(as_sstr(sv, "SStr.len: not an SString")->len), sv);
}

/* at : SString -> Int -> (Int, SString)   (1-indexed byte code) */
static V g_sstrAt(V sv, V iv) {
  sstr_t *s = as_sstr(sv, "SStr.at: not an SString");
  sw k = UNTAG(iv);
  if (k < 1 || (uw)k > s->len) fpr_cpanic("SStr.at: index out of range");
  return sstr_pair(TAG(s->bytes[k - 1]), sv);
}

/* put : SString -> Int -> Int -> SString   (overwrite byte i, 1-indexed) */
static V g_sstrPut(V sv, V iv, V cv) {
  sstr_t *s = as_sstr(sv, "SStr.put: not an SString");
  sw k = UNTAG(iv);
  if (k < 1 || (uw)k > SSTR_CAP) fpr_cpanic("SStr.put: index out of range");
  s->bytes[k - 1] = (uint8_t)UNTAG(cv);
  if ((uw)k > s->len) s->len = (uw)k;
  return sv; /* linear: same reference back */
}

/* push : SString -> Int -> SString   (append one byte code) */
static V g_sstrPush(V sv, V cv) {
  sstr_t *s = as_sstr(sv, "SStr.push: not an SString");
  if (s->len >= SSTR_CAP) fpr_cpanic("SStr.push: SString full (128B)");
  s->bytes[s->len] = (uint8_t)UNTAG(cv);
  s->len++;
  return sv;
}

/* fromStr : String -> SString   (copy up to 128 bytes of a heap string) */
static V g_sstrFromStr(V strv) {
  if (ISINT(strv) || ((str_t *)strv)->tid != T_STR) fpr_cpanic("SStr.fromStr: not a String");
  str_t *src = (str_t *)strv;
  uw n = src->len > SSTR_CAP ? SSTR_CAP : src->len;
  sstr_t *s = (sstr_t *)fpr_alloc(sizeof(sstr_t));
  s->tid = T_SSTR;
  s->var = 0;
  s->len = n;
  for (uw i = 0; i < n; i++) s->bytes[i] = src->bytes[i];
  return (V)s;
}

/* toStr : SString -> (String, SString)   (heap copy of the live bytes) */
static V g_sstrToStr(V sv) {
  sstr_t *s = as_sstr(sv, "SStr.toStr: not an SString");
  return sstr_pair((V)fpr_mkstr(s->bytes, s->len), sv);
}

/* clear : SString -> SString   (reset length to 0; keep the buffer) */
static V g_sstrClear(V sv) {
  sstr_t *s = as_sstr(sv, "SStr.clear: not an SString");
  s->len = 0;
  return sv;
}

FPR_FN(fpr_g_sstrNew, g_sstrNew, 1);
FPR_FN(fpr_g_sstrLen, g_sstrLen, 1);
FPR_FN(fpr_g_sstrAt, g_sstrAt, 2);
FPR_FN(fpr_g_sstrPut, g_sstrPut, 3);
FPR_FN(fpr_g_sstrPush, g_sstrPush, 2);
FPR_FN(fpr_g_sstrFromStr, g_sstrFromStr, 1);
FPR_FN(fpr_g_sstrToStr, g_sstrToStr, 1);
FPR_FN(fpr_g_sstrClear, g_sstrClear, 1);
