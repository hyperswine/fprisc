/* Shared descriptor I/O for Unix and ESP-IDF VFS/lwIP. */
#include "os_value.h"
#include <fcntl.h>
#include <limits.h>
#ifdef FPR_ESP_IDF
#include <sys/poll.h>
#else
#include <poll.h>
#include <signal.h>
#endif
#include <unistd.h>

/* ---- the reactor: descriptor waits off the harts (overhead plan R2) -------
 * One thread waits in epoll_wait for every descriptor an actor is parked on
 * (actors.c fpr_io_wait) and hands each ready one back by its token
 * (fpr_io_fire), which wakes the actor on its hart.  Started on the first
 * wait.  A registration is one-shot and is removed by the waiter after it
 * wakes.  Linux only for now: elsewhere hal_io_arm stays the runtime's weak
 * "no reactor" and a read waits in the kernel as it did. */
int fpr_io_wait(int fd, int events);
#if defined(__linux__) && !defined(FPR_ESP_IDF)
#include <sys/epoll.h>
#include <pthread.h>
#include <errno.h>
void fpr_io_fire(uint64_t token);
static int reactor_ep = -1;
static pthread_once_t reactor_once = PTHREAD_ONCE_INIT;
static void *reactor_loop(void *arg) {
  (void)arg;
  struct epoll_event ev[64];
  for (;;) {
    int n = epoll_wait(reactor_ep, ev, 64, -1);
    if (n < 0) {
      if (errno == EINTR) continue;
      fpr_cpanic("reactor: epoll_wait failed");
    }
    for (int i = 0; i < n; i++) fpr_io_fire(ev[i].data.u64);
  }
  return 0;
}
static void reactor_start(void) {
  int ep = epoll_create1(EPOLL_CLOEXEC);
  if (ep < 0) return;
  reactor_ep = ep;
  sigset_t all, old;
  sigfillset(&all); /* the harts' signals stay with the harts */
  pthread_sigmask(SIG_BLOCK, &all, &old);
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
  pthread_t t;
  if (pthread_create(&t, &at, reactor_loop, 0)) { close(ep); reactor_ep = -1; }
  pthread_attr_destroy(&at);
  pthread_sigmask(SIG_SETMASK, &old, 0);
}
/* 0 = armed; anything else = not (a regular file: EPERM; a descriptor some
 * other actor is already waiting on: EEXIST) */
int hal_io_arm(int fd, int events, uint64_t token) {
  pthread_once(&reactor_once, reactor_start);
  if (reactor_ep < 0) return -1;
  struct epoll_event e;
  e.events = ((events & 1) ? EPOLLIN | EPOLLRDHUP : 0) | ((events & 2) ? EPOLLOUT : 0) | EPOLLONESHOT;
  e.data.u64 = token;
  return epoll_ctl(reactor_ep, EPOLL_CTL_ADD, fd, &e);
}
void hal_io_disarm(int fd) {
  if (reactor_ep >= 0) (void)epoll_ctl(reactor_ep, EPOLL_CTL_DEL, fd, 0);
}
#endif
/* a blocking descriptor with nothing to read yet: park the actor until it has
 * (or until it hangs up), instead of the hart; a non-blocking one keeps its
 * "again" answer */
#if defined(__linux__) && !defined(FPR_ESP_IDF)
/* descriptors Os.open opened on a regular file (until Os.close): a read of
 * one never waits, so it skips the readiness check (a system call a read).
 * A stale bit -- the descriptor closed some other way and reused -- only
 * makes that read wait in the kernel, as every read did before. */
#include <sys/stat.h>
#define REG_FDS 4096
static uint64_t reg_fd[REG_FDS / 64];
static void reg_note(int fd) {
  struct stat st;
  if (fd < 0 || fd >= REG_FDS) return;
  if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) __atomic_fetch_or(&reg_fd[fd / 64], (uint64_t)1 << (fd % 64), __ATOMIC_RELAXED);
}
static void reg_forget(int fd) {
  if (fd >= 0 && fd < REG_FDS) __atomic_fetch_and(&reg_fd[fd / 64], ~((uint64_t)1 << (fd % 64)), __ATOMIC_RELAXED);
}
static int reg_is(int fd) {
  return fd >= 0 && fd < REG_FDS && (__atomic_load_n(&reg_fd[fd / 64], __ATOMIC_RELAXED) >> (fd % 64)) & 1;
}
#else
static void reg_note(int fd) { (void)fd; }
static void reg_forget(int fd) { (void)fd; }
#endif
static void wait_readable(int fd) {
#if defined(__linux__) && !defined(FPR_ESP_IDF)
  if (reg_is(fd)) return;
  struct pollfd p = {fd, POLLIN, 0};
  int r;
  do r = poll(&p, 1, 0); while (r < 0 && errno == EINTR);
  if (r != 0) return; /* ready, or poll's own error: the read reports it */
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || (flags & O_NONBLOCK)) return;
  (void)fpr_io_wait(fd, 1);
#else
  (void)fd;
#endif
}

/* ---- streams: a file or a socket is a descriptor ------------------------- */
static V h_open(V pathv, V modev) {
  char *path = os_cstr(pathv, "Os.open: the path is not a String");
  char *mode = os_cstr(modev, "Os.open: the mode is not a String");
  int flags = !strcmp(mode, "r") ? O_RDONLY
            : !strcmp(mode, "w") ? O_WRONLY | O_CREAT | O_TRUNC
            : !strcmp(mode, "a") ? O_WRONLY | O_CREAT | O_APPEND
            : !strcmp(mode, "rw") ? O_RDWR | O_CREAT : -1;
  V r;
  if (flags < 0) r = os_err("mode must be \"r\", \"w\", \"a\" or \"rw\"");
  else {
    int fd = open(path, flags | O_CLOEXEC, 0666);
    if (fd >= 0) reg_note(fd);
    r = fd < 0 ? os_errno() : os_ok(TAG(fd));
  }
  free(path); free(mode);
  return r;
}
FPR_FN_CSTACK(fpr_g_Os_x2eopen, h_open, 2);

/* Is there something to read (or an end of stream to learn of)?  Answers one
 * of the two STATIC booleans: waiting for a quiet socket allocates nothing, so
 * an idle session costs no memory however long it idles.  (Os.read used to be
 * the poll: it allocated its 64 KiB String BEFORE finding there was nothing,
 * and 600 idle sessions made gigabytes of garbage a second.) */
static V h_ready(V fdv) {
  struct pollfd p = {want_fd(fdv, "Os.ready: the stream is not an Int"), POLLIN, 0};
  int r = poll(&p, 1, 0);
  return (r > 0 || (r < 0 && errno != EINTR)) ? V_TRUE : V_FALSE;
}
FPR_FN(fpr_g_Os_x2eready, h_ready, 1);

/* Directional zero-time readiness; no retry/deadline policy lives here.
 * Static successful results keep quiet readiness checks allocation-free. */
static const struct { hdr_t h; V value; } ready_yes = {{T_RESULT, 0}, V_TRUE};
static const struct { hdr_t h; V value; } ready_no = {{T_RESULT, 0}, V_FALSE};
static V h_ready_for(V fdv, V maskv) {
  int fd = want_fd(fdv, "Os.readyFor: descriptor must be an Int");
  if (UNTAG(fdv) < 0 || UNTAG(fdv) > INT_MAX) return os_err("descriptor outside host range");
  if (!ISINT(maskv) || UNTAG(maskv) < 1 || UNTAG(maskv) > 3)
    return os_err("readiness mask must be 1, 2 or 3");
  int mask = (int)UNTAG(maskv);
  struct pollfd p = {fd, (short)(((mask & 1) ? POLLIN : 0) | ((mask & 2) ? POLLOUT : 0)), 0};
  int r = poll(&p, 1, 0);
  if (r < 0) return errno == EINTR ? (V)&ready_no : os_errno();
  if (p.revents & POLLNVAL) return os_err("invalid descriptor");
  return r > 0 ? (V)&ready_yes : (V)&ready_no;
}
FPR_FN(fpr_g_Os_x2ereadyFor, h_ready_for, 2);

/* ONE system call for every descriptor a server is waiting on (std/poller.fpr).
 * Nothing ready answers the static Nil: an idle server's poller allocates
 * nothing.  A descriptor that has gone bad counts as ready -- its reader will
 * learn why from the read. */
static V h_poll(V fdsv) {
  size_t n = 0;
  for (V c = fdsv; ISPTR(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) n++;
  if (!n) return V_NIL;
  struct pollfd small[64], *p = n <= 64 ? small : malloc(n * sizeof *p);
  if (!p) fpr_cpanic("out of memory");
  size_t i = 0;
  for (V c = fdsv; i < n; c = ((V *)((char *)c + 8))[1]) {
    V f = ((V *)((char *)c + 8))[0];
    p[i].fd = ISINT(f) ? (int)UNTAG(f) : -1;
    p[i].events = POLLIN;
    p[i++].revents = 0;
  }
  V out = V_NIL;
  if (poll(p, (nfds_t)n, 0) > 0)
    for (i = n; i-- > 0;)
      if (p[i].revents) out = os_cons(TAG(p[i].fd), out);
  if (p != small) free(p);
  return out;
}
FPR_FN(fpr_g_Os_x2epoll, h_poll, 1);

static V h_read(V fdv, V nv) {
  int fd = want_fd(fdv, "Os.read: the stream is not an Int");
  sw n = ISINT(nv) ? UNTAG(nv) : 0;
  if (n <= 0) return os_ok(os_str("", 0));
  hal_console_flush(); /* what was printed is out before the program waits for input */
  char small[4096], *buf = small;
  if ((size_t)n > sizeof small) { buf = malloc((size_t)n); if (!buf) return os_err("out of memory"); }
  wait_readable(fd);
  ssize_t r;
  do r = read(fd, buf, (size_t)n); while (r < 0 && errno == EINTR);
  V out = r < 0 ? os_again_or_errno() : os_ok(os_str(buf, (uw)r));
  if (buf != small) free(buf);
  return out;
}
FPR_FN_CSTACK(fpr_g_Os_x2eread, h_read, 2);

static V h_write(V fdv, V datav) {
  int fd = want_fd(fdv, "Os.write: the stream is not an Int");
  if (ISINT(datav) || TID(datav) != T_STR) fpr_cpanic("Os.write: the data is not a String");
  const str_t *d = (const str_t *)datav;
#ifndef FPR_ESP_IDF
  signal(SIGPIPE, SIG_IGN); /* a peer that has gone is an Err, not our death */
#endif
  hal_console_flush(); /* printed lines first: a raw write to descriptor 1 follows them */
  ssize_t r;
  do r = write(fd, d->bytes, d->len); while (r < 0 && errno == EINTR);
  return r < 0 ? os_again_or_errno() : os_ok(TAG((sw)r));
}
FPR_FN_CSTACK(fpr_g_Os_x2ewrite, h_write, 2);

static V h_seek(V fdv, V offv) {
  off_t at = lseek(want_fd(fdv, "Os.seek: the stream is not an Int"), (off_t)UNTAG(offv), SEEK_SET);
  return at < 0 ? os_errno() : os_ok(TAG((sw)at));
}
FPR_FN_CSTACK(fpr_g_Os_x2eseek, h_seek, 2);

static V h_close(V fdv) {
  int fd = want_fd(fdv, "Os.close: the stream is not an Int");
  reg_forget(fd);
  return os_unit_or_errno(close(fd));
}
FPR_FN_CSTACK(fpr_g_Os_x2eclose, h_close, 1);
