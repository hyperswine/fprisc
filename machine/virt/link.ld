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
  /* the heap: everything after the image, for the buddy -- actors' slabs
   * and stacks, and loaded process images (QOS docs/2026-10-01-PROCESS-
   * IMAGES.md), which are buddy blocks like any other.  It ends where QEMU
   * virt's default 128 MiB of RAM ends; a fixed 32 MiB process slot used to
   * follow it, beyond that RAM (QOS ran QEMU with 256 MiB for it), and is
   * gone.  The RAM size belongs to the device tree the firmware hands over,
   * not to this script: docs/2026-09-19-BOUNDS.md. */
  . = ALIGN(16); _heap_start = .; . = 0x88000000; _heap_end = .;
}
