/* link-app.ld -- the fixed-slot linker script for dynamically loadable
 * QOS processes (docs/PROCESS-LOADING.md). PROC_SLOT_BASE is supplied
 * on the link command line via --defsym (it is System.qa's actual
 * `_proc_arena_start` address for THIS build -- extracted from
 * system.elf's symbol table, not guessed; see the Makefile rule).
 *
 * No .text.entry / reset vector: this image is never the machine's
 * boot image. `fpr_process_entry` (proc_entry.S) is a PLAIN CALLABLE
 * FUNCTION, and ENTRY() below just points the ELF header's e_entry at
 * it so the loader can read it straight out of the file, the way any
 * ELF loader would -- no ad hoc symbol lookup needed.
 *
 * No process-arena reservation at the end: apps don't recursively host
 * their own loadable sub-processes in this design.
 */
OUTPUT_ARCH(riscv)
ENTRY(fpr_process_entry)

MEMORY { SLOT (rwx) : ORIGIN = PROC_SLOT_BASE, LENGTH = 16M }

SECTIONS {
  _proc_image_start = PROC_SLOT_BASE; /* statics window base (fpr_static_lo) */
  .text : { *(.text .text.*) } > SLOT
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > SLOT
  .data : { *(.data .data.*) *(.sdata .sdata.*) } > SLOT
  .bss (NOLOAD) : {
    . = ALIGN(8); _bss_start = .;
    *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    . = ALIGN(8); _bss_end = .;
  } > SLOT
  . = ALIGN(16); _proc_image_end = .; /* where the loader's heap hand-off starts */
}
