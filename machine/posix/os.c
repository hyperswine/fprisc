/* os.c (posix) -- what the std library's OS modules stand on: whole files,
 * directories, file facts, processes and the wall clock, over libc.
 *
 * These are declared where they are USED -- a signature with no definition in
 * std/file.fpr, std/dir.fpr, std/proc.fpr, std/clock.fpr (docs/C-REDUCTION.md:
 * a primitive is declared by whoever implements it, and this is the posix
 * system's).  A program that uses std/dir on a system with no directories
 * fails at LINK time on the fpr_g_Os_ name: its imports are its manifest.
 *
 *   Os.readFile  : String -> Result String String
 *   Os.listDir   : String -> Result (List String) String        names, sorted, no "." / ".."
 *   Os.stat      : String -> Result (Int, Int, Int) String      kind (0 file, 1 dir, 2 other), bytes, mtime (s)
 *   Os.mkdir     : String -> Result Unit String                 one level; "exists" is Ok
 *   Os.remove    : String -> Result Unit String                 a file, or an EMPTY directory
 *   Os.rename    : String -> String -> Result Unit String
 *   Os.cwd       : Unit -> String
 *   Os.run       : List String -> String -> String -> Result (Int, String, String) String
 *                  argv, working directory ("" = this one), stdin's bytes
 *                  -> exit status (128 + signal when killed), stdout, stderr
 *   Os.wallClock : Unit -> Int                                  seconds since 1970-01-01 UTC
 *
 * Nothing here has a capacity: paths and outputs are as long as they are.
 * Every failure is an Err with the system's own words, never a panic. */
#include "fpr.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const hdr_t os_nil = {T_LIST, 0};

static V os_str(const char *s, uw n) { return (V)fpr_mkstr((const uint8_t *)s, n); }
static V os_cell(uint32_t tid, uint32_t var, int n, const V *f) {
  V c = fpr_alloc((V)(8 + (uw)n * sizeof(uw)));
  ((hdr_t *)c)->tid = tid;
  ((hdr_t *)c)->var = var;
  for (int i = 0; i < n; i++) ((V *)((char *)c + 8))[i] = f[i];
  return c;
}
static V os_ok(V v) { return os_cell(T_RESULT, 0, 1, &v); }
static V os_err(const char *what) { V m = os_str(what, (uw)strlen(what)); return os_cell(T_RESULT, 1, 1, &m); }
static V os_errno(void) { return os_err(strerror(errno)); }
static V os_cons(V h, V t) { V f[2] = {h, t}; return os_cell(T_LIST, 1, 2, f); }

/* a NUL-terminated copy, as long as the String is (the caller frees) */
static char *os_cstr(V v, const char *who) {
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
static int buf_room(buf_t *b, size_t more) {
  if (b->n + more <= b->cap) return 1;
  size_t cap = b->cap ? b->cap : 4096;
  while (cap < b->n + more) cap *= 2;
  char *q = realloc(b->p, cap);
  if (!q) return 0;
  b->p = q; b->cap = cap;
  return 1;
}

static V h_read_file(V pathv) {
  char *path = os_cstr(pathv, "Os.readFile: the path is not a String");
  int fd = open(path, O_RDONLY);
  free(path);
  if (fd < 0) return os_errno();
  buf_t b = {0, 0, 0};
  for (;;) { /* read to EOF: a pipe or /proc file has no size to ask for */
    if (!buf_room(&b, 65536)) { close(fd); free(b.p); return os_err("out of memory"); }
    ssize_t r = read(fd, b.p + b.n, b.cap - b.n);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) { V e = os_errno(); close(fd); free(b.p); return e; }
    if (r == 0) break;
    b.n += (size_t)r;
  }
  close(fd);
  V s = os_str(b.p ? b.p : "", b.n);
  free(b.p);
  return os_ok(s);
}
FPR_FN(fpr_g_Os_x2ereadFile, h_read_file, 1);

static int name_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static V h_list_dir(V pathv) {
  char *path = os_cstr(pathv, "Os.listDir: the path is not a String");
  DIR *d = opendir(path);
  free(path);
  if (!d) return os_errno();
  char **names = 0;
  size_t n = 0, cap = 0;
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    if (n == cap) {
      cap = cap ? cap * 2 : 64;
      char **q = realloc(names, cap * sizeof *q);
      if (!q) fpr_cpanic("out of memory");
      names = q;
    }
    names[n++] = strdup(e->d_name);
  }
  closedir(d);
  qsort(names, n, sizeof *names, name_cmp); /* readdir's order is the filesystem's whim */
  V l = (V)&os_nil;
  for (size_t i = n; i-- > 0;) { l = os_cons(os_str(names[i], (uw)strlen(names[i])), l); free(names[i]); }
  free(names);
  return os_ok(l);
}
FPR_FN(fpr_g_Os_x2elistDir, h_list_dir, 1);

static V h_stat(V pathv) {
  char *path = os_cstr(pathv, "Os.stat: the path is not a String");
  struct stat st;
  int r = stat(path, &st);
  free(path);
  if (r) return os_errno();
  V f[3] = {TAG(S_ISREG(st.st_mode) ? 0 : S_ISDIR(st.st_mode) ? 1 : 2), TAG((sw)st.st_size), TAG((sw)st.st_mtime)};
  return os_ok(os_cell(T_TUP3, 0, 3, f));
}
FPR_FN(fpr_g_Os_x2estat, h_stat, 1);

static V os_unit_or_errno(int r) { return r ? os_errno() : os_ok((V)&fpr_unit); }

static V h_mkdir(V pathv) {
  char *path = os_cstr(pathv, "Os.mkdir: the path is not a String");
  int r = mkdir(path, 0777);
  if (r && errno == EEXIST) { struct stat st; if (!stat(path, &st) && S_ISDIR(st.st_mode)) r = 0; else errno = EEXIST; }
  V v = os_unit_or_errno(r);
  free(path);
  return v;
}
FPR_FN(fpr_g_Os_x2emkdir, h_mkdir, 1);

static V h_remove(V pathv) {
  char *path = os_cstr(pathv, "Os.remove: the path is not a String");
  V v = os_unit_or_errno(remove(path));
  free(path);
  return v;
}
FPR_FN(fpr_g_Os_x2eremove, h_remove, 1);

static V h_rename(V fromv, V tov) {
  char *from = os_cstr(fromv, "Os.rename: the path is not a String");
  char *to = os_cstr(tov, "Os.rename: the path is not a String");
  V v = os_unit_or_errno(rename(from, to));
  free(from); free(to);
  return v;
}
FPR_FN(fpr_g_Os_x2erename, h_rename, 2);

static V h_cwd(V u) {
  (void)u;
  char *c = getcwd(0, 0); /* the allocating form: both libcs size it */
  if (!c) return os_str("", 0);
  V s = os_str(c, (uw)strlen(c));
  free(c);
  return s;
}
FPR_FN(fpr_g_Os_x2ecwd, h_cwd, 1);

static V h_wall_clock(V u) { (void)u; return TAG((sw)time(0)); }
FPR_FN(fpr_g_Os_x2ewallClock, h_wall_clock, 1);

/* ---- Os.run: a child with all three streams held ------------------------
 * fork/exec rather than posix_spawn for the chdir.  stdin is fed and both
 * outputs drained in ONE poll loop, so a child that fills a pipe while we
 * are still writing its input cannot deadlock us. */
static V h_run(V argvv, V cwdv, V inv) {
  if (ISINT(inv) || TID(inv) != T_STR) fpr_cpanic("Os.run: stdin is not a String");
  const str_t *in = (const str_t *)inv;
  size_t argc = 0;
  for (V c = argvv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) argc++;
  if (!argc) return os_err("no program named");
  char **argv = calloc(argc + 1, sizeof *argv);
  if (!argv) fpr_cpanic("out of memory");
  size_t i = 0;
  for (V c = argvv; i < argc; c = ((V *)((char *)c + 8))[1]) argv[i++] = os_cstr(((V *)((char *)c + 8))[0], "Os.run: an argument is not a String");
  char *cwd = os_cstr(cwdv, "Os.run: the directory is not a String");
  int pin[2], pout[2], perr[2], pexec[2];
  V result;
  if (pipe(pin) || pipe(pout) || pipe(perr) || pipe(pexec)) { result = os_errno(); goto done; }
  fcntl(pexec[1], F_SETFD, FD_CLOEXEC); /* closes on a successful exec: EOF means it ran */
  fflush(stdout); fflush(stderr);
  pid_t pid = fork();
  if (pid < 0) { result = os_errno(); goto done; }
  if (pid == 0) {
    dup2(pin[0], 0); dup2(pout[1], 1); dup2(perr[1], 2);
    close(pin[0]); close(pin[1]); close(pout[0]); close(pout[1]); close(perr[0]); close(perr[1]); close(pexec[0]);
    if (!*cwd || !chdir(cwd)) execvp(argv[0], argv);
    int e = errno;
    if (write(pexec[1], &e, sizeof e) < 0) {}
    _exit(127);
  }
  close(pin[0]); close(pout[1]); close(perr[1]); close(pexec[1]);
  int child_errno = 0;
  if (read(pexec[0], &child_errno, sizeof child_errno) != sizeof child_errno) child_errno = 0;
  close(pexec[0]);
  signal(SIGPIPE, SIG_IGN); /* a child that does not read its input is not our death */
  fcntl(pin[1], F_SETFL, O_NONBLOCK);
  buf_t out = {0, 0, 0}, err = {0, 0, 0};
  size_t fed = 0;
  int open_in = 1, open_out = 1, open_err = 1;
  if (!in->len) { close(pin[1]); open_in = 0; }
  while (open_in || open_out || open_err) {
    struct pollfd p[3];
    int n = 0, ii = -1, io = -1, ie = -1;
    if (open_in) { p[n].fd = pin[1]; p[n].events = POLLOUT; ii = n++; }
    if (open_out) { p[n].fd = pout[0]; p[n].events = POLLIN; io = n++; }
    if (open_err) { p[n].fd = perr[0]; p[n].events = POLLIN; ie = n++; }
    if (poll(p, (nfds_t)n, -1) < 0) { if (errno == EINTR) continue; break; }
    if (ii >= 0 && p[ii].revents) {
      ssize_t w = write(pin[1], in->bytes + fed, in->len - fed);
      if (w > 0) fed += (size_t)w;
      if ((w < 0 && errno != EAGAIN && errno != EINTR) || fed == in->len) { close(pin[1]); open_in = 0; }
    }
    buf_t *bs[2] = {&out, &err};
    int idx[2] = {io, ie}, fds[2] = {pout[0], perr[0]}, *opens[2] = {&open_out, &open_err};
    for (int k = 0; k < 2; k++) {
      if (idx[k] < 0 || !p[idx[k]].revents) continue;
      if (!buf_room(bs[k], 65536)) fpr_cpanic("out of memory");
      ssize_t r = read(fds[k], bs[k]->p + bs[k]->n, bs[k]->cap - bs[k]->n);
      if (r > 0) bs[k]->n += (size_t)r;
      else if (r == 0 || (errno != EINTR && errno != EAGAIN)) { close(fds[k]); *opens[k] = 0; }
    }
  }
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  if (child_errno) {
    errno = child_errno;
    result = os_errno(); /* it never ran: "No such file or directory" */
  } else {
    V f[3] = {TAG(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status)),
              os_str(out.p ? out.p : "", out.n), os_str(err.p ? err.p : "", err.n)};
    result = os_ok(os_cell(T_TUP3, 0, 3, f));
  }
  free(out.p); free(err.p);
done:
  for (i = 0; i < argc; i++) free(argv[i]);
  free(argv); free(cwd);
  return result;
}
FPR_FN(fpr_g_Os_x2erun, h_run, 3);
