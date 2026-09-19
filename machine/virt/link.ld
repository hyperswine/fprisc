OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M }

SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > RAM
  .data : { *(.data .data.*) *(.sdata .sdata.*) } > RAM
  .bss (NOLOAD) : {
    . = ALIGN(8); _bss_start = .;
    *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    . = ALIGN(8); _bss_end = .;
  } > RAM
  . = ALIGN(16); . += 256K; _stack_top = .;
  /* heap runs from the image to the FIXED process-slot base: pinning
   * _proc_arena_start absolutely means process apps linked against it
   * never go stale when System.qa's own image size shifts. */
  . = ALIGN(16); _heap_start = .; . = 0x88000000; _heap_end = .;
  /* the process arena: reserved for buddy.c, owned by whichever image
   * calls buddy_init (System.qa) -- docs/PROCESS-LOADING.md. Disjoint
   * from _heap_start.._heap_end (that stays the runtime's OWN heap). */
  _proc_arena_start = .; . += 32M; _proc_arena_end = .;
}
