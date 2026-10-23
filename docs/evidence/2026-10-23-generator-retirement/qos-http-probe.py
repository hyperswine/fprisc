import os,socket,subprocess,time,sys
from pathlib import Path
ROOT=Path('/Users/jasonqin/Documents/GitHub/qos')
variant=sys.argv[1]
qa=ROOT/('build/typed-retirement-pos-before/pos.qa' if variant=='before' else 'build/typed-retirement-pos/pos.qa')
port=8153 if variant=='before' else 8154
log=Path('/private/tmp/fprlive-probe-'+variant+'.log')
disk=Path('/private/tmp/fprlive-probe-'+variant+'.disk')
disk.unlink(missing_ok=True)
env=dict(os.environ,FPR_PORT=str(port),FPR_DISK=str(disk),FPR_DISK_MB='64',FPR_HARTS='4')
with log.open('w') as f:
 p=subprocess.Popen([str(ROOT/'qos/qosp'),'--yes',str(qa)],cwd=ROOT/'qos',env=env,stdout=f,stderr=subprocess.STDOUT)
 try:
  start=time.monotonic()
  for i in range(30):
   time.sleep(1)
   if p.poll() is not None:print('process exit',p.returncode,log.read_text());sys.exit(1)
   try:
    with socket.create_connection(('127.0.0.1',port),1) as s:
     s.settimeout(1);s.sendall(b'GET / HTTP/1.1\r\nHost: x\r\n\r\n');data=b''
     while True:
      chunk=s.recv(65536)
      if not chunk:break
      data+=chunk
    print(variant,'elapsed',round(time.monotonic()-start,2),'response',repr(data[:100]),flush=True)
    if data.startswith(b'HTTP/1.1 200'):
     Path('/private/tmp/fprlive-page-'+variant+'.http').write_bytes(data);sys.exit(0)
   except (OSError,TimeoutError) as e:print(variant,'elapsed',round(time.monotonic()-start,2),type(e).__name__,flush=True)
  print(log.read_text());sys.exit(1)
 finally:
  p.terminate()
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
