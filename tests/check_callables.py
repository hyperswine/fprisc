#!/usr/bin/env python3
"""Analysis-only callable reports: warm/cold code identity and snapshot freshness."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COMPILER = ROOT / 'fpr'

def compile_source(source, out, env, *flags, ok=True):
    p = subprocess.run([str(COMPILER), 'compile', *([] if '--target=rv32' in flags else ['--system=posix']), *flags, str(source), str(out)],
                       cwd=ROOT, env=env, text=True, capture_output=True, timeout=120)
    assert (p.returncode == 0) == ok, p.stdout + p.stderr
    reports = [json.loads(line) for line in p.stderr.splitlines() if line.startswith('{"callableVersion"')]
    return p, reports

def code(out):
    units = Path(str(out) + '.units')
    return (out.read_bytes(), [(Path(p).name, Path(p).read_bytes()) for p in units.read_text().splitlines()])

with tempfile.TemporaryDirectory(prefix='fpr-callables-') as directory:
    tmp = Path(directory)
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'))
    (tmp / 'one.fpr').write_text('inc x = x + 1.\n')
    (tmp / 'two.fpr').write_text('inc x = x + 2.\n')
    source = tmp / 'main.fpr'
    source.write_text('''A = use "./one".
B = use "./two".
choose flag = if flag then A.inc else B.inc.
add n x = n + x.
partial n = add n.
captured n = fn x -> x + n.
twice f x = f (f x).
main = print (twice (choose True) 3 + (partial 4) 5 + (captured 2) 6).
''')
    for target in [[], ['--target=rv32']]:
        for mode in [[], ['--no-inline']]:
            plain = tmp / 'plain.s'
            flagged = tmp / 'flagged.s'
            p, reports = compile_source(source, plain, env, *target, *mode)
            assert not reports
            original = code(plain)
            p, reports = compile_source(source, flagged, env, *target, *mode, '--callables=json')
            assert code(flagged) == original, 'diagnostic changes assembly or unit cache identity'
            assert len(reports) == 1
            report = reports[0]
            assert report['callableVersion'] == 1
            assert report['status'] == 'fixed-point', report['status']
            assert report['counts']['FunctionReference'] > 0
            assert report['counts']['ClosureConstruction'] > 0
            assert report['counts']['BoundaryApplication'] > 0
            assert re.search(r'^apply root: dispatch=\d+ known-partial=\d+ static-descriptors=\d+$', p.stderr, re.M)
            assert report['machinePAPCounts'].startswith('see per-unit')
            assert any(s['captures'] for s in report['summaries'])
            assert any(s['source'].get('file', '').endswith('main.fpr') for s in report['sites'])
            p, warm = compile_source(source, flagged, env, *target, *mode, '--callables=json')
            assert warm == reports, 'warm cache changed typed evidence'
            assert code(flagged) == original
            # A second cold cache must retain the same report and generated units.
            cold = dict(env, XDG_CACHE_HOME=str(tmp / ('cold-' + '-'.join(target + mode))))
            _, cold_report = compile_source(source, flagged, cold, *target, *mode, '--callables=json')
            assert cold_report == reports
            assert code(flagged) == original
            print('callables: same assembly/unit keys and report cold/warm', target, mode, flush=True)
    out = tmp / 'edited.s'
    _, before = compile_source(source, out, env, '--no-inline', '--callables=json')
    imported = [s for s in before[0]['summaries'] if s['source'].get('file', '').endswith(('one.fpr', 'two.fpr')) and s['target']['kind'] == 'root']
    assert len({s['target']['identity'] for s in imported}) >= 2
    stat = (tmp / 'two.fpr').stat()
    (tmp / 'two.fpr').write_text('inc x = x + 3.\n')
    os.utime(tmp / 'two.fpr', ns=(stat.st_atime_ns, stat.st_mtime_ns))
    _, after = compile_source(source, out, env, '--no-inline', '--callables=json')
    assert before[0]['snapshot'] != after[0]['snapshot'], 'dependency change reused old analysis'
    p, rows = compile_source(source, out, env, '--callables')
    assert not rows and 'callables v1:' in p.stderr
    p, _ = compile_source(source, out, env, '--callables=typo', ok=False)
    assert 'expects summary or json' in p.stderr
    p, _ = compile_source(source, out, env, '--check-only', '--callables=json', ok=False)
    assert 'requires native compilation' in p.stderr
print('Callable census: opt-in, cold/warm identity, host/RV32, inline modes, imports and dependency invalidation PASS')
