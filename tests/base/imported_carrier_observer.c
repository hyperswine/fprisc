/* Foreign code consumes the public constructor and reads its tagged field. */
#include "fpr.h"

static V read_wrapper(V value) {
    if (!value || ISINT(value)) return TAG(-1000);
    const hdr_t *header = (const hdr_t *)value;
    if (header->var != 0 || fpr_layout_fields(header->tid, header->var) != 1)
        return TAG(-1000);
    return ((const V *)(header + 1))[0];
}
FPR_FN(fpr_g_Carrier_x2einspect, read_wrapper, 1);
