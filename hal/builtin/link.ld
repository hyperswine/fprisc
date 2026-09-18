OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M }
SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : { *(.data .data.*) PROVIDE(__global_pointer$ = . + 0x800); *(.sdata .sdata.*) } > RAM
  .bss (NOLOAD) : { . = ALIGN(16); _bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(16); _bss_end = .; } > RAM
  .stack (NOLOAD) : { . += 64K; . = ALIGN(16); _stack_top = .; } > RAM
  .trap_stack (NOLOAD) : { . += 4K; . = ALIGN(16); _trap_stack_top = .; } > RAM
  .irq_stack (NOLOAD) : { . += 64K; . = ALIGN(16); _irq_stack_top = .; } > RAM
  /* the allocator's state cell (heap.fpr reads it through Addr.symbol):
   * head, low, high -- an FP-RISC unit has no globals of its own */
  .heap_state (NOLOAD) : { . = ALIGN(16); _heap_state = .; . += 64; } > RAM
  _heap_start = .;
  _heap_end = ORIGIN(RAM) + LENGTH(RAM);
  ASSERT(_heap_start + 64K <= _heap_end, "insufficient Builtin heap")
}
