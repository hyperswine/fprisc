/* SimpleRisc RV32IM + Zicsr: one core, no FPU or interrupt sources yet. */
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
    li a0, 1 /* fpr_builtin_main must not return */
    call hal_poweroff
3:  j 3b
