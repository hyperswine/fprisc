/* BSD socket facilities. Host availability does not imply an active network. */
#include "os_value.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

/* lwIP provides getaddrinfo but IDF 5.3.2 does not link gai_strerror. */
static V os_gai_error(int code) {
#ifdef ESP_PLATFORM
  char message[64];
  snprintf(message, sizeof message, "address lookup failed (%d)", code);
  return os_err(message);
#else
  return os_err(gai_strerror(code));
#endif
}

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
  if (g) return os_gai_error(g);
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
  if (g) return os_gai_error(g);
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
