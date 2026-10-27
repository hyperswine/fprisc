#!/usr/bin/env python3
"""Float expression/comparison trees against independent IEEE C expressions."""
import os,platform,re,tempfile,shutil
from pathlib import Path
from x64_probe import ROOT,adapt,host,link,run

def main():
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
 env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1',FPR_TYPED_IR_STRICT='all')
 with tempfile.TemporaryDirectory(prefix='fpr-float-trees-') as d:
  tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
  for target in ('qa64mac','x64','rv64'):
   asm=tmp/(target+'.s')
   run([ROOT/'fprc','--target='+target,ROOT/'tests/typed_ir/float_trees.fpr',asm],env)
   text=asm.read_text();headers=re.findall(r'^# fn (.*)',text,re.M)
   assert all('typed-ir' in h for h in headers) and '# wcet:' not in text
   bodies=re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# native-insns-v1:)',text)
   body='\n'.join(b for n,b in bodies if not n.startswith('main '))
   if target == 'qa64mac':
    cmpbody = next(b for n,b in bodies if n.startswith('cmp64lt '))
    f32body = next(b for n,b in bodies if n.startswith('chain32 '))
    assert len(re.findall(r'^\s*fmov ',cmpbody,re.M)) == 7, cmpbody
    assert len(re.findall(r'^\s*fmov ',f32body,re.M)) == 6, f32body
   assert not re.search(r'(?:fmadd|fmsub|vfmadd)',body),'no implicit FMA'
   oracle=ROOT/'tests/typed_ir/float_tree_oracle.c';exe=tmp/(target+'-probe')
   if target=='qa64mac':
    if platform.machine() not in ('arm64','aarch64'):print('A64 execution SKIP');continue
    # the ticks' register-saving wrapper is emitted once per unit, after the functions
    wrapper=re.search(r'(?ms)^fpr_fuel_save_local:\n.*?^\s*ret\n',text)
    asm.write_text('.text\n'+body+('\n'+wrapper.group(0) if wrapper else ''))
    run(['clang','-O2','-ffp-contract=off','-ffixed-x28',asm,oracle,'-o',exe],env)
    result=run([exe],env)
   elif target=='x64':
    available=host()
    if available is None:print('x64 execution SKIP');continue
    wrapper=re.search(r'(?ms)^fpr_fuel_save_local:\n.*?^\s*ret\n',text)
    mac,runner,label=available;asm.write_text('.text\n'+adapt(body+('\n'+wrapper.group(0) if wrapper else ''),mac))
    link(['-ffp-contract=off',asm,oracle],exe,mac,env);result=run([*runner,exe],env)
   else:
    if not all(shutil.which(t) for t in ('riscv64-unknown-elf-gcc','qemu-system-riscv64')):print('RV64 execution SKIP');continue
    # the ticks' register-saving wrapper is emitted once per unit, after the functions
    wrapper=re.search(r'(?ms)^fpr_fuel_save_local:\n.*?^\s*ret\n',text)
    asm.write_text('.text\n'+body+('\n'+wrapper.group(0) if wrapper else ''))
    run(['riscv64-unknown-elf-gcc','-O2','-ffp-contract=off','-march=rv64imafd_zicsr_zifencei','-mabi=lp64','-mcmodel=medany','-msmall-data-limit=0','-ffreestanding','-nostdlib','-fno-builtin','-T',ROOT/'tests/typed_ir/kernel_link.ld',ROOT/'tests/typed_ir/kernel_crt.S',asm,oracle,'-o',exe],env)
    result=run(['qemu-system-riscv64','-machine','virt','-m','16M','-nographic','-bios','none','-kernel',exe],env)
    assert 'FLOAT_TREE_PASS' in result,result
   print(target+': '+result.strip(),flush=True)
if __name__=='__main__':main()
