#!/usr/bin/env python3
"""I32 native, RV32 Base, manual Builtin and ARC64 acceptance.

Run the native suite by default. Add --qemu for RV32IM/IMC Base, --builtin
for RV32 manual Builtin with a test-only 16550 UART adapter, and --arc64
for the integer-only ARC64 suite. No FPGA programming is performed.
The compiler and matching runtime must already have been rebuilt.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FAILURES = {
    'div-zero': ('I32.ofInt 9 / I32.ofInt 0', 'I32: division by zero'),
    'rem-zero': ('I32.rem (I32.ofInt 9) (I32.ofInt 0)', 'I32: division by zero'),
    'divU-zero': ('I32.divU (I32.ofInt -1) (I32.ofInt 0)', 'I32: division by zero'),
    'remU-zero': ('I32.remU (I32.ofInt -1) (I32.ofInt 0)', 'I32: division by zero'),
    'div-overflow': ('I32.shl (I32.ofInt 1) 31 / I32.ofInt -1', 'I32: division overflow'),
}
TYPE_FAILURES = {
    'mix-int': 'I32.ofInt 1 + 1',
    'mix-i64': 'I32.ofInt 1 + I64.ofInt 1',
    'mix-word': 'I32.ofInt 1 + Word.fromInt 1',
    'mix-f32': 'I32.ofInt 1 + 1f',
    'mixed-list': '[I32.ofInt 1, 1]',
    'power': 'I32.ofInt 2 ^ I32.ofInt 3',
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, *, env=None, timeout=180):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                          text=True, capture_output=True, timeout=timeout)


def checked(args, log, *, env=None, timeout=180):
    result = command(args, env=env, timeout=timeout)
    log.write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (args, log, result.stdout, result.stderr)
    return result


def lcg(steps):
    """Independent affine exponentiation modulo 2^32, avoiding a 10M loop."""
    modulus = (1 << 32) - 1
    multiplier, increment = 1664525, 1013904223
    a, b = 1, 0
    while steps:
        if steps & 1:
            a, b = (multiplier * a) & modulus, (multiplier * b + increment) & modulus
        multiplier, increment = (multiplier * multiplier) & modulus, (increment * (multiplier + 1)) & modulus
        steps >>= 1
    return b


class Suite:
    def __init__(self, out):
        self.out = out
        self.results = []
        out.mkdir(parents=True, exist_ok=True)

    def record(self, name, platform, image, output, code=0):
        self.results.append({'name': name, 'platform': platform,
                             'image': str(image.relative_to(ROOT)) if image.is_relative_to(ROOT) else str(image),
                             'sha256': sha(image), 'image_bytes': image.stat().st_size,
                             'returncode': code, 'output': output, 'passed': True})
        self.save(False)
        print(f'{platform} {name}: PASS', flush=True)

    def save(self, complete):
        (self.out / 'results.json').write_text(json.dumps({'complete': complete, 'cases': self.results,
          'sources': {str(path.relative_to(ROOT)): sha(path) for path in [
              ROOT / 'tests/i32.fpr', ROOT / 'tests/tangnano20k_i32_core.fpr',
              ROOT / 'tests/tangnano20k_i32_alloc.fpr', ROOT / 'tests/i32_builtin_arc.fpr']}}, indent=2) + '\n')

    def generated(self, name, expression):
        path = self.out / (name + '.fpr')
        path.write_text('profile base.\nmain : Unit .\nmain = print (I32.str (' + expression + ')).\n')
        return path

    def typing(self):
        for name, expression in TYPE_FAILURES.items():
            source = self.out / ('type-' + name + '.fpr')
            source.write_text('profile base.\nmain = print (str (' + expression + ')).\n')
            for target in ('a64', 'rv32'):
                result = command([ROOT / 'fprc', '--system=bare-metal', '--profile=base',
                                  '--target=' + target, '--check-only', source, self.out / 'bad.s'])
                output = result.stdout + result.stderr
                (self.out / f'type-{name}-{target}.log').write_text(output)
                assert result.returncode != 0 and 'I32' in output, (name, target, output)
            print(f'type {name}: refused on a64 and RV32', flush=True)
        wide = self.out / 'profile-wide.fpr'
        wide.write_text('profile builtin.\nmain = I32.toI64 (I32.ofInt 1).\n')
        sol = self.out / 'profile-sol.fpr'
        sol.write_text('profile sol.\nadd : I32 -> I32 -> I32.\nadd a b = a + b.\nmain = Unit.\n')
        for name, flags, source, reason in [
            ('arc-wide', ['--system=bare-metal', '--profile=builtin', '--target=rv64', '--arc'],
             wide, 'bridge ownership adapters'),
            ('builtin32-wide', ['--system=bare-metal', '--profile=builtin', '--target=rv32'],
             wide, 'I32 wide conversions require Base'),
            ('sol', [],
             sol, 'this profile has no I32 runtime'),
        ]:
            arguments = ([ROOT / 'fpr', 'sol', source] if name == 'sol' else
                         [ROOT / 'fprc', *flags, source, self.out / ('profile-' + name + '.s')])
            result = command(arguments)
            output = result.stdout + result.stderr
            (self.out / ('profile-' + name + '.log')).write_text(output)
            assert result.returncode != 0 and reason in output, (name, output)
            print(f'profile {name}: explicit refusal', flush=True)
        raw = self.out / 'profile-raw64.fpr'
        raw.write_text('profile builtin.\nbump x = I32.ofInt x + I32.ofInt 1.\nmain = bump 2 == I32.ofInt 3.\n')
        checked([ROOT / 'fprc', '--system=bare-metal', '--profile=builtin', '--target=rv64',
                 '--arc', '--raw', raw, self.out / 'profile-raw64.s'], self.out / 'profile-raw64.log')
        print('profile raw64: integer arithmetic compiles', flush=True)

    def native_build(self, source, name):
        image = self.out / ('native-' + name)
        checked([ROOT / 'fpr', 'build', source, '--harts', '1', '-o', image],
                self.out / ('native-' + name + '-build.log'))
        return image

    def native(self):
        environment = {**os.environ, 'FPR_HARTS': '1', 'FPR_HEAP_MB': '64'}
        for name, source, marker in [
            ('base', ROOT / 'tests/i32.fpr', 'I32 BASE HOLDS'),
            ('allocation', ROOT / 'tests/tangnano20k_i32_alloc.fpr',
             f'I32 ALLOC HOLDS steps=10000000 delta=0 hex={lcg(10000000):x}'),
        ]:
            image = self.native_build(source, name)
            result = checked([image], self.out / ('native-' + name + '.log'), env=environment, timeout=120)
            assert marker in result.stdout, result.stdout
            self.record(name, 'native64', image, result.stdout)
        for name, (expression, reason) in RUNTIME_FAILURES.items():
            image = self.native_build(self.generated(name, expression), name)
            result = command([image], env=environment, timeout=30)
            output = result.stdout + result.stderr
            (self.out / ('native-' + name + '.log')).write_text(output)
            assert result.returncode != 0 and reason in output, (name, result.returncode, output)
            self.record(name, 'native64 expected panic', image, output, result.returncode)

    def rv32_build(self, source, name, compressed=False):
        directory = self.out / (name + ('-imc' if compressed else '-im'))
        directory.mkdir(parents=True, exist_ok=True)
        environment = {**os.environ, 'FPR_XLEN': '32', 'FPR_RVC': str(int(compressed)), 'FPR_QEMU': '1'}
        checked(['machine/tangnano20k/build.sh', source, directory], directory / 'build.log', env=environment)
        return directory / 'base.elf'

    def qemu_run(self, image, name, reason=None, bits=32):
        # The production virt ARC64 linker places its stack in 128 MiB RAM;
        # the Tang Nano RV32 linker uses 8 MiB.
        memory = '128M' if bits == 64 else '8M'
        result = command([f'qemu-system-riscv{bits}', '-machine', 'virt', '-m', memory, '-bios', 'none',
                          '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-kernel', image], timeout=60)
        output = result.stdout + result.stderr
        (image.parent / (name + '-qemu.log')).write_text(output)
        if reason:
            assert result.returncode != 0 and reason in output, (name, result.returncode, output)
        else:
            assert result.returncode == 0, (name, result.returncode, output)
        return result.returncode, output

    def qemu(self):
        for compressed in (False, True):
            image = self.rv32_build(ROOT / 'tests/tangnano20k_i32.fpr', 'base', compressed)
            code, output = self.qemu_run(image, 'base')
            assert 'TANG NANO I32 HOLDS' in output and 'FPR EXIT 0' in output, output
            self.record('base', 'QEMU RV32IMC' if compressed else 'QEMU RV32IM', image, output, code)
        for name, (expression, reason) in RUNTIME_FAILURES.items():
            image = self.rv32_build(self.generated(name, expression), name)
            code, output = self.qemu_run(image, name, reason)
            assert 'FPR EXIT 1' in output, output
            self.record(name, 'QEMU RV32IM expected panic', image, output, code)

    def builtin(self):
        directory = self.out / 'builtin-im'
        directory.mkdir(parents=True, exist_ok=True)
        assembly = directory / 'builtin.s'
        checked([ROOT / 'fprc', '--system=bare-metal', '--profile=builtin', '--target=rv32',
                 ROOT / 'tests/tangnano20k_i32_builtin.fpr', assembly], directory / 'compile.log')
        # Match the production board host exactly except for its UART register
        # adapter. This file is a test artifact, never a source/FPGA modification.
        board_source = (ROOT / 'machine/builtin/tangnano20k/board.c').read_text()
        old = '''  volatile uint32_t *uart = (volatile uint32_t *)0x10000000;
  while (!(uart[1] & 1)) {}
  uart[0] = (uint8_t)c;'''
        new = '''  volatile uint8_t *uart = (volatile uint8_t *)0x10000000;
  while (!(uart[5] & 0x20)) {}
  uart[0] = (uint8_t)c;'''
        assert board_source.count(old) == 1, 'production UART adapter changed; review test adapter'
        board = directory / 'board-qemu.c'
        board.write_text(board_source.replace(old, new))
        image = directory / 'builtin.elf'
        sources = [ROOT / name for name in [
            'machine/builtin/tangnano20k/crt0.S', 'machine/builtin/tangnano20k/machine.c',
            'machine/builtin/heap.c', 'machine/builtin/unsafe.c', 'runtime/runtime.c',
            'runtime/i32.c', 'runtime/bits.c', 'machine/virt/memshim.c']]
        units = [Path(line) for line in assembly.with_suffix('.s.units').read_text().splitlines() if line]
        checked(['riscv64-unknown-elf-gcc', '-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-mcmodel=medany',
                 '-Os', '-ffreestanding', '-nostdlib', '-nostartfiles', '-fno-builtin',
                 '-DFPR_NHARTS=1', '-DFPR_BUILTIN', '-DFPR_SIMPLE_RISC',
                 '-DFPR_BUILTIN_HEAP_MAX_BYTES=8388608', '-ffunction-sections', '-fdata-sections',
                 '-Wl,--gc-sections', '-Wl,--no-warn-rwx-segments', '-I', ROOT / 'runtime',
                 '-I', ROOT / 'machine/builtin', '-T', ROOT / 'machine/builtin/tangnano20k/link-sdram.ld',
                 *sources, board, assembly, *units, '-lgcc', '-o', image], directory / 'build.log')
        checked(['python3', 'tools/check_tangnano20k_isa.py', image, '--xlen', '32'], directory / 'isa.log')
        code, output = self.qemu_run(image, 'builtin')
        assert 'BUILTIN I32 HOLDS' in output and 'FPR EXIT 0' in output, output
        self.record('integer core', 'QEMU RV32IM manual Builtin (16550 adapter)', image, output, code)

    def arc64(self):
        directory = self.out / 'builtin-arc64'
        directory.mkdir(parents=True, exist_ok=True)
        native = directory / 'arc-adapters-native'
        strip = '-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'
        checked(['cc', '-std=c11', '-O1', '-g', '-DFPR_POSIX', '-DFPR_BUILTIN_ARC', '-DFPR_BUILTIN_RAW',
                 '-I', ROOT / 'runtime', '-I', ROOT / 'machine/builtin', '-fsanitize=address,undefined',
                 '-ffunction-sections', '-fdata-sections', strip, ROOT / 'tests/base/i32arc_runtime.c',
                 ROOT / 'runtime/i32.c', ROOT / 'machine/builtin/heap.c', ROOT / 'machine/builtin/arc.c',
                 '-o', native], directory / 'adapters-build.log')
        result = checked([native], directory / 'adapters-native.log')
        self.record('consuming adapters, ASan/UBSan', 'native64 ARC C', native, result.stdout)
        image = directory / 'builtin.elf'
        checked(['make', '-s', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'HEAP=c',
                 'PROG=tests/i32_builtin_arc.fpr', 'BUILD=' + str(directory), 'IMAGE=' + str(image)],
                directory / 'build.log', timeout=300)
        code, output = self.qemu_run(image, 'arc64', bits=64)
        assert 'I32 ARC HOLDS' in output, output
        self.record('integer core, zero live allocations', 'QEMU RV64 ARC Builtin', image, output, code)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--qemu', action='store_true')
    parser.add_argument('--builtin', action='store_true')
    parser.add_argument('--arc64', action='store_true')
    parser.add_argument('--typing-only', action='store_true')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/i32')
    args = parser.parse_args()
    suite = Suite(args.out.resolve())
    suite.typing()
    if args.typing_only:
        return
    if args.native or not (args.qemu or args.builtin or args.arc64):
        suite.native()
    if args.qemu:
        suite.qemu()
    if args.builtin:
        suite.builtin()
    if args.arc64:
        suite.arc64()
    suite.save(True)


if __name__ == '__main__':
    main()
