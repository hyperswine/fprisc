/* link-app.ld -- a dynamically loadable QOS process image
 * (qos docs/2026-10-01-PROCESS-IMAGES.md).  The image is RELOCATABLE: it
 * is linked at PROC_IMAGE_BASE = 0 with --emit-relocs, and the kernel
 * places it in a block from Memory.qa's buddy and moves its address words
 * by wherever that block is (qos tools/mkqa.py writes the list).  Code
 * reaches everything PC-relative (-mcmodel=medany), so only data words
 * move.  A second link at another base is the build's check of the list.
 *
 * No .text.entry / reset vector: this image is never the machine's
 * boot image. `fpr_process_entry` (proc_entry.c) is a PLAIN CALLABLE
 * FUNCTION, and ENTRY() below just points the ELF header's e_entry at
 * it so the loader can read it straight out of the file.
 */
OUTPUT_ARCH(riscv)
ENTRY(fpr_process_entry)

MEMORY { IMAGE (rwx) : ORIGIN = PROC_IMAGE_BASE, LENGTH = 1024M }

SECTIONS {
  _proc_image_start = PROC_IMAGE_BASE; /* statics window base (fpr_static_lo) */
  .text : { *(.text .text.*) } > IMAGE
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > IMAGE
  .data : { *(.data .data.*) *(.sdata .sdata.*) } > IMAGE
  .bss (NOLOAD) : {
    . = ALIGN(8); _bss_start = .;
    *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    . = ALIGN(8); _bss_end = .;
  } > IMAGE
  . = ALIGN(16); _proc_image_end = .; /* the image's end: its statics window's top */
}
