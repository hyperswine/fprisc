#!/usr/bin/env python3
"""Constructor metadata from loaded modules survives registry detach and growth."""
from pathlib import Path
import os, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
PROBE=r'''#include "fpr.h"
extern int fpr_mod_attach(const uw*);
extern void fpr_mod_detach(const uw*);
static void check(int b){if(!b)fpr_cpanic("layout registry oracle");}
static V seed(V v){(void)v;
 uw rows[]={1,0x7f001001,7,3};
 static const struct {uint32_t tid,var;uw len;unsigned char text[4];} name={T_STR,0,4,{'t','e','s','t'}};
 uw tab[]={0x4650524d,2,(uw)&name,(uw)rows,FPR_MANAGED_PREFIX,0};
 check(fpr_mod_attach(tab)==0);fpr_mod_detach(tab);
 rows[1]=0;rows[3]=99;
 check(fpr_layout_fields(0x7f001001,7)==3);
 uw bad[]={1,0x7f001001,7,4};check(fpr_layout_register(bad)==-1);
 check(fpr_layout_fields(0x7f001001,7)==3);
 uw unordered[]={2,0x7f001003,0,1,0x7f001002,0,2};check(fpr_layout_register(unordered)==-1);
 uw huge[]={(uw)-1};check(fpr_layout_register(huge)==-1);
 return (V)&fpr_unit;
}
static V grow(V kv){uw k=UNTAG(kv);
 for(uw i=0;i<100;i++){uw id=0x7f100000+k*100+i,rows[]={1,id,0,i};
  check(fpr_layout_register(rows)==0);check(fpr_layout_fields(id,0)==i);
  check(fpr_layout_fields(0x7f001001,7)==3);
 }
 return TAG(100);
}
static V inspect(V v){check(fpr_layout_fields(TID(v),((hdr_t*)v)->var)==3);
 for(uw i=0;i<3;i++)check(FPR_FLD(v,i)==TAG(41+i));return (V)&fpr_unit;}
FPR_FN(fpr_g_Probe_x2einspect,inspect,1);
FPR_FN(fpr_g_Probe_x2eseed,seed,1);
FPR_FN(fpr_g_Probe_x2egrow,grow,1);
'''
def run(args,env,timeout=300):
 p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout)
 assert p.returncode==0,(args,p.returncode,p.stdout[-2000:],p.stderr[-4000:])
 return p

def main():
 with tempfile.TemporaryDirectory(prefix='fpr-layout-modules-') as d:
  tmp=Path(d);env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'),FPR_LAYOUT_CHECK='1',FPR_LAYOUT_REPORT='1')
  mod=tmp/'module.fpr';mod.write_text('Payload = Type (Payload Int Int Int).\nmake x = Payload x (x + 1) (x + 2).\n')
  lib=tmp/('module.dylib' if os.uname().sysname=='Darwin' else 'module.so')
  run([ROOT/'fpr','build',mod,'--module','-o',lib],env)
  probe=tmp/'probe.c';probe.write_text(PROBE)
  host=tmp/'host.fpr';host.write_text('''unsafe base.
Probe.inspect : unsafe a -> Unit.
Probe.seed : unsafe Unit -> Unit.
Probe.grow : unsafe Int -> Int.
N = use "std/native".
R = use "std/reload".
echo self = (who,v) = receive self; send who v.
worker k self = (who,n) = receive self; send who (Probe.grow k).
main =
  _ = case N.attach "MODULE" of Ok u -> Unit | Err why -> error why;
  make = R.bindAt 0 "make";
  value = make 41;
  me = myself 0;
  child = spawn echo;
  _ = send child (me,value);
  back = receive me;
  _ = Probe.inspect back;
  _ = print (value == back);
  _ = Probe.seed Unit;
  a = spawn (worker 0); b = spawn (worker 1); c = spawn (worker 2); d = spawn (worker 3);
  _ = send a (me,0); _ = send b (me,0); _ = send c (me,0); _ = send d (me,0);
  p = receive me; q = receive me; r = receive me; s = receive me;
  _ = case p + q + r + s == 400 of True -> Unit | False -> error "layout growth replies";
  print "LAYOUT MODULES HOLD".
'''.replace('\"MODULE\"','\"'+str(lib)+'\"'))
  exe=tmp/'host';run([ROOT/'fpr','build',host,'--harts','4','--with',probe,'-o',exe],env)
  for harts in ('1','4','4'):
   p=run([exe],dict(env,FPR_HARTS=harts),60)
   assert 'LAYOUT MODULES HOLD' in p.stdout and 'True' in p.stdout,(p.stdout,p.stderr)
   assert '[layout] verified constructor' in p.stdout+p.stderr,p.stderr
  print('Dynamic constructor layouts: module message round trip, detached metadata lifetime, conflict/overflow refusal and concurrent index growth PASS',flush=True)
if __name__=='__main__':main()
