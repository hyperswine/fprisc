import hashlib,json,os,statistics,subprocess,sys,time
from pathlib import Path
root=Path(sys.argv[1]).resolve()
repo=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else Path.cwd()
env=dict(os.environ,FPR_HARTS='1')
names=['fib','sum','pipeline','byteloop','helpers','sha']
expected={'fib':9227465,'sum':50000005000000,'pipeline':750000500007}
samples={n+'-'+m:[] for n in names for m in ['off','on']}
for i in range(31):
 for n in (names if i%2==0 else names[::-1]):
  for m in (['off','on'] if i%2==0 else ['on','off']):
   key=n+'-'+m;t=time.perf_counter_ns()
   p=subprocess.run([root/key],capture_output=True,text=True,env=env,check=True,timeout=60)
   elapsed=time.perf_counter_ns()-t
   if n in expected:
    value,elapsed=map(int,p.stdout.split());assert value==expected[n]
   else: assert p.stdout==(repo/'tests/bench'/f'{n}.expected').read_text()
   samples[key].append(elapsed)
 print(i+1,flush=True)
d={'protocol':'31 alternating paired repetitions of frozen binaries; same timer scopes as original run', 'samples_ns':samples,
   'medians_ns':{k:statistics.median(v) for k,v in samples.items()},
   'binary_sha256':{k:hashlib.sha256((root/k).read_bytes()).hexdigest() for k in samples}}
(root/'repeat.json').write_text(json.dumps(d,indent=2)+'\n')
for n in names:
 a,b=[d['medians_ns'][n+'-'+m]/1e6 for m in ['off','on']]
 print(n,round(a,3),round(b,3),'less time %',round((1-b/a)*100,2))
