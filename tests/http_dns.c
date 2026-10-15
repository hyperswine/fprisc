/* Test routing only: verify server.example's published fixture certificate
 * while dialing loopback. Production HTTP always verifies its URL host. */
#include <netdb.h>
#include <string.h>
int fpr_dns_lookup(const char *host, const char *port,
                   const struct addrinfo *hints, struct addrinfo **out) {
  if (!strcmp(host, "server.example") || !strcmp(host, "wrong.example")) host = "127.0.0.1";
  return getaddrinfo(host, port, hints, out);
}
