/* Independent runtime layout observations, not the compiler cost formulas. */
#include "fpr.h"
static uw nodes(V value, uw depth) {
  if (ISINT(value) || depth > 12) fpr_cpanic("resource probe: tree shape/depth");
  hdr_t *h = (hdr_t *)value;
  if (h->var == 0) return 0;
  if (h->var != 1) fpr_cpanic("resource probe: tree variant");
  V *fields = (V *)((char *)value + sizeof(hdr_t));
  return 1 + nodes(fields[0], depth + 1) + nodes(fields[1], depth + 1);
}
static V tree_bytes(V value) { return TAG(nodes(value, 0) * (sizeof(hdr_t) + 2 * sizeof(V))); }
static V pap_bytes(V value) {
  if (ISINT(value) || TID(value) != T_PAP) fpr_cpanic("resource probe: not a PAP");
  pap_t *p = (pap_t *)value;
  if (p->arity != 3 || p->nargs != 1) fpr_cpanic("resource probe: PAP shape");
  return TAG(sizeof(pap_t) + p->arity * sizeof(V));
}
FPR_FN(fpr_g_resourceTreeBytes, tree_bytes, 1);
FPR_FN(fpr_g_resourcePapBytes, pap_bytes, 1);
/* Retained one-field chain, including its allocating integer-bearing end. */
static V chain_bytes(V value) {
  uw cells = 0;
  for (;;) {
    if (ISINT(value) || ++cells > 16) fpr_cpanic("resource probe: chain shape/depth");
    hdr_t *h = (hdr_t *)value;
    V *fields = (V *)((char *)value + sizeof(hdr_t));
    if (h->var == 0) return TAG(cells * (sizeof(hdr_t) + sizeof(V)));
    if (h->var != 1) fpr_cpanic("resource probe: chain variant");
    value = fields[0];
  }
}
FPR_FN(fpr_g_resourceChainBytes, chain_bytes, 1);
