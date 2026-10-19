#if __riscv_xlen == 32
#define W 4
#define SAVE sw
#define LOAD lw
#else
#define W 8
#define SAVE sd
#define LOAD ld
#endif
.text
.globl gc_register_probe
gc_register_probe:
  addi sp,sp,-4*W
  SAVE ra,0(sp)
  SAVE s1,W(sp)
  SAVE s2,2*W(sp)
  li a0,64
  call fpr_alloc
  mv s1,a0
  li t0,1234
  SAVE t0,0(s1)
  li a0,64
  call fpr_alloc
  mv t5,a0
  li t0,5678
  SAVE t0,0(t5)
  li a0,0
  li a1,0
  li a2,0
  li a3,0
  li a4,0
  li a5,0
  li a6,0
  li a7,0
  li t0,0
  li t1,0
  li t2,0
  li t3,0
  li t4,0
  li t6,0
  call fpr_builtin_gc_collect
  mv s2,t5
  call fpr_builtin_live_allocations
  li t0,2
  bltu a0,t0,1f
  LOAD t0,0(s1)
  li t1,1234
  bne t0,t1,1f
  LOAD t0,0(s2)
  li t1,5678
  bne t0,t1,1f
  li a0,0
  j 2f
1:li a0,1
2:LOAD ra,0(sp)
  LOAD s1,W(sp)
  LOAD s2,2*W(sp)
  addi sp,sp,4*W
  ret
