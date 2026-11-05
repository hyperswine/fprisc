/* Tagged boundary leaves. Raw addresses are payload bits, never owned edges;
 * floating payloads are copied as bits, preserving NaNs and signed zero.
 * Unboxing consumes exactly the reference supplied by its caller. */
static V uniform_box(V value, unsigned variant, unsigned width) {
  bits_t *box=(bits_t *)fpr_builtin_alloc_adt(sizeof(bits_t),0);
  box->tid=T_BITS; box->var=variant; box->len=width;
  box->val=width==32 ? (uw)(uint32_t)value : (uw)value;
  return (V)box;
}
static V uniform_unbox(V value, unsigned variant, unsigned width) {
  if(!value || ISINT(value) || TID(value)!=T_BITS || ((bits_t *)value)->var!=variant
      || ((bits_t *)value)->len!=width)
    fpr_cpanic("Builtin: uniform scalar representation mismatch");
  V result=(V)((bits_t *)value)->val;
  fpr_builtin_release(value);
  return width==32 ? (V)(uint32_t)result : result;
}
#define UNIFORM_SCALAR(name,variant,width) \
  V fpr_fn__x24arc_x2euniformBox##name(V v) { return uniform_box(v,variant,width); } \
  V fpr_fn__x24arc_x2euniformUnbox##name(V v) { return uniform_unbox(v,variant,width); }
UNIFORM_SCALAR(Word,2,64)
UNIFORM_SCALAR(Addr,3,64)
UNIFORM_SCALAR(F64,5,64)
UNIFORM_SCALAR(F32,6,32)
#undef UNIFORM_SCALAR
V fpr_fn__x24arc_x2euniformUnboxTagged(V value) {
  if(!ISINT(value))fpr_cpanic("Builtin: uniform tagged representation mismatch");
  return value;
}
V fpr_fn__x24arc_x2euniformUnboxText(V value) {
  if(!value || ISINT(value) || TID(value)!=T_STR)
    fpr_cpanic("Builtin: uniform text representation mismatch");
  return value;
}
V fpr_fn__x24arc_x2euniformUnboxData(V value,V tid) {
  if(!ISINT(tid) || !value || ISINT(value) || TID(value)!=(uw)UNTAG(tid))
    fpr_cpanic("Builtin: uniform nominal representation mismatch");
  if((UNTAG(tid)==T_BOOL || UNTAG(tid)==T_UNIT) &&
      (fpr_in_heap(value) || ((hdr_t *)value)->var>(UNTAG(tid)==T_BOOL?1u:0u)))
    fpr_cpanic("Builtin: uniform immortal representation mismatch");
  return value;
}
V fpr_fn__x24arc_x2euniformProject(V value,V index) {
  if(!ISINT(index) || UNTAG(index)<0 || !value || ISINT(value) || !fpr_in_heap(value) ||
      (uw)UNTAG(index)>=fpr_builtin_field_count(value) ||
      fpr_builtin_field_kind(value,(uw)UNTAG(index))!='t')
    fpr_cpanic("Builtin: uniform field representation mismatch");
  V result=fpr_builtin_retain(((V *)(value+8))[UNTAG(index)]);
  fpr_builtin_release(value);
  return result;
}
V fpr_fn__x24arc_x2euniformTagEq(V value,V tid,V variant) {
  if(!ISINT(tid) || !ISINT(variant) || UNTAG(tid)<0 || UNTAG(variant)<0)
    fpr_cpanic("Builtin: uniform tag test descriptor mismatch");
  int equal=value && !ISINT(value) && TID(value)==(uw)UNTAG(tid)
      && ((hdr_t*)value)->var==(uw)UNTAG(variant);
  fpr_builtin_release(value);
  return equal ? (V)&fpr_true : (V)&fpr_false;
}
#include "uniform-aggregate.inc"
