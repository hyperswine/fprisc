#!/usr/bin/env python3
"""An executable may be launched while make publishes a freshly built compiler."""
import subprocess,threading,tempfile,os,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
stop=threading.Event();failures=[];launches=[]
def launch():
 while not stop.is_set():
  try:
   p=subprocess.run([str(ROOT/'fpr'),'--version'],capture_output=True,text=True,timeout=10)
   if p.returncode or not p.stdout.startswith('fpr '):failures.append((p.returncode,p.stdout,p.stderr))
   launches.append(1)
  except Exception as e:failures.append(repr(e))
thread=threading.Thread(target=launch);thread.start()
try:
 for _ in range(3):
  p=subprocess.run(['make','-s','fpr-cabal'],cwd=ROOT,capture_output=True,text=True,timeout=300)
  assert p.returncode==0,p.stdout+p.stderr
finally:
 stop.set();thread.join()
assert launches and not failures,(len(launches),failures)
before=hashlib.sha256((ROOT/'fpr').read_bytes()).digest()
with tempfile.TemporaryDirectory(prefix='fpr-failed-build-') as d:
 fake=Path(d)/'cabal';fake.write_text('#!/bin/sh\nexit 17\n');fake.chmod(0o755)
 p=subprocess.run(['make','-s','fpr-cabal'],cwd=ROOT,env={**os.environ,'PATH':d+os.pathsep+os.environ['PATH']},capture_output=True,text=True)
 assert p.returncode!=0,'failed compiler build reported success'
assert hashlib.sha256((ROOT/'fpr').read_bytes()).digest()==before,'failed build replaced the prior compiler'
p=subprocess.run([str(ROOT/'fpr'),'--version'],capture_output=True,text=True)
assert p.returncode==0 and p.stdout.startswith('fpr '),(p.returncode,p.stdout,p.stderr)
print('Failed compiler build preserves the working executable: PASS')
print(f'Atomic compiler publication: {len(launches)} concurrent launches over three builds: PASS')
