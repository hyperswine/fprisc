/* Shared descriptor I/O for Unix and ESP-IDF VFS/lwIP. */
#include "os_value.h"
#include <fcntl.h>
#ifdef ESP_PLATFORM
#include <sys/poll.h>
#else
#include <poll.h>
#include <signal.h>
#endif
#include <unistd.h>

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
  else { int fd = open(path, flags | O_CLOEXEC, 0666); r = fd < 0 ? os_errno() : os_ok(TAG(fd)); }
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
FPR_FN_CSTACK(fpr_g_Os_x2eread, h_read, 2);

static V h_write(V fdv, V datav) {
  int fd = want_fd(fdv, "Os.write: the stream is not an Int");
  if (ISINT(datav) || TID(datav) != T_STR) fpr_cpanic("Os.write: the data is not a String");
  const str_t *d = (const str_t *)datav;
#ifndef ESP_PLATFORM
  signal(SIGPIPE, SIG_IGN); /* a peer that has gone is an Err, not our death */
#endif
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

static V h_close(V fdv) { return os_unit_or_errno(close(want_fd(fdv, "Os.close: the stream is not an Int"))); }
FPR_FN_CSTACK(fpr_g_Os_x2eclose, h_close, 1);
