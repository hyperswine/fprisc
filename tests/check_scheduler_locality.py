#!/usr/bin/env python3
"""Exercise the real scheduler selector, bounded hints and migration races."""
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "actors-locality.c"
fpr_hart_t fpr_harts[FPR_NHARTS];
uw fpr_live_harts = 2;
FPR_TLS fpr_hart_t *fpr_posix_hart;
static uw reaped;
static void test_reap(acb_t *a) { (void)a; reaped++; }
void hal_ipi_send(uw hart) { (void)hart; }
void hal_putc(char c) { (void)c; }
void fpr_cpanic(const char *why) { fprintf(stderr,"%s\n",why); __builtin_trap(); }
static acb_t actors[12];
static fpr_hart_t *reset(void) {
  memset(fpr_harts,0,sizeof fpr_harts); memset(actors,0,sizeof actors);
  memset(xr,0,sizeof xr); g_adm=1; g_tau=64; reaped=0;
  fpr_posix_hart=&fpr_harts[0]; fpr_harts[1].id=1;
  for (uw i=0;i<12;i++) { actors[i].var=ST_READY; actors[i].weight=1; actors[i].id=i+1; }
  return fpr_posix_hart;
}
int main(void) {
  fpr_hart_t *h=reset(); acb_t *peer=&actors[0], *other=&actors[1];
  /* A real local wake records a one-shot hint; the normal FIFO still wins. */
  h->current=other; peer->var=ST_BLOCKED; wake(peer);
  assert(h->wake_hint==peer && peer->in_bl);
  backlog_add(h,peer); assert(h->bl_len==1); /* late/duplicate ship */
  other->in_rq=1; h->rq_head=h->rq_tail=other; h->rq_len=1;
  assert(deq(h)==other); assert(deq(h)==peer);
  assert(!h->wake_hint && !peer->in_bl && !peer->in_rq);
  /* Two preferences then an ordinary weighted choice. A very large weight
   * makes that choice deterministic for this fixture's LCG sequence. */
  h=reset(); peer=&actors[0]; other=&actors[1]; other->weight=1000000;
  backlog_add(h,other);
  for (uw i=0;i<3;i++) {
    backlog_add(h,peer); h->wake_hint=peer;
    acb_t *a=select_backlog(h);
    assert(a==(i<2?peer:other));
  }
  assert(h->handoff_run==0 && !h->wake_hint);
  /* Aging and priority both outrank a wake, even with budget left. */
  h=reset(); backlog_add(h,&actors[0]); g_adm=100;
  backlog_add(h,&actors[1]); h->wake_hint=&actors[1];
  assert(select_backlog(h)==&actors[0]);
  h=reset(); actors[0].prio=1; backlog_add(h,&actors[0]);
  backlog_add(h,&actors[1]); h->wake_hint=&actors[1];
  assert(select_backlog(h)==&actors[0]);
  /* Continuous wakes cannot starve ten other actors. Admission waits retain
   * the same conservative tau + backlog + one bound; hints never restamp. */
  h=reset(); g_tau=3; uw counts[12]={0}, max_wait=0;
  for (uw i=0;i<11;i++) backlog_add(h,&actors[i]);
  for (uw i=0;i<2000;i++) {
    h->wake_hint=&actors[0]; acb_t *a=select_backlog(h); assert(a);
    uw wait=++g_adm-a->ready_at; if (wait>max_wait) max_wait=wait;
    counts[a->id-1]++; backlog_add(h,a);
  }
  assert(max_wait<=g_tau+12);
  for (uw i=0;i<11;i++) assert(counts[i]>100);
  /* Hints are references to identities, never admissions: dead/blocked
   * entries disappear and no stale pointer can get selected. */
  h=reset(); backlog_add(h,&actors[0]); backlog_add(h,&actors[1]);
  actors[0].var=ST_DEAD; h->wake_hint=&actors[0];
  assert(select_backlog(h)==&actors[1] && reaped==1);
  h=reset(); backlog_add(h,&actors[0]); actors[0].var=ST_BLOCKED;
  h->wake_hint=&actors[0]; assert(!select_backlog(h));
  /* A thief still skips pinned, unsaved and blocked contexts. A hint to
   * the stolen actor misses. A late wake follows its new owner exactly once. */
  h=reset(); actors[0].pin=1; actors[1].running=1; actors[2].var=ST_BLOCKED;
  for (uw i=0;i<4;i++) backlog_add(h,&actors[i]);
  h->wake_hint=&actors[3]; assert(steal_from(h,1)==&actors[3]);
  assert(actors[3].hart==1 && !actors[3].in_bl);
  backlog_add(h,&actors[3]); drain(&fpr_harts[1]);
  assert(fpr_harts[1].bl_len==1 && actors[3].in_bl);
  backlog_add(&fpr_harts[1],&actors[3]); assert(fpr_harts[1].bl_len==1);
  assert(select_backlog(h)!=&actors[3]);
  assert(select_backlog(&fpr_harts[1])==&actors[3]);
  puts("scheduler locality: bounded hints, FIFO, aging, priority, stale wakes, pinning and late-wake migration PASS");
}
'''
with tempfile.TemporaryDirectory(prefix='fpr-scheduler-locality-') as directory:
    tmp=Path(directory)
    source=(ROOT/'runtime/actors.c').read_text()
    begin=source.index('static void reap(acb_t *a) {')
    end=source.index('\nextern void fpr_ctx_switch',begin)
    source=source[:begin]+'static void test_reap(acb_t *a);\nstatic void reap(acb_t *a) { test_reap(a); }\n'+source[end:]
    (tmp/'actors-locality.c').write_text(source)
    (tmp/'check.c').write_text(HARNESS)
    linker='-Wl,-dead_strip' if sys.platform=='darwin' else '-Wl,--gc-sections'
    # GCC's SLP vectoriser pools fpr_plane_export's function-pointer pairs in the
    # one anonymous .data.rel.ro.local section that also holds main's constants,
    # so GNU ld keeps the whole plane (fpr_actor_fail, a_spawn_heap, ...) and
    # then fails on their runtime symbols. ld64 strips per symbol and is fine.
    novec=[] if sys.platform=='darwin' else ['-fno-tree-slp-vectorize']
    exe=tmp/'check'
    subprocess.run([*shlex.split(os.environ.get('CC','cc')),'-O2',*novec,'-DFPR_POSIX','-DFPR_NHARTS=2',
                    '-ffunction-sections','-fdata-sections','-I',str(ROOT/'runtime'),tmp/'check.c',linker,'-o',exe],
                   check=True,timeout=60)
    subprocess.run([exe],check=True,timeout=10)
    native=tmp/'native'
    env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'))
    subprocess.run([ROOT/'fpr','build',ROOT/'tests/base/locality.fpr','--harts','4','-o',native],
                   cwd=ROOT,env=env,check=True,capture_output=True,text=True,timeout=180)
    for harts in ('1','4','4'):
        p=subprocess.run([native],env=dict(env,FPR_HARTS=harts,FPR_BLOCK_SPIN_NS='0'),
                         capture_output=True,text=True,timeout=30)
        assert p.returncode==0 and p.stdout=='locality 200030000\n',(harts,p.stdout,p.stderr)
    print('scheduler locality: contended request/reply completes with pinned competitors on one/four harts PASS')
