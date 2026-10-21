# Test-owned SysV entry: seed/check every integer callee-save register.
.text
.globl probe_call
probe_call:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $24, %rsp
    movq %rdi, 0(%rsp)
    movq %rsi, %r11
    movq $101, %rbp
    movq $102, %rbx
    movq $103, %r12
    movq $104, %r13
    movq $105, %r14
    movq $106, %r15
    movq 0(%r11), %rdi
    movq 8(%r11), %rsi
    movq 16(%r11), %rdx
    movq 24(%r11), %rcx
    movq 32(%r11), %r8
    movq 40(%r11), %r9
    call *0(%rsp)
    cmpq $101, %rbp
    jne .Lprobe_bad
    cmpq $102, %rbx
    jne .Lprobe_bad
    cmpq $103, %r12
    jne .Lprobe_bad
    cmpq $104, %r13
    jne .Lprobe_bad
    cmpq $105, %r14
    jne .Lprobe_bad
    cmpq $106, %r15
    jne .Lprobe_bad
    addq $24, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lprobe_bad:
    ud2

# Check alignment at generated-to-C boundaries, then deliberately destroy
# all SysV volatile integer and SIMD registers before returning to generated code.
.globl fpr_fuel_exhausted
fpr_fuel_exhausted:
    movq %rsp, %r11
    andq $15, %r11
    cmpq $8, %r11
    jne .Lprobe_bad
    subq $8, %rsp
    call probe_fuel_reset
    addq $8, %rsp
    xorq %rax, %rax
    xorq %rdi, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    xorq %rcx, %rcx
    xorq %r8, %r8
    xorq %r9, %r9
    xorq %r10, %r10
    xorq %r11, %r11
    pxor %xmm0, %xmm0
    pxor %xmm1, %xmm1
    pxor %xmm2, %xmm2
    pxor %xmm3, %xmm3
    pxor %xmm4, %xmm4
    pxor %xmm5, %xmm5
    pxor %xmm6, %xmm6
    pxor %xmm7, %xmm7
    pxor %xmm8, %xmm8
    pxor %xmm9, %xmm9
    pxor %xmm10, %xmm10
    pxor %xmm11, %xmm11
    pxor %xmm12, %xmm12
    pxor %xmm13, %xmm13
    pxor %xmm14, %xmm14
    pxor %xmm15, %xmm15
    ret
