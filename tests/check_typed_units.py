#!/usr/bin/env python3
"""Checked unit execution and warm context/calling-arity cache transitions.

The caller builds fpr once. Keep all roots in one cache so stale cross-root
reuse would be observable, rather than hidden by per-case build directories.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-checked-units-') as directory:
        tmp = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'))

        def run(args, code=0):
            p = subprocess.run(list(map(str, args)), cwd=tmp, env=env, capture_output=True,
                               text=True, timeout=120)
            assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
            return p

        def execute(name, source, expected, harts=1):
            path = tmp / (name + '.fpr')
            path.write_text(source)
            image = tmp / name
            run([ROOT / 'fpr', 'build', path, '--harts', harts, '-o', image])
            p = run([image])
            assert p.stdout == expected and not p.stderr, (name, p.stdout, p.stderr)
            return path

        (tmp / 'provider.fpr').write_text('value n = n * 1.25.\n')
        (tmp / 'client.fpr').write_text('P = use "provider.fpr".\n'
                                      'twice n = P.value n + P.value n.\n'
                                      'local n = loop k = if k == 0 then P.value n else loop (k - 1); loop 2.\n')
        source = 'unsafe base. M = use "client.fpr". main = print "checked-units {M.twice 2.0} {M.local 2.0}".\n'
        for harts in (1, 4):
            execute(f'transitive-{harts}', source, 'checked-units 5 2.5\n', harts)
        unit_dir = tmp / 'cache/fpr/build/units'

        def keys():
            return {p.name: p.stat().st_mtime_ns for p in unit_dir.glob('u-*.s')}

        assert keys(), 'native build did not populate the shared unit cache'
        assert any('$typed_recursive_' in p.read_text() for p in unit_dir.glob('u-*.s')), 'imported recursive function missed typed closure conversion'
        # The unit's body stays the same while a root supplies the type and
        # implementation of a global. Both operator decisions must be keyed.
        (tmp / 'context.fpr').write_text('twice n = rootValue n + rootValue n.\n')
        previous = keys()
        float_root = 'unsafe base. M = use "context.fpr". rootValue n = n * 1.25. main = print (M.twice 2.0).\n'
        execute('float-root', float_root, '5\n')
        floating = keys()
        assert len(floating.keys() - previous.keys()) == 1, (previous, floating)
        execute('int-root', 'unsafe base. M = use "context.fpr". rootValue n = n * 2. main = print (M.twice 3).\n', '12\n')
        integer = keys()
        assert len(integer.keys() - floating.keys()) == 1, (floating, integer)
        execute('unrelated-root', float_root + 'Unrelated = Type Int. unused x = x.\n', '5\n')
        assert keys() == integer, 'an unrelated root declaration invalidated or rewrote a reusable unit'
        execute('float-again', float_root, '5\n')
        assert keys() == integer, 'warm return to the original context failed to reuse its unit'
        # Equal logical types and unit Core can still need different native
        # calls when a root exports a flat entry versus a curried function.
        (tmp / 'arity.fpr').write_text('combine n = rootValue n 4.\n')
        flat = 'unsafe base. M = use "arity.fpr". rootValue x y = x + y. main = print (M.combine 3).\n'
        execute('flat-root', flat, '7\n')
        flat_keys = keys()
        assert len(flat_keys.keys() - integer.keys()) == 1, (integer, flat_keys)
        curried = 'unsafe base. M = use "arity.fpr". rootValue x = fn y -> x + y. main = print (M.combine 3).\n'
        path = execute('curried-root', curried, '7\n')
        curried_keys = keys()
        assert len(curried_keys.keys() - flat_keys.keys()) == 1, (flat_keys, curried_keys)
        execute('flat-again', flat, '7\n')
        assert keys() == curried_keys, 'warm callable-arity transition failed to reuse the original unit'
        for target in ('x64', 'rv32', 'rv64'):
            output_dir = tmp / target
            output_dir.mkdir()
            output = output_dir / 'root.s'
            run([ROOT / 'fpr', 'compile', f'--target={target}', path, output])
            emitted = list((output_dir / 'units').glob('u-*.s'))
            assert output.exists() and emitted, (target, emitted)
            assert all('ccore2-' in p.name for p in emitted), (target, emitted)
        # The imported caller is unchanged while its root-provided callee
        # changes from bounded arithmetic to allocating recursion and back.
        # Region placement (and therefore the cache key) must follow the
        # current post-linked body, including on an otherwise warm build.
        (tmp / 'cost-context.fpr').write_text('invoke n = rootWork n.\n')
        env.update(FPR_NO_INLINE='1', FPR_NO_SPEC='1', FPR_NO_SCALAR_WORKERS='1',
                   FPR_NO_FIELD_WORKERS='1', FPR_RECEIVE_NOTES='1')
        cost_root = tmp / 'cost-root.fpr'
        header = 'unsafe base. M = use "cost-context.fpr".\n'
        small = header + 'rootWork n = n + 1. main = print (M.invoke 12).\n'
        large = header + ('rootWork n = if n == 0 then 0 else '
                          'strlen "row {n}" + rootWork (n - 1). '
                          'main = print (M.invoke 12).\n')
        snapshots = []
        for label, body, expected, pending in [('small', small, '13\n', False),
                                                ('large', large, '63\n', True),
                                                ('small-again', small, '13\n', False)]:
            cost_root.write_text(body)
            image = tmp / ('cost-' + label)
            built = run([ROOT / 'fpr', 'build', cost_root, '-o', image])
            assert run([image]).stdout == expected, label
            call_notes = [line for line in built.stderr.splitlines()
                          if line.startswith('call-regions: invoke@')]
            assert bool(call_notes) == pending, (label, built.stderr)
            snapshots.append(keys())
        assert snapshots[0].keys() < snapshots[1].keys(), 'callee cost change failed to emit a new caller'
        assert snapshots[1] == snapshots[2], 'warm cost reversal failed to reuse the original caller'
        print('Typed units: transitive F64/recursive imports on one/four harts; warm Float/Int/context/flat-curried arity transitions, unrelated-root/cost-transition reuse and x64/RV32/RV64 emission passed')


if __name__ == '__main__':
    main()
