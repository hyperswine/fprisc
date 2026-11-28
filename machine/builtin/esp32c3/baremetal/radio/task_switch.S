    .text
    .balign 4
    .globl c3_task_switch
    .type c3_task_switch,@function
/* Cooperative switch at a C calling boundary. The firmware owns gp and tp
 * across all controller tasks. Interrupt callbacks never switch stacks. */
c3_task_switch:
    sw sp,  0(a0)
    sw ra,  4(a0)
    sw s0,  8(a0)
    sw s1, 12(a0)
    sw s2, 16(a0)
    sw s3, 20(a0)
    sw s4, 24(a0)
    sw s5, 28(a0)
    sw s6, 32(a0)
    sw s7, 36(a0)
    sw s8, 40(a0)
    sw s9, 44(a0)
    sw s10, 48(a0)
    sw s11, 52(a0)
    lw sp,  0(a1)
    lw ra,  4(a1)
    lw s0,  8(a1)
    lw s1, 12(a1)
    lw s2, 16(a1)
    lw s3, 20(a1)
    lw s4, 24(a1)
    lw s5, 28(a1)
    lw s6, 32(a1)
    lw s7, 36(a1)
    lw s8, 40(a1)
    lw s9, 44(a1)
    lw s10, 48(a1)
    lw s11, 52(a1)
    ret
    .size c3_task_switch, .-c3_task_switch
