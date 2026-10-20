/* Optional OpenSSL 3 adapter, linked with --with. Every engine operation,
 * trust-file read and context teardown runs on the connection's worker, never
 * a hart. Buffers are native-owned across WANT retries. Protocol, readiness,
 * deadlines, cancellation and chunk policy are FP-RISC's. */
#include "os_owned.h"
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>
#include <arpa/inet.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>
static uw tls_active;
/* Numeric native failures only: no peer names, paths, payloads or credentials.
 * Per-operation exponential sampling retains first failures without an
 * unbounded log stream during repeated upstream outages. */
static void tls_failure(int operation, int error, long verify) {
  static unsigned long counts[5];
  unsigned index = operation >= 1 && operation <= 5 ? (unsigned)operation - 1 : 4;
  unsigned long n = __atomic_add_fetch(&counts[index], 1, __ATOMIC_RELAXED);
  if (n && (n <= 4 || !(n & (n - 1))))
    fprintf(stderr, "TLS failure op=%d count=%lu errno=%d verify=%ld\n",
            operation, n, error, verify);
  errno = error;
}
static int tls_admit(uw capacity) {
  uw count = __atomic_load_n(&tls_active, __ATOMIC_ACQUIRE);
  while (count < capacity)
    if (__atomic_compare_exchange_n(&tls_active, &count, count + 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return 1;
  return 0;
}
typedef struct {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int fd, started, closing, command, operation, busy, ready, result, failed;
  int minimum, read_retry;
  size_t read_length;
  SSL_CTX *ctx;
  SSL *ssl;
  char *peer, *ca, *writebuf, *readbuf;
  size_t length, transferred;
  char error[256];
} tls_t;
static void tls_free(tls_t *t) {
  if (t->ssl) SSL_free(t->ssl);
  if (t->ctx) SSL_CTX_free(t->ctx);
  close(t->fd); free(t->peer); free(t->ca); free(t->writebuf); free(t->readbuf);
  pthread_cond_destroy(&t->cv); pthread_mutex_destroy(&t->mu); free(t);
  __atomic_fetch_sub(&tls_active, 1, __ATOMIC_ACQ_REL);
}
static void tls_destroy(void *arg, int fd) {
  (void)fd; tls_t *t = arg;
  pthread_mutex_lock(&t->mu);
  t->closing = 1;
  /* Retire peer I/O immediately, but keep the descriptor number reserved
   * until an in-flight engine call releases it. Never close/reuse under SSL. */
  shutdown(t->fd, SHUT_RDWR);
  int started = t->started;
  pthread_cond_signal(&t->cv);
  pthread_mutex_unlock(&t->mu);
  if (!started) tls_free(t);
}
static int tls_init(tls_t *t) {
  t->ctx = SSL_CTX_new(TLS_client_method());
  if (!t->ctx) return 0;
  if (!SSL_CTX_set_min_proto_version(t->ctx, t->minimum)) return 0;
  SSL_CTX_set_verify(t->ctx, SSL_VERIFY_PEER, 0);
  if (*t->ca ? !SSL_CTX_load_verify_locations(t->ctx, t->ca, 0) : !SSL_CTX_set_default_verify_paths(t->ctx)) return 0;
  t->ssl = SSL_new(t->ctx);
  if (!t->ssl || !SSL_set_fd(t->ssl, t->fd)) return 0;
  unsigned char address[16];
  if (inet_pton(AF_INET, t->peer, address) == 1 || inet_pton(AF_INET6, t->peer, address) == 1) {
    if (!X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(t->ssl), t->peer)) return 0;
  } else {
    if (!SSL_set1_host(t->ssl, t->peer) || !SSL_set_tlsext_host_name(t->ssl, t->peer)) return 0;
    X509_VERIFY_PARAM_set_hostflags(SSL_get0_param(t->ssl), X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
  }
  SSL_set_connect_state(t->ssl);
  return 1;
}
static void *tls_worker(void *arg) {
  tls_t *t = arg;
  sigset_t signals; sigemptyset(&signals); sigaddset(&signals, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &signals, 0);
  for (;;) {
    pthread_mutex_lock(&t->mu);
    while (!t->command && !t->closing) pthread_cond_wait(&t->cv, &t->mu);
    if (t->closing) { pthread_mutex_unlock(&t->mu); break; }
    int op = t->command; t->command = 0;
    pthread_mutex_unlock(&t->mu);
    ERR_clear_error(); errno = 0;
    int r, code = 3; size_t transferred = 0;
    if (op == 1) { r = tls_init(t); if (!r) code = -1; }
    else if (op == 2) r = SSL_do_handshake(t->ssl);
    else if (op == 3) r = SSL_read_ex(t->ssl, t->readbuf, t->read_length, &transferred);
    else if (op == 4) r = SSL_write_ex(t->ssl, t->writebuf, t->length, &transferred);
    else r = SSL_shutdown(t->ssl);
    if (op != 1 && r <= 0) {
      int e = SSL_get_error(t->ssl, r); /* same worker, before any other SSL call */
      if (op == 5 && r == 0) code = 1; /* close_notify sent: wait for peer's */
      else if (e == SSL_ERROR_WANT_READ) code = 1;
      else if (e == SSL_ERROR_WANT_WRITE) code = 2;
      else if (op == 3 && e == SSL_ERROR_ZERO_RETURN) code = 4;
      else code = -1;
    }
    char message[256] = "TLS operation failed";
    if (code < 0) {
      int saved_errno = errno;
      tls_failure(op, saved_errno, t->ssl ? SSL_get_verify_result(t->ssl) : -1L);
      unsigned long error = ERR_get_error();
      if (error) ERR_error_string_n(error, message, sizeof message);
      else if (errno) snprintf(message, sizeof message, "TLS I/O: %s", strerror(errno));
      if (t->ssl && SSL_get_verify_result(t->ssl) != X509_V_OK)
        snprintf(message, sizeof message, "certificate verify failed: %s", X509_verify_cert_error_string(SSL_get_verify_result(t->ssl)));
    }
    pthread_mutex_lock(&t->mu);
    t->result = code; t->transferred = transferred;
    if (code < 0) { t->failed = 1; memcpy(t->error, message, sizeof message); }
    t->busy = 0; t->ready = 1;
    pthread_mutex_unlock(&t->mu);
  }
  tls_free(t); return 0;
}
static V tls_start(V socket, V peer, V ca, V minimum, V capacity) {
  if (!ISINT(minimum) || (UNTAG(minimum) != TLS1_2_VERSION && UNTAG(minimum) != TLS1_3_VERSION)) return os_err("unsupported TLS minimum version");
  if (!ISINT(capacity) || UNTAG(capacity) < 1) return os_err("invalid TLS worker capacity");
  char *name = os_cstr(peer, "TLS peer must be text"), *roots = os_cstr(ca, "TLS CA file must be text");
  if (!*name || strlen(name) != ((str_t *)peer)->len || strlen(roots) != ((str_t *)ca)->len) { free(name); free(roots); return os_err("invalid TLS peer or CA path"); }
  if (!tls_admit((uw)UNTAG(capacity))) { free(name); free(roots); return os_err("TLS worker pool busy"); }
  tls_t *t = calloc(1, sizeof *t);
  if (!t) { __atomic_fetch_sub(&tls_active, 1, __ATOMIC_ACQ_REL); free(name); free(roots); return os_err("out of memory"); }
  int e = pthread_mutex_init(&t->mu, 0);
  if (e) { __atomic_fetch_sub(&tls_active, 1, __ATOMIC_ACQ_REL); free(name); free(roots); free(t); return os_err(strerror(e)); }
  e = pthread_cond_init(&t->cv, 0);
  if (e) { __atomic_fetch_sub(&tls_active, 1, __ATOMIC_ACQ_REL); pthread_mutex_destroy(&t->mu); free(name); free(roots); free(t); return os_err(strerror(e)); }
  const char *why; void *unused;
  if (!fpr_owned_take(socket, OWN_SOCKET, &t->fd, &unused, &why)) { __atomic_fetch_sub(&tls_active, 1, __ATOMIC_ACQ_REL); pthread_cond_destroy(&t->cv); pthread_mutex_destroy(&t->mu); free(name); free(roots); free(t); return os_err(why); }
  t->peer = name; t->ca = roots; t->minimum = (int)UNTAG(minimum);
  uw id = fpr_owned_add(OWN_TLS, t->fd, t, tls_destroy);
  if (!id) { tls_free(t); return os_err("native resource ownership unavailable"); }
  pthread_attr_t attr;
  e = pthread_attr_init(&attr);
  if (!e) {
    e = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (!e) e = pthread_attr_setstacksize(&attr, 512 * 1024);
    pthread_t thread;
    /* Hold the mutex through publication, so death cannot race worker start. */
    pthread_mutex_lock(&t->mu);
    if (!e) e = pthread_create(&thread, &attr, tls_worker, t);
    if (!e) t->started = 1;
    pthread_mutex_unlock(&t->mu);
    pthread_attr_destroy(&attr);
  }
  if (e) { fpr_owned_close(TAG(id), OWN_TLS, &why); return os_err(strerror(e)); }
  return os_ok(TAG(id));
}
FPR_FN(fpr_g_TlsHost_x2estart, tls_start, 5);
static V tls_fd(V id) {
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_TLS, 0, &why);
  if (!r) return os_err(why);
  int fd = r->fd; fpr_owned_unlock(); return os_ok(TAG(fd));
}
FPR_FN(fpr_g_TlsHost_x2efd, tls_fd, 1);
static void free_result(void *p) { free(p); }
static V tls_step(V id, V opv, V bytes, V count) {
  if (!ISINT(opv) || UNTAG(opv) < 1 || UNTAG(opv) > 5 || !ISINT(count) || UNTAG(count) < 0) return os_err("invalid TLS step");
  if (ISINT(bytes) || TID(bytes) != T_STR) fpr_cpanic("TLS step needs bytes");
  int op = (int)UNTAG(opv);
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_TLS, 0, &why);
  if (!r) return os_err(why);
  tls_t *t = r->data; pthread_mutex_lock(&t->mu);
  char error[256] = ""; int code = 0; size_t transferred = 0; char *result = 0;
  if (op != 1 && !t->busy && !t->ssl) snprintf(error, sizeof error, "TLS not initialised");
  else if (t->closing) snprintf(error, sizeof error, "closed");
  else if (t->operation && t->operation != op) snprintf(error, sizeof error, "resume or close the pending TLS operation");
  else if (t->operation && (op == 3 || op == 4) &&
           (t->length != (op == 3 ? (size_t)UNTAG(count) : ((str_t *)bytes)->len) ||
            (op == 4 && memcmp(t->writebuf, ((str_t *)bytes)->bytes, t->length))))
    snprintf(error, sizeof error, "TLS retry bytes/size changed");
  else if (t->ready) {
    code = t->result; transferred = t->transferred; t->ready = 0;
    if (code < 0) snprintf(error, sizeof error, "%s", t->error);
    if (op == 3 && code == 1) {
      /* SSL_read WANT_READ may be interleaved with a write. Keep the exact
       * native read buffer/size for its retry; this permits MQTT keepalive. */
      t->read_retry = 1; t->operation = 0; t->length = 0;
    }
    if (code == 3 || code == 4) {
      if (op == 3) { result = t->readbuf; t->readbuf = 0; t->read_retry = 0; t->read_length = 0; }
      free(t->writebuf); t->writebuf = 0; t->operation = 0; t->length = 0;
    }
  } else if (t->failed) snprintf(error, sizeof error, "%s", t->error);
  else if (!t->busy) {
    str_t *input = (str_t *)bytes;
    size_t length = op == 4 ? input->len : (size_t)UNTAG(count);
    if (t->operation && (t->length != length || (op == 4 && memcmp(t->writebuf, input->bytes, length)))) snprintf(error, sizeof error, "TLS retry bytes/size changed");
    else if (!t->operation) {
      if ((op == 3 || op == 4) && !length) snprintf(error, sizeof error, "empty TLS transfer");
      else {
        if (op == 3) {
          if (t->read_retry && t->read_length != length) snprintf(error, sizeof error, "TLS read retry size changed");
          else if (!t->read_retry) { t->readbuf = malloc(length); t->read_length = length; }
        }
        if (op == 4) { t->writebuf = malloc(length); if (t->writebuf) memcpy(t->writebuf, input->bytes, length); }
        if ((op == 3 && !t->readbuf) || (op == 4 && !t->writebuf)) snprintf(error, sizeof error, "out of memory");
        else if (!*error) { t->operation = op; t->length = length; if (op == 3) t->read_retry = 0; }
      }
    }
    if (!*error) { t->command = op; t->busy = 1; pthread_cond_signal(&t->cv); }
  }
  pthread_mutex_unlock(&t->mu); fpr_owned_unlock();
  fpr_resource_t scratch;
  if (result) fpr_actor_resource_add(&scratch, free_result, result);
  V out;
  if (*error) out = os_err(error);
  else { V fields[3] = {TAG(code), os_str(result ? result : "", op == 3 ? transferred : 0), TAG(transferred)}; out = os_ok(os_cell(T_TUP3, 0, 3, fields)); }
  if (result) { fpr_actor_resource_remove(&scratch); free(result); }
  return out;
}
FPR_FN_CSTACK(fpr_g_TlsHost_x2estep, tls_step, 4);
static V tls_close(V id) { const char *why; return fpr_owned_close(id, OWN_TLS, &why) ? os_ok((V)&fpr_unit) : os_err(why); }
FPR_FN(fpr_g_TlsHost_x2eclose, tls_close, 1);

static V tls_pending(V id) {
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_TLS, 0, &why);
  if (!r) return os_err(why);
  tls_t *t = r->data; pthread_mutex_lock(&t->mu);
  int op = t->operation;
  pthread_mutex_unlock(&t->mu); fpr_owned_unlock(); return os_ok(TAG(op));
}
FPR_FN(fpr_g_TlsHost_x2epending, tls_pending, 1);
