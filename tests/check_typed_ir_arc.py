#!/usr/bin/env python3
"""ARC/raw ownership, exports, interrupts and an independent raw-bit oracle."""
import argparse,os,random,shutil,subprocess,sys,tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution',action='store_true')
    ap.add_argument('--backend',choices=('mixed','1'),default='mixed')
    a=ap.parse_args()
    missing=[t for t in ('riscv64-unknown-elf-gcc','qemu-system-riscv64','clang') if not shutil.which(t)]
    if missing:
        if a.require_execution:ap.error('missing execution tools: '+', '.join(missing))
        print('ARC execution SKIP: '+', '.join(missing));return
    env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_TYPED_IR_BACKEND=a.backend)
    if a.backend in ('mixed','1'):env['FPR_TYPED_IR_STRICT']='all'
    def run(cmd,timeout=600,expected=0):
        r=subprocess.run([str(x) for x in cmd],cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout)
        assert r.returncode==expected,(cmd,r.returncode,r.stdout,r.stderr)
        return r.stdout+r.stderr
    with tempfile.TemporaryDirectory(prefix='fpr-typed-arc-') as d:
        tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
        for script in ('check_arc.py','check_raw.py','check_layout.py','check_export.py'):
            print(run([sys.executable,ROOT/'tests'/script]),end='',flush=True)

        # A raw library links into hosts without the ARC adapter table.
        # Byte addresses need no alignment guard or slow-path symbol.
        byte_src=tmp/'raw-byte.fpr'
        byte_src.write_text('profile builtin.\nroundTrip : Addr -> Int -> Int.\n'
                            'roundTrip p x = _ = Mem.write8 p x; Mem.read8 p.\n')
        byte_asm=tmp/'raw-byte.s'
        run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--raw','--lib',
             '--export=roundTrip:raw_round_trip',byte_src,byte_asm])
        if a.backend in ('mixed','1'):
            assert '# typed IR: no translation' in byte_asm.read_text()
        assert 'call fpr_fn__x24arc_x2ememread8' not in byte_asm.read_text()
        assert 'call fpr_fn__x24arc_x2ememwrite8' not in byte_asm.read_text()
        crt=tmp/'byte-crt.S'
        crt.write_text((ROOT/'tests/typed_ir/kernel_crt.S').read_text().split('.globl fpr_fuel_exhausted')[0])
        byte_c=tmp/'raw-byte.c'
        byte_c.write_text(r'''#include <stdint.h>
struct { uint32_t tid,var; } fpr_unit={0,0};
extern intptr_t raw_round_trip(void*,intptr_t);
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
__attribute__((noreturn)) void oracle_finish(int code){*(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){}}
int main(void){
 unsigned char bytes[16];
 for(unsigned offset=1;offset<=8;offset++)for(unsigned value=0;value<256;value++){
  for(unsigned i=0;i<16;i++)bytes[i]=0xa7;
  if(raw_round_trip(bytes+offset,value)!=(intptr_t)value)oracle_finish(1);
  for(unsigned i=0;i<16;i++)if(bytes[i]!=(i==offset?value:0xa7))oracle_finish(2);
 }
 say("RAW_BYTE_UNIT_PASS\n");return 0;
}
''')
        byte_elf=tmp/'raw-byte.elf'
        run(['riscv64-unknown-elf-gcc','-march=rv64im_zicsr_zifencei','-mabi=lp64','-mcmodel=medany',
             '-msmall-data-limit=0','-O2','-ffreestanding','-nostdlib','-fno-builtin','-Wl,--gc-sections',
             '-T',ROOT/'tests/typed_ir/kernel_link.ld',crt,byte_asm,byte_c,'-o',byte_elf])
        out=run(['qemu-system-riscv64','-machine','virt','-m','16M','-nographic','-bios','none','-kernel',byte_elf])
        assert 'RAW_BYTE_UNIT_PASS' in out,out
        print('Raw byte library without ARC runtime/adapters: 2048 value/address cases and neighbor canaries PASS',flush=True)

        # Dropping constructor field metadata must fail the ownership oracle.
        bad=tmp/'missing-fields.c'
        bad.write_text('#include "builtin.h"\nextern V __real_fpr_builtin_alloc_adt(uw,uw);\nV __wrap_fpr_builtin_alloc_adt(uw bytes,uw fields){(void)fields;return __real_fpr_builtin_alloc_adt(bytes,0);}\n')
        image=tmp/'missing-fields.elf'
        run(['make','bare-metal-builtin','ARC=1','ARC_CHECK=1','BUILTIN_HEAP_BYTES=16384',
            'PROG=tests/builtin_arc.fpr','BUILD='+str(tmp/'missing-fields'),'IMAGE='+str(image),
            'BUILTIN_EXTRA='+str(bad),'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_builtin_alloc_adt'])
        out=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=1)
        assert 'Builtin: invalid field descriptor' in out,out
        print('Negative control: missing constructor field metadata fails the real ownership runtime PASS',flush=True)

        mask=(1<<64)-1;rng=random.Random(7616)
        def word(n):
            n&=mask
            return f'(Word.or (Word.shl (Word.fromInt {n>>32}) 32) (Word.fromInt {n&0xffffffff}))'
        checks=[]
        values=[0,1,mask,1<<63,(1<<63)-1,0xaaaaaaaaaaaaaaaa,0x5555555555555555]+[rng.getrandbits(64) for _ in range(9)]
        for i,x in enumerate(values):
            y=values[(i+5)%len(values)]
            for op,result in [('add',x+y),('sub',x-y),('and',x&y),('or',x|y),('xor',x^y)]:
                checks.append(f'Word.eq (Word.{op} {word(x)} {word(y)}) {word(result)}')
            checks.append(f'Word.eq (Word.not {word(x)}) {word(~x)}')
        for n in range(64):
            x=values[n%len(values)]
            for op,result in [('shl',x<<n),('shr',x>>n),('bitSet',x|(1<<n)),('bitClear',x&~(1<<n))]:
                checks.append(f'Word.eq (Word.{op} {word(x)} {n}) {word(result)}')
            checks.append(f'Word.bitTest {word(x)} {n}' if (x>>n)&1 else f'Word.eq (Word.fromInt 0) (Word.fromInt (case Word.bitTest {word(x)} {n} of True -> 1 | False -> 0))')
        ints=[-(1<<62),-(1<<31),-1,0,1,(1<<31)-1,(1<<62)-1]+[rng.randrange(-(1<<62),1<<62) for _ in range(9)]
        for x in ints:
            for y in (-1,1,3):
                for op,result in [('+',x+y),('-',x-y),('*',x*y),('/',(abs(x)//abs(y))*(-1 if (x<0)!=(y<0) else 1))]:
                    if -(1<<62)<=result<(1<<62):checks.append(f'({x} {op} {y}) == {result}')
                for op,result in [('<',x<y),('>',x>y),('<=',x<=y),('>=',x>=y),('==',x==y),('!=',x!=y)]:
                    checks.append(f'({x} {op} {y}) == '+('True' if result else 'False'))
        chunks=[checks[i:i+24] for i in range(0,len(checks),24)]
        src=tmp/'bits.fpr'
        src.write_text('check b = case b of True -> Unit | False -> error "raw bit oracle failed".\n'+
            ''.join('chunk'+str(i)+' u = '+''.join('_ = check ('+c+'); ' for c in cs)+'Unit.\n' for i,cs in enumerate(chunks))+
            'main = '+''.join('_ = chunk'+str(i)+' Unit; ' for i in range(len(chunks)))+'print "ARC RAW BIT ORACLE HOLDS".\n')
        image=tmp/'bits.elf';build=tmp/'bits'
        run(['make','bare-metal-builtin','ARC=1','ARC_CHECK=1','BUILTIN_HEAP_BYTES=16384','PROG='+str(src),'BUILD='+str(build),'IMAGE='+str(image)])
        if a.backend in ('mixed','1'):
            for path in (build/'builtin.s',build/'heap.s'):
                text=path.read_text()
                assert '# typed IR: no translation' in text and '# wcet:' not in text,path
                assert 'fpr_fuel_exhausted' not in text and 'fpr_stack_grow' not in text,path
        out=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image])
        assert 'ARC RAW BIT ORACLE HOLDS' in out,out
        print(f'Independent Python word/Int oracle: {len(checks)} checks, every shift/bit index, wrapping, high bits and checked arithmetic PASS',flush=True)

if __name__=='__main__':main()
