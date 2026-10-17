#!/usr/bin/env python3
"""Ownership through polymorphic functions and generic containers, in native
and HostedBytecode (docs/2026-10-17-OWNERSHIP-POLYMORPHISM.md).

A type variable is instantiated with the ownership of the value it receives,
so `identity` hands an owner back and `Box Token` unpacks to an owner; a
function that duplicates or discards a type variable may not receive an owner
there, including the std helpers that do (L.repeat, Option.withDefault,
L.length).  Tokens are integers with no resource behind them, so a
regression that slips through is safe to execute while developing the checker.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BASE = '''profile base.
Token 1 = Type (Token Int).
consume : Token -> Int.
consume owner = Token n = owner; u = print "consume {n}"; n.
'''

REFUSALS = {
    'generic-duplicate': '''
duplicate : a -> (a, a).
duplicate x = (x, x).
main = t = Token 7; (a, b) = duplicate t; print (consume a, consume b).
''',
    'generic-identity-reused': '''
identity : a -> a.
identity x = x.
main = t = Token 7; moved = identity t; print (consume moved, consume moved).
''',
    'generic-discard': '''
first : a -> b -> a.
first x y = x.
main = t = Token 7; print (first 1 t).
''',
    'generic-inferred-duplicate': '''
twin x = (x, x).
main = t = Token 7; (a, b) = twin t; print (consume a, consume b).
''',
    'box-pattern-double': '''
Box a = Type (Box a).
useBox : Box Token -> (Int, Int).
useBox box = case box of Box x -> (consume x, consume x).
main = print (useBox (Box (Token 7))).
''',
    'box-wildcard-loses-owner': '''
Box a = Type (Box a).
forget : Box Token -> Unit.
forget box = case box of Box _ -> Unit.
main = u = forget (Box (Token 7)); print "owner lost".
''',
    'box-generic-wildcard-with-owner': '''
Box a = Type (Box a).
forget : Box a -> Unit.
forget box = case box of Box _ -> Unit.
main = u = forget (Box (Token 7)); print "owner lost".
''',
    'result-pattern-double': '''
takeResult : Result Token String -> (Int, Int).
takeResult result = case result of Ok owner -> (consume owner, consume owner) | Err _ -> (0, 0).
main = print (takeResult (Ok (Token 7))).
''',
    'list-pattern-double': '''
takeTokens : List Token -> Int.
takeTokens tokens = case tokens of Nil -> 0 | owner :: Nil -> consume owner + consume owner | owner :: rest -> consume owner.
main = print (takeTokens [Token 7]).
''',
    'list-rest-dropped': '''
firstOnly : List Token -> Int.
firstOnly tokens = case tokens of Nil -> 0 | owner :: rest -> consume owner.
main = print (firstOnly [Token 7, Token 8]).
''',
    'inferred-container-return': '''
boxed u = Ok (Token 7).
main = case boxed 0 of Ok t -> print (consume t, consume t) | Err why -> print why.
''',
    'std-repeat-owner': '''
L = use "../std/list".
main = t = Token 7; print (L.length (L.repeat 2 t)).
''',
    'std-with-default-owner': '''
O = use "../std/option".
main = t = Token 7; print (consume (O.withDefault t O.None)).
''',
    'std-length-drops-owners': '''
L = use "../std/list".
main = print (L.length [Token 7]).
''',
    'linear-generic-type-owned-field-dropped': '''
Owned 1 s = Type (Owned s).
peek : Owned s -> Int.
peek owner = Owned inner = owner; 0.
main = print (peek (Owned (Token 7))).
''',
    'generic-through-generic': '''
Box a = Type (Box a).
twin : a -> (a, a).
twin x = (x, x).
twinBoxed : Box b -> (b, b).
twinBoxed (Box x) = twin x.
main = (a, b) = twinBoxed (Box (Token 7)); print (consume a, consume b).
''',
}

POSITIVES = {
    'generic-identity-once': ('''
identity : a -> a.
identity x = x.
main = t = Token 7; print (consume (identity t)).
''', 'consume 7\n7\n'),
    'generic-swap-pair': ('''
pair : a -> b -> (a, b).
pair x y = (x, y).
swap : (a, b) -> (b, a).
swap (x, y) = (y, x).
main = (n, t) = swap (pair (Token 7) 1); print (consume t + n).
''', 'consume 7\n8\n'),
    'generic-duplicate-unrestricted': ('''
duplicate : a -> (a, a).
duplicate x = (x, x).
main = (a, b) = duplicate 21; t = Token 7; print (a + b + consume t).
''', 'consume 7\n49\n'),
    'box-unpack-once': ('''
Box a = Type (Box a).
unbox : Box a -> a.
unbox (Box x) = x.
main = print (consume (unbox (Box (Token 7)))).
''', 'consume 7\n7\n'),
    'box-generic-wildcard-unrestricted': ('''
Box a = Type (Box a).
forget : Box a -> Unit.
forget box = case box of Box _ -> Unit.
main = u = forget (Box 7); t = Token 7; print (consume t).
''', 'consume 7\n7\n'),
    'result-and-option-once': ('''
O = use "../std/option".
R = use "../std/result".
main = some = O.map consume (O.Some (Token 7)) |> O.withDefault 0;
  ok = R.map consume (Ok (Token 8)) |> R.withDefault 0;
  print (some + ok).
''', 'consume 7\nconsume 8\n15\n'),
    'list-map-and-fold': ('''
L = use "../std/list".
main = sum = [Token 1, Token 2, Token 3] |> L.map consume |> L.sum;
  rev = L.reverse [Token 4, Token 5] |> L.fold (fn acc x -> acc + consume x) 0;
  print (sum, rev).
''', 'consume 1\nconsume 2\nconsume 3\nconsume 5\nconsume 4\n(6, 9)\n'),
    'list-recursion-consumes-each': ('''
drain : (tokens : List Token | measure tokens) -> Int -> Int.
drain tokens acc = case tokens of Nil -> acc | owner :: rest -> drain rest (acc + consume owner).
main = print (drain [Token 7, Token 8] 0).
''', 'consume 7\nconsume 8\n15\n'),
    'linear-generic-type-instantiates': ('''
Owned 1 s = Type (Owned s).
Stat = {hits : Int, seen : Int}.
bump : Owned Stat -> (Int, Owned Stat).
bump owner = Owned stat = owner; (stat.hits + stat.seen, Owned {stat | hits = stat.hits + 1}).
main = (n, next) = bump (Owned {hits = 1, seen = 2}); Owned final = next; print (n + final.hits).
''', '5\n'),
    'std-helpers-on-unrestricted': ('''
L = use "../std/list".
O = use "../std/option".
main = t = Token 7; print (L.length (L.repeat 2 1) + O.withDefault 5 O.None + consume t).
''', 'consume 7\n14\n'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', action='append', help='run only these cases')
    args = parser.parse_args()
    selected = set(args.case or REFUSALS.keys() | POSITIVES.keys())
    unknown = selected - REFUSALS.keys() - POSITIVES.keys()
    if unknown:
        raise SystemExit('unknown cases: ' + ', '.join(sorted(unknown)))
    count = 0
    with tempfile.TemporaryDirectory(prefix='fpr-generic-ownership-') as name:
        tmp = Path(name)
        env = {**os.environ, 'FPR_HOME': str(ROOT), 'SOL_CACHE_DIR': str(tmp / 'sol-cache'),
               'SOL_GPU': '0', 'SOL_JIT': '0',
               'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache'))}

        def invoke(command):
            return subprocess.run([str(a) for a in command], cwd=ROOT, env=env,
                                  capture_output=True, text=True, timeout=180)

        def source(name, body):
            path = tmp / (name + '.fpr')
            path.write_text(BASE + body.replace('"../std/', '"' + str(ROOT / 'std') + '/'))
            return path

        for name, body in REFUSALS.items():
            if name not in selected:
                continue
            path = source(name, body)
            for mode, command in (
                ('native', [ROOT / 'fprc', '--system=posix', '--check-only', path, '/dev/null']),
                ('Sol', [ROOT / 'fpr', 'sol', path]),
            ):
                p = invoke(command)
                output = p.stdout + p.stderr
                assert p.returncode != 0 and 'LINEARITY: ERRORS' in output, (name, mode, p.returncode, output)
                assert 'consume 7' not in p.stdout, (name, mode, p.stdout)
                count += 1
        for name, (body, expected) in POSITIVES.items():
            if name not in selected:
                continue
            path = source(name, body)
            binary = tmp / name
            p = invoke([ROOT / 'fpr', 'build', path, '-o', binary])
            assert p.returncode == 0, (name, 'build', p.stdout + p.stderr)
            p = invoke([binary])
            assert p.returncode == 0 and p.stdout == expected, (name, 'native', p.returncode, p.stdout, p.stderr)
            p = invoke([ROOT / 'fpr', 'sol', path])
            assert p.returncode == 0 and p.stdout == expected, (name, 'Sol', p.returncode, p.stdout, p.stderr)
            count += 1
    print(f'{count} generic ownership cases (polymorphic functions and containers, native and Sol) PASS')


if __name__ == '__main__':
    main()
