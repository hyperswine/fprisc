#!/usr/bin/env python3
"""Independent RISC-V large-frame ABI oracle; real runtime acceptance is separate."""
import argparse,os,re,shutil,subprocess,tempfile
from pathlib import Path
from frame_emitter import build_emitter
from check_typed_ir_rv import ROOT,run
FIX=ROOT/'tests/typed_ir'

def crt(width):
 ld,st=('lw','sw') if width=='32' else ('ld','sd');w=int(width)//8
 base=(FIX/'kernel_crt.S').read_text().split('.globl fpr_fuel_exhausted')[0]
 def clobber(label,callee,keep):
  return f'.globl {label}\n{label}:\n addi sp,sp,-16\n {st} ra,0(sp)\n call {callee}\n {ld} ra,0(sp)\n addi sp,sp,16\n'+''.join(f' li {r},0\n' for r in [*[f'a{i}' for i in range(8)],*[f't{i}' for i in range(7)]] if r!=keep)+' ret\n'
 code=base+clobber('fpr_fuel_exhausted','oracle_tick',None)+clobber('fpr_stack_reserve','oracle_reserve','a0')
 regs=['s'+str(i) for i in range(12)]
 code+=' .globl oracle_invoke\noracle_invoke:\n addi sp,sp,-128\n'+f' {st} ra,0(sp)\n'
 code+=''.join(f' {st} {r},{(i+1)*w}(sp)\n li {r},{1000+i}\n' for i,r in enumerate(regs))
 code+=f' la t0,oracle_entry_sp\n {st} sp,0(t0)\n la t0,oracle_target\n {ld} t0,0(t0)\n jalr ra,t0,0\n'
 code+=''.join(f' li t0,{1000+i}\n bne {r},t0,oracle_bad_saved\n' for i,r in enumerate(regs))
 code+=''.join(f' {ld} {r},{(i+1)*w}(sp)\n' for i,r in enumerate(regs))
 code+=f' {ld} ra,0(sp)\n addi sp,sp,128\n ret\noracle_bad_saved:\n li a0,200\n tail oracle_finish\n'
 return code

def actor_source(source,depth=80):
 n=512
 values=[f'v{i}' for i in range(n)]
 source.write_text('unsafe base.\nReserve.tick : Unit -> Unit.\nidn x = x+1.\n'
  'sumL : unsafe List Int -> Int.\nsumL xs = case xs of Nil -> 0 | x::rest -> x+sumL rest.\n'
  'large : unsafe Int -> List Int.\nlarge n = '+''.join(f'v{i}=idn n; ' for i in range(n))+
  '_=Reserve.tick Unit; if n==0 then ['+', '.join(values)+'] else xs=large (n - 1); total=sumL xs; ['+
  ', '.join(['v0+total']+values[1:])+'].\nmain = answer=sumL (large '+str(depth)+'); '
  'if answer=='+str(n*(depth+1)*(depth+2)//2)+' then print "RV ACTOR FRAMES HOLD" else error "large frame result".\n')
 return source

def actor_runtime(out,env,width,*,compiler=None,strict=True,counter=None,execute=True,small_stack=True):
 compiler=compiler or ROOT/'fpr'
 out.mkdir(parents=True,exist_ok=True)
 source=actor_source(out/('actor-'+width+'.fpr'))
 mode=dict(env,FPR_TYPED_IR_BACKEND='mixed',FPR_TYPED_IR_STRICT='all' if strict else '',FPR_NO_F64_INLINE='1',FPR_NO_INLINE='1',FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1',FPR_NO_REUSE='1',XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(out/('cache-'+width))))
 asm=out/('actor-'+width+'.s');run([compiler,'compile','--system=bare-metal','--target=rv'+width,source,asm],mode)
 whole=asm.read_text()
 if strict:
  assert '# typed IR: no translation' in whole
  assert re.search(r'^# fn large .*reserve=yes',whole,re.M)
 else:
  assert re.search(r'^# fn large .*\n',whole,re.M) and '# wcet: large ' in whole
 units=[Path(x) for x in Path(str(asm)+'.units').read_text().splitlines()]
 if strict:assert all('# typed IR: no translation' in p.read_text() for p in units)
 raw=[]
 if width=='64':
  clint=out/'clint.s'
  run([compiler,'compile','--profile=bare-metal-builtin','--arc','--raw','--lib',
       '--export=ipiSend:hal_ipi_send,ipiClear:hal_ipi_clear,mtime:hal_mtime,timerPark:hal_timer_park,timerArm:hal_timer_arm',
       ROOT/'machine/virt/clint.fpr',clint],mode)
  raw=[clint,ROOT/'machine/virt/rawunit.c']
 image=out/('actor-'+width+'.elf')
 # The installed toolchain has integer-ABI IMAC multilibs, but no IMAD/soft
 # combination. Its IMAC libgcc has the same ILP32/LP64 calling convention.
 libgcc=run(['riscv64-unknown-elf-gcc','-march=rv'+width+'imac','-mabi='+('ilp32' if width=='32' else 'lp64'),'-print-libgcc-file-name'],mode).strip()
 assert Path(libgcc).is_file(),libgcc
 command=['riscv64-unknown-elf-gcc','-march=rv'+width+'imafdc_zicsr_zifencei','-mabi='+('ilp32' if width=='32' else 'lp64'),
  '-mcmodel=medany','-msmall-data-limit=0','-O2','-ffreestanding','-nostdlib','-nostartfiles','-fno-builtin','-fno-stack-protector',
  '-DFPR_NHARTS=1',*(['-DFPR_STACK_SZ=32752','-DFPR_BUDDY_MIN=4096'] if small_stack else []),'-Iruntime','-Imachine/virt','-T','machine/virt/link.ld',
  *[ROOT/'machine/virt'/p for p in ('crt0.S','ctx.S','ctx_fab.c','hal.c','memshim.c')],*raw,asm,*units,
  *[ROOT/'runtime'/p for p in ('runtime.c','i32.c','actors.c','bits.c','vec.c','sstr.c','mod.c','buddy.c')],
  ROOT/'tests/typed_ir/runtime_reserve.c',*(['-Wl,--wrap=fpr_fn_main',counter] if counter else []),libgcc,'-o',image]
 run(command,mode)
 if execute:
  result=run(['qemu-system-riscv'+width,'-machine','virt','-smp','1','-m','128M','-nographic','-bios','none','-kernel',image],mode)
  assert 'RV ACTOR FRAMES HOLD' in result,result
  print(f'RV{width} production actor runtime: 512 held values, 80 nested frames, 32KiB first stack, forced yields PASS',flush=True)
 return image,mode


def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--require-execution',action='store_true');ap.add_argument('--keep-dir',type=Path);a=ap.parse_args()
 missing=[x for x in ('riscv64-unknown-elf-gcc','qemu-system-riscv32','qemu-system-riscv64') if not shutil.which(x)]
 if missing:
  assert not a.require_execution,missing
  print('RV large frames SKIP: '+', '.join(missing));return
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')};env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT))
 run(['make','fpr'],env)
 with tempfile.TemporaryDirectory(prefix='fpr-rv-frames-') as temp:
  out=a.keep_dir or Path(temp);out.mkdir(parents=True,exist_ok=True)
  exe=build_emitter(env)
  for width in ('32','64'):
   for loops in ('0','1'):
    asm=out/f'frames-{width}-{loops}.s'
    report=run([exe,'rv',width,loops,asm],env)
    headers=re.findall(r'^# fn .*$',asm.read_text(),re.M);assert len(headers)==3 and all('reserve=yes' in h for h in headers),headers
    assert not re.search(r'native-insns-v1:.*UNBOUNDED',asm.read_text())
    crtfile=out/'crt.S';crtfile.write_text(crt(width));image=out/f'frames-{width}-{loops}.elf'
    run(['riscv64-unknown-elf-gcc','-march=rv'+width+'im_zicsr_zifencei','-mabi='+('ilp32' if width=='32' else 'lp64'),'-mcmodel=medany',
         '-msmall-data-limit=0','-O2','-fno-omit-frame-pointer','-ffreestanding','-nostdlib','-fno-builtin',*(['-DSELF_LOOPS'] if loops=='1' else []),
         '-T',FIX/'kernel_link.ld',crtfile,asm,FIX/'rv_frames_oracle.c','-o',image],env)
    result=run(['qemu-system-riscv'+width,'-machine','virt','-m','16M','-nographic','-bios','none','-kernel',image],env)
    assert 'RV_SIZED_FRAMES_PASS' in result,result
    print(f'RV{width} loops={loops}: '+report.strip()+'\n'+result.strip(),flush=True)
   actor_runtime(out,env,width)

if __name__=='__main__':main()
