#include <stdio.h>
long loop(long acc,long n){ while(n){ acc+=n&7; n--; } return acc; }
int main(int c,char**v){ printf("%ld\n",loop(0,10000000L+(c>5))); }
