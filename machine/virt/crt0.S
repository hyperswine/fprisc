/* crt0 — SMP boot.  XLEN-neutral via asm.h; FPR_NHARTS via -D.
 *
 * Every hart below FPR_NHARTS gets a 64 KiB boot stack carved below
 * _stack_top (the boot stack BECOMES that hart's scheduler/idle stack;
 * actors get their own heap-allocated stacks).  Hart 0 clears bss, runs
 * fpr_rt_init (which sets hart 0's tp, splits the heap, and finally
 * publishes fpr_smp_go with release semantics), then enters the hart
 * loop.  Secondaries spin on fpr_smp_go (it lives in .data, so it is 0
 * from the ELF image before hart 0 writes it -- no bss-clear race),
 * take an acquire fence, and join.  Harts >= FPR_NHARTS park in wfi.
 */
#include "asm.h"
    .section .text.entry
    .globl _start
_start:
    /* FPU on before ANY C runs: with -march=...fd the compiler may
     * use F regs anywhere, and mstatus.FS resets to Off (every FP
     * instruction traps).  FS=11 (Dirty) is the no-lazy-save choice;
     * PER-HART, so the secondary path below does it too (same
     * reasoning as the fpr_rvv_enable comment in runtime.c). */
    li    t0, 0x6000
    csrs  mstatus, t0
    csrr  t0, mhartid
    li    t1, FPR_NHARTS
    bgeu  t0, t1, 9f
    /* per-hart boot stack: _stack_top - hartid * 64K */
    slli  t2, t0, 16
    la    sp, _stack_top
    sub   sp, sp, t2
    bnez  t0, 5f
    /* ---- hart 0: clear bss, global init, go ---- */
    la    t0, _bss_start
    la    t1, _bss_end
1:  bgeu  t0, t1, 2f
    REG_S zero, 0(t0)
    addi  t0, t0, WSZ
    j     1b
2:  call  fpr_rt_init          /* sets tp for hart 0, releases fpr_smp_go */
    li    a0, 0
    call  fpr_hart_main        /* never returns */
9:  wfi
    j     9b
    /* ---- secondaries: wait for the release flag ---- */
5:  la    t1, fpr_smp_go
6:  lw    t2, 0(t1)
    beqz  t2, 6b
    fence r, rw                /* acquire: hart 0's init happens-before us */
    li    t0, 0x6000
    csrs  mstatus, t0
    csrr  a0, mhartid
    call  fpr_hart_secondary   /* sets tp, per-hart init, hart loop */
    j     9b
