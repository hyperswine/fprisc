#!/usr/bin/env python3
"""Native staging: physical arities, partial snapshots and optimizer-independent effects."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
SOURCE = ROOT / 'tests/typed_core/staging.fpr'
EXPECTED = ('known-first\nknown-entered\nknown-second\nknown-body\n'
            'partial-first\npartial-ready\npartial-second\npartial-entered\npartial-third\npartial-body\n'
            'unknown-first\nunknown-second\nunknown-entered\nunknown-body\n'
            'computed-first\ncomputed-second\ncomputed-entered\ncomputed-body\n'
            'factory\ncaf-first\ncaf-second\ncaf-entered\ncaf-body\n'
            'global-first\nglobal-entered\nglobal-second\nglobal-body\n'
            'captured-first\ncaptured-second\ncaptured-entered\ncaptured-third\ncaptured-body\n'
            'staging 12 13 10 16 117 3 13\n')

def run(args, env, code=0, timeout=120):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p

with tempfile.TemporaryDirectory(prefix='fpr-typed-staging-') as directory:
    temp = Path(directory)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               XDG_CACHE_HOME=str(temp / 'cache'))
    env.pop('FPR_FOREIGN', None)
    # Four cache modes on one hart, plus both extreme modes on four harts.
    for harts, specialize, inline in ((1, 0, 0), (1, 1, 0), (1, 0, 1),
                                     (1, 1, 1), (4, 0, 0), (4, 1, 1)):
        mode = dict(env, FPR_NO_SPEC=str(specialize), FPR_NO_INLINE=str(inline))
        exe = temp / 'staging'
        run([FPR, 'build', SOURCE, '--harts', harts, '-o', exe], mode)
        normal = run([exe], mode)
        assert normal.stdout == EXPECTED and not normal.stderr, (harts, specialize, inline, normal.stdout, normal.stderr)
        for action, prefix, message in [('known', 'known-first\n', 'known body'),
                                        ('unknown', 'unknown-first\n', 'argument panic')]:
            trapped = run([exe, action], mode, code=1)
            expected = prefix + f'[ERR] {message}\n\n*** FPRISC PANIC [actor 0]: {message} ***\n'
            assert trapped.stdout == expected and not trapped.stderr, (action, specialize, inline, trapped.stdout, trapped.stderr)
    # Calling metadata from an imported checked unit must be physical, too.
    remote = temp / 'remote.fpr'
    remote.write_text('unsafe base. first x = _ = print "remote-entered"; fn y -> x + y.\n')
    client = temp / 'client.fpr'
    client.write_text(f'unsafe base. R = use "{remote}". '
                      'later = _ = print "later"; 2. main = print (R.first 1 later).\n')
    for disabled in (0, 1):
        mode = dict(env, FPR_NO_SPEC=str(disabled), FPR_NO_INLINE=str(disabled))
        p = run([FPR, 'run', client], mode)
        assert p.stdout == 'remote-entered\nlater\n3\n' and not p.stderr, (p.stdout, p.stderr)
    for target in ('x64', 'rv32', 'rv64'):
        assembly = temp / f'{target}.s'
        run([FPR, 'compile', f'--target={target}', SOURCE, assembly], env)
        assert re.search(r'^# fn known .*typed-ir ' + target + r' ', assembly.read_text(), re.M), target
print('Typed staging: exact effects/traps in all specialization/inlining cache modes, one/four harts, imported physical entries and x64/RV32/RV64 emission passed')
