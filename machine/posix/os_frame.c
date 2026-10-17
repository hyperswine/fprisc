/* Bounded byte storage only. Framing/transport/admission policy is FP-RISC. */
#include "os_owned.h"
#define FRAME_MAX (4u * 1024u * 1024u)
#define FRAME_TOTAL (32u * 1024u * 1024u)
#define FRAME_SLOTS 16u
typedef struct { fpr_resource_t snapshot; size_t cap, used; unsigned char bytes[]; } frame_t;
static pthread_mutex_t frame_mu = PTHREAD_MUTEX_INITIALIZER;
static size_t frame_count, frame_bytes, frame_peak;
static void frame_destroy(void *data, int fd) {
  (void)fd; frame_t *b = data;
  pthread_mutex_lock(&frame_mu);
  frame_count--; frame_bytes -= b->cap;
  pthread_mutex_unlock(&frame_mu);
  free(b);
}
static void frame_scratch(void *data) { frame_destroy(data, -1); }
static V frame_create(V size) {
  if (!ISINT(size) || UNTAG(size) < 4 || UNTAG(size) > FRAME_MAX)
    return os_err("invalid frame capacity");
  size_t n = (size_t)UNTAG(size);
  pthread_mutex_lock(&frame_mu);
  if (frame_count >= FRAME_SLOTS || n > FRAME_TOTAL - frame_bytes) {
    pthread_mutex_unlock(&frame_mu); return os_err("frame buffer capacity exhausted");
  }
  frame_count++; frame_bytes += n;
  if (frame_bytes > frame_peak) frame_peak = frame_bytes;
  pthread_mutex_unlock(&frame_mu);
  frame_t *b = malloc(sizeof *b + n);
  if (!b) {
    pthread_mutex_lock(&frame_mu); frame_count--; frame_bytes -= n; pthread_mutex_unlock(&frame_mu);
    return os_err("frame allocation failed");
  }
  b->cap = n; b->used = 0;
  uw id = fpr_owned_add(OWN_FRAME, -1, b, frame_destroy);
  if (!id) { frame_destroy(b, -1); return os_err("frame ownership unavailable"); }
  return os_ok(TAG(id));
}
FPR_FN(fpr_g_FrameHost_x2ecreate, frame_create, 1);
static V frame_append(V id, V bytes) {
  if (ISINT(bytes) || TID(bytes) != T_STR) return os_err("frame append needs bytes");
  str_t *s = (str_t *)bytes;
  if (!s->len || s->len > 16384) return os_err("frame chunk must contain 1..16384 bytes");
  const char *why; fpr_owned_t *r = fpr_owned_lock(id, OWN_FRAME, 0, &why);
  if (!r) return os_err(why);
  frame_t *b = r->data;
  if (s->len > b->cap - b->used) { fpr_owned_unlock(); return os_err("frame capacity exceeded"); }
  memcpy(b->bytes + b->used, s->bytes, s->len); b->used += s->len;
  fpr_owned_unlock(); return os_ok((V)&fpr_unit);
}
FPR_FN(fpr_g_FrameHost_x2eappend, frame_append, 2);
static V frame_finish(V id) {
  const char *why; int fd; void *data;
  if (!fpr_owned_take(id, OWN_FRAME, &fd, &data, &why)) return os_err(why);
  frame_t *b = data;
  if (b->used != b->cap) {
    frame_destroy(b, -1); return os_err("incomplete frame buffer");
  }
  /* Allocating FP-RISC output can panic: install death cleanup before doing
   * so, outside the registry mutex. The payload remains accounted meanwhile. */
  /* CSTACK is shared host storage: the cleanup node must live in the owned
   * allocation, never in this function's stack frame. */
  if (!fpr_actor_resource_add(&b->snapshot, frame_scratch, b)) {
    frame_destroy(b, -1); return os_err("frame cleanup unavailable");
  }
  V output = os_ok(os_str((const char *)b->bytes, b->used));
  fpr_actor_resource_remove(&b->snapshot); frame_destroy(b, -1); return output;
}
FPR_FN_CSTACK(fpr_g_FrameHost_x2efinish, frame_finish, 1);
static V frame_close(V id) {
  const char *why;
  return fpr_owned_close(id, OWN_FRAME, &why) ? os_ok((V)&fpr_unit) : os_err(why);
}
FPR_FN(fpr_g_FrameHost_x2eclose, frame_close, 1);
static V frame_usage(V unit) {
  (void)unit;
  pthread_mutex_lock(&frame_mu);
  V values[3] = {TAG(frame_count), TAG(frame_bytes), TAG(frame_peak)};
  pthread_mutex_unlock(&frame_mu);
  return os_cell(T_TUP3, 0, 3, values);
}
FPR_FN(fpr_g_FrameHost_x2eusage, frame_usage, 1);
