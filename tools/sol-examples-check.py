#!/usr/bin/env python3
"""The Sol examples in the intended style (docs/2026-10-04-SOL-EXAMPLES-STYLE.md).

  python3 tools/sol-examples-check.py            check against tests/sol-examples/
  python3 tools/sol-examples-check.py --update   rewrite the golden files
  python3 tools/sol-examples-check.py --examples DIR
                                                 run another copy of the examples
                                                 (used to compare two revisions)

Each example runs from a copy in a temporary directory, its `../lib/` imports
pointed at this tree's sol/lib, so nothing is written next to the sources.

  * the scripts' output equals its golden file, including bboard on a netlist
    with malformed lines and one that fills the board;
  * the MVU apps (no server is started) replay a message sequence through
    `update`, printing every result and the rendered view between segments;
    the last segment is malformed browser payloads, which must be refused
    without a panic;
  * violated contracts panic with named blame;
  * a measure whose descent is removed is refused.

The golden files were produced by the style versions after they matched
minimally patched copies of the original examples on the same inputs (the
originals no longer compile); malformed-input behaviour is new.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
GOLDEN = ROOT / 'tests' / 'sol-examples'

SCRIPTS = ['bboard', 'dtree', 'mandel', 'physics', 'prolog']

SIGN_IN = [('refresh', ''), ('login', 'bob pw'), ('auth', ''), ('auth', 'pw'), ('auth', 'zz'),
           ('register', 'amy p'), ('regchk', ''), ('regchk', 'x'), ('setuser', 'bob'),
           ('connected', ''), ('refresh', ''), ('nosuch', 'q')]

def terra_game(turns, plays, attacks):
    msgs = [('connected', '')]
    for t in range(turns):
        msgs += [('play', str(p)) for p in plays(t)] + [('attack', str(a)) for a in attacks(t)] + [('end', '')]
    return msgs

# segments of (event, payload); a payload is Sol string-literal text, so a
# newline is written {base.nl}
APPS = {
    'todo': [SIGN_IN + [('gottodos', '0 a{base.nl}1 b{base.nl}{base.nl}0 c'), ('add', 'd'), ('toggle', '1'),
                        ('toggle', '9'), ('toggle', '0'), ('clear', ''), ('gottodos', '')],
             [('logout', '')],
             [('setuser', 'bob'), ('add', 'e'), ('toggle', 'x'), ('toggle', ''), ('toggle', '-1')]],
    'todo2': [SIGN_IN + [('gottodos', '0 a{base.nl}1 b{base.nl}{base.nl}0 c{base.nl}'), ('add', 'd'), ('toggle', '1'),
                         ('toggle', '9'), ('toggle', '0'), ('clear', ''), ('gottodos', ''), ('add', 'e')],
              [('logout', '')],
              [('setuser', 'bob'), ('add', 'e'), ('toggle', 'x'), ('toggle', '')]],
    'pos': [SIGN_IN + [('checkout', ''), ('buy', '0'), ('buy', '2'), ('gotrev', '15'), ('checkout', ''),
                       ('dorev', '10'), ('buy', '3'), ('dorev', '')],
            [('logout', '')],
            [('setuser', 'bob'), ('buy', '7'), ('buy', '-1'), ('buy', 'x'), ('buy', ''), ('buy', '1')]],
    'dash': [SIGN_IN + [('tick', ''), ('bump', '4'), ('bump', ''), ('gotlogins', '7'), ('sample', '50'),
                        ('sample', '0'), ('sample', '95')],
             [('logout', '')]],
    'terra': [terra_game(60, lambda t: [t % 4, 0, 9][: 1 + t % 3], lambda t: [t % 3, (t + 1) % 3][: t % 2 + 1]),
              terra_game(70, lambda t: [0, 1, 0], lambda t: [0, 0, 1, 2]) + [('new', ''), ('attack', '0')],
              [('new', ''), ('attack', '5'), ('attack', '-1'), ('attack', 'x'), ('play', 'x'), ('play', '-1'),
               ('play', '99'), ('play', '0')]],
}

BAD_NETLIST = '''[
  "* malformed lines are reported, good ones still placed",
  "V1 vcc 0 DC 5",
  "R0 vcc",
  "Q1 c b e",
  "R1 vcc out 1k",
  "C1 out 0 10n",
  "x",
  ".end"
]'''

STRESS_NETLIST = '[\n  ' + ',\n  '.join(
    ['"* fills the board: some parts find no position, one power net is left unplaced"',
     '"V1 vcc 0 DC 5"', '"V2 vb 0"', '"r1 a b 1k"']
    + [f'"R{i} n{i % 7} n{(i * 3) % 11} {i}k"' for i in range(2, 70)]
    + ['"D9 vb 0"', '".end"']) + '\n]'

# (example, appended statement, the blame stderr must name)
CONTRACTS = [
    ('terra', '> print (slotAt 3 emptyZone).', 'slotAt requires'),
    ('terra', '> print (setAt (0 - 1) Empty emptyZone).', 'setAt requires'),
    ('bboard', '> print (holeLetter 0 6).', 'holeLetter requires'),
    ('bboard', '> print (sKey 31 0).', 'sKey requires'),
    ('bboard', '> print (padL (0 - 1) "x").', 'padL requires'),
    ('mandel', '> print (rowOf [1, 2] (0 - 1)).', 'rowOf requires'),
]

# (example, text, replacement, the refusal stderr must contain)
MEASURES = [
    ('dtree', 'True -> predict l p', 'True -> predict t p', 'the measure does not decrease at the call to predict'),
    ('dtree', '(build (depth - 1) (buildVec ls', '(build depth (buildVec ls', 'the measure does not decrease at the call to build'),
    ('dtree', '| Node f th l r -> "Node(x{f} < {th}: {showT l}', '| Node f th l r -> "Node(x{f} < {th}: {showT t}',
     'the measure does not decrease at the call to showT'),
]


def sol_string(s):
    return '"' + s.replace('"', '\\"') + '"'


def harness(segments):
    lines = ['', 'traceStep m msg = (m2, c) = update msg m; u = print "{msg} => {c} :: {m2}"; m2.',
             'traceView m = print "VIEW {view m}".',
             '> m0 = init "";', '  v0 = traceView m0;']
    for i, seg in enumerate(segments, 1):
        msgs = ', '.join(f'({sol_string(e)}, {sol_string(p)})' for e, p in seg)
        lines.append(f'  m{i} = List.fold traceStep m{i - 1} [{msgs}];')
        lines.append(f'  v{i} = traceView m{i};')
    lines[-1] = '  ' + lines[-1].split('=', 1)[1].strip().rstrip(';') + '.'
    return '\n'.join(lines) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--update', action='store_true')
    ap.add_argument('--examples', default=str(ROOT / 'sol' / 'examples'))
    args = ap.parse_args()
    examples = Path(args.examples).resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_') and k != 'GHCRTS'}
    fails = []
    count = 0

    with tempfile.TemporaryDirectory(prefix='sol-examples-check-') as tmp:
        work = Path(tmp)
        env['SOL_CACHE_DIR'] = str(work / 'cache')

        def source(name, statements=True):
            # statements=False: the definitions only, cut at the first
            # top-level `>` statement (they all sit at the end of the file)
            text = (examples / f'{name}.sol').read_text()
            text = text.replace('use "../lib/', f'use "{ROOT}/sol/lib/')
            if not statements:
                text = text.split('\n> ', 1)[0] + '\n'
            return text

        def run(name, text):
            path = work / f'{name}.sol'
            path.write_text(text)
            return subprocess.run([str(FPR), 'sol', str(path)], env=env, capture_output=True, text=True,
                                  timeout=300, cwd=work)

        def golden(key, out):
            nonlocal count
            count += 1
            g = GOLDEN / f'{key}.out'
            if args.update:
                GOLDEN.mkdir(parents=True, exist_ok=True)
                g.write_text(out)
            elif not g.exists() or g.read_text() != out:
                fails.append(f'{key}: output differs from {g.relative_to(ROOT)}')

        def clean(key, r):
            if r.returncode != 0 or r.stderr:
                fails.append(f'{key}: exit {r.returncode}\n{r.stderr[-2000:]}')
                return False
            return True

        for name in SCRIPTS:
            r = run(name, source(name))
            if clean(name, r):
                golden(name, r.stdout)

        bb = source('bboard', statements=False)
        for key, netlist in (('bboard-skipped', BAD_NETLIST), ('bboard-stress', STRESS_NETLIST)):
            r = run(key, bb + f'\n> runBoard "{key}" {netlist}.\n')
            if clean(key, r):
                golden(key, r.stdout)

        for name, segments in APPS.items():
            r = run(name, source(name, statements=False) + harness(segments))
            if clean(name, r):
                golden(f'{name}.trace', r.stdout)

        for name, stmt, blame in CONTRACTS:
            count += 1
            text = source(name, statements=False)
            r = run(f'{name}-contract', text + '\n' + stmt + '\n')
            if r.returncode == 0 or 'precondition violated' not in r.stderr or blame not in r.stderr:
                fails.append(f'contract {name}: {stmt} did not panic naming {blame!r}\n{r.stderr[-1000:]}')

        for name, old, new, refusal in MEASURES:
            count += 1
            text = source(name)
            if text.count(old) != 1:
                fails.append(f'measure {name}: the text to mutate is not unique: {old!r}')
                continue
            r = run(f'{name}-measure', text.replace(old, new))
            if r.returncode == 0 or refusal not in r.stderr:
                fails.append(f'measure {name}: removing descent was not refused with {refusal!r}\n{r.stderr[-1000:]}')

    if fails:
        print('\n'.join(fails))
        print(f'sol examples: {len(fails)} of {count} checks FAILED')
        raise SystemExit(1)
    print(f'sol examples: {count} checks passed' + (' (golden files written)' if args.update else ''))


if __name__ == '__main__':
    main()
