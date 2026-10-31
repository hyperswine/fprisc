/* unbox bench C references (gcc -O2). argv: mode N R.
 * "arr_*" = ideal unboxed baseline (flat int64 array or no structure);
 * "cons_*" = a boxed cons list via a bump allocator (16-byte cells, no free),
 * i.e. what a uniform-representation list costs with the cheapest allocator. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef int64_t I;
typedef struct C { I h; struct C *t; } C;
static char *heap, *hp;
static C *cons(I h, C *t) { C *c = (C *)hp; hp += sizeof(C); c->h = h; c->t = t; return c; }
static C *range(I a, I b) { C *acc = 0; for (I i = b; i >= a; i--) acc = cons(i, acc); return acc; }
static C *rev(C *x) { C *a = 0; for (; x; x = x->t) a = cons(x->h, a); return a; }
typedef struct T { struct T *l; I k; struct T *r; } T;
static T *build(int d, I k) { if (!d) return 0; T *t = (T *)hp; hp += sizeof(T); t->l = build(d-1, 2*k); t->k = k; t->r = build(d-1, 2*k+1); return t; }
static I total(T *t) { return t ? total(t->l) + t->k + total(t->r) : 0; }
int main(int argc, char **argv) {
  const char *m = argv[1]; I N = atoll(argv[2]), R = atoll(argv[3]); I acc = 0;
  heap = hp = malloc((size_t)64 << 20 << 4);
  for (I r = 0; r < R; r++) {
    char *mark = hp;
    if (!strcmp(m, "arr_sum")) { I *a = malloc(N*8); for (I i=0;i<N;i++) a[i]=i+1; for (I i=0;i<N;i++) acc+=a[i]; free(a); }
    else if (!strcmp(m, "cons_sum")) { for (C *x = range(1,N); x; x = x->t) acc += x->h; }
    else if (!strcmp(m, "cons_map")) { C *x = range(1,N), *y = 0; for (; x; x = x->t) y = cons(x->h+1, y); for (y = rev(y); y; y = y->t) acc += y->h; }
    else if (!strcmp(m, "cons_filter")) { C *x = range(1,N), *y = 0; for (; x; x = x->t) if (x->h % 2 == 0) y = cons(x->h, y); for (y = rev(y); y; y = y->t) acc += y->h; }
    else if (!strcmp(m, "cons_rev")) { static C *once; if (!once) { once = range(1,N); mark = hp; } for (C *y = rev(once); y; y = y->t) acc++; }
    else if (!strcmp(m, "cons_fold")) { static C *once; if (!once) { once = range(1,N); mark = hp; } for (C *y = once; y; y = y->t) acc += y->h * 3; }
    else if (!strcmp(m, "option")) { for (I i = N; i > 0; i--) acc += (i % 2 == 0) ? i / 2 : 1; }
    else if (!strcmp(m, "tuple")) { I a = 0, b = 1; for (I i = N; i > 0; i--) { I t = (a + b) % 1000003; a = b; b = t; } acc += a; }
    else if (!strcmp(m, "tree")) { acc += total(build((int)N, 1)); }
    else if (!strcmp(m, "scan")) { static char *s; if (!s) { s = malloc(N); for (I i=0;i<N;i++) s[i]="abcdefgh"[i%8]; } for (I i=0;i<N;i++) acc += s[i]=='a'; }
    hp = mark;
  }
  printf("%lld\n", (long long)acc); return 0;
}
