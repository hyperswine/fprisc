/* base_file.c (posix) -- the Base profile's whole-file builtins, over stdio.
 *
 *   fileRead     : String -> String                 whole file; panics when it cannot
 *   fileWrite    : String -> String -> Result Unit String   path, contents (replace)
 *   fileAppend   : String -> String -> Result Unit String
 *   fileExists   : String -> Bool
 *
 * Apart from base.c (argv, exit, environment, stdin) because they need only
 * stdio and stat: ESP-IDF's newlib and VFS provide both once a filesystem is
 * mounted, and a board has no process for base.c to describe. */
#include "fpr.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static const str_t *want_str(V v, const char *who) {
  if (ISINT(v) || TID(v) != T_STR) {
    char msg[96];
    snprintf(msg, sizeof msg, "%s: expected a String", who);
    fpr_cpanic(msg);
  }
  return (const str_t *)v;
}

/* a NUL-terminated copy of a path: past the buffer is a named panic, never a cut path */
static void cpath(V v, const char *who, char *out, size_t cap) {
  const str_t *s = want_str(v, who);
  if (s->len >= cap) fpr_cpanic("path too long");
  memcpy(out, s->bytes, s->len);
  out[s->len] = 0;
}

static V h_file_read(V pathv) {
  char path[1024];
  cpath(pathv, "fileRead", path, sizeof path);
  FILE *file = fopen(path, "rb");
  if (!file) fpr_cpanic("fileRead: open failed");
  if (fseek(file, 0, SEEK_END) || ftell(file) < 0) { fclose(file); fpr_cpanic("fileRead: seek failed"); }
  long size = ftell(file);
  rewind(file);
  str_t *result = (str_t *)fpr_alloc((V)(sizeof(str_t) + (uw)size));
  result->tid = T_STR;
  result->var = 0;
  result->len = (uw)size;
  if (size && fread(result->bytes, 1, (size_t)size, file) != (size_t)size) { fclose(file); fpr_cpanic("fileRead: read failed"); }
  fclose(file);
  return (V)result;
}
FPR_FN_CSTACK(fpr_g_fileRead, h_file_read, 1);

static V file_put(V pathv, V datav, const char *mode, const char *who) {
  char path[1024];
  cpath(pathv, who, path, sizeof path);
  const str_t *s = want_str(datav, who);
  FILE *f = fopen(path, mode);
  if (!f) return fpr_mkresult(1, strerror(errno));
  if (s->len && fwrite(s->bytes, 1, s->len, f) != s->len) { fclose(f); return fpr_mkresult(1, "write failed"); }
  if (fclose(f)) return fpr_mkresult(1, strerror(errno));
  return fpr_mkresult(0, "");
}
static V h_file_write(V p, V d) { return file_put(p, d, "wb", "fileWrite"); }
static V h_file_append(V p, V d) { return file_put(p, d, "ab", "fileAppend"); }
FPR_FN_CSTACK(fpr_g_fileWrite, h_file_write, 2);
FPR_FN_CSTACK(fpr_g_fileAppend, h_file_append, 2);

static V h_file_exists(V pathv) {
  char path[1024];
  cpath(pathv, "fileExists", path, sizeof path);
  struct stat st;
  return stat(path, &st) == 0 ? (V)&fpr_true : (V)&fpr_false;
}
FPR_FN_CSTACK(fpr_g_fileExists, h_file_exists, 1);
