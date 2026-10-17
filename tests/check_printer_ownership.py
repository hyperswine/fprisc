#!/usr/bin/env python3
"""Linear printer APIs, bounded native buffers and proof/refusal cases.
Only disposable local resources. Native buffers are tested on one/four harts.
"""
from pathlib import Path
import os
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-printer-ownership-') as directory:
    tmp = Path(directory)
    env = {**os.environ, 'FPR_HOME': str(ROOT),
           'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache'))}
    def run(args, code=0, extra=None):
        p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env | (extra or {}),
                           capture_output=True, text=True, timeout=240)
        assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
        return p.stdout + p.stderr
    binary = tmp / 'owners'
    run([ROOT / 'fpr', 'build', 'tests/printerownership.fpr', '-o', binary])
    for harts in ('1', '4'):
        out = run([binary], extra={'FPR_HARTS': harts})
        assert out.count('release\n') == 6, out
        assert 'actor death PASS' in out, out
        print(harts + ' hart(s): ' + out.splitlines()[-1], flush=True)

    imports = '''unsafe base.
FB = use "examples/printer-dashboard/framebuffer".
OT = use "std/ownedtransport".
MQ = use "std/ownedmqtt".
'''
    failures = {
        'frame-double-close': 'bad : FB.Buffer -> Unit.\nbad b = a = FB.close b; c = FB.close b; Unit.',
        'frame-lost': 'bad : FB.Buffer -> Unit.\nbad b = Unit.',
        'frame-stale-append': 'bad : FB.Buffer -> Unit.\nbad b = (r, next) = FB.append "x" b; a = FB.close next; c = FB.close b; Unit.',
        'frame-discard-successor': 'bad : FB.Buffer -> Unit.\nbad b = (r, _) = FB.append "x" b; Unit.',
        'frame-closure-reuse': 'bad : FB.Buffer -> Unit.\nbad b = f = fn u -> FB.close b; a = f Unit; c = f Unit; Unit.',
        'frame-discard-opening': 'bad u = case FB.open 4 of FB.Opened _ -> Unit | FB.Refused _ -> Unit.',
        'connection-double-close': 'bad : OT.Connection s -> Unit.\nbad c = a = OT.close c; b = OT.close c; Unit.',
        'connection-discard-opening': 'bad c = case c of OT.Opened _ -> Unit | OT.OpenFailed _ -> Unit.',
        'connection-lost-on-error': 'bad : OT.Connection s -> Unit.\nbad c = (r, next) = OT.readSome (T.Uncancelled 100) 1 c; case r of Err _ -> Unit | Ok _ -> a = OT.close next; Unit.',
        'mqtt-double-close': 'bad c = a = MQ.close c; b = MQ.close c; Unit.',
        'mqtt-discard-successor': 'bad c = (r, _) = MQ.next (T.Uncancelled 100) c; Unit.',
        'mqtt-reuse-after-stop': 'bad c = a = MQ.stop (T.Uncancelled 100) c; b = MQ.close c; Unit.',
    }
    for name, body in failures.items():
        source = tmp / (name + '.fpr')
        source.write_text(imports + 'T = use "std/transport".\n' + body + '\nmain = Unit.\n')
        out = run([ROOT / 'fpr', 'build', source, '-o', tmp / name], 1)
        assert 'LINEARITY: ERRORS' in out, (name, out)
    print(str(len(failures)) + ' lost/stale/duplicated connection, client and buffer owners refused', flush=True)
    core = ROOT / 'examples/printer-dashboard/resourcecore.fpr'
    proof = tmp / 'proof.fpr'
    proof.write_text(core.read_text() + '\nmain = Unit.\n')
    report = run([ROOT / 'fpr', 'build', '--cost', proof, '-o', tmp / 'core'])
    assert report.count('PROVEN') == 8 and 'UNPROVED' not in report, report
    for name, value in [('remaining', 4), ('readSize', 3), ('chunks', 3), ('backoff', 4)]:
        assert name + ': declared work <= ' + str(value) in report, report
    source = tmp / 'core-oracle.fpr'
    source.write_text('''profile base.
R = use "examples/printer-dashboard/resourcecore".
main = print (R.remaining 4194304 4194304, R.remaining 4 4194304, R.readSize 4194304, R.chunks 4194304, R.backoff 15999, R.backoff 30000).
''')
    run([ROOT / 'fpr', 'build', source, '-o', tmp / 'oracle'])
    assert run([tmp / 'oracle']).strip() == '(0, 0, 16384, 256, 30000, 30000)'
    rng = random.Random(20261017)
    rows = [(4, 0, 4, 1000), (4194304, 4194304, 4194304, 30000),
            (4, 4194304, 16385, 15000)]
    rows += [(rng.randint(4, 4194304), rng.randint(0, 4194304),
              rng.randint(4, 4194304), rng.randint(1000, 30000)) for _ in range(300)]
    source.write_text('''profile base.
R = use "examples/printer-dashboard/resourcecore".
L = use "std/list".
emit (capacity, used, size, backoff) = print (R.remaining capacity used, R.readSize size, R.chunks size, R.backoff backoff).
main = L.fold (fn u row -> emit row) Unit ''' + str(rows).replace(' ', '') + '.\n')
    run([ROOT / 'fpr', 'build', source, '-o', tmp / 'oracle'])
    expected = [str((max(0, c-u), min(n, 16384), (n+16383)//16384, min(2*ms, 30000)))
                for c, u, n, ms in rows]
    assert run([tmp / 'oracle']).splitlines() == expected
    print('eight scalar work/allocation bounds PROVEN; maximum frame/read/chunk arithmetic agrees', flush=True)
    for name, text in [('too-little-work', core.read_text().replace('work chunks <= 3', 'work chunks <= 2')),
                       ('too-little-allocation', imports + 'rewrap : FB.Buffer -> FB.Buffer | alloc rewrap <= 15.\nrewrap b = FB.Buffer id = b; FB.Buffer id.\n')]:
        source = tmp / (name + '.fpr')
        source.write_text(text + '\nmain = Unit.\n')
        out = run([ROOT / 'fpr', 'build', source, '-o', tmp / name], 1)
        assert 'COST: ERRORS' in out and 'OVER' in out, (name, out)
    print('insufficient work and owner-cell allocation budgets refused', flush=True)
    print(str(len(rows)) + ' independent capacity/chunk/backoff reference cases agree', flush=True)
