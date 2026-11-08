#!/usr/bin/env python3
"""P2 typed lowering, slice 1 (docs/2026-11-08-P2-TYPED-LOWERING-SLICE-1.md).

Compiles every corpus entry (tests/pipeline/corpus.json) cold for the host and
for RV64 and reads the per-unit notes:

  # typed lowering census: t1=.. calls=.. forms=.. ... unit=..
  # typed lowering: s1=.. agreed=.. refused=.. both_refused=.. erase_refused=.. unit=..

A disagreement between the typed lowering and the erased lowering stops the
compile, so every compile succeeding is the main assertion. On top of that:

  - refused must be 0: the typed lowering refuses nothing in its class that
    the erased lowering lowers (a refusal means the class definition and
    Codegen.LowerTyped disagree);
  - the typed_lower_s1 fixture's root unit has at least 7 S1 functions, all
    agreed;
  - across the corpus, agreed must be non-zero for each target.
Shared units are counted once per target (by unit name).
"""
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NOTE = re.compile(r'# typed lowering: s1=(\d+) agreed=(\d+) refused=(\d+) both_refused=(\d+) erase_refused=(\d+)(?: refused_by=(\S+))? unit=(\S+)')
CENSUS = re.compile(r'# typed lowering census: (.*) unit=(\S+)')
FIXTURE_S1 = 7


def compile_notes(src, target, tmp, tag):
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / f'c-{tag}-{target or "host"}'))
    out = tmp / f'{tag}-{target or "host"}.s'
    cmd = [str(ROOT / 'fpr'), 'compile', '--system=posix'] + ([f'--target={target}'] if target else []) + [str(src), str(out)]
    p = subprocess.run(cmd, cwd=ROOT, env=env, text=True, capture_output=True, timeout=900)
    if p.returncode != 0:
        sys.exit(f'FAIL {tag} ({target or "host"}): compile failed\n{p.stdout[-2000:]}{p.stderr[-2000:]}')
    return p.stdout


def main():
    corpus = json.loads((ROOT / 'tests/pipeline/corpus.json').read_text())['entries']
    bad = 0
    with tempfile.TemporaryDirectory(prefix='fpr-typed-lower-') as d:
        tmp = Path(d)
        for target in (None, 'rv64'):
            name = target or 'host'
            units, census = {}, {}
            for e in corpus:
                out = compile_notes(ROOT / e['source'], target, tmp, e['id'])
                for m in NOTE.finditer(out):
                    s1, agreed, refused, both, erase = map(int, m.groups()[:5])
                    unit = m.group(7) if m.group(7) != 'root' else f'root:{e["id"]}'
                    units[unit] = (s1, agreed, refused, both, erase)
                    if refused:
                        print(f'FAIL {e["id"]} ({name}): typed lowering refused {refused} S1 function(s): {m.group(6)}')
                        bad += 1
                    if e['id'] == 'typed_lower_s1' and m.group(7) == 'root' and (s1 < FIXTURE_S1 or agreed != s1):
                        print(f'FAIL typed_lower_s1 ({name}): s1={s1} agreed={agreed}, expected at least {FIXTURE_S1}, all agreed')
                        bad += 1
                for m in CENSUS.finditer(out):
                    unit = m.group(2) if m.group(2) != 'root' else f'root:{e["id"]}'
                    census[unit] = dict((k, int(v)) for k, v in (kv.split('=') for kv in m.group(1).split()))
            total = [sum(u[i] for u in units.values()) for i in range(5)]
            rungs = {}
            for c in census.values():
                for k, v in c.items():
                    rungs[k] = rungs.get(k, 0) + v
            print(f'typed lowering ({name}): {len(corpus)} corpus entries, {len(units)} distinct units; '
                  f's1={total[0]} agreed={total[1]} refused={total[2]} both_refused={total[3]} erase_refused={total[4]}, no disagreement')
            print(f'  census ({name}): ' + ' '.join(f'{k}={v}' for k, v in rungs.items()))
            if total[1] == 0:
                print(f'FAIL {name}: no S1 function agreed')
                bad += 1
    if bad:
        return 1
    print('typed lowering: every S1 function lowers the same from its typed body as from its erasure: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
