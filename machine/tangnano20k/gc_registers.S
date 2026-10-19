/* Stop-the-world register snapshot for the single-threaded IM/IMC Base host.
 * Save all integer registers, including caller-saved generated-code roots.
 * No floating registers exist in the supported soft-float ABI. */
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
.balign 4
.globl fpr_builtin_gc_collect
.type fpr_builtin_gc_collect,@function
fpr_builtin_gc_collect:
  addi sp,sp,-32*W
  SAVE x1,1*W(sp)
  SAVE x3,3*W(sp)
  SAVE x4,4*W(sp)
  SAVE x5,5*W(sp)
  SAVE x6,6*W(sp)
  SAVE x7,7*W(sp)
  SAVE x8,8*W(sp)
  SAVE x9,9*W(sp)
  SAVE x10,10*W(sp)
  SAVE x11,11*W(sp)
  SAVE x12,12*W(sp)
  SAVE x13,13*W(sp)
  SAVE x14,14*W(sp)
  SAVE x15,15*W(sp)
  SAVE x16,16*W(sp)
  SAVE x17,17*W(sp)
  SAVE x18,18*W(sp)
  SAVE x19,19*W(sp)
  SAVE x20,20*W(sp)
  SAVE x21,21*W(sp)
  SAVE x22,22*W(sp)
  SAVE x23,23*W(sp)
  SAVE x24,24*W(sp)
  SAVE x25,25*W(sp)
  SAVE x26,26*W(sp)
  SAVE x27,27*W(sp)
  SAVE x28,28*W(sp)
  SAVE x29,29*W(sp)
  SAVE x30,30*W(sp)
  SAVE x31,31*W(sp)
  addi t0,sp,32*W
  SAVE t0,2*W(sp)
  SAVE zero,0(sp)
  mv a0,sp
  call fpr_tangnano_gc_scan
  LOAD x1,1*W(sp)
  LOAD x3,3*W(sp)
  LOAD x4,4*W(sp)
  LOAD x5,5*W(sp)
  LOAD x6,6*W(sp)
  LOAD x7,7*W(sp)
  LOAD x8,8*W(sp)
  LOAD x9,9*W(sp)
  LOAD x10,10*W(sp)
  LOAD x11,11*W(sp)
  LOAD x12,12*W(sp)
  LOAD x13,13*W(sp)
  LOAD x14,14*W(sp)
  LOAD x15,15*W(sp)
  LOAD x16,16*W(sp)
  LOAD x17,17*W(sp)
  LOAD x18,18*W(sp)
  LOAD x19,19*W(sp)
  LOAD x20,20*W(sp)
  LOAD x21,21*W(sp)
  LOAD x22,22*W(sp)
  LOAD x23,23*W(sp)
  LOAD x24,24*W(sp)
  LOAD x25,25*W(sp)
  LOAD x26,26*W(sp)
  LOAD x27,27*W(sp)
  LOAD x28,28*W(sp)
  LOAD x29,29*W(sp)
  LOAD x30,30*W(sp)
  LOAD x31,31*W(sp)
  addi sp,sp,32*W
  ret
.size fpr_builtin_gc_collect,.-fpr_builtin_gc_collect
