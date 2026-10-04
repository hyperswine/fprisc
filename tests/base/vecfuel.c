/* Force the SIMD chunk's fuel path before any vector register is live. */
#include "fpr.h"
static V force_kernel_fuel(V unit) {
  (void)unit;
  fpr_hart()->fuel = 2;
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_forceKernelFuel, force_kernel_fuel, 1);
