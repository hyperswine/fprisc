OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.*) } > RAM
 .data : { *(.data .data.*) } > RAM
 .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > RAM
 _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
