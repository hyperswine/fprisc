#!/usr/bin/env python3
"""Filesystem metadata and listing contract for the Sol script runner.

Covers the Phase 1 first slice of docs/2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md:
exists/stat on directories must observe metadata instead of panicking on a
content snapshot, and ls must distinguish missing/wrong-kind from an empty
directory while still composing the transaction's own pending mkdir/write/
remove view.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
ENV = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')} | {'SOL_GPU': '0'}


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-fs-') as tmp:
        work = Path(tmp)
        ENV['SOL_CACHE_DIR'] = str(work / 'cache')
        empty = work / 'empty'
        empty.mkdir()
        full = work / 'full'
        (full / 'sub').mkdir(parents=True)
        (full / 'a.txt').write_text('a')
        (full / 'b.txt').write_text('b')
        plain = work / 'plain.txt'
        plain.write_text('text')
        dangling = work / 'dangling'
        dangling.symlink_to(work / 'no-such-target')

        def check(name, source, stdout=b'', code=0, error=None):
            nonlocal count
            path = work / (name + '.sol')
            path.write_text(source)
            result = subprocess.run([str(FPR), 'sol', str(path)],
                                    capture_output=True, env=ENV, timeout=30)
            assert result.returncode == code, (name, result)
            assert result.stdout == stdout, (name, result.stdout, stdout, result.stderr)
            if error is None:
                assert result.stderr == b'', (name, result.stderr)
            else:
                assert error in result.stderr, (name, result.stderr)
            count += 1
            return result

        # ---- exists: metadata observation, no content snapshot --------------
        check('exists_file', f'> p = "{plain}"; print "{{exists p}}".\n', b'True\n')
        check('exists_missing', f'> p = "{work}/nope"; print "{{exists p}}".\n', b'False\n')
        check('exists_dir', f'> p = "{full}"; print "{{exists p}}".\n', b'True\n')
        check('exists_empty_dir', f'> p = "{empty}"; print "{{exists p}}".\n', b'True\n')
        check('exists_dangling', f'> p = "{dangling}"; print "{{exists p}}".\n', b'False\n')

        # ---- isDir: unchanged metadata surface -------------------------------
        check('isdir_dir', f'> p = "{full}"; print "{{isDir p}}".\n', b'True\n')
        check('isdir_file', f'> p = "{plain}"; print "{{isDir p}}".\n', b'False\n')

        # ---- stat: presence bit for every kind, none of them panics ---------
        check('stat_file', f'> p = "{plain}"; (e, sz, mt) = stat p; print "{{e}} {{sz > 0}} {{mt > 0}}".\n',
              b'True True True\n')
        check('stat_missing', f'> p = "{work}/nope"; (e, sz, mt) = stat p; print "{{e}} {{sz}} {{mt}}".\n',
              b'False 0 0\n')
        check('stat_dir', f'> p = "{full}"; (e, sz, mt) = stat p; print "{{e}} {{mt > 0}}".\n',
              b'True True\n')
        check('stat_dangling', f'> p = "{dangling}"; (e, sz, mt) = stat p; print "{{e}} {{sz}} {{mt}}".\n',
              b'False 0 0\n')

        # ---- ls: missing/wrong-kind fail, empty is empty ---------------------
        check('ls_empty', f'> p = "{empty}"; print "{{ls p}}".\n', b'[]\n')
        check('ls_full', f'> p = "{full}"; print "{{ls p}}".\n', b'[a.txt, b.txt, sub]\n')
        check('ls_missing', f'> p = "{work}/nope"; ls p.\n', code=1,
              error=b'SOL PANIC: ls: no such directory')
        check('ls_wrong_kind', f'> p = "{plain}"; ls p.\n', code=1,
              error=b'SOL PANIC: ls:')

        # ---- the transaction's own view composes (txn_iso.sol semantics) ----
        # A pending mkdir answers ls/stat/exists even though the disk still
        # lacks the directory; this is the path missing-as-[] used to mask.
        pending = work / 'pending'
        rmtest = work / 'rmtest'
        check('ls_pending_mkdir', f'> u = mkdirp "{pending}"; p = "{pending}"; print "{{ls p}}".\n',
              b'[]\n')
        check('ls_pending_writes',
              f'> u = mkdirp "{pending}"; v = write "{pending}/f.txt" "x"; p = "{pending}";'
              f' print "{{ls p}}".\n',
              b'[f.txt]\n')
        check('exists_pending_mkdir', f'> u = mkdirp "{pending}"; p = "{pending}"; print "{{exists p}}".\n',
              b'True\n')
        check('stat_pending_mkdir',
              f'> u = mkdirp "{pending}"; p = "{pending}"; (e, sz, mt) = stat p; print "{{e}} {{mt > 0}}".\n',
              b'True True\n')
        check('ls_removed_entry',
              f'> u = mkdirp "{rmtest}"; v = write "{rmtest}/g.txt" "y"; w = rm "{rmtest}/g.txt";'
              f' p = "{rmtest}"; print "{{ls p}}".\n',
              b'[]\n')
        # a directory this transaction removed is not listable
        check('ls_after_rmdir',
              f'> u = mkdirp "{work}/gone"; v = rmdir "{work}/gone"; p = "{work}/gone"; ls p.\n',
              code=1, error=b'SOL PANIC: ls: no such directory')
        # stat of a pending mkdir over an existing directory keeps disk metadata
        check('stat_pending_over_disk',
              f'> u = mkdirp "{full}"; p = "{full}"; (e, sz, mt) = stat p; print "{{e}} {{mt > 0}}".\n',
              b'True True\n')

    print(f'sol fs contract: {count} checks passed')


if __name__ == '__main__':
    main()
