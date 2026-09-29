#!/usr/bin/env python3
"""Compiler cache invalidation, diagnostics, corruption and runtime isolation."""
import concurrent.futures
import os
import re
import shutil
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-startup-') as tmp:
        w = Path(tmp)
        cache = w / 'cache'
        script = w / 'main.sol'
        env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
        env.update(SOL_CACHE_DIR=str(cache), SOL_CACHE_TRACE='1', SOL_JIT='0', SOL_GPU='0')

        def run(source=None, expected=b'42\n', status='hit', extra=None, code=0, error=None, args=()):
            nonlocal count
            if source is not None:
                script.write_text(source)
            p = subprocess.run([str(FPR), 'sol', str(script), *args], env=env | (extra or {}), capture_output=True, timeout=30)
            assert p.returncode == code and p.stdout == expected, p
            if status:
                assert f'[sol cache] {status}\n'.encode() in p.stderr, p.stderr
            if error:
                assert error in p.stderr, p.stderr
            count += 1
            return p

        hello = '> print "42".\n'
        run(hello, status='miss')
        run()
        run(status='disabled', extra={'SOL_CACHE': '0'})
        run('> print "43".\n', expected=b'43\n', status='miss')
        run(expected=b'43\n')
        # A transitive edit with unchanged size and mtime must invalidate.
        leaf = w / 'leaf.sol'
        leaf.write_text('answer = 42.\n')
        (w / 'helper.sol').write_text('l = use "leaf.sol".\nanswer = l.answer.\n')
        source = 'h = use "helper.sol".\n> print "{h.answer}".\n'
        run(source, status='miss')
        run()
        st = leaf.stat()
        leaf.write_text('answer = 43.\n')
        os.utime(leaf, ns=(st.st_atime_ns, st.st_mtime_ns))
        run(expected=b'43\n', status='miss')
        run(expected=b'43\n')
        leaf.unlink()
        run(expected=b'', status=None, code=1, error=b'no such module')
        # Pins are checked before cache lookup, including after a warm hit.
        leaf.write_text('answer = 42.\n')
        unpinned = 'h = use "leaf.sol".\n> print "{h.answer}".\n'
        announced = run(unpinned, status='miss', extra={'SOL_VERBOSE': '1'})
        pin = re.search(rb'leaf.sol#([0-9a-f]+)', announced.stderr).group(1).decode()
        run(unpinned.replace('leaf.sol', 'leaf.sol#' + pin), status='miss')
        run()
        leaf.write_text('answer = 43.\n')
        run(expected=b'', status=None, code=1, error=b'hash mismatch')
        # Inputs used by the runtime are not part of cached results.
        run('> print "{args Unit}".\n', expected=b'[one]\n', status='miss', args=('one',))
        run(expected=b'[two]\n', args=('two',))
        data = w / 'input.txt'
        data.write_text('42')
        run(f'> print (readPath @{data}).\n', status='miss')
        data.write_text('43')
        run(expected=b'43\n')
        # Fresh resolution notices a new importer-local module shadowing FPR_PATH.
        external = w / 'external'
        external.mkdir()
        (external / 'choice.sol').write_text('answer = 42.\n')
        choice = 'h = use "choice.sol".\n> print "{h.answer}".\n'
        opts = {'FPR_PATH': str(external)}
        run(choice, status='miss', extra=opts)
        run(extra=opts)
        (w / 'choice.sol').write_text('answer = 43.\n')
        run(expected=b'43\n', status='miss', extra=opts)
        # Compiler option changes never reuse an unchecked artifact.
        bad = 'unused = 1 + "wrong".\n> print "42".\n'
        run(bad, status='miss', extra={'SOL_NOTYPES': '1'})
        run(extra={'SOL_NOTYPES': '1'})
        run(expected=b'', status='miss', code=1, error=b'TYPE ERRORS')
        run(hello, status='hit')
        run(status='miss', extra={'SOL_NO_SAFETY': '1'})
        run(status='hit')
        run(status='disabled', extra={'SOL_TYPES': '1'}, error=b'INFERRED TYPES')
        run(status='disabled', extra={'SOL_WIDTHS': '1'}, error=b'NUMERIC WIDTHS')
        # Persist compiler warnings, not runtime effects.
        a = run('# sol:notypes\n' + hello, status='miss')
        b = run()
        assert a.stderr.replace(b'miss', b'hit') == b.stderr
        target = w / 'effect.txt'
        write = f'> writePath @{target} "saved".\n'
        run(write, expected=b'', status='miss')
        target.unlink()
        run(expected=b'')
        assert target.read_text() == 'saved'
        target.unlink()
        run(expected=b'', extra={'SOL_FORCE_RETRY': '1'}, error=b'retrying')
        assert target.read_text() == 'saved'
        target.unlink()
        panic = f'> u = writePath @{target} "never"; parseInt "boom".\n'
        run(panic, expected=b'', status='miss', code=1, error=b'SOL PANIC')
        run(expected=b'', code=1, error=b'SOL PANIC')
        assert not target.exists()
        # JIT input Core is restored along with interpreter bytecode.
        jit = 'inc x = x + 1.\n> print "{List.sum (List.map inc (List.range 1 3000))}".\n'
        run(jit, expected=b'4504500\n', status='miss')
        run(expected=b'4504500\n', extra={'SOL_JIT': '1', 'SOL_VERBOSE': '1'}, error=b'[jit] compiled')
        run(hello, status='hit')
        def asm():
            p = subprocess.run([str(FPR), 'sol', '--asm', str(script)], env=env, capture_output=True, timeout=30)
            assert p.returncode == 0 and b'print' in p.stdout
            return p.stdout
        assert asm() == asm()
        # Corrupt/truncated entries are discarded and atomically replaced.
        for old in cache.glob('*.cache'): old.unlink()
        run(status='miss')
        entry, = cache.glob('*.cache')
        for content in (b'', b'FPRSOL1\n', entry.read_bytes()[:-1]):
            entry.write_bytes(content)
            run(status='miss')
            run()
        content = bytearray(entry.read_bytes())
        content[-1] ^= 1
        entry.write_bytes(content)
        run(status='miss')
        run()
        unavailable = w / 'not-directory'
        unavailable.write_text('x')
        run(status='miss', extra={'SOL_CACHE_DIR': str(unavailable)}, error=b'write unavailable')
        # Concurrent writers leave one complete usable entry and no temp files.
        entry.unlink()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: subprocess.run([str(FPR), 'sol', str(script)], env=env, capture_output=True, timeout=30), range(4)))
        assert all(p.returncode == 0 and p.stdout == b'42\n' for p in results), results
        run()
        assert not list(cache.glob('.sol-cache-*'))
        # Replacing/rebuilding the compiler invalidates its executable identity.
        copy = w / 'fpr-copy'
        shutil.copy2(FPR, copy)
        def copied():
            return subprocess.run([str(copy), 'sol', str(script)], env=env, capture_output=True, timeout=30)
        assert b'[sol cache] miss' in copied().stderr
        assert b'[sol cache] hit' in copied().stderr
        st = copy.stat()
        os.utime(copy, ns=(st.st_atime_ns, st.st_mtime_ns + 1000000000))
        changed = copied()
        assert changed.returncode == 0 and changed.stdout == b'42\n' and b'[sol cache] miss' in changed.stderr
        run(extra={'SOL_TIMINGS': '1'}, error=b'[sol timing] startup:')
        quiet = run(status=None, extra={'SOL_CACHE_TRACE': '0'})
        assert quiet.stderr == b''
    print(f'sol startup: {count} checks passed (plus assembly and concurrent writers)')


if __name__ == '__main__':
    main()
