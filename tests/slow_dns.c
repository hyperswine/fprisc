/* A test-only OS resolver stall; never linked into an application. */
#include <netdb.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include "os_value.h"
int fpr_dns_lookup(const char *host, const char *port, const struct addrinfo *hints, struct addrinfo **out) {
  if (!strcmp(host, "fpr-delay.invalid")) { usleep(200000); host = "127.0.0.1"; }
  return getaddrinfo(host, port, hints, out);
}
/* Deterministically reuse a closed descriptor in this disposable test process.
 * Refuse to overwrite anything still open. Never linked into an application. */
static V reuse_pair(V fdv) {
  if (!ISINT(fdv) || UNTAG(fdv) < 3) return os_err("invalid test descriptor");
  int target = (int)UNTAG(fdv);
  if (fcntl(target, F_GETFD) >= 0 || errno != EBADF) return os_err("test descriptor still open");
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return os_errno();
  if (pair[0] != target) {
    if (pair[1] == target) { int tmp = pair[0]; pair[0] = pair[1]; pair[1] = tmp; }
    else {
      if (dup2(pair[0], target) < 0) { int e = errno; close(pair[0]); close(pair[1]); errno = e; return os_errno(); }
      close(pair[0]); pair[0] = target;
    }
  }
  V fields[2] = {TAG(pair[0]), TAG(pair[1])};
  return os_ok(os_cell(T_TUP2, 0, 2, fields));
}
FPR_FN(fpr_g_ReuseHost_x2eopen, reuse_pair, 1);
