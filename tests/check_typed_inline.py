#!/usr/bin/env python3
"""Explicit saved/new compiler oracle for the checked Base inliner.

The existing Base inlining job covers default/off behavior in the normal
sweep. This optional paired oracle adds saved-compiler execution and all
eight native emission targets without adding another umbrella job.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tests/base/inlining.fpr'
EXPECTED = ('eval a\neval b\neval c\neval tick\neval tick\n'
            'typed-inline 23 True 3.5 3.5 31\n'
            'r1=6 r2=20 r3=7 r4=12 r5=-91 r6=False r7=15 r8=5\n')


def run(command, env):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=180)
    assert result.returncode == 0, (command, result.stdout[-3000:], result.stderr[-6000:])
    return result


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
    with tempfile.TemporaryDirectory(prefix='fpr-typed-inline-') as directory:
        tmp = Path(directory)
        revisions = {}
        for label, compiler in [('before', args.against.resolve()), ('after', ROOT / 'fpr')]:
            for off in (False, True):
                mode = dict(env, XDG_CACHE_HOME=str(tmp / f'cache-{label}-{off}'))
                if off:
                    mode['FPR_NO_INLINE'] = '1'
                for harts in (1, 4):
                    exe = tmp / f'{label}-{off}-{harts}'
                    run([compiler, 'build', SOURCE, '--harts', harts, '-o', exe], mode)
                    observed = run([exe], mode).stdout
                    assert observed == EXPECTED, (label, off, harts, observed)
                for target in ('a64', 'a64mac', 'qa64mac', 'x64', 'x64mac', 'qx64', 'rv64', 'rv32'):
                    output = tmp / f'{label}-{off}-{target}.s'
                    run([compiler, 'compile', '--target=' + target, SOURCE, output], mode)
                    assembly = output.read_text()
                    assert '# typed IR: no translation' in assembly and 'fpr_fn_main:' in assembly, (label, off, target)
                    assert 'UNBOUNDED' not in assembly, (label, off, target)
                    units = Path(str(output) + '.units')
                    assert units.exists(), (label, off, target, 'missing unit cache identity')
                    versions = {int(re.search(r'-g(\d+)-tirbe', Path(p).name)[1]) for p in units.read_text().splitlines()}
                    assert len(versions) == 1, versions
                    revisions.setdefault(label, versions)
                    assert revisions[label] == versions, (label, versions)
                    if label == 'after':
                        assert versions == {current}, (target, versions, current)
                print(f'{label} inline={not off}: one/four-hart effects/values and eight native targets PASS', flush=True)
        assert revisions['before'] != revisions['after'], revisions
        print('Typed inlining: 8 native executions and 32 emission configurations; distinct codegen/cache revisions PASS')


if __name__ == '__main__':
    main()
