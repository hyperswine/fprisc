#ifdef __APPLE__
#define SYM(x) _##x
#else
#define SYM(x) x
#endif
.text
.globl SYM(fp_context_probe)
SYM(fp_context_probe):
    sub sp,sp,#96
    stp d8,d9,[sp,#0]
    stp d10,d11,[sp,#16]
    stp d12,d13,[sp,#32]
    stp d14,d15,[sp,#48]
    stp x29,x30,[sp,#64]
    str x3,[sp,#80]
    ldp d8,d9,[x2,#0]
    ldp d10,d11,[x2,#16]
    ldp d12,d13,[x2,#32]
    ldp d14,d15,[x2,#48]
    bl SYM(fpr_ctx_switch)
    ldr x3,[sp,#80]
    stp d8,d9,[x3,#0]
    stp d10,d11,[x3,#16]
    stp d12,d13,[x3,#32]
    stp d14,d15,[x3,#48]
    ldp d8,d9,[sp,#0]
    ldp d10,d11,[sp,#16]
    ldp d12,d13,[sp,#32]
    ldp d14,d15,[sp,#48]
    ldp x29,x30,[sp,#64]
    add sp,sp,#96
    ret
