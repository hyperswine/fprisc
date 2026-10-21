#!/usr/bin/env python3
"""Exercise the RV32 Base ABI and UART host in QEMU (no FPGA programming).

Uses production startup/runtime with only a 16550 UART register adapter.
The FPGA loader/cache/SDRAM and clock timing require separate board checks.
"""
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from run_tangnano20k_base import Device, PREFIX, frame, parse


def run_image(image, files, timeout=30, *, device=None, expected_exit=0, xlen=32):
    process = subprocess.Popen([
        f'qemu-system-riscv{xlen}', '-machine', 'virt', '-m', '8M', '-bios', 'none',
        '-kernel', str(image), '-display', 'none', '-monitor', 'none',
        '-serial', 'stdio'], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    if device is None:
        device = Device(files, {'TEST_UART': 'connected'}, ['hello RV32'])
    pending, output, sequence = b'', bytearray(), 0
    try:
        while time.monotonic() < deadline:
            if not select.select([process.stdout], [], [], .1)[0]:
                continue
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            pending += chunk
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                line += b'\n'
                if not line.startswith(PREFIX):
                    output.extend(line)
                    continue
                seq, op, payload = parse(line)
                assert seq == sequence + 1, (seq, sequence)
                sequence = seq
                status, reply = device.dispatch(op, payload)
                for byte in frame(seq, status, reply):
                    process.stdin.write(bytes([byte]))
                    process.stdin.flush()
                    if not select.select([process.stdout], [], [], 5)[0]:
                        raise TimeoutError('QEMU virtual-device ACK')
                    ack = os.read(process.stdout.fileno(), 1)
                    assert ack == b'+', ack
        else:
            raise TimeoutError(f'QEMU execution: {bytes(output)!r} {pending!r}')
        output.extend(pending)
        code = process.wait(timeout=5)
        stderr = process.stderr.read().decode()
        text = output.decode()
        assert code == expected_exit and f'FPR EXIT {int(expected_exit != 0)}\n' in text, (code, text, stderr)
        return text
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)


def main():
    results = []
    for compressed in (False, True):
        for name, source, expected in [
            ('numeric', 'tests/tangnano20k_rv32_numeric.fpr', 'RV32 BASE NUMERIC HOLDS'),
            ('int', 'tests/tangnano20k_rv32_int.fpr', 'RV32 INT HOLDS max=1073741823 min=-1073741824'),
            ('word', 'tests/tangnano20k_rv32_word.fpr', 'RV32 WORD32 HOLDS'),
            ('host', 'tests/tangnano20k_rv32_host.fpr', 'RV32 BASE HOST HOLDS'),
            ('records', 'tests/base/vecshape.fpr', 'vecshape: two=1149000 four=2498000 in place=True'),
        ]:
            out = ROOT / 'build' / 'tangnano20k-rv32-base' / f'{name}-im{"c" if compressed else ""}'
            out.mkdir(parents=True, exist_ok=True)
            env = {**os.environ, 'FPR_XLEN': '32', 'FPR_RVC': str(int(compressed)), 'FPR_QEMU': '1'}
            build = subprocess.run(['machine/tangnano20k/build.sh', source, str(out)],
                                   cwd=ROOT, env=env, text=True, capture_output=True, timeout=180)
            (out / 'build.log').write_text(build.stdout + build.stderr)
            assert build.returncode == 0, (out, build.stdout, build.stderr)
            output = run_image(out / 'base.elf', out)
            (out / 'qemu.log').write_text(output)
            assert expected in output, output
            results.append({'case': name, 'isa': 'RV32IMC' if compressed else 'RV32IM',
                            'sha256': hashlib.sha256((out / 'base.bin').read_bytes()).hexdigest(),
                            'image_bytes': (out / 'base.bin').stat().st_size,
                            'output': output, 'passed': True})
            print(f'{name} RV32IM{"C" if compressed else ""}: PASS', flush=True)
    (ROOT / 'build/tangnano20k-rv32-base/results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
