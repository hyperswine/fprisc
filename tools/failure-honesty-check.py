#!/usr/bin/env python3
"""Publication, precondition and atomic-write failure regressions."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
with tempfile.TemporaryDirectory(prefix='fpr-honesty-') as tmp:
    work = Path(tmp)
    env = os.environ | {'FPR_HOME': str(ROOT), 'SOL_CACHE_DIR': str(work / 'cache'), 'SOL_GPU': '0'}
    env.pop('FPR_FOREIGN', None)
    def run(args, code=0, text=None):
        r = subprocess.run([str(FPR), *args], cwd=work, env=env, capture_output=True, text=True, timeout=30)
        assert r.returncode == code, (args, r.stdout, r.stderr)
        if text:
            assert text in r.stdout + r.stderr, (args, r.stdout, r.stderr)
        return r
    def sol(name, source, code=0, text=None):
        p = work / (name + '.sol')
        p.write_text(source)
        return run(['sol', str(p)], code, text)
    bad = work / 'bad.fpr'
    bad.write_text('f x = 1 + "wrong".\n')
    run(['commit', str(bad)], 1, 'TYPE ERRORS')
    assert not (work / '.fpr').exists()
    for name, source, diagnostic in [
        ('linear', 'f x = v = Vec.new Unit; a = Vec.free v; Vec.free v.\n', 'LINEARITY'),
        ('hole', 'f x = ?missing.\n', 'TYPED HOLES'),
        ('recursive', 'f n = f n.\n', 'SAFETY'),
    ]:
        module = work / (name + '.fpr')
        module.write_text(source)
        run(['commit', str(module)], 1, diagnostic)
        assert not (work / '.fpr').exists()
    good = work / 'good.fpr'
    good.write_text('inc x = x + 1.\n')
    run(['commit', str(good)], text='committed good.v1.0')
    db = (work / '.fpr/versions.db').read_bytes()
    good.write_text('inc x = 1 + "wrong".\n')
    run(['commit', str(good)], 1, 'TYPE ERRORS')
    assert (work / '.fpr/versions.db').read_bytes() == db
    (work / 'untrusted.fpr').write_text('loop : unsafe Int -> Int.\nloop n = loop n.\n')
    caller = work / 'caller.fpr'
    caller.write_text('M = use "untrusted".\nmain = M.loop 1.\n')
    run(['--check-only', str(caller), '/dev/null'], 1, 'main is unsafe')
    (work / 'blanket.fpr').write_text('unsafe module.\nloop n = loop n.\n')
    blanket_caller = work / 'blanket-caller.fpr'
    blanket_caller.write_text('M = use "blanket".\nmain = M.loop 1.\n')
    run(['--check-only', str(blanket_caller), '/dev/null'], 1, 'main is unsafe')
    sol('blanket-import', 'M = use "blanket.fpr".\n> print "{M.loop 1}".', 1, 'main is unsafe')
    # Do not execute the intentionally divergent fixture.
    caller.write_text('M = use "untrusted".\nmain : unsafe Int.\nmain = M.loop 1.\n')
    run(['--check-only', str(caller), '/dev/null'])
    sol('unsafe-import', 'M = use "untrusted.fpr".\n> print "{M.loop 1}".', 1, 'main is unsafe')
    (work / 'dotted.fpr').write_text('Ops = Struct {loop = fn n -> loop n}.\nloop : unsafe Int -> Int.\nloop n = loop n.\n')
    # Qualification through a local struct must not grant a trust boundary.
    sol('unsafe-struct', 'loop : unsafe Int -> Int.\nloop n = loop n.\nOps = Struct {loop = fn n -> loop n}.\nf n = Ops.loop n.\n> print "{f 1}".', 1, 'SAFETY')
    # A changed trust policy must invalidate warm Sol artifacts.
    core = work / 'core'
    core.mkdir()
    manifest = core / 'trusted-modules.txt'
    manifest.write_text('../untrusted.fpr\n')
    old_home = env['FPR_HOME']
    env['FPR_HOME'] = str(work)
    env['FPR_PATH'] = str(ROOT)
    sol('trust-cache', 'M = use "untrusted.fpr".\n> print "safe startup".', text='safe startup')
    # The marked function is unreachable so it is safe to warm this artifact.
    sol('trust-cache', 'M = use "untrusted.fpr".\n> print "safe startup".', text='safe startup')
    manifest.write_text('')
    # An unmarked imported wrapper must fail even without executing it.
    (work / 'wrapper.fpr').write_text('M = use "untrusted".\nf n = M.loop n.\n')
    manifest.write_text('../untrusted.fpr\n../wrapper.fpr\n')
    sol('policy-cache', 'W = use "wrapper.fpr".\n> print "policy warm".', text='policy warm')
    manifest.write_text('')
    sol('policy-cache', 'W = use "wrapper.fpr".\n> print "policy warm".', 1, 'SAFETY')
    env['FPR_HOME'] = old_home
    contract = 'positive : (n : Int | n > 0) -> Int.\npositive n = n.\n'
    sol('positive', contract + '> print "{positive 2}".\n', text='2')
    for entry in ['> print "{positive (-1)}".', 'main = print "{positive (-1)}".']:
        sol('negative', contract + entry, 1, 'precondition violated: positive')
    rollback = work / 'must-not-commit'
    sol('contract-rollback', contract + f'> u = writePath "{rollback}" "partial"; print "{{positive (-1)}}".', 1, 'precondition violated')
    assert not rollback.exists()
    (work / 'contract.sol').write_text(contract)
    sol('imported-contract', 'P = use "contract".\n> print "{P.positive (-1)}".', 1, 'precondition violated: P.positive')
    sol('fragment', 'bad : (n : Int | bogus n) -> Int.\nbad n = n.\n> print "{bad 2}".', 1, 'outside the decidable fragment')
    target = work / 'executable'
    target.write_text('old')
    target.chmod(0o751)
    sol('mode', f'> writePath "{target}" "new".\n')
    assert target.read_text() == 'new' and stat.S_IMODE(target.stat().st_mode) == 0o751
    link = work / 'link'
    link.symlink_to(target)
    sol('symlink', f'> writePath "{link}" "bad".\n', 1, 'refusing symbolic link')
    assert link.is_symlink() and target.read_text() == 'new'
    dangling = work / 'dangling'
    dangling.symlink_to(work / 'absent')
    sol('dangling', f'> writePath "{dangling}" "bad".\n', 1, 'refusing symbolic link')
    assert dangling.is_symlink() and not (work / 'absent').exists()
print('failure honesty: commit, contracts, mode and symlinks HOLD')
