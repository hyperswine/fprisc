#!/usr/bin/env python3
"""Relative paths resolve against the process cwd (like bash/Python), not
the script directory. `use` imports stay relative to the importing source."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT/'fpr')).resolve()


def main():
    with tempfile.TemporaryDirectory(prefix='sol-cwd-') as t:
        t = Path(t).resolve()
        sdir, cwd = t/'scripts', t/'work'
        sdir.mkdir(); cwd.mkdir()
        (sdir/'rel.txt').write_text('script-dir\n')
        (cwd/'rel.txt').write_text('cwd\n')
        (sdir/'helper.sol').write_text('tag u = "helper".\n')
        script = sdir/'relpath.sol'
        script.write_text(
            'H = use "helper".\n'
            '> print (readPath "rel.txt").\n'
            '> print (exists "only-in-cwd.txt").\n'
            '> print (H.tag Unit).\n'
            '> writePath "out.txt" "written".\n')
        (cwd/'only-in-cwd.txt').write_text('x')
        env = dict(os.environ, SOL_GPU='0')
        p = subprocess.run([str(FPR), 'sol', str(script)], cwd=cwd, env=env,
                           capture_output=True, text=True, timeout=60)
        assert p.returncode == 0, p
        lines = p.stdout.split('\n')
        assert lines[0] == 'cwd', p.stdout          # read resolved against cwd
        assert 'True' in lines[1:3], p.stdout       # exists resolved against cwd
        assert 'helper' in p.stdout, p.stdout       # use is script-relative
        assert (cwd/'out.txt').read_text() == 'written', 'write did not land in cwd'
        assert not (sdir/'out.txt').exists(), 'write landed in the script directory'
    print('sol-cwd-check: 5 checks passed')


if __name__ == '__main__':
    main()
