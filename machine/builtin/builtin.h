#ifndef FPR_BUILTIN_H
#define FPR_BUILTIN_H
#include "fpr.h"
/* Initialize once, before allocations; [start,end) is caller-owned RAM. */
void fpr_builtin_heap_init(void *start, void *end);
V fpr_builtin_alloc_adt(V bytes, uw fields);
uw fpr_builtin_live_allocations(void);
typedef struct {
  uw live_bytes, peak_bytes, requests, requested_bytes, regions, reclaimed_bytes;
} fpr_builtin_heap_stats;
/* Byte counters are enabled by FPR_BUILTIN_HEAP_STATS, otherwise zero; regions
 * (opened) and reclaimed_bytes (freed by region resets and closes) always
 * count. Byte residency includes block headers/padding, excludes the bitmap.
 * Cumulative counters wrap at machine-word width; snapshots do not allocate. */
void fpr_builtin_heap_get_stats(fpr_builtin_heap_stats *out);
/* Regions (docs/2026-10-25-REGIONS-LOOPS-CALLS.md): runtime.c's compiler-region
 * primitives drive these; Builtin ARC builds open none.  Single-threaded. */
void fpr_builtin_heap_clock(uw *cell);
int fpr_builtin_untracked(V v);
uw fpr_builtin_region_bytes(void);
uw fpr_builtin_region_seq(void);
int fpr_builtin_region_open(uw seq);
void fpr_builtin_region_cycle_begin(void);
void fpr_builtin_region_cycle_end(void);
void *fpr_builtin_region_close_begin(void);
void fpr_builtin_region_close_end(void *token);
/* bytes the closing region allocated since its last reset, and the close
 * that keeps them: its live blocks join the enclosing region (untracked when
 * none is open), its freed ones are freed now, and its record goes */
uw fpr_builtin_region_scratch(void *token);
void fpr_builtin_region_adopt(void *token);
uw fpr_builtin_pend(void);
void *fpr_builtin_pend_pop(uw tok);
void fpr_builtin_region_counts(uw *opens, uw *reclaimed);
V fpr_builtin_retain(V value);
void fpr_builtin_release(V value);
void fpr_builtin_set_layout(V value,V descriptor);
uw fpr_builtin_field_count(V value);
char fpr_builtin_field_kind(V value,uw index);
#endif
