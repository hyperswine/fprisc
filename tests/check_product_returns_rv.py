#!/usr/bin/env python3
"""Execute private wide product returns against a C oracle in RV64 QEMU.

The harness links only the real emitted reader and worker. It supplies no
allocator, so an unexpected materialization is also a link-time failure.
The fuel shim overwrites all volatile argument and temporary registers.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import tempfile
from check_product_returns import ROOT, fixture, run
from fuel_wrapper import fuel_wrapper
from product_return_probe import return_bodies


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-execution', action='store_true')
    args = parser.parse_args()
    missing = [p for p in ('riscv64-unknown-elf-gcc', 'qemu-system-riscv64') if not shutil.which(p)]
    if missing:
        assert not args.require_execution, missing
        print('Product returns RV64 execution SKIP:', ', '.join(missing))
        return
    with tempfile.TemporaryDirectory(prefix='fpr-product-rv-') as directory:
        tmp = Path(directory)
        env = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'),
                   FPR_NO_INLINE='1', FPR_NO_CALL_REGIONS='1', FPR_NO_SCALAR_WORKERS='1', FPR_NO_FIELD_WORKERS='1',
                   FPR_NO_LOOP_REGIONS='1')

        def checked(argv):
            p = run(argv, env)
            assert p.returncode == 0, (argv, p.returncode, p.stdout[-3000:], p.stderr[-5000:])
            return p.stdout

        for width in range(1, 9):
            source = tmp/f'width{width}.fpr'; source.write_text(fixture(width))
            asm = tmp/f'width{width}.s'
            checked([ROOT/'fpr', 'compile', '--system=bare-metal', '--target=rv64', source, asm])
            whole = asm.read_text()
            body = return_bodies(whole, width)
            asm.write_text('.text\n'+body+fuel_wrapper(whole, body))
            exe = tmp/f'width{width}.elf'
            checked(['riscv64-unknown-elf-gcc', '-ffixed-x27', '-march=rv64im_zicsr_zifencei', '-mabi=lp64',
                     '-mcmodel=medany', '-msmall-data-limit=0', '-O2', '-ffreestanding', '-nostdlib',
                     '-fno-builtin', f'-DPRODUCT_WIDTH={width}', '-T', ROOT/'tests/typed_ir/kernel_link.ld',
                     ROOT/'tests/typed_ir/kernel_crt.S', asm, ROOT/'tests/typed_ir/product_return_oracle.c', '-o', exe])
            output = checked(['qemu-system-riscv64', '-machine', 'virt', '-smp', '1', '-m', '16M',
                              '-nographic', '-bios', 'none', '-kernel', exe])
            assert '2100 C-reference' in output and 'PASS' in output, output
            print(f'Product returns RV64: {width} fields, '+output.strip(), flush=True)


if __name__ == '__main__':
    main()
