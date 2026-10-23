#!/usr/bin/env python3
"""RV32 typed float constants: independent bit/layout/pooling and real runtime."""
import argparse,hashlib,os,random,re,shutil,subprocess,sys,tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def run(cmd,env,timeout=180):
    p=subprocess.run([str(x) for x in cmd],cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout)
    assert p.returncode==0,(cmd,p.returncode,p.stdout[-2000:],p.stderr[-4000:])
    return p.stdout.replace('\r\n','\n')

def build(source,out,env,*,compiler=None,extra=None,compressed=False,physical=False,ldflags=()):
    out.mkdir(parents=True,exist_ok=True)
    asm=out/'base.s';compiler=compiler or ROOT/'fpr'
    run([compiler,'compile','--system=bare-metal','--profile=base','--target=rv32',
         '--prelude='+str(ROOT/'core/prelude.fpr'),source,asm],env)
    units=[Path(x) for x in Path(str(asm)+'.units').read_text().splitlines()]
    if env.get('FPR_TYPED_IR_STRICT')=='all':
        for p in [asm,*units]:
            t=p.read_text();assert t.startswith('# typed IR: no translation') and '# wcet:' not in t,p
    soft=Path(env.get('FPR_SOFTFLOAT_ROOT',ROOT/'build/tangnano20k-softfloat'))
    library=soft/'build/Linux-RISCV32-GCC/softfloat.a'
    elf=out/'base.elf'
    cmd=['riscv64-unknown-elf-gcc','-march=rv32im'+('c' if compressed else '')+'_zicsr_zifencei',
         '-mabi=ilp32','-mcmodel=medany','-Os','-ffreestanding','-nostdlib','-nostartfiles','-fno-builtin',
         '-DFPR_NHARTS=1','-DFPR_BUILTIN','-DFPR_SIMPLE_RISC','-DFPR_CPU_MHZ=48',
         '-DFPR_BUILTIN_HEAP_MAX_BYTES=8388608','-ffunction-sections','-fdata-sections','-Wl,--gc-sections',
         '-Wl,--no-warn-rwx-segments','-Iruntime','-Imachine/builtin','-T','machine/tangnano20k/link.ld',
         'machine/tangnano20k/crt0.S','machine/tangnano20k/base.c','machine/tangnano20k/sd_hal.c',
         'machine/tangnano20k/unsupported.c','machine/builtin/heap.c','runtime/runtime.c',
         'machine/builtin/unsafe.c','machine/builtin/tangnano20k/machine.c','runtime/i32.c','runtime/bits.c',
         'runtime/vec.c','runtime/sstr.c','runtime/mod.c','machine/virt/memshim.c',
         '-I'+str(soft/'source/include'),'machine/tangnano20k/softfloat.c',asm,*units,library,'-lgcc','-o',elf]
    if not physical:cmd.insert(1,'-DFPR_TANGNANO_QEMU')
    if extra:cmd[1:1]=['-Wl,--wrap=fpr_fn_main',str(extra)]
    cmd[1:1]=list(ldflags)
    run(cmd,env)
    run([sys.executable,ROOT/'tools/check_tangnano20k_isa.py',elf,'--xlen','32',*(['--compressed'] if compressed else [])],env)
    return elf

def boot(elf,env,*,count=False):
    cmd=['qemu-system-riscv32','-machine','virt','-m','8M','-nographic','-bios','none','-kernel',elf]
    if count:cmd[1:1]=['-icount','shift=0,align=off,sleep=off']
    return run(cmd,env,timeout=90)

def fixture(tmp):
    rng=random.Random(7717)
    bits64=[0,1,0x000fffffffffffff,0x0010000000000000,0x3ff3c0ca428c59dd,0x4004000000000000,
            0x7fefffffffffffff,0x7ff0000000000000,0x7ff0000000000001,0x7ff8000000001234,
            0x8000000000000000,0xbff8000000000000,0xfff0000000000000,0xffffffffffffffff]+[rng.getrandbits(64) for _ in range(50)]
    bits32=[0,1,0x007fffff,0x00800000,0x3f800000,0x40200000,0x7f7fffff,0x7f800000,0x7f800001,
            0x7fc01234,0x80000000,0xc0200000,0xff800000,0xffffffff]+[rng.getrandbits(32) for _ in range(50)]
    def body(width,values):
        def lit(x):return f'f64frombits {x>>32} {x&0xffffffff}' if width==64 else f'f32frombits {x}'
        return ''.join(f'if n == {i} then ({lit(x)}) else ' for i,x in enumerate(values[:-1]))+lit(values[-1])
    source=tmp/'float-bits.fpr'
    source.write_text('profile base.\nraw64 : Int -> F64 .\nraw64 n = '+body(64,bits64)+'.\nraw32 : Int -> F32 .\nraw32 n = '+body(32,bits32)+'.\nmain = print "RV32 FLOAT CONSTANTS HOLD".\n')
    oracle=tmp/'float-bits.c'
    oracle.write_text('''#include "builtin.h"
extern V __real_fpr_fn_main(void),fpr_fn_raw64(V),fpr_fn_raw32(V);
#define CHECK(c) do{if(!(c))fpr_cpanic("float constant C oracle failed");}while(0)
'''+f'static const uint64_t expected64[]={{'+','.join(hex(x)+'ULL' for x in bits64)+'};\n'+
        'static const uint32_t expected32[]={'+','.join(hex(x)+'U' for x in bits32)+'};\n'+'''
V __wrap_fpr_fn_main(void){
 uw before=fpr_builtin_live_allocations();
 for(unsigned i=0;i<sizeof(expected64)/sizeof(expected64[0]);i++){
   V a=fpr_fn_raw64(TAG(i)),b=fpr_fn_raw64(TAG(i));fpr_num64_t*p=(void*)a;
   CHECK(a==b && !(a&7) && p->tid==T_BITS && p->var==5 && p->len==64 && p->val==expected64[i]);
 }
 for(unsigned i=0;i<sizeof(expected32)/sizeof(expected32[0]);i++){
   V a=fpr_fn_raw32(TAG(i)),b=fpr_fn_raw32(TAG(i));bits_t*p=(void*)a;
   CHECK(a==b && !(a&7) && p->tid==T_BITS && p->var==6 && p->len==32 && p->val==expected32[i]);
 }
 CHECK(fpr_builtin_live_allocations()==before);
 return __real_fpr_fn_main();
}
''')
    return source,oracle

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution',action='store_true')
    ap.add_argument('--port',help='also load the bit oracle into RAM on an already configured 48 MHz RV32 Tang Nano')
    args=ap.parse_args()
    env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_TYPED_IR_BACKEND='mixed',FPR_TYPED_IR_STRICT='all')
    if 'FPR_SOFTFLOAT_ROOT' in os.environ:env['FPR_SOFTFLOAT_ROOT']=os.environ['FPR_SOFTFLOAT_ROOT']
    with tempfile.TemporaryDirectory(prefix='fpr-boxed-floats-') as d:
        tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
        print(run([sys.executable,ROOT/'tests/check_rv32_base_codegen.py'],env),end='',flush=True)
        missing=[t for t in ('riscv64-unknown-elf-gcc','qemu-system-riscv32') if not shutil.which(t)]
        soft=Path(env.get('FPR_SOFTFLOAT_ROOT',ROOT/'build/tangnano20k-softfloat'))/'build/Linux-RISCV32-GCC/softfloat.a'
        if not soft.is_file():missing.append('RV32 SoftFloat archive (FPR_SOFTFLOAT_ROOT)')
        if missing:
            if args.require_execution or args.port:ap.error('missing '+', '.join(missing))
            print('RV32 boxed-float execution SKIP: '+', '.join(missing));return
        source,oracle=fixture(tmp)
        for disabled in ('0','1'):
            mode=dict(env,FPR_NO_F64_INLINE=disabled)
            elf=build(source,tmp/('bits-'+disabled),mode,extra=oracle)
            out=boot(elf,mode);assert 'RV32 FLOAT CONSTANTS HOLD' in out,out
            print(f'RV32 bits, numeric leaf layout/alignment, repeated addresses, zero allocations: 128 IEEE patterns, no-inline-float={disabled} PASS',flush=True)
        for compressed in (False,True):
            for name,expected in [('tangnano20k_rv32_numeric','RV32 BASE NUMERIC HOLDS'),
                                  ('typed_ir/record_float_kernels','17.5\n'),('typed_ir/f32_kernels','14881\n')]:
                src=ROOT/'tests'/(name+'.fpr');outdir=tmp/(Path(name).name+str(compressed))
                elf=build(src,outdir,env,compressed=compressed)
                out=boot(elf,env);assert expected in out,(name,out)
                print(f'{name}: real RV32IM'+('C' if compressed else '')+' runtime/software arithmetic/vector ABI PASS',flush=True)
        if args.port:
            for name,src,extra,marker in [('bits',source,oracle,'RV32 FLOAT CONSTANTS HOLD'),
                    ('numeric',ROOT/'tests/tangnano20k_rv32_numeric.fpr',None,'RV32 BASE NUMERIC HOLDS')]:
                elf=build(src,tmp/('physical-'+name),env,extra=extra,physical=True);binary=elf.with_suffix('.bin')
                run(['riscv64-unknown-elf-objcopy','-O','binary',elf,binary],env)
                print('Physical '+name+' image sha256='+hashlib.sha256(binary.read_bytes()).hexdigest(),flush=True)
                out=run([sys.executable,ROOT/'tools/run_tangnano20k_base.py',binary,'--port',args.port,'--freq-mhz','48','--timeout','120'],env)
                assert marker in out and 'FPR EXIT 0' in out and 'DONE' in out,out
                print('Physical RV32 '+name+' oracle: '+out.strip(),flush=True)

if __name__=='__main__':main()
