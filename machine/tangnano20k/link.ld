OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : { . = ALIGN(16); _gc_roots_start = .; *(.data .data.*) PROVIDE(__global_pointer$ = . + 0x800); *(.sdata .sdata.*) } > RAM
  _image_end = .;
  ASSERT(_image_end - ORIGIN(RAM) <= 2M, "SDRAM loader currently supports 2 MiB images")
  .bss (NOLOAD) : {
    . = ALIGN(16); _bss_start = .;
    _gc_heap_state_start = .; *(.bss.fpr_heap) . = ALIGN(16); _gc_heap_state_end = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(16); _bss_end = .;
  } > RAM
  _heap_start = .;
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
  _heap_end = _stack_top - 64K;
  ASSERT(_heap_start + 4K <= _heap_end, "SimpleRisc image leaves less than 4 KiB heap and 64 KiB stack")
}
