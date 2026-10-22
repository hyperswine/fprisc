
.section .text.entry,"ax",@progbits
.globl _start
_start:
    la sp, _stack_top
    la t0, trap
    csrw mtvec, t0
#ifdef __riscv_flen
    li t0, 0x6000
    csrs mstatus, t0
#endif
    call main
    tail oracle_finish
.balign 4
trap:
    li a0, 1
    tail oracle_finish
.text
.globl fpr_fuel_exhausted
fpr_fuel_exhausted:
    addi sp, sp, -16
    sd ra, 8(sp)
    call oracle_tick
    ld ra, 8(sp)
    addi sp, sp, 16
    li a0, 0
    li a1, 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0
    li a7, 0
    li t0, 0
    li t1, 0
    li t2, 0
    li t3, 0
    li t4, 0
    li t5, 0
    li t6, 0
    ret
