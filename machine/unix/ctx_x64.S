/* ctx_x64.S — fpr_ctx_switch for x86-64 SysV (ctx.S's posix sibling).
 *
 * void fpr_ctx_switch(uintptr_t *save %rdi, uintptr_t *load %rsi);
 *
 * Same contract as runtime/virt/ctx.S: save the CALLER's callee-saved
 * state, resume whoever saved into `load`.  Layout keeps ctx.S's word
 * indices where the slot has an x86 meaning:
 *   0 = resume pc ("ra")   1 = %rsp AFTER our return would pop
 *   4..9 = %rbp %rbx %r12 %r13 %r14 %r15   (2,3,10..15 unused)
 * SysV has no callee-saved xmm registers, so integer state is the
 * whole contract.  Resuming jmp's to the saved pc with the saved rsp:
 * indistinguishable from fpr_ctx_switch having returned normally.
 */
    .text
    .balign 16
    .globl fpr_ctx_switch
fpr_ctx_switch:
    movq (%rsp), %rax          # caller's resume pc
    movq %rax,  0(%rdi)
    leaq 8(%rsp), %rax         # caller's sp once we "return"
    movq %rax,  8(%rdi)
    movq %rbp, 32(%rdi)
    movq %rbx, 40(%rdi)
    movq %r12, 48(%rdi)
    movq %r13, 56(%rdi)
    movq %r14, 64(%rdi)
    movq %r15, 72(%rdi)

    movq  8(%rsi), %rsp
    movq 32(%rsi), %rbp
    movq 40(%rsi), %rbx
    movq 48(%rsi), %r12
    movq 56(%rsi), %r13
    movq 64(%rsi), %r14
    movq 72(%rsi), %r15
    movq  0(%rsi), %rax
    jmp *%rax
