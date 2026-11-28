#pragma once
#include "builtin.h"

/* Manual Builtin Addr boxes contain a caller-owned pointer. Capacity and
 * lifetime are the caller's responsibility, as with Mem.read8/write8. */
static inline void *buffer_ptr(V addr) {
    if (!ISPTR(addr) || TID(addr) != T_BITS || ((bits_t *)addr)->var != 3)
        fpr_cpanic("expected a Builtin Addr");
    return (void *)(uw)((bits_t *)addr)->val;
}
