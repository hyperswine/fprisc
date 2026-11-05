/* A declared Int can be a managed foreign value. Verify that every map
 * slot still contains its string and that the one crossing Sys.arena was
 * copied before the arena was destroyed. */
#include "fpr.h"
#include <string.h>

static V selected;
static const uint8_t bytes[] = "private map payload";

static V payload(V key) {
    V value = (V)fpr_mkstr(bytes, sizeof(bytes) - 1);
    if (UNTAG(key) == 1) selected = value;
    return value;
}

static V valid(V value) {
    if (!value || ISINT(value) || TID(value) != T_STR) return TAG(0);
    const str_t *s = (const str_t *)value;
    return TAG(s->len == sizeof(bytes) - 1 && !memcmp(s->bytes, bytes, sizeof(bytes) - 1));
}

static V promoted(V value) {
    return selected && value != selected ? valid(value) : TAG(0);
}

FPR_FN(fpr_g_Carrier_x2epayload, payload, 1);
FPR_FN(fpr_g_Carrier_x2evalid, valid, 1);
FPR_FN(fpr_g_Carrier_x2epromoted, promoted, 1);
