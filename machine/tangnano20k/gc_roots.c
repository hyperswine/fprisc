/* Root boundary for the single-threaded, soft-float Base board host.
 * gc_registers.S snapshots integer registers before entering this C frame.
 * The heap lies after BSS and before the reserved downward-growing stack. */
#include "builtin.h"
extern char _gc_roots_start[], _bss_end[], _heap_end[], _stack_top[];
extern char _gc_heap_state_start[], _gc_heap_state_end[];
void fpr_tangnano_gc_scan(const uw *stack) {
  if ((uw)stack < (uw)_heap_end || (uw)stack > (uw)_stack_top)
    fpr_cpanic("Base: GC stack outside reservation");
  fpr_builtin_gc_begin();
  fpr_builtin_gc_roots((const uw *)_gc_roots_start, (const uw *)_gc_heap_state_start, 0);
  fpr_builtin_gc_roots((const uw *)_gc_heap_state_end, (const uw *)_bss_end, 0);
  fpr_builtin_gc_roots(stack, (const uw *)_stack_top, 1);
  fpr_builtin_gc_end();
#ifdef FPR_HEAP_REPORT
  extern void fpr_tangnano_gc_report(void);
  fpr_tangnano_gc_report();
#endif
}
