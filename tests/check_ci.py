#!/usr/bin/env python3
"""Run registered CI configurations and record successful coverage for Base.

Use a fresh --results file for each CI run. Receipts are bound to source contents,
registry definitions and host; missing, changed or failed checks cannot skip work.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

from check_registry import CI, GROUPS

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = 1


def source_digest(root=ROOT):
    # Include local/untracked sources too, so local receipts cannot survive an
    # edit. Ignored outputs (build/, fpr, .o, caches) are intentionally excluded.
    paths = subprocess.check_output(
        ['git', 'ls-files', '-z', '-c', '-o', '--exclude-standard'], cwd=root).split(b'\0')
    digest = hashlib.sha256()
    for name in sorted(set(paths) - {b''}):
        path = root / os.fsdecode(name)
        if path.is_file():
            digest.update(name + b'\0')
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def context():
    return {'schema': SCHEMA, 'source': source_digest(),
            'root': str(ROOT), 'host': platform.platform(),
            'ci_run': [os.environ.get(k) for k in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB')],
            'environment': hashlib.sha256(json.dumps({
                k: v for k, v in os.environ.items()
                if k.startswith(('FPR_', 'FPRC_', 'XDG_', 'GHC', 'CABAL', 'PKG_CONFIG'))
                or k in ('PATH', 'CC', 'CXX', 'CFLAGS', 'CPPFLAGS', 'LDFLAGS')
            }, sort_keys=True).encode()).hexdigest()}


def read_results(path, expected=None):
    result = json.loads(Path(path).read_text())
    if result['context'] != (expected or context()):
        raise ValueError('completed checks are from a different source tree, host or environment')
    for key, entry in result['checks'].items():
        if key not in CI or entry.get('status') != 'ok':
            raise ValueError(f'invalid completed configuration: {key}')
    return result


def covered_base(path):
    result = read_results(path)
    return {base for key in result['checks'] for base in CI[key].covers}


def write_results(path, result):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as f:
        tmp = Path(f.name)
        json.dump(result, f, indent=2)
        f.write('\n')
    tmp.replace(path)


def run_group(group, results, output, *, execute=subprocess.run):
    expected = context()
    record = read_results(results, expected) if Path(results).exists() else {'context': expected, 'checks': {}}
    for check in GROUPS[group]:
        if check.id in record['checks']:
            raise ValueError(f'configuration already completed: {check.id}; use a fresh results file')
        args = [sys.executable, '-u', check.path, *(arg.format(output=output) for arg in check.args)]
        print('check_ci:', check.id, flush=True)
        began = time.monotonic()
        # Every invocation keeps its exact environment/arguments. A nonzero
        # result never gets a receipt, even if earlier checks in the group passed.
        execute(args, cwd=ROOT, env={**os.environ, **dict(check.env)},
                timeout=check.timeout, check=True)
        elapsed = time.monotonic() - began
        if context() != expected:
            raise ValueError('source/environment changed while checks were running')
        record['checks'][check.id] = {'status': 'ok', 'seconds': elapsed, 'command': args}
        write_results(results, record)
        print(f'check_ci: {check.id}: {elapsed:.1f} s', flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--group', choices=GROUPS)
    ap.add_argument('--results', type=Path, required=True)
    ap.add_argument('--output', type=Path, default=ROOT / 'build/ci')
    ap.add_argument('--verify', action='store_true', help='require all registered CI configurations to have passed')
    ap.add_argument('--list', action='store_true', help='print configuration/coverage plan without running checks')
    args = ap.parse_args()
    try:
        if args.list:
            checks = GROUPS[args.group] if args.group else CI.values()
            print(json.dumps([{'id': c.id, 'path': c.path, 'args': c.args,
                               'env': dict(c.env), 'covers': c.covers} for c in checks], indent=2))
        elif args.verify:
            result = read_results(args.results)
            missing = CI.keys() - result['checks'].keys()
            if missing:
                raise ValueError('missing CI configurations: ' + ', '.join(sorted(missing)))
            print(f'check_ci: all {len(CI)} configurations passed')
        elif args.group:
            args.output.mkdir(parents=True, exist_ok=True)
            run_group(args.group, args.results, args.output.resolve())
        else:
            ap.error('--group, --verify or --list is required')
    except (ValueError, OSError, KeyError) as exc:
        ap.error(str(exc))


if __name__ == '__main__':
    main()
