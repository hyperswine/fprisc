/* base.c (posix) -- the Base profile's environment: the minimal console,
 * process and file interfaces a standalone program needs, over libc.
 *
 *   Sys.args     : Unit -> List String              argv[1..]
 *   Sys.exit     : Int -> a                         exit status (0..255)
 *   Sys.env      : String -> Result String String   Err "unset"
 *   Sys.readLine : Unit -> Result String String     one stdin line, no newline; Err "eof"
 *   Sys.stderr   : String -> Unit                   bytes to stderr, as given
 *   Sys.timeUs   : Unit -> Int                      monotonic microseconds
 *   (the file builtins -- fileRead, fileWrite, fileAppend, fileExists -- are
 *   base_file.c: a board with a filesystem and no process links that alone)
 *
 * Types are declared in compiler/Infer.hs (builtinEnv); the names are
 * the fpr_g_ contract every profile's HAL may or may not grant.  Every
 * value crossing here is checked by tag and panics by name on misuse. */
#include "fpr.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern int fpr_posix_argc;
extern char **fpr_posix_argv;

static const hdr_t base_nil = {T_LIST, 0};

static V cons(V h, V t) {
  V c = fpr_alloc((V)(8 + 2 * sizeof(uw)));
  ((hdr_t *)c)->tid = T_LIST;
  ((hdr_t *)c)->var = 1;
  *(V *)((char *)c + 8) = h;
  *(V *)((char *)c + 8 + sizeof(uw)) = t;
  return c;
}

static V mkstr(const char *s, uw n) { return (V)fpr_mkstr((const uint8_t *)s, n); }

static const str_t *want_str(V v, const char *who) {
  if (ISINT(v) || TID(v) != T_STR) {
    char msg[96];
    snprintf(msg, sizeof msg, "%s: expected a String", who);
    fpr_cpanic(msg);
  }
  return (const str_t *)v;
}

/* a NUL-terminated copy of a path (bounded) */
static void cpath(V v, const char *who, char *out, size_t cap) {
  const str_t *s = want_str(v, who);
  if (s->len >= cap) fpr_cpanic("path too long");
  memcpy(out, s->bytes, s->len);
  out[s->len] = 0;
}

static V h_args(V u) {
  (void)u;
  V l = (V)&base_nil;
  for (int i = fpr_posix_argc - 1; i >= 1; i--)
    l = cons(mkstr(fpr_posix_argv[i], (uw)strlen(fpr_posix_argv[i])), l);
  return l;
}
FPR_FN(fpr_g_Sys_x2eargs, h_args, 1);

static V h_exit(V code) {
  if (!ISINT(code)) fpr_cpanic("Sys.exit: expected an Int");
  hal_poweroff((int)(UNTAG(code) & 255));
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Sys_x2eexit, h_exit, 1);

static V h_env(V name) {
  char key[256];
  cpath(name, "Sys.env", key, sizeof key);
  const char *v = getenv(key);
  if (!v) return fpr_mkresult(1, "unset");
  return fpr_mkresultn(0, v, (uw)strlen(v));
}
FPR_FN(fpr_g_Sys_x2eenv, h_env, 1);

static V h_read_line(V u) {
  (void)u;
  size_t cap = 256, n = 0;
  char *buf = malloc(cap);
  if (!buf) fpr_cpanic("Sys.readLine: out of memory");
  int c;
  while ((c = getchar()) != EOF && c != '\n') {
    if (n + 1 >= cap) {
      cap *= 2;
      char *nb = realloc(buf, cap);
      if (!nb) fpr_cpanic("Sys.readLine: out of memory");
      buf = nb;
    }
    buf[n++] = (char)c;
  }
  if (c == EOF && n == 0) { free(buf); return fpr_mkresult(1, "eof"); }
  V r = fpr_mkresultn(0, buf, (uw)n);
  free(buf);
  return r;
}
FPR_FN(fpr_g_Sys_x2ereadLine, h_read_line, 1);

static V h_stderr(V s) {
  const str_t *t = want_str(s, "Sys.stderr");
  fflush(stdout);
  fwrite(t->bytes, 1, t->len, stderr);
  fflush(stderr);
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Sys_x2estderr, h_stderr, 1);

/* monotonic microseconds.  A 64-bit word holds centuries of them; a 32-bit
 * one (rv32: ESP-IDF) holds a 31-bit Int, so there the count is modulo 2^30
 * (about 18 minutes): right for intervals, which is what it is for */
static V h_time_us(V u) {
  (void)u;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  uint64_t us = (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
#if UINTPTR_MAX > 0xffffffffu
  return TAG((sw)us);
#else
  return TAG((sw)(us & 0x3fffffffu));
#endif
}
FPR_FN(fpr_g_Sys_x2etimeUs, h_time_us, 1);
