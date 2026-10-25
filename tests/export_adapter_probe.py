"""Independent C callers for the existing RV64 soft/hard export ABIs.

Also supplies fixtures to the two-compiler exact-emission oracle. This helper
runs inside check_export.py, so it adds no separate Base build/job.
"""
from pathlib import Path
import subprocess
import tempfile

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
    return '\n'.join(text) + '\n'


def export_flags(hard):
    names = [name for name, _, _ in entries() if not hard or name.startswith('small')]
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
            checks += ['  if (' + condition + ') oracle_finish(' + str(len(checks) + 1) + ');']
        harness = tmp / ('adapter-hard.c' if hard else 'adapter-soft.c')
        harness.write_text('''#include <stdint.h>
#include "builtin.h"
extern uintptr_t __real_fpr_fn_main(void);
union D { uint64_t bits; double value; };
union F { uint32_t bits; float value; };
__attribute__((noreturn)) void oracle_finish(int code){*(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){}}
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
''' + '\n'.join(prototypes) + '''
uintptr_t __wrap_fpr_fn_main(void){
 uintptr_t cells[64];
 for(unsigned iteration=0;iteration<128;iteration++){
  intptr_t n=(intptr_t)iteration-10000;
  uintptr_t w=0xfedcba9876543210ULL ^ ((uintptr_t)iteration<<47);
  union D d={.bits=0x7ff0000000000000ULL ^ ((uint64_t)iteration*0x9e3779b97f4a7c15ULL)};
  union F s={.bits=0x7f800000U ^ ((uint32_t)iteration*0x9e3779b9U)};
''' + '\n'.join(checks) + '''
 }
 say("C_EXPORT_ADAPTER_PASS\\n"); return __real_fpr_fn_main();
}
''')
        asm = tmp / ('adapter-hard.s' if hard else 'adapter-soft.s')
        run([ROOT / 'fpr', *export_flags(hard), source, asm])
        image = asm.with_suffix('.elf')
        units = Path(str(asm) + '.units')
        run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1',
             'PROG=tests/builtin_export_main.fpr', 'BUILD='+str(tmp/('hard-runtime' if hard else 'soft-runtime')),
             'IMAGE='+str(image), 'BUILTIN_EXTRA='+' '.join([str(asm), *units.read_text().splitlines(), str(harness)]),
             'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main',
             'ARCHFLAGS=-march=rv64imafdc_zicsr -mabi='+('lp64d' if hard else 'lp64')+' -mcmodel=medany',
             *(['FPRC_FLAGS=--float-abi=hard'] if hard else [])])
        output = run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic', '-bios', 'none', '-kernel', image])
        assert 'C_EXPORT_ADAPTER_PASS' in output, output
        print(f'C export adapters {"lp64d" if hard else "lp64"}: {128*len(selected)} independent C calls, all boundary types, IEEE bits, '
              + ('separate integer/FP banks' if hard else 'arguments through 64 and hart cells') + ' PASS', flush=True)


if __name__ == '__main__':
    def run(command):
        result = subprocess.run([str(x) for x in command], cwd=ROOT, capture_output=True, text=True, timeout=180)
        assert result.returncode == 0, (command, result.returncode, result.stdout, result.stderr)
        return result.stdout + result.stderr
    run(['make', 'fpr'])
    with tempfile.TemporaryDirectory(prefix='fpr-export-adapter-') as directory:
        check_adapter_probes(Path(directory), run)
