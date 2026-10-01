#!/usr/bin/env python3
"""Force a losing first sender to resume after a winner has queued a Result.

Compile the actual actors.c in a small harness, inserting a scheduling hook
only into the test copy. Dead stripping removes unrelated runtime entrypoints.
"""
from pathlib import Path
import os, shlex, subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[1]
def check(temp):
    tmp = Path(temp)
    source = (ROOT / 'runtime/actors.c').read_text()
    marker = '    if (!free_slot) return sh_chan(a);'
    assert source.count(marker) == 1
    source = source.replace(marker, marker + '\n    claim_interleave(a, key);')
    (tmp / 'actors-claim.c').write_text(source)
    harness = r'''
#include <assert.h>
#include <stdio.h>
static void claim_interleave(void *a, unsigned long key);
#include "actors-claim.c"
static acb_t winner, loser, previous;
static int inject;
static struct { hdr_t h; V value; } result = {{T_RESULT, 0}, 0};
static void claim_interleave(void *av, unsigned long key) {
  if (!inject || key != (uw)&loser) return;
  inject = 0; /* resume the winner while the loser holds a stale candidate */
  acb_t *a = av;
  chan_t *c = chan_for(a, (uw)&winner, 1);
  uint32_t rt = c->rt;
  SLOT(c->rv, rt) = (V)&result;
  __atomic_store_n(&c->rt, rt + 1, __ATOMIC_RELEASE);
}
int main(void) {
  /* Also cover dead, drained slot reuse with wrapped, nonzero counters. */
  for (int reclaimed = 0; reclaimed < 2; reclaimed++) {
    acb_t a = {0}; chan_t ch[MAXSND] = {0};
    a.ch = ch; winner.var = loser.var = ST_READY; previous.var = ST_DEAD;
    for (int i = 0; i < MAXSND; i++) {
      ch[i].rv = &ch[i].rv0;
      ch[i].rv0.cap = RING_CAP; ch[i].rv0.slots = ch[i].slots0;
    }
    ch[SHIDX].sender = SHARED_KEY;
    if (reclaimed) {
      ch[0].sender = (uw)&previous;
      ch[0].rh = ch[0].rt = UINT32_MAX;
    }
    inject = 1;
    chan_t *c = chan_for(&a, (uw)&loser, 1);
    assert(c != &ch[0]); /* loser retries, never owns the winner's ring */
    assert(ch_count(&ch[0]) == 1);
    assert(p_res(&a, 0));
    winner.var = ST_DEAD;
    assert(chan_for(&a, (uw)&previous, 1) != &ch[0]); /* nonempty is never reclaimed */
    assert(take_at(&a, &ch[0], ch[0].rh) == (V)&result);
    assert(!p_res(&a, 0));
    /* Middle removal in dedicated and shared rings keeps unrelated events,
     * including their sender tags, across free-running counter wraparound. */
    for (int shared = 0; shared < 2; shared++) {
      c = &ch[shared ? SHIDX : 0];
      uw tags[RING_CAP] = {0};
      c->rv0.from = shared ? tags : 0;
      c->rh = UINT32_MAX - 1; c->rt = 1;
      SLOT(c->rv, c->rh) = TAG(7);
      SLOT(c->rv, c->rh + 1) = (V)&result;
      SLOT(c->rv, c->rh + 2) = TAG(9);
      if (shared) {
        TAGAT(c->rv, c->rh) = (uw)&loser;
        TAGAT(c->rv, c->rh + 1) = (uw)&winner;
        TAGAT(c->rv, c->rh + 2) = (uw)&previous;
      }
      assert(p_res(&a, 0));
      assert(take_at(&a, c, c->rh + 1) == (V)&result);
      assert(!p_res(&a, 0));
      if (shared) assert(TAGAT(c->rv, c->rh) == (uw)&loser);
      assert(take_at(&a, c, c->rh) == TAG(7));
      if (shared) assert(TAGAT(c->rv, c->rh) == (uw)&previous);
      assert(take_at(&a, c, c->rh) == TAG(9));
      assert(ch_count(c) == 0);
    }
  }
  puts("actor claim interleaving: PASS");
}
'''
    (tmp / 'actor-claim.c').write_text(harness)
    linker = '-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'
    exe = tmp / 'actor-claim'
    subprocess.run([*shlex.split(os.environ.get('CC', 'cc')), '-O2', '-DFPR_POSIX',
                    '-ffunction-sections', '-fdata-sections', '-I', str(ROOT / 'runtime'),
                    str(tmp / 'actor-claim.c'), linker, '-o', str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=10)
if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='fpr-actor-claim-') as temp:
        check(temp)
