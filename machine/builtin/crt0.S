/* crt0.S -- BareMetal-Builtin boot: one hart, no scheduler.
 *
 * Hart 0 turns the FPU on (mstatus.FS = Dirty: the C runtime and the
 * generated code may use F registers anywhere under -march=...fd), takes
 * the 64 KiB main stack the linker script carved (_stack_top), installs
 * the FATAL trap vector, clears bss and enters fpr_builtin_main
 * (virt.c), which never returns.  Every other hart parks in wfi: this
 * profile has no secondaries.
 *
 * fpr_machine_trap is the fallback vector for the whole profile: any
 * exception or interrupt that reaches it is reported through
 * fpr_builtin_fatal_trap on the 4 KiB emergency stack (_trap_stack_top)
 * and ends the machine.  It is also where interrupt.S sends a SYNCHRONOUS
 * fault raised inside a resumable handler, so it must not trust sp: it
 * loads its own.  ARC builds that define machineInterrupt replace mtvec
 * with fpr_machine_interrupt_entry at startup (virt.c) and keep this one
 * for faults.
 */
    .section .text.entry,"ax",@progbits
    .globl _start
_start:
    li    t0, 0x6000
    csrs  mstatus, t0            /* FS = 11: no FP trap, no lazy save */
    csrr  t0, mhartid
    bnez  t0, 9f                 /* only hart 0 runs the program */
    .option push
    .option norelax
    la    gp, __global_pointer$
    .option pop
    la    sp, _stack_top
    la    t0, fpr_machine_trap
    csrw  mtvec, t0              /* fatal fallback until main installs its own */
    csrw  mie, zero              /* no source enabled until the program asks */
    la    t0, _bss_start
    la    t1, _bss_end
1:  bgeu  t0, t1, 2f
    sd    zero, 0(t0)
    addi  t0, t0, 8
    j     1b
2:  call  fpr_builtin_main       /* never returns */
9:  wfi
    j     9b

/* the fatal trap: emergency stack, then report and halt (virt.c) */
    .section .text.fpr_machine_trap,"ax",@progbits
    .balign 4
    .globl fpr_machine_trap
fpr_machine_trap:
    la    sp, _trap_stack_top
    li    t0, 0x6000
    csrs  mstatus, t0            /* the reporter is C built with fd */
    csrr  a0, mcause
    csrr  a1, mepc
    csrr  a2, mtval
    call  fpr_builtin_fatal_trap /* never returns */
1:  wfi
    j     1b
