#!/usr/bin/env python3
"""P0 reference baselines for the pipeline refactoring
(docs/2026-11-07-PIPELINE-REFACTORING-ROADMAP.md, Phase P0).

Records, for every entry of tests/pipeline/corpus.json:

  behaviour  exact stdout (or the .expected file it names), exit status and
             the required stderr fragments, plus the runtime cost counters
             (allocation requests/bytes, copies, turns, receives) that
             FPR_COST_PROBE already reports
  code       generated assembly bytes and instruction lines, per-function
             frame/spills/segment facts and the native coverage the compiler
             reports, and the core cache identity of every emitted unit
  compiler   wall time and GHC heap allocation of one cold compile, the
             remark stream counted by pass, kind and outcome, the compiler
             binary hash and the codegen revision

  tools/pipeline-baseline.py --record     write bench/pipeline-baseline.json
  tools/pipeline-baseline.py --check      compare against it
  tools/pipeline-baseline.py --check fib  only these entries
  tools/pipeline-baseline.py --record --target=rv64
                                          cross-compile only: code facts in
                                          bench/pipeline-baseline-rv64.json

`--record` is a machine-local act: the file names the host it was measured on.
Comparing a different host reports, never fails (tools/bench.py does the same).
Behaviour is the contract: a stdout, exit status or trap mismatch always fails,
whatever the compiler.  Metric drift fails only when the compiler binary is the
one the baseline was recorded with; a new compiler changes code and allocation
counts by design, and the drift is printed for review instead.  Timing is
recorded but never gated -- tools/bench.py owns the timing ratchet.

`--target` records a cross target's compile facts (coverage, code size,
per-function frame/spill/segment facts, remarks, compile cost) without running
anything, into its own file.  Its behaviour is not executed by this tool, and
the file says so in its unverified list.

Targets that are not this host's are listed as unverified: a missing board or
cross toolchain is reported, never counted as a pass.
"""
import argparse, hashlib, json, os, platform, re, statistics, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'tests' / 'pipeline' / 'corpus.json'
BASE = ROOT / 'bench' / 'pipeline-baseline.json'
UNVERIFIED = [
    'rv32-tangnano20k: physical board and vendor synthesis are not part of this recording',
    'a64-qos / pi: the deployment host is not this machine',
    'rv64: compile facts only (record with --target=rv64); no execution is recorded',
]


def target_unverified(target):
    return [f'{target}: behaviour, timing and allocation counters are not executed by this tool '
            '(compile facts only); execution needs that target\'s emulator or board',
            *[u for u in UNVERIFIED if not u.startswith(target + ':')]]

PRECOND = re.compile(r'precond: (\d+) obligations: (\d+) discharged, (\d+) runtime-checked, (\d+) builtin traps$', re.M)
WORKERS = re.compile(r'# private workers: fields=(\d+) scalar=(\d+)')
CONSUMING = re.compile(r'# private consuming workers: (\d+)')
COVERAGE = re.compile(r'typed-ir-backend: native (\d+)/(\d+) functions')
FN_NATIVE = re.compile(r'typed-ir-backend: (\S+) native \((.*)\)$', re.M)
FN_KV = re.compile(r'(\w+)=([^,\s]+(?:,[^\s)]+)*)')
WROTE = re.compile(r'wrote \S+ \((\d+) supercombinators', re.M)
UNIT = re.compile(r'unit (\S+)')
CORE_ID = re.compile(r'ccore\d+-([0-9a-f]+)')
REVISION = re.compile(r'-g(\d+)-')
COST = re.compile(r'\[fpr cost\] (\{.*\})')
RTS_ALLOC = re.compile(r'([\d,]+) bytes allocated in the heap')
RTS_PEAK = re.compile(r'([\d,]+) bytes maximum residency')


def host():
    return f'{platform.system()}-{platform.machine()}-{platform.node().split(".")[0]}'


def compiler_hash():
    return hashlib.sha256((ROOT / 'fpr').read_bytes()).hexdigest()


def clean_env(cache, **extra):
    """Nothing inherited: FPR_* from the caller would silently change the build."""
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(cache))
    env.update(extra)
    return env


def run(command, env, timeout=900):
    return subprocess.run([str(c) for c in command], cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def check(command, env, what):
    p = run(command, env)
    if p.returncode != 0:
        sys.exit(f'{what} failed:\n$ {" ".join(map(str, command))}\n{p.stdout[-4000:]}{p.stderr[-4000:]}')
    return p


def size_sections(exe):
    """Linked text size. Hosted posix executables link the runtime, so this is a
    coarse whole-image number beside the generated assembly figures."""
    try:
        if platform.system() == 'Darwin':
            p = run(['size', '-m', exe], clean_env(Path(exe).parent))
            m = re.search(r'Section __text: (\d+)', p.stdout)
            return int(m.group(1)) if m else None
        p = run(['size', exe], clean_env(Path(exe).parent))
        rows = [l.split() for l in p.stdout.splitlines() if l.strip()]
        return int(rows[1][0]) if len(rows) > 1 else None
    except Exception:
        return None


def function_facts(text):
    facts = {}
    for m in FN_NATIVE.finditer(text):
        name, body = m.group(1), m.group(2)
        kv = {}
        for key, value in FN_KV.findall(body):
            kv[key] = value
        seg = re.search(r'segmax=(\d+) exittail=(\d+) ccalls=(\d+)', body)
        facts[name] = {
            'frame': int(kv['frame']) if 'frame' in kv else None,
            'spills': int(kv['spills']) if 'spills' in kv else None,
            'slots': int(kv['slots']) if 'slots' in kv else None,
            'loops': int(kv['loops']) if 'loops' in kv else None,
            'shallow': kv.get('shallow'),
            'segmax': int(seg.group(1)) if seg else None,
            'exittail': int(seg.group(2)) if seg else None,
            'ccalls': int(seg.group(3)) if seg else None,
        }
    return facts


def remark_counts(lines):
    counts = {}
    for line in lines:
        line = line.strip()
        if not line.startswith('{"remarkVersion"'):
            continue
        remark = json.loads(line)
        key = f'{remark.get("pass")}:{remark.get("kind")}:{remark.get("outcome")}'
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def compile_facts(entry, system, cache, tmp, target=None):
    """One cold compile through the fprc path: it prints the human summary the
    build subcommand suppresses, and the same JSON remark stream.

    The compile emits the prelude and every dependency unit before the root,
    and each prints its own coverage line and function facts, so the summary
    is attributed per unit rather than read as one block.  `cold` means a
    fresh unit cache: the prelude is compiled here too, which is why the
    allocated bytes of a cold compile are much larger than a warm one.
    """
    # its own directory: `unit` lines report every unit file in
    # <dirname>/units, so a shared directory would attribute an earlier
    # entry's units to this one
    asm = tmp / entry['id'] / f'{entry["id"]}.s'
    asm.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    flags = [f'--system={system}'] + ([f'--target={target}'] if target else [])
    p = check([ROOT / 'fpr', 'compile', *flags, '--remarks=json',
               entry['source'], asm, '+RTS', '-s'], clean_env(cache), f'compile {entry["id"]}')
    seconds = time.perf_counter() - started
    lines = p.stdout.splitlines()
    alloc = RTS_ALLOC.search(p.stderr)
    peak = RTS_PEAK.search(p.stderr)
    body = asm.read_text() if asm.exists() else ''
    precond = PRECOND.search(p.stdout)
    workers = [{'fields': int(a), 'scalar': int(b)} for a, b in WORKERS.findall(p.stdout)]
    consuming = [int(n) for n in CONSUMING.findall(p.stdout)]
    coverage = [{'native': int(a), 'functions': int(b)} for a, b in COVERAGE.findall(p.stdout)]
    wrote = WROTE.search(p.stdout)
    units = sorted({m.group(1) for m in UNIT.finditer(p.stdout)})
    return {
        'compile': {
            'seconds': round(seconds, 3),
            'allocated_bytes': int(alloc.group(1).replace(',', '')) if alloc else None,
            'max_residency_bytes': int(peak.group(1).replace(',', '')) if peak else None,
        },
        'code': {
            'asm_bytes': len(body.encode()),
            'asm_instruction_lines': len([l for l in body.splitlines() if re.match(r'^\s+[a-z][a-z0-9._]*\s', l)]),
            'linked_text_bytes': None,  # filled by the behaviour build
            'supercombinators': int(wrote.group(1)) if wrote else None,
        },
        # every emitted unit must lower natively, whole; a shortfall would be
        # the silently untyped fallback P2 forbids
        'coverage': {'units': coverage,
                     'complete': all(u['native'] == u['functions'] for u in coverage) if coverage else None},
        'preconditions': {'obligations': int(precond.group(1)), 'discharged': int(precond.group(2)),
                          'runtime_checked': int(precond.group(3)), 'builtin_traps': int(precond.group(4))}
                         if precond else None,
        'private_workers': workers,
        'private_consuming_workers': consuming,
        'functions': function_facts('\n'.join(lines)),
        'remarks': remark_counts(p.stderr.splitlines()),
        'units': {
            'count': len(units),
            'core_identities': sorted({m.group(1) for u in units for m in [CORE_ID.search(u)] if m}),
            'codegen_revision': int(m.group(1)) if units and (m := REVISION.search(units[0])) else None,
        },
    }


def expected_stdout(entry):
    expect = entry['expect']
    if 'stdout_file' in expect:
        return (ROOT / expect['stdout_file']).read_text()
    return expect.get('stdout', '')


def behaviour(entry, defaults, cache, probe_cache, tmp):
    harts = str(entry.get('harts', defaults['harts']))
    exe = tmp / (entry['id'] + '.exe')
    check([ROOT / 'fpr', 'build', entry['source'], '--harts', harts, '-o', exe],
          clean_env(cache), f'build {entry["id"]}')

    times, out, err, code = [], '', '', None
    for _ in range(defaults['runs']):
        started = time.perf_counter()
        p = run([exe], clean_env(cache))
        times.append(time.perf_counter() - started)
        out, err, code = p.stdout, p.stderr, p.returncode
    want = entry['expect']
    problems = []
    if out != expected_stdout(entry):
        problems.append(f'stdout: want {expected_stdout(entry)!r}, got {out!r}')
    if code != want.get('exit', 0):
        problems.append(f'exit: want {want.get("exit", 0)}, got {code}')
    for fragment in want.get('stderr_contains', []):
        if fragment not in err:
            problems.append(f'stderr: missing {fragment!r}')
    # The probe build sets a runtime C macro, so it must not share a unit cache
    # with the plain build: the counts describe the same source and the same
    # output, which is asserted rather than assumed.
    cost_exe = tmp / (entry['id'] + '.cost')
    check([ROOT / 'fpr', 'build', entry['source'], '--harts', harts, '-o', cost_exe],
          clean_env(probe_cache, FPR_COST_PROBE='1'), f'probe build {entry["id"]}')
    q = run([cost_exe], clean_env(probe_cache, FPR_COST_REPORT='1'))
    m = COST.search(q.stderr)
    cost = json.loads(m.group(1)) if m else None
    if q.stdout != out:
        problems.append(f'probe stdout differs from the plain build: {q.stdout!r}')
    if cost is None:
        problems.append('probe build reported no [fpr cost] counters')
    return {
        'behaviour': {
            'stdout_sha256': hashlib.sha256(out.encode()).hexdigest(),
            'stdout_lines': len(out.splitlines()),
            'exit': code,
            'stderr_fragments': [f for f in want.get('stderr_contains', []) if f in err],
        },
        'timing': {'runs': defaults['runs'], 'min_s': round(min(times), 4),
                   'median_s': round(statistics.median(times), 4)},
        'cost': cost,
        'problems': problems,
        'linked_text_bytes': size_sections(exe),
    }


def record(entries, defaults, system, target=None):
    rows = {}
    with tempfile.TemporaryDirectory(prefix='fpr-p0-') as folder:
        tmp = Path(folder)
        for entry in entries:
            # a fresh cache per entry: the compile facts must describe a cold
            # compile of this source, not a unit that an earlier entry warmed
            facts = compile_facts(entry, system, tmp / ('c-' + entry['id']), tmp, target)
            if target:
                rows[entry['id']] = {
                    'category': entry['category'],
                    'source': entry['source'],
                    'positive_for': entry.get('positive_for', []),
                    'negative_fixtures': entry.get('negative_fixtures', []),
                    **facts,
                }
                units = facts['coverage']['units']
                print(f'{entry["id"]:24} {sum(u["native"] for u in units):3}/{sum(u["functions"] for u in units)} '
                      f'native in {len(units)} unit(s)  {facts["code"]["asm_bytes"]:7} asm bytes  '
                      f'{facts["compile"]["seconds"]:5.2f}s  ({target}, not run)', flush=True)
                continue
            live = behaviour(entry, defaults, tmp / ('c-' + entry['id']), tmp / ('p-' + entry['id']), tmp)
            facts['code']['linked_text_bytes'] = live.pop('linked_text_bytes')
            problems = live.pop('problems')
            if problems:
                sys.exit(f'{entry["id"]}: behaviour contract broken:\n  ' + '\n  '.join(problems))
            rows[entry['id']] = {
                'category': entry['category'],
                'source': entry['source'],
                'positive_for': entry.get('positive_for', []),
                'negative_fixtures': entry.get('negative_fixtures', []),
                **live, **facts,
            }
            units = facts['coverage']['units']
            native = sum(u['native'] for u in units)
            found = sum(u['functions'] for u in units)
            print(f'{entry["id"]:24} {native:3}/{found} native in {len(units)} unit(s)  '
                  f'{facts["code"]["asm_bytes"]:7} asm bytes  '
                  f'{facts["compile"]["seconds"]:5.2f}s  '
                  f'{live["timing"]["min_s"]:6.3f}s run', flush=True)
    return {
        'schema': 1,
        'host': host(),
        'recorded_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'git_commit': subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True,
                                     capture_output=True).stdout.strip(),
        'compiler_sha256': compiler_hash(),
        'system': system,
        'target': target,
        'unverified': target_unverified(target) if target else UNVERIFIED,
        'entries': rows,
    }


def metric(row, path):
    node = row
    for key in path.split('.'):
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


GATED = ['compile.allocated_bytes', 'code.asm_bytes',
         'preconditions.runtime_checked', 'cost.alloc_requests', 'cost.alloc_bytes']
PER_FUNCTION = ['spills', 'segmax', 'frame', 'loops']


def compare(baseline, fresh, slack, same_compiler, subset):
    failures, drift = [], []
    for name in baseline['entries']:
        if name not in fresh['entries']:
            if not subset:
                failures.append(f'{name}: missing from the fresh recording')
            continue
    for name, new in fresh['entries'].items():
        old = baseline['entries'].get(name)
        if old is None:
            failures.append(f'{name}: not in the baseline; re-record it')
            continue
        if old.get('behaviour') != new.get('behaviour'):
            failures.append(f'{name}: behaviour changed: {old["behaviour"]} -> {new["behaviour"]}')
        if new['coverage']['complete'] is False:
            failures.append(f'{name}: a unit lowered fewer functions natively than it emitted: {new["coverage"]["units"]}')
        # semantic policy Decision 2: the scheduling contract is a finite
        # instruction bound between safepoints in every native function
        unbounded = [fn for fn, facts in new['functions'].items() if facts.get('segmax') is None]
        if unbounded:
            failures.append(f'{name}: no finite segmax (UNBOUNDED between safepoints): {", ".join(unbounded[:5])}')
        if old['remarks'] != new['remarks']:
            drift.append(f'{name}: remark stream changed')
        if old['coverage']['units'] != new['coverage']['units']:
            drift.append(f'{name}: per-unit coverage {old["coverage"]["units"]} -> {new["coverage"]["units"]}')
        if not same_compiler:
            continue
        for path in GATED:
            a, b = metric(old, path), metric(new, path)
            if a is None or b is None:
                continue
            if a == 0:
                if b != 0:
                    drift.append(f'{name}: {path} {a} -> {b}')
                continue
            if abs(b - a) > abs(a) * slack:
                drift.append(f'{name}: {path} {a} -> {b}')
        for fn, facts in old['functions'].items():
            fresh_facts = new['functions'].get(fn)
            if fresh_facts is None:
                drift.append(f'{name}: function {fn} is gone')
                continue
            for key in PER_FUNCTION:
                a, b = facts.get(key), fresh_facts.get(key)
                if a is not None and b is not None and a != b:
                    drift.append(f'{name}: {fn}.{key} {a} -> {b}')
    return failures, drift


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('names', nargs='*', help='corpus entry ids (default: all)')
    ap.add_argument('--record', action='store_true', help=f'write {BASE.relative_to(ROOT)}')
    ap.add_argument('--check', action='store_true', help='compare against the recorded baseline')
    ap.add_argument('--slack', type=float, default=0.10, help='metric drift allowed on the same compiler')
    ap.add_argument('--system', default=None, help='override the corpus default compile system')
    ap.add_argument('--target', default=None,
                    help='cross target (e.g. rv64): compile facts only, written to bench/pipeline-baseline-TARGET.json')
    ap.add_argument('--out', default=None, help='baseline file for --record/--check')
    a = ap.parse_args()
    if not a.record and not a.check:
        ap.error('choose --record or --check')

    corpus = json.loads(CORPUS.read_text())
    defaults = dict(corpus['defaults'])
    entries = corpus['entries']
    if a.names:
        known = {e['id'] for e in entries}
        unknown = [n for n in a.names if n not in known]
        if unknown:
            ap.error(f'unknown corpus entries: {", ".join(unknown)}')
        entries = [e for e in entries if e['id'] in a.names]
    system = a.system or defaults['system']
    out = Path(a.out) if a.out else (BASE.with_name(f'pipeline-baseline-{a.target}.json') if a.target else BASE)
    fresh = record(entries, defaults, system, a.target)

    if a.record:
        if a.names and not a.out:
            ap.error('--record writes the whole corpus; partial recordings would silently drop entries')
        out.write_text(json.dumps(fresh, indent=1, sort_keys=True) + '\n')
        shown = out.relative_to(ROOT) if out.resolve().is_relative_to(ROOT) else out
        print(f'recorded {len(fresh["entries"])} entries to {shown} on {fresh["host"]}')
        return 0

    if not out.exists():
        sys.exit(f'no baseline at {out}; run --record first')
    baseline = json.loads(out.read_text())
    if baseline.get('host') != fresh['host']:
        print(f'note: baseline host {baseline.get("host")} differs from {fresh["host"]}: reporting only')
    same = baseline.get('compiler_sha256') == fresh['compiler_sha256']
    failures, drift = compare(baseline, fresh, a.slack, same and baseline.get('host') == fresh['host'], bool(a.names))
    for line in drift:
        print(f'drift: {line}')
    if not same:
        print('note: compiler binary changed; behaviour still must match, code and allocation metrics are not gated')
    for line in failures:
        print(f'FAIL: {line}')
    print('unverified targets (reported, never passed):')
    for line in fresh['unverified']:
        print(f'  - {line}')
    if failures:
        return 1
    what = (f'{len(fresh["entries"])} {a.target} compile recordings hold' if a.target
            else f'{len(fresh["entries"])} behaviour contracts hold')
    print(f'pipeline baseline: {what}' + ('' if drift else ', no metric drift'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
