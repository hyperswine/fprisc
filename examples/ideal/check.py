#!/usr/bin/env python3
"""Behavior comparisons and refused contracts for the ideal example collection.
Run from any directory: python3 examples/ideal/check.py. No interactive UI needed.
"""
from pathlib import Path
import hashlib
import json
import os
import queue
import subprocess
import tempfile
import threading
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
IDEAL = ROOT / 'examples' / 'ideal'
ENV = dict(os.environ)


def run(args, *, cwd=ROOT, ok=True, timeout=90):
    p = subprocess.run(list(map(str, args)), cwd=cwd, env=ENV,
                       capture_output=True, text=True, timeout=timeout)
    if ok and p.returncode:
        raise AssertionError(f'{args}: exit {p.returncode}\n{p.stdout}{p.stderr}')
    return p


def build(src, dest, *flags, ok=True):
    return run([ROOT / 'fpr', 'build', src, '-o', dest, *flags], ok=ok)


def harness(tmp, name, body, *, ok=True, unsafe=False):
    src = tmp / (name + '.fpr')
    src.write_text(('unsafe base.\n' if unsafe else 'profile base.\n') + body)
    exe = tmp / name
    build(src, exe)
    return run([exe], cwd=tmp, ok=ok)


def request(port, method, path, body=None):
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=body, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as e:
        response = e
    with response:
        return response.status, response.read()


def service(exe, tmp):
    # stdout is line-buffered by the runtime; wait for the actual bound port.
    with (tmp / (exe.name + '.stderr')).open('w') as err:
        proc = subprocess.Popen([str(exe), '--port=0', '--workers=2'], cwd=tmp,
                                env=ENV, stdout=subprocess.PIPE, stderr=err, text=True)
        ready = queue.Queue()
        threading.Thread(target=lambda: ready.put(proc.stdout.readline()), daemon=True).start()
        try:
            line = ready.get(timeout=15)
            assert line.startswith('ready '), (line, (tmp / (exe.name + '.stderr')).read_text())
            port = int(line.split()[1])
            replies = [request(port, 'GET', '/kv/missing'),
                       request(port, 'PUT', '/kv/greeting', b'hello'),
                       request(port, 'GET', '/kv/greeting'),
                       request(port, 'GET', '/keys'),
                       request(port, 'PUT', '/kv/', b'bad'),
                       request(port, 'GET', '/absent'),
                       request(port, 'PATCH', '/kv/greeting', b'bad'),
                       request(port, 'POST', '/digests', b'alpha\nbeta\n'),
                       request(port, 'POST', '/shutdown')]
            proc.wait(timeout=15)
            assert proc.returncode == 0, proc.returncode
            assert [r[0] for r in replies] == [404, 201, 200, 200, 404, 404, 405, 200, 200]
            assert replies[2][1] == b'hello'
            assert json.loads(replies[3][1]) == ['greeting']
            assert replies[7][1] == ('\n'.join(hashlib.sha256(x).hexdigest() for x in [b'alpha', b'beta']) + '\n').encode()
            return replies
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
            proc.stdout.close()


def check(tmp):
    ENV['XDG_CACHE_HOME'] = str(tmp / 'cache')
    bins = {}
    for name in ['wc', 'report', 'todo', 'service', 'measure', 'pipeline', 'buffer', 'transitions']:
        exe = tmp / ('ideal-' + name)
        p = build(IDEAL / (name + '.fpr'), exe, '--cost')
        bins[name] = exe
        if name in ['measure', 'pipeline', 'todo', 'transitions']:
            assert 'PROVEN' in p.stdout and 'UNPROVED' not in p.stdout, p.stdout
    print('eight ideal programs build; their declared bounds are proven', flush=True)

    # File tool: empty, CRLF, Unicode, multiple inputs and a missing file.
    inputs = []
    for name, text in [('empty', ''), ('words', 'one two\nthree\n'), ('utf8', 'café 世界\r\nlast')]:
        path = tmp / name
        path.write_bytes(text.encode())
        inputs.append(path)
    inputs.append(tmp / 'missing')
    old_wc = tmp / 'old-wc'
    build(ROOT / 'examples/wc.fpr', old_wc)
    a, b = [run([exe, *inputs], cwd=tmp) for exe in [old_wc, bins['wc']]]
    assert (a.stdout, a.stderr, a.returncode) == (b.stdout, b.stderr, b.returncode)
    assert run([bins['wc']], cwd=tmp).stdout == ''
    print('wc output and read failures match the original', flush=True)

    # Report: compare every document field except the clock, and console except elapsed time.
    tree = tmp / 'tree'
    tree.mkdir()
    (tree / 'a.txt').write_text('alpha')
    (tree / 'b.txt').write_text('beta')
    (tree / 'c.fpr').write_text('main = 1.')
    (tree / '.hidden').write_text('ignored')
    old_report = tmp / 'old-report'
    build(ROOT / 'examples/report.fpr', old_report)
    docs, outputs = [], []
    for index, exe in enumerate([old_report, bins['report']]):
        out = tmp / f'report-{index}.json'
        p = run([exe, tree, out], cwd=tmp)
        doc = json.loads(out.read_text())
        doc.pop('generated')
        docs.append(doc)
        outputs.append(p.stdout.splitlines()[:-1])
        assert p.stdout.splitlines()[-1].startswith(f'wrote {out} in ')
        fail = run([exe, tmp / 'missing-dir'], cwd=tmp, ok=False)
        assert fail.returncode == 1 and 'report:' in fail.stderr
        fail = run([exe, tree, tmp / 'absent' / 'out.json'], cwd=tmp, ok=False)
        assert fail.returncode == 1 and 'report:' in fail.stderr
        fail = run([exe], cwd=tmp, ok=False)
        assert fail.returncode == 2 and 'usage: report' in fail.stderr
    assert docs[0] == docs[1] and outputs[0] == outputs[1]
    assert docs[1]['files'] == 3 and docs[1]['bytes'] == 18
    print('report data, console and input/write failures match the original', flush=True)

    # Nominal Msg types differ across modules: compare observable model/command summaries.
    body = f'''O = use "{ROOT / 'examples/todo.fpr'}".
I = use "{IDEAL / 'todo.fpr'}".
Term = use "std/term".
List = use "std/list".
String = use "std/string".
kind (Term.Run _) = "run".
kind Term.Quit = "quit".
kind (Term.After _ _) = "after".
snapshot (m, cmds) = (m, List.map kind cmds).
same a b = if a == b then Unit else error "todo parity failed".
oldStep ev (m, _) = O.update ev m.
newStep ev (m, _) = I.update ev m.
checkKey key (old, new) =
  a = oldStep (Term.Key key) old;
  b = newStep (Term.Key key) new;
  _ = same (snapshot a) (snapshot b);
  _ = same (O.view (80,24) (case a of (m, _) -> m)) (I.view (80,24) (case b of (m, _) -> m));
  (a,b).
saveOld (O.Saved s) = s.
saveOld _ = error "expected Saved".
saveNew (I.Saved s) = s.
saveNew _ = error "expected Saved".
performOld (Term.Run f :: _) = saveOld (f Unit).
performOld _ = error "expected save command".
performNew (Term.Run f :: _) = saveNew (f Unit).
performNew _ = error "expected save command".
main =
  m = {{items = Nil, at = 0, draft = "", path = "todo.json", note = "", seconds = 0}};
  keys = [Term.Up, Term.Down, Term.Tab, Term.Delete, Term.Enter, Term.Char "  café😀", Term.Backspace, Term.Enter,
          Term.Char "second", Term.Enter, Term.Up, Term.Tab, Term.Down, Term.Down, Term.Delete, Term.Backspace,
          Term.Left, Term.Escape, Term.Ctrl "q"];
  pair = List.fold (fn p k -> checkKey k p) ((m,Nil),(m,Nil)) keys;
  _ = same (snapshot (O.update (Term.Msg (O.Saved "failed")) m)) (snapshot (I.update (Term.Msg (I.Saved "failed")) m));
  _ = same (snapshot (O.update (Term.Msg O.Second) m)) (snapshot (I.update (Term.Msg I.Second) m));
  _ = same (snapshot (O.update (Term.Resized 100 40) m)) (snapshot (I.update (Term.Resized 100 40) m));
  _ = same (O.dropLastChar "😀") (I.dropLastChar "😀");
  _ = same (O.dropLastChar "") (I.dropLastChar "");
  a = O.update (Term.Key (Term.Char "persist")) m;
  b = I.update (Term.Key (Term.Char "persist")) m;
  ac = case a of (x, _) -> case O.update (Term.Key Term.Enter) x of (_, cmds) -> cmds;
  bc = case b of (x, _) -> case I.update (Term.Key Term.Enter) x of (_, cmds) -> cmds;
  _ = same (performOld ac) (performNew bc);
  bad = {{m | draft = "failure", path = "absent/todo.json"}};
  af = case O.update (Term.Key Term.Enter) bad of (_, cmds) -> performOld cmds;
  bf = case I.update (Term.Key Term.Enter) bad of (_, cmds) -> performNew cmds;
  _ = same af bf;
  _ = if String.startsWith "NOT saved:" bf then Unit else error "save failure was hidden";
  print "todo parity holds".
'''
    p = harness(tmp, 'todo-parity', body, unsafe=True)
    assert p.stdout == 'todo parity holds\n'
    assert json.loads((tmp / 'todo.json').read_text()) == [{'text': 'persist', 'done': False}]
    old_todo = tmp / 'old-todo'
    build(ROOT / 'examples/todo.fpr', old_todo)
    broken = tmp / 'broken.json'
    broken.write_text('not JSON')
    for exe in [old_todo, bins['todo']]:
        p = run([exe, broken], cwd=tmp, ok=False)
        assert p.returncode == 1 and 'todo:' in p.stderr
    print('todo event trace, rows, UTF-8 backspace, save success/failure and corrupt input match', flush=True)

    old_service = tmp / 'old-service'
    build(ROOT / 'examples/service.fpr', old_service)
    assert service(old_service, tmp) == service(bins['service'], tmp)
    for exe in [old_service, bins['service']]:
        for args in [['--workers=0'], ['--port=65536']]:
            p = run([exe, *args], cwd=tmp, ok=False)
            assert p.returncode == 2 and 'service: configuration:' in p.stderr
    print('service live HTTP routes, store, digests, shutdown and invalid configuration match', flush=True)

    # The native baseline returns a string; the ideal script prints that value.
    assert run([bins['measure']]).stdout == 'measure: 10 120 55 (zero unsafe markers)\n'
    p = harness(tmp, 'measure-parity', f'''O = use "{ROOT / 'tests/measure.fpr'}".
I = use "{IDEAL / 'measure.fpr'}".
main = if O.main == "measure: {{I.lsum [1,2,3,4] 0}} {{I.fact 5 1}} {{I.sumTo 10 1 0}} (zero unsafe markers)" then print "measure parity holds" else error "measure parity failed".
''')
    assert p.stdout == 'measure parity holds\n'
    old_pipeline = tmp / 'old-pipeline'
    build(ROOT / 'tests/cases/bound_pipeline.fpr', old_pipeline)
    assert run([bins['pipeline']]).stdout == run([old_pipeline]).stdout == '110\n'

    p = harness(tmp, 'buffer-parity', f'O = use "{ROOT / "tests/linpap.fpr"}".\nmain = print O.main.\n')
    assert p.stdout == run([bins['buffer']]).stdout == 'linpap: x=5 y=10 z=108\n'
    # Independent arithmetic reference, including empty and singleton carriers.
    cases = [(n, factor) for n in [0, 1, 2, 10, 64] for factor in [-3, 0, 5]]
    body = f'M = use "{IDEAL / "buffer.fpr"}".\nmain =\n'
    body += ''.join(f'  _ = print (M.build {n} |> M.evenOnly |> M.scale ({factor}) |> M.total);\n' for n, factor in cases)
    body += '  Unit.\n'
    p = harness(tmp, 'buffer-compute', body)
    assert [int(x) for x in p.stdout.splitlines()] == [sum(x * f for x in range(1, n + 1) if x % 2 == 0) for n, f in cases]

    # Compare every transition with the original and an independent state trace.
    events = [('Increment', 30), ('Increment', 40), ('Decrement', 25),
              ('Increment', 0), ('Decrement', -7), ('Decrement', 200),
              ('Reset', None), ('Increment', 7)]
    body = f'O = use "{ROOT / "tests/precond.fpr"}".\nI = use "{IDEAL / "transitions.fpr"}".\nmain =\n  o0 = {{amount = 50, hist = 0}}; i0 = {{amount = 50, hist = 0}};\n'
    expected = []
    amount, hist = 50, 0
    for j, (kind, n) in enumerate(events, 1):
        event = kind if n is None else f'{kind} ({n})'
        body += f'  o{j} = O.update (O.{event}) o{j-1}; i{j} = I.update (I.{event}) i{j-1};\n'
        body += f'  _ = print "{{o{j}.amount}},{{o{j}.hist}}|{{i{j}.amount}},{{i{j}.hist}}";\n'
        if kind == 'Reset': amount, hist = 0, hist + 1
        elif n > 0:
            amount = min(100, amount + n) if kind == 'Increment' else max(0, amount - n)
            hist += 1
        expected.append(f'{amount},{hist}|{amount},{hist}')
    body += '  replayed = I.replay [I.Increment 30, I.Increment 40, I.Decrement 25] {amount = 50, hist = 0};\n  print "replayed={replayed.amount},{replayed.hist}".\n'
    p = harness(tmp, 'transitions-parity', body)
    assert p.stdout.splitlines() == expected + ['replayed=75,3'], p.stdout
    assert run([bins['transitions']]).stdout == 'transitions: amount=75,7 hist=5 avg=30,0\n'
    print('linear buffer parity and map/filter/fold; guarded transitions and measured replay agree with independent references', flush=True)

    for name, expression in [('negative-count', 'build (-1)'), ('large-count', 'build 4097'), ('negative-index', 'peek (-1) (M.build 2)')]:
        p = harness(tmp, name, f'M = use "{IDEAL / "buffer.fpr"}".\nmain = M.{expression}.\n', ok=False)
        assert p.returncode != 0 and 'precondition violated:' in p.stdout + p.stderr, p.stdout + p.stderr
    p = harness(tmp, 'bad-transition', f'M = use "{IDEAL / "transitions.fpr"}".\nmain = print (M.bump 0 {{amount = 10, hist = 0}}).\n', ok=False)
    assert p.returncode != 0 and 'precondition violated: addAmount' in p.stdout + p.stderr, p.stdout + p.stderr
    for name, body in [
        ('owner-reuse', 'main = s = M.build 10; _ = M.finish s; M.finish s.'),
        ('owner-alias', 'main = s = M.build 10; (x, next) = M.peek 0 s; _ = M.finish s; M.finish next.')]:
        src = tmp / (name + '.fpr')
        src.write_text(f'profile base.\nM = use "{IDEAL / "buffer.fpr"}".\n' + body + '\n')
        p = build(src, tmp / name, ok=False)
        assert p.returncode != 0 and 'linear variable' in p.stdout + p.stderr and 'used 2 time(s)' in p.stdout + p.stderr, p.stdout + p.stderr
    for name, module, old, new, needle in [
        ('bad-buffer-descent', 'buffer', 'buildGo (n - 1)', 'buildGo n', 'measure does not decrease'),
        ('bad-replay-descent', 'transitions', 'replay rest (update', 'replay events (update', 'measure does not decrease'),
        ('bad-replay-bound', 'transitions', '31 * len events + 31', '1', 'OVER')]:
        src = tmp / (name + '.fpr')
        source = (IDEAL / (module + '.fpr')).read_text()
        assert old in source
        src.write_text(source.replace(old, new))
        p = build(src, tmp / name, ok=False)
        assert p.returncode != 0 and needle in p.stdout + p.stderr, p.stdout + p.stderr
    print('linear reuse/aliasing, broken buffer contracts, nondecreasing replay/build and insufficient replay bounds are refused', flush=True)

    # Refuse broken guarantees, rather than just displaying happy-path syntax.
    for name, module, expression in [
        ('column', 'wc', 'column 0 1'), ('kib', 'report', 'kib (-1)'),
        ('selection', 'todo', 'selection (-1) 0'), ('fact', 'measure', 'fact (-1) 1'),
        ('digests', 'service', 'digests 0 "alpha"')]:
        p = harness(tmp, 'bad-' + name, f'M = use "{IDEAL / (module + ".fpr")}".\nmain = print (M.{expression}).\n', ok=False)
        assert p.returncode != 0 and 'precondition violated:' in p.stdout + p.stderr, p.stdout + p.stderr
    for name, old, new, needle in [
        ('bad-bound', '19 * len xs + 27', '1', 'OVER'),
        ('bad-measure', 'factGo (n - 1)', 'factGo n', 'measure does not decrease')]:
        src = tmp / (name + '.fpr')
        source = IDEAL / ('pipeline.fpr' if name == 'bad-bound' else 'measure.fpr')
        assert old in source.read_text()
        src.write_text(source.read_text().replace(old, new))
        p = build(src, tmp / name, ok=False)
        assert p.returncode != 0 and needle in p.stdout + p.stderr, p.stdout + p.stderr
    print('five violated preconditions panic; insufficient work and nondecreasing recursion are refused', flush=True)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='fpr-ideal-') as directory:
        check(Path(directory))
    print('ideal examples: all checks passed')
