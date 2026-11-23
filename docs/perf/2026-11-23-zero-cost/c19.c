#include <stdio.h>
typedef struct {double x,y,z;} V;
static V add3(V a,V b){ V r={a.x+b.x,a.y+b.y,a.z*0.5+b.z}; return r;}
int main(int c,char**v){ V s={0,0,0}; for(long i=10000000L+(c>5);i>0;i--){ V b={0.5,0.25,1.0}; s=add3(s,b);} printf("%ld\n",(long)(s.x+s.y+s.z));}
