#include <stdio.h>
enum Op {Add,Sub,Mul,Xor};
static enum Op opOf(long n){ switch(n&3){case 0:return Add;case 1:return Sub;case 2:return Mul;default:return Xor;} }
static long ap(enum Op o,long a,long b){ switch(o){case Add:return a+b;case Sub:return a-b;case Mul:return (a*b)&65535;default:return a^b;} }
int main(int c,char**v){ long acc=0; for(long i=10000000L+(c>5);i>0;i--) acc=ap(opOf(i),acc,i)&1048575; printf("%ld\n",acc);}
