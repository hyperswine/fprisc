#!/usr/bin/env python3
"""Differential check: incremental (sliced) prelude vs the whole prelude.

docs/2026-10-29-SOL-INCREMENTAL-PRELUDE.md.  For every .sol file in the tree
(sol/examples, sol/lib, sol/scripts, tests, std, plus generated programs that
type-error, shadow, redefine and import), compile with `--asm` under
SOL_INCREMENTAL=0 and under the default, with the compile cache off, and
require byte-identical stdout (the disassembly of everything the run can
reach), stderr (every diagnostic) and exit status.  Then drive REPL sessions
(definitions, prelude shadowing, `use`, type errors mid-session and recovery,
redefinition refusals, panics) through both modes and require identical
transcripts.

  python3 tools/sol-incremental-check.py [-v]
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
VERBOSE = '-v' in sys.argv

GENERATED = {
    'type-error.sol': '> print (1 + "a").\n',
    'unbound.sol': '> print (nosuchThing 3).\n',
    'shadow-prelude.sol': 'not b = 42.\n> print (not True).\n',
    'shadow-struct.sol': 'Str = Struct { len = fn s -> 7 }.\n> print (Str.len "abc").\n',
    'method-dispatch.sol': '> print ("abc".len).\n> print ([1, 2, 3].len).\n> print ("x" + "y").\n> print ([1] + [2]).\n',
    'ops.sol': '> print (7 % 3).\n> print (2 ^ 10).\n> print (Numeric.max 3 9).\n',
    'list-ops.sol': 'xs = List.range 1 10.\n> print (List.sum (List.map (fn x -> x * x) xs)).\n> print (Str.join "," (List.map str xs)).\n',
    'hole.sol': 'f x = ?? .\n> print 1.\n',
    'named-hole.sol': 'f x = ?what.\n> print 1.\n',
    'sig-mismatch.sol': 'f : Int -> String.\nf x = x + 1.\n> print (f 1).\n',
    'result.sol': '> print (match (Try.parseInt "12") ).\nmatch r = case r of Ok n -> n | Err e -> 0.\n',
    'parse-int.sol': '> print (parseInt "41" + 1).\n',
    'wire.sol': '> print (wireToInt (WStr "12")).\n',

    'realtime.sol': '> print (read (Now "x")).\n',
    'redefine-twice.sol': 'f x = 1.\nf x = 2.\n> print (f 0).\n',
    'linear.sol': 'g h = close h.\n> print 1.\n',
    'empty.sol': '',
    'only-defs.sol': 'sq x = x * x.\n',
    'main.sol': 'main = print "from main".\n',
}

SESSIONS = {
    'basic': ['> print "tick".', 'sq x = x * x.', '> print (sq 7).', '> print (Str.upper "abc").'],
    'redefine': ['f x = x + 1.', 'f x = x + 2.', '> print (f 1).'],
    'shadow-prelude': ['not b = 3.', '> print (not True).', 'or a b = a.', '> print (or 1 2).'],
    'type-error-recover': ['> print (1 + "a").', 'g x = x ++ 1.', '> print "still here".', 'g x = x * 2.', '> print (g 21).'],
    'panic-recover': ['> print (error "boom").', '> print "after".', '> print (List.range 1 3).'],
    'multiline': ['h x =', '  x + 1.', '> print (h 1).'],
    'parse-error': ['> print (.', '> print 2.'],
    'unbound-then-define': ['> print (later 1).', 'later x = x.', '> print (later 5).'],
    'use-libs': ['json = use "../lib/json".', '> print (json.encode (json.JNum 3)).', 'csv = use "../lib/csv".', '> print "ok".', '> print (json.nosuch 1).', '> print "recovered".'],
    'methods': ['> print ("abc".len).', 's = "a,b".', '> print (Str.split 44 s).', '> print ([3, 1].len + 1).'],
}


def run(cmd, mode, cwd, stdin=None):
    env = dict(os.environ, SOL_CACHE='0', SOL_GPU='0')
    env.pop('SOL_TIMINGS', None)
    if mode is None:
        env['SOL_INCREMENTAL'] = 'trace'
    else:
        env['SOL_INCREMENTAL'] = mode
    # the incremental side runs in trace mode so the summary can show the
    # slice was actually used (trace lines are stripped before comparing)
    p = subprocess.run(cmd, cwd=cwd, env=env, input=stdin, capture_output=True, text=True, timeout=120)
    err = []
    for line in p.stderr.splitlines(keepends=True):
        if line.startswith('[sol incremental] '):
            TALLY[re.sub(r'\(.*\)|\d+/\d+', '..', line[18:].strip())] = TALLY.get(re.sub(r'\(.*\)|\d+/\d+', '..', line[18:].strip()), 0) + 1
        else:
            err.append(line)
    return p.returncode, p.stdout, ''.join(err)


TALLY = {}


HEADER = re.compile(r'^(\S.*?) \(arity \d+, frame \d+ slots\):$')
NUMBERED = re.compile(r'[_.]\d+$')


def canonical(text):
    """Alpha-normalize a --asm listing.

    Compiler-generated functions (lifted_N, f_fb_N, $spec...mono.N,
    case_join_N) are numbered from global counters, and the sliced program
    numbers them from a different start, which also reorders the listing.
    Rename every numbered function by the order a traversal from the
    un-numbered roots first reaches it, then sort, so two listings are equal
    exactly when the programs are equal up to those names."""
    blocks = {}
    order = []
    for block in text.strip('\n').split('\n\n'):
        lines = block.split('\n')
        m = HEADER.match(lines[0])
        if not m:
            return text  # not a listing (e.g. an error): compare verbatim
        blocks[m.group(1)] = lines
        order.append(m.group(1))
    if not blocks:
        return text
    internal = {n for n in blocks if NUMBERED.search(n) and not n.startswith('top__')}
    names = {}
    def refs(n):
        out = []
        for ln in blocks[n][1:]:
            for q in re.findall(r'"((?:[^"\\]|\\.)*)"', ln):
                if q in blocks and q not in out:
                    out.append(q)
        return out
    work = sorted(n for n in blocks if n not in internal)
    seen = set()
    while work:
        n = work.pop(0)
        if n in seen:
            continue
        seen.add(n)
        for r in refs(n):
            if r in internal and r not in names:
                names[r] = f'<gen{len(names)}>'
            work.append(r)
    for n in sorted(internal - set(names)):
        names[n] = f'<unreached:{n}>'
    def rename(s):
        return re.sub(r'"((?:[^"\\]|\\.)*)"', lambda m: '"' + names.get(m.group(1), m.group(1)) + '"', s)
    out = []
    for n in order:
        lines = blocks[n]
        head = names.get(n, n) + lines[0][len(n):]
        out.append('\n'.join([head] + [rename(l) for l in lines[1:]]))
    return '\n\n'.join(sorted(out))


def compare(label, a, b, failures, canon=False):
    if canon:
        a = (a[0], canonical(a[1]), a[2])
        b = (b[0], canonical(b[1]), b[2])
    if a != b:
        failures.append(label)
        print(f'DIFF {label}')
        for name, x, y in zip(('rc', 'stdout', 'stderr'), a, b):
            if x != y:
                print(f'  {name}:\n    full: {str(x)[:600]!r}\n    incr: {str(y)[:600]!r}')
    elif VERBOSE:
        print(f'same {label} (rc {a[0]})')


def main():
    failures = []
    files = sorted(p for p in ROOT.rglob('*.sol')
                   if not any(part in ('dist-newstyle', '.git', 'build') for part in p.parts))
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        gen = tmp / 'gen'
        gen.mkdir()
        for name, text in GENERATED.items():
            (gen / name).write_text(text)
        files += sorted(gen.iterdir())
        n = 0
        for f in files:
            # the script's own directory resolves `use` and relative paths
            full = run([str(FPR), 'sol', '--asm', str(f)], '0', f.parent)
            incr = run([str(FPR), 'sol', '--asm', str(f)], None, f.parent)
            compare(f'asm {f.relative_to(ROOT) if ROOT in f.parents else f.name}', full, incr, failures, canon=True)
            n += 1
        # executed outputs for the self-contained generated programs
        for name in GENERATED:
            outs = []
            for mode in ('0', None):
                d = tmp / 'run'
                shutil.rmtree(d, ignore_errors=True)
                d.mkdir()
                shutil.copy(gen / name, d / name)
                outs.append(run([str(FPR), 'sol', name], mode, d))
            compare(f'run {name}', outs[0], outs[1], failures)
            n += 1
        for name, lines in SESSIONS.items():
            outs = []
            for mode in ('0', None):
                d = tmp / 'repl'
                shutil.rmtree(d, ignore_errors=True)
                d.mkdir()
                if name == 'use-libs':
                    d = ROOT / 'sol' / 'examples'
                outs.append(run([str(FPR), 'sol', '--repl'], mode, d, stdin='\n'.join(lines) + '\n'))
            compare(f'repl {name}', outs[0], outs[1], failures)
            n += 1
    print(f'{n - len(failures)}/{n} identical')
    for k, v in sorted(TALLY.items()):
        print(f'  incremental: {v:4d} x {k}')
    if failures:
        print('FAIL: ' + ', '.join(failures))
        sys.exit(1)
    print('PASS sol-incremental-check')


if __name__ == '__main__':
    main()
