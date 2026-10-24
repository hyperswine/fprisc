#!/usr/bin/env python3
"""Build and run fprisc-48 programs or verify the example suite in QEMU/on FPGA.

The board target programs FPGA SRAM from a checked preset build manifest.
It does not write FPGA flash or the SD card. QEMU verifies software only.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from check_tangnano20k_rv32_base import run_image
from run_tangnano20k_base import Device
from tangnano_artifact import sha, repository

CASES = ('hello', 'numeric', 'collections', 'host', 'args', 'wc', 'classifier')
SOURCES = {'hello': 'examples/tangnano20k_hello.fpr',
           'numeric': 'tests/tangnano20k_rv32_numeric.fpr',
           'collections': 'tests/base/vecshape.fpr',
           'host': 'tests/tangnano20k_rv32_host.fpr',
           'args': 'tests/tangnano20k_args.fpr', 'wc': 'examples/wc.fpr'}
EXPECTED = {'hello': 'SimpleRisc: factorial(6)=720',
            'numeric': 'RV32 BASE NUMERIC HOLDS',
            'collections': 'vecshape: two=1149000 four=2498000 in place=True',
            'host': 'RV32 BASE HOST HOLDS'}
ARGUMENTS = ['', 'two words', '-n', '雪', 'quote"slash\\']
FPGA_CONFIG = dict(xlen=32, compressed=True, cpu_mhz=48, memory_mhz=48,
                   ram_bytes=8388608, cache_bytes=65536, phase_degrees=135,
                   placement=2, write_update=True)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(command, log, env, timeout=180):
    try:
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b''
        log.write_bytes(output.encode() if isinstance(output, str) else output)
        raise
    log.write_text(result.stdout)
    require(result.returncode == 0, f'command failed ({result.returncode}); see {log}\n{result.stdout[-2000:]}')
    return result.stdout


def fpga_image(path):
    report = json.loads(path.read_text())
    require(report.get('preset') == 'fprisc-48' and report.get('ready') is True,
            'FPGA manifest must be a completed fprisc-48 build')
    require(report.get('configuration') == FPGA_CONFIG, 'FPGA preset configuration mismatch')
    artifacts = report.get('artifacts', {})
    require(all(name in artifacts for name in ('impl/pnr/sdram_test.fs', 'impl/pnr/sdram_test.tr')),
            'FPGA manifest lacks bitstream or checked timing report')
    for name, digest in artifacts.items():
        artifact = (path.parent / name).resolve()
        require(artifact.is_relative_to(path.parent.resolve()), 'FPGA artifact escapes build directory')
        require(sha(artifact) == digest, f'FPGA artifact hash mismatch: {name}')
    return path.parent / 'impl/pnr/sdram_test.fs', report


def validate_case(name, output, files):
    lines = output.splitlines()
    require(lines.count('FPR EXIT 0') == 1 and 'FPR EXIT 1' not in lines,
            f'{name}: expected exactly one successful runtime exit')
    if name in EXPECTED:
        require(lines.count(EXPECTED[name]) == 1, f'{name}: missing or duplicated expected output')
    if name == 'host':
        require((files / 'output.txt').read_bytes() == b'RV32 UART + append', 'host file content mismatch')
    if name == 'args':
        require([line for line in lines if line.startswith('ARG ')] ==
                [f'ARG {len(arg.encode())}:{arg}' for arg in ARGUMENTS], 'argument content/order mismatch')
        require(lines.count('ARGS count=5') == 1, 'argument count mismatch')
    if name == 'wc':
        expected = [f'{2:8}{3:8}{17:9} words.txt', f'{1:8}{2:8}{11:9} two words.txt']
        actual = [line for line in lines if line.endswith((' words.txt', ' two words.txt'))]
        require(actual == expected, f'wc result mismatch: {actual!r}')


def execute_guest(directory, files, arguments, inputs, environment, args, env):
    log = directory / 'run.log'
    if args.target == 'qemu':
        return run_image(directory / 'base.elf', files, args.timeout,
                         device=Device(files, environment, inputs, arguments), log=log)
    command = [sys.executable, ROOT / 'tools/run_tangnano20k_base.py', directory / 'base.bin',
               '--root', files, '--freq-mhz', '48', '--port', args.port,
               '--timeout', str(args.timeout)]
    command += [f'--arg={value}' for value in arguments]
    command += [f'--input={value}' for value in inputs]
    command += [f'--env={key}={value}' for key, value in environment.items()]
    upload_seconds = (directory / 'base.bin').stat().st_size * 8680 / 48000000
    output = run(command, log, env, args.timeout + 60 + upload_seconds)
    require(output.rstrip().endswith('DONE'), 'board did not return to loader')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=('qemu', 'board'), default='qemu')
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--cases', nargs='+', choices=CASES)
    selection.add_argument('--program', type=Path, help='compile and run a Base .fpr program instead of the suite')
    parser.add_argument('--arg', action='append', default=[], help='program argument; use --arg=-x for leading dashes')
    parser.add_argument('--input', action='append', default=[], help='input line; repeat in order, then EOF')
    parser.add_argument('--env', action='append', default=[], metavar='NAME=VALUE')
    parser.add_argument('--root', type=Path, help='existing guest file root; default: isolated output/files')
    parser.add_argument('--timeout', type=float, default=120, help='guest execution seconds (default: 120)')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--fpga-manifest', type=Path, help='required for board; programs its bitstream into SRAM')
    parser.add_argument('--loader', default=str(Path.home() / 'Documents/Libs/oss-cad-suite/bin/openFPGALoader'))
    parser.add_argument('--port', default='/dev/cu.usbserial-20250303171')
    args = parser.parse_args()
    if args.target == 'board' and args.fpga_manifest is None:
        parser.error('--target board requires --fpga-manifest from the matching preset build')
    if args.target == 'qemu' and args.fpga_manifest is not None:
        parser.error('--fpga-manifest is only used with --target board')
    args.cases = args.cases or list(CASES)
    if len(set(args.cases)) != len(args.cases):
        parser.error('duplicate cases')
    mode = 'program' if args.program is not None else 'suite'
    default_directory = f'program-{args.target}' if args.program is not None else args.target
    out = (args.out or ROOT / f'build/tangnano20k-examples/{default_directory}').resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, 'FPR_PRESET': 'fprisc-48', 'FPR_QEMU': str(int(args.target == 'qemu')),
           'FPR_HEAP_REPORT': '1'}
    report = dict(preset='fprisc-48', target=args.target, mode=mode, passed=False,
                  suite_complete=False, repository=None, cases=[])
    # Invalidate a previous pass before any work, including interrupted runs
    # and the identity lookup below (git can refuse a container's checkout).
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    report['repository'] = repository(ROOT)
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    try:
        require(math.isfinite(args.timeout) and args.timeout > 0, '--timeout must be finite and positive')
        require(args.program is not None or not (args.arg or args.input or args.env or args.root),
                '--arg, --input, --env and --root require --program')
        if args.program is not None:
            source = args.program.resolve()
            require(source.is_file() and source.suffix == '.fpr', '--program must be an existing .fpr file')
            files = args.root.resolve() if args.root is not None else out / 'files'
            if args.root is not None:
                require(files.is_dir(), '--root must be an existing directory')
            else:
                files.mkdir(exist_ok=True)
            require(all('=' in entry and entry.split('=', 1)[0] for entry in args.env),
                    '--env requires a nonempty NAME=VALUE')
            environment = dict(entry.split('=', 1) for entry in args.env)
            # Refuse invalid arguments before compiler work or FPGA programming.
            Device(files, environment, args.input, args.arg)
            report['invocation'] = dict(source=str(source), root=str(files), arguments=args.arg,
                                        input_lines=args.input, environment=environment, timeout=args.timeout)
        # Validate the preset before compiler builds, tool downloads or hardware
        # changes. The shell contract refuses conflicting inherited settings.
        run(['bash', '-c', 'source machine/tangnano20k/preset.sh'], out / 'preset.log', env)
        env.update(FPR_XLEN='32', FPR_RVC='1', FPR_CPU_MHZ='48')
        bitstream = None
        if args.target == 'board':
            bitstream, report['fpga'] = fpga_image(args.fpga_manifest.resolve())
        run(['make', 'fpr'], out / 'compiler-build.log', env, 900)
        softfloat = Path(env.get('FPR_SOFTFLOAT_ROOT', ROOT / 'build/tangnano20k-softfloat'))
        if not (softfloat / 'build/Linux-RISCV32-GCC/softfloat.a').is_file():
            run(['machine/tangnano20k/build-softfloat.sh'], out / 'softfloat-build.log', env, 300)
        if args.program is not None:
            directory = out / 'program'
            directory.mkdir(exist_ok=True)
            started = time.monotonic()
            case = dict(name='program', passed=False)
            report['cases'].append(case)
            run(['machine/tangnano20k/build.sh', source, directory], directory / 'build.log', env)
            case['build'] = json.loads((directory / 'build-manifest.json').read_text())
            if bitstream:
                run([args.loader, '-b', 'tangnano20k', bitstream], out / 'program-fpga.log', env, 120)
                report['fpga_programmed_sram'] = True
            output = execute_guest(directory, files, args.arg, args.input, environment, args, env)
            validate_case('program', output, files)
            print(output, end='' if output.endswith('\n') else '\n', flush=True)
            case.update(passed=True, wall_seconds=time.monotonic() - started)
            report['passed'] = True
            print(f'PASS: program; {out / "results.json"}', flush=True)
            return
        if bitstream:
            run([args.loader, '-b', 'tangnano20k', bitstream], out / 'program-fpga.log', env, 120)
            report['fpga_programmed_sram'] = True
        for name in args.cases:
            print(f'{name}: building/running ({args.target}, fprisc-48)', flush=True)
            case = dict(name=name, passed=False)
            report['cases'].append(case)
            directory = out / name
            directory.mkdir(parents=True, exist_ok=True)
            started = time.monotonic()
            if name == 'classifier':
                command = [sys.executable, ROOT / 'tests/check_tangnano20k_dtree.py',
                           '--qemu' if args.target == 'qemu' else '--hardware',
                           '--xlen', '32', '--freq-mhz', '48', '--train', '512', '--test', '128',
                           '--bins', '16', '--depth', '6', '--min-leaf', '5', '--repeat', '10',
                           '--timeout', '600', '--output', directory, '--port', args.port]
                if bitstream:
                    command += ['--bitstream', bitstream]
                run(command, directory / 'run.log', env, 900)
                detail = json.loads((directory / 'results.json').read_text())
                execution = detail['executions']['qemu' if args.target == 'qemu' else 'board']
                require(execution['passed'] and len(execution['elapsed_us_runs']) == 10,
                        'classifier did not complete ten exact iterations')
                samples = execution['heap_samples']
                limit = execution['usable_heap_block_bytes']
                require(len(samples) > 2 and all(s['peak'] <= limit for s in samples)
                        and max(s['live'] for s in samples[:-1]) < 1024 * 1024
                        and samples[-1]['reclaimed'] > 10 * limit and samples[-1]['collections'] >= 10,
                        'classifier heap/reclamation gate failed')
                case['classifier_report'] = str(directory / 'results.json')
            else:
                run(['machine/tangnano20k/build.sh', SOURCES[name], directory], directory / 'build.log', env)
                case['build'] = json.loads((directory / 'build-manifest.json').read_text())
                files = directory / 'files'
                files.mkdir(exist_ok=True)
                arguments = ARGUMENTS if name == 'args' else []
                if name == 'host':
                    (files / 'output.txt').unlink(missing_ok=True)
                if name == 'wc':
                    (files / 'words.txt').write_bytes(b'alpha beta\ngamma\n')
                    (files / 'two words.txt').write_bytes(b'delta zeta\n')
                    arguments = ['words.txt', 'two words.txt']
                output = execute_guest(directory, files, arguments, ['hello RV32'],
                                       {'TEST_UART': 'connected'}, args, env)
                validate_case(name, output, files)
            case.update(passed=True, wall_seconds=time.monotonic() - started)
            print(f'{name}: PASS', flush=True)
        report.update(passed=True, suite_complete=set(args.cases) == set(CASES))
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(args.cases)} cases; {out / "results.json"}', flush=True)


if __name__ == '__main__':
    main()
