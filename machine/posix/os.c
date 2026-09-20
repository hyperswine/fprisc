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
 *   Os.run       : List String -> String -> String -> List String -> Int
 *                  -> Result (Int, String, String) String
 *                  argv, working directory ("" = this one), stdin's bytes,
 *                  extra environment ("NAME=value", added to this process's),
 *                  a time limit in ms (0 = none; past it the child is killed
 *                  and the answer is Err "timed out after N ms")
 *                  -> exit status (128 + signal when killed), stdout, stderr
 *   Os.wallClock : Unit -> Int                                  seconds since 1970-01-01 UTC
 *   Os.exec      : List String -> Result Unit String            BECOME that program (execvp): on
 *                                                               success this process is gone, so an
 *                                                               answer is always the Err
 *
 * Streams (files and sockets alike are a descriptor, an Int):
 *   Os.open      : String -> String -> Result Int String        path, mode "r" | "w" | "a" | "rw"
 *   Os.ready     : Int -> Bool                                  something to read (or accept) NOW; allocates nothing
 *   Os.poll      : List Int -> List Int                         which of these are ready NOW (one poll(2) for
 *                                                               all of them); none ready = the static Nil
 *   Os.read      : Int -> Int -> Result String String           up to n bytes; "" = end of stream;
 *                                                               Err "again" = nothing YET (sockets)
 *   Os.write     : Int -> String -> Result Int String           bytes taken (may be fewer); Err "again"
 *   Os.seek      : Int -> Int -> Result Int String              absolute offset -> the new offset
 *   Os.close     : Int -> Result Unit String
 *   Os.connect   : String -> Int -> Result Int String           host, port -> a connected socket
 *   Os.listen    : String -> Int -> Result Int String           address ("" = every), port -> a listener
 *   Os.accept    : Int -> Result (Int, String) String           a connection and its peer; Err "again"
 *   Os.localPort : Int -> Result Int String                     the port a listener got (listen on 0)
 *
 * Sockets are NON-BLOCKING: a hart is a thread shared by many actors, so a
 * primitive must never sit in the kernel waiting.  "again" is the answer when
 * there is nothing yet, and std/stream.fpr sleeps the ACTOR and retries.
 *
 * Nothing here has a capacity: paths and outputs are as long as they are.
 * Every failure is an Err with the system's own words, never a panic. */
#include "fpr.h"
#include <arpa/inet.h>
#include <dirent.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
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
static sw now_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (sw)ts.tv_sec * 1000 + ts.tv_nsec / 1000000; }
static V h_run(V argvv, V cwdv, V inv, V envv, V limitv) {
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
  size_t envc = 0;
  for (V c = envv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) envc++;
  char **envs = calloc(envc + 1, sizeof *envs);
  if (!envs) fpr_cpanic("out of memory");
  { size_t k = 0; for (V c = envv; k < envc; c = ((V *)((char *)c + 8))[1]) envs[k++] = os_cstr(((V *)((char *)c + 8))[0], "Os.run: an environment entry is not a String"); }
  sw limit = ISINT(limitv) ? UNTAG(limitv) : 0, started = now_ms();
  int timed_out = 0;
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
    for (size_t k = 0; k < envc; k++) putenv(envs[k]); /* the child's copy; "NAME=value" */
    { sigset_t none; sigemptyset(&none); sigprocmask(SIG_SETMASK, &none, 0); signal(SIGPIPE, SIG_DFL); }
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
    int wait_ms = -1;
    if (limit > 0) {
      sw left = limit - (now_ms() - started);
      if (left <= 0) { timed_out = 1; kill(pid, SIGKILL); break; }
      wait_ms = (int)left;
    }
    int pr = poll(p, (nfds_t)n, wait_ms);
    if (pr < 0) { if (errno == EINTR) continue; break; }
    if (pr == 0) continue; /* the limit is checked at the top */
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
  if (open_in) close(pin[1]);
  if (open_out) close(pout[0]);
  if (open_err) close(perr[0]);
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  if (timed_out) {
    char msg[64];
    snprintf(msg, sizeof msg, "timed out after %ld ms", (long)limit);
    result = os_err(msg);
  } else if (child_errno) {
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
  for (i = 0; i < envc; i++) free(envs[i]);
  free(argv); free(envs); free(cwd);
  return result;
}
FPR_FN(fpr_g_Os_x2erun, h_run, 5);

/* ---- streams: a file or a socket is a descriptor ------------------------- */
static V os_again_or_errno(void) { return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS) ? os_err("again") : os_errno(); }
static int want_fd(V v, const char *who) { if (!ISINT(v)) fpr_cpanic(who); return (int)UNTAG(v); }

static V h_open(V pathv, V modev) {
  char *path = os_cstr(pathv, "Os.open: the path is not a String");
  char *mode = os_cstr(modev, "Os.open: the mode is not a String");
  int flags = !strcmp(mode, "r") ? O_RDONLY
            : !strcmp(mode, "w") ? O_WRONLY | O_CREAT | O_TRUNC
            : !strcmp(mode, "a") ? O_WRONLY | O_CREAT | O_APPEND
            : !strcmp(mode, "rw") ? O_RDWR | O_CREAT : -1;
  V r;
  if (flags < 0) r = os_err("mode must be \"r\", \"w\", \"a\" or \"rw\"");
  else { int fd = open(path, flags | O_CLOEXEC, 0666); r = fd < 0 ? os_errno() : os_ok(TAG(fd)); }
  free(path); free(mode);
  return r;
}
FPR_FN(fpr_g_Os_x2eopen, h_open, 2);

/* Is there something to read (or an end of stream to learn of)?  Answers one
 * of the two STATIC booleans: waiting for a quiet socket allocates nothing, so
 * an idle session costs no memory however long it idles.  (Os.read used to be
 * the poll: it allocated its 64 KiB String BEFORE finding there was nothing,
 * and 600 idle sessions made gigabytes of garbage a second.) */
static V h_ready(V fdv) {
  struct pollfd p = {want_fd(fdv, "Os.ready: the stream is not an Int"), POLLIN, 0};
  int r = poll(&p, 1, 0);
  return (r > 0 || (r < 0 && errno != EINTR)) ? (V)&fpr_true : (V)&fpr_false;
}
FPR_FN(fpr_g_Os_x2eready, h_ready, 1);

/* ONE system call for every descriptor a server is waiting on (std/poller.fpr).
 * Nothing ready answers the static Nil: an idle server's poller allocates
 * nothing.  A descriptor that has gone bad counts as ready -- its reader will
 * learn why from the read. */
static V h_poll(V fdsv) {
  size_t n = 0;
  for (V c = fdsv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) n++;
  if (!n) return (V)&os_nil;
  struct pollfd small[64], *p = n <= 64 ? small : malloc(n * sizeof *p);
  if (!p) fpr_cpanic("out of memory");
  size_t i = 0;
  for (V c = fdsv; i < n; c = ((V *)((char *)c + 8))[1]) {
    V f = ((V *)((char *)c + 8))[0];
    p[i].fd = ISINT(f) ? (int)UNTAG(f) : -1;
    p[i].events = POLLIN;
    p[i++].revents = 0;
  }
  V out = (V)&os_nil;
  if (poll(p, (nfds_t)n, 0) > 0)
    for (i = n; i-- > 0;)
      if (p[i].revents) out = os_cons(TAG(p[i].fd), out);
  if (p != small) free(p);
  return out;
}
FPR_FN(fpr_g_Os_x2epoll, h_poll, 1);

/* read into C memory first, then make a String of EXACTLY what arrived: a
 * 20-byte frame is a 20-byte String, not a 64 KiB block with 20 bytes used */
static V h_read(V fdv, V nv) {
  int fd = want_fd(fdv, "Os.read: the stream is not an Int");
  sw n = ISINT(nv) ? UNTAG(nv) : 0;
  if (n <= 0) return os_ok(os_str("", 0));
  char small[4096], *buf = small;
  if ((size_t)n > sizeof small) { buf = malloc((size_t)n); if (!buf) return os_err("out of memory"); }
  ssize_t r;
  do r = read(fd, buf, (size_t)n); while (r < 0 && errno == EINTR);
  V out = r < 0 ? os_again_or_errno() : os_ok(os_str(buf, (uw)r));
  if (buf != small) free(buf);
  return out;
}
FPR_FN(fpr_g_Os_x2eread, h_read, 2);

static V h_write(V fdv, V datav) {
  int fd = want_fd(fdv, "Os.write: the stream is not an Int");
  if (ISINT(datav) || TID(datav) != T_STR) fpr_cpanic("Os.write: the data is not a String");
  const str_t *d = (const str_t *)datav;
  signal(SIGPIPE, SIG_IGN); /* a peer that has gone is an Err, not our death */
  ssize_t r;
  do r = write(fd, d->bytes, d->len); while (r < 0 && errno == EINTR);
  return r < 0 ? os_again_or_errno() : os_ok(TAG((sw)r));
}
FPR_FN(fpr_g_Os_x2ewrite, h_write, 2);

static V h_seek(V fdv, V offv) {
  off_t at = lseek(want_fd(fdv, "Os.seek: the stream is not an Int"), (off_t)UNTAG(offv), SEEK_SET);
  return at < 0 ? os_errno() : os_ok(TAG((sw)at));
}
FPR_FN(fpr_g_Os_x2eseek, h_seek, 2);

static V h_close(V fdv) { return os_unit_or_errno(close(want_fd(fdv, "Os.close: the stream is not an Int"))); }
FPR_FN(fpr_g_Os_x2eclose, h_close, 1);

static void sock_tune(int fd) {
  int one = 1;
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
}

/* name resolution and the connect itself DO wait (bounded by the system's own
 * timeouts): there is no portable non-blocking resolver.  Everything after is
 * non-blocking. */
static V h_connect(V hostv, V portv) {
  char *host = os_cstr(hostv, "Os.connect: the host is not a String");
  char port[16];
  snprintf(port, sizeof port, "%ld", (long)UNTAG(portv));
  struct addrinfo hints = {0}, *res = 0;
  hints.ai_socktype = SOCK_STREAM;
  int g = getaddrinfo(host, port, &hints, &res);
  free(host);
  if (g) return os_err(gai_strerror(g));
  V r = os_err("no address to connect to");
  for (struct addrinfo *a = res; a; a = a->ai_next) {
    int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0) { r = os_errno(); continue; }
    if (connect(fd, a->ai_addr, a->ai_addrlen)) { r = os_errno(); close(fd); continue; }
    sock_tune(fd);
    r = os_ok(TAG(fd));
    break;
  }
  freeaddrinfo(res);
  return r;
}
FPR_FN(fpr_g_Os_x2econnect, h_connect, 2);

static V h_listen(V addrv, V portv) {
  char *addr = os_cstr(addrv, "Os.listen: the address is not a String");
  char port[16];
  snprintf(port, sizeof port, "%ld", (long)UNTAG(portv));
  struct addrinfo hints = {0}, *res = 0;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_INET;
  hints.ai_flags = AI_PASSIVE;
  int g = getaddrinfo(*addr ? addr : 0, port, &hints, &res);
  free(addr);
  if (g) return os_err(gai_strerror(g));
  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol), one = 1;
  V r;
  if (fd < 0) r = os_errno();
  else {
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(fd, res->ai_addr, res->ai_addrlen) || listen(fd, SOMAXCONN)) { r = os_errno(); close(fd); }
    else { sock_tune(fd); r = os_ok(TAG(fd)); }
  }
  freeaddrinfo(res);
  return r;
}
FPR_FN(fpr_g_Os_x2elisten, h_listen, 2);

static V h_accept(V fdv) {
  struct sockaddr_in peer;
  socklen_t len = sizeof peer;
  int fd;
  do fd = accept(want_fd(fdv, "Os.accept: the listener is not an Int"), (struct sockaddr *)&peer, &len); while (fd < 0 && errno == EINTR);
  if (fd < 0) return os_again_or_errno();
  sock_tune(fd);
  char name[64] = "?";
  inet_ntop(AF_INET, &peer.sin_addr, name, sizeof name);
  V f[2] = {TAG(fd), os_str(name, (uw)strlen(name))};
  return os_ok(os_cell(T_TUP2, 0, 2, f));
}
FPR_FN(fpr_g_Os_x2eaccept, h_accept, 1);

static V h_local_port(V fdv) {
  struct sockaddr_in me;
  socklen_t len = sizeof me;
  if (getsockname(want_fd(fdv, "Os.localPort: the listener is not an Int"), (struct sockaddr *)&me, &len)) return os_errno();
  return os_ok(TAG((sw)ntohs(me.sin_port)));
}
FPR_FN(fpr_g_Os_x2elocalPort, h_local_port, 1);

/* become another program: how a live server restarts into its rebuilt self
 * (std/live.fpr).  Sockets and files opened here are close-on-exec. */
/* what a new program must not inherit from the thread that started it: a hart
 * thread's signal mask (exec keeps the CALLING thread's, and a restarted server
 * with its wake-up signals blocked hangs one time in three), and the ignored
 * SIGPIPE (dispositions of SIG_IGN survive exec) */
static void clean_for_exec(void) {
  sigset_t none;
  sigemptyset(&none);
  pthread_sigmask(SIG_SETMASK, &none, 0);
  signal(SIGPIPE, SIG_DFL);
}

static V h_exec(V argvv) {
  size_t argc = 0;
  for (V c = argvv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) argc++;
  if (!argc) return os_err("no program named");
  char **argv = calloc(argc + 1, sizeof *argv);
  if (!argv) fpr_cpanic("out of memory");
  size_t i = 0;
  for (V c = argvv; i < argc; c = ((V *)((char *)c + 8))[1]) argv[i++] = os_cstr(((V *)((char *)c + 8))[0], "Os.exec: an argument is not a String");
  fflush(stdout); fflush(stderr);
  clean_for_exec();
  execvp(argv[0], argv);
  V e = os_errno();
  signal(SIGPIPE, SIG_IGN);
  for (i = 0; i < argc; i++) free(argv[i]);
  free(argv);
  return e;
}
FPR_FN(fpr_g_Os_x2eexec, h_exec, 1);
