/* Hosted files, directories, clocks and descriptor operations.
 * Processes, sockets, watcher and Unix terminal support are separate objects.
 * This is not yet an ESP-IDF adapter: VFS flags and SIGPIPE need review. */
#include "os_value.h"
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

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
/* the local zone's offset from UTC at that instant, in seconds east (DST
 * included): the one thing a clock needs that only the OS knows */
static V h_tz_offset(V secs) {
  time_t t = (time_t)UNTAG(secs);
  struct tm tm;
  if (!localtime_r(&t, &tm)) return TAG(0);
  return TAG((sw)tm.tm_gmtoff);
}
FPR_FN(fpr_g_Os_x2etzOffset, h_tz_offset, 1);
