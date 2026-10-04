#!/usr/bin/env python3
"""Commit compares checked inferred types and contracts, with no refusal writes."""
import re
import subprocess
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'

def snapshot(cwd):
    store = cwd / '.fpr'
    return {str(p.relative_to(cwd)): p.read_bytes() for p in store.rglob('*') if p.is_file()}

def commit(cwd, text=None, major=False, success=True):
    if text is not None:
        (cwd/'dep.fpr').write_text(text)
    before = snapshot(cwd)
    p = subprocess.run([str(FPR), 'commit', 'dep.fpr', *(['--major'] if major else [])],
                       cwd=cwd, capture_output=True, text=True, timeout=180)
    out = p.stdout + p.stderr
    assert (p.returncode == 0) == success, out
    if not success:
        assert snapshot(cwd) == before, ('refusal mutated the store', out)
    return out

cases = [
    ('unannotated argument/result', 'op x = x + 1.\n', 'op x = x + "!".\n'),
    ('polymorphic restriction', 'op x = x.\n', 'op x = x + 0.\n'),
    ('variable correlation', 'op x y = (x, x).\n', 'op x y = (x, y).\n'),
    ('record requirement', 'op r = r.a.\n', 'op r = r.b.\n'),
    ('constant representation', 'value = 1.\n', 'value = "text".\n'),
    ('precondition', 'op : (x : Int | x > 0) -> Int .\nop x = x.\n',
                     'op : (x : Int | x > 1) -> Int .\nop x = x.\n'),
    ('unsafe marker', 'op : Int -> Int .\nop x = x + 1.\n',
                      'op : unsafe Int -> Int .\nop 0 = 0.\nop x = op (x - 1).\n'),
    ('resource bound', 'op : (x : Int) -> Int | work op <= 20 .\nop x = x + 1.\n',
                       'op : (x : Int) -> Int | work op <= 21 .\nop x = x + 1.\n'),
    ('nominal version', 'Box = Type (Box x).\nop x = Box (x + 1).\n',
                        'Box = Type (Box x).\nop x = Box (x + 2).\n'),
    ('linear declaration', 'Box 1 = Type (Box Int).\nop x = x + 1.\n',
                           'Box = Type (Box Int).\nop x = x + 1.\n'),
]
with tempfile.TemporaryDirectory(prefix='fpr-commit-interface-') as temp:
    root = Path(temp)
    for i, (name, old, new) in enumerate(cases):
        cwd = root / str(i); cwd.mkdir()
        assert 'first version' in commit(cwd, old)
        out = commit(cwd, new, success=False)
        assert 'commit refused: not a compatible subset' in out, out
        assert 'MAJOR' in commit(cwd, major=True)
        print(f'commit {name}: refusal leaves store unchanged; explicit major PASS')
    cwd = root/'stable'; cwd.mkdir()
    commit(cwd, 'id x = x.\nmake x y = {b = y, a = x}.\n')
    out = commit(cwd, 'extra q = (q, q).\nid x = x.\nmake x y = {a = x, b = y}.\n')
    assert 'patch: signature-compatible' in out, out
    assert 'no-op' in commit(cwd), 'exact content must remain a checked no-op'
    print('commit alpha normalization, sorted rows, export additions and no-op: PASS')
    cwd = root/'bad'; cwd.mkdir()
    commit(cwd, 'op x = x + 1.\n')
    assert 'TYPE ERRORS' in commit(cwd, 'op x = x + True.\n', success=False)
    # Missing or malformed history must never become an empty old interface.
    (cwd/'dep.fpr').write_text('op x = x + 2.\n')
    h = (cwd/'.fpr/versions.db').read_text().split()[2]
    old_blob = cwd/'.fpr/store'/f'{h}.fpr'
    old_blob.unlink()
    assert 'prior version blob missing' in commit(cwd, success=False)
    assert 'prior version blob missing' in commit(cwd, 'op x = x + 1.\n', success=False)
    (cwd/'dep.fpr').write_text('op x = x + 2.\n')
    old_blob.write_text('op x = x + 3.\n')
    assert 'prior version blob hash mismatch' in commit(cwd, success=False)
    old_blob.write_text('this is not a module')
    assert 'prior version cannot load' in commit(cwd, success=False)
    print('commit type error and missing/malformed prior blob: refusal before writes PASS')

    cwd = root/'closure'; cwd.mkdir()
    commit(cwd, 'op x = x + 1.\n')
    helper = cwd/'helper.fpr'; helper.write_text('convert x = x + "!".\n')
    p = subprocess.run([str(FPR), '--check-only', '--lib', 'helper.fpr', '/dev/null'],
                       cwd=cwd, capture_output=True, text=True, timeout=180)
    assert p.returncode == 0, p.stdout + p.stderr
    h = re.search(r'helper.fpr#([0-9a-f]+)', p.stdout).group(1)
    commit(cwd, f'H = use "helper#{h}".\nop x = H.convert x.\n', success=False)
    assert not (cwd/'.fpr/store'/f'{h}.fpr').exists()
    print('commit refused new pinned dependency: no closure blob publication PASS')

    cwd = root/'dependency'; cwd.mkdir()
    helper = cwd/'helper.fpr'; helper.write_text('twice x = x * 2.\n')
    p = subprocess.run([str(FPR), '--check-only', '--lib', 'helper.fpr', '/dev/null'],
                       cwd=cwd, capture_output=True, text=True, timeout=180)
    assert p.returncode == 0, p.stdout + p.stderr
    h = re.search(r'helper.fpr#([0-9a-f]+)', p.stdout).group(1)
    header = f'H = use "helper#{h}".\n'
    commit(cwd, header + 'op x = H.twice x + 1.\n')
    helper.unlink()
    assert 'patch: signature-compatible' in commit(cwd, header + 'op x = H.twice x + 2.\n')
    print('commit checked pinned closure from store, no scratch dependency: PASS')
    cwd = root/'positions'; cwd.mkdir()
    signed = 'op : (x : Int | x > 0) -> Int .\nop x = x.\n'
    commit(cwd, signed)
    assert 'patch: signature-compatible' in commit(cwd, 'extra q = q.\n' + signed)
    print('commit contract identity ignores diagnostic source positions: PASS')
