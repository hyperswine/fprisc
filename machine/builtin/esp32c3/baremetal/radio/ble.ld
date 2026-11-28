ENTRY(_start)
/* The instruction and data windows alias SRAM at an offset of 0x700000.
   Reserve distinct physical ranges below the ROM downloader's workspace. */
MEMORY {
  /* Flash images map only the descriptor. Executable code and data load into SRAM. */
  descriptor (r) : ORIGIN = 0x3c000020, LENGTH = 256
  code (rx) : ORIGIN = 0x40380000, LENGTH = 160K
  data (rw) : ORIGIN = 0x3fca8000, LENGTH = 96K
}
SECTIONS {
  .appdesc : { KEEP(*(.appdesc)) } > descriptor
  .text : { KEEP(*(.text.entry)) *(.text .text.* .iram1 .iram1.*) } > code
  .data : { *(.rodata .rodata.* .srodata .srodata.* .sdata .sdata.* .data .data.* .dram1 .dram1.*) } > data
  .bss (NOLOAD) : {
    . = ALIGN(4);
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > data
  _stack_top = ORIGIN(data) + LENGTH(data);
  ASSERT(_bss_end + 8192 <= _stack_top, "C3 BLE image needs 8 KiB stack")
}
