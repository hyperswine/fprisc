"""Compare selected native function bodies with the compiler before deletion.
Only cache-revision spelling is normalized; instructions, labels, frame facts
and native instruction reports must remain identical.
"""
import hashlib,json,os,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-retirement-parity';OUT.mkdir(exist_ok=True)
BEFORE=Path('/private/tmp/fpr-native-data-g88')
env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(OUT/'cache'))
rows=[]
def bodies(root):
 paths=[root,*map(Path,Path(str(root)+'.units').read_text().splitlines())]
 result={}
 for p in paths:
  text=p.read_text()
  text=re.sub(r'g(?:88|89)(?=(?:-|_x2d)tirbe)','gREV',text)
  text=re.sub(r'rv64posixr(?:3|22)(?=[^0-9]|$)','rv64posixrREV',text)
  for body,name in re.findall(r'(?ms)^(# fn ([^\n]+)\n.*?^# native-insns-v1: [^\n]+)',text):
   assert name not in result,(p,name)
   result[name]=body
 return result
for target in ('rv32','rv64','a64mac','x64'):
 for fixture in ('scalar','record_kernels','record_float_kernels','f32_kernels','mapas_kernels'):
  all_bodies=[]
  for variant,compiler in (('before',BEFORE),('after',ROOT/'fpr')):
   folder=OUT/target/fixture/variant;folder.mkdir(parents=True,exist_ok=True)
   asm=folder/'root.s'
   p=subprocess.run([str(compiler),'compile','--target='+target,str(ROOT/'tests/typed_ir'/(fixture+'.fpr')),str(asm)],cwd=ROOT,env=env,text=True,capture_output=True,timeout=600)
   assert p.returncode==0,(target,fixture,variant,p.stdout,p.stderr)
   all_bodies.append(bodies(asm))
  before,after=all_bodies
  assert list(before)==list(after),(target,fixture,'function set changed',before.keys()-after.keys(),after.keys()-before.keys())
  changed=[name for name in before if before[name]!=after[name]]
  assert not changed,(target,fixture,changed[:3])
  rows.append({'target':target,'fixture':fixture,'functions':len(before),'result':'byte-identical selected function text'})
  print(f'{target} {fixture}: {len(before)} identical native functions and reports PASS',flush=True)
report={'compiler_sha256':{str(c):hashlib.sha256(c.read_bytes()).hexdigest() for c in (BEFORE,ROOT/'fpr')},'cases':rows}
(ROOT/'docs/evidence/2026-10-23-generator-retirement/emission-parity.json').write_text(json.dumps(report,indent=2)+'\n')
