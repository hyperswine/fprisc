#include "os_owned.h"
#ifdef FPR_ESP_IDF
static V unavailable_adopt(V a0) { (void)a0; return os_err("ConnHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_ConnHost_x2eadopt, unavailable_adopt, 1);
static V unavailable_begin(V a0, V a1, V a2) { (void)a0; (void)a1; (void)a2; return os_err("ConnHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_ConnHost_x2ebegin, unavailable_begin, 3);
static V unavailable_fd(V a0) { (void)a0; return os_err("ConnHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_ConnHost_x2efd, unavailable_fd, 1);
static V unavailable_status(V a0) { (void)a0; return os_err("ConnHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_ConnHost_x2estatus, unavailable_status, 1);
static V unavailable_read(V a0, V a1) { (void)a0; (void)a1; return os_err("ConnHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_ConnHost_x2eread, unavailable_read, 2);
static V unavailable_write(V a0, V a1) { (void)a0; (void)a1; return os_err("ConnHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_ConnHost_x2ewrite, unavailable_write, 2);
static V unavailable_close(V a0) { (void)a0; return os_err("ConnHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_ConnHost_x2eclose, unavailable_close, 1);
#else

#include <arpa/inet.h>
#include <fcntl.h>
#include <limits.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>
static void socket_destroy(void *data, int fd) { (void)data; close(fd); }
static int socket_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) return -1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC)) return -1;
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
  return 0;
}
/* Adoption failures otherwise become a silent TCP reset at a gateway;
 * outgoing connect failures need the same evidence for offline devices. Log
 * only native metadata, never peer addresses or request/authentication bytes.
 * Independent counters retain the first occurrence of each stage; exponential
 * sampling bounds log growth during a persistent failure or hostile traffic. */
static void connection_failure(unsigned stage, int fd, int error) {
  static unsigned long counts[6];
  static const char *names[] = {"socket-type", "peer", "nonblocking", "ownership", "connect-begin", "connect-status"};
  unsigned long n = __atomic_add_fetch(&counts[stage], 1, __ATOMIC_RELAXED);
  if (n && (n <= 4 || !(n & (n - 1))))
    fprintf(stderr, "ConnHost failure time=%lld stage=%s count=%lu fd=%d errno=%d\n",
            (long long)time(NULL), names[stage], n, fd, error);
  errno = error;
}
static V conn_adopt(V fdv) {
  if (!ISINT(fdv) || UNTAG(fdv) < 0 || UNTAG(fdv) > INT_MAX) return os_err("invalid descriptor");
  int fd = (int)UNTAG(fdv), type; socklen_t len = sizeof type;
  struct sockaddr_storage peer;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len)) { connection_failure(0, fd, errno); return os_errno(); }
  if (type != SOCK_STREAM) { connection_failure(0, fd, 0); return os_err("not a stream socket"); }
  len = sizeof peer;
  if (getpeername(fd, (struct sockaddr *)&peer, &len)) { connection_failure(1, fd, errno); return os_errno(); }
  if (socket_nonblock(fd)) { connection_failure(2, fd, errno); return os_errno(); }
  uw id = fpr_owned_add(OWN_SOCKET, fd, 0, socket_destroy);
  if (!id) { connection_failure(3, fd, 0); return os_err("socket already owned or resource ownership unavailable"); }
  return os_ok(TAG(id));
}
FPR_FN(fpr_g_ConnHost_x2eadopt, conn_adopt, 1);
static V conn_begin(V familyv, V addrv, V portv) {
  if (!ISINT(portv) || UNTAG(portv) < 1 || UNTAG(portv) > 65535) return os_err("invalid TCP port");
  if (!ISINT(familyv) || (UNTAG(familyv) != 4 && UNTAG(familyv) != 6)) return os_err("invalid address family");
  char *address = os_cstr(addrv, "connection address must be text");
  struct sockaddr_storage storage; memset(&storage, 0, sizeof storage);
  int family = UNTAG(familyv) == 4 ? AF_INET : AF_INET6, good;
  socklen_t len;
  if (family == AF_INET) {
    struct sockaddr_in *a = (struct sockaddr_in *)&storage;
    a->sin_family = family; a->sin_port = htons((uint16_t)UNTAG(portv));
    good = inet_pton(family, address, &a->sin_addr); len = sizeof *a;
  } else {
    struct sockaddr_in6 *a = (struct sockaddr_in6 *)&storage;
    a->sin6_family = family; a->sin6_port = htons((uint16_t)UNTAG(portv));
    char *scope = strchr(address, '%');
    if (scope) { *scope++ = 0; a->sin6_scope_id = if_nametoindex(scope); if (!a->sin6_scope_id) a->sin6_scope_id = (uint32_t)strtoul(scope, 0, 10); }
    good = inet_pton(family, address, &a->sin6_addr); len = sizeof *a;
  }
  free(address);
  if (good != 1) return os_err("address must be numeric");
  int fd = socket(family, SOCK_STREAM, IPPROTO_TCP);
  if (fd < 0) return os_errno();
  if (socket_nonblock(fd)) { int e = errno; close(fd); errno = e; return os_errno(); }
  int r = connect(fd, (struct sockaddr *)&storage, len);
  if (r && errno != EINPROGRESS && errno != EWOULDBLOCK && errno != EINTR) { int e = errno; connection_failure(4, fd, e); close(fd); errno = e; return os_errno(); }
  uw id = fpr_owned_add(OWN_SOCKET, fd, 0, socket_destroy);
  if (!id) { close(fd); return os_err("native resource ownership unavailable"); }
  return os_ok(TAG(id));
}
FPR_FN(fpr_g_ConnHost_x2ebegin, conn_begin, 3);
static V conn_fd(V id) {
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_SOCKET, 0, &why);
  if (!r) return os_err(why);
  int fd = r->fd; fpr_owned_unlock(); return os_ok(TAG(fd));
}
FPR_FN(fpr_g_ConnHost_x2efd, conn_fd, 1);
static V conn_status(V id) {
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_SOCKET, 0, &why);
  if (!r) return os_err(why);
  int error = 0; socklen_t n = sizeof error;
  int bad = getsockopt(r->fd, SOL_SOCKET, SO_ERROR, &error, &n);
  struct sockaddr_storage peer; n = sizeof peer;
  int connected = !bad && !error && getpeername(r->fd, (struct sockaddr *)&peer, &n) == 0;
  int saved = bad ? errno : error;
  int fd = r->fd;
  fpr_owned_unlock();
  if (saved) connection_failure(5, fd, saved);
  if (saved) { errno = saved; return os_errno(); }
  return os_ok(connected ? (V)&fpr_true : (V)&fpr_false);
}
FPR_FN(fpr_g_ConnHost_x2estatus, conn_status, 1);
static void free_buffer(void *p) { free(p); }
static V conn_read(V id, V nv) {
  if (!ISINT(nv) || UNTAG(nv) <= 0) return os_err("invalid read size");
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_SOCKET, 0, &why);
  if (!r) return os_err(why);
  struct pollfd p = {r->fd, POLLIN, 0};
  int ready = poll(&p, 1, 0);
  if (ready <= 0) { int e = errno; fpr_owned_unlock(); if (ready < 0 && e != EINTR) { errno = e; return os_errno(); } return os_err("again"); }
  size_t n = (size_t)UNTAG(nv);
  char small[4096], *buf = n <= sizeof small ? small : malloc(n);
  if (!buf) { fpr_owned_unlock(); return os_err("out of memory"); }
  ssize_t got = recv(r->fd, buf, n, 0); int saved = errno;
  fpr_owned_unlock();
  fpr_resource_t scratch;
  if (buf != small) fpr_actor_resource_add(&scratch, free_buffer, buf);
  V out;
  if (got < 0) { errno = saved; out = (saved == EINTR) ? os_err("again") : os_again_or_errno(); }
  else out = os_ok(os_str(buf, (uw)got));
  if (buf != small) { fpr_actor_resource_remove(&scratch); free(buf); }
  return out;
}
FPR_FN_CSTACK(fpr_g_ConnHost_x2eread, conn_read, 2);
static V conn_write(V id, V bytes) {
  if (ISINT(bytes) || TID(bytes) != T_STR) fpr_cpanic("connection write needs bytes");
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_SOCKET, 0, &why);
  if (!r) return os_err(why);
  str_t *s = (str_t *)bytes;
#ifdef MSG_NOSIGNAL
  ssize_t got = send(r->fd, s->bytes, s->len, MSG_NOSIGNAL);
#else
  ssize_t got = send(r->fd, s->bytes, s->len, 0);
#endif
  int saved = errno; fpr_owned_unlock();
  if (got < 0) { errno = saved; return saved == EINTR ? os_err("again") : os_again_or_errno(); }
  return os_ok(TAG(got));
}
FPR_FN(fpr_g_ConnHost_x2ewrite, conn_write, 2);
static V conn_close(V id) {
  const char *why; int fd; void *data;
  if (!fpr_owned_take(id, OWN_SOCKET, &fd, &data, &why)) return os_err(why);
  return os_unit_or_errno(close(fd));
}
FPR_FN(fpr_g_ConnHost_x2eclose, conn_close, 1);

#endif
