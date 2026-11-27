#include <errno.h>
#include "builtin.h"

/* The shared Journal library selects the raw flash backend here. Keep the
 * filesystem ABI linkable and return a defined error if used directly. */
static V unavailable1(V a) { (void)a; return TAG(-ENOSYS); }
static V unavailable2(V a, V b) { (void)b; return unavailable1(a); }
static V unavailable3(V a, V b, V c) { (void)c; return unavailable2(a, b); }
FPR_FN(fpr_g_EspFile_x2emount, unavailable1, 1);
FPR_FN(fpr_g_EspFile_x2ecreate, unavailable1, 1);
FPR_FN(fpr_g_EspFile_x2eopen, unavailable1, 1);
FPR_FN(fpr_g_EspFile_x2eappend, unavailable1, 1);
FPR_FN(fpr_g_EspFile_x2eedit, unavailable1, 1);
FPR_FN(fpr_g_EspFile_x2eclose, unavailable1, 1);
FPR_FN(fpr_g_EspFile_x2eflush, unavailable1, 1);
FPR_FN(fpr_g_EspFile_x2etruncate, unavailable2, 2);
FPR_FN(fpr_g_EspFile_x2eread, unavailable3, 3);
FPR_FN(fpr_g_EspFile_x2ewrite, unavailable3, 3);
FPR_FN(fpr_g_EspRecord_x2epack, unavailable2, 2);
FPR_FN(fpr_g_EspRecord_x2eunpack, unavailable1, 1);

int memcmp(const void *lhs, const void *rhs, size_t n) {
    const unsigned char *a = lhs, *b = rhs;
    for (size_t i = 0; i < n; ++i)
        if (a[i] != b[i]) return (int)a[i] - b[i];
    return 0;
}
