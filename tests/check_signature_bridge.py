#!/usr/bin/env python3
"""P2 signature bridge, first slice (docs/2026-11-08-P2-SIGNATURE-BRIDGE.md).

Compiles every corpus entry (tests/pipeline/corpus.json) for the host and for
RV64 and reads the `# signature bridge:` line each unit prints: how many scalar
worker signatures solved by KernelKinds agree with the checked interface,
stay guarded (a checked position that is not a raw word), or have no checked
interface, or are admitted by the checked kinds only (counted, not yet
admitted: slice 2 keeps code shape). A disagreement is a compile error, so every compile succeeding is
the main assertion. On top of that:

  - fib's worker (fib : Int -> Int) must agree;
  - across the corpus, agreed must be non-zero for each target;
  - no worker may be unchecked (slice 3: field workers carry their source's
    checked kinds); the note names any unchecked function.
"""
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NOTE = re.compile(r'# signature bridge: agreed=(\d+) guarded=(\d+) unchecked=(\d+) checked_only=(\d+)(?: unchecked_names=(\S+))?')


def compile_counts(src, target, tmp, tag):
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / f'c-{tag}-{target or "host"}'))
    out = tmp / f'{tag}-{target or "host"}.s'
    cmd = [str(ROOT / 'fpr'), 'compile', '--system=posix'] + ([f'--target={target}'] if target else []) + [str(src), str(out)]
    p = subprocess.run(cmd, cwd=ROOT, env=env, text=True, capture_output=True, timeout=600)
    if p.returncode != 0:
        sys.exit(f'FAIL {tag} ({target or "host"}): compile failed\n{p.stdout[-1500:]}{p.stderr[-1500:]}')
    totals = [0, 0, 0, 0]
    names = []
    for m in NOTE.finditer(p.stdout):
        for i in range(4):
            totals[i] += int(m.group(i + 1))
        if m.group(5):
            names += m.group(5).split(',')
    return totals, names


def main():
    corpus = json.loads((ROOT / 'tests/pipeline/corpus.json').read_text())['entries']
    bad = 0
    with tempfile.TemporaryDirectory(prefix='fpr-bridge-') as d:
        tmp = Path(d)
        for target in (None, 'rv64'):
            grand = [0, 0, 0, 0]
            for e in corpus:
                (a, g, u, c), names = compile_counts(ROOT / e['source'], target, tmp, e['id'])
                if u:
                    print(f'FAIL {e["id"]} ({target or "host"}): unchecked workers: {", ".join(names)}')
                    bad += 1
                grand = [grand[0] + a, grand[1] + g, grand[2] + u, grand[3] + c]
                if e['id'] == 'fib' and a < 1:
                    print(f'FAIL fib ({target or "host"}): its Int -> Int worker did not agree (agreed={a} guarded={g} unchecked={u})')
                    bad += 1
            name = target or 'host'
            print(f'signature bridge ({name}): {len(corpus)} corpus entries compiled; '
                  f'agreed={grand[0]} guarded={grand[1]} unchecked={grand[2]} checked_only={grand[3]}, no disagreement')
            if grand[0] == 0:
                print(f'FAIL {name}: no worker signature agreed with a checked interface')
                bad += 1
    if bad:
        return 1
    print('signature bridge: KernelKinds agrees with every checked raw-word position: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
