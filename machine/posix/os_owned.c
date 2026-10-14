/* Checked native identity and lifetime; no transfer/retry/protocol policy. */
#include "os_owned.h"
static pthread_mutex_t owned_mu = PTHREAD_MUTEX_INITIALIZER;
static fpr_owned_t *owned;
static uw serial;
static void owned_death(void *arg) {
  fpr_owned_t *r = arg;
  pthread_mutex_lock(&owned_mu);
  for (fpr_owned_t **p = &owned; *p; p = &(*p)->next)
    if (*p == r) { *p = r->next; break; }
  pthread_mutex_unlock(&owned_mu);
  r->destroy(r->data, r->fd);
  free(r);
}
uw fpr_owned_add(int kind, int fd, void *data, void (*destroy)(void *, int)) {
  fpr_owned_t *r = calloc(1, sizeof *r);
  if (!r) return 0;
  r->kind = kind; r->fd = fd; r->data = data; r->destroy = destroy;
  r->owner = fpr_hart() ? fpr_hart()->current : 0;
  if (!fpr_actor_resource_add(&r->resource, owned_death, r)) { free(r); return 0; }
  pthread_mutex_lock(&owned_mu);
  for (fpr_owned_t *p = owned; p; p = p->next)
    if (fd >= 0 && p->fd == fd) {
      pthread_mutex_unlock(&owned_mu);
      fpr_actor_resource_remove(&r->resource); free(r); return 0;
    }
  if (serial >= (uw)INTPTR_MAX / 2) {
    pthread_mutex_unlock(&owned_mu);
    fpr_actor_resource_remove(&r->resource); free(r); return 0;
  }
  r->id = ++serial; r->next = owned; owned = r;
  pthread_mutex_unlock(&owned_mu);
  return r->id; /* IDs never reuse, even when native allocations/descriptors do */
}
fpr_owned_t *fpr_owned_lock(V id, int kind, int shared, const char **why) {
  pthread_mutex_lock(&owned_mu);
  fpr_owned_t *r = owned;
  while (r && (!ISINT(id) || r->id != (uw)UNTAG(id))) r = r->next;
  if (!r || r->kind != kind) *why = "closed";
  else if (!shared && r->owner != (fpr_hart() ? fpr_hart()->current : 0)) *why = "wrong owner";
  else return r;
  pthread_mutex_unlock(&owned_mu); return 0;
}
void fpr_owned_unlock(void) { pthread_mutex_unlock(&owned_mu); }
int fpr_owned_take(V id, int kind, int *fd, void **data, const char **why) {
  fpr_owned_t *r = fpr_owned_lock(id, kind, 0, why);
  if (!r) return 0;
  for (fpr_owned_t **p = &owned; *p; p = &(*p)->next)
    if (*p == r) { *p = r->next; break; }
  fpr_actor_resource_remove(&r->resource);
  *fd = r->fd; *data = r->data;
  fpr_owned_unlock(); free(r); return 1;
}
int fpr_owned_close(V id, int kind, const char **why) {
  fpr_owned_t *r = fpr_owned_lock(id, kind, 0, why);
  if (!r) return 0;
  void (*destroy)(void *, int) = r->destroy;
  fpr_owned_unlock();
  int fd; void *data;
  if (!fpr_owned_take(id, kind, &fd, &data, why)) return 0;
  destroy(data, fd); return 1;
}
