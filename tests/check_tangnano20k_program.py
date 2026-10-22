#!/usr/bin/env python3
"""Run a user source from another cwd with arguments, input and a rooted file device."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'tools/run_tangnano20k_examples.py'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=('qemu', 'board'), default='qemu')
    parser.add_argument('--fpga-manifest', type=Path)
    parser.add_argument('--port', default='/dev/cu.usbserial-20250303171')
    args = parser.parse_args()
    if args.target == 'board' and args.fpga_manifest is None:
        parser.error('board test requires --fpga-manifest')
    out = ROOT / 'build/tangnano20k-program-check' / args.target
    out.mkdir(parents=True, exist_ok=True)
    files = out / 'file root'
    files.mkdir(exist_ok=True)
    (files / 'two words.txt').write_text('custom file\n')
    (files / 'result.txt').unlink(missing_ok=True)
    (out / 'outside.txt').write_text('must not be accessible\n')
    shutil.copyfile(ROOT / 'tests/tangnano20k_program.fpr', out / 'custom source.fpr')
    command = [sys.executable, str(RUNNER), '--target', args.target,
               '--program', 'custom source.fpr', '--root', 'file root', '--out', 'run',
               '--arg=', '--arg=two words', '--arg=-n', '--arg=雪', '--arg=quote"slash\\',
               '--input=', '--input=hello 雪', '--input=-last', '--env=CUSTOM_VALUE=a=b 雪']
    if args.target == 'board':
        command += ['--fpga-manifest', str(args.fpga_manifest.resolve()), '--port', args.port]
    result = subprocess.run(command, cwd=out, env={**os.environ, 'FPR_HOME': str(ROOT)},
                            capture_output=True, text=True, timeout=600)
    (out / 'runner.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((out / 'run/results.json').read_text())
    assert report['passed'] and report['mode'] == 'program' and not report['suite_complete']
    assert report['cases'][0]['build']['program']['path'] == str(out / 'custom source.fpr')
    assert report['invocation']['root'] == str(files)
    assert 'CUSTOM PROGRAM HOLDS\n' in result.stdout
    assert (files / 'result.txt').read_bytes() == b'custom output\n'
    assert (out / 'outside.txt').read_bytes() == b'must not be accessible\n'
    print(f'PASS: custom {args.target} source, caller-relative paths, arguments, input/EOF, environment and file root')
    if args.target == 'qemu':
        # A failed compile, failing guest, or hung guest must replace an old
        # success with a failed report and retain the relevant diagnostics.
        for name, text, expected, log, timeout in [
            ('compile-failure', 'profile base. main = noSuchName Unit.\n', None, 'build.log', '120'),
            ('runtime-failure', 'profile base. main = error "EXPECTED FAILURE".\n',
             'EXPECTED FAILURE', 'run.log', '120'),
            ('timeout', 'profile base. spin : unsafe Int -> Int . spin n = spin n. '
             'main : unsafe Unit . main = _ = print "BEFORE WAIT"; print "{spin 0}".\n',
             'BEFORE WAIT', 'run.log', '1'),
        ]:
            source = out / (name + '.fpr')
            source.write_text(text)
            failed_out = out / name
            failed_out.mkdir(exist_ok=True)
            (failed_out / 'results.json').write_text('{"passed": true, "suite_complete": true}')
            result = subprocess.run([sys.executable, str(RUNNER), '--program', str(source),
                                     '--out', str(failed_out), '--timeout', timeout], cwd=out,
                                    capture_output=True, text=True, timeout=600)
            (failed_out / 'runner.log').write_text(result.stdout + result.stderr)
            assert result.returncode != 0, name
            report = json.loads((failed_out / 'results.json').read_text())
            assert not report['passed'] and not report['suite_complete'] and 'error' in report, name
            diagnostic = (failed_out / 'program' / log).read_text()
            assert diagnostic and (expected is None or expected in diagnostic), (name, diagnostic)
            if name == 'timeout':
                assert 'QEMU execution' in report['error'], report
            print(f'PASS: {name} fails closed and preserves diagnostics')


if __name__ == '__main__':
    main()
