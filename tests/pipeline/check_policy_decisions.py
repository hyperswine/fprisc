#!/usr/bin/env python3
"""Executable checks for the semantic policy's decisions
(docs/2026-11-07-PIPELINE-SEMANTIC-POLICY.md, "Decisions (8 November 2026)").

  D1  fusion's overflow relaxation: the fused and unfused builds of
      tests/pipeline/fusion_overflow_order.fpr both trap with Int overflow,
      after the same stdout; only which overflow is reported may differ.
      A pipeline that does not overflow returns the same value both ways.
  D2  scheduling contract: every native function in the recorded baselines
      (bench/pipeline-baseline*.json) has a finite segmax -- a bound on
      instructions between consecutive safepoints.  UNBOUNDED fails.

D3 (allocation failure order) has no executable form until P6 merges a
reservation; D4 (validation provenance) is enforced today by
tests/check_typed_case.py's received-value cases and gains its stale-fact
negative with P2.  Both are listed so the gap stays visible.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'tests/pipeline/fusion_overflow_order.fpr'
NO_TRAP = '''List = use "std/list".
main = print "{List.sum (List.map (fn x -> x * 2) (List.filter (fn x -> x % 3 == 0) (List.range 1 3000)))}".
'''


def env_for(cache, **extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1', XDG_CACHE_HOME=str(cache), **extra)
    return env


def build_run(src, out, env):
    b = subprocess.run([str(ROOT / 'fpr'), 'build', str(src), '--harts', '1', '-o', str(out)],
                       cwd=ROOT, env=env, text=True, capture_output=True, timeout=600)
    if b.returncode != 0:
        sys.exit(f'build {src} failed:\n{b.stdout[-2000:]}{b.stderr[-2000:]}')
    return subprocess.run([str(out)], cwd=ROOT, env=env, text=True, capture_output=True, timeout=120)


def d1(tmp):
    problems = []
    fused = build_run(FIXTURE, tmp / 'f', env_for(tmp / 'cf'))
    plain = build_run(FIXTURE, tmp / 'u', env_for(tmp / 'cu', FPR_NO_LIST_FUSE='1'))
    if fused.returncode == 0 or plain.returncode == 0:
        problems.append(f'D1: both builds must trap (fused exit {fused.returncode}, unfused exit {plain.returncode})')
    if fused.returncode != plain.returncode:
        problems.append(f'D1: exit status differs: fused {fused.returncode}, unfused {plain.returncode}')
    if fused.stdout != plain.stdout:
        problems.append(f'D1: output before the trap differs: {fused.stdout!r} vs {plain.stdout!r}')
    for name, p in (('fused', fused), ('unfused', plain)):
        if 'Int overflow' not in p.stderr:
            problems.append(f'D1: {name} build did not report Int overflow: {p.stderr[-300:]!r}')
    reported = lambda p: next((l for l in p.stderr.splitlines() if 'Int overflow' in l), '')
    same = reported(fused) == reported(plain)
    src = tmp / 'notrap.fpr'
    src.write_text(NO_TRAP)
    a = build_run(src, tmp / 'nf', env_for(tmp / 'cnf'))
    b = build_run(src, tmp / 'nu', env_for(tmp / 'cnu', FPR_NO_LIST_FUSE='1'))
    if (a.returncode, a.stdout) != (b.returncode, b.stdout) or a.returncode != 0:
        problems.append(f'D1: a non-overflowing pipeline differs: {a.returncode} {a.stdout!r} vs {b.returncode} {b.stdout!r}')
    note = ('same overflow reported' if same else
            'the relaxation is exercised: fused and unfused report different overflows')
    return problems, note


def d2():
    problems, counted = [], 0
    for path in sorted((ROOT / 'bench').glob('pipeline-baseline*.json')):
        data = json.loads(path.read_text())
        for entry, row in data['entries'].items():
            for fn, facts in row['functions'].items():
                counted += 1
                if facts.get('segmax') is None:
                    problems.append(f'D2: {path.name} {entry}: {fn} has no finite segmax (UNBOUNDED)')
    return problems, f'{counted} recorded native functions all bounded' if not problems else ''


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-policy-') as d:
        p1, n1 = d1(Path(d))
    p2, n2 = d2()
    for p in p1 + p2:
        print(f'FAIL {p}')
    if p1 or p2:
        return 1
    print(f'D1 fusion overflow relaxation: both builds trap after the same output ({n1}): PASS')
    print(f'D2 scheduling contract: {n2}: PASS')
    print('D3 allocation failure order: no merged reservation yet (P6 adds its fixture): NOT YET EXECUTABLE')
    print('D4 validation provenance: tests/check_typed_case.py received-value cases (P2 adds the stale-fact negative)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
