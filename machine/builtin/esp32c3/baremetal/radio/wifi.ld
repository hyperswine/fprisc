ENTRY(_start)
MEMORY {
  drom (r) : ORIGIN = 0x3c000020, LENGTH = 256K
  /* IROM and DROM share the C3 flash MMU table. Reserve DROM's first
     four 64 KiB page indices before assigning any IROM pages. */
  irom (rx) : ORIGIN = 0x42040020, LENGTH = 512K
  code (rx) : ORIGIN = 0x40380000, LENGTH = 64K
  data (rw) : ORIGIN = 0x3fc90000, LENGTH = 160K
}
SECTIONS {
  .flash.rodata : {
    KEEP(*(.appdesc))
    *(.rodata .rodata.* .srodata .srodata.* .rodata_wlog_*)
  } > drom
  .iram.text : {
    KEEP(*(.text.entry))
    *(.text.vectors .text.c3_trap .iram1 .iram1.* .wifi*iram .wifi*iram.*)
  } > code
  .flash.text : { *(.text .text.*) } > irom
  .data : { *(.sdata .sdata.* .data .data.* .dram1 .dram1.*) } > data
  .bss (NOLOAD) : {
    . = ALIGN(4);
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > data
  _stack_top = ORIGIN(data) + LENGTH(data);
  ASSERT(_bss_end + 8192 <= _stack_top, "C3 Wi-Fi image needs 8 KiB stack")
}
