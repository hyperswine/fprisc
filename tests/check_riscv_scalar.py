#!/usr/bin/env python3
"""Execute width-correct scalar code and private indexed memory on RV32/RV64 QEMU.

Uses a small test-only virt machine adapter; no FPGA is reconfigured. The two
differential flags also test warm unit-cache separation. Metrics count generated
assembly instructions and linked text bytes, not FPGA cycle throughput.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT)}
ENV.pop('FPR_FOREIGN', None)
ENV.setdefault('FPR_TYPED_IR_BACKEND','mixed')


def run(args, env=ENV, expected=0, timeout=180):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout.replace('\r\n', '\n')


def setup(out, bits):
    word = 'sw' if bits == 32 else 'sd'
    stride = bits // 8
    (out / 'crt.S').write_text(f'''
.section .text.entry,"ax",@progbits
.globl _start
_start:
 .option push
 .option norelax
 la gp,__global_pointer$
 .option pop
 la sp,_stack_top
 la t0,trap
 csrw mtvec,t0
 la t0,_bss_start
 la t1,_bss_end
1: bgeu t0,t1,2f
 {word} zero,0(t0)
 addi t0,t0,{stride}
 j 1b
2: call fpr_builtin_main
trap:
 la sp,_stack_top
 call unexpected_trap
 j trap
''')
    (out / 'link.ld').write_text('''
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
 .data : { *(.data .data.*) PROVIDE(__global_pointer$ = . + 0x800); *(.sdata .sdata.*) } > RAM
 .bss (NOLOAD) : { . = ALIGN(16); _bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(16); _bss_end = .; } > RAM
 _heap_start = .; _stack_top = ORIGIN(RAM) + LENGTH(RAM); _heap_end = _stack_top - 64K;
}
''')
    (out / 'host.c').write_text('''
#include "builtin.h"
extern char _heap_start[],_heap_end[];
extern V fpr_fn_main(void);
extern V fpr_fn_hot(V,V,V,V,V) __attribute__((weak));
void hal_putc(char c) { volatile uint8_t *u=(void *)0x10000000; while(!(u[5]&32)){} u[0]=(uint8_t)c; }
__attribute__((noreturn)) void hal_poweroff(int code) { *(volatile uint32_t *)0x100000=code?0x13333:0x5555;for(;;){} }
void fpr_cpanic_n(const char *s,uw n) { for(uw i=0;i<n;i++)hal_putc(s[i]);hal_putc('\n');hal_poweroff(1); }
void fpr_cpanic(const char *s) { uw n=0;while(s[n])n++;fpr_cpanic_n(s,n); }
void unexpected_trap(void) { fpr_cpanic("UNEXPECTED ISA TRAP"); }
void fpr_builtin_main(void) {
 fpr_set_tp(&fpr_harts[0]);fpr_builtin_heap_init(_heap_start,_heap_end);
 if(fpr_fn_hot) for(sw a=-7;a<=7;a++) for(sw b=-9;b<=9;b++) {
  sw c=13,d=-3,e=6;
  sw expected=2*(a*b+c*d+e*a+b*c+d*e+a*c+b*d+c*e+d*a+e*b);
  if(fpr_fn_hot(TAG(a),TAG(b),TAG(c),TAG(d),TAG(e))!=TAG(expected))fpr_cpanic("independent arithmetic reference failed");
 }
 (void)fpr_fn_main();hal_poweroff(0);
}
'''.replace("hal_putc('\n')", "hal_putc('\\n')"))


def compile_image(out, bits, source, env, compressed=False):
    asm = out / 'program.s'
    run(['./fprc', '--system=bare-metal', '--profile=builtin', f'--target=rv{bits}', source, asm], env)
    units = asm.with_suffix('.s.units').read_text().splitlines()
    image = out / 'program.elf'
    # An explicit bridge keeps IM-only coverage available on toolchains
    # whose RV64 libgcc multilibs require F/D, A or C instructions.
    softfloat=[]
    if bits==64 and env.get('FPR_SOFTFLOAT_ROOT'):
        sfroot=Path(env['FPR_SOFTFLOAT_ROOT'])
        library=sfroot/'build/Linux-RISCV64-GCC/softfloat.a'
        assert library.exists(),'build the RV64 SoftFloat archive before running this gate'
        softfloat=['-I'+str(sfroot/'source/include'),'machine/tangnano20k/softfloat.c',str(library)]
    run(['riscv64-unknown-elf-gcc', f'-march=rv{bits}im' + ('c' if compressed else '') + '_zicsr_zifencei',
         '-mabi=ilp32' if bits == 32 else '-mabi=lp64', '-mcmodel=medany', '-Os',
         '-ffreestanding', '-nostdlib', '-nostartfiles', '-fno-builtin',
         '-DFPR_NHARTS=1', '-DFPR_BUILTIN', '-DFPR_SIMPLE_RISC',
         '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
         '-Wl,--no-warn-rwx-segments', '-I', 'runtime', '-I', 'machine/builtin',
         '-T', out / 'link.ld', out / 'crt.S', out / 'host.c',
         'machine/builtin/heap.c', 'machine/builtin/unsafe.c',
         'machine/builtin/tangnano20k/machine.c', 'runtime/runtime.c',
         # -nostdlib also suppresses libgcc. The runtime's scalar equality
         # and formatting paths need its width/ABI-matched soft-float helpers.
         'runtime/bits.c', 'machine/virt/memshim.c', asm, *units, *softfloat, *([] if softfloat else ['-lgcc']), '-o', image], env)
    text = asm.read_text()
    if env.get('FPR_TYPED_IR_BACKEND','mixed') not in ('legacy','off','0'):
        headers=re.findall(r'^# fn ([^\n]+)',text,re.M)
        assert headers and all('typed-ir rv'+str(bits) in h for h in headers),'builtin fallback escaped native coverage'
    if bits == 32:
        assert not re.search(r'^\s+(?:ld|sd|lwu|f(?:add|mul|sub|div|mv|ld|sd|eq|lt|le|sqrt)[a-z.]*)\s', text, re.M), 'RV64/FPU instruction in RV32 output'
        for count in re.findall(r'^\s+s[rl][al]i\s+\w+,\s*\w+,\s*(\d+)', text, re.M):
            assert int(count) < 32, ('illegal RV32 shift', count)
    size = run(['riscv64-unknown-elf-size', image]).splitlines()[1].split()
    report = run(['riscv64-unknown-elf-readelf', '-Ah', image])
    assert f'ELF{bits}' in report and 'little endian' in report
    assert re.search(r'Flags:\s+0x' + ('1' if compressed else '0') + r'\b', report), 'unexpected ABI or compression flag'
    arch = re.search(r'Tag_RISCV_arch:\s+"([^"]+)"', report)
    assert arch
    allowed = (f'rv{bits}i', 'm', 'zicsr', 'zifencei', 'zmmul') + (('c', 'zca') if compressed else ())
    assert all(any(re.fullmatch(name + r'\d+p\d+', part) for name in allowed)
               for part in arch[1].split('_')), ('unexpected ISA/library requirement', arch[1])
    return image, {'instructions': len(re.findall(r'^    [a-z][a-z0-9.]*\s', text, re.M)),
                   'text_bytes': int(size[0]),
                   'indexed_calls': len(re.findall(r'\b(?:call|j|tail) fpr_prim_fn__x24mem_x2e', text)),
                   'addr_add_calls': len(re.findall(r'\b(?:call|j|tail) fpr_g_Addr_x2eadd_call2', text)),
                   'unit_cache': [Path(u).name for u in units]}


def execute(bits, image, expected=0):
    return run([f'qemu-system-riscv{bits}', '-machine', 'virt', '-smp', '1', '-m', '16M',
                '-nographic', '-bios', 'none', '-kernel', image], expected=expected, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bits', type=int, nargs='+', choices=(32, 64), default=[32, 64],
                        help='Run selected word sizes; default checks both')
    widths = parser.parse_args().bits
    for tool in ('riscv64-unknown-elf-gcc', *(f'qemu-system-riscv{b}' for b in widths)):
        assert shutil.which(tool), f'{tool} is required for this execution gate'
    metrics = {}
    with tempfile.TemporaryDirectory(prefix='fpr-riscv-scalar-') as tmp:
        root = Path(tmp)
        for bits in widths:
            out = root / str(bits); out.mkdir(); setup(out, bits)
            outputs = []; caches = []
            for slow, indexed in ((False, True), (True, False), (False, False), (False, True)):
                env = {**ENV, 'FPR_NO_RV32_FAST': str(int(slow)), 'FPR_NO_INDEXED_MEMORY': str(int(not indexed))}
                image, info = compile_image(out, bits, 'tests/builtin_scalar_fast.fpr', env)
                outputs.append(execute(bits, image))
                caches.append(info['unit_cache'])
                assert outputs[-1] == 'CAF ONCE\nCAF ONCE\nSCALAR FAST HOLDS\n', outputs[-1]
                if indexed:
                    assert info['indexed_calls'] > 0, ('fusion did not run', bits)
                    asm = (out / 'program.s').read_text()
                    for function in ('escaped', 'writeEffect'):
                        body = re.search(rf'(?ms)^fpr_fn_{function}:\n(.*?)(?=^# (?:wcet|native-insns-v1):)', asm)
                        assert body and 'fpr_g_Addr_x2eadd_call2' in body[1], ('unsafe fusion', bits, function)
                metrics[f'rv{bits}-slow{int(slow)}-indexed{int(indexed)}'] = info
            assert len(set(outputs)) == 1, (bits, outputs)
            assert caches[0] and caches[0] == caches[3] and caches[0] != caches[1] and caches[0] != caches[2], ('unit-cache mode separation', bits, caches)
            image, info = compile_image(out, bits, 'tests/builtin_scalar_fast.fpr', ENV, compressed=True)
            assert execute(bits, image) == outputs[0]
            disassembly = run(['riscv64-unknown-elf-objdump', '-d', image])
            assert re.search(r'^\s*[0-9a-f]+:\s+[0-9a-f]{4}\s', disassembly, re.M), 'compressed image contains no 16-bit instructions'
            metrics[f'rv{bits}-compressed'] = info
            # Both expression and jumping-condition dispatch must resolve the
            # primitive identity, not merely recognize its source name. Keep
            # inlining disabled in one leg so the call dispatch is exercised.
            shadow_expected = ('7\n7\nUSER ADD\n55\nUSER LT\nVALUE FALSE\n'
                               'USER LT\nCONDITION FALSE\n11\n')
            for no_inline in (False, True):
                for slow in (False, True):
                    env = {**ENV, 'FPR_NO_INLINE': str(int(no_inline)),
                           'FPR_NO_RV32_FAST': str(int(slow)), 'FPR_NO_INDEXED_MEMORY': '0'}
                    image, _ = compile_image(out, bits, 'tests/builtin_scalar_shadow.fpr', env)
                    assert execute(bits, image) == shadow_expected, (bits, no_inline, slow)
                    if no_inline:
                        asm = (out / 'program.s').read_text()
                        for symbol in ('charAt', '_x2b', '_x3c'):
                            assert re.search(r'\b(?:call|j|tail) fpr_fn_' + symbol + r'\b', asm), ('shadowed call vanished', bits, symbol)
            for name, expr, message in (
                ('add', 'intMax Unit + 1', 'Int overflow'),
                ('sub', 'intMin Unit - 1', 'Int overflow'),
                ('mul', '(intMax Unit) * 2', 'Int overflow'),
                ('div', '(intMin Unit) / -1', 'Int overflow'),
                ('zero', '17 / 0', 'division by zero'),
                ('char', 'charAt "abc" -1', 'charAt'),
                ('shift-width', 'BITSHIFTL 1 (Word.bits Unit)', f'shift must be 0..{bits-1}'),
                ('bit-width', 'BITTEST 1 (Word.bits Unit)', f'bit index must be 0..{bits-1}'),
                ('mask-offset', 'BITMASK 1 (Word.bits Unit)', 'bad width/offset'),
                ('align', 'p = Mem.alloc 16; a = Addr.add p 1; v = Mem.read16 a; _ = Rc.release a; v', 'unaligned access'),
            ):
                source = out / f'{name}.fpr';source.write_text(f'profile builtin.\nmain = {expr}.\n')
                for slow in (False, True):
                    env = {**ENV, 'FPR_NO_RV32_FAST': str(int(slow)), 'FPR_NO_INDEXED_MEMORY': str(int(slow))}
                    image, _ = compile_image(out, bits, source, env)
                    assert message in execute(bits, image, 1), (bits, name, slow)
            for bench in ('sieve', 'sort', 'matrix', 'compute'):
                for slow in (False, True):
                    env = {**ENV, 'FPR_NO_RV32_FAST': str(int(slow)), 'FPR_NO_INDEXED_MEMORY': str(int(slow))}
                    _, info = compile_image(out, bits, f'tests/tangnano20k_stress/{bench}.fpr', env)
                    metrics[f'rv{bits}-{bench}-slow{int(slow)}'] = info
        print(json.dumps(metrics, indent=2))
    print('/'.join(f'RV{b}' for b in widths) +
          ' scalar semantics, primitive shadowing, overflow/refusals, cache isolation and indexed memory: PASS')


if __name__ == '__main__':
    main()
