/* heap.S -- the posix stand-in for link.ld's memory map.
 *
 * Bare metal, _heap_start/_heap_end and the process arena are linker-
 * script symbols carving up physical RAM.  Hosted, the "RAM" is one
 * big .bss block; the process arena is zero-sized (no process loading
 * in the posix HAL) but the symbols must exist and be ordered, because
 * fpr_in_heap() tests _heap_start <= p < _proc_arena_end.  Assembles
 * unchanged for aarch64 and x86-64.  FPR_HEAP_MB sizes it (default 256). */
#ifndef FPR_HEAP_MB
#define FPR_HEAP_MB 256
#endif
#ifdef __APPLE__
    .globl __heap_start, __heap_end, __proc_arena_start, __proc_arena_end
    .zerofill __DATA,__fprheap,__heap_start,FPR_HEAP_MB*1048576,14
    .zerofill __DATA,__fprheap,__heap_end,0,3
    .zerofill __DATA,__fprheap,__proc_arena_start,0,3
    .zerofill __DATA,__fprheap,__proc_arena_end,0,3
#else
    .bss
    .balign 65536
    .globl _heap_start, _heap_end, _proc_arena_start, _proc_arena_end
_heap_start:
    .space FPR_HEAP_MB * 1024 * 1024
_heap_end:
_proc_arena_start:
_proc_arena_end:
    .section .note.GNU-stack,"",%progbits
#endif
