ENTRY(_start)

/* This image occupies 64 KiB in the P4's low internal SRAM, below the
   bootloader and ROM work areas. Keep the stack and data in that window. */
MEMORY {
  drom (r) : ORIGIN = 0x40000020, LENGTH = 256
  irom (rx) : ORIGIN = 0x40010020, LENGTH = 4
  ram (rwx) : ORIGIN = 0x4ff10000, LENGTH = 64K
}

PHDRS {
  descriptor PT_LOAD FLAGS(4);
  mapped_code PT_LOAD FLAGS(5);
  code PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS {
  .appdesc : { KEEP(*(.appdesc)) } > drom :descriptor
  /* The P4 second-stage bootloader requires two separate MMU mappings.
     All callable code is in SRAM, including during SPI flash writes. */
  .flash.text : { LONG(0x00000013) } > irom :mapped_code
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > ram :code
  .data : { *(.rodata .rodata.* .srodata .srodata.* .sdata .sdata.* .data .data.*) } > ram :data
  .bss (NOLOAD) : {
    . = ALIGN(4);
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > ram :data
  _stack_top = ORIGIN(ram) + LENGTH(ram);
  ASSERT(_bss_end + 8192 <= _stack_top, "P4 RAM image needs 8 KiB stack")
}
