"""Closed, single-hart activation runtime for the static-arena build gate.

No caller-supplied C/assembly/link flags enter this build. Startup performs no
stack accesses before selecting the reserved stack and no heap operations.
The ordinary entry then owns the fresh heap exclusively for one invocation.
"""

START = r'''
.section .text.entry,"ax",@progbits
.globl _start
_start:
    csrw mie, zero
    csrw mstatus, zero
    csrr t0, mhartid
    bnez t0, .Lpark
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, fpr_static_stack_end
    la tp, fpr_static_hart_state
    la t0, .Lfatal
    csrw mtvec, t0
    la t0, fpr_static_bss_start
    la t1, fpr_static_bss_end
.Lclear:
    bgeu t0, t1, .Lenter
    sd zero, 0(t0)
    addi t0, t0, 8
    j .Lclear
.Lenter:
    tail fpr_static_run
.balign 4
.Lfatal:
    lui t0, 0x100
    li t1, 0x13333
    sw t1, 0(t0)
.Lpark:
    j .Lpark
'''

LINK = r'''
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
 .data : { *(.data .data.* .sdata .sdata.*) PROVIDE(__global_pointer$ = . + 0x800); } > RAM
 .bss (NOLOAD) : { . = ALIGN(16); fpr_static_bss_start = .;
   *(.bss .bss.* .sbss .sbss.* COMMON)
   . = ALIGN(16); fpr_static_bss_end = .; } > RAM
 .arena_heap (NOLOAD) : { . = ALIGN(16); fpr_static_heap_guard = .; . += 16;
   fpr_static_heap_start = .; . += HEAP_BYTES; fpr_static_heap_end = .; . += 16; } > RAM
 .arena_stack (NOLOAD) : { . = ALIGN(16); fpr_static_stack_guard = .; . += 16;
   fpr_static_stack_start = .; . += STACK_BYTES; fpr_static_stack_end = .; . += 16; } > RAM
 ASSERT(fpr_static_stack_end + 16 + 65536 <= ORIGIN(RAM) + LENGTH(RAM), "static arenas exceed target reserve")
}
'''

HEAP_SETUP = r'''
 fpr_builtin_heap_plan plan;
 check(!fpr_builtin_heap_plan_range(fpr_static_heap_start,fpr_static_heap_end,&plan));
 check(plan.block_prefix_bytes==80 && plan.minimum_block_bytes==96);
 fpr_builtin_heap_init(fpr_static_heap_start,fpr_static_heap_end);
'''

CHECKPOINT = r''' check(fpr_builtin_live_allocations()==0);
 for(unsigned i=0;i<16;i++){
  check(fpr_static_heap_guard[i]==0xa5 && fpr_static_heap_end[i]==0xa5);
  check(fpr_static_stack_guard[i]==0xa5 && fpr_static_stack_end[i]==0xa5);
 }
'''

CALLER = r'''
#include "builtin.h"
#include <stdint.h>
const hdr_t fpr_unit={0,0},fpr_true={1,1},fpr_false={1,0};
_Alignas(16) uw fpr_static_hart_state[128];
_Static_assert(1 + FPR_ARGSPILL <= 128,"reserved hart argument state is too small");
volatile uw fpr_static_result;
volatile uw fpr_static_status;
extern unsigned char fpr_static_heap_guard[],fpr_static_heap_start[],fpr_static_heap_end[];
extern unsigned char fpr_static_stack_guard[],fpr_static_stack_end[];
DECLARATION
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
static void number(uw n){char b[32];unsigned k=0;do{b[k++]='0'+n%10;n/=10;}while(n);while(k){char s[]={b[--k],0};say(s);}}
__attribute__((noreturn)) static void finish(int failed){
 fpr_static_status=failed?2:1;*(volatile unsigned*)0x100000=failed?0x13333:0x5555;for(;;){}
}
void fpr_cpanic(const char*s){say("STATIC_ARENA_FAIL ");say(s);say("\n");finish(1);}
static void check(int ok){if(!ok)fpr_cpanic("geometry, ownership or guard");}
__attribute__((noreturn)) void fpr_static_run(void){
 for(unsigned i=0;i<16;i++){
  fpr_static_heap_guard[i]=fpr_static_heap_end[i]=0xa5;
  fpr_static_stack_guard[i]=fpr_static_stack_end[i]=0xa5;
 }
 HEAP_SETUP
 INVOCATION
''' + CHECKPOINT + r''' say("STATIC_ARENA_PASS result=");number(fpr_static_result);say("\n");finish(0);
}
'''
