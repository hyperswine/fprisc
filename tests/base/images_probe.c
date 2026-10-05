/* images_probe.c -- a FAKE process image for tests/base/images.fpr: a buddy
 * block registered as process 7's image (fpr_image_add), holding cells laid
 * out the way an image's statics are -- a string and a function value with
 * no allocation preheader.  The test's actors are process 0, so both are
 * another process's statics to them. */
#include "fpr.h"
static fpr_image_t g_im;
static char *g_blk;
static V probe_make(V u) {
  (void)u;
  g_blk = (char *)buddy_alloc(4096);
  if (!g_blk) fpr_cpanic("probe: no block");
  const char *msg = "from the image";
  str_t *s = (str_t *)(g_blk + 64);
  s->tid = T_STR; s->var = 0; s->len = 14;
  for (int i = 0; i < 14; i++) s->bytes[i] = (uint8_t)msg[i];
  pap_t *p = (pap_t *)(g_blk + 256);
  p->tid = T_PAP; p->var = 0;
  p->fn = (uw)(g_blk + 1024); /* "code" in the image: never called */
  p->arity = 1; p->nargs = 0;
  g_im.lo = g_blk - sizeof(uw);
  g_im.hi = g_blk + buddy_block_usable_size(g_blk);
  g_im.pid = 7;
  g_im.owner = 0;
  fpr_image_add(&g_im);
  return TAG(0);
}
static V probe_str(V u) { (void)u; return (V)(g_blk + 64); }
static V probe_fn(V u) { (void)u; return (V)(g_blk + 256); }
/* Force dirty packed-slab memory under the padding of a copied nullary
 * constructor. Generic walkers must see a zero field, never old bytes. */
static V probe_padding(V u) {
  (void)u;
  hdr_t *h = (hdr_t *)(g_blk + 512);
  h->tid = 0x12345678; h->var = 0;
  V first = fpr_msg_copy_to((V)h, 0);
  fpr_slab_t *sl = *(fpr_slab_t **)((char *)first - sizeof(uw));
  if (sl->end - sl->hp < 32) fpr_cpanic("probe: packed slab unexpectedly full");
  for (int i = 0; i < 32; i++) sl->hp[i] = (char)0xAA;
  V second = fpr_msg_copy_to((V)h, 0);
  return TAG(*(uw *)((char *)second + 8) == 0);
}
/* the process ended: unregister, poison what was there, free the block */
static V probe_end(V u) {
  (void)u;
  fpr_image_remove(&g_im);
  for (uw i = 0; i < 4096; i++) g_blk[i] = (char)0xAA;
  buddy_free(g_blk);
  return TAG(0);
}
FPR_FN(fpr_g_Probe_x2emakeImage, probe_make, 1);
FPR_FN(fpr_g_Probe_x2estr, probe_str, 1);
FPR_FN(fpr_g_Probe_x2efn, probe_fn, 1);
FPR_FN(fpr_g_Probe_x2eendImage, probe_end, 1);
FPR_FN(fpr_g_Probe_x2epadding, probe_padding, 1);
