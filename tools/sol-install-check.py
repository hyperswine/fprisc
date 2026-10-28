#!/usr/bin/env python3
"""Installed scheduled-style execution, shebangs and private recovery state."""
import hashlib
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT/'fpr')).resolve()


def lit(value):
    return json.dumps(str(value), ensure_ascii=False).replace('{', '\\{').replace('}', '\\}')


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-install-') as temporary:
        w = Path(temporary).resolve()
        prefix = w/'prefix with spaces'
        archive = w/'bundle.tar.gz'
        result = subprocess.run([sys.executable, ROOT/'tools/sol-install.py', '--binary', FPR,
                                 '--prefix', prefix, '--output', archive], capture_output=True, timeout=90)
        assert result.returncode == 0, result
        metadata = json.loads(result.stdout)
        bundle = prefix/'libexec/sol'/metadata['bundle_id']
        manifest = json.loads((bundle/'manifest.json').read_text())
        assert manifest['binary_sha256'] == hashlib.sha256(FPR.read_bytes()).hexdigest()
        assert (bundle/'source/compiler/Sol/Txn.hs').is_file()
        assert (bundle/'sol/lib/http.sol').is_file()
        count += 4
        cwd = w/'unrelated'; cwd.mkdir()
        home = w/'home'; home.mkdir()
        scripts = w/'installed scripts'; scripts.mkdir()
        script = scripts/'daily.sol'
        script.write_text('#!/usr/bin/env sol\nD = use "sol/lib/digest.sol".\n> u = print (args Unit); print (Hex.encode (Sha256.bytes (unwrap (Utf8.encode "abc")))).\n')
        script.chmod(0o555); scripts.chmod(0o555)
        env = {'PATH': str(prefix/'bin')+':/usr/bin:/bin', 'HOME': str(home),
               'LANG': 'C', 'SOL_GPU': '0', 'SOL_JIT': os.environ.get('FPR_TEST_JIT', '1'),
               'XDG_STATE_HOME': str(w/'state root'), 'XDG_CACHE_HOME': str(w/'cache root')}
        sol = prefix/'bin/sol'

        def run(args, expected=None, code=0, extra=None):
            nonlocal count
            p = subprocess.run([str(a) for a in args], env=env|(extra or {}), cwd=cwd,
                               capture_output=True, timeout=45)
            assert p.returncode == code and (expected is None or p.stdout == expected), p
            count += 1
            return p

        try:
            run([sol, '--version'], b'Sol 0.12.0 (scripting API 1)\n')
            assert b'SOL_STATE_DIR' in run([sol, '--help']).stdout
            expected = b'[a b;*, , --literal]\nba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n'
            run([sol, script, 'a b;*', '', '--literal'], expected)
            run([script, 'a b;*', '', '--literal'], expected)
            run([sol, '--', script, 'a b;*', '', '--literal'], expected)
            assert list((w/'cache root/sol').glob('*.cache'))
            assert not list(scripts.glob('*.soljournal*'))
            root = w/'state root/sol'
            assert root.stat().st_mode & 0o777 == 0o700
            count += 3
            # Absolute-interpreter shebang is portable when its path has no spaces.
            direct = w/'direct.sol'
            direct.write_text('#!'+str(FPR)+' sol\n> print "direct".\n'); direct.chmod(0o755)
            # A kernel shebang with an argument supports the fpr form. Installed
            # sol uses no argument; /usr/bin/env sol supports relocatable installs.
            run([direct], b'direct\n')
            # The archive independently carries libraries and the source snapshot.
            extracted = w/'extracted'; extracted.mkdir()
            with tarfile.open(archive) as tar:
                tar.extractall(extracted, filter='data')
            run([extracted/metadata['bundle_id']/'launch-sol', script, 'a b;*', '', '--literal'], expected)
            # Relocating the entire prefix preserves relative activation links.
            relocated = w/'relocated'; shutil.move(prefix, relocated)
            prefix = relocated; sol = prefix/'bin/sol'
            env['PATH'] = str(prefix/'bin')+':/usr/bin:/bin'
            run([script, 'a b;*', '', '--literal'], expected)
            installed_direct = w/'installed-direct.sol'
            installed_direct.write_text('#!'+str(sol)+'\n> print "installed direct".\n')
            installed_direct.chmod(0o755)
            run([installed_direct], b'installed direct\n')
            child = cwd/'child.sol'; child.write_text('> print "child".\n')
            parent = cwd/'parent.sol'
            parent.write_text('m = use "child.sol".\n> print (run m Unit).\n')
            run([sol, parent], b'child\n\n')
            # Read-only application: crash after durable commit, then recover from
            # a different script and cwd through the absolute dead-owner lock.
            target = w/'result'; target.write_text('old'); target.chmod(0o640)
            scripts.chmod(0o755)
            writer = scripts/'writer.sol'
            writer.write_text(f'> writePath {lit(target)} "new".\n'); writer.chmod(0o444)
            scripts.chmod(0o555)
            run([sol, writer], code=137, extra={'SOL_CRASH_AT': '0'})
            assert target.read_text() == 'old'
            status = run([sol, 'state']).stdout
            assert b'dead ' in status and b'run.soljournal.' in status
            journals = list(root.glob('*/run.soljournal.*'))
            assert journals and all(p.is_absolute() for p in journals)
            reader = cwd/'reader.sol'; reader.write_text(f'> log (readPath {lit(target)}).\n')
            run([sol, reader], b'new\n')
            assert target.stat().st_mode & 0o777 == 0o640
            assert not list(root.glob('*/run.soljournal.*'))
            count += 4
            # Deferred-only journals have no file lock to trigger recovery. The
            # explicit command can complete them without reopening the script.
            scripts.chmod(0o755)
            deferred = scripts/'deferred.sol'
            marker = w/'deferred-marker'
            deferred.write_text(f'> Proc.afterCommit (ProcessSpec ["/usr/bin/touch", {lit(marker)}] "" [] "" 1000).\n')
            scripts.chmod(0o555)
            run([sol, deferred], code=137, extra={'SOL_CRASH_AT': '0'})
            assert not marker.exists()
            run([sol, 'recover'])
            assert marker.exists() and b'dead ' not in run([sol, 'state']).stdout
            count += 2
            # A malformed/incomplete journal is discarded as pre-commit; a valid
            # failing replay retains the fence until its cause is repaired.
            blocked = w/'blocked'; staging = w/'blocked.sol-tmp'; staging.mkdir()
            failing = cwd/'failing.sol'; failing.write_text(f'> writePath {lit(blocked)} "complete".\n')
            run([sol, failing], code=1)
            assert b'dead ' in run([sol, 'state']).stdout
            run([sol, 'recover'], code=1)
            staging.rmdir()
            run([sol, 'recover'])
            assert blocked.read_text() == 'complete' and not list(root.glob('*/run.soljournal.*'))
            count += 1
            # An actually live owner is never replayed by maintenance.
            group = root/('a'*64); group.mkdir()
            journal = group/f'run.soljournal.{os.getpid()}.live'
            forbidden = w/'forbidden'
            journal.write_text('SOLJ1\n[EWrite '+json.dumps(str(forbidden))+' "bad"]\nCOMMIT\n')
            run([sol, 'recover'])
            assert journal.exists() and not forbidden.exists()
            journal.unlink(); count += 1
            # First-ever concurrent invocations share only an immutable source
            # descriptor. Its creation must not race on one fixed staging name.
            fresh = w/'fresh-concurrent-state'
            def concurrent_run(_):
                return subprocess.run([sol, script], env=env|{'SOL_STATE_DIR': str(fresh)},
                                      cwd=cwd, capture_output=True, timeout=45)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(concurrent_run, range(16)))
            assert all(p.returncode == 0 for p in results), results
            assert len(list(fresh.glob('*/script'))) == 1
            assert not list(fresh.glob('*/.sol-script-*'))
            count += 1
            # Explicit state override, relative-path rejection and symlink safety.
            state = w/'explicit-state'
            run([sol, script], extra={'SOL_STATE_DIR': str(state)})
            assert state.is_dir()
            run([sol, script], code=1, extra={'SOL_STATE_DIR': 'relative'})
            alias = w/'state-alias'; alias.symlink_to(state, target_is_directory=True)
            run([sol, script], code=1, extra={'SOL_STATE_DIR': str(alias)})
            count += 1
            # Reinstalling the exact extracted source verifies an existing
            # version instead of silently accepting a damaged immutable bundle.
            installed = sol.resolve().parent
            library = installed/'source/sol/lib/digest.sol'
            original = library.read_bytes(); library.write_bytes(b'broken = ).\n')
            p = subprocess.run([sys.executable, extracted/metadata['bundle_id']/'source/tools/sol-install.py',
                                '--binary', extracted/metadata['bundle_id']/'fpr', '--prefix', prefix],
                               capture_output=True, timeout=90)
            assert p.returncode != 0 and b'corrupt' in p.stderr, p
            library.write_bytes(original); count += 1
            # Refuse to overwrite an unrelated installed command.
            unmanaged = w/'unmanaged/bin'; unmanaged.mkdir(parents=True)
            (unmanaged/'sol').write_text('user-owned')
            p = subprocess.run([sys.executable, ROOT/'tools/sol-install.py', '--binary', FPR,
                                '--prefix', unmanaged.parent], capture_output=True, timeout=60)
            assert p.returncode != 0 and (unmanaged/'sol').read_text() == 'user-owned'
            count += 1
        finally:
            scripts.chmod(0o755)
    print(f'sol installed workflow: {count} checks passed')


if __name__ == '__main__':
    main()
