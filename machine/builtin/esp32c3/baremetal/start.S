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
2:  call c3_main
3:  wfi
    j 3b
