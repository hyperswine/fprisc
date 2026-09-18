/* hjrun.c -- execute a hand-JIT blob on a dumped case and compare.
 *
 * The Sol VM, run with SOL_HJIT_XCHECK=<dir>, writes for every native
 * kernel it installs the blob for the host ISA AND for the other one
 * (<sym>.x86-64.bin / <sym>.a64.bin), and for every native call a case
 * file with the exact inputs and the host's outputs.  This program maps
 * a blob executable, replays the case through the same driver ABI, and
 * reports whether the outputs agree word for word.  Built for aarch64
 * and run under qemu-user it is the proof that the A64 backend computes
 * what the x86-64 backend (and therefore the interpreter) computed.
 *
 *   hjrun BLOB CASE
 *
 * case words (LE i64): magic, kind, n, nEx, nCols, nExp, acc0,
 *   extras[nEx], cols[nCols][n], expected[nExp]
 * kind 0/2: map or filter, expected = k : out[k]
 * kind 1/3: fold,          expected = [r]
 * kind 4:   vecmapr,       expected = nOuts : out[nOuts][n]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

typedef int64_t (*drv4)(int64_t *, int64_t *, int64_t, int64_t *);
typedef int64_t (*drvf)(int64_t *, int64_t *, int64_t, int64_t);
typedef int64_t (*drv5)(int64_t *, int64_t *, int64_t **, int64_t, int64_t *);
typedef int64_t (*drvf5)(int64_t *, int64_t *, int64_t **, int64_t, int64_t);

static void *slurp(const char *path, long *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(2); }
  fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
  void *p = malloc(*len + 8);
  if (fread(p, 1, *len, f) != (size_t)*len) { perror("read"); exit(2); }
  fclose(f);
  return p;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: hjrun BLOB CASE\n"); return 2; }
  long blen, clen;
  uint8_t *blob = slurp(argv[1], &blen);
  int64_t *w = slurp(argv[2], &clen);
  if (w[0] != 0x484A4954) { fprintf(stderr, "bad case magic\n"); return 2; }
  int64_t kind = w[1], n = w[2], nEx = w[3], nCols = w[4], nExp = w[5], acc0 = w[6];
  int64_t *extras = w + 7, *colw = extras + nEx, *expect = colw + nCols * n;
  long sz = (blen + 4095) & ~4095L;
  void *code = mmap(0, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  memcpy(code, blob, blen);
  if (mprotect(code, sz, PROT_READ | PROT_EXEC) != 0) { perror("mprotect"); return 2; }
  __builtin___clear_cache((char *)code, (char *)code + sz);
  int64_t fuel = 1 << 30;
  int64_t **cols = calloc(nCols + 1, sizeof(int64_t *));
  for (int64_t c = 0; c < nCols; c++) cols[c] = colw + c * n;
  int64_t *got = calloc((size_t)(nExp + 1 + 8 * n), 8);
  int64_t ngot = 0;
  switch (kind) {
    case 0: { int64_t *out = calloc(n + 1, 8); int64_t k = ((drv4)code)(&fuel, cols[0], n, out);
              got[0] = k; memcpy(got + 1, out, k * 8); ngot = 1 + k; break; }
    case 1: { got[0] = ((drvf)code)(&fuel, cols[0], n, acc0); ngot = 1; break; }
    case 2: { int64_t ex[16]; memcpy(ex, extras, nEx * 8); int64_t *out = calloc(n + 1, 8);
              int64_t k = ((drv5)code)(&fuel, ex, cols, n, out);
              got[0] = k; memcpy(got + 1, out, k * 8); ngot = 1 + k; break; }
    case 3: { int64_t ex[16]; memcpy(ex, extras, nEx * 8);
              got[0] = ((drvf5)code)(&fuel, ex, cols, n, acc0); ngot = 1; break; }
    case 4: { int64_t ex[16]; memcpy(ex, extras, nEx * 8); int64_t nOuts = expect[0];
              int64_t *outs[8]; for (int64_t j = 0; j < nOuts; j++) outs[j] = calloc(n + 1, 8);
              ((drv5)code)(&fuel, ex, cols, n, (int64_t *)outs);
              got[0] = nOuts; ngot = 1;
              for (int64_t j = 0; j < nOuts; j++) { memcpy(got + ngot, outs[j], n * 8); ngot += n; }
              break; }
    default: fprintf(stderr, "unknown kind %ld\n", (long)kind); return 2;
  }
  if (ngot != nExp) { printf("FAIL %s: %ld words, expected %ld\n", argv[2], (long)ngot, (long)nExp); return 1; }
  for (int64_t i = 0; i < nExp; i++)
    if (got[i] != expect[i]) {
      printf("FAIL %s: word %ld = %016llx, expected %016llx\n", argv[2], (long)i,
             (unsigned long long)got[i], (unsigned long long)expect[i]);
      return 1;
    }
  printf("ok %s (kind %ld, n=%ld, %ld words, fuel used %ld)\n", argv[2], (long)kind, (long)n, (long)nExp, (long)((1 << 30) - fuel));
  return 0;
}
