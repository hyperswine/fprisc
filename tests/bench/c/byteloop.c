/* C reference for tests/bench/byteloop.fpr: sum the bytes of an 800,000-byte
   string ("abcdefgh" x 100000), 50 times. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static long sum_bytes(const char *s, long n) {
  long acc = 0;
  for (long i = 0; i < n; i++) acc += (unsigned char)s[i];
  return acc;
}
int main(void) {
  long n = 8L * 100000;
  char *s = malloc(n + 1);
  for (long i = 0; i < n; i += 8) memcpy(s + i, "abcdefgh", 8);
  s[n] = 0;
  long acc = 0;
  for (int k = 0; k < 50; k++) acc += sum_bytes(s, (long)strlen(s));
  printf("byteloop = %ld\n", acc);
  free(s);
  return 0;
}
