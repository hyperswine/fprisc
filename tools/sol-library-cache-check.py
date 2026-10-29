#!/usr/bin/env python3
"""Differential check: checked-library verdicts + library slicing vs full compile.

docs/2026-10-29-SOL-LIBRARY-CHECK-CACHE.md.  A program whose `use`d libraries
carry a verdict (they passed the whole pipeline before, under this executable,
these options and this exact text) is compiled with the libraries sliced to
what the program names.  For every program here: compile once to record the
verdict, drop the whole-program cache entries, compile again (the sliced
path), and require the same stdout (--asm listing, up to compiler-generated
names), stderr and exit status as SOL_INCREMENTAL=0.  Covers every library in
sol/lib alone and together, every tree program that uses one, generated
programs (shadowing, type errors, unknown members), REPL sessions with `use`,
and invalidation: editing an unused library function must be seen.

  python3 tools/sol-library-cache-check.py [-v]
"""
import importlib.util
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
spec = importlib.util.spec_from_file_location('incr', ROOT / 'tools' / 'sol-incremental-check.py')
incr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(incr)
LIB = ROOT / 'sol' / 'lib'
TALLY = {}


def run(cmd, cwd, cache, mode=None, stdin=None, extra=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
    env.update(SOL_GPU='0', SOL_CACHE_DIR=str(cache), FPR_HOME=str(ROOT))
    env['SOL_INCREMENTAL'] = mode or 'trace'
    env.update(extra or {})
    # never reuse a whole-program entry: only verdicts and parses persist
    for f in Path(cache).glob('*.cache'):
        f.unlink()
    p = subprocess.run(cmd, cwd=cwd, env=env, input=stdin if stdin is not None else '', capture_output=True, text=True, timeout=180)
    err = []
    for line in p.stderr.splitlines(keepends=True):
        if line.startswith('[sol incremental] '):
            k = re.sub(r'\(.*\)|\d+/\d+', '..', line[18:].strip())
            TALLY[k] = TALLY.get(k, 0) + 1
        else:
            err.append(line)
    return p.returncode, p.stdout, ''.join(err)


def differential(label, cmd, cwd, tmp, failures, stdin=None, canon=True, extra=None, shared=False):
    full_cache = tmp / 'cache-full'
    inc_cache = tmp / ('cache-shared' if shared else 'cache-inc')
    if not shared:
        shutil.rmtree(inc_cache, ignore_errors=True)
    full = run(cmd, cwd, full_cache, '0', stdin, extra)
    run(cmd, cwd, inc_cache, None, stdin, extra)      # records the verdict
    second = run(cmd, cwd, inc_cache, None, stdin, extra)  # sliced libraries
    incr.compare(label, full, second, failures, canon=canon)


def main():
    failures = []
    n = 0
    libs = sorted(p.stem for p in LIB.glob('*.sol'))
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        gen = tmp / 'gen'
        gen.mkdir()
        programs = {}
        for lib in libs:
            programs[f'lib-{lib}.sol'] = f'L = use "{LIB}/{lib}".\n> print "ok".\n'
        programs['all-libs.sol'] = ''.join(f'L{i} = use "{LIB}/{l}".\n' for i, l in enumerate(libs)) + '> print "ok".\n'
        programs['json-csv.sol'] = f'J = use "{LIB}/json".\nC = use "{LIB}/csv".\n> print (J.render (J.strs ["a", "b"])).\n'
        programs['json-shadow.sol'] = f'J = use "{LIB}/json".\nrender x = 7.\nstrs x = 8.\n> print (render 1 + strs 2).\n> print (J.render (J.strs ["q"])).\n'
        programs['json-type-error.sol'] = f'J = use "{LIB}/json".\n> print (J.render 3).\n'
        programs['json-unknown.sol'] = f'J = use "{LIB}/json".\n> print (J.nosuchThing 3).\n'
        # auth needs the app's record shape: verified in one program's
        # context, it must not be trusted in another's (shared cache below)
        programs['auth-app.sol'] = f'L = use "{LIB}/auth".\nmodel = {{user = Persistent "demo", pendu = "", pendp = "", note = ""}}.\n> print (L.unwrapU model).\n'
        # per-program-interface verdicts: same declarations with other
        # bodies reuse the verdict; other shapes / names / a missing field
        # must not (identical diagnostics either way)
        A = f'L = use "{LIB}/auth".\n'
        M = 'model = {user = Persistent "demo", pendu = "", pendp = "", note = ""}.\n'
        programs['auth-app-body.sol'] = A + M + '> print (L.unwrapU model).\n> print 42.\n'
        programs['auth-app-body2.sol'] = A + M + '> print (L.unwrapU model).\n> print (L.doLogin "a b" model).\n'
        programs['auth-app-fn.sol'] = A + M + 'go v = L.doReg v model.\n> print (go "x y").\n'
        programs['auth-app-fn2.sol'] = A + M + 'go v = L.doLogin v model.\n> print (go "x y").\n'
        programs['auth-app-extra.sol'] = A + M + 'other = {pendu = "q", zz = 1}.\n> print (L.unwrapU model).\n> print other.zz.\n'
        programs['auth-app-missing.sol'] = A + 'model = {user = Persistent "demo", pendu = "", pendp = ""}.\n> print (L.unwrapU model).\n'
        programs['auth-app-missing2.sol'] = A + 'model = {user = Persistent "demo", pendu = "", pendp = ""}.\n> print (L.doReg "a b" model).\n'
        programs['auth-app-typeerr.sol'] = A + M + '> print (L.unwrapU model + 1).\n'
        programs['auth-app-shadow.sol'] = A + M + 'unwrapU m = 7.\n> print (unwrapU model).\n> print (L.unwrapU model).\n'
        programs['auth-bare.sol'] = f'L = use "{LIB}/auth".\n> print "loaded".\n'
        programs['json-twice.sol'] = f'J = use "{LIB}/json".\nK = use "{LIB}/json".\n> print (K.render (J.strs ["z"])).\n'
        for name, text in programs.items():
            (gen / name).write_text(text)
        files = sorted(gen.iterdir())
        files += sorted(p for p in ROOT.rglob('*.sol')
                        if not any(part in ('dist-newstyle', '.git', 'build') for part in p.parts)
                        and 'use "' in p.read_text(errors='replace'))
        for f in files:
            differential(f'asm {f.name if f.parent == gen else f.relative_to(ROOT)}', [str(FPR), 'sol', '--asm', str(f)], f.parent, tmp, failures)
            n += 1
        # one cache shared by every program, in order: verdicts recorded for
        # one program are used by the next ones
        for f in files:
            differential(f'shared {f.name if f.parent == gen else f.relative_to(ROOT)}', [str(FPR), 'sol', '--asm', str(f)], f.parent, tmp, failures, shared=True)
            n += 1
        for name in ('json-csv.sol', 'json-shadow.sol', 'json-twice.sol'):
            differential(f'run {name}', [str(FPR), 'sol', str(gen / name)], gen, tmp, failures, canon=False)
            n += 1
        # invalidation: a verdict for json does not cover an edited json
        mine = tmp / 'mine'
        mine.mkdir()
        (mine / 'mylib.sol').write_text('twice x = x * 2.\ngreet n = "hi {n}".\n')
        prog = mine / 'p.sol'
        prog.write_text('M = use "mylib".\n> print (M.twice 21).\n')
        cache = tmp / 'cache-edit'
        run([str(FPR), 'sol', str(prog)], mine, cache)
        warm = run([str(FPR), 'sol', str(prog)], mine, cache)
        with open(mine / 'mylib.sol', 'a') as fh:
            fh.write('\nunusedBroken x = x + "a" + 1.\n')
        edited = run([str(FPR), 'sol', str(prog)], mine, cache)
        full = run([str(FPR), 'sol', str(prog)], mine, tmp / 'cache-full', '0')
        incr.compare('edited library is rechecked', full, edited, failures, canon=False)
        if not (warm[0] == 0 and full[0] != 0):
            failures.append('edited library fixture')
            print('DIFF edited library fixture', warm[0], full[0])
        n += 1
        # options: SOL_NO_SAFETY never records nor uses a verdict
        differential('no-safety json', [str(FPR), 'sol', '--asm', str(gen / 'json-csv.sol')], gen, tmp, failures, extra={'SOL_NO_SAFETY': '1'})
        n += 1
        sessions = {
            'use-json': ['J = use "../lib/json".', '> print (J.render (J.strs ["a"])).', 'f x = J.strs [x].', '> print (J.render (f "b")).'],
            'use-error-recover': ['J = use "../lib/json".', '> print (J.render 3).', '> print (J.nosuch 1).', '> print "fine".', 'C = use "../lib/csv".', '> print "both".'],
            'use-shadow': ['J = use "../lib/json".', 'render x = 1.', '> print (render 0).', '> print (J.render (J.strs []))'],
        }
        # `use` stays in effect for later REPL commands (each command
        # recompiles the session; its imports are spliced afresh)
        r = run([str(FPR), 'sol', '--repl'], ROOT / 'sol' / 'examples', tmp / 'cache-repl', None,
                '\n'.join(sessions['use-json']) + '\n')
        if r[1] != '["a"]\n["b"]\n':
            failures.append('repl use persists')
            print('DIFF repl use persists', r)
        n += 1
        for name, lines in sessions.items():
            differential(f'repl {name}', [str(FPR), 'sol', '--repl'], ROOT / 'sol' / 'examples', tmp, failures,
                         stdin='\n'.join(lines) + '\n', canon=False)
            n += 1
    print(f'{n - len(failures)}/{n} identical')
    for k, v in sorted(TALLY.items()):
        print(f'  incremental: {v:4d} x {k}')
    if not any('verified: sliced' in k for k in TALLY):
        print('FAIL: library slicing was never exercised')
        sys.exit(1)
    if failures:
        print('FAIL: ' + ', '.join(failures))
        sys.exit(1)
    print('PASS sol-library-cache-check')


if __name__ == '__main__':
    main()
