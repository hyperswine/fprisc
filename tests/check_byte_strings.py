#!/usr/bin/env python3
"""Byte-string values, allocation contract, failure guards and actor lifetime."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args, env, expected=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=180)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout + p.stderr

with tempfile.TemporaryDirectory(prefix='fpr-byte-strings-') as temp:
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               FPR_COST_PROBE='1', XDG_CACHE_HOME=temp)
    env.pop('FPR_FOREIGN', None)
    exe = Path(temp) / 'bytestrings'
    run([ROOT/'fpr', 'build', 'tests/base/bytestrings.fpr', '--harts', '4',
         '--with', 'tests/base/bytestrings_probe.c', '-o', exe], env)
    images = Path(temp) / 'images'
    run([ROOT/'fpr', 'build', 'tests/base/images.fpr', '--harts', '4',
         '--with', 'tests/base/images_probe.c', '-o', images], env)
    for harts in ('1', '4'):
        e = dict(env, FPR_HARTS=harts)
        assert 'byte Strings: 256 values, zero chr allocations, encodings and actor lifetime PASS' in run([exe], e)
        for mode, message in (
            ('negative', 'chr: -1 is not a byte (0..255)'),
            ('overflow', 'chr: 256 is not a byte (0..255)'),
            ('type', 'chr: not an Int'),
        ):
            assert message in run([exe, mode], e, 1)
        image_result = run([images], e)
        assert 'kept: from the image; a function of the image: refused' in image_result, image_result
        print(f'Byte Strings: all values, zero allocations, actor lifetime and refusals ({harts} workers) PASS')
        print(f'Foreign image: byte Strings survive poisoning/unload ({harts} workers) PASS')
