#!/usr/bin/env python3
"""Release acceptance matrix for Sol daily scripting; save every check result."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CHECKS = [
    ('inventory', 'tools/sol-fs-check.py'),
    ('configuration', 'tools/sol-cli-config-check.py'),
    ('csv-json', 'tools/sol-format-check.py'),
    ('binary-copy-log-filter', 'tools/sol-io-check.py'),
    ('checksum', 'tools/sol-digest-check.py'),
    ('raw-argv-pipeline', 'tools/sol-pipeline-check.py'),
    ('http', 'tools/sol-http-check.py'),
    ('git-recovery', 'tools/sol-effects-check.py'),
    ('installed-scheduled-run', 'tools/sol-install-check.py'),
    ('guarded-retry', 'tools/sol-retry-policy-check.py'),
    ('receipt-bounds', 'tools/sol-receipt-budget-check.py'),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--only', action='append', choices=[name for name, _ in CHECKS])
    ap.add_argument('--startup-runs', type=int, default=5)
    ap.add_argument('--build-description', required=True)
    ap.add_argument('--host-description', default='local host')
    args = ap.parse_args()
    if args.startup_runs < 1:
        ap.error('--startup-runs must be positive')
    binary = ROOT/'fpr'
    paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).split(b'\0')
    sources = {os.fsdecode(p): sha(ROOT/os.fsdecode(p)) for p in sorted(set(paths)) if p
               and os.fsdecode(p).startswith(('compiler/', 'app/', 'core/', 'std/', 'sol/', 'tools/', 'tests/'))
               and (ROOT/os.fsdecode(p)).is_file()}
    report = dict(schema=1, started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  host=dict(platform=platform.platform(), machine=platform.machine(), description=args.host_description, python=sys.version),
                  build=args.build_description, executable=dict(path=str(binary), sha256=sha(binary)),
                  base_revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  source_sha256=sources, checks=[], startup=[], status='running')

    def save():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')

    def command(argv, env, timeout=1800):
        started = time.monotonic()
        process = subprocess.Popen(argv, env=env, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            return dict(command=[str(a) for a in argv], seconds=time.monotonic()-started,
                        returncode=process.returncode, stdout=stdout, stderr=stderr)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            return dict(command=[str(a) for a in argv], seconds=time.monotonic()-started,
                        returncode=None, stdout=stdout, stderr=stderr, failure='timeout')

    save()
    with tempfile.TemporaryDirectory(prefix='sol-daily-') as temporary:
        work = Path(temporary).resolve()
        env = {k:v for k,v in os.environ.items() if not k.startswith(('SOL_', 'FPR_TEST_'))}
        env |= {'XDG_STATE_HOME': str(work/'state'), 'XDG_CACHE_HOME': str(work/'cache'), 'SOL_GPU': '0'}
        for name, script in CHECKS:
            if args.only and name not in args.only:
                continue
            print('checking '+name, flush=True)
            result = command([sys.executable, '-u', str(ROOT/script)], env)
            report['checks'].append(dict(workflow=name, **result))
            save()
            if result['returncode'] != 0:
                report['status'] = 'failed'; save()
                print(result['stdout']+result['stderr'], file=sys.stderr)
                raise SystemExit(1)
            print(result['stdout'].strip(), flush=True)
        # Fresh processes, warm filesystem; discard all compiler cache tiers for
        # misses. Hits are verified with diagnostics in a separate untimed call.
        hello = work/'startup.sol'
        hello.write_text('D = use "sol/lib/digest.sol".\n> print "ready".\n')
        cache = work/'startup-cache'
        for mode in ('disabled', 'miss', 'hit'):
            settings = env|{'SOL_CACHE': '0' if mode == 'disabled' else '1', 'SOL_CACHE_DIR': str(cache), 'SOL_JIT': '0'}
            samples = []
            for sample in range(args.startup_runs+1):
                if mode == 'miss':
                    shutil.rmtree(cache, ignore_errors=True)
                result = command([str(binary), 'sol', str(hello)], settings, timeout=90)
                assert result['returncode'] == 0 and result['stdout'] == 'ready\n' and not result['stderr'], result
                if sample:
                    samples.append(result['seconds']*1000)
            if mode == 'miss':
                shutil.rmtree(cache, ignore_errors=True)
            traced = command([str(binary), 'sol', str(hello)], settings|{'SOL_CACHE_TRACE': '1'}, timeout=90)
            assert ('[sol cache] '+mode) in traced['stderr'], traced
            report['startup'].append(dict(mode=mode, samples_ms=samples, median_ms=statistics.median(samples),
                                          command=traced['command'], settings={k:v for k,v in settings.items() if k.startswith(('SOL_', 'XDG_'))},
                                          separate_followup_trace=traced['stderr']))
            save()
    report['status'] = 'passed'
    report['finished_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    save()
    print('Sol daily-scripting release matrix passed', flush=True)


if __name__ == '__main__':
    main()
