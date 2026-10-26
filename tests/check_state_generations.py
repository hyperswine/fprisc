#!/usr/bin/env python3
"""Single-slab persistent-state generations, compaction and conservative paths."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
SOURCE='''unsafe base.
Cost.begin : Unit -> Unit.
Cost.report : Unit -> String.
storage : a -> Int.
stash : a -> Unit.
checkStash : Unit -> Unit.
releaseShare : a -> Unit.
large : Int -> String.
generations : Unit -> Bool.
list n = if n == 0 then [] else n :: list (n - 1).
sum xs acc = case xs of [] -> acc | x :: rest -> sum rest (acc + x).
arcReader boss self =
  xs = receive self;
  _ = if sum xs 0 == 50005000 then Unit else error "ARC reader lost state";
  _ = drop xs; _ = send boss 1;
  # This receive closes the reader's post-drop borrow window before its ack.
  tick = receive self; _ = send boss tick; Unit.
step reader limit st =
  (n,xs,ys,text,last,changes) = st;
  _ = if text == "row {n}" then Unit else error "generation lost text";
  token = storage xs;
  changed = if n > 1 and token != last then 1 else 0;
  _ = if n == 3 then
        me = myself 0; _ = sendArc reader xs; _ = releaseShare xs;
        _ = receiveFrom me reader; _ = send reader 2; _ = receiveFrom me reader;
        if sum xs 0 == 50005000 then Unit else error "scope lost last ARC holder"
      else Unit;
  _ = if n == 5 then stash xs else Unit;
  (n + 1 < limit,(n + 1,xs,ys,"row {n + 1}",token,changes + changed)).
capacity limit st =
  (n,xs,text,last,changes) = st;
  _ = if n > 0 and strlen text != 40000 then error "capacity lost text" else Unit;
  token = storage xs;
  changed = if n > 1 and token != last then 1 else 0;
  (n + 1 < limit,(n + 1,xs,large n,token,changes + changed)).
prefix limit st = (n,xs) = st; (n + 1 < limit,(n + 1,n :: xs)).
parked boss me =
  _ = Sys.loop (0,list 1000) (fn st ->
    (n,xs) = st;
    _ = if n == 10 then _ = send boss me; Sys.sleepUs 10000000 else Unit;
    (True,(n + 1,xs)));
  Unit.
killRounds me n = if n == 0 then Unit else
  child = spawn (parked me); ready = receiveFrom me child;
  _ = kill ready; killRounds me (n - 1).
freeKiB u = case Sys.memInfo 0 of _ :: free :: _ -> free | _ -> 0.
main = case Sys.args Unit of
    ["cancel"] ->
      me = myself 0; _ = killRounds me 40; _ = Sys.sleepUs 100000;
      before = freeKiB Unit;
      _ = killRounds me 200; _ = Sys.sleepUs 100000;
      lost = before - freeKiB Unit;
      _ = if lost < 8192 then Unit else error "cancelled state leaked {lost} KiB";
      print "cancel PASS"
  | ["capacity"] ->
      (n,xs,text,last,changes) = Sys.loop (0,list 100,"",0,0) (capacity 200);
      _ = if n == 200 and sum xs 0 == 5050 and strlen text == 40000 and changes > 40
          and (if generations Unit then changes < 150 else changes > 150)
          then Unit else error "capacity must compact: {n} {sum xs 0} {strlen text} {changes}";
      print "capacity PASS"
  | ["prefix"] ->
      (n,xs) = Sys.loop (0,[]) (prefix 1000);
      _ = if n == 1000 and sum xs 0 == 499500 then Unit else error "persistent prefix lost";
      print "prefix PASS"
  | _ ->
      xs = list 10000;
      roots = arcLive 0;
      reader = spawn (arcReader (myself 0));
      _ = Cost.begin Unit;
      (n,ys,zs,text,last,changes) = Sys.loop (0,xs,xs,"row 0",0,0) (step reader 1000);
      report = Cost.report Unit;
      _ = checkStash Unit;
      _ = if n == 1000 and sum ys 0 == 50005000 and sum zs 0 == 50005000 and text == "row 1000"
          and arcLive 0 == roots then Unit else error "retained graph or ARC root lost";
      _ = if generations Unit then
            if changes > 100 and changes < 200 then Unit else error "generation bound"
          else if changes > 900 then Unit else error "full-copy control";
      _ = print "state-generations PASS {changes}"; print report.
'''
PROBE=r'''#include "fpr.h"
#include <assert.h>
#ifndef FPR_STATE_GENERATIONS
#define FPR_STATE_GENERATIONS 8
#endif
static V saved;
static V storage(V v) { assert(!ISINT(v) && fpr_in_heap(v)); return TAG((sw)(uw)*(fpr_slab_t **)((char*)v-8)); }
static V release_share(V v) { fpr_arc_decref(v); return (V)&fpr_unit; }
static V stash(V v) { assert(!saved); saved=v; fpr_arc_promote_share(v); return (V)&fpr_unit; }
static V check_stash(V u) {
  (void)u; uw count=0,sum=0; V cur=saved;
  while (!ISINT(cur) && TID(cur)==T_LIST && ((hdr_t*)cur)->var==1) {
    assert(++count<=10000); sum+=(uw)UNTAG(FPR_FLD(cur,0)); cur=FPR_FLD(cur,1);
  }
  assert(count==10000 && sum==50005000); fpr_arc_decref(saved); fpr_arc_decref(saved); saved=0;
  return (V)&fpr_unit;
}
static V large(V n) { (void)n; static char bytes[40000]; return (V)fpr_mkstr(bytes,sizeof bytes); }
static V generations(V u) { (void)u; return BOOL(FPR_STATE_GENERATIONS>1); }
FPR_FN(fpr_g_storage,storage,1);
FPR_FN(fpr_g_stash,stash,1);
FPR_FN(fpr_g_checkStash,check_stash,1);
FPR_FN(fpr_g_releaseShare,release_share,1);
FPR_FN(fpr_g_large,large,1);
FPR_FN(fpr_g_generations,generations,1);
'''

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-state-generations-') as directory:
        tmp=Path(directory); source=tmp/'state.fpr'; source.write_text(SOURCE)
        probe=tmp/'probe.c'; probe.write_text(PROBE)
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'),
                 FPR_COST_PROBE='1',FPR_NO_LOOP_REGIONS='1',FPR_NO_CALL_REGIONS='1')
        env.pop('FPR_FOREIGN',None)
        results={}
        for disabled in (False,True):
            wrapper=tmp/('cc-full' if disabled else 'cc-generations')
            wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execvp("cc",["cc",'+
                               ('"-DFPR_STATE_GENERATIONS=1",' if disabled else '')+'*sys.argv[1:]])\n')
            wrapper.chmod(0o755)
            for no_reuse in ('0','1'):
                exe=tmp/'run'
                built=subprocess.run([ROOT/'fpr','build',source,'--harts','4','--cc',wrapper,'--with',probe,
                                '--with',ROOT/'tests/bench/costprobe.c','-o',exe],cwd=ROOT,
                               env=dict(env,FPR_NO_REUSE=no_reuse),capture_output=True,text=True,timeout=180)
                assert built.returncode==0,built.stdout+built.stderr
                for harts in ('1','4'):
                    for case in ('','capacity','prefix','cancel'):
                        p=subprocess.run([exe,*([case] if case else [])],env=dict(env,FPR_HARTS=harts),
                                         capture_output=True,text=True,timeout=60)
                        assert p.returncode==0,(disabled,no_reuse,harts,case,p.stdout,p.stderr)
                        if case:
                            assert p.stdout==case+' PASS\n',p.stdout
                        else:
                            assert p.stdout.startswith('state-generations PASS '),p.stdout
                            stats=json.loads(p.stdout.splitlines()[1]);assert stats['state_copies']==1000,stats
                            results[disabled,no_reuse,harts]=stats['state_bytes']
                print(f'state generations: full-copy={disabled} no-reuse={no_reuse}: retained aliases, final result, ARC export, capacity compaction, list-prefix persistence; 1/4 harts PASS',flush=True)
        for no_reuse in ('0','1'):
            for harts in ('1','4'):
                before,after=results[True,no_reuse,harts],results[False,no_reuse,harts]
                assert after*4<before,(no_reuse,harts,before,after)
                print(f'state copy bytes: reuse-off={no_reuse} harts={harts}: {before} -> {after}',flush=True)

if __name__=='__main__': main()
