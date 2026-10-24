#!/usr/bin/env python3
"""Real RV32/RV64 arguments, malformed replies, and collection during decoding."""
import os
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from run_tangnano20k_base import Device, encode_args
from check_tangnano20k_rv32_base import run_image


class BadArguments(Device):
    def __init__(self, root, status, payload):
        super().__init__(root)
        self.reply = status, payload

    def dispatch(self, op, data):
        return self.reply if op == 9 else super().dispatch(op, data)


def main():
    cases = [[], ['', 'two words', '-n', '雪', 'quote"slash\\'], ['x'] * 256,
             ['a' * 65528]]
    for args in cases:
        encoded = encode_args(args)
        assert Device(ROOT, args=args).dispatch(9, b'') == (0, encoded)
    for args in (['x'] * 257, ['a' * 65529], ['nul\0byte']):
        try:
            encode_args(args)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid arguments accepted')
    assert Device(ROOT).dispatch(9, b'bad')[0] == 1
    for xlen in (32, 64):
        out = ROOT / f'build/tangnano20k-args/rv{xlen}'
        out.mkdir(parents=True, exist_ok=True)
        env = {**os.environ, 'FPR_XLEN': str(xlen), 'FPR_RVC': '1',
               'FPR_QEMU': '1', 'FPR_CPU_MHZ': '48'}
        env.pop('FPR_PRESET', None)
        build = subprocess.run(['machine/tangnano20k/build.sh', 'tests/tangnano20k_args.fpr', str(out)],
                               cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
        (out / 'build.log').write_text(build.stdout + build.stderr)
        assert build.returncode == 0, build.stdout + build.stderr
        # The maximum count and frame exercise allocation on the region heap
        # (docs/2026-10-25-REGIONS-LOOPS-CALLS.md; the collector is gone).
        for i, args in enumerate(cases):
            output = run_image(out / 'base.elf', out, 120, device=Device(out, args=args), xlen=xlen)
            (out / f'case-{i}.log').write_text(output)
            expected = [f'ARG {len(arg.encode())}:{arg}' for arg in args]
            assert [line for line in output.splitlines() if line.startswith('ARG ')] == expected
            assert f'ARGS count={len(args)}\n' in output
        invalid = [(0, b'', 'truncated'), (0, struct.pack('<I', 257), 'too many'),
                   (0, struct.pack('<II', 1, 8) + b'x', 'truncated'),
                   (0, struct.pack('<I', 0) + b'x', 'trailing bytes'),
                   (0, struct.pack('<II', 1, 1) + b'\0', 'contains NUL'),
                   (0, b'x' * 65537, 'too large'), (1, b'virtual operation unavailable', 'unavailable')]
        for i, (status, payload, reason) in enumerate(invalid):
            output = run_image(out / 'base.elf', out, 120, device=BadArguments(out, status, payload),
                               expected_exit=1, xlen=xlen)
            (out / f'invalid-{i}.log').write_text(output)
            assert reason in output, output
        print(f'RV{xlen}: arguments, limits, malformed/unsupported replies on the region heap PASS', flush=True)


if __name__ == '__main__':
    main()
