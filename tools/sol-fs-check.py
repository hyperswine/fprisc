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
import time

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

        def check(name, source, stdout=b'', code=0, error=None, error_not=None):
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
            if error_not is not None:
                assert error_not not in result.stderr, (name, result.stderr)
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

        # ---- metadata dependencies: promised fields, no content reads ----
        # A stat-able file whose contents cannot be read: metadata answers.
        # This doubles as the instrumented proof that a metadata query never
        # opens contents: any content read fails the check with permission
        # denied.
        locked = work / 'locked.txt'
        locked.write_text('secret')
        locked.chmod(0o000)
        check('exists_unreadable', f'> p = "{locked}"; print "{{exists p}}".\n', b'True\n')
        check('stat_unreadable',
              f'> p = "{locked}"; (e, sz, mt) = stat p; print "{{e}} {{sz > 0}} {{mt > 0}}".\n',
              b'True True True\n')
        locked.chmod(0o644)

        # FIFOs and other non-regular files observe without opening (the old
        # snapshot recorded a phantom empty-content dependency on them).
        pipe = work / 'pipe'
        os.mkfifo(pipe)
        check('exists_fifo', f'> p = "{pipe}"; print "{{exists p}}".\n', b'True\n')
        check('stat_fifo', f'> p = "{pipe}"; (e, sz, mt) = stat p; print "{{e}} {{mt > 0}}".\n',
              b'True True\n')
        check('ls_fifo', f'> p = "{pipe}"; ls p.\n', code=1, error=b'SOL PANIC: ls:')

        # Metadata does not scale with content size: stat of an 8 GiB sparse
        # file must answer fast (the whole-content snapshot read all of it).
        sparse = work / 'sparse.bin'
        with open(sparse, 'wb') as fh:
            fh.truncate(8 * 1024 ** 3)
        t0 = time.monotonic()
        check('stat_sparse', f'> p = "{sparse}"; (e, sz, mt) = stat p; print "{{e}} {{sz}}".\n',
              b'True 8589934592\n')
        elapsed = time.monotonic() - t0
        assert elapsed < 3.0, ('stat_sparse scaling', elapsed)

        # ---- promised-field validation at commit --------------------------
        # A promised presence flip conflicts, retries, and the retry sees the
        # new world. (shNow is a realtime escape: it acts before commit, so
        # it supplies the foreign writer deterministically.)
        ftarget = work / 'arrive'
        check('presence_flip_conflict',
              f'> b = exists "{ftarget}"; u = shNow "touch {ftarget}"; print "{{b}}".\n',
              b'False\nTrue\n', error=b'conflict on')

        # stat promises the fields it returned: a size change conflicts.
        grown = work / 'grown.txt'
        grown.write_text('abc')
        check('stat_size_drift_conflict',
              f'> (e, sz, mt) = stat "{grown}"; u = shNow "printf abcd > {grown}"; print "{{sz}}".\n',
              b'3\n4\n', error=b'conflict on')

        # An isDir answer is a promise: a kind flip mid-run conflicts instead
        # of committing on a branch decided by a world that no longer exists.
        gonedir = work / 'gonedir'
        gonedir.mkdir()
        check('isdir_flip_conflict',
              f'> b = isDir "{gonedir}"; u = shNow "rm -rf {gonedir}"; print "{{b}}".\n',
              b'True\nFalse\n', error=b'conflict on')

        # The loosening, stated: a metadata-only promise does NOT conflict
        # when a foreign writer rewrites the path's CONTENT unchanged in
        # presence. One attempt, no conflict line; the old whole-content
        # dependency conflicted and printed twice. Scripts wanting the
        # content dependency read the file (exact-byte validation stays).
        rewritten = work / 'rewritten.txt'
        rewritten.write_text('one')
        check('exists_no_content_conflict',
              f'> b = exists "{rewritten}"; u = shNow "printf two > {rewritten}"; print "{{b}}".\n',
              b'True\n', error=b'REALTIME: shNow', error_not=b'conflict on')

        # ---- the typed tier: Try.ls / Try.stat / Try.exists ---------------
        # One FsError carries operation, path and a distinguishable reason;
        # the panicking spellings stay for scripts that mean to insist.
        def try_check(name, source, stdout):
            nonlocal count
            path = work / (name + '.sol')
            path.write_text(source)
            result = subprocess.run([str(FPR), 'sol', str(path)],
                                    capture_output=True, env=ENV, timeout=30)
            assert result.returncode == 0, (name, result)
            assert result.stdout == stdout, (name, result.stdout, stdout, result.stderr)
            assert result.stderr == b'', (name, result.stderr)
            count += 1

        why = ('> r = %s;\n'
               '  out = case r of Ok x -> "ok {x}" | Err (FsError op p why m) -> "{op} {p} {why}";\n'
               '  print out.\n')
        try_check('try_ls_ok', f'> r = Try.ls "{full}"; print "{{r}}".\n',
                  f'Ok [a.txt, b.txt, sub]\n'.encode())
        try_check('try_ls_missing', why % f'Try.ls "{work}/nope"',
                  f'OpLs {work}/nope FsMissing\n'.encode())
        try_check('try_ls_wrong_kind', why % f'Try.ls "{plain}"',
                  f'OpLs {plain} FsWrongKind\n'.encode())
        denied_dir = work / 'denieddir'
        denied_dir.mkdir()
        denied_dir.chmod(0o000)
        try_check('try_ls_denied', why % f'Try.ls "{denied_dir}"',
                  f'OpLs {denied_dir} FsDenied\n'.encode())
        try_check('try_stat_ok',
                  f'> r = Try.stat "{plain}";'
                  f' out = case r of Ok (sz, mt) -> "{{sz > 0}}" | Err e -> "err"; print out.\n',
                  b'True\n')
        try_check('try_stat_missing', why % f'Try.stat "{work}/nope"',
                  f'OpStat {work}/nope FsMissing\n'.encode())
        # exists answers absence; only an unknowable observation is an error
        try_check('try_exists_missing',
                  f'> r = Try.exists "{work}/nope";'
                  f' out = case r of Ok b -> "{{b}}" | Err e -> "err"; print out.\n',
                  b'False\n')
        try_check('try_exists_ok',
                  f'> r = Try.exists "{plain}";'
                  f' out = case r of Ok b -> "{{b}}" | Err e -> "err"; print out.\n',
                  b'True\n')
        try_check('try_exists_denied', why % f'Try.exists "{denied_dir}/x"',
                  f'OpExists {denied_dir}/x FsDenied\n'.encode())
        # a symlink loop is its own reason, on every observation spelling
        loop_a = work / 'loop-a'
        loop_b = work / 'loop-b'
        loop_a.symlink_to(loop_b)
        loop_b.symlink_to(loop_a)
        try_check('try_stat_loop', why % f'Try.stat "{loop_a}"',
                  f'OpStat {loop_a} FsLoop\n'.encode())
        # the railway composes: isOk / andThen work on the typed tier
        try_check('try_railway',
                  f'> d = "{full}"; m = "{work}/nope";'
                  f' print "{{isOk (Try.ls d)}} {{isOk (Try.ls m)}}".\n',
                  b'True False\n')
        # plain spellings on unknowable paths fail CLEARLY (classified panic)
        check('exists_denied_panic', f'> p = "{denied_dir}/x"; print "{{exists p}}".\n',
              code=1, error=b'SOL PANIC: exists:')
        check('isdir_denied_panic', f'> p = "{denied_dir}/x"; print "{{isDir p}}".\n',
              code=1, error=b'SOL PANIC: isDir:')
        denied_dir.chmod(0o755)
        check('stat_loop_panic', f'> p = "{loop_a}"; stat p.\n',
              code=1, error=b'SOL PANIC: stat:')

    print(f'sol fs contract: {count} checks passed')


if __name__ == '__main__':
    main()
