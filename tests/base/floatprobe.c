/* Independent C-runtime reference paths: codegen cannot inline these names. */
#include "fpr.h"
extern V fpr_prim_fn_F64_x2e_x2b(V, V);
extern V fpr_prim_fn_F64_x2e_x2d(V, V);
extern V fpr_prim_fn_F64_x2e_x2a(V, V);
extern V fpr_prim_fn_F64_x2e_x2f(V, V);
extern V fpr_prim_fn_F64_x2e_x3c(V, V);
extern V fpr_prim_fn_F64_x2e_x3e(V, V);
extern V fpr_prim_fn_F64_x2e_x3c_x3d(V, V);
extern V fpr_prim_fn_F64_x2e_x3e_x3d(V, V);
extern V fpr_prim_fn_F64_x2e_x3d_x3d(V, V);
extern V fpr_prim_fn_F64_x2e_x21_x3d(V, V);
FPR_FN(fpr_g_floatRefAdd, fpr_prim_fn_F64_x2e_x2b, 2);
FPR_FN(fpr_g_floatRefSub, fpr_prim_fn_F64_x2e_x2d, 2);
FPR_FN(fpr_g_floatRefMul, fpr_prim_fn_F64_x2e_x2a, 2);
FPR_FN(fpr_g_floatRefDiv, fpr_prim_fn_F64_x2e_x2f, 2);
FPR_FN(fpr_g_floatRefLt, fpr_prim_fn_F64_x2e_x3c, 2);
FPR_FN(fpr_g_floatRefGt, fpr_prim_fn_F64_x2e_x3e, 2);
FPR_FN(fpr_g_floatRefLe, fpr_prim_fn_F64_x2e_x3c_x3d, 2);
FPR_FN(fpr_g_floatRefGe, fpr_prim_fn_F64_x2e_x3e_x3d, 2);
FPR_FN(fpr_g_floatRefEq, fpr_prim_fn_F64_x2e_x3d_x3d, 2);
FPR_FN(fpr_g_floatRefNe, fpr_prim_fn_F64_x2e_x21_x3d, 2);
static V float_bits(V x) {
  char b[16]; const char *hex = "0123456789abcdef";
  for (unsigned i = 0; i < 16; i++) b[i] = hex[((uw)x >> (60 - 4 * i)) & 15];
  return (V)fpr_mkstr(b, 16);
}
FPR_FN(fpr_g_floatBits, float_bits, 1);
