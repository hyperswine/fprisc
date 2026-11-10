#!/usr/bin/env python3
"""Checked products in allocator-free raw libraries and resumed interrupts."""
import os
from pathlib import Path
import re
import tempfile
from check_uniform_aggregate import ROOT, run

SOURCE = '''profile builtin.
Oct = Type (Oct Word Word Word Word Word Word Word Word).
makeOct : Word -> Word -> Oct.
makeOct n w = Oct n w w w w w w w.
step : Oct -> Oct.
step p = case p of Oct n a b c d e f g -> Oct (Word.sub n (Word.fromInt 1)) (Word.add a (Word.fromInt 1)) (Word.add b (Word.fromInt 1)) (Word.add c (Word.fromInt 1)) (Word.add d (Word.fromInt 1)) (Word.add e (Word.fromInt 1)) (Word.add f (Word.fromInt 1)) (Word.add g (Word.fromInt 1)).
loop : Oct -> Oct.
loop p = case p of Oct n a b c d e f g -> if Word.eq n (Word.fromInt 0) then p else loop (step p).
sumOct : Oct -> Word.
sumOct p = case p of Oct n a b c d e f g -> Word.add a (Word.add b (Word.add c (Word.add d (Word.add e (Word.add f g))))).
runRaw : Word -> Word.
runRaw w = sumOct (loop (makeOct (Word.fromInt 500) w)).
branchRaw : Bool -> Word -> Word.
branchRaw flag w = p = if flag then makeOct (Word.fromInt 0) w else makeOct (Word.fromInt 0) (Word.fromInt 0); sumOct p.
Mixed = Type (Mixed Word F64 F32 Addr Int Bool Unit).
makeMixed : F64 -> F32 -> Mixed.
makeMixed d f = Mixed (Word.fromInt 7) d f (Addr.fromWord (Word.fromInt 0)) 3 True Unit.
readMixed : Mixed -> F64.
readMixed p = case p of Mixed w d f a i b u -> d.
floatRaw : F64 -> F32 -> F64.
floatRaw d f = readMixed (makeMixed d f).
readFloat : Mixed -> F32.
readFloat p = case p of Mixed w d f a i b u -> f.
float32Raw : F64 -> F32 -> F32.
float32Raw d f = readFloat (makeMixed d f).
Pair = Type (Pair Word Word).
writeFirst : Addr -> Word -> Word.
writeFirst p w = _ = Mem.writeWord p w; w.
writeSecond : Addr -> Word -> Word.
writeSecond p w = _ = Mem.writeWord (Addr.add p 8) w; w.
makePair : Word -> Word -> Pair.
makePair a b = Pair a b.
readPair : Pair -> Word.
readPair p = case p of Pair a b -> Word.add a b.
effectRaw : Addr -> Word -> Word.
effectRaw p w = readPair (makePair (writeFirst p w) (writeSecond p (Word.not w))).
Four = Type (Four Pair Pair).
NestedEight = Type (NestedEight Four Four).
makeNested : Word -> NestedEight.
makeNested w = NestedEight (Four (Pair w (Word.not w)) (Pair (Word.add w (Word.fromInt 1)) (Word.sub w (Word.fromInt 1)))) (Four (Pair (Word.xor w (Word.fromInt 17)) (Word.or w (Word.fromInt 64))) (Pair (Word.and w (Word.fromInt 255)) (Word.add w w))).
readNested : NestedEight -> Word.
readNested p = case p of NestedEight a b -> case a of Four c d -> case b of Four e f ->
 case c of Pair w x -> case d of Pair y z -> case e of Pair h i -> case f of Pair j k ->
 Word.xor (Word.add w x) (Word.xor (Word.add y z) (Word.xor (Word.add h i) (Word.add j k))).
nestedRaw : Word -> Word.
nestedRaw w = readNested (makeNested w).
Floats = Type (Floats F64 F32).
NestedMixed = Type (NestedMixed Pair Floats).
makeNestedMixed : Word -> F64 -> F32 -> NestedMixed.
makeNestedMixed w d f = NestedMixed (Pair w (Word.not w)) (Floats d f).
readNestedDouble : NestedMixed -> F64.
readNestedDouble p = case p of NestedMixed _ fs -> case fs of Floats d f -> d.
readNestedFloat : NestedMixed -> F32.
readNestedFloat p = case p of NestedMixed _ fs -> case fs of Floats d f -> f.
nestedFloatRaw : F64 -> F32 -> F64.
nestedFloatRaw d f = readNestedDouble (makeNestedMixed (Word.fromInt 7) d f).
nestedFloat32Raw : F64 -> F32 -> F32.
nestedFloat32Raw d f = readNestedFloat (makeNestedMixed (Word.fromInt 7) d f).
'''

# Check every source-field position independently, not only a symmetric sum.
NESTED_EXPORTS = []
for index, field in enumerate(('w','x','y','z','h','i','j','k')):
    NESTED_EXPORTS.append(f'nestedField{index}')
    SOURCE += (f'readField{index} : NestedEight -> Word.\nreadField{index} p = '
               'case p of NestedEight a b -> case a of Four c d -> case b of Four e f -> '
               'case c of Pair w x -> case d of Pair y z -> case e of Pair h i -> case f of Pair j k -> '+field+'.\n'
               f'nestedField{index} : Word -> Word.\nnestedField{index} w = readField{index} (makeNested w).\n')

ORACLE = r'''
#include <stdint.h>
#include <stddef.h>
struct {uint32_t tid,var;} fpr_unit={0,0},fpr_false={1,0},fpr_true={1,1};
extern uint64_t runRaw(uint64_t),branchRaw(int,uint64_t),effectRaw(void*,uint64_t);
extern double floatRaw(double,float);
extern float float32Raw(double,float);
extern uint64_t nestedRaw(uint64_t);
extern double nestedFloatRaw(double,float);
extern float nestedFloat32Raw(double,float);
NESTED_DECLARATIONS
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
__attribute__((noreturn)) void oracle_finish(int code){*(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){}}
__attribute__((noreturn)) void fpr_cpanic(const char*s){say(s);oracle_finish(1);}
__attribute__((noreturn)) void fpr_panic(uint64_t object){(void)object;fpr_cpanic("unexpected generated panic");}
uint64_t fpr_fn__x24arc_x2ememwriteWord(uint64_t address,uint64_t value){
 if(address&7)fpr_cpanic("unaligned oracle address");
 *(volatile uint64_t*)(uintptr_t)address=value;return (uint64_t)(uintptr_t)&fpr_unit;
}
int main(void){
 for(uint64_t i=0;i<256;i++){
  uint64_t w=0xfedcba9876543210ULL^i;
  if(runRaw(w)!=(w+500)*7 || branchRaw(1,w)!=w*7 || branchRaw(0,w)!=0)fpr_cpanic("raw product result");
  union{uint32_t bits;float value;}f={.bits=i==0?0x80000000U:0x7fc00011U+(uint32_t)i};
  union{uint64_t bits;double value;}d={.bits=i==0?0x8000000000000000ULL:0x7ff8000000000011ULL+i},r={.value=floatRaw(d.value,f.value)};
  union{uint32_t bits;float value;}fr={.value=float32Raw(d.value,f.value)};
  if(r.bits!=d.bits || fr.bits!=f.bits)fpr_cpanic("raw product IEEE payload");
  r.value=nestedFloatRaw(d.value,f.value);fr.value=nestedFloat32Raw(d.value,f.value);
  if(r.bits!=d.bits || fr.bits!=f.bits)fpr_cpanic("nested product IEEE payload");
  uint64_t expected=(w+~w)^((w+1)+(w-1))^((w^17)+(w|64))^((w&255)+(w+w));
  if(nestedRaw(w)!=expected)fpr_cpanic("nested eight-field result");
  uint64_t fields[]={w,~w,w+1,w-1,w^17,w|64,w&255,w+w};
  for(unsigned field=0;field<8;field++)if(nested_fields[field](w)!=fields[field])fpr_cpanic("nested field position");
  uint64_t slots[4]={0x1122,0,0,0x3344};
  if(effectRaw(slots+1,w)!=UINT64_MAX || slots[0]!=0x1122 || slots[1]!=w || slots[2]!=~w || slots[3]!=0x3344)fpr_cpanic("raw product effects");
 }
 say("RAW_PRODUCTS_WITHOUT_ALLOCATOR_PASS\n");return 0;
}
'''

ORACLE = ORACLE.replace('NESTED_DECLARATIONS',
    'extern uint64_t '+','.join(name+'(uint64_t)' for name in NESTED_EXPORTS)+';\n'
    'static uint64_t (*nested_fields[])(uint64_t)={'+','.join(NESTED_EXPORTS)+'};')

IRQ_HELPERS = '''Oct = Type (Oct Word Word Word Word Word Word Word Word).
makePacket : Word -> Oct.
makePacket c = Oct c (Word.not c) (Word.add c (Word.fromInt 1)) (Word.sub c (Word.fromInt 1)) (Word.xor c (Word.fromInt 17)) (Word.or c (Word.fromInt 64)) (Word.and c (Word.fromInt 255)) (Word.shl c 3).
inspectPacket : Oct -> Word.
inspectPacket p = case p of Oct a b c d e f g h ->
 if Word.eq b (Word.not a) then
 if Word.eq c (Word.add a (Word.fromInt 1)) then
 if Word.eq d (Word.sub a (Word.fromInt 1)) then
 if Word.eq e (Word.xor a (Word.fromInt 17)) then
 if Word.eq f (Word.or a (Word.fromInt 64)) then
 if Word.eq g (Word.and a (Word.fromInt 255)) then
 if Word.eq h (Word.shl a 3) then Word.fromInt 1
 else error "packet h" else error "packet g" else error "packet f" else error "packet e" else error "packet d" else error "packet c" else error "packet b".
'''

# The handler exercises both the original flat packet and a three-level tree
# with the same eight leaves. No constructor or ARC runtime may execute there.
IRQ_HELPERS += SOURCE[SOURCE.index('Four ='):SOURCE.index('Floats =')]

IRQ_GUARD = r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void),__real_fpr_fn_machineInterrupt(uw,uw,uw),__real_fpr_builtin_alloc_adt(V,uw);
static uw allocations,interrupts;
V __wrap_fpr_builtin_alloc_adt(V b,uw n){allocations++;return __real_fpr_builtin_alloc_adt(b,n);}
V fpr_test_product_interrupt(uw cause,uw pc,uw value){
 uw count=allocations,live=fpr_builtin_live_allocations();
 V result=__real_fpr_fn_machineInterrupt(cause,pc,value);
 if(count!=allocations || live!=fpr_builtin_live_allocations())fpr_cpanic("interrupt product allocated");
 interrupts++;return result;
}
V fpr_test_product_main(void){
 V result=__real_fpr_fn_main();
 if(interrupts!=1001)fpr_cpanic("product interrupt count");
 return result;
}
void fpr_test_irq_verify(const uw*p){
 if(*(volatile uw*)0x81000000!=1 || interrupts!=1)fpr_cpanic("probe: no product interrupt");
 for(uw i=0;i<64;i++)if(p[i]!=p[64+i])fpr_cpanic("probe: register changed");
 if(p[128]!=97)fpr_cpanic("probe: fcsr changed");
}
'''


def raw_library(tmp, env, rollback, abi):
    source=tmp/'raw-products.fpr';source.write_text(SOURCE)
    asm=tmp/f'raw-products-{rollback}-{abi}.s'
    run([ROOT/'fpr','--profile=bare-metal-builtin','--arc','--raw','--lib',f'--float-abi={abi}',
         '--export=runRaw,branchRaw,floatRaw,float32Raw,effectRaw,nestedRaw,nestedFloatRaw,nestedFloat32Raw,'+','.join(NESTED_EXPORTS),source,asm],env=env)
    text=asm.read_text()
    assert re.search(r'\b(?:call|tail) .*ret8',text), 'eight-word calls must survive'
    crt=tmp/'crt.S';crt.write_text((ROOT/'tests/typed_ir/kernel_crt.S').read_text().split('.globl fpr_fuel_exhausted')[0])
    oracle=tmp/'oracle.c';oracle.write_text(ORACLE)
    image=asm.with_suffix('.elf')
    run(['riscv64-unknown-elf-gcc','-ffixed-x27','-march=rv64imafdc_zicsr',f'-mabi={"lp64d" if abi=="hard" else "lp64"}','-mcmodel=medany',
         '-msmall-data-limit=0','-O2','-ffreestanding','-nostdlib','-fno-builtin','-Wl,--gc-sections',
         '-T',ROOT/'tests/typed_ir/kernel_link.ld',crt,asm,oracle,'-o',image])
    symbols=run(['riscv64-unknown-elf-nm',image])
    assert not re.search(r'\b(?:fpr_builtin_(?:alloc|retain|release)|malloc|free)\w*$',symbols,re.M),symbols
    output=run(['qemu-system-riscv64','-machine','virt','-m','16M','-nographic','-bios','none','-kernel',image])
    assert output.strip()=='RAW_PRODUCTS_WITHOUT_ALLOCATOR_PASS',output
    print(f'{abi}, type-spec rollback={rollback}: flat/nested eight-word products, recursion/joins, IEEE bits and memory effects, no allocator/ARC linked PASS',flush=True)


def interrupt(tmp, env, rollback, allocator):
    original=(ROOT/'tests/builtin_interrupt.fpr').read_text()
    original=original.replace('(Word.add (Mem.readWord flag) (Word.fromInt 1))',
                              '(Word.add (Mem.readWord flag) (checkedPacket cause))')
    checked = ('Pair = Type (Pair Word Word).\ncheckedPacket : Word -> Word.\n'
               'checkedPacket c = expected = Word.xor (Word.add c (Word.not c)) (Word.xor (Word.add (Word.add c (Word.fromInt 1)) (Word.sub c (Word.fromInt 1))) (Word.xor (Word.add (Word.xor c (Word.fromInt 17)) (Word.or c (Word.fromInt 64))) (Word.add (Word.and c (Word.fromInt 255)) (Word.add c c))));\n'
               'if Word.eq (nestedRaw c) expected then inspectPacket (makePacket c) else error "nested interrupt packet".\n')
    source=tmp/'interrupt-products.fpr';source.write_text(IRQ_HELPERS+checked+original)
    probe=tmp/'irq.S';probe.write_text((ROOT/'tests/builtin_interrupt_probe.S').read_text().replace('call __real_fpr_fn_machineInterrupt','call fpr_test_product_interrupt').replace('call __real_fpr_fn_main','call fpr_test_product_main'))
    guard=tmp/'irq.c';guard.write_text(IRQ_GUARD)
    build=tmp/f'irq-{rollback}-{allocator}';image=build.with_suffix('.elf')
    run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',f'HEAP={allocator}','BUILTIN_HEAP_BYTES=16384',
         f'PROG={source}',f'BUILD={build}',f'IMAGE={image}',f'BUILTIN_EXTRA={probe} {guard}',
         'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main,--wrap=fpr_fn_machineInterrupt,--wrap=fpr_builtin_alloc_adt'],env=env)
    assert re.search(r'\b(?:call|tail) .*ret8', (build/'builtin.s').read_text())
    output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image])
    assert 'INTERRUPTS RESUME' in output,output
    print(f'{allocator}, type-spec rollback={rollback}: 1,001 resumed product interrupts; GPR/FPR/fcsr restored and zero handler allocations PASS',flush=True)


def refusals(tmp, env):
    pair=('Pair = Type (Pair Word Word).\nmake : Word -> Pair.\nmake w = Pair w w.\n'
          'read : Pair -> Word.\nread p = case p of Pair a b -> Word.add a b.\n')
    wide=('wide : Pair -> Pair -> Pair -> Pair -> Pair -> Word.\n'
          'wide a b c d e = Word.add (read a) (Word.add (read b) (Word.add (read c) (Word.add (read d) (read e)))).\n')
    cases=[
        ('expanded-raw',True,pair+wide+'entry : Word -> Word.\nentry w = p = make w; wide p p p p p.\n',['entry'],'after product expansion'),
        ('expanded-interrupt',False,pair+wide+'machineInterrupt c p v = _ = wide (make c) (make c) (make c) (make c) (make c); Unit.\nmain = Unit.\n',[], 'after product expansion'),
        ('boxed-export',True,pair,['make'],'not a C-representable type'),
        ('generic',True,pair+'identity : a -> a.\nidentity x = x.\nentry : Word -> Word.\nentry w = Word.add (read (identity (make w))) (Word.fromInt (identity 7)).\n',['entry'],'incompatible representations'),
        ('heap',True,pair+'entry : Word -> Word.\nentry w = xs = [make w]; case xs of p :: _ -> read p | _ -> w.\n',['entry'],'raw unit'),
        ('rollback',True,pair+'entry : Word -> Word.\nentry w = read (make w).\n',['entry'],'raw unit'),
        ('nested-owned',True,'Inner = Type (Inner String Word).\nOuter = Type (Outer Inner Word).\n'
         'make : Word -> Outer.\nmake w = Outer (Inner "owned" w) w.\n'
         'read : Outer -> Word.\nread p = case p of Outer inner w -> case inner of Inner s x -> Word.add w x.\n'
         'entry : Word -> Word.\nentry w = read (make w).\n',['entry'],'owned-reference products'),
        ('single-owned',True,'Shell = Type (Shell String).\nmake : Word -> Shell.\nmake w = Shell "owned".\n'
         'read : Shell -> Word.\nread p = case p of Shell s -> Word.fromInt (String.len s).\n'
         'entry : Word -> Word.\nentry w = read (make w).\n',['entry'],'owned-reference products'),
        ('single-owned-interrupt',False,'Shell = Type (Shell String).\nmake : Word -> Shell.\nmake w = Shell "owned".\n'
         'read : Shell -> Word.\nread p = case p of Shell s -> Word.fromInt (String.len s).\n'
         'machineInterrupt c p v = Mem.writeWord (Addr.fromWord p) (read (make c)).\nmain = Unit.\n',[],'owned-reference products'),
        ('nested-too-wide',True,pair+SOURCE[SOURCE.index('Four ='):SOURCE.index('Floats =')]+
         'Nine = Type (Nine NestedEight Word).\nmakeNine : Word -> Nine.\nmakeNine w = Nine (makeNested w) w.\n'
         'readNine : Nine -> Word.\nreadNine p = case p of Nine inner w -> Word.add (readNested inner) w.\n'
         'entry : Word -> Word.\nentry w = readNine (makeNine w).\n',['entry'],'owned-reference products'),
    ]
    for name,raw,code,exports,message in cases:
        source=tmp/f'refused-{name}.fpr';source.write_text(code)
        output=source.with_suffix('.s');current=dict(env)
        if name=='rollback':current['FPR_NO_PAIR_RETURNS']='1'
        if name=='generic':current['FPR_NO_TYPE_SPEC']='1'
        result=run([ROOT/'fpr','--profile=bare-metal-builtin','--arc',*(['--raw','--lib'] if raw else []),
                    *(['--export='+','.join(exports)] if exports else []),source,output],expected=1,env=current)
        assert message in result and not output.exists(),result
    print('Expanded register ABI, boxed export, incompatible generic representations, heap storage and product rollback: refused before emission PASS',flush=True)


FAULT_GUARD = r'''#include "builtin.h"
extern void __real_fpr_cpanic_n(const char*,uw),__real_fpr_cpanic(const char*);
static void check_trace(void){
 volatile unsigned char*uart=(void*)0x10000000;
 const char*s=*(volatile uw*)0x81000000==0x12?"RAW_PRODUCT_TRACE_PASS\n":"RAW_PRODUCT_TRACE_FAIL\n";
 for(;*s;s++){while(!(uart[5]&32)){}uart[0]=*s;}
}
void __wrap_fpr_cpanic_n(const char*s,uw n){check_trace();__real_fpr_cpanic_n(s,n);}
void __wrap_fpr_cpanic(const char*s){check_trace();__real_fpr_cpanic(s);}
'''


def faults(tmp,env,rollback,nested=False):
    guard=tmp/'fault-guard.c';guard.write_text(FAULT_GUARD)
    for name,input_value,expression,message in [
        ('maximum','intMax Unit','n + 1','overflow'),
        ('minimum','intMin Unit','n - 1','overflow'),
        ('division','3','17 / (n - n)','division by zero'),
        ('shift','64','Word.toInt (Word.shl (Word.fromInt 1) n)','shift out of range'),
        ('alignment','0','Word.toInt (Mem.readWord (Addr.add p 1))','unaligned access'),
    ]:
        source=tmp/f'fault-{rollback}-{nested}-{name}.fpr'
        packet=('Pair = Type (Pair Int Int).\nOuter = Type (Outer Pair Int).\n'
                'pack : Int -> Int -> Outer.\npack a b = Outer (Pair a b) 0.\n'
                'first : Outer -> Int.\nfirst p = case p of Outer inner _ -> case inner of Pair a _ -> a.\n'
                if nested else 'Pair = Type (Pair Int Int).\n'
                'pack : Int -> Int -> Pair.\npack a b = Pair a b.\n'
                'first : Pair -> Int.\nfirst p = case p of Pair a _ -> a.\n')
        source.write_text(packet+
            'left : Addr -> Int -> Int.\nleft p n = _ = Mem.writeWord p (Word.add (Word.shl (Mem.readWord p) 4) (Word.fromInt 1)); n.\n'
            'right : Addr -> Int -> Int.\nright p n = _ = Mem.writeWord p (Word.add (Word.shl (Mem.readWord p) 4) (Word.fromInt 2)); '+expression+'.\n'
            'entry : Addr -> Int -> Int.\nentry p n = first (pack (left p n) (right p n)).\n'
            'main = p = Addr.fromWord (Word.fromInt 2164260864); _ = Mem.writeWord p (Word.fromInt 0); '
            '_ = entry p ('+input_value+'); _ = Mem.writeWord p (Word.fromInt 3); Unit.\n')
        build=source.with_suffix('');image=build.with_suffix('.elf')
        run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1','HEAP=c','FPRC_FLAGS=--raw',
             f'PROG={source}',f'BUILD={build}',f'IMAGE={image}',f'BUILTIN_EXTRA={guard}',
             'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_cpanic,--wrap=fpr_cpanic_n'],env=env)
        output=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',image],expected=1)
        assert 'RAW_PRODUCT_TRACE_PASS' in output and 'RAW_PRODUCT_TRACE_FAIL' not in output and message in output,output
    print(f'type-spec rollback={rollback}, nested={nested}: unused product fields preserve memory-effect order and overflow/division/shift/alignment failures PASS',flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-raw-products-') as directory:
        tmp=Path(directory)
        for rollback in (False,True):
            env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
            env.update(FPR_HOME=str(ROOT),FPR_NO_INLINE='1',FPR_TYPED_IR_BACKEND='1',FPR_TYPED_IR_STRICT='all',XDG_CACHE_HOME=str(tmp/f'cache-{rollback}'))
            if rollback:env['FPR_NO_TYPE_SPEC']='1'
            refusals(tmp,env)
            faults(tmp,env,rollback)
            faults(tmp,env,rollback,nested=True)
            for abi in ('soft','hard'):raw_library(tmp,env,rollback,abi)
            for allocator in ('c','fpr'):interrupt(tmp,env,rollback,allocator)

if __name__=='__main__':main()
