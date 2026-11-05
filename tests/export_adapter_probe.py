"""Independent C callers for the existing RV64 soft/hard export ABIs.

Also supplies fixtures to the two-compiler exact-emission oracle. This helper
runs inside check_export.py, so it adds no separate Base build/job.
"""
from pathlib import Path
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[1]
SMALL = ['F64', 'Int', 'F32', 'Bool', 'Word', 'Unit', 'Addr', 'F64']
WIDE = (['Int', 'Bool', 'Unit', 'F32', 'F64', 'Word', 'Addr'] * 10)[:64]
WIDE_RETURNS = [0, 8, 9, 11, 12, 31, 55, 62, 63]
C_TYPES = {'Int': 'intptr_t', 'Bool': 'int', 'Unit': 'uintptr_t', 'Word': 'uintptr_t',
           'Addr': 'void*', 'F64': 'double', 'F32': 'float'}


def entries():
    return ([('small' + str(i), SMALL, i) for i in range(8)]
            + [('wide' + str(i), WIDE, i) for i in WIDE_RETURNS])


def fixture():
    text = ['profile builtin.']
    for name, kinds, result in entries():
        text += [name + ' : ' + ' -> '.join(kinds + [kinds[result]]) + '.',
                 name + ' ' + ' '.join('p' + str(i) for i in range(len(kinds))) + ' = p' + str(result) + '.']
    text += ['zeroWord : Word.', 'zeroWord = Word.not (Word.fromInt 0).']
    text += ['guarded : (n : Int | n > 0) -> Word -> Word.',
             'guarded n w = w.']
    text += ['trapOverflow : Word -> Int -> Int.',
             'trapOverflow x n = _ = print (Word.toInt (Word.and x (Word.fromInt 7))); n + 1.',
             'trapDivide : Word -> Int -> Int.',
             'trapDivide x n = _ = print (Word.toInt (Word.and x (Word.fromInt 7))); 17 / n.',
             'trapBounds : Addr -> Word.', 'trapBounds p = _ = print 7; Mem.readWord p.']
    return '\n'.join(text) + '\n'


def export_flags(hard):
    names = [name for name, _, _ in entries() if not hard or name.startswith('small')] + ['zeroWord','guarded','trapOverflow','trapDivide','trapBounds']
    return ['--profile=bare-metal-builtin', '--arc', '--lib', '--export=' + ','.join(names)] + (
        ['--float-abi=hard'] if hard else [])


def check_adapter_probes(tmp, run):
    source = tmp / 'adapter-probe.fpr'
    source.write_text(fixture())
    for hard in (False, True):
        selected = [entry for entry in entries() if not hard or entry[0].startswith('small')]
        prototypes, checks = [], []
        for name, kinds, result in selected:
            kind = kinds[result]
            prototypes += [f'extern {C_TYPES[kind]} {name}(' + ','.join(C_TYPES[k] for k in kinds) + ');']
            def bits(k, position):
                return ('d.bits ^ (0x1000000000001ULL*'+str(position)+')' if k == 'F64'
                        else 's.bits ^ (0x10101U*'+str(position)+')')
            def value(k, position):
                return {'Int': '(n+'+str(17*position)+')',
                        'Bool': '((((iteration+1)*0x9e3779b9U)>>'+str(position%31)+')&1)',
                        'Unit': '(uintptr_t)(0xfedcba9876543210ULL+'+str(position)+')',
                        'Word': '(w ^ (0x100000001ULL*'+str(position)+'))',
                        'Addr': '(void*)&cells['+str(position)+']',
                        'F64': '((union D){.bits='+bits('F64',position)+'}).value',
                        'F32': '((union F){.bits='+bits('F32',position)+'}).value'}[k]
            call = name + '(' + ','.join(value(k, i) for i, k in enumerate(kinds)) + ')'
            if kind == 'F64':
                condition = f'((union D){{.value={call}}}).bits != ('+bits(kind,result)+')'
            elif kind == 'F32':
                condition = f'((union F){{.value={call}}}).bits != ('+bits(kind,result)+')'
            else:
                want = '(uintptr_t)&fpr_unit' if kind == 'Unit' else value(kind,result)
                condition = call + ' != ' + want
            boxes = sum(k in ('Word','Addr','F64','F32') for k in kinds) + (kind in ('Word','Addr','F64','F32'))
            checks += ['  requests_before=boundary_requests;',
                       '  if (' + condition + ') oracle_finish(' + str(len(checks) + 1) + ');',
                       f'  if (boundary_requests!=requests_before+{boxes}) oracle_finish(906);']
            checks += ['  if (fpr_builtin_live_allocations()!=before) oracle_finish(900);']
        harness = tmp / ('adapter-hard.c' if hard else 'adapter-soft.c')
        harness.write_text('''#include <stdint.h>
#include "builtin.h"
extern uintptr_t __real_fpr_fn_main(void);
extern uintptr_t zeroWord(void);
extern uintptr_t guarded(intptr_t,uintptr_t);
extern V native_entry(V,V,V,V,V,V,V,V) __asm__("NATIVE_ENTRY");
extern V raw_worker(V,V,V,V,V,V,V,V) __asm__("RAW_WORKER");
extern V fpr_fn__x24arc_x2euniformBoxWord(V), fpr_fn__x24arc_x2euniformBoxAddr(V);
extern V fpr_fn__x24arc_x2euniformBoxF64(V), fpr_fn__x24arc_x2euniformBoxF32(V);
extern V fpr_fn__x24arc_x2euniformUnboxWord(V);
extern V fpr_prim_fn__x3d_x3d(V,V), fpr_prim_fn_str(V);
static uw boundary_requests;
extern V __real_fpr_builtin_alloc_adt(V,uw);
V __wrap_fpr_builtin_alloc_adt(V bytes,uw fields){boundary_requests++;return __real_fpr_builtin_alloc_adt(bytes,fields);}
union D { uint64_t bits; double value; };
union F { uint32_t bits; float value; };
__attribute__((noreturn)) void oracle_finish(int code){*(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){}}
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
static int render15(V value){
 V text=fpr_prim_fn_str(value); str_t*s=(str_t*)text;
 int ok=s->len==3 && s->bytes[0]=='1' && s->bytes[1]=='.' && s->bytes[2]=='5';
 fpr_builtin_release(text); return ok;
}
static void generic_scalars(void){
 uw live=fpr_builtin_live_allocations();
 V dn=fpr_fn__x24arc_x2euniformBoxF64(0x7ff8000000000001ULL);
 V dz=fpr_fn__x24arc_x2euniformBoxF64(0), dm=fpr_fn__x24arc_x2euniformBoxF64(0x8000000000000000ULL);
 V d=fpr_fn__x24arc_x2euniformBoxF64(0x3ff8000000000000ULL);
 V fn=fpr_fn__x24arc_x2euniformBoxF32(0x7fc00001U);
 V fz=fpr_fn__x24arc_x2euniformBoxF32(0), fm=fpr_fn__x24arc_x2euniformBoxF32(0x80000000U);
 V f=fpr_fn__x24arc_x2euniformBoxF32(0x3fc00000U);
 if(fpr_prim_fn__x3d_x3d(dn,dn)!=(V)&fpr_false || fpr_prim_fn__x3d_x3d(fn,fn)!=(V)&fpr_false) oracle_finish(920);
 if(fpr_prim_fn__x3d_x3d(dz,dm)!=(V)&fpr_true || fpr_prim_fn__x3d_x3d(fz,fm)!=(V)&fpr_true) oracle_finish(921);
 if(!render15(d) || !render15(f)) oracle_finish(922);
 V tuple=fpr_builtin_alloc_adt(8+2*sizeof(V),2);
 ((hdr_t*)tuple)->tid=T_TUP2; ((hdr_t*)tuple)->var=0;
 ((V*)(tuple+8))[0]=fpr_builtin_retain(dn); ((V*)(tuple+8))[1]=(V)&fpr_unit;
 struct {hdr_t h;uw len;uint8_t bytes[2];} layout={{T_STR,0},2,{'t','t'}};
 fpr_builtin_set_layout(tuple,(V)&layout);
 if(fpr_prim_fn__x3d_x3d(tuple,tuple)!=(V)&fpr_false) oracle_finish(923);
 fpr_builtin_release(tuple);
 V values[]={dn,dz,dm,d,fn,fz,fm,f};
 for(unsigned i=0;i<8;i++)fpr_builtin_release(values[i]);
 if(fpr_builtin_live_allocations()!=live) oracle_finish(924);
}
''' + '\n'.join(prototypes) + '''
uintptr_t __wrap_fpr_fn_main(void){
 generic_scalars();
 uintptr_t cells[64];
 uw before=fpr_builtin_live_allocations();
 uw requests_before;
 static const uint64_t dedge[]={0,0x8000000000000000ULL,1,0x7ff0000000000000ULL,
   0xfff0000000000000ULL,0x7ff8000000000001ULL,0x7ff0000000000001ULL,UINT64_MAX};
 static const uint32_t sedge[]={0,0x80000000U,1,0x7f800000U,0xff800000U,0x7fc00001U,0x7f800001U,UINT32_MAX};
 for(unsigned iteration=0;iteration<128;iteration++){
  intptr_t n=iteration==0 ? -(INTPTR_MAX/2)-1 : iteration==1 ? INTPTR_MAX/2-17*63 : (intptr_t)iteration-10000;
  uintptr_t w=0xfedcba9876543210ULL ^ ((uintptr_t)iteration<<47);
  union D d={.bits=0x7ff0000000000000ULL ^ ((uint64_t)iteration*0x9e3779b97f4a7c15ULL)};
  union F s={.bits=0x7f800000U ^ ((uint32_t)iteration*0x9e3779b9U)};
  if(iteration<8){d.bits=dedge[iteration];s.bits=sedge[iteration]^(0x10101U*2);}
''' + '\n'.join(checks) + '''
 requests_before=boundary_requests;
 if(zeroWord()!=UINTPTR_MAX || boundary_requests!=requests_before+1) oracle_finish(909);
 if(fpr_builtin_live_allocations()!=before) oracle_finish(910);
 requests_before=boundary_requests;
 if(guarded(iteration+1,w)!=w || boundary_requests!=requests_before+2) oracle_finish(911);
 if(fpr_builtin_live_allocations()!=before) oracle_finish(912);
 /* Call the FP-RISC entry itself with tagged values. Keep one shared input
    reference to check consumption independently of the C conversion shim. */
 V shared=fpr_fn__x24arc_x2euniformBoxWord(w);
 V owned=fpr_builtin_retain(shared);
 V tagged=native_entry(fpr_fn__x24arc_x2euniformBoxF64(d.bits), TAG(n),
   fpr_fn__x24arc_x2euniformBoxF32(s.bits), (V)&fpr_true, owned, (V)&fpr_unit,
   fpr_fn__x24arc_x2euniformBoxAddr(shared), fpr_fn__x24arc_x2euniformBoxF64(d.bits));
 if(ISINT(tagged) || TID(tagged)!=T_BITS || ((bits_t*)tagged)->var!=2) oracle_finish(901);
 if(fpr_builtin_live_allocations()!=before+2) oracle_finish(902);
 if(fpr_fn__x24arc_x2euniformUnboxWord(shared)!=w) oracle_finish(903);
 if(fpr_fn__x24arc_x2euniformUnboxWord(tagged)!=w) oracle_finish(904);
 if(fpr_builtin_live_allocations()!=before) oracle_finish(905);
 requests_before=boundary_requests;
 if(raw_worker(d.bits,TAG(n),s.bits,(V)&fpr_true,w,(V)&fpr_unit,(V)&cells[6],d.bits)!=w) oracle_finish(907);
 if(boundary_requests!=requests_before) oracle_finish(908);
 }
 say("C_EXPORT_ADAPTER_PASS\\n"); return __real_fpr_fn_main();
}
''')
        asm = tmp / ('adapter-hard.s' if hard else 'adapter-soft.s')
        run([ROOT / 'fpr', *export_flags(hard), source, asm])
        emitted = asm.read_text()
        native_entry = re.search(r'^# export small4 -> (\S+)', emitted, re.M).group(1)
        raw_worker = re.search(r'^# fn \$uniform\.raw\.small4\S* .*?^    \.globl (\S+)', emitted, re.M | re.S).group(1)
        harness.write_text(harness.read_text().replace('NATIVE_ENTRY', native_entry).replace('RAW_WORKER', raw_worker))
        image = asm.with_suffix('.elf')
        units = Path(str(asm) + '.units')
        run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1',
             'PROG=tests/builtin_export_main.fpr', 'BUILD='+str(tmp/('hard-runtime' if hard else 'soft-runtime')),
             'IMAGE='+str(image), 'BUILTIN_EXTRA='+' '.join([str(asm), *units.read_text().splitlines(), str(harness)]),
             'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main -Wl,--wrap=fpr_builtin_alloc_adt',
             'ARCHFLAGS=-march=rv64imafdc_zicsr -mabi='+('lp64d' if hard else 'lp64')+' -mcmodel=medany',
             *(['FPRC_FLAGS=--float-abi=hard'] if hard else [])])
        output = run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic', '-bios', 'none', '-kernel', image])
        assert 'C_EXPORT_ADAPTER_PASS' in output, output
        print(f'C export adapters {"lp64d" if hard else "lp64"}: {128*len(selected)} independent C calls, all boundary types, IEEE bits, '
              + ('separate integer/FP banks' if hard else 'arguments through 64 and hart cells')
              + ', 128 nullary/tagged/shared/raw-worker probes, exact boundary allocations and no leaks PASS', flush=True)
        if not hard:
            check_boundary_failures(tmp, asm, units, run)


def check_boundary_failures(tmp, asm, units, run):
    emitted = asm.read_text()
    def worker(name):
        return re.search(r'^# fn \$uniform\.raw\.' + name + r'\S* .*?^    \.globl (\S+)', emitted, re.M | re.S).group(1)
    def image(label, symbol, args):
        harness = tmp / (label + '.c')
        harness.write_text('#include "builtin.h"\n'
                          'extern V target(' + ','.join('V' for _ in args) + ') __asm__("' + symbol + '");\n'
                          'extern V fpr_fn__x24arc_x2euniformBoxAddr(V);\n'
                          'extern V fpr_fn__x24arc_x2euniformBoxWord(V);\n'
                          'extern V __real_fpr_fn_main(void);\n'
                          'V __wrap_fpr_fn_main(void){target(' + ','.join(args) + ');return __real_fpr_fn_main();}\n')
        output = tmp / (label + '.elf')
        run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=1',
             'PROG=tests/builtin_export_main.fpr','BUILD='+str(tmp/label),'IMAGE='+str(output),
             'BUILTIN_EXTRA='+' '.join([str(asm),*units.read_text().splitlines(),str(harness)]),
             'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main'])
        return run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none','-kernel',output],expected=1)
    for name, public, private in [
        ('trapOverflow',['7','((V)1<<62)-1'],['7','TAG(((V)1<<62)-1)']),
        ('trapDivide',['7','0'],['7','TAG(0)']),
        ('trapBounds',['0x80001001UL'],['0x80001001UL'])]:
        wrapped = image(name+'-public',name,public)
        direct = image(name+'-private',worker(name),private)
        assert wrapped == direct and '7' in wrapped.splitlines(), (name,wrapped,direct)
    native = re.search(r'^# export trapOverflow -> (\S+)', emitted, re.M).group(1)
    rejected = image('wrong-uniform-kind',native,['fpr_fn__x24arc_x2euniformBoxAddr(7)','TAG(0)'])
    assert 'uniform scalar representation mismatch' in rejected and '7' not in rejected.splitlines(), rejected
    checked = re.search(r'^# export guarded -> (\S+)', emitted, re.M).group(1)
    # This must name a uniform wrapper for the generated checked entry, not
    # the raw source function or its raw precondition worker.
    assert '$uniform.raw.$precond0.guarded' in emitted
    rejected = image('guarded-public','guarded',['0','7'])
    direct = image('guarded-tagged',checked,['TAG(0)','fpr_fn__x24arc_x2euniformBoxWord(7)'])
    assert rejected == direct and 'precondition' in rejected.lower(), (rejected,direct)
    print('Tagged/public versus raw/private preserves printed prefixes and overflow/division/alignment failures; wrong scalar kind refuses before effects: PASS',flush=True)


if __name__ == '__main__':
    def run(command, expected=0):
        result = subprocess.run([str(x) for x in command], cwd=ROOT, capture_output=True, text=True, timeout=180)
        assert result.returncode == expected, (command, result.returncode, result.stdout, result.stderr)
        return result.stdout + result.stderr
    run(['make', 'fpr'])
    with tempfile.TemporaryDirectory(prefix='fpr-export-adapter-') as directory:
        check_adapter_probes(Path(directory), run)
