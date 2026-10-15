#!/usr/bin/env python3
"""Run the local Base clock, software float and receive refusal on RV64 RTL.

Uses HaskPlayground's existing CPU/cache testbench and word-memory model.
No board programming or UART virtual-device connection is performed.
"""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HARDWARE = Path(os.environ.get('HASKPLAYGROUND', ROOT.parent / 'HaskPlayground'))
CPU = HARDWARE / 'boards/tangnano20k/rv64'


def run(args, env=None, timeout=180):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=env,
                       text=True, capture_output=True, timeout=timeout)
    assert p.returncode == 0, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout


for compressed in (False, True):
    out = ROOT / 'build' / ('tangnano20k-clock-c' if compressed else 'tangnano20k-clock-im')
    print(run(['machine/tangnano20k/build.sh', 'tests/tangnano20k_clock.fpr', out],
              {**os.environ, 'FPR_RVC': str(int(compressed))}).splitlines()[-1], flush=True)
    image = (out / 'base.bin').read_bytes()
    image += b'\0' * (-len(image) % 4)
    (out / 'image.hex').write_text(''.join(f'{int.from_bytes(image[i:i+4], "little"):08x}\n'
                                        for i in range(0, len(image), 4)))
    run(['iverilog', '-g2012', '-s', 'rv64_tb', '-P', f'rv64_tb.RVC={int(compressed)}',
         '-o', out / 'clock.sim', CPU / 'core.v', CPU / 'compressed.v',
         CPU.parent / 'sdram/cache.v', CPU / 'testbench.v'])
    output = run(['vvp', out / 'clock.sim', f'+IMAGE={out}/image.hex'])
    expected = 'RV64 CLOCK HOLDS\nRV64 SOFTFLOAT HOLDS\nBase: receiveFromNow unavailable\nFPR EXIT 0\nDONE'
    assert expected in output, output
    assert 'TRAP cause=0000000000000000' in output, output
    print(f'RV64{"IMC" if compressed else "IM"}: local 10MHz clock, software float, selective receive Err and successful exit: PASS', flush=True)
