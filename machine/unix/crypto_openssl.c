/* Optional crypto mechanism. Entropy and EVP verification run off-hart.
 * FP-RISC supplies admission, input bounds, deadlines and auth policy. */
#include "os_owned.h"
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>
#include <limits.h>
static uw crypto_active;
typedef struct {
  pthread_mutex_t mu;
  int refs, done, verified, failed, random;
  unsigned char *key, *message, *signature, *output;
  size_t key_n, message_n, signature_n, output_n;
} crypto_job;
static void crypto_dispose(crypto_job *j) {
  OPENSSL_clear_free(j->output, j->output_n);
  free(j->key); free(j->message); free(j->signature);
  pthread_mutex_destroy(&j->mu); free(j);
  __atomic_fetch_sub(&crypto_active, 1, __ATOMIC_ACQ_REL);
}
static void crypto_put(crypto_job *j) {
  pthread_mutex_lock(&j->mu);
  int last = --j->refs == 0;
  pthread_mutex_unlock(&j->mu);
  if (last) crypto_dispose(j);
}
static void crypto_destroy(void *p, int fd) { (void)fd; crypto_put(p); }
static void *crypto_work(void *p) {
  crypto_job *j = p;
  int result = 0, failed = 0;
  if (j->random) failed = RAND_bytes(j->output, (int)j->output_n) != 1;
  else {
    EVP_PKEY *key = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, j->key, j->key_n);
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!key || !ctx || EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, key) != 1) failed = 1;
    else { int r = EVP_DigestVerify(ctx, j->signature, j->signature_n, j->message, j->message_n); result = r == 1; failed = r < 0; }
    EVP_MD_CTX_free(ctx); EVP_PKEY_free(key);
  }
  pthread_mutex_lock(&j->mu);
  j->verified = result; j->failed = failed; j->done = 1;
  /* Publish completion together with releasing the worker's reference. An
   * owner observing done can then close and immediately reuse its capacity. */
  int last = --j->refs == 0;
  pthread_mutex_unlock(&j->mu);
  if (last) crypto_dispose(j);
  return NULL;
}
static crypto_job *crypto_new(V cap) {
  if (!ISINT(cap) || UNTAG(cap) < 1) return NULL;
  uw count = __atomic_load_n(&crypto_active, __ATOMIC_ACQUIRE);
  while (count < (uw)UNTAG(cap)) {
    if (__atomic_compare_exchange_n(&crypto_active, &count, count+1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
      crypto_job *j = calloc(1, sizeof *j);
      if (!j) { __atomic_fetch_sub(&crypto_active,1,__ATOMIC_ACQ_REL); return NULL; }
      if (pthread_mutex_init(&j->mu,0)) { free(j); __atomic_fetch_sub(&crypto_active,1,__ATOMIC_ACQ_REL); return NULL; }
      j->refs=1; return j;
    }
  }
  return NULL;
}
static int copy_bytes(V v, unsigned char **out, size_t *n) {
  if (ISINT(v) || TID(v)!=T_STR) return 0;
  str_t *s=(str_t *)v; *n=s->len; *out=malloc(*n ? *n : 1);
  if (!*out) return 0; memcpy(*out,s->bytes,*n); return 1;
}
static V crypto_start(crypto_job *j) {
  uw id=fpr_owned_add(OWN_CRYPTO,-1,j,crypto_destroy);
  if (!id) { crypto_put(j); return os_err("native crypto ownership unavailable"); }
  pthread_attr_t attr;
  int e=pthread_attr_init(&attr);
  if (!e) {
    e=pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);
    if (!e) e=pthread_attr_setstacksize(&attr,256*1024);
    if (!e) { pthread_t thread; j->refs++; e=pthread_create(&thread,&attr,crypto_work,j); if(e)j->refs--; }
    pthread_attr_destroy(&attr);
  }
  if(e){const char *why;fpr_owned_close(TAG(id),OWN_CRYPTO,&why);return os_err("native crypto worker unavailable");}
  return os_ok(TAG(id));
}
static V verify_begin(V key,V message,V signature,V cap) {
  crypto_job *j=crypto_new(cap); if(!j)return os_err("native crypto busy");
  if(!copy_bytes(key,&j->key,&j->key_n)||!copy_bytes(message,&j->message,&j->message_n)||!copy_bytes(signature,&j->signature,&j->signature_n)){
    crypto_put(j);return os_err("invalid crypto input");}
  return crypto_start(j);
}
FPR_FN(fpr_g_CryptoHost_x2everifyBegin,verify_begin,4);
static V random_begin(V count,V cap) {
  if(!ISINT(count)||UNTAG(count)<1||UNTAG(count)>INT_MAX)return os_err("invalid entropy length");
  crypto_job *j=crypto_new(cap);if(!j)return os_err("native crypto busy");
  j->random=1;j->output_n=(size_t)UNTAG(count);j->output=OPENSSL_malloc(j->output_n);
  if(!j->output){crypto_put(j);return os_err("native crypto allocation refused");}
  return crypto_start(j);
}
FPR_FN(fpr_g_CryptoHost_x2erandomBegin,random_begin,2);
static V crypto_poll(V id) {
  const char *why; fpr_owned_t *owned=fpr_owned_lock(id,OWN_CRYPTO,0,&why);
  if(!owned)return os_err(why);
  crypto_job *j=owned->data;
  pthread_mutex_lock(&j->mu); fpr_owned_unlock();
  int done=j->done,failed=j->failed,verified=j->verified;
  unsigned char *copy=NULL;size_t n=j->output_n;
  if(done&&!failed&&n){copy=malloc(n);if(copy)memcpy(copy,j->output,n);else failed=1;}
  pthread_mutex_unlock(&j->mu);
  if(!done)return os_err("again");
  if(failed){free(copy);return os_err("native crypto operation failed");}
  V fields[2]={verified ? (V)&fpr_true : (V)&fpr_false,os_str((const char *)(copy?copy:(unsigned char *)""),n)};
  if(copy){OPENSSL_cleanse(copy,n);free(copy);}
  return os_ok(os_cell(T_TUP2,0,2,fields));
}
FPR_FN(fpr_g_CryptoHost_x2epoll,crypto_poll,1);
static V crypto_close(V id){const char *why;return fpr_owned_close(id,OWN_CRYPTO,&why)?os_ok((V)&fpr_unit):os_err(why);}
FPR_FN(fpr_g_CryptoHost_x2eclose,crypto_close,1);
