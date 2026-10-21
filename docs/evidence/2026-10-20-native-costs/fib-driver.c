
#include <stdio.h>
#include <time.h>
extern long fib_plain(long), fib_checked(long);
int main(int argc, char **argv) {
    struct timespec a,b;
    if (clock_gettime(CLOCK_MONOTONIC,&a)) return 2;
    long r = argc > 1 ? fib_checked(35) : fib_plain(35);
    if (clock_gettime(CLOCK_MONOTONIC,&b)) return 2;
    if (r != 9227465) return 1;
    printf("%ld %lld\n",r,(long long)(b.tv_sec-a.tv_sec)*1000000000LL+b.tv_nsec-a.tv_nsec);
    return 0;
}
