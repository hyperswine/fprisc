/* Private runtime-value helpers shared by the hosted OS facilities.
 * No host syscalls or device state live here; implementations can be linked
 * separately when a host provides only part of the Os.* surface.
 */
#ifndef FPR_POSIX_OS_VALUE_H
#define FPR_POSIX_OS_VALUE_H
#include "fpr.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static const hdr_t os_nil = {T_LIST, 0};

static inline V os_str(const char *s, uw n) { return (V)fpr_mkstr((const uint8_t *)s, n); }
static inline V os_cell(uint32_t tid, uint32_t var, int n, const V *f) {
  V c = fpr_alloc((V)(8 + (uw)n * sizeof(uw)));
  ((hdr_t *)c)->tid = tid;
  ((hdr_t *)c)->var = var;
  for (int i = 0; i < n; i++) ((V *)((char *)c + 8))[i] = f[i];
  return c;
}
static inline V os_ok(V v) { return os_cell(T_RESULT, 0, 1, &v); }
static inline V os_err(const char *what) { V m = os_str(what, (uw)strlen(what)); return os_cell(T_RESULT, 1, 1, &m); }
static inline V os_errno(void) { return os_err(strerror(errno)); }
static inline V os_cons(V h, V t) { V f[2] = {h, t}; return os_cell(T_LIST, 1, 2, f); }

/* a NUL-terminated copy, as long as the String is (the caller frees) */
static inline char *os_cstr(V v, const char *who) {
  if (ISINT(v) || TID(v) != T_STR) fpr_cpanic(who);
  const str_t *s = (const str_t *)v;
  char *c = malloc(s->len + 1);
  if (!c) fpr_cpanic("out of memory");
  memcpy(c, s->bytes, s->len);
  c[s->len] = 0;
  return c;
}

/* bytes that grow */
typedef struct { char *p; size_t n, cap; } buf_t;
static inline int buf_room(buf_t *b, size_t more) {
  if (b->n + more <= b->cap) return 1;
  size_t cap = b->cap ? b->cap : 4096;
  while (cap < b->n + more) cap *= 2;
  char *q = realloc(b->p, cap);
  if (!q) return 0;
  b->p = q; b->cap = cap;
  return 1;
}

static inline V os_again_or_errno(void) { return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS) ? os_err("again") : os_errno(); }
static inline int want_fd(V v, const char *who) { if (!ISINT(v)) fpr_cpanic(who); return (int)UNTAG(v); }

static inline V os_unit_or_errno(int r) { return r ? os_errno() : os_ok((V)&fpr_unit); }
#endif
