/* Test-only image tables: schema refusal and root/dependency name collisions. */
#include "fpr.h"
extern int fpr_mod_attach(const uw *);
static V root_op(V v) { (void)v; return TAG(11); }
static V dep_op(V v) { (void)v; return TAG(77); }
FPR_FN(fpr_g_Probe_x2erootOp, root_op, 1);
FPR_FN(fpr_g_Probe_x2edepOp, dep_op, 1);
static uw str(const char *s) {
  uw n = 0; while (s[n]) n++;
  return (uw)fpr_mkstr((const unsigned char *)s, n);
}
static V legacy(V ignored) {
  (void)ignored;
  uw old[] = {str("old"), str("op"), (uw)&fpr_g_Probe_x2erootOp, 0};
  uw unknown[] = {0x4650524d, 3, str("root"), 0};
  uw wrong_layout[] = {0x4650524d, 2, str("root"), 0, FPR_MANAGED_PREFIX == 8 ? 16 : 8, 0};
  return BOOL(fpr_mod_attach(old) == -1 && fpr_mod_attach(unknown) == -1 &&
              fpr_mod_attach(wrong_layout) == -1);
}
static V attach(V kv) {
  sw k = UNTAG(kv);
  uw *t = (uw *)fpr_alloc_raw(14 * sizeof(uw));
  t[0] = 0x4650524d; t[1] = 2; t[2] = str("root"); t[3] = 0; t[4] = FPR_MANAGED_PREFIX;
  /* Dependency row comes FIRST, with the root's name and a different stamp. */
  t[5] = str("dep"); t[6] = str("op");
  t[7] = (uw)&fpr_g_Probe_x2edepOp; t[8] = str("dependency");
  t[9] = str("root"); t[10] = str(k == 2 ? "other" : "op");
  t[11] = (uw)&fpr_g_Probe_x2erootOp;
  t[12] = str(k == 3 ? "changed" : k == 4 ? "" : "checked"); t[13] = 0;
  if (k == 5) t[9] = 0;
  return TAG(fpr_mod_attach(t));
}
FPR_FN(fpr_g_Probe_x2elegacy, legacy, 1);
FPR_FN(fpr_g_Probe_x2eattach, attach, 1);
