#!/usr/bin/env python3
"""Exercise the real scheduler selector, bounded hints and migration races."""
from pathlib import Path
import os
import json
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "actors-locality.c"
fpr_hart_t fpr_harts[FPR_NHARTS];
uw fpr_live_harts = 2;
FPR_TLS fpr_hart_t *fpr_posix_hart;
static uw reaped;
static void test_reap(acb_t *a) { (void)a; reaped++; }
static acb_t *cancel_at_dispatch;
static uint32_t dispatch_state;
static void before_dispatch_check(acb_t *actor) {
  if (actor == cancel_at_dispatch) {
    __atomic_store_n(&actor->var,dispatch_state,__ATOMIC_RELEASE);
    cancel_at_dispatch=0;
  }
}
static unsigned rung;
void hal_ipi_send(uw hart) { if (hart==1) __atomic_store_n(&rung,1,__ATOMIC_RELAXED); }
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
/* In each fresh round the thief scans once, with no timeout or second poll.
 * A miss must leave a doorbell after the eligible entry is published. */
enum { rounds = 10000 };
static unsigned start, done;
static acb_t *taken;
static void *idle_thief(void *unused) {
  (void)unused;
  fpr_hart_t *h=&fpr_harts[1];
  fpr_posix_hart=h;
  for (unsigned i=1;i<=rounds;i++) {
    while (__atomic_load_n(&start,__ATOMIC_ACQUIRE)!=i) {}
    __atomic_store_n(&h->idle,1,__ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    taken=steal(h);
    __atomic_store_n(&done,i,__ATOMIC_RELEASE);
  }
  return 0;
}
static void check_offer(void) {
  pthread_t thief;
  assert(!pthread_create(&thief,0,idle_thief,0));
  for (unsigned i=1;i<=rounds;i++) {
    fpr_hart_t *h=reset();
    __atomic_store_n(&rung,0,__ATOMIC_RELAXED);
    __atomic_store_n(&start,i,__ATOMIC_RELEASE);
    for (unsigned k=0;k<=DONATE_HI;k++) {
      actors[k].pin=k<DONATE_HI;
      backlog_add(h,&actors[k]);
    }
    while (__atomic_load_n(&done,__ATOMIC_ACQUIRE)!=i) {}
    if (!taken) {
      assert(__atomic_load_n(&rung,__ATOMIC_RELAXED));
      taken=steal(&fpr_harts[1]);
    }
    assert(taken==&actors[DONATE_HI] && h->bl_len==DONATE_HI);
  }
  assert(!pthread_join(thief,0));
}
static void trace_dispatch(void) {
  fpr_hart_t *h = reset();
  g_max_wait = 0;
  g_tau = 4;
  for (unsigned round = 0; round < 60; round++) {
    unsigned count = 1 + round % 12;
    for (unsigned i = 0; i < count; i++) {
      actors[i].weight = 1 + (i + round) % 8;
      backlog_add(h, &actors[i]);
    }
    for (unsigned i = 0; i < count; i++) {
      h->wake_hint = &actors[(round + i) % count];
      acb_t *chosen = deq(h);
      assert(chosen);
      printf("dispatch %u %u %lu %lu %lu %lu %lu %lu\n", round, i,
             (unsigned long)chosen->id, (unsigned long)g_adm,
             (unsigned long)h->lcg, (unsigned long)g_max_wait,
             (unsigned long)h->rq_len, (unsigned long)h->bl_len);
    }
    assert(!deq(h));
  }
}
extern uint64_t clock_reads;
static int spin_probes;
static int spin_probe(acb_t *actor, uw succeed) {
  (void)actor;
  spin_probes++;
  return succeed != 0;
}
static void check_spin(void) {
  fpr_hart_t *h = reset();
  struct spin_window *w = &spin_windows[h->id];
  *w = (struct spin_window){2000, 2000, 1};
  for (int i = 0; i < 12; i++) assert(!spin_until(&actors[0], spin_probe, 0));
  assert(w->current == (FPR_ADAPTIVE_BLOCK_SPIN ? 0 : 2000));
  spin_probes = 0;
  clock_reads = 0;
  assert(!spin_until(&actors[0], spin_probe, 0));
  assert(FPR_ADAPTIVE_BLOCK_SPIN ? spin_probes == 1 : spin_probes > 1);
  assert(spin_until(&actors[0], spin_probe, 1) && w->current == 2000);
  assert(FPR_ADAPTIVE_BLOCK_SPIN ? clock_reads == 0 : clock_reads > 0);
  spin_probes = 0;
  h->rq_head = &actors[1];
  assert(!spin_until(&actors[0], spin_probe, 1) && spin_probes == 0);
  h->rq_head = 0;
  *w = (struct spin_window){0, 0, 1};
  assert(!spin_until(&actors[0], spin_probe, 1) && spin_probes == 0);
}
int main(void) {
  check_spin();
  fpr_hart_t *h=reset(); acb_t *peer=&actors[0], *other=&actors[1];
  /* An empty selection can complete even while the backlog lock is held.
   * It consumes the stale preference without drawing or admitting work. */
  h->wake_hint=peer; h->handoff_run=1; h->lcg=17;
  fpr_lock(&h->bl_lock);
  assert(!select_backlog(h));
  fpr_unlock(&h->bl_lock);
  assert(!h->wake_hint && !h->handoff_run && h->lcg==17 && g_adm==1);
  /* A real local wake records a one-shot hint; the normal FIFO still wins. */
  h->current=other; peer->var=ST_BLOCKED; wake(peer);
  assert(h->wake_hint==peer && peer->in_bl);
  backlog_add(h,peer); assert(h->bl_len==1); /* late/duplicate ship */
  other->in_rq=1; h->rq_head=h->rq_tail=other; h->rq_len=1;
  assert(deq(h)==other); assert(deq(h)==peer);
  assert(!h->wake_hint && !peer->in_bl && !peer->in_rq);
  /* A sole preferred wake is eligible for direct dispatch only after
   * normal selection and admission. Compare both builds at that boundary. */
  h=reset(); peer=&actors[0]; backlog_add(h,peer); h->wake_hint=peer;
  acb_t *direct=refill(h);
  assert(g_adm==2 && !h->handoff_run && !h->wake_hint);
  if (FPR_DIRECT_LOCAL_HANDOFF) assert(direct==peer && !h->rq_len && !peer->in_rq);
  else assert(!direct && peer->in_rq && deq(h)==peer);
  h=reset(); peer=&actors[0]; backlog_add(h,peer); h->wake_hint=peer;
  assert(deq(h)==peer && !h->rq_head && !peer->in_rq && !peer->in_bl);
  /* Force the status change after admission and before the final dispatch
   * check. A parked peer can be woken again, a dead peer is reaped once. */
  for (int dead=0;dead<=1;dead++) {
    h=reset(); peer=&actors[0]; other=&actors[1];
    backlog_add(h,peer); h->wake_hint=peer;
    cancel_at_dispatch=peer; dispatch_state=dead ? ST_DEAD : ST_BLOCKED;
    assert(!deq(h) && !cancel_at_dispatch && reaped==(uw)dead);
    assert(!peer->in_bl && !peer->in_rq && !h->rq_len && !h->bl_len);
    backlog_add(h,other); assert(deq(h)==other);
    if (!dead) { wake(peer); assert(deq(h)==peer); }
    assert(!deq(h) && reaped==(uw)dead);
  }
  /* A lone candidate and later weighted competitors must see exactly the
   * same selections and generator state as the original reservoir walk. */
  for (uw n=1;n<=12;n++) for (uw seed=0;seed<32;seed++) {
    h=reset(); h->lcg=seed;
    uw rng=seed, total=0, selected=0;
    for (uw i=0;i<n;i++) {
      actors[i].weight=1+(i+seed)%7;
      backlog_add(h,&actors[i]);
      total+=actors[i].weight;
      rng=rng*1103515245u+12345u;
      if ((rng>>16)%total<actors[i].weight) selected=i;
    }
    assert(select_backlog(h)==&actors[selected] && h->lcg==rng);
  }
  /* Place the first aged candidate at each list position. A later
   * priority entry supersedes it, and every ready actor consumes a draw. */
  for (unsigned first=0; first<12; first++) {
    h=reset(); g_adm=100; uw rng=h->lcg;
    for (unsigned i=0; i<12; i++) {
      backlog_add(h,&actors[i]);
      if (i==first) actors[i].ready_at=1;
      rng=rng*1103515245u+12345u;
    }
    h->wake_hint=&actors[0];
    if (first%2) actors[11].prio=1;
    assert(select_backlog(h)==&actors[first%2 ? 11 : first]);
    assert(h->lcg==rng && !h->wake_hint && !h->handoff_run);
  }
  /* Four maximum tagged weights plus four units used to wrap the sum
   * to zero. All draws after those large weights are below the true sum. */
  h=reset();
  for (uw i=0;i<8;i++) {
    actors[i].weight=i<4 ? ((uw)-1 >> 2) : 1;
    backlog_add(h,&actors[i]);
  }
  assert(select_backlog(h)==&actors[3]);
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
  h=reset(); g_tau=1; g_adm=(uw)-3; backlog_add(h,&actors[0]);
  g_adm=0; backlog_add(h,&actors[1]); g_adm=3;
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
  g_adm=100; /* the stolen entry is already aged when the forwarded wake arrives */
  backlog_add(h,&actors[3]); drain(&fpr_harts[1]);
  assert(fpr_harts[1].bl_len==1 && actors[3].in_bl);
  backlog_add(&fpr_harts[1],&actors[3]); assert(fpr_harts[1].bl_len==1);
  assert(select_backlog(h)!=&actors[3]);
  other=&actors[4]; other->hart=1; backlog_add(&fpr_harts[1],other);
  fpr_harts[1].wake_hint=other;
  g_max_wait=0;
  refill(&fpr_harts[1]);
  assert(deq(&fpr_harts[1])==&actors[3] && g_max_wait==100);
  backlog_add(&fpr_harts[1],&actors[3]);
  assert(actors[3].ready_at==g_adm); /* next turn starts a fresh wait */
  trace_dispatch();
  check_offer();
  puts("scheduler locality: bounded hints, FIFO, aging, priority, stale wakes, pinning and late-wake migration PASS");
}
'''
with tempfile.TemporaryDirectory(prefix='fpr-scheduler-locality-') as directory:
    tmp=Path(directory)
    source=(ROOT/'runtime/actors.c').read_text()
    begin=source.index('static void reap(acb_t *a) {')
    end=source.index('\nextern void fpr_ctx_switch',begin)
    source=source[:begin]+'static void test_reap(acb_t *a);\nstatic void reap(acb_t *a) { test_reap(a); }\n'+source[end:]
    point=source.index('    uint32_t st = __atomic_load_n(&a->var', source.index('static acb_t *deq(fpr_hart_t *h) {'))
    source=source[:point]+'    before_dispatch_check(a);\n'+source[point:]
    point=source.index('static acb_t *deq(fpr_hart_t *h) {')
    source=source[:point]+'static void before_dispatch_check(acb_t *);\n'+source[point:]
    (tmp/'actors-locality.c').write_text(source)
    (tmp/'check.c').write_text(HARNESS)
    linker='-Wl,-dead_strip' if sys.platform=='darwin' else '-Wl,--gc-sections'
    # GCC's SLP vectoriser pools fpr_plane_export's function-pointer pairs in the
    # one anonymous .data.rel.ro.local section that also holds main's constants,
    # so GNU ld keeps the whole plane (fpr_actor_fail, a_spawn_heap, ...) and
    # then fails on their runtime symbols. ld64 strips per symbol and is fine.
    novec=[] if sys.platform=='darwin' else ['-fno-tree-slp-vectorize']
    exe=tmp/'check'
    (tmp/'clock.c').write_text('#include <stdint.h>\nuint64_t clock_reads;\nuint64_t hal_mtime(void) { return clock_reads++; }\n')
    traces=[]
    for mode in (0,1):
        subprocess.run([*shlex.split(os.environ.get('CC','cc')),f'-DFPR_DIRECT_LOCAL_HANDOFF={mode}',f'-DFPR_ADAPTIVE_BLOCK_SPIN={mode}','-O2','-pthread',*novec,'-DFPR_POSIX','-DFPR_NHARTS=2',
                        '-ffunction-sections','-fdata-sections','-I',str(ROOT/'runtime'),tmp/'check.c',tmp/'clock.c',linker,'-o',exe],
                       check=True,timeout=60)
        run=subprocess.run([exe],check=True,timeout=10,capture_output=True,text=True)
        traces.append([line for line in run.stdout.splitlines() if line.startswith('dispatch ')])
    assert len(traces[0]) == 390 and traces[0] == traces[1], "dispatch traces differ"
    print("scheduler locality: queued and direct traces match for 390 dispatches")
    native=tmp/'native'
    env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp/'cache')))
    for mode in (0,1):
        cc=tmp/f'cc-handoff-{mode}'
        cc.write_text('#!/bin/sh\nexec '+shlex.join(shlex.split(os.environ.get('CC','cc')))+
                      f' -DFPR_DIRECT_LOCAL_HANDOFF={mode} "$@"\n')
        cc.chmod(0o755)
        subprocess.run([ROOT/'fpr','build',ROOT/'tests/base/locality.fpr','--harts','4','--cc',cc,'-o',native],
                       cwd=ROOT,env=env,check=True,capture_output=True,text=True,timeout=180)
        for harts in ('1','4','4'):
            p=subprocess.run([native],env=dict(env,FPR_HARTS=harts,FPR_BLOCK_SPIN_NS='0'),
                             capture_output=True,text=True,timeout=30)
            assert p.returncode==0 and p.stdout=='locality 200030000\n',(mode,harts,p.stdout,p.stderr)
        print(f'scheduler locality: direct handoff={mode}, contended request/reply on one/four harts PASS')
        probe_cc=tmp/f'cc-handoff-probe-{mode}'
        probe_cc.write_text('#!/bin/sh\nexec '+shlex.quote(str(cc))+' -DFPR_SCHED_PROBE "$@"\n')
        probe_cc.chmod(0o755)
        subprocess.run([ROOT/'fpr','build',ROOT/'tests/base/handoffpressure.fpr','--harts','4',
                        '--with',ROOT/'tests/base/scheduler_probe.c','--cc',probe_cc,'-o',native],
                       cwd=ROOT,env=env,check=True,timeout=180)
        for harts in ('1','4'):
            p=subprocess.run([native],env=dict(env,FPR_HARTS=harts),capture_output=True,text=True,timeout=30)
            assert p.returncode==0 and p.stdout=='handoffpressure: 256 admissions, refusals and ordered replies\n',p
            records=[json.loads(line.removeprefix('[fpr sched] ')) for line in p.stderr.splitlines()
                     if line.startswith('[fpr sched] ')]
            assert len(records)==1 and records[0]['role']==1 and records[0]['fuel']>0,records
        print(f'scheduler locality: direct handoff={mode}, bounded replies with fuel preemption PASS')
