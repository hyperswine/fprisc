#include "builtin.h"
void fpr_test_irq_verify(const uw *p) {
  if(*(volatile uw *)0x81000000 != 1) fpr_cpanic("probe: no interrupt delivered");
  for(uw i=0;i<64;i++) if(p[i]!=p[64+i]) fpr_cpanic("probe: register changed");
  if(p[128]!=97) fpr_cpanic("probe: fcsr changed");
}
