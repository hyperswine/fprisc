#include <stdio.h>
#include <stdlib.h>
int main(){ long *v=malloc(1000*sizeof(long)); for(int i=0;i<1000;i++) v[i]=1000-i; long acc=0;
 for(int k=10000;k>0;k--){ long s=0; for(int i=0;i<1000;i++) s+=v[i]; acc=(acc+s)&1048575;} printf("%ld\n",acc);}
