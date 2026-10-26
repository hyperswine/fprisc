/* C reference for tests/bench/fib.fpr: the same doubly recursive fib. */
#include <stdio.h>
static long fib(long n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int main(void) { printf("fib 35 = %ld\n", fib(35)); return 0; }
