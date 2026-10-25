#!/usr/bin/env python3
"""Typed local clones: native object identity, generic code and strict effects."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
SOURCE = ROOT / 'tests/typed_core/callbacks.fpr'
EXPECTED = ('prefix\nready\nfirst\npartial-body\ncapture\nsecond\npartial-body\n'
            'callbacks 7 True 9 True 8 True False 12 True 13 17 27 14 4 23\n')


def run(args, env, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=120)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p


with tempfile.TemporaryDirectory(prefix='fpr-typed-callbacks-') as directory:
    temp = Path(directory)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               XDG_CACHE_HOME=str(temp / 'cache'))
    env.pop('FPR_FOREIGN', None)
    # Warm mode changes use one cache. Native PAP equality is pointer identity;
    # the independent machine-IR evaluator alone cannot test this property.
    for harts, specialize, inline in ((1, 0, 0), (1, 1, 0), (1, 0, 1),
                                     (1, 1, 1), (4, 0, 0), (4, 1, 1)):
        mode = dict(env, FPR_NO_SPEC=str(specialize), FPR_NO_INLINE=str(inline))
        exe = temp / 'callbacks'
        run([FPR, 'build', SOURCE, '--harts', harts, '-o', exe], mode)
        normal = run([exe], mode)
        assert normal.stdout == EXPECTED and not normal.stderr, (harts, specialize, inline, normal.stdout, normal.stderr)
        trapped = run([exe, 'panic'], mode, code=1)
        expected = '[ERR] capture panic\n\n*** FPRISC PANIC [actor 0]: capture panic ***\n'
        assert trapped.stdout == expected and not trapped.stderr, (trapped.stdout, trapped.stderr)
    # Exercise owned imported units and root-dependent cache reuse. A new root
    # declaration changes inference IDs but must leave private code stable.
    module = temp / 'provider.fpr'
    module.write_text('unsafe base. value n = apply f x = f x; apply (fn x -> x + 1) n.\n')
    client = temp / 'client.fpr'
    for extra in ('', 'unrelated x = (x,True). '):
        client.write_text(f'unsafe base. M = use "{module}". {extra}main = print (M.value 8).\n')
        out = run([FPR, 'run', client], env)
        assert out.stdout == '9\n' and not out.stderr, (out.stdout, out.stderr)
    # Assert the typed pass itself emitted clones. A legacy .mono label would
    # not prove that checking evidence survived the specialization boundary.
    for target in ('a64', 'x64', 'rv32', 'rv64'):
        assembly = temp / f'{target}.s'
        mode = dict(env, FPR_NO_SPEC='0', FPR_NO_INLINE='1')
        run([FPR, 'compile', f'--target={target}', SOURCE, assembly], mode)
        text = assembly.read_text()
        assert '$typed.mono.' in text or '_24typed_2emono_2e' in text, target
        assert re.search(r'^# fn localPoly .*typed-ir ' + target + r' ', text, re.M), target
print('Typed callbacks: native identity/effects in all optimizer modes, one/four harts, imports and A64/x64/RV32/RV64 emission passed')
