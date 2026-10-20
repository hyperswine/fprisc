
#include <stdint.h>
long fib_plain(long n) {
    if (n < 2) return n;
    return fib_plain(n-1) + fib_plain(n-2);
}
static long fit63(long r) {
    if (r < -4611686018427387904L || r > 4611686018427387903L) __builtin_trap();
    return r;
}
long fib_checked(long n) {
    if (n < 2) return n;
    long a = fib_checked(fit63(n-1));
    long b = fib_checked(fit63(n-2));
    long r;
    if (__builtin_add_overflow(a,b,&r)) __builtin_trap();
    return fit63(r);
}
