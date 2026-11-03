#!/usr/bin/env python3
"""The inline bump allocation (docs/2026-11-03-INLINE-BUMP-ALLOC.md).

1. Differential: every program prints the same with the fast path on (the
   default) and off (FPR_NO_BUMP_ALLOC=1), on one and four harts.  The set
   covers the allocating unbox rows (fused and FPR_NO_LIST_FUSE), loop and
   call regions cycling per slab (regionnest), call regions past the pend
   stack across a Sys.poolReset (pendreset), arenas and turn roots
   (turnroots), fixed heaps (fixedheap), parked receive loops (autodrop3) and
   eight actors migrating while they allocate (tests/bump_alloc/actors.fpr).
2. The bump-check runtime (FPR_BUMP_CHECK=1) verifies at every fuel tick and
   refill that an open window is the current pool's bump slab; each program
   must print the same under it, and the allocating ones must have been seen
   with a window open (not vacuous) and with refills (slabs filled under load).
3. Emitted code: on x64, a64mac and rv64 a cons builder bumps inline (the
   unit's fpr_alloc_save_local refill, no fpr_alloc call in the function);
   off, it calls fpr_alloc and the unit has no refill wrapper.
"""
from pathlib import Path
import os, re, subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parents[1]
UNBOX = ROOT / 'tests/bench/unbox'
PROBE = ROOT / 'tests/arc_churn/arcprobe.c'

# (name, source, extra build arguments, extra environment, allocates)
PROGRAMS = [
    ('list_fold', UNBOX / 'list_fold.fpr', [], {}, True),
    ('list_length_rev', UNBOX / 'list_length_rev.fpr', [], {}, True),
    ('tree_sum', UNBOX / 'tree_sum.fpr', [], {}, True),
    ('list_map_unfused', UNBOX / 'list_map.fpr', [], {'FPR_NO_LIST_FUSE': '1'}, True),
    ('list_filter_unfused', UNBOX / 'list_filter.fpr', [], {'FPR_NO_LIST_FUSE': '1'}, True),
    ('regionnest', ROOT / 'tests/base/regionnest.fpr', ['--with', PROBE], {}, True),
    ('pendreset', ROOT / 'tests/base/pendreset.fpr', ['--with', PROBE], {'FPR_NO_INLINE': '1'}, True),
    ('turnroots', ROOT / 'tests/base/turnroots.fpr', [], {}, True),
    ('fixedheap', ROOT / 'tests/base/fixedheap.fpr', [], {}, False),
    ('autodrop3', ROOT / 'tests/base/autodrop3.fpr', ['--with', PROBE], {}, True),
    ('actors', ROOT / 'tests/bump_alloc/actors.fpr', [], {}, True),
]

CONS = '''build : unsafe Int -> List Int -> List Int .
build n acc = if n == 0 then acc else build (n - 1) (n :: acc).
main = print "{build 3 Nil}".
'''

CHECK_LINE = re.compile(r'\[bump-check\] checks (\d+) open (\d+) calls (\d+)\n')


def run(args, env, timeout=600):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def fn_block(asm, prefix):
    m = re.search(rf'(?ms)^# fn {re.escape(prefix)}[^\n]*\n.*?(?=^# native-insns-v1:[^\n]*\n)', asm)
    assert m, f'missing function {prefix}'
    return m.group(0)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-bump-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'),
                    FPR_NO_RUN_CACHE='1')

        # 1 and 2: differential and the bump-check runtime
        for name, src, args, extra, allocates in PROGRAMS:
            exes = {}
            for mode, menv in (('on', {}), ('off', {'FPR_NO_BUMP_ALLOC': '1'}), ('check', {'FPR_BUMP_CHECK': '1'})):
                env = dict(base, **extra, **menv)
                exe = tmp / f'{name}-{mode}'
                made = run([ROOT / 'fpr', 'build', src, *args, '-o', exe], env)
                assert made.returncode == 0, (name, mode, made.stdout[-2000:], made.stderr[-4000:])
                exes[mode] = exe
            for harts in ('1', '4'):
                env = dict(base, FPR_HARTS=harts)
                out = {mode: run([exe], env, timeout=300) for mode, exe in exes.items()}
                on, off, check = out['on'], out['off'], out['check']
                assert (on.returncode, on.stdout) == (off.returncode, off.stdout), (name, harts, on.stdout, on.stderr[-2000:], off.stdout, off.stderr[-2000:])
                assert '[bump-check]' not in on.stderr, (name, on.stderr)
                m = CHECK_LINE.search(check.stderr)
                assert m and (check.returncode, check.stdout) == (on.returncode, on.stdout), (name, harts, check.stdout, check.stderr[-2000:])
                checks, opened, refills = map(int, m.groups())
                if allocates:
                    assert opened > 0 and refills > 0, (name, harts, m.group(0))
                print(f'Inline bump differential: {name} on {harts} hart(s) -> {on.stdout.strip()[:60]!r}, '
                      f'bump-check {checks} checks, {opened} with a window open, {refills} fpr_alloc calls PASS', flush=True)

        # 3: the fast path in emitted code, per target
        src = tmp / 'cons.fpr'
        src.write_text(CONS)
        for target in ('x64', 'a64mac', 'rv64'):
            texts = {}
            for mode, menv in (('on', {}), ('off', {'FPR_NO_BUMP_ALLOC': '1'})):
                asm = tmp / f'cons-{target}-{mode}.s'
                made = run([ROOT / 'fpr', 'compile', '--system=posix', f'--target={target}', src, asm], dict(base, **menv))
                assert made.returncode == 0, (target, mode, made.stderr[-4000:])
                texts[mode] = asm.read_text()
            on, off = fn_block(texts['on'], 'build'), fn_block(texts['off'], 'build')
            calls = re.compile(r'\b(bl|call)\s+_?fpr_alloc\b')
            assert 'fpr_alloc_save_local' in on and not calls.search(on), (target, on)
            assert calls.search(off) and 'fpr_alloc_save_local' not in off, (target, off)
            assert 'fpr_alloc_save_local:' in texts['on'] and 'fpr_alloc_save_local:' not in texts['off'], target
            print(f'Inline bump selection ({target}): the cons cell bumps the hart window, '
                  f'fpr_alloc only through the unit\'s refill wrapper; off keeps the call PASS', flush=True)


if __name__ == '__main__':
    main()
