/* Guest instruction count around the generated main; actual ARC runtime and
 * self-hosted allocator, with startup and final result release outside it. */
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern void hal_putc(char);
static uw retired(void){uw n;__asm__ volatile("rdinstret %0":"=r"(n)::"memory");return n;}
V __wrap_fpr_fn_main(void){
  uw start=retired();V result=__real_fpr_fn_main();uw count=retired()-start;
  const char *p="ARC_GUEST_INSNS=";while(*p)hal_putc(*p++);
  static const char digits[]="0123456789abcdef";
  for(unsigned i=0;i<16;i++)hal_putc(digits[(count>>(4*(15-i)))&15]);
  hal_putc('\n');return result;
}
