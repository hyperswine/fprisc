import argparse,json,os,subprocess,tempfile,statistics,platform
from pathlib import Path
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description='Strict fused A64 map benchmark; scalar references retained.')
parser.add_argument('--output',type=Path)
args=parser.parse_args()
if platform.machine() not in ('arm64','aarch64'): raise SystemExit('requires a native AArch64 host')
temporary=tempfile.TemporaryDirectory(prefix='fpr-neon-bench-')
w=Path(temporary.name)
s=(root/'tests/base/vecsimd.fpr').read_text().replace('profile base.','profile base.\nClock = use "std/clock".')
s=s.replace('  v = fill n (Vec.new Unit) |> Vec.map first |> Vec.map second;', '  original = fill n (Vec.new Unit);\n  t0 = Clock.monotonic Unit;\n  v = original |> Vec.map first |> Vec.map second;\n  t1 = Clock.monotonic Unit;')
s=s.replace('print "simd: {n} {total}"','print "{total} {t1 - t0}"').replace('main = probes 99.','main = probe 500000.')
source=w/'benchmark.fpr';source.write_text(s)
env={**os.environ,'XDG_CACHE_HOME':str(w/'cache'),'FPR_HARTS':'1'}
variants={'neon':{},'scalar':{'FPR_NO_VEC_SIMD':'1'},'two_pass_scalar':{'FPR_NO_VEC_SIMD':'1','FPR_NO_VEC_FUSE':'1'}}
for name,flags in variants.items():
 p=subprocess.run([str(root/'fpr'),'build',str(source),'-o',str(w/name)],cwd=root,env={**env,**flags},capture_output=True,text=True)
 assert p.returncode==0,p.stdout+p.stderr
samples={name:[] for name in variants}
for i in range(10):
 for name in variants:
  p=subprocess.run([str(w/name)],env=env,capture_output=True,text=True)
  assert p.returncode==0,p.stdout+p.stderr
  checksum,us=p.stdout.split();assert checksum=='187500875000',p.stdout
  if i: samples[name].append(int(us))
report={'host':platform.platform(),'elements':500000,'timed':'maps only, construction and ordered fold excluded','warmups':1,'samples':9,'median_us':{n:statistics.median(v) for n,v in samples.items()},'samples_us':samples,'checksum':'187500875000'}
if args.output: args.output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
temporary.cleanup()
