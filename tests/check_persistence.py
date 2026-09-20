#!/usr/bin/env python3
"""Real failed append, restore/schema errors, strict event replay and compaction.
Uses the existing ./fpr binary; build it first after compiler changes.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, cwd, expected=0):
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                       capture_output=True, text=True, timeout=120)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout + p.stderr


with tempfile.TemporaryDirectory(prefix='fpr-persistence-') as temp:
    tmp = Path(temp)
    env = {**os.environ, 'FPR_HOME': str(ROOT), 'XDG_CACHE_HOME': str(tmp / 'cache')}
    exe = tmp / 'persistence'
    run([ROOT / 'fpr', 'build', 'tests/base/persistence_failure.fpr', '-o', exe], ROOT)
    work = tmp / 'work'
    work.mkdir()
    (work / 'directory').mkdir()
    output = run([exe], work)
    assert output == ('failed append preserves memory\n'
                      'restore rejects incompatible field\n'
                      'replay rejects incompatible events and malformed envelopes\n'), output
    output = run([exe, 'put-panic'], work, expected=1)
    assert 'kvlog: cannot save count:' in output, output
    assert 'unreachable after failed put' not in output, output
    compact = tmp / 'compact'
    run([ROOT / 'fpr', 'build', 'tests/std/compact.fpr', '-o', compact], ROOT)
    output = run([compact], work)
    assert output == (ROOT / 'tests/std/compact.expected').read_text(), output
    print('Persistence failures, valid restore/replay, and compaction: PASS')
