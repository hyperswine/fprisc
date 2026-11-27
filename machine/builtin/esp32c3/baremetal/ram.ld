ENTRY(_start)
/* The instruction and data windows alias SRAM at an offset of 0x700000.
   Reserve distinct physical ranges below the ROM downloader's workspace. */
MEMORY {
  code (rx) : ORIGIN = 0x40380000, LENGTH = 64K
  data (rw) : ORIGIN = 0x3fc90000, LENGTH = 64K
}
SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > code
  .data : { *(.rodata .rodata.* .srodata .srodata.* .sdata .sdata.* .data .data.*) } > data
  .bss (NOLOAD) : {
    . = ALIGN(4);
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > data
  _stack_top = ORIGIN(data) + LENGTH(data);
  ASSERT(_bss_end + 8192 <= _stack_top, "C3 RAM image needs 8 KiB stack")
}
