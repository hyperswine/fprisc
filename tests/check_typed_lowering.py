#!/usr/bin/env python3
"""P2 typed lowering, slices 1-2 (docs/2026-11-08-P2-TYPED-LOWERING-SLICE-1.md).

Compiles every corpus entry (tests/pipeline/corpus.json) cold for the host and
for RV64 and reads the per-unit notes:

  # typed lowering census: t1=.. calls=.. forms=.. ... unit=..
  # typed lowering: s1=.. typed=.. regions=.. worker=.. reuse=.. optimized=.. placed=.. arc=.. absent=.. refused=.. unit=..

Emission takes each S1 function from the typed lowering where the erased
lowering of the same function agrees; any other difference stops the
compile, so every compile succeeding is the main assertion. On top of that:

  - refused must be 0: the typed lowering refuses nothing in its class (a
    refusal means the class definition and Codegen.LowerTyped disagree);
  - regions counts the typed functions lowered from region placement's
    typed result (call regions); they are part of typed;
  - every S1 function is accounted for: typed + worker + reuse + optimized + placed +
    arc + absent = s1;
  - the typed_lower_s1 fixture's root unit has at least 7 S1 functions, at
    least 4 emitted typed, and its code is identical to the build with
    FPR_NO_TYPED_LOWER=1;
  - across the corpus, typed must be non-zero for each target.
Shared units are counted once per target (by unit name).

RV32 (no posix system: the default system) compiles a fixed set of
programs instead (RV32_PROGRAMS). RV32 doesn't run the optimizer's
normalization or reuse, and its call table differs from the host's, so
it is where a plan that mirrors only the host pipeline disagrees; each of
these must compile, refuse nothing, account for every S1 function and
emit the same code as the FPR_NO_TYPED_LOWER=1 build.
"""
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NOTE = re.compile(r'# typed lowering: s1=(\d+) typed=(\d+) regions=(\d+) worker=(\d+) reuse=(\d+) optimized=(\d+) placed=(\d+) arc=(\d+) absent=(\d+) refused=(\d+)(?: refused_by=(.*?))? unit=(\S+)')
FIELDS = ('s1', 'typed', 'regions', 'worker', 'reuse', 'optimized', 'placed', 'arc', 'absent', 'refused')
CENSUS = re.compile(r'# typed lowering census: (.*) unit=(\S+)')
FIXTURE_S1 = 7
FIXTURE_TYPED = 4
RV32_PROGRAMS = ['tests/pipeline/typed_lower_s1.fpr', 'tests/typed_core/vector_reads.fpr', 'examples/mconf.fpr',
                 'examples/report.fpr', 'tests/base/vecpipeline.fpr', 'examples/swarm.fpr']


def compile_notes(src, target, tmp, tag, extra=None, system='posix'):
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(extra or {})
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / f'c-{tag}-{target or "host"}'))
    out = tmp / f'{tag}-{target or "host"}.s'
    cmd = [str(ROOT / 'fpr'), 'compile'] + ([f'--system={system}'] if system else []) + ([f'--target={target}'] if target else []) + [str(src), str(out)]
    p = subprocess.run(cmd, cwd=ROOT, env=env, text=True, capture_output=True, timeout=900)
    if p.returncode != 0:
        sys.exit(f'FAIL {tag} ({target or "host"}): compile failed\n{p.stdout[-2000:]}{p.stderr[-2000:]}')
    return p.stdout


def code(path):
    return [l for l in path.read_text().splitlines() if not l.startswith('#')]


def rv32(tmp):
    bad = 0
    typed = 0
    for src in RV32_PROGRAMS:
        tag = 'rv32-' + Path(src).stem
        out = compile_notes(ROOT / src, 'rv32', tmp, tag, system=None)
        for m in NOTE.finditer(out):
            v = dict(zip(FIELDS, map(int, m.groups()[:10])))
            typed += v['typed']
            if v['refused']:
                print(f'FAIL {src} (rv32): typed lowering refused {v["refused"]}: {m.group(11)}')
                bad += 1
            if sum(v[k] for k in ('typed', 'worker', 'reuse', 'optimized', 'placed', 'arc', 'absent')) != v['s1']:
                print(f'FAIL {src} (rv32) unit {m.group(12)}: S1 functions unaccounted for: {v}')
                bad += 1
        compile_notes(ROOT / src, 'rv32', tmp, tag + '-erased', {'FPR_NO_TYPED_LOWER': '1'}, system=None)
        if code(tmp / f'{tag}-rv32.s') != code(tmp / f'{tag}-erased-rv32.s'):
            print(f'FAIL {src} (rv32): code differs from the FPR_NO_TYPED_LOWER=1 build')
            bad += 1
    print(f'typed lowering (rv32): {len(RV32_PROGRAMS)} programs, typed={typed} (shared units counted per program), code identical' if not bad else 'typed lowering (rv32): FAILED')
    if typed == 0:
        print('FAIL rv32: no S1 function emitted typed')
        bad += 1
    return bad


# an inlined helper's lambda is a template closure: once the callback pass
# calls the higher-order function's clone with its capture, the caller's
# binding of it is dead and must go, so nothing in the root keeps the erased
# function (typed callbacks' trim)
INLINED_CLOSURE = 'tests/typed_core/inlined_closure.fpr'


def inlined_closure(tmp):
    out = compile_notes(ROOT / INLINED_CLOSURE, None, tmp, 'inlined-closure')
    for m in NOTE.finditer(out):
        v = dict(zip(FIELDS, map(int, m.groups()[:10])))
        if m.group(12) == 'root':
            if v['optimized'] or v['typed'] != v['s1']:
                print(f'FAIL inlined closure: {v}, expected every root S1 function typed')
                return 1
            print(f'typed lowering (inlined closure): root s1={v["s1"]} typed={v["typed"]}, no dead closure let')
            return 0
    print('FAIL inlined closure: no root note')
    return 1


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
                    v = dict(zip(FIELDS, map(int, m.groups()[:10])))
                    unit = m.group(12) if m.group(12) != 'root' else f'root:{e["id"]}'
                    units[unit] = v
                    if v['refused']:
                        print(f'FAIL {e["id"]} ({name}): typed lowering refused {v["refused"]} S1 function(s): {m.group(11)}')
                        bad += 1
                    if sum(v[k] for k in ('typed', 'worker', 'reuse', 'optimized', 'placed', 'arc', 'absent')) != v['s1']:
                        print(f'FAIL {e["id"]} ({name}) unit {unit}: S1 functions unaccounted for: {v}')
                        bad += 1
                    if e['id'] == 'typed_lower_s1' and m.group(12) == 'root' and (v['s1'] < FIXTURE_S1 or v['typed'] < FIXTURE_TYPED):
                        print(f'FAIL typed_lower_s1 ({name}): {v}, expected s1>={FIXTURE_S1} typed>={FIXTURE_TYPED}')
                        bad += 1
                if e['id'] == 'typed_lower_s1':
                    compile_notes(ROOT / e['source'], target, tmp, e['id'] + '-erased', {'FPR_NO_TYPED_LOWER': '1'})
                    if code(tmp / f'{e["id"]}-{name}.s') != code(tmp / f'{e["id"]}-erased-{name}.s'):
                        print(f'FAIL typed_lower_s1 ({name}): code differs from the FPR_NO_TYPED_LOWER=1 build')
                        bad += 1
                for m in CENSUS.finditer(out):
                    unit = m.group(2) if m.group(2) != 'root' else f'root:{e["id"]}'
                    census[unit] = dict((k, int(v)) for k, v in (kv.split('=') for kv in m.group(1).split()))
            total = {k: sum(u[k] for u in units.values()) for k in FIELDS}
            rungs = {}
            for c in census.values():
                for k, v in c.items():
                    rungs[k] = rungs.get(k, 0) + v
            print(f'typed lowering ({name}): {len(corpus)} corpus entries, {len(units)} distinct units; '
                  + ' '.join(f'{k}={v}' for k, v in total.items()) + ', no disagreement')
            print(f'  census ({name}): ' + ' '.join(f'{k}={v}' for k, v in rungs.items()))
            if total['typed'] == 0:
                print(f'FAIL {name}: no S1 function emitted typed')
                bad += 1
        bad += rv32(tmp)
        bad += inlined_closure(tmp)
    if bad:
        return 1
    print('typed lowering: S1 functions are emitted from the typed lowering where the erased lowering agrees, every other one accounted for: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
