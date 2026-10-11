#!/usr/bin/env python3
"""Value-state turn regions, mutable-state refusals, and cancellation."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-loop-state-') as directory:
    out = Path(directory)

    def build(source, name):
        exe = out / name
        p = subprocess.run([str(ROOT/'fpr'), 'build', str(source), '--harts', '4', '-o', str(exe)],
                           cwd=ROOT, capture_output=True, text=True, timeout=180)
        assert p.returncode == 0, p.stdout + p.stderr
        return exe

    exe = build(ROOT/'tests/base/loopstate.fpr', 'loopstate')
    for harts in (1, 4):
        p = subprocess.run([exe], env={**os.environ, 'FPR_HARTS': str(harts), 'FPR_HEAP_MB': '64'},
                           capture_output=True, text=True, timeout=120)
        assert p.returncode == 0, (harts, p.stdout, p.stderr)
        assert p.stdout == 'loopstate: one million turns bounded; caller and captured state survive\n', p.stdout
    print('Sys.loop: one million value-state turns, 64 MiB heap, one/four harts PASS')

    src = out / 'handle.fpr'
    src.write_text('''unsafe base.
worker boss self =
  message = receive self;
  _ = send boss message;
  _ = drop message;
  Unit.
step handle = (False, handle).
main =
  me = myself 0;
  a = spawn (worker me);
  b = Sys.loop a step;
  c = Sys.arena (fn u -> b);
  _ = if a == b and b == c then Unit else error "actor handle changed";
  _ = send c 42;
  result = receiveFrom me a;
  _ = drop result;
  _ = if result == 42 then Unit else error "actor handle no longer live";
  print "loop handle: identity and actor preserved".
''')
    exe = build(src, 'handle')
    for harts in (1, 4):
        p = subprocess.run([exe], env={**os.environ, 'FPR_HARTS': str(harts)},
                           capture_output=True, text=True, timeout=30)
        assert p.returncode == 0 and p.stdout == 'loop handle: identity and actor preserved\n', (harts, p.stdout, p.stderr)
    print('Sys.loop / Sys.arena bare actor handle: identity and liveness PASS')

    exe = build(ROOT/'tests/base/scopecancel.fpr', 'scopecancel')
    for harts in (1, 4):
        p = subprocess.run([exe], env={**os.environ, 'FPR_HARTS': str(harts), 'FPR_HEAP_MB': '64'},
                           capture_output=True, text=True, timeout=120)
        assert p.returncode == 0, (harts, p.stdout, p.stderr)
        assert p.stdout == 'scopecancel: nested scratch and transferred state reclaimed on kill\n', p.stdout
    print('Nested Sys.arena / Sys.loop / Sys.loopWith cancellation: one/four harts PASS')

    refusals = {
        'initial-vector': ('step s = (False, s).\nmain = _ = Vec.free (Sys.loop (Vec.iota 2) step); Unit.\n',
                           'Sys.loop: the state may not hold a Vector'),
        'captured-vector': ('step v s = _ = Vec.free v; (False, s).\nmain = print (str (Sys.loop 0 (step (Vec.iota 2)))).\n',
                            'Sys.loop: the callback may not capture a Vector'),
        'returned-vector': ('step s =\n  me = myself 0;\n  _ = send me (Vec.iota 2);\n  m = receiveFrom me me;\n  v = keep m;\n  _ = drop m;\n  (False, v).\nmain = print (str (Sys.loop 0 step)).\n',
                            'Sys.loop: the state may not hold a Vector'),
    }
    for name, (body, reason) in refusals.items():
        src = out / (name + '.fpr')
        src.write_text('unsafe base.\n' + body)
        exe = build(src, name)
        p = subprocess.run([exe], capture_output=True, text=True, timeout=10)
        assert p.returncode != 0 and reason in p.stdout+p.stderr, (name, p.stdout, p.stderr)
        print(f'Sys.loop {name}: named refusal PASS')
