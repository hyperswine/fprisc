#include "fpr.h"
static V pause_fp(V u){(void)u;fpr_hart()->fuel=0;fpr_fuel_exhausted();return (V)&fpr_unit;}
FPR_FN(fpr_g_Fp_x2epause,pause_fp,1);
