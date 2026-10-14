/* OS resolver work outside harts. Pool capacity comes from FP-RISC. Abandon
 * drops the caller's lease; the uncancellable OS call owns its buffers until
 * completion and still occupies a pool slot. There is no unbounded queue. */
#include "os_owned.h"
#ifdef FPR_ESP_IDF
static V unavailable_pool(V a0) { (void)a0; return os_err("DnsHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_DnsHost_x2epool, unavailable_pool, 1);
static V unavailable_begin(V a0, V a1, V a2) { (void)a0; (void)a1; (void)a2; return os_err("DnsHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_DnsHost_x2ebegin, unavailable_begin, 3);
static V unavailable_poll(V a0) { (void)a0; return os_err("DnsHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_DnsHost_x2epoll, unavailable_poll, 1);
static V unavailable_abandon(V a0) { (void)a0; return os_err("DnsHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_DnsHost_x2eabandon, unavailable_abandon, 1);
static V unavailable_close(V a0) { (void)a0; return os_err("DnsHost: native adapter unavailable on ESP-IDF"); }
FPR_FN(fpr_g_DnsHost_x2eclose, unavailable_close, 1);
#else

#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <sys/socket.h>
typedef struct { pthread_mutex_t mu; size_t limit, active, refs; int closed; } dns_pool_t;
typedef struct {
  pthread_mutex_t mu;
  size_t refs;
  int done, error;
  struct addrinfo *addresses;
  dns_pool_t *pool;
  char *host;
  char port[16];
} dns_job_t;
/* Weak syscall seam for deterministic stalled-resolver tests. */
__attribute__((weak)) int fpr_dns_lookup(const char *host, const char *port,
                                        const struct addrinfo *hints, struct addrinfo **out) {
  return getaddrinfo(host, port, hints, out);
}
static void pool_put(dns_pool_t *p, int finished) {
  pthread_mutex_lock(&p->mu);
  if (finished) p->active--;
  int dispose = --p->refs == 0;
  pthread_mutex_unlock(&p->mu);
  if (dispose) { pthread_mutex_destroy(&p->mu); free(p); }
}
static void pool_destroy(void *arg, int fd) {
  (void)fd; dns_pool_t *p = arg;
  pthread_mutex_lock(&p->mu); p->closed = 1; pthread_mutex_unlock(&p->mu);
  pool_put(p, 0);
}
static void job_put(dns_job_t *j) {
  pthread_mutex_lock(&j->mu); int dispose = --j->refs == 0; pthread_mutex_unlock(&j->mu);
  if (dispose) { if (j->addresses) freeaddrinfo(j->addresses); free(j->host); pthread_mutex_destroy(&j->mu); free(j); }
}
static void job_destroy(void *arg, int fd) { (void)fd; job_put(arg); }
static void *resolve_worker(void *arg) {
  dns_job_t *j = arg;
  struct addrinfo hints = {0}, *addresses = 0;
  hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP;
  int error = fpr_dns_lookup(j->host, j->port, &hints, &addresses);
  pthread_mutex_lock(&j->mu);
  j->addresses = addresses; j->error = error; j->done = 1;
  pthread_mutex_unlock(&j->mu);
  pool_put(j->pool, 1); job_put(j); return 0;
}
static V dns_pool(V count) {
  if (!ISINT(count) || UNTAG(count) < 1) return os_err("resolver capacity must be positive");
  dns_pool_t *p = calloc(1, sizeof *p);
  if (!p) return os_err("out of memory");
  int e = pthread_mutex_init(&p->mu, 0);
  if (e) { free(p); return os_err(strerror(e)); }
  p->limit = (size_t)UNTAG(count); p->refs = 1;
  uw id = fpr_owned_add(OWN_DNS_POOL, -1, p, pool_destroy);
  if (!id) { pool_destroy(p, -1); return os_err("native resource ownership unavailable"); }
  return os_ok(TAG(id));
}
FPR_FN(fpr_g_DnsHost_x2epool, dns_pool, 1);
static V dns_begin(V pool, V host, V port) {
  if (!ISINT(port) || UNTAG(port) < 1 || UNTAG(port) > 65535) return os_err("invalid TCP port");
  char *name = os_cstr(host, "resolver host must be text");
  if (strlen(name) != ((str_t *)host)->len || !*name) { free(name); return os_err("invalid host name"); }
  const char *why; fpr_owned_t *owned = fpr_owned_lock(pool, OWN_DNS_POOL, 1, &why);
  if (!owned) { free(name); return os_err(why); }
  dns_pool_t *p = owned->data;
  pthread_mutex_lock(&p->mu);
  if (p->closed || p->active >= p->limit) { pthread_mutex_unlock(&p->mu); fpr_owned_unlock(); free(name); return os_err("resolver busy"); }
  p->active++; p->refs++;
  pthread_mutex_unlock(&p->mu); fpr_owned_unlock();
  dns_job_t *j = calloc(1, sizeof *j);
  if (!j) { pool_put(p, 1); free(name); return os_err("out of memory"); }
  int e = pthread_mutex_init(&j->mu, 0);
  if (e) { pool_put(p, 1); free(name); free(j); return os_err(strerror(e)); }
  j->pool = p; j->host = name; j->refs = 2;
  snprintf(j->port, sizeof j->port, "%ld", (long)UNTAG(port));
  uw id = fpr_owned_add(OWN_DNS_JOB, -1, j, job_destroy);
  if (!id) { pool_put(p, 1); job_put(j); job_put(j); return os_err("native resource ownership unavailable"); }
  pthread_attr_t attr;
  e = pthread_attr_init(&attr);
  if (!e) {
    e = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (!e) e = pthread_attr_setstacksize(&attr, 256 * 1024);
    pthread_t thread;
    if (!e) e = pthread_create(&thread, &attr, resolve_worker, j);
    pthread_attr_destroy(&attr);
  }
  if (e) { fpr_owned_close(TAG(id), OWN_DNS_JOB, &why); pool_put(p, 1); job_put(j); return os_err(strerror(e)); }
  return os_ok(TAG(id));
}
FPR_FN(fpr_g_DnsHost_x2ebegin, dns_begin, 3);
static void snapshot_free(void *arg) { free(arg); }
static V dns_poll(V id) {
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_DNS_JOB, 0, &why);
  if (!r) return os_err(why);
  dns_job_t *j = r->data;
  pthread_mutex_lock(&j->mu);
  if (!j->done) { pthread_mutex_unlock(&j->mu); fpr_owned_unlock(); return os_err("again"); }
  int error = j->error;
  size_t n = 0;
  for (struct addrinfo *a = j->addresses; a; a = a->ai_next) if (a->ai_family == AF_INET || a->ai_family == AF_INET6) n++;
  struct sockaddr_storage *copy = calloc(n ? n : 1, sizeof *copy);
  if (copy) {
    size_t i = 0;
    for (struct addrinfo *a = j->addresses; a; a = a->ai_next)
      if (a->ai_family == AF_INET || a->ai_family == AF_INET6) memcpy(&copy[i++], a->ai_addr, a->ai_addrlen);
  }
  pthread_mutex_unlock(&j->mu); fpr_owned_unlock();
  if (!copy) return os_err("out of memory");
  fpr_resource_t scratch; fpr_actor_resource_add(&scratch, snapshot_free, copy);
  V out = (V)&os_nil;
  if (error) {
#ifdef FPR_ESP_IDF
    out = os_err("address lookup failed");
#else
    out = os_err(gai_strerror(error));
#endif
  } else {
    for (size_t i = n; i-- > 0;) {
      char text[INET6_ADDRSTRLEN + 24]; int family = copy[i].ss_family;
      const void *address = family == AF_INET ? (void *)&((struct sockaddr_in *)&copy[i])->sin_addr : (void *)&((struct sockaddr_in6 *)&copy[i])->sin6_addr;
      if (!inet_ntop(family, address, text, sizeof text)) continue;
      if (family == AF_INET6) {
        unsigned scope = ((struct sockaddr_in6 *)&copy[i])->sin6_scope_id;
        if (scope) snprintf(text + strlen(text), sizeof text - strlen(text), "%%%u", scope);
      }
      V pair[2] = {TAG(family == AF_INET ? 4 : 6), os_str(text, (uw)strlen(text))};
      out = os_cons(os_cell(T_TUP2, 0, 2, pair), out);
    }
    out = os_ok(out);
  }
  fpr_actor_resource_remove(&scratch); free(copy); return out;
}
FPR_FN_CSTACK(fpr_g_DnsHost_x2epoll, dns_poll, 1);
static V dns_abandon(V id) { const char *why; return fpr_owned_close(id, OWN_DNS_JOB, &why) ? os_ok((V)&fpr_unit) : os_err(why); }
FPR_FN(fpr_g_DnsHost_x2eabandon, dns_abandon, 1);
static V dns_close(V id) { const char *why; return fpr_owned_close(id, OWN_DNS_POOL, &why) ? os_ok((V)&fpr_unit) : os_err(why); }
FPR_FN(fpr_g_DnsHost_x2eclose, dns_close, 1);

#endif
