#ifndef FPR_BUILTIN_H
#define FPR_BUILTIN_H
#include "fpr.h"
/* Initialize once, before allocations; [start,end) is caller-owned RAM. */
void fpr_builtin_heap_init(void *start, void *end);
V fpr_builtin_alloc_adt(V bytes, uw fields);
uw fpr_builtin_live_allocations(void);
typedef struct {
  uw live_bytes, peak_bytes, requests, requested_bytes, collections, reclaimed_bytes;
} fpr_builtin_heap_stats;
/* Counters are enabled by FPR_BUILTIN_HEAP_STATS or FPR_BUILTIN_GC, otherwise
 * zero. Byte residency includes block headers/padding, excludes the bitmap.
 * Cumulative counters wrap at machine-word width; snapshots do not allocate. */
void fpr_builtin_heap_get_stats(fpr_builtin_heap_stats *out);
#ifdef FPR_BUILTIN_GC
/* Single-threaded, nonmoving conservative collection. The port captures all
 * registers before calling begin/roots/end; none of these functions allocates.
 * Roots and pointer fields must use naturally aligned machine words. Interior
 * payload pointers retain their allocation. allocator_headers is for saved C
 * stack/register roots only, not static roots or arbitrary object fields. */
void fpr_builtin_gc_collect(void);
void fpr_builtin_gc_begin(void);
void fpr_builtin_gc_roots(const uw *begin, const uw *end, int allocator_headers);
void fpr_builtin_gc_end(void);
#endif
V fpr_builtin_retain(V value);
void fpr_builtin_release(V value);
void fpr_builtin_set_layout(V value,V descriptor);
uw fpr_builtin_field_count(V value);
char fpr_builtin_field_kind(V value,uw index);
#endif
