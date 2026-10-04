/* SimpleRisc RV32IM: one core, no CSR/FPU/interrupt instructions. */
    .section .text.entry,"ax",@progbits
    .globl _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, _stack_top
    la t0, _bss_start
    la t1, _bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call fpr_builtin_main
    ecall
3:  j 3b
