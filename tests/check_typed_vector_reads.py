#!/usr/bin/env python3
"""Optional saved/new compiler oracle for checked pair-free vector reads.

The existing typed-Core/vecpeek jobs own normal CI coverage; this adds paired
runtime/trap and eight-target emission evidence without another umbrella job.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tests/typed_core/vector_reads.fpr'
EXPECTED = 'wide\nnarrow\npair\nrecord\nvector-reads 7.5 2.25 17 True 23 False 1 29\n'


def run(command, env, expected=0):
    p = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=180)
    assert p.returncode == expected, (command, p.returncode, p.stdout[-3000:], p.stderr[-6000:])
    return p


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--against', required=True, type=Path)
    args = parser.parse_args()
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
        if Path(keg).is_dir():
            env['PKG_CONFIG_PATH'] = keg + ':' + env.get('PKG_CONFIG_PATH', '')
            break
    current = int(re.search(r'^codegenRev = (\d+)', (ROOT / 'compiler/Codegen.hs').read_text(), re.M)[1])
    reference_traps = {}
    revisions = {}
    with tempfile.TemporaryDirectory(prefix='fpr-typed-vector-read-') as directory:
        tmp = Path(directory)
        for label, compiler in [('before', args.against.resolve()), ('after', ROOT / 'fpr')]:
            for off in (False, True):
                for no_inline in (False, True):
                    mode = dict(env, XDG_CACHE_HOME=str(tmp / f'cache-{label}-{off}-{no_inline}'),
                                FPR_NO_VEC_PEEK=str(int(off)), FPR_NO_INLINE=str(int(no_inline)))
                    for harts in (1, 4):
                        exe = tmp / f'{label}-{off}-{no_inline}-{harts}'
                        run([compiler, 'build', SOURCE, '--harts', harts, '-o', exe], mode)
                        p = run([exe], mode)
                        assert p.stdout == EXPECTED and not p.stderr, (label, off, no_inline, harts, p.stdout, p.stderr)
                        for failure, prefix, message in [('at', 'before-at\n', 'Vec.get: index out of range'),
                                                         ('get', 'before-get\n', 'Vec.get: index out of range'),
                                                         ('pattern', 'before-pattern\n', 'let pattern: no match'),
                                                         ('index', '', 'division by zero'),
                                                         ('discard', 'before-discard\n', 'Vec.get: index out of range')]:
                            p = run([exe, failure], mode, expected=1)
                            m = re.search(r'PANIC \[actor 0\]: (.*?) \*\*\*', p.stdout + p.stderr)
                            assert m and message in m[1] and p.stdout.startswith(prefix), (failure, p.stdout, p.stderr)
                            # No label may run when its index argument traps.
                            if failure == 'index':
                                assert 'before-index' not in p.stdout, p.stdout
                            observed = (p.stdout, m[1])
                            reference_traps.setdefault(failure, observed)
                            assert observed == reference_traps[failure], (label, off, no_inline, harts, failure, observed)
                    for target in ('a64', 'a64mac', 'qa64mac', 'x64', 'x64mac', 'qx64', 'rv64', 'rv32'):
                        output = tmp / f'{label}-{off}-{no_inline}-{target}.s'
                        run([compiler, 'compile', '--target=' + target, SOURCE, output], mode)
                        assembly = output.read_text()
                        assert '# typed IR: no translation' in assembly and 'fpr_fn_main:' in assembly, target
                        assert '# wcet:' not in assembly and 'UNBOUNDED' not in assembly, target
                        units = Path(str(output) + '.units')
                        versions = {int(re.search(r'-g(\d+)-tirbe', Path(p).name)[1]) for p in units.read_text().splitlines()}
                        revisions.setdefault(label, versions)
                        assert len(versions) == 1 and versions == revisions[label], (label, target, versions)
                        if label == 'after':
                            assert versions == {current}, (target, versions, current)
                    print(f'{label} peek={not off} inline={not no_inline}: one/four-hart values/effects/traps and eight targets PASS', flush=True)
        assert revisions['before'] != revisions['after'], revisions
        print('Typed vector reads: 16 executions, 80 trap checks, 64 emission configurations and distinct cache revisions PASS')


if __name__ == '__main__':
    main()
