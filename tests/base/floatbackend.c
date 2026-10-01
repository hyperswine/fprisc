/* Check actual generated raw-bits functions, independently of the runtime. */
#include <stdint.h>
#include <stdio.h>
struct boolean { uint32_t tid, var; } fpr_true = {1, 1}, fpr_false = {1, 0};
static uintptr_t fuel = 1000000;
uintptr_t *probe_hart = &fuel;
uintptr_t fpr_fuel_exhausted(void) { fuel = 1000000; return 0; }
#define DECL(n) extern uintptr_t fpr_fn_##n(uintptr_t, uintptr_t)
DECL(add); DECL(sub); DECL(mul); DECL(div);
DECL(lt); DECL(le); DECL(gt); DECL(ge); DECL(eq); DECL(ne);
static double d(uint64_t u) { union { uint64_t u; double d; } x = {u}; return x.d; }
static uint64_t bits(double v) { union { uint64_t u; double d; } x; x.d = v; return x.u; }
static int nanbits(uint64_t u) { return (u & UINT64_C(0x7ff0000000000000)) == UINT64_C(0x7ff0000000000000) && (u & UINT64_C(0xfffffffffffff)); }
static int same(uint64_t a, uint64_t b) { return a == b || (nanbits(a) && nanbits(b)); }
static int value(uintptr_t b) { return ((struct boolean *)b)->var; }
static int check(uint64_t a, uint64_t b) {
  double x = d(a), y = d(b);
  return !same(fpr_fn_add(a, b), bits(x + y))
       + !same(fpr_fn_sub(a, b), bits(x - y))
       + !same(fpr_fn_mul(a, b), bits(x * y))
       + !same(fpr_fn_div(a, b), bits(x / y))
       + (value(fpr_fn_lt(a, b)) != (x < y))
       + (value(fpr_fn_le(a, b)) != (x <= y))
       + (value(fpr_fn_gt(a, b)) != (x > y))
       + (value(fpr_fn_ge(a, b)) != (x >= y))
       + (value(fpr_fn_eq(a, b)) != (x == y))
       + (value(fpr_fn_ne(a, b)) != (x != y));
}
static uint64_t random_bits(uint64_t *s) { *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s; }
int main(void) {
  uint64_t v[] = {0, UINT64_C(0x8000000000000000), 1, UINT64_C(0x8000000000000001),
    UINT64_C(0x0010000000000000), UINT64_C(0x8010000000000000),
    UINT64_C(0x7fefffffffffffff), UINT64_C(0xffefffffffffffff),
    UINT64_C(0x3ff0000000000000), UINT64_C(0xbff0000000000000),
    UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000),
    UINT64_C(0x7ff8000000000001), UINT64_C(0xfff8000000000001),
    UINT64_C(0x7ff0000000000001), UINT64_C(0xfff0000000000001)};
  int bad = 0; unsigned pairs = 0;
  for (unsigned i = 0; i < sizeof v / sizeof *v; i++)
    for (unsigned j = 0; j < sizeof v / sizeof *v; j++) { bad += check(v[i], v[j]); pairs++; }
  uint64_t seed = UINT64_C(0x6a09e667f3bcc909);
  for (unsigned i = 0; i < 1024; i++) { uint64_t a = random_bits(&seed), b = random_bits(&seed); bad += check(a, b); pairs++; }
  printf("x64 F64: %d mismatches over %u pairs\n", bad, pairs);
  return bad != 0;
}
