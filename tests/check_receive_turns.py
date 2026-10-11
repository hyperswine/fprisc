#!/usr/bin/env python3
"""Automatic receive turns: state, strictness, refusal boundaries and caches."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_RECEIVE_NOTES':'1'}
with tempfile.TemporaryDirectory(prefix='fpr-receive-turns-') as directory:
    out = Path(directory)
    def build(source, name, extra_env=None, flags=()):
        exe = out/name
        p = subprocess.run([str(ROOT/'fpr'),'build',str(source),'--harts','4',*flags,'-o',str(exe)],
                           cwd=ROOT,env={**ENV,**(extra_env or {})},capture_output=True,text=True,timeout=180)
        assert p.returncode == 0, p.stdout+p.stderr
        return exe,p.stdout+p.stderr
    def run(exe, harts=4):
        return subprocess.run([exe],env={**os.environ,'FPR_HARTS':str(harts),'FPR_HEAP_MB':'64'},
                              capture_output=True,text=True,timeout=120)
    def source(name, body):
        p=out/(name+'.fpr');p.write_text('unsafe base.\n'+body);return p

    exe, notes = build(ROOT/'tests/base/receiveturns.fpr','stress')
    assert 'turn: automatic value-state turn regions' in notes, notes
    for h in (1,4):
        p=run(exe,h)
        assert p.returncode == 0 and 'one million ordinary recursive receives bounded' in p.stdout,(h,p.stdout,p.stderr)
    print('automatic receive turns: million messages, one/four harts, 64 MiB PASS')
    for no_inline in (False, True):
        exe, notes = build(ROOT/'tests/base/receivecoverage.fpr', 'coverage'+str(no_inline),
                           {'FPR_NO_INLINE': str(int(no_inline))})
        for name in ('zero', 'clauses', 'patterns', 'dead', 'forwardLeft', 'inside', 'temporary'):
            assert any(name in line.split(': ')[1].split() and 'automatic value-state' in line
                       for line in notes.splitlines() if line.startswith('receive-turns: ')), notes
        for h in (1, 4):
            p = run(exe, h)
            assert p.returncode == 0 and 'temporary ownership HOLDS' in p.stdout, (h, p.stdout, p.stderr)
    print('automatic receive turns: zero args, shared joins, dead state and strict effects PASS')
    exe, notes = build(ROOT/'tests/base/mvutextmemory.fpr', 'text-memory')
    assert any('trLoop@' in line and 'automatic value-state turn regions' in line
               for line in notes.splitlines()), notes
    for h in (1, 4):
        p = run(exe, h)
        assert p.returncode == 0 and 'received roots released HOLDS' in p.stdout, (h, p.stdout, p.stderr)
    print('automatic receive turns: concrete MVU text protocol and root ownership PASS')
    exe, notes = build(ROOT/'tests/base/mvueventports.fpr', 'event-ports')
    assert any('eventPortsAcc@' in line and 'automatic value-state turn regions' in line
               for line in notes.splitlines()), notes
    for h in (1, 4):
        p = run(exe, h)
        assert p.returncode == 0 and 'multi-port batches bounded, roots released HOLDS' in p.stdout, (h, p.stdout, p.stderr)
    print('automatic receive turns: ordered typed ports, deduplication and ownership PASS')
    # Same source, separate cache identity: baseline keeps the old growing pool.
    old,_=build(ROOT/'tests/base/receiveturns.fpr','baseline',{'FPR_NO_RECEIVE_TURNS':'1'})
    p=run(old)
    assert p.returncode != 0 and 'caller heap grew' in p.stdout+p.stderr,(p.stdout,p.stderr)
    print('automatic receive turns: opt-out baseline reproduces growth PASS')

    mutual=source('mutual','''
State = Type (Carry Int String | Finish String).
right me n state =
  _ = send me state;
  message = receiveFrom me me;
  case message of
    Carry total text -> if n == 0 then text else left me (n - 1) (Carry (total + 1) "right {total}")
  | Finish text -> text.
left me n state =
  _ = send me state;
  message = receiveFrom me me;
  case message of
    Carry total text -> if n == 0 then text else right me (n - 1) (Carry (total + 1) "left {total}")
  | Finish text -> text.
arg me text n = _ = send me text; n.
ordered me n a b =
  l = receiveFrom me me;
  r = receiveFrom me me;
  _ = if l == "left" and r == "right" then Unit else error "argument effect order";
  _ = drop l;
  _ = drop r;
  if n == 0 then a + b else ordered me (n - 1) (arg me "left" (a + 1)) (arg me "right" (b + 1)).
main =
  me = myself 0;
  caller = strcat "caller" "-alive";
  result = left me 20000 (Carry 0 caller);
  _ = if result == "right 19999" and caller == "caller-alive" then Unit else error "mutual result: {result}";
  _ = send me "left";
  _ = send me "right";
  total = ordered me 1000 0 0;
  _ = if total == 2000 then Unit else error "strict arguments";
  print "mutual state, final result and strict argument order HOLDS".
''')
    for no_inline in (False,True):
        exe,notes=build(mutual,'mutual'+str(no_inline),{'FPR_NO_INLINE':str(int(no_inline))})
        assert any('left' in line and 'right' in line and 'automatic value-state turn regions' in line for line in notes.splitlines()),notes
        assert 'ordered: automatic value-state' in notes,notes
        for h in (1,4):
            p=run(exe,h)
            assert p.returncode == 0 and 'strict argument order HOLDS' in p.stdout,(no_inline,h,p.stdout,p.stderr)
    print('automatic receive turns: mutual recursion, nominal state, case branches and strictness PASS')

    # Unit codegen must transform the imported body too, and a cached unit
    # must not accidentally reuse assembly from the opt-out compilation.
    unit=source('unit','''
rpc me n = _ = send me n; receiveFrom me me.
wide me n a b c d e f g =
  got = rpc me n;
  _ = drop got;
  _ = if strlen "temporary row {n}" > 5 then Unit else error "temporary allocation";
  if n == 0 then a + b + c + d + e + f + g
  else wide me (n - 1) (a + 1) b c d e f g.
''')
    imported=source('imported','''
U = use "./unit".
main =
  before = heapUsed Unit;
  result = U.wide (myself 0) 20000 0 1 2 3 4 5 6;
  growth = heapUsed Unit - before;
  _ = if result == 20021 and growth < 4096 then Unit else error "imported wide loop: {result}, {growth}";
  print "imported arity-spilled receive loop HOLDS".
''')
    for suffix, settings in [('first',{}),('off',{'FPR_NO_RECEIVE_TURNS':'1'}),('cached',{})]:
        exe,notes=build(imported,'imported-'+suffix,settings)
        p=run(exe)
        if suffix == 'off':
            assert p.returncode != 0 and 'imported wide loop:' in p.stdout+p.stderr,(p.stdout,p.stderr)
        else:
            assert any(line.startswith('receive-turns: wide@') and line.endswith('automatic value-state turn regions') for line in notes.splitlines()),notes
            assert p.returncode == 0 and 'arity-spilled receive loop HOLDS' in p.stdout,(p.stdout,p.stderr)
    print('automatic receive turns: imported helper receives, arity spill and cache isolation PASS')

    cancel=source('cancel','''
AC = use "std/actor".
freeKiB u = case Sys.memInfo 0 of _ :: f :: _ -> f | _ -> 0.
worker boss text me =
  _ = send boss (strlen text);
  message = receiveFrom me boss;
  _ = if message == 7 then Unit else error "cancel request";
  _ = drop message;
  worker boss "next state" me.
cycles me n = if n == 0 then Unit else
  a = AC.spawnWith (AC.Dynamic 8) (worker me "initial state");
  ack = receiveFrom me a;
  _ = drop ack;
  _ = send a 7;
  next = receiveFrom me a;
  _ = drop next;
  _ = send a 7;
  final = receiveFrom me a;
  _ = drop final;
  _ = kill a;
  _ = Sys.sleepUs 1000;
  cycles me (n - 1).
main =
  me = myself 0;
  _ = cycles me 32;
  before = freeKiB Unit;
  _ = cycles me 256;
  retained = before - freeKiB Unit;
  _ = if retained < 4096 then Unit else error "automatic cancellation retained {retained} KiB";
  print "automatic cancellation HOLDS".
''')
    exe,notes=build(cancel,'cancel')
    assert 'worker: automatic value-state turn regions' in notes,notes
    for h in (1,4):
        p=run(exe,h)
        assert p.returncode == 0 and 'automatic cancellation HOLDS' in p.stdout,(h,p.stdout,p.stderr)
    print('automatic receive turns: cancellation releases transferred closures PASS')

    skips={
        'functional-result':('''loop me n = case (n, 0) of
    (0, 0) -> fn x -> x + 1
  | other -> _ = send me n; got = receiveFrom me me; _ = drop got; loop me (n - 1).
main = print (str ((loop (myself 0) 10) 4)).
''','state/result is mutable, functional'),
        'mutable':('''loop me n v =
  _ = send me n;
  got = receiveFrom me me;
  _ = drop got;
  if n == 0 then v else loop me (n - 1) v.
main = Vec.free (loop (myself 0) 10 (Vec.iota 2)).
''','state/result is mutable'),
        'non-tail':('''loop me n =
  _ = send me n;
  got = receiveFrom me me;
  _ = drop got;
  if n == 0 then 0 else 1 + loop me (n - 1).
main = print (str (loop (myself 0) 10)).
''','non-tail, partial or escaping'),
        'functional':('''loop me f n =
  _ = send me n;
  got = receiveFrom me me;
  _ = drop got;
  if n == 0 then f n else loop me f (n - 1).
main = print (str (loop (myself 0) (fn x -> x + 1) 10)).
''','state/result is mutable, functional'),
        'managed':('''loop me n =
  _ = send me n;
  got = receiveFrom me me;
  _ = drop got;
  _ = Sys.poolReset 0;
  if n == 0 then 0 else loop me (n - 1).
main = print (str (loop (myself 0) 10)).
''','explicit region management'),
    }
    for name,(body,reason) in skips.items():
        exe,notes=build(source(name,body),name)
        assert 'loop: '+reason in notes,notes
        p=run(exe)
        assert p.returncode == 0,(name,p.stdout,p.stderr)
        print('automatic receive turns:',name,'reported unchanged PASS')
