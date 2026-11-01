#!/usr/bin/env python3
"""Checked case of known constructor: differential behavior, allocation and rollback."""
from pathlib import Path
import json, os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]

HALF = '''O = use "std/option".
half : Int -> O.Option Int .
half x = if x % 2 == 0 then O.Some (x / 2) else O.None.
loop : unsafe Int -> Int -> Int .
'''

# name -> (source, requests with the pass off, requests with it on)
PROGRAMS = {
    # The constructed Option never exists: its 500 allocations disappear.
    'option': (HALF + 'loop i acc = if i == 0 then acc else loop (i - 1) (case half i of O.Some y -> acc + y | O.None -> acc + 1).\nmain = print "{loop 1000 0}".\n', 501, 1),
    'wildcard': (HALF + 'loop i acc = if i == 0 then acc else loop (i - 1) (case half i of O.None -> acc + 1 | _ -> acc + 7).\nmain = print "{loop 1000 0}".\n', 501, 1),
    # The whole value is still used, so it must still be built.
    'bind-whole': (HALF + 'loop i acc = if i == 0 then acc else loop (i - 1) (case half i of O.None -> acc + 1 | v -> acc + O.withDefault 5 v).\nmain = print "{loop 1000 0}".\n', 501, 501),
    # A nested pattern is not decided by the constructor alone.
    'nested-pattern': (HALF + 'loop i acc = if i == 0 then acc else loop (i - 1) (case half i of O.Some 3 -> acc + 100 | O.Some y -> acc + y | O.None -> acc + 1).\nmain = print "{loop 1000 0}".\n', 501, 501),
    # Two leaves would select one alternative: alternatives are moved, never copied.
    'shared-alternative': ('''O = use "std/option".
pick : Int -> O.Option Int .
pick x = if x > 10 then O.Some x else O.Some (x + 1).
loop : unsafe Int -> Int -> Int .
loop i acc = if i == 0 then acc else loop (i - 1) (case pick i of O.Some y -> acc + y | O.None -> acc + 1).
main = print "{loop 30 0}".
''', 31, 31),
    # An unknown leaf (a call that is not inlined or not a constructor) declines.
    'unknown-leaf': ('''O = use "std/option".
loop : unsafe Int -> Int -> Int .
loop i acc = if i == 0 then acc else loop (i - 1) (case O.map (fn x -> x + 1) (O.Some i) of O.Some y -> acc + y | O.None -> acc + 1).
main = print "{loop 30 0}".
''', None, None),
    'tuple': ('''f : Int -> Int .
f x = case (x + 1, x * 2) of (a, b) -> a + b.
g : Int -> Int .
g x = case (if x > 3 then (x, 1) else (1, x)) of (a, b) -> a * 10 + b.
main = print "{f 5} {g 2} {g 9}".
''', None, None),
    # The field expression traps in the same place whether or not it is built.
    'trap-order': ('''O = use "std/option".
mk : Int -> Int -> O.Option Int .
mk d x = if x > 3 then O.Some (x / d) else O.None.
f : Int -> Int -> Int .
f d x = case mk d x of O.Some _ -> 1 | O.None -> 0.
main = print "{f 0 1} {f 0 5}".
''', None, None),
    'trap-used-field': ('''O = use "std/option".
mk : Int -> Int -> O.Option Int .
mk d x = if x > 3 then O.Some (x / d) else O.None.
f : Int -> Int -> Int .
f d x = case mk d x of O.Some y -> y | O.None -> 0.
main = print "{f 0 1} {f 2 8} {f 0 9}".
''', None, None),
}


def run(args, env, timeout=180):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-case-known-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
                    XDG_CACHE_HOME=str(tmp / 'cache'))

        def build(name, text, disabled):
            path = tmp / (name + '.fpr')
            path.write_text(text)
            env = dict(base, FPR_COST_PROBE='1', FPR_NO_LOOP_REGIONS='1', FPR_NO_CALL_REGIONS='1')
            if disabled:
                env['FPR_NO_CASE_KNOWN'] = '1'
            exe = tmp / f'{name}-{int(disabled)}'
            made = run([ROOT / 'fpr', 'build', path, '--harts', '1', '-o', exe], env)
            assert made.returncode == 0, (name, made.stdout[-2000:], made.stderr[-6000:])
            return exe, env

        for name, (text, off, on) in PROGRAMS.items():
            seen = {}
            for disabled in (True, False):
                exe, env = build(name, text, disabled)
                observed = run([exe], dict(env, FPR_COST_REPORT='1'), timeout=60)
                match = re.search(r'\[fpr cost\] (\{.*\})', observed.stderr)
                assert match, (name, disabled, observed.stderr)
                ledger = json.loads(match.group(1))
                stderr = observed.stderr.replace(match.group(0), '')
                seen[disabled] = (observed.returncode, observed.stdout, stderr, ledger['alloc_requests'])
            assert seen[True][:3] == seen[False][:3], (name, seen)
            wanted = (off, on)
            if wanted != (None, None):
                assert (seen[True][3], seen[False][3]) == wanted, (name, seen, wanted)
            print(f'Case of known constructor: {name} {seen[True][3]} -> {seen[False][3]} requests PASS', flush=True)

        # The trapping programs really do trap, with and without the pass.
        for name in ('trap-order', 'trap-used-field'):
            exe, env = build(name, PROGRAMS[name][0], False)
            observed = run([exe], env, timeout=60)
            assert 'division by zero' in observed.stdout + observed.stderr, (name, observed.stdout, observed.stderr)

        # Rollback: the disabled build is byte-for-byte the unrewritten pipeline,
        # so the rewrite is visible in the emitted code only when enabled.
        source = tmp / 'option.fpr'
        outputs = {}
        for disabled in (True, False):
            env = dict(base)
            if disabled:
                env['FPR_NO_CASE_KNOWN'] = '1'
            assembly = tmp / f'option-{int(disabled)}.s'
            made = run([ROOT / 'fpr', 'compile', '--system=posix', '--target=a64mac', source, assembly], env)
            assert made.returncode == 0, made.stderr[-4000:]
            outputs[disabled] = assembly.read_text()
        assert outputs[True] != outputs[False]
        print('Case of known constructor rollback PASS', flush=True)


if __name__ == '__main__':
    main()
