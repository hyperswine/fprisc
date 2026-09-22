#!/usr/bin/env python3
"""The standard library (std/*.fpr, docs/STD.md): every module, on this machine.

Each tests/std/<name>.fpr prints what it computed; tests/std/<name>.expected is
that output, reviewed by hand once.  --bless rewrites the expectations."""
import os, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
bless = '--bless' in sys.argv
subprocess.run(['make', 'fpr'], check=True, capture_output=True, timeout=600)
fpr = str(ROOT / 'fpr')
def check(name, args=(), cwd=None, label='', env=None):
    src = ROOT / 'tests' / 'std' / f'{name}.fpr'
    p = subprocess.run([fpr, 'run', str(src), *args], capture_output=True, text=True, timeout=300, cwd=cwd,
                       env=None if env is None else {**os.environ, **env})
    assert p.returncode == 0, f'{name}: exit {p.returncode}\n{p.stdout}\n{p.stderr}'
    want = src.with_suffix('.expected')
    if bless: want.write_text(p.stdout)
    assert p.stdout == want.read_text(), f'{name}: output differs from {want.name}\n{p.stdout}'
    print(f'{label}: PASS')
check('ifelse', label='if/then/else: sugar for the two-armed case -- else-if chains, block branches, names that merely start with if')
check('codec', label='@Msg and @Model.field carry enc/dec minted from the declarations: records, lists, tuples and sum types through Wire and back; bad input refused with its path')
check('foundation', label='Option, Order, Result; values print as they are written')
check('list', label='List: map/filter/fold/find/zip/group, a stable merge sort of 300,000')
check('string', label='String: split/join/trim/replace/search/slices/toInt, 1.3 MB through join and split')
check('map', label='Map and Set: a persistent AVL tree, 100,000 keys in and half out, ascending iteration')
check('json', label='Json: parse with line and column, escapes and surrogate pairs, deterministic render, a 640 KB round trip')
# the SAME module files from a Sol script (docs/WHAT_IS_SOL.md: one vocabulary)
p = subprocess.run([fpr, 'sol', str(ROOT / 'tests' / 'std' / 'solstd.sol')], capture_output=True, text=True, timeout=300)
got = [l for l in p.stdout.splitlines() if not l.startswith(('[sol]', '[table]', '[jit]'))]
assert got == ['[1, 2, 3]', 'Some 3', 'A-B--C', '[(and, 2), (bird, 1), (cat, 1), (dog, 1), (the, 3)]', '[1,{"a":null}]',
               'Err line 1, column 4: expected a value, found the end of the text'], p.stdout + p.stderr
bad = ROOT / 'tests' / 'std' / 'codec_bad.fpr'
p2 = subprocess.run([fpr, 'build', str(bad), '-o', os.devnull], capture_output=True, text=True, timeout=300)
assert p2.returncode != 0 and 'codec literal @Msg' in p2.stdout + p2.stderr, p2.stdout + p2.stderr
print('@Msg over a type with an unwireable field is a COMPILE error that says which constructor: PASS')
print('Sol runs the same std modules (list, string, map, option, order, json), and prints values as written: PASS')
p = subprocess.run([fpr, 'sol', str(ROOT / 'tests' / 'std' / 'solcodec.sol')], capture_output=True, text=True, timeout=300)
got = [l for l in p.stdout.splitlines() if not l.startswith(('[sol]', '[table]', '[jit]'))]
assert got == ['["Move",[3,"x"],[1,2]]', 'Ok Bump 41', 'Err Msg: no such message: Nope'], p.stdout + p.stderr
print('a codec literal in a Sol script: the same @Msg, the same JSON, the same refusal: PASS')
check('extbase', label='Math, Encoding (hex, Base64, URL), Binary, Digest: SHA-256 against the published vectors, incremental equals whole')
check('proclimits', label='Proc: a time limit kills the child and says so; extra environment reaches it')
check('tcp', label='Stream and Tcp: a server and its clients in ONE process, an actor per connection, 2 MB echoed, stop')
check('poller', label='receiveNow (an empty mailbox allocates nothing), receiveWithin, and a server whose accepts and reads wait on ONE poller')
check('term', label='Term.decode: text a UTF-8 character at a time, named and function keys, Ctrl and Alt, sequences split across reads')
check('http', label='Http: client and server, headers, a 100 KB POST, 404, chunked decoding, URL parsing')
with tempfile.TemporaryDirectory(prefix='fpr-std-') as t:
    check('compact', cwd=t, label='KvLog.compact: the latest of every key, the journal kept whole, written beside the log and renamed over it; the store reopens the same')
with tempfile.TemporaryDirectory(prefix='fpr-std-') as t:
    check('apps', cwd=t, env={'T16_HOST': 'from-env'}, label='Decode (errors name the path), Config (defaults < file < env < args), Log, streaming File, Task (bounded, parallel)')
with tempfile.TemporaryDirectory(prefix='fpr-std-') as t:
    tree = Path(t) / 'tree'
    (tree / 'sub' / 'deep').mkdir(parents=True)
    (tree / 'a.txt').write_text('hello\n')
    (tree / 'sub' / 'b.fpr').write_text('fn main\n')
    (tree / 'sub' / 'deep' / 'c d.fpr').write_text('x\n')
    check('posix', args=['one', 'two words'], cwd=t, label='Path, File, Dir, Proc, Program, Clock: walk, glob, create and remove, three held streams, 3.9 MB through a pipe')
    out = Path(t) / 'r.json'
    p = subprocess.run([fpr, 'run', str(ROOT / 'examples' / 'report.fpr'), 'tree', str(out)], capture_output=True, text=True, timeout=300, cwd=t)
    assert p.returncode == 0 and 'tree: 3 files' in p.stdout and '"files":3' in out.read_text(), p.stdout + p.stderr
    p = subprocess.run([fpr, 'run', str(ROOT / 'examples' / 'report.fpr'), '/no/such/dir'], capture_output=True, text=True, timeout=300)
    assert p.returncode == 1 and 'No such file or directory' in p.stderr, p.stderr
    print('examples/report.fpr, the automation acceptance program: a report and its JSON; failures said in words, exit 1: PASS')
# the concurrent-service acceptance program, driven from outside over HTTP
import threading, time, urllib.request, urllib.error
with tempfile.TemporaryDirectory(prefix='fpr-svc-') as t:
    svc = subprocess.Popen([fpr, 'run', str(ROOT / 'examples' / 'service.fpr'), '--port=0', '--workers=3'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=t)
    try:
        line = svc.stdout.readline()
        assert line.startswith('ready '), line + svc.stderr.read()
        base = f'http://127.0.0.1:{int(line.split()[1])}'
        def call(method, path, body=None):
            req = urllib.request.Request(base + path, data=body, method=method)
            try:
                with urllib.request.urlopen(req, timeout=30) as r: return r.status, r.read().decode()
            except urllib.error.HTTPError as e: return e.code, e.read().decode()
        assert call('PUT', '/kv/greeting', b'hello world') == (201, 'stored greeting\n')
        assert call('GET', '/kv/greeting') == (200, 'hello world')
        assert call('GET', '/kv/nope')[0] == 404
        threads = [threading.Thread(target=call, args=('PUT', f'/kv/k{i}', f'v{i}'.encode())) for i in range(40)]
        [x.start() for x in threads]; [x.join() for x in threads]
        import json as pyjson, hashlib
        assert len(pyjson.loads(call('GET', '/keys')[1])) == 41
        assert call('GET', '/kv/k37') == (200, 'v37')
        words = [f'word{i}' for i in range(12)]
        status, body = call('POST', '/digests', ('\n'.join(words) + '\n').encode())
        assert status == 200 and body.split() == [hashlib.sha256(w.encode()).hexdigest() for w in words], body
        assert call('POST', '/shutdown')[0] == 200
        assert svc.wait(timeout=20) == 0
        err = svc.stderr.read()
        assert 'WARN  request failed' in err and 'stopped keys=41' in err, err
    finally:
        if svc.poll() is None: svc.kill()
    p = subprocess.run([fpr, 'run', str(ROOT / 'examples' / 'service.fpr'), '--port=99999'], capture_output=True, text=True, timeout=300, cwd=t)
    assert p.returncode == 2 and 'port: must be 0..65535' in p.stderr, p.stderr
    print('examples/service.fpr, the concurrent-service acceptance program: typed config, one actor owns the store, 40 parallel writes, parallel digests, logged failures, clean shutdown: PASS')
# a terminal application, through a real pseudo-terminal
with tempfile.TemporaryDirectory(prefix='fpr-tui-') as t:
    p = subprocess.run([sys.executable, str(ROOT / 'tests' / 'std' / 'todo_pty.py'), fpr, str(ROOT / 'examples' / 'todo.fpr'), str(Path(t) / 'todo.json')],
                       capture_output=True, text=True, timeout=300)
    assert p.returncode == 0 and '"buy milk"' in p.stdout, p.stdout + p.stderr
    print('examples/todo.fpr, a terminal app: raw-mode keys (UTF-8 text, arrows, Tab, Delete), a resize, a subscription, a durable list through a minted codec, the terminal put back: PASS')
# a live web app, driven over its websocket the way a browser drives it
with tempfile.TemporaryDirectory(prefix='fpr-live-') as t:
    p = subprocess.run([sys.executable, str(ROOT / 'tests' / 'std' / 'logbook_ws.py'), fpr, str(ROOT / 'examples' / 'logbook.fpr'), str(Path(t) / 'log.kvlog')],
                       capture_output=True, text=True, timeout=600)
    assert p.returncode == 0 and p.stdout.strip() == 'ok', p.stdout + p.stderr
    print('examples/logbook.fpr, a live web app: two tabs on one model, each with its own search and page; add/edit/delete stamped by the clock; the edit form filled through the JS port; killed, replayed from the journal, restarted from the fields: PASS')
