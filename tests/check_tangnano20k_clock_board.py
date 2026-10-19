#!/usr/bin/env python3
"""Check a programmed RV32IMC split-clock FPGA using prepared FP-RISC guests.

The FPGA must already contain the supplied bitstream. This runner uploads
programs over UART; it never programs FPGA flash or formats the card. The SD
fixture creates CLKTEST.BIN in the existing FAT test partition if absent.
The independent SD audit requires the retained prior card evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
HASK = ROOT.parent / 'HaskPlayground'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--freq-mhz', type=int, choices=(72, 108), required=True)
    parser.add_argument('--bitstream', type=Path, required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepared, output = args.prepared.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    files = output / 'host-files'
    files.mkdir(exist_ok=True)
    report = {'cpu_mhz': args.freq_mhz, 'sdram_mhz': 54,
              'bitstream_sha256': sha(args.bitstream.resolve()),
              'complete': False, 'passed': False, 'cases': []}
    for name in ('numeric', 'i32', 'host', 'sd', 'sd-audit'):
        image = prepared / name / 'base.bin'
        report.setdefault('guest_images', {})[name] = {
            'bytes': image.stat().st_size, 'sha256': sha(image)}
    freq = str(args.freq_mhz)
    spi_divider = str(args.freq_mhz // 6 - 1)

    def save():
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')

    def run(name, command, marker=None, timeout=240):
        print(f'START {name}', flush=True)
        started = time.monotonic()
        try:
            result = subprocess.run(list(map(str, command)), cwd=ROOT,
                                    capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            partial = error.stdout or b''
            if isinstance(partial, bytes):
                partial = partial.decode(errors='replace')
            log = output / f'{name}.log'
            log.write_text(partial + '\nTimed out\n')
            report['cases'].append({'name': name, 'passed': False,
                                    'seconds': time.monotonic() - started,
                                    'error': 'timeout', 'log_sha256': sha(log)})
            save()
            raise
        text = result.stdout + result.stderr
        log = output / f'{name}.log'
        log.write_text(text)
        passed = result.returncode == 0 and (marker is None or marker in text)
        report['cases'].append({'name': name, 'passed': passed,
                                'seconds': time.monotonic() - started,
                                'command': list(map(str, command)),
                                'exit_code': result.returncode,
                                'log_sha256': sha(log)})
        save()
        if not passed:
            raise RuntimeError(f'{name} failed; see {log}')
        print(f'PASS {name}', flush=True)
        return text

    def guest(name, image, *extra, marker=None):
        return run(name, ['python3', ROOT/'tools/run_tangnano20k_base.py',
                         prepared/image/'base.bin', '--freq-mhz', freq,
                         '--root', files, '--timeout', '180', *extra], marker)

    save()
    try:
        run('uart', ['python3', ROOT/'tools/run_tangnano20k_base.py',
                     '--probe', '--freq-mhz', freq], 'PASS: board UART diagnostic')
        run('rv32c', ['python3', HASK/'boards/tangnano20k/sdram/check_compressed_board.py',
                      '--freq-mhz', freq], 'RV32C BOARD HOLDS')
        run('ram', ['python3', HASK/'boards/tangnano20k/sdram/check_core.py',
                    '--freq-mhz', freq], 'PASS: high-address execution')
        guest('numeric', 'numeric', marker='RV32 BASE NUMERIC HOLDS')
        guest('i32', 'i32', marker='TANG NANO I32 HOLDS')
        guest('host', 'host', '--env', 'TEST_UART=connected', '--input', 'hello RV32',
              marker='RV32 BASE HOST HOLDS')
        if (files/'output.txt').read_bytes() != b'RV32 UART + append':
            raise RuntimeError('host file differs from independent expected bytes')
        for repeat in (1, 2):
            run(f'dtree-{repeat}', ['python3', ROOT/'tests/check_tangnano20k_dtree.py',
                '--hardware', '--xlen', '32', '--freq-mhz', freq, '--train', '128',
                '--test', '64', '--bins', '8', '--depth', '5', '--min-leaf', '2',
                '--timeout', '180', '--output', output/f'dtree-{repeat}',
                '--bitstream', args.bitstream.resolve()],
                'PASS: decision-tree shape, all prediction digests')
        for repeat in (1, 2):
            text = guest(f'sd-{repeat}', 'sd', '--env', f'SD_DIVIDER={spi_divider}',
                         marker='CLOCK SD FILE HOLDS 512 BYTES 9 READS')
            report['cases'][-1]['created_file'] = 'CLOCK SD NEW FILE STORED' in text
        guest('sd-audit', 'sd-audit', '--env', f'SD_DIVIDER={spi_divider}',
              marker='FP SD CLOCK INDEPENDENT SECTOR AUDIT HOLDS')
        run('sd-independent', ['python3', ROOT/'tests/check_tangnano20k_sd_clock_audit.py',
                              '--log', output/'sd-audit.log',
                              '--out', output/'sd-sectors'],
            'PASS: both binary files, independent FAT/root decoding')
        report.update(complete=True, passed=True)
        print('PASS: split-clock FPGA acceptance', flush=True)
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
