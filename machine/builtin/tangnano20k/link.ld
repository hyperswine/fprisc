OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 64K }
SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : { *(.data .data.*) PROVIDE(__global_pointer$ = . + 0x800); *(.sdata .sdata.*) } > RAM
  .bss (NOLOAD) : {
    . = ALIGN(16); _bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(16); _bss_end = .;
  } > RAM
  _heap_start = .;
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
  _heap_end = _stack_top - 8K;
  ASSERT(_heap_start + 4K <= _heap_end, "SimpleRisc image leaves less than 4 KiB heap and 8 KiB stack")
}
