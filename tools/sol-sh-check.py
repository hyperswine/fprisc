#!/usr/bin/env python3
"""`sh` insists (nonzero exit panics), `Try.sh` is the typed Result tier,
`shStatus` keeps the never-failing (code, output) shape."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT/'fpr')).resolve()


def run(src):
    with tempfile.TemporaryDirectory(prefix='sol-sh-') as t:
        f = Path(t)/'s.sol'; f.write_text(src)
        return subprocess.run([str(FPR), 'sol', str(f)], cwd=t, capture_output=True,
                              text=True, timeout=60, env=dict(os.environ, SOL_GPU='0'))


def main():
    n = 0
    r = run('> print (sh "printf hi").\n')
    assert r.returncode == 0 and r.stdout == 'hi\n', r; n += 1
    r = run('> u = print "before"; o = sh "echo boom >&2; exit 3"; print "after {o}".\n')
    assert r.returncode == 1 and 'after' not in r.stdout, r
    assert 'sh: `echo boom >&2; exit 3` exited 3: boom' in r.stderr, r; n += 1
    r = run('> o = sh "sol-no-such-cmd-xyz"; print "after".\n')
    assert r.returncode == 1 and 'exited 127' in r.stderr and 'after' not in r.stdout, r; n += 1
    r = run('> print (case Try.sh "printf o; printf e >&2; exit 5" of Ok o -> "ok {o}"'
            ' | Err (ShError c code o e) -> "cmd={c}|code={code}|out={o}|err={e}").\n')
    assert r.returncode == 0 and r.stdout == 'cmd=printf o; printf e >&2; exit 5|code=5|out=o|err=e\n', r; n += 1
    r = run('> print (case Try.sh "sol-no-such-cmd-xyz" of Ok o -> 0'
            ' | Err (ShError c code o e) -> code).\n')
    assert r.returncode == 0 and r.stdout == '127\n', r; n += 1
    r = run('> print (Try.sh "printf yes").\n')
    assert r.returncode == 0 and r.stdout == 'Ok yes\n', r; n += 1
    r = run('> print (shStatus "printf a; printf b >&2; exit 4").\n')
    assert r.returncode == 0 and r.stdout == '(4, ab)\n', r; n += 1
    print(f'sol-sh-check: {n} checks passed')


if __name__ == '__main__':
    main()
