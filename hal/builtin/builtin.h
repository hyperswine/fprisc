#ifndef FPR_BUILTIN_H
#define FPR_BUILTIN_H
#include "fpr.h"
/* Initialize once, before allocations; [start,end) is caller-owned RAM. */
void fpr_builtin_heap_init(void *start, void *end);
V fpr_builtin_alloc_adt(V bytes, uw fields);
uw fpr_builtin_live_allocations(void);
V fpr_builtin_retain(V value);
void fpr_builtin_release(V value);
#endif
