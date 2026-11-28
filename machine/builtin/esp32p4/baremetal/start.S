    .section .text.entry,"ax",@progbits
    .global _start
_start:
    csrci mstatus, 8
    csrr t0, mhartid
    bnez t0, .Lpark
    la sp, _stack_top
    la t0, _bss_start
    la t1, _bss_end
.Lzero:
    bgeu t0, t1, .Lboot
    sw zero, 0(t0)
    addi t0, t0, 4
    j .Lzero
.Lboot:
    call p4_main
.Lpark:
    wfi
    j .Lpark
