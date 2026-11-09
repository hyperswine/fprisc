#!/usr/bin/env python3
"""Closures and partial applications that hold an owner are single-use.

Covers the callable cases of the ownership audit
(tools/audit_linear_ownership.py; docs/2026-11-09-CALLABLE-OWNERSHIP.md):
a linear capture reaching a higher-order parameter, a returned closure, a
partial application through an alias, and a partial application of a
dynamically chosen function; and the neighbouring forms found while
closing them: function types nested in parameters and results, lambda-bodied
definitions, closures over an owner the callee made itself, function-typed
constructor fields, and the HostedBytecode list schemes. Each refusal has a legal single-use twin that
must still build and run identically in native and HostedBytecode.

The compiler must already be built. Tokens are immutable integers with no
external resource or destructor, so a regression is safe to execute.
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

AT = '''at : Token -> Int -> Int.
at t n = consume t + n.
'''
TWICE = '''twice : (Int -> Int) -> (Int, Int).
twice f = (f 0, f 1).
'''
ONCE = '''once : (Int -> Int) -> Int.
once f = f 1.
'''
MAKE = '''make : Token -> (Int -> Int).
make t = fn n -> consume t + n.
'''
PAIR = '''pair : Token -> ((Int -> Int), Int).
pair t = (fn n -> consume t + n, 0).
'''
DUP = '''dup : ((Int -> Int), Int) -> Int.
dup p = (g, k) = p; g k + g k.
'''
SELF = '''mk : Int -> (Int -> Int).
mk k = t = Token k; fn n -> consume t + n.
'''
HOLDER = '''Holder = Type (Holder (Int -> Int)).
'''

# (source, the diagnostic text both frontends must print)
REFUSALS = {
    'higher-order-twice': (TWICE + '''
main = t = Token 7; f = fn n -> consume t + n; print (twice f).
''', "'twice' may call its function argument #1 more than once"),
    'higher-order-never': ('''
ignore : (Int -> Int) -> Int.
ignore f = 0.
main = t = Token 7; f = fn n -> consume t + n; print (ignore f).
''', "'ignore' may call its function argument #1 more than once (or never)"),
    'higher-order-forwarded': (TWICE + '''
forward : (Int -> Int) -> (Int, Int).
forward g = twice g.
main = t = Token 7; f = fn n -> consume t + n; print (forward f).
''', "'forward' may call its function argument #1"),
    'higher-order-pap-twice': (TWICE + AT + '''
main = t = Token 7; print (twice (at t)).
''', "'twice' may call its function argument #1"),
    'closure-return-twice': (MAKE + '''
main = f = make (Token 7); print (f 0, f 1).
''', "linear variable 'f' used 2 time(s)"),
    'closure-return-lambda-clause': (AT.replace('at t n = consume t + n.', 'at t = fn n -> consume t + n.') + '''
main = t = Token 7; f = at t; print (f 0, f 1).
''', "linear variable 'f' used 2 time(s)"),
    'aliased-pap-twice': (AT + '''
alias = at.
main = t = Token 7; f = alias t; print (f 0, f 1).
''', "linear variable 'f' used 2 time(s)"),
    'dynamic-pap-twice': (AT + '''
main = t = Token 7; f = (case True of True -> at | False -> at) t; print (f 0, f 1).
''', "linear variable 'f' used 2 time(s)"),
    'local-callable-pap-twice': (AT + '''
main = t = Token 7; g = (case True of True -> at | False -> at); f = g t; print (f 0, f 1).
''', "linear variable 'f' used 2 time(s)"),
    'recursive-map': ('''
mapL : (Int -> Int) -> (xs : List Int | measure xs) -> List Int.
mapL f xs = case xs of Nil -> Nil | x :: r -> f x :: mapL f r.
main = t = Token 7; f = fn n -> consume t + n; print (mapL f [1, 2]).
''', "'mapL' may call its function argument #1"),
    # a function type nested in a parameter is a callable parameter too
    'nested-callback-twice': (DUP + '''
main = t = Token 7; f = fn n -> consume t + n; print (dup (f, 1)).
''', "'dup' may call a function inside its argument #1 more than once"),
    # a lambda-bodied definition's parameters are its own
    'lambda-bodied-twice': ('''
twice = fn f -> (f 0, f 1).
main = t = Token 7; f = fn n -> consume t + n; print (twice f).
''', "'twice' may call its function argument #1 more than once"),
    # a function type nested in a result holds the owners passed in
    'tuple-result-twice': (PAIR + '''
main = (f, k) = pair (Token 7); print (f 1 + f 2 + k).
''', "linear variable 'f' used 2 time(s)"),
    # a closure over an owner the callee made itself, behind an
    # unrestricted-looking signature
    'self-held-twice': (SELF + '''
main = f = mk 7; print (f 1 + f 2).
''', "linear variable 'f' used 2 time(s)"),
    'self-held-unannotated-twice': ('''
mk k = t = Token k; fn n -> consume t + n.
main = f = mk 7; print (f 1 + f 2).
''', "linear variable 'f' used 2 time(s)"),
    # a function-typed constructor field cannot say it is single-use
    'constructor-field-store': (HOLDER + '''
wrap : Token -> Holder.
wrap t = Holder (fn n -> consume t + n).
main = h = wrap (Token 7); Holder f = h; print (f 1 + f 2).
''', "constructor 'Holder' cannot store a single-use closure"),
    'std-list-map': ('''
main = t = Token 7; f = fn n -> consume t + n; print (List.map f [1, 2]).
''', "'List.map' may call its function argument #1"),
    'prim-vec-map': ('''
main = t = Token 7; v = Vec.push 1 (Vec.new Unit); f = fn n -> consume t + n;
  w = Vec.map f v; u = Vec.free w; print 0.
''', "'Vec.map' may call its function argument #1"),
}

# HostedBytecode-only list schemes (Sol.Infer.solBuiltins): primitives with
# no body, so the refusal comes from Ownership.Shape.repeatedCallbackPrims
SOL_REFUSALS = {
    'sol-scheme-map': ('''
main = t = Token 7; f = fn n -> consume t + n; print (map f [1, 2]).
''', "'map' may call its function argument #1"),
    'sol-scheme-foldl': ('''
main = t = Token 7; f = fn a n -> consume t + n; print (foldl f 0 [1, 2]).
''', "'foldl' may call its function argument #1"),
    'sol-scheme-filter-nested': ('''
main = t = Token 7; f = fn n -> consume t + n; print (filter (fn x -> f x > 0) [1, 2]).
''', "'filter' may call its function argument #1"),
}

POSITIVES = {
    'higher-order-once': (ONCE + '''
main = t = Token 7; f = fn n -> consume t + n; print (once f).
''', 'consume 7\n8\n'),
    'lambda-bodied-once': ('''
once = fn f -> f 1.
main = t = Token 7; f = fn n -> consume t + n; print (once f).
''', 'consume 7\n8\n'),
    'nested-callback-unrestricted': (DUP + '''
main = k = 3; print (dup (fn n -> n + k, 1)).
''', '8\n'),
    'tuple-result-once': (PAIR + '''
main = (f, k) = pair (Token 7); print (f 1 + k).
''', 'consume 7\n8\n'),
    'self-held-once': (SELF + '''
main = f = mk 7; print (f 1).
''', 'consume 7\n8\n'),
    'constructor-field-unrestricted': (HOLDER + '''
main = k = 3; h = Holder (fn n -> n + k); Holder f = h; print (f 1 + f 2).
''', '9\n'),
    'higher-order-unrestricted-twice': (TWICE + '''
main = k = 7; print (twice (fn n -> k + n)).
''', '(7, 8)\n'),
    'higher-order-pap-once': (ONCE + AT + '''
main = t = Token 7; print (once (at t)).
''', 'consume 7\n8\n'),
    'closure-return-once': (MAKE + '''
main = f = make (Token 7); print (f 1).
''', 'consume 7\n8\n'),
    'aliased-pap-once': (AT + '''
alias = at.
main = t = Token 7; f = alias t; print (f 1).
''', 'consume 7\n8\n'),
    'dynamic-pap-once': (AT + '''
main = t = Token 7; f = (case True of True -> at | False -> at) t; print (f 1).
''', 'consume 7\n8\n'),
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', action='append', help='run only the named case; repeatable')
    args = parser.parse_args()
    selected = set(args.case or REFUSALS.keys() | SOL_REFUSALS.keys() | POSITIVES.keys())
    unknown = selected - REFUSALS.keys() - SOL_REFUSALS.keys() - POSITIVES.keys()
    if unknown:
        parser.error('unknown case(s): ' + ', '.join(sorted(unknown)))
    with tempfile.TemporaryDirectory(prefix='fpr-callable-ownership-') as directory:
        tmp = Path(directory)
        env = os.environ | {
            'FPR_HOME': str(ROOT), 'SOL_CACHE_DIR': str(tmp / 'sol-cache'),
            'SOL_GPU': '0', 'SOL_JIT': '0', 'SOL_NOTYPES': '0',
            'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')),
        }
        env.pop('FPR_FOREIGN', None)

        def invoke(command):
            return subprocess.run([str(a) for a in command], cwd=ROOT, env=env,
                                  capture_output=True, text=True, timeout=120)

        for name, (body, needle) in REFUSALS.items():
            if name not in selected:
                continue
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            for mode, command in (
                ('native', [ROOT / 'fprc', '--system=posix', '--check-only', source, '/dev/null']),
                ('Sol', [ROOT / 'fpr', 'sol', source]),
            ):
                result = invoke(command)
                output = result.stdout + result.stderr
                assert result.returncode != 0 and 'LINEARITY: ERRORS' in output, (name, mode, result.returncode, output)
                assert needle in output, (name, mode, needle, output)
            print(name + ': refused by native and Sol', flush=True)

        for name, (body, needle) in SOL_REFUSALS.items():
            if name not in selected:
                continue
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            result = invoke([ROOT / 'fpr', 'sol', source])
            output = result.stdout + result.stderr
            assert result.returncode != 0 and 'LINEARITY: ERRORS' in output, (name, result.returncode, output)
            assert needle in output and 'consume 7' not in output, (name, needle, output)
            print(name + ': refused by Sol', flush=True)

        for name, (body, expected) in POSITIVES.items():
            if name not in selected:
                continue
            source = tmp / (name + '.fpr')
            source.write_text(BASE + body)
            binary = tmp / name
            built = invoke([ROOT / 'fpr', 'build', source, '-o', binary])
            assert built.returncode == 0, (name, built.returncode, built.stdout + built.stderr)
            for mode, command in (
                ('native', [binary]),
                ('Sol', [ROOT / 'fpr', 'sol', source]),
            ):
                result = invoke(command)
                assert result.returncode == 0, (name, mode, result.returncode, result.stdout + result.stderr)
                assert result.stdout == expected, (name, mode, expected, result.stdout, result.stderr)
            print(name + ': single-use result agrees in native and Sol', flush=True)
    print(str(len(selected)) + ' callable ownership cases PASS', flush=True)


if __name__ == '__main__':
    main()
