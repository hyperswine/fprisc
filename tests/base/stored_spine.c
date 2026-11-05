/* Fixture for the private physical ABI. Use a heap payload even though a
 * source scalar normally fits in a tagged word: boundary values can differ
 * from their declared type. Every slot must survive copying and migration. */
#include "fpr.h"
#include <string.h>

static const hdr_t nil = {T_LIST, 0};
static V make_spine(V count_arg, V width_arg) {
  sw count=UNTAG(count_arg), width=UNTAG(width_arg);
  if (width<1 || width>8 || count<0) fpr_cpanic("invalid spine fixture");
  V tail=(V)&nil;
  for (sw n=1; n<=count; ++n) {
    V cell=fpr_alloc(sizeof(hdr_t)+(width+1)*sizeof(V));
    hdr_t *head=(hdr_t *)cell;
    head->tid=T_STORED_LIST;
    head->var=(uint32_t)((n%3)*8+width-1);
    V *slots=(V *)(head+1);
    for (sw j=0; j<width; ++j)
      slots[j]=j==width-1 ? (V)fpr_mkstr((const uint8_t *)"kept",4) : TAG(n+j);
    slots[width]=tail;
    tail=cell;
  }
  return tail;
}

static V verify_spine(V node, V count_arg, V width_arg) {
  sw width=UNTAG(width_arg);
  if (width<1 || width>8) return TAG(0);
  for (sw n=UNTAG(count_arg); n>0; --n) {
    if (!node || ISINT(node)) return TAG(0);
    hdr_t *h=(hdr_t *)node;
    if (h->tid!=T_STORED_LIST || h->var!=(uint32_t)((n%3)*8+width-1)) return TAG(0);
    V *slots=(V *)(h+1);
    for (sw j=0; j<width-1; ++j) if (slots[j]!=TAG(n+j)) return TAG(0);
    V s=slots[width-1];
    if (!s || ISINT(s) || TID(s)!=T_STR || ((str_t *)s)->len!=4 ||
        memcmp(((str_t *)s)->bytes,"kept",4)) return TAG(0);
    node=slots[width];
  }
  return TAG(node && !ISINT(node) && TID(node)==T_LIST && ((hdr_t *)node)->var==0);
}
FPR_FN(fpr_g_Stored_x2emake, make_spine, 2);
FPR_FN(fpr_g_Stored_x2everify, verify_spine, 3);

/* The declaration claims Int. The collector must still follow the actual
 * tagged reference while an automatically opened call region closes. */
static V opaque_payload(V unused) {
  (void)unused;
  return (V)fpr_mkstr((const uint8_t *)"kept",4);
}
static V valid_payload(V value) {
  if (!value || ISINT(value) || TID(value)!=T_STR) return TAG(0);
  const str_t *s=(const str_t *)value;
  return TAG(s->len==4 && !memcmp(s->bytes,"kept",4));
}
static V opened(V unused) { (void)unused; return TAG(fpr_region_call_opens_count()); }
FPR_FN(fpr_g_Stored_x2epayload, opaque_payload, 1);
FPR_FN(fpr_g_Stored_x2evalid, valid_payload, 1);
FPR_FN(fpr_g_Stored_x2eopens, opened, 1);
