/* machine.S -- the opaque machine primitives (docs/2026-09-18-MACHINE-PRIMITIVES.md).
 *
 * Plain RV64 integer ABI: arguments in a0..a2, result in a0, nothing
 * tagged, boxed, allocated or reference-counted here -- the FP-RISC
 * adapters in unsafe.c do that.  Preconditions (shift counts < 64,
 * aligned addresses, CSR numbers < 4096) are the caller's, and machine.h
 * is the contract.  Each primitive sits in its own section so the linker
 * drops what a program does not use -- in particular the two 32 KiB CSR
 * dispatch tables, which are only linked when csrRead / csrWrite are.
 *
 * Memory, CSR, interrupt and fence operations are real, ordered,
 * out-of-line instructions: the C compiler cannot fold or reorder them,
 * and neither may a future FP-RISC optimizer.
 */
/* the Makefile's -march carries no zifencei; this file declares it for
 * itself so that fence.i assembles AND stays decodable in the linked
 * image (objdump reads the merged Tag_RISCV_arch; a push/pop-scoped
 * .option arch does not reach the object's attribute) */
    .option arch, +zifencei

    .macro FN name
    .section .text.\name,"ax",@progbits
    .balign 4
    .globl \name
\name:
    .endm

/* ---- bits: pure ------------------------------------------------------- */
FN fpr_machine_shl
    sll   a0, a0, a1
    ret
FN fpr_machine_shr
    srl   a0, a0, a1
    ret
FN fpr_machine_and
    and   a0, a0, a1
    ret
FN fpr_machine_or
    or    a0, a0, a1
    ret
FN fpr_machine_xor
    xor   a0, a0, a1
    ret
FN fpr_machine_not
    not   a0, a0
    ret
FN fpr_machine_bit_set
    li    t0, 1
    sll   t0, t0, a1
    or    a0, a0, t0
    ret
FN fpr_machine_bit_clear
    li    t0, 1
    sll   t0, t0, a1
    not   t0, t0
    and   a0, a0, t0
    ret
FN fpr_machine_bit_test
    srl   a0, a0, a1
    andi  a0, a0, 1
    ret

/* ---- raw memory: naturally aligned, mapped, permitted (caller) -------- */
FN fpr_machine_read8
    lbu   a0, 0(a0)
    ret
FN fpr_machine_read16
    lhu   a0, 0(a0)
    ret
FN fpr_machine_read32
    lwu   a0, 0(a0)
    ret
FN fpr_machine_readWord
    ld    a0, 0(a0)
    ret
FN fpr_machine_write8
    sb    a1, 0(a0)
    ret
FN fpr_machine_write16
    sh    a1, 0(a0)
    ret
FN fpr_machine_write32
    sw    a1, 0(a0)
    ret
FN fpr_machine_writeWord
    sd    a1, 0(a0)
    ret

/* ---- fences ----------------------------------------------------------- */
FN fpr_machine_fence
    fence iorw, iorw
    ret
FN fpr_machine_fence_i
    fence.i
    ret

/* ---- CSRs: the number is an instruction field, so a runtime number is
 * dispatched through a table of 4096 eight-byte slots -- the complete
 * architectural address space, no software allowlist.  Read is CSRRS
 * with x0 (no write side effect); write is CSRRW into x0 (no read).  An
 * unimplemented, privilege-forbidden or read-only access traps in
 * hardware, as the architecture says; only the RANGE is checked here.
 * norvc inside the tables: a compressed ret would make a 6-byte slot. */
    .section .rodata.fpr_machine_csr_msg,"a",@progbits
fpr_machine_csr_msg:
    .asciz "CSR number out of range"

FN fpr_machine_csr_read
    li    t0, 4096
    bgeu  a0, t0, 8f             /* unsigned: a negative number is out of range too */
    slli  t0, a0, 3
    la    t1, 1f
    add   t0, t0, t1
    jr    t0
    .balign 8
    .option push
    .option norvc
1:
    .set  csr, 0
    .rept 4096
    csrrs a0, csr, zero
    jalr  zero, 0(ra)
    .set  csr, csr + 1
    .endr
    .option pop
8:  la    a0, fpr_machine_csr_msg
    tail  fpr_cpanic

FN fpr_machine_csr_write
    li    t0, 4096
    bgeu  a0, t0, 8f
    slli  t0, a0, 3
    la    t1, 1f
    add   t0, t0, t1
    jr    t0
    .balign 8
    .option push
    .option norvc
1:
    .set  csr, 0
    .rept 4096
    csrrw zero, csr, a1
    jalr  zero, 0(ra)
    .set  csr, csr + 1
    .endr
    .option pop
8:  la    a0, fpr_machine_csr_msg
    tail  fpr_cpanic

/* ---- interrupts: ONLY mstatus.MIE; the token is the previous bit ----- */
FN fpr_machine_irq_save
    csrrci a0, mstatus, 8
    andi  a0, a0, 8
    ret
FN fpr_machine_irq_restore
    andi  a0, a0, 8
    csrci mstatus, 8
    csrs  mstatus, a0            /* set only when the token says it was set */
    ret
FN fpr_machine_irq_enable
    csrsi mstatus, 8
    ret
FN fpr_machine_wait
    wfi
    ret

/* ---- atomics: 8-byte aligned ordinary RAM ---------------------------- */
FN fpr_machine_exchange
    amoswap.d.aqrl a0, a1, (a0)
    ret
FN fpr_machine_compare_exchange
1:  lr.d.aq t0, (a0)
    bne   t0, a1, 2f
    sc.d.rl t1, a2, (a0)
    bnez  t1, 1b
2:  mv    a0, t0
    ret
