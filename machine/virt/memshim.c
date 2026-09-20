/* memshim.c — freestanding mem* for the virt machine layer.
 *
 * Even with -ffreestanding -fno-builtin, GCC is entitled to emit calls to
 * memset/memcpy/memmove (C11 note: the implementation may assume these
 * exist). gcc 13.2 does so in runtime/core/vec.c (struct/column zeroing in
 * h_fromList/h_eqS/h_gather). The posix build gets them from libc and the
 * qosapp build from support.c; the virt build had none.
 */
#include <stddef.h>

void *memset(void *dst, int c, size_t n) {
  unsigned char *d = dst;
  while (n--) *d++ = (unsigned char)c;
  return dst;
}

void *memcpy(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  while (n--) *d++ = *s++;
  return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  if (d < s) { while (n--) *d++ = *s++; }
  else { d += n; s += n; while (n--) *--d = *--s; }
  return dst;
}
