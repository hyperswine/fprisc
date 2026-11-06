/* ctx_a64_fp.c -- an actor context's d8..d15 survive a park and a migration.
 *
 * The reduction of QOS tests/qsysfail.fpr check 12 at 4 harts
 * (docs/2026-11-06-QOSAPP-A64-FP-CONTEXT.md).  There, clang kept the
 * constant {T_RESULT, Ok} in d8 across the calls in a_spawn_inbox; the
 * spawner parked, resumed on another hart, and stored that hart's d8 as the
 * result header, so `Ok actor` read as `Err actor`.  QOS apps' fpr_ctx_switch
 * did not save d8..d15.
 *
 * Here one context parks ROUNDS times and is resumed each time by the next of
 * HARTS threads, each of which enters with its own d8..d15.  Every park sets
 * the context's d8..d15 and checks them on resumption.  Prints "ok" or the
 * first mismatch; the exit code is the mismatch count (capped at 100). */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define HARTS 4
#define ROUNDS 1000

extern void fpr_ctx_switch(uintptr_t *save, uintptr_t *load);
extern void test_switch_with(uintptr_t *save, uintptr_t *load, const uint64_t *in, uint64_t *out);

/* 24 words: the widest A64 context (FPR_CTX_WORDS) */
static uintptr_t actor_ctx[24], hart_ctx[HARTS][24];
static uint64_t actor_stack[16384] __attribute__((aligned(16)));
static volatile int turn, cur, done;
static int bad, first_round = -1, first_reg, first_hart;
static uint64_t first_want, first_got;

static void actor_entry(void) {
  for (int r = 0; r < ROUNDS; r++) {
    uint64_t in[8], out[8];
    for (int i = 0; i < 8; i++) in[i] = 0xA000000000000000ull | ((uint64_t)r << 8) | (uint64_t)i;
    test_switch_with(actor_ctx, hart_ctx[cur], in, out);
    for (int i = 0; i < 8; i++)
      if (out[i] != in[i] && bad++ == 0) {
        first_round = r; first_reg = 8 + i; first_hart = cur;
        first_want = in[i]; first_got = out[i];
      }
  }
  done = 1;
  for (;;) fpr_ctx_switch(actor_ctx, hart_ctx[cur]);
}

static void *hart(void *arg) {
  int me = (int)(intptr_t)arg;
  uint64_t mine[8], after[8];
  for (int i = 0; i < 8; i++) mine[i] = 0xD000000000000000ull | ((uint64_t)me << 8) | (uint64_t)i;
  for (;;) {
    while (__atomic_load_n(&turn, __ATOMIC_ACQUIRE) != me && !__atomic_load_n(&done, __ATOMIC_ACQUIRE)) ;
    if (__atomic_load_n(&done, __ATOMIC_ACQUIRE)) return 0;
    cur = me;
    test_switch_with(hart_ctx[me], actor_ctx, mine, after); /* returns when the actor parks */
    if (__atomic_load_n(&done, __ATOMIC_ACQUIRE)) {
      __atomic_store_n(&turn, -1, __ATOMIC_RELEASE);
      return 0;
    }
    __atomic_store_n(&turn, (me + 1) % HARTS, __ATOMIC_RELEASE);
  }
}

int main(void) {
  actor_ctx[0] = (uintptr_t)actor_entry;
  actor_ctx[1] = (uintptr_t)(actor_stack + 16384);
  pthread_t t[HARTS];
  for (int i = 0; i < HARTS; i++) pthread_create(&t[i], 0, hart, (void *)(intptr_t)i);
  for (int i = 0; i < HARTS; i++) pthread_join(t[i], 0);
  if (!bad) { printf("ok: %d parks across %d harts kept d8..d15\n", ROUNDS, HARTS); return 0; }
  printf("lost: %d of %d registers; first at park %d, d%d resumed on hart %d: want %#llx got %#llx\n",
         bad, ROUNDS * 8, first_round, first_reg, first_hart,
         (unsigned long long)first_want, (unsigned long long)first_got);
  return bad > 100 ? 100 : bad;
}
