.section .text.entry,"ax",@progbits
.global _start
_start:
    csrci mstatus, 8
    la sp, _stack_top
    la t0, _bss_start
    la t1, _bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  la t0, c3_vectors
    ori t0, t0, 1
    csrw mtvec, t0
    call c3_irq_init
    call c3_main
3:  wfi
    j 3b

    /* C3 uses four-byte entries in vectored mode. */
    .section .text.vectors,"ax",@progbits
    .balign 256
    .option push
    .option norvc
c3_vectors:
    .rept 32
    j c3_trap
    .endr
    .option pop
