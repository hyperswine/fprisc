#!/usr/bin/env python3
"""Observe received-root counts on the scheduler stack at an actual park.

The CC wrapper instruments a temporary actors.c copy, before the context's
running marker is cleared. No production hook or timing-based sleep is needed.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
PROBE=r'''#include "fpr.h"
static uw watched, armed, observed=(uw)-1, effects;
void fpr_test_parked(void *actor, uw roots) {
  if ((uw)actor==__atomic_load_n(&watched,__ATOMIC_ACQUIRE) && __atomic_load_n(&armed,__ATOMIC_ACQUIRE)) {
    __atomic_store_n(&observed,roots,__ATOMIC_RELEASE);
    __atomic_store_n(&armed,0,__ATOMIC_RELEASE);
  }
}
static V watch(V actor) { __atomic_store_n(&watched,(uw)actor,__ATOMIC_RELEASE); return (V)&fpr_unit; }
static V arm(V actor) { if((uw)actor==__atomic_load_n(&watched,__ATOMIC_ACQUIRE)) {
  __atomic_store_n(&observed,(uw)-1,__ATOMIC_RELEASE); __atomic_store_n(&armed,1,__ATOMIC_RELEASE);
} return (V)&fpr_unit; }
static V reset(V ignored) { (void)ignored; __atomic_store_n(&observed,(uw)-1,__ATOMIC_RELEASE); return (V)&fpr_unit; }
static V sample(V ignored) { (void)ignored; return TAG((sw)__atomic_load_n(&observed,__ATOMIC_ACQUIRE)); }
static V effect(V ignored) { (void)ignored; effects++; return (V)&fpr_unit; }
static V count(V ignored) { (void)ignored; return TAG((sw)effects); }
FPR_FN(fpr_g_Park_x2ewatch,watch,1);
FPR_FN(fpr_g_Park_x2earm,arm,1);
FPR_FN(fpr_g_Park_x2esample,sample,1);
FPR_FN(fpr_g_Park_x2ereset,reset,1);
FPR_FN(fpr_g_Park_x2eeffect,effect,1);
FPR_FN(fpr_g_Park_x2ecount,count,1);
'''
HEADER='''unsafe base.
Park.watch : Int -> Unit.
Park.arm : Int -> Unit.
Park.sample : Unit -> Int.
Park.reset : Unit -> Unit.
Park.effect : Unit -> Unit.
Park.count : Unit -> Int.
Msg = Type (Data String | Inspect | Stop | Noise String).
peer boss = _ = Park.effect Unit; boss.
await n = count = Park.sample Unit;
  if count >= 0 then count else if n == 0 then error "no park observed"
  else _ = yield (myself 0); await (n - 1).
noise target boss self = _ = send target (Noise "queued unrelated message"); _ = send boss 0; Unit.
'''
def source():
    definitions=[]
    for mode,receive in [('any','receive self'),('from','receiveFrom self boss'),
                          ('dead','case receiveFromRes self boss of Ok m -> m | Err e -> error e'),
                          ('result','case receiveRes self of Ok m -> m | Err e -> error e'),
                          ('effect','receiveFrom self (peer boss)')]:
        definitions.append(f'''{mode} boss last self =
  message = {receive};
  case message of
    Data text -> _ = send boss 1; _ = Park.arm self; {mode} boss text self
  | Inspect -> _ = if last == "payload-{{Sys.harts Unit}}" then Unit else error "copied state lost";
      _ = send boss 2; _ = Park.arm self; {mode} boss last self
  | Stop -> Unit
  | Noise text -> error "selective probe consumed unrelated message".
''')
    definitions.append('''mid boss self =
  message = receiveFrom self boss;
  _ = send boss 1; _ = Park.arm self;
  _ = receiveFrom self boss;
  _ = case message of Data text -> if text == "payload-{Sys.harts Unit}" then Unit else error "mid-turn root lost"
      | _ -> error "mid-turn protocol";
  _ = send boss 3; mid boss self.
''')
    cases=[]
    for mode in ('any','from','dead','result','effect','mid'):
        noise='' if mode in ('any','effect','mid') else 'n = spawn (noise worker me); _ = receiveFrom me n;'
        def send(value): return f'send worker ({"Ok ("+value+")" if mode=="result" else value})'
        if mode=='mid':
            cases.append(f'''["{mode}"] -> me = myself 0; worker = spawn (mid me); _ = Park.watch worker;
              _ = {send('Data (strcat "payload-" (str (Sys.harts Unit)))')};
              _ = receiveFrom me worker; count = await 100000;
              _ = if count > 0 then Unit else error "mid-turn message released early";
              _ = send worker 0; reply = receiveFrom me worker;
              _ = if reply == 3 then Unit else error "mid-turn continuation";
              _ = kill worker; print "mid PASS"''')
        else:
            check='if Park.count Unit == 2 then Unit else error "sender evaluated by probe"' if mode=='effect' else 'Unit'
            check2='if Park.count Unit == 3 then Unit else error "sender replayed by probe"' if mode=='effect' else 'Unit'
            cases.append(f'''["{mode}"] -> me = myself 0; worker = spawn ({mode} me "initial"); _ = Park.watch worker;
              {noise}
              _ = {send('Data (strcat "payload-" (str (Sys.harts Unit)))')};
              _ = receiveFrom me worker; first = await 100000;
              _ = if first == 0 then Unit else error "parked roots {{first}}";
              _ = {check};
              _ = Park.reset Unit; _ = {send('Inspect')}; _ = receiveFrom me worker; second = await 100000;
              _ = if second == 0 then Unit else error "retained-state park roots {{second}}";
              _ = {check2}; _ = Park.reset Unit;
              _ = {send('Data (strcat "payload-" (str (Sys.harts Unit)))')};
              _ = receiveFrom me worker; third = await 100000;
              _ = if third == 0 then Unit else error "same-slab park roots {{third}}";
              _ = {send('Stop')}; print "{mode} PASS"''')
    return HEADER+'\n'.join(definitions)+'main = case Sys.args Unit of\n  '+'\n  | '.join(cases)+'\n  | _ -> error "choose receive mode".\n'

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--compiler',type=Path,default=ROOT/'fpr');ap.add_argument('--runs',type=int,default=3)
    args=ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='fpr-parked-') as directory:
        tmp=Path(directory); program=tmp/'parked.fpr';program.write_text(source());probe=tmp/'probe.c';probe.write_text(PROBE)
        actors=(ROOT/'runtime/actors.c').read_text()
        marker='      __atomic_store_n(&n->running, 0, __ATOMIC_RELEASE);'
        assert actors.count(marker)==1
        actors=actors.replace('#include "fpr.h"','#include "fpr.h"\nextern void fpr_test_parked(void *, uw);',1)
        actors=actors.replace(marker,'      if (__atomic_load_n(&n->var, __ATOMIC_ACQUIRE)==ST_BLOCKED) fpr_test_parked(n,fpr_acb_rx(n)->n);\n'+marker)
        (tmp/'actors.c').write_text(actors)
        cc=tmp/'cc';cc.write_text('#!/usr/bin/env python3\nimport os,sys\na=['+repr(str(tmp/'actors.c'))+' if x.endswith("/runtime/actors.c") else x for x in sys.argv[1:]]\nos.execvp("cc",["cc",*a])\n');cc.chmod(0o755)
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp/'cache')))
        env.pop('FPR_FOREIGN',None)
        for disabled in ('0','1'):
            executable=tmp/'parked'
            p=subprocess.run([args.compiler,'build',program,'--harts','4','--cc',cc,'--with',probe,'-o',executable],
                cwd=ROOT,env=dict(env,FPR_NO_INLINE=disabled),capture_output=True,text=True,timeout=180)
            assert p.returncode==0,p.stdout+p.stderr
            for harts in ('1','4'):
                for mode in ('any','from','dead','result','effect','mid'):
                    for run in range(args.runs):
                        p=subprocess.run([executable,mode],env=dict(env,FPR_HARTS=harts),capture_output=True,text=True,timeout=30)
                        assert p.returncode==0 and p.stdout==mode+' PASS\n',(disabled,harts,mode,run,p.stdout,p.stderr)
                print(f'park boundary: no-inline={disabled} harts={harts}: any/sender/death/Result readiness, unrelated queued messages, exact sender effects, copied state and live mid-turn roots PASS',flush=True)
        # Ordinary call selection carries the same boundary contract on each
        # managed ISA; QOS process images keep their existing trampoline.
        for target in ('a64','x64','rv64','rv32','qa64','qx64','qrv64'):
            assembly=tmp/(target+'.s')
            p=subprocess.run([args.compiler,'compile',f'--target={target}',program,assembly],cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
            assert p.returncode==0,p.stdout+p.stderr
            emitted=assembly.read_text()
            assert ('fpr_g__x24receiveReady' in emitted)==(target in ('a64','x64','rv64','rv32')),target
            print(f'park boundary emission: {target} PASS',flush=True)
if __name__=='__main__': main()
