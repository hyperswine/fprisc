#!/usr/bin/env python3
"""C1 piece 2a, slice 1: the (tid, variant) layout table against the allocator.

Every walker in the posix runtime derives a constructor's field count from the
allocator's 16-byte preheader: nfields = (total - 16 - 8) / W, which is the
arity plus whatever rounding pad fpr_alloc zeroed.  The compiler now also emits
fpr_layout_table -- the arity per (tid, variant), record shapes included, whose
variant word is their field count.  A runtime built with FPR_LAYOUT_CHECK
compares the capacity implied by the table with the one the allocator produced,
for every object a walker sees, so the table can become the authority before the
preheader shrinks.

Per program: the check build must match the plain build's output and exit code
(no behaviour change); a build with FPR_LAYOUT_FAULT -- which adds a row of
slack to the derived size -- must panic, so the check cannot pass vacuously; and
a build with FPR_LAYOUT_REPORT must name every class the program drives through
the preheader, so a rule cannot pass by never running.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)

MESSAGES = '''List = use "std/list".
Shape = Type (Dot | Box Int Int).
Point = { x : Int, y : Int }.
area s = case s of Dot -> 0 | Box w h -> w * h .
echoShape : unsafe Int -> p36 .
echoShape me =
  m = receive me;
  case m of (replyTo, s) -> send replyTo (area s) >> echoShape me .
echoPoint : unsafe Int -> p36 .
echoPoint me =
  m = receive me;
  case m of (replyTo, p) -> send replyTo (p.x + p.y) >> echoPoint me .
echoList : unsafe Int -> p36 .
echoList me =
  m = receive me;
  case m of (replyTo, xs) -> send replyTo (List.length xs) >> echoList me .
echoAny : unsafe Int -> p36 .
echoAny me =
  m = receive me;
  case m of (replyTo, s) -> send replyTo (String.len (str s)) >> echoAny me .
main =
  me = myself 0;
  s = spawn echoShape;
  p = spawn echoPoint;
  l = spawn echoList;
  a = spawn echoAny;
  _ = send s (me, Box 3 4);
  _ = print (str (receive me));
  _ = send s (me, Dot);
  _ = print (str (receive me));
  _ = send p (me, {x = 5, y = 7});
  _ = print (str (receive me));
  _ = send l (me, List.range 1 10);
  _ = print (str (receive me));
  _ = send l (me, List.map (fn x -> x * 2) (List.range 1 5));
  _ = print (str (receive me));
  # a heap string and a capturing closure: the classes a literal cannot reach
  text = strcat "hel" "lo";
  _ = send a (me, text);
  _ = print (str (receive me));
  n = 5;
  f = (fn y -> y + n);
  _ = send a (me, f);
  print (str (receive me)).
'''

# classes each program must drive through the preheader
CLASSES = {'messages': {'constructor', 'string', 'pap'},
           'actors': {'constructor'}}


def run(args, env, timeout):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-layout-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='2')

        def source(name, text):
            path = tmp / (name + '.fpr')
            path.write_text(text)
            return path

        def build(path, name, define, cache):
            env = dict(base, XDG_CACHE_HOME=str(tmp / cache))
            if define:
                env.update(define)
            exe = tmp / name
            made = run([ROOT / 'fpr', 'build', path, '--harts', '2', '-o', exe], env, 300)
            assert made.returncode == 0, (name, made.stdout[-2000:], made.stderr[-3000:])
            return exe, env

        cases = {'messages': source('messages', MESSAGES),
                 'actors': ROOT / 'tests/actors.fpr'}
        for name, path in cases.items():
            plain, plain_env = build(path, f'{name}-plain', {}, f'cache-{name}-plain')
            check, check_env = build(path, f'{name}-check', {'FPR_LAYOUT_CHECK': '1'},
                                     f'cache-{name}-check')
            fault, fault_env = build(path, f'{name}-fault',
                                     {'FPR_LAYOUT_CHECK': '1', 'FPR_LAYOUT_FAULT': '1'},
                                     f'cache-{name}-fault')
            report, report_env = build(path, f'{name}-report',
                                       {'FPR_LAYOUT_CHECK': '1', 'FPR_LAYOUT_REPORT': '1'},
                                       f'cache-{name}-report')
            obs = [run([exe], env, 60) for exe, env in
                   ((plain, plain_env), (check, check_env))]
            assert obs[0].returncode == 0, (name, obs[0].stdout, obs[0].stderr)
            assert (obs[1].returncode, obs[1].stdout) == (obs[0].returncode, obs[0].stdout), (
                name, obs[1].returncode, obs[1].stdout, obs[1].stderr)
            watched = run([report], report_env, 60)
            verified = {line.split('verified ')[1].strip()
                        for line in (watched.stdout + watched.stderr).splitlines()
                        if '[layout] verified' in line}
            assert CLASSES[name] <= verified, (name, sorted(verified))
            broken = run([fault], fault_env, 60)
            seen = broken.stdout + broken.stderr
            assert broken.returncode != 0 and 'layout check' in seen, (
                name, broken.returncode, seen[-1500:])
            print(f'Layout table {name}: check build agrees with the allocator; '
                  f'classes {sorted(verified)}; fault injection panics PASS', flush=True)


if __name__ == '__main__':
    main()
