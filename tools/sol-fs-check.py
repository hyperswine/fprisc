#!/usr/bin/env python3
"""Filesystem metadata and listing contract for the Sol script runner.

Covers the Phase 1 first slice of docs/2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md:
exists/stat on directories must observe metadata instead of panicking on a
content snapshot, and ls must distinguish missing/wrong-kind from an empty
directory while still composing the transaction's own pending mkdir/write/
remove view.
"""
import errno
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
ENV = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')} | {'SOL_GPU': '0'}


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-fs-') as tmp:
        work = Path(tmp).resolve()
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
                                    capture_output=True, env=ENV | ({'SOL_RETRY_POLICY': 'legacy'} if error == b'conflict on' else {}), timeout=30)
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

        # ---- kind and link policy: Try.lstat (no follow) / Try.statKind ---
        # lstat is THE dangling-vs-missing distinguisher: a dangling link
        # answers Ok KLink; only an absent ENTRY answers FsMissing.
        link = work / 'tolink'
        link.symlink_to(plain)
        try_check('try_lstat_link', f'> r = Try.lstat "{link}"; print "{{r}}".\n',
                  b'Ok KLink\n')
        try_check('try_lstat_dangling', f'> r = Try.lstat "{dangling}"; print "{{r}}".\n',
                  b'Ok KLink\n')
        try_check('try_lstat_missing', why % f'Try.lstat "{work}/nope"',
                  f'OpLstat {work}/nope FsMissing\n'.encode())
        try_check('try_lstat_file', f'> r = Try.lstat "{plain}"; print "{{r}}".\n',
                  b'Ok KFile\n')
        try_check('try_lstat_dir', f'> r = Try.lstat "{full}"; print "{{r}}".\n',
                  b'Ok KDir\n')
        # statKind follows: a link to a file is a file; a dangling link is gone
        try_check('try_statkind_follow', f'> r = Try.statKind "{link}"; print "{{r}}".\n',
                  b'Ok KFile\n')
        try_check('try_statkind_dangling', why % f'Try.statKind "{dangling}"',
                  f'OpStatKind {dangling} FsMissing\n'.encode())
        # plain isLink over the no-follow kind
        try_check('islink_plain',
                  f'> a = "{link}"; b = "{plain}"; c = "{dangling}";'
                  f' print "{{isLink a}} {{isLink b}} {{isLink c}}".\n',
                  b'True False True\n')
        # a promised no-follow kind is validated: link replaced by a file
        # mid-run conflicts, then the retry sees the new world
        check('lstat_flip_conflict',
              f'> b = isLink "{link}"; u = shNow "rm {link} && printf x > {link}"; print "{{b}}".\n',
              b'True\nFalse\n', error=b'conflict on')

        # ---- bounded recursive walking --------------------------------------
        # walk root depth entries follow -> Result (List WalkEntry), where a
        # WalkEntry is (path, kind, depth). Defaults: no dir-symlink follow,
        # cycle-safe follow when opted in, explicit limits, explicit
        # non-UTF-8 rejection.
        tree = work / 'tree'
        (tree / 'sub' / 'deep').mkdir(parents=True)
        (tree / 'top.txt').write_text('t')
        (tree / 'sub' / 'inner.txt').write_text('i')
        (tree / 'sub' / 'deep' / 'leaf.txt').write_text('l')
        dlink = tree / 'tolinkdir'
        dlink.symlink_to(tree / 'sub')
        # entries render as WalkEntry "path" KKind depth tuples
        try_check('walk_default_nofollow',
                  f'> r = Try.walk "{tree}" 8 1000 False;'
                  f' out = case r of Ok es -> "{{List.len es}}" | Err e -> "err"; print out.\n',
                  b'6\n')  # top.txt, sub, sub/inner.txt, sub/deep, sub/deep/leaf.txt, tolinkdir(link, cut)
        try_check('walk_kinds_and_depths',
                  f'> r = Try.walk "{tree}" 8 1000 False;'
                  f' out = case r of Ok es -> es |> List.filter (fn e -> case e of'
                  f' WalkEntry p KFile d -> d == 2 | _ -> False) |> List.len'
                  f' | Err e -> -1; print out.\n',
                  b'1\n')  # sub/inner.txt is the file at depth 2
        # follow=True descends the symlinked dir once; a self-cycle is cut
        # by canonical identity, not by exhausting the depth budget
        cyc = work / 'cyc'
        cyc.mkdir()
        (cyc / 'in.txt').write_text('x')
        os.symlink(cyc, cyc / 'self')
        try_check('walk_follow_cycle_cut',
                  f'> r = Try.walk "{cyc}" 8 1000 True;'
                  f' out = case r of Ok es -> "{{List.len es}}" | Err e -> "err"; print out.\n',
                  b'2\n')  # in.txt + self (ancestor identity cuts descent)
        # limits are explicit and distinguishable
        try_check('walk_depth_limit',
                  f'> r = Try.walk "{tree}" 1 1000 False;'
                  f' out = case r of Ok es -> "{{List.len es}}" | Err e -> "err"; print out.\n',
                  b'3\n')  # top.txt, sub (dir, not descended), tolinkdir (link)
        try_check('walk_entry_limit', why % f'Try.walk "{tree}" 8 1 False',
                  f'OpWalk {tree} FsLimit\n'.encode())
        # names: spaces, Unicode and newlines survive exactly
        names = work / 'names'
        names.mkdir()
        (names / 'a b.txt').write_text('1')
        (names / 'λ世界.txt').write_text('2')
        (names / 'nl\nline.txt').write_text('3')
        try_check('walk_hard_names',
                  f'> r = Try.walk "{names}" 2 100 False;'
                  f' out = case r of Ok es -> es |> List.filter (fn e -> case e of'
                  f' WalkEntry p _ _ -> Str.endsWith "b.txt" p | _ -> False) |> List.len'
                  f' | Err e -> -1; print out.\n',
                  b'1\n')
        # non-UTF-8 filenames fail explicitly, never silently replaced
        badname = work / 'badname'
        badname.mkdir()
        # APFS and restricted macOS sessions can refuse such a name at
        # creation. Report the unexercised case instead of inventing bytes.
        try:
            fd = os.open(os.fsencode(badname) + b'/bad\xff.txt', os.O_CREAT | os.O_WRONLY, 0o644)
            os.write(fd, b'x')
            os.close(fd)
            can_badname = True
        except OSError as exc:
            assert exc.errno == errno.EILSEQ or (sys.platform == 'darwin' and exc.errno == errno.EPERM), exc
            can_badname = False
            print(f'note: non-UTF-8 filename fixture unavailable here ({exc}); '
                  'ls_nonutf8_rejected was not exercised')
        if can_badname:
            try_check('ls_nonutf8_rejected', why % f'Try.ls "{badname}"',
                      f'OpLs {badname} FsEncoding\n'.encode())
        # ---- owned temp directories ------------------------------------------
        # Try.tempDir prefix: a 0700 scratch dir under the system temp dir,
        # owned by the run: discarded attempts sweep it, every exit sweeps
        # it. It NEVER outlives the process — durable output goes to
        # ordinary transactional paths.
        probe = work / 'tempdir-probe.sol'

        def run_sol(source, env=None):
            probe.write_text(source)
            return subprocess.run([str(FPR), 'sol', str(probe)],
                                  capture_output=True, env=ENV | (env or {}), timeout=30)

        r = run_sol('> r = Try.tempDir "scratch";'
                    ' out = case r of Ok d -> "{exists d} {isDir d}" | Err e -> "{e}"; print out.\n')
        assert r.returncode == 0 and r.stdout == b'True True\n', r
        count += 1
        r2 = run_sol('> a = tempDir "u1"; b = tempDir "u2"; print "{a}\n{b}".\n')
        assert r2.returncode == 0, r2
        p1, p2 = r2.stdout.decode().splitlines()
        import tempfile as _tf
        temp_root = Path(_tf.gettempdir()).resolve()
        assert p1 != p2 and Path(p1).parent == temp_root and Path(p2).parent == temp_root, (p1, p2)
        assert not Path(p1).exists() and not Path(p2).exists(), 'temp dirs must not outlive the run'
        count += 2
        # a discarded attempt sweeps its own temps; the final attempt's too
        r3 = run_sol('> d = tempDir "retry"; print d.\n', env={'SOL_FORCE_RETRY': '2', 'SOL_RETRY_POLICY': 'legacy'})
        assert r3.returncode == 0, r3
        paths = [Path(line) for line in r3.stdout.decode().splitlines()]
        # forced-retry 2 = two discarded attempts plus the final one
        assert len(paths) == 3 and len(set(paths)) == 3, r3.stdout
        assert not any(p.exists() for p in paths), paths
        count += 1
        # panic path sweeps too
        r4 = run_sol('> d = tempDir "boom"; v = print "{d}"; parseInt "boom".\n')
        assert r4.returncode == 1 and b'SOL PANIC' in r4.stderr, r4
        gone = Path(r4.stdout.decode().splitlines()[0])
        assert not gone.exists(), gone
        count += 1
        # 0700 on both spellings of stat
        flag = '-f %Lp' if sys.platform == 'darwin' else '-c %a'
        r5 = run_sol(f'> d = tempDir "m"; mode = sh "stat {flag} {{d}}";'
                     f' print "{{mode}}".\n')
        assert r5.returncode == 0 and r5.stdout.strip() == b'700', r5
        count += 1

        # a walk's observations are promises: a foreign file appearing in a
        # walked directory mid-run conflicts, and the retry walks the new world
        check('walk_conflict_on_foreign_add',
              f'> r = Try.walk "{tree}" 8 1000 False; u = shNow "printf x > {tree}/new.txt";'
              f' n = case r of Ok es -> List.len es | Err e -> -1; print "{{n}}".\n',
              b'6\n7\n', error=b'conflict on')

        # ---- review regressions: modalities, budgets and ownership ----------
        try_check('lstat_loop_does_not_follow',
                  f'> print (Try.lstat "{loop_a}").\n', b'Ok KLink\n')
        arrived_link = work / 'arrived-link'
        check('lstat_absence_is_validated',
              f'> r = Try.lstat "{arrived_link}"; u = shNow "touch {arrived_link}"; print (isOk r).\n',
              b'False\nTrue\n', error=b'conflict on')
        check('isdir_fifo_predicate', f'> print (isDir "{pipe}").\n', b'False\n')
        drift = work / 'twice.txt'
        drift.write_text('abc')
        check('contradictory_metadata_retries',
              f'> (e, a, t) = stat "{drift}"; u = shNow "printf abcd > {drift}";'
              f' (e2, b, t2) = stat "{drift}"; print "{{a}} {{b}}".\n',
              b'3 4\n4 4\n', error=b'conflict on')
        try_check('walk_exact_entry_budget',
                  f'> r = Try.walk "{cyc}" 8 2 True; print (isOk r).\n', b'True\n')
        try_check('walk_empty_budget',
                  f'> r = Try.walk "{empty}" 8 1 False; print (isOk r).\n', b'True\n')
        for depth, budget in [(0, 1), (1, 0), (-1, 1), (4097, 1), (1, 10000001)]:
            try_check(f'walk_invalid_{depth}_{budget}', why % f'Try.walk "{empty}" ({depth}) {budget} False',
                      f'OpWalk {empty} FsLimit\n'.encode())
        try_check('walk_missing_root', why % f'Try.walk "{work}/absent-root" 2 10 False',
                  f'OpWalk {work}/absent-root FsMissing\n'.encode())
        try_check('walk_file_root', why % f'Try.walk "{plain}" 2 10 False',
                  f'OpWalk {plain} FsWrongKind\n'.encode())
        rootlink = work / 'root-link'
        rootlink.symlink_to(cyc)
        try_check('walk_root_link_nofollow', why % f'Try.walk "{rootlink}" 2 10 False',
                  f'OpWalk {rootlink} FsWrongKind\n'.encode())
        try_check('walk_root_link_follow',
                  f'> r = Try.walk "{rootlink}" 8 10 True; print (isOk r).\n', b'True\n')
        loop_tree = work / 'loop-tree'
        loop_tree.mkdir()
        (loop_tree / 'bad').symlink_to(loop_a)
        try_check('walk_follow_loop_error', why % f'Try.walk "{loop_tree}" 2 10 True',
                  f'OpWalk {loop_tree}/bad FsLoop\n'.encode())
        try_check('walk_loop_link_nofollow',
                  f'> r = Try.walk "{loop_tree}" 2 10 False; print (isOk r).\n', b'True\n')
        check('islink_denied_is_not_false', f'> print (isLink "{plain}/child").\n',
              code=1, error=b'FsWrongKind')

        # Preorder is deterministic, including depth, links and difficult names.
        import json
        exact = work / 'exact'
        (exact / 'a-dir').mkdir(parents=True)
        (exact / 'a-dir' / 'b.txt').write_text('b')
        (exact / 'c\nλ.txt').write_text('c')
        encoded_paths = json.dumps(str(exact))
        try_check('walk_preorder_depths',
                  f'> r = Try.walk {encoded_paths} 8 10 False;'
                  ' print (case r of Ok es -> List.map (fn e -> case e of WalkEntry p k d -> d) es | Err e -> []).\n',
                  b'[1, 2, 1]\n')
        nested = work / 'pending-walk'
        try_check('walk_pending_view',
                  f'> u = mkdirp "{nested}"; v = mkdirp "{nested}/sub";'
                  f' w = writePath "{nested}/sub/f" "x"; r = Try.walk "{nested}" 8 10 False;'
                  ' print (case r of Ok es -> List.len es | Err e -> -1).\n', b'2\n')
        check('directory_stat_with_descendant_locks',
              f'> (e, sz, mt) = stat "{full}"; r = Try.walk "{full}" 8 100 False;'
              ' print (isOk r).\n', b'True\n')
        later_alias = work / 'zz-dir-alias'
        later_alias.symlink_to(full)
        check('directory_stat_alias_with_descendant_locks',
              f'> x = stat "{later_alias}"; r = Try.walk "{later_alias}" 8 100 True;'
              ' print (isOk r).\n', b'True\n')
        next_dir = work / 'retargeted-dir'
        next_dir.mkdir()
        check('directory_stat_alias_retarget_conflicts',
              f'> x = stat "{later_alias}"; u = shNow "rm {later_alias}; ln -s {next_dir} {later_alias}";'
              ' print "attempt".\n', b'attempt\nattempt\n', error=b'conflict on')
        unreadable_tree = work / 'unreadable-tree'
        unreadable_tree.mkdir()
        hidden = unreadable_tree / 'content'
        hidden.write_text('not readable')
        hidden.chmod(0)
        try:
            try_check('walk_never_reads_contents',
                      f'> r = Try.walk "{unreadable_tree}" 8 10 False; print (isOk r).\n', b'True\n')
        finally:
            hidden.chmod(0o600)
        implied = work / 'implied-parent'
        try_check('walk_mkdirp_implied_parent',
                  f'> u = mkdirp "{implied}/child"; r = Try.walk "{implied}" 8 10 False;'
                  ' print (case r of Ok es -> List.len es | Err e -> -1).\n', b'1\n')
        check('pending_read_path_alias',
              f'> u = writePath "{work}/./aliased.txt" "pending"; print (readPath "{work}/aliased.txt").\n',
              b'pending\n')
        check('pending_rmdir_then_file',
              f'> u = mkdirp "{work}/turn-into-file"; v = rmdir "{work}/turn-into-file";'
              f' w = writePath "{work}/turn-into-file" "file";'
              f' print (Try.statKind "{work}/turn-into-file").\n', b'Ok KFile\n')
        remove_dir = work / 'remove-child'
        (remove_dir / 'child').mkdir(parents=True)
        try_check('ls_pending_rmdir_hides_child',
                  f'> u = rmdir "{remove_dir}/child"; print (ls "{remove_dir}").\n', b'[]\n')

        for prefix in ['', '../escape', 'a/b', 'a' * 65]:
            r = run_sol(f'> print (isOk (Try.tempDir {json.dumps(prefix)})).\n')
            assert r.returncode == 0 and r.stdout == b'False\n' and not r.stderr, r
            count += 1
        r = run_sol(f'> f = tempFile "private"; mode = sh "stat {flag} {{f}}";'
                    ' u = print f; print mode.\n')
        assert r.returncode == 0 and not r.stderr, r
        temp_path, *mode_lines = r.stdout.decode().splitlines()
        assert ''.join(mode_lines).strip() == '600' and not Path(temp_path).exists(), r
        count += 1

        # Cancellation after allocation must clean up, including actor-owned temps.
        probe.write_text('> d = tempDir "cancel"; u = print d; Sys.sleepUs 10000000.\n')
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            child = subprocess.Popen([str(FPR), 'sol', str(probe)], stdout=out, stderr=err, env=ENV)
            try:
                until = time.monotonic() + 15
                while time.monotonic() < until:
                    out.seek(0)
                    ready = out.read().decode().splitlines()
                    if ready:
                        break
                    assert child.poll() is None, 'cancel fixture exited before allocation'
                    time.sleep(.02)
                assert ready, 'cancel readiness timeout'
                child.send_signal(signal.SIGINT)
                assert child.wait(timeout=5) == 130
                assert not Path(ready[0]).exists(), ready
                count += 1
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()

        # A durable redo may still consume scratch. A failed replay must retain
        # it, and the next run can complete recovery from its saved path.
        recovery_file = work / 'recovery-output'
        blocker = Path(str(recovery_file) + '.sol-tmp')
        blocker.mkdir()
        r = run_sol(f'> d = tempDir "recovery"; u = print d;'
                    f' writePath "{recovery_file}" "recovered".\n')
        assert r.returncode == 1 and b'retaining scratch for pending recovery' in r.stderr, r
        retained = Path(r.stdout.decode().splitlines()[0])
        assert retained.is_dir(), r
        blocker.rmdir()
        r = run_sol('> print "recovery complete".\n')
        assert r.returncode == 0 and recovery_file.read_text() == 'recovered', r
        # Ownership is process-local; retained crash-recovery scratch is an
        # explicitly documented manual-cleanup case, not automatically claimed.
        retained.rmdir()
        count += 1

    print(f'sol fs contract: {count} checks passed')


if __name__ == '__main__':
    main()
