#!/usr/bin/env python3
"""Exact stdout/stderr and exit contract for the Sol script runner."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()
ENV = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')} | {'SOL_GPU': '0'}


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-output-') as tmp:
        work = Path(tmp)

        def check(name, source, stdout=b'', code=0, error=None, env=None, args=(), stderr=None):
            nonlocal count
            path = work / (name + '.sol')
            path.write_text(source)
            result = subprocess.run([str(FPR), 'sol', *args, str(path)],
                                    capture_output=True, env=ENV | (env or {}), timeout=30)
            assert result.returncode == code, (name, result)
            assert result.stdout == stdout, (name, result.stdout, stdout, result.stderr)
            if error is None:
                assert result.stderr == b'', (name, result.stderr)
            else:
                assert error in result.stderr, (name, result.stderr)
            if stderr is not None:
                assert result.stderr == stderr, (name, result.stderr, stderr)
            count += 1
            return result

        check('json', '> print "[true,42]".\n', b'[true,42]\n')
        check('unicode', '> print "hello λ 世界".\n', 'hello λ 世界\n'.encode())
        check('values', '> 42.\nmain = 7.\n')
        check('definitions', 'answer = 42.\n')
        jit = 'inc x = x + 1.\n> print "{List.sum (List.map inc (List.range 1 3000))}".\n'
        check('jit_quiet', jit, b'4504500\n')
        check('jit_debug', jit, b'4504500\n', env={'SOL_VERBOSE': '1'}, error=b'[jit] compiled')
        asm = work / 'assembly.sol'
        asm.write_text('> print "should not execute".\n')
        result = subprocess.run([str(FPR), 'sol', '--asm', str(asm)], capture_output=True, env=ENV, timeout=30)
        assert result.returncode == 0 and result.stdout and not result.stderr, result
        count += 1

        module = work / 'helper.sol'
        module.write_text('answer = 42.\n')
        check('import', 'h = use "helper.sol".\n> print "{h.answer}".\n', b'42\n')
        check('import_verbose', 'h = use "helper.sol".\n> print "{h.answer}".\n', b'42\n',
              error=b'[sol] use (compile):', env={'SOL_VERBOSE': '1'})
        check('parse', '> ).\n', code=1, error=b'unexpected')
        check('type', '> print (1 + "wrong").\n', code=1, error=b'TYPE ERRORS')
        check('missing_module', 'h = use "missing.sol".\n', code=1, error=b'missing')
        check('panic', '> parseInt "boom".\n', code=1, error=b'SOL PANIC')
        check('types', 'answer = 42.\n', env={'SOL_TYPES': '1'}, error=b'INFERRED TYPES')
        target = work / 'saved.txt'
        write = f'> writePath @{target} "saved".\n'
        check('write', write)
        assert target.read_bytes() == b'saved'
        check('write_verbose', write, env={'SOL_VERBOSE': '1'}, error=b'committed 1 file(s)')
        check('retry', write, env={'SOL_FORCE_RETRY': '1'}, error=b'retrying')
        failed = work / 'failed.txt'
        check('exhausted', f'> writePath @{failed} "never".\n', code=1,
              env={'SOL_FORCE_RETRY': '12'}, error=b'giving up after 12 attempts')
        assert not failed.exists()
        check('rollback', f'> u = writePath @{failed} "never"; parseInt "boom".\n',
              code=1, error=b'SOL PANIC')
        assert not failed.exists()
        # Both APIs preserve intentional child output, including embedded NUL.
        check('shell', '> shq "printf \'a\\\\000b\'; printf err >&2".\n',
              b'a\x00b', error=b'err', stderr=b'err')
        check('process', '> Proc.afterCommit (ProcessSpec ["/bin/sh", "-c", "printf out; printf err >&2"] "" [] "" 1000).\n',
              b'out', error=b'err', stderr=b'err')
        check('failed_process', '> u = Proc.afterCommit (ProcessSpec ["/bin/sh", "-c", "printf before; exit 7"] "" [] "" 1000);\n'
              'Proc.afterCommit (ProcessSpec ["/bin/sh", "-c", "printf forbidden"] "" [] "" 1000).\n',
              b'before', code=1, error=b'deferred process FAILED (exit 7)')
        check('failed_shell', '> u = shq "exit 7"; shq "printf forbidden".\n',
              code=1, error=b'deferred command FAILED (exit 7)')
        for args in ([], [str(work / 'absent.sol')]):
            result = subprocess.run([str(FPR), 'sol', *args], capture_output=True, env=ENV, timeout=30)
            assert result.returncode == 1 and not result.stdout and result.stderr, result
            count += 1
        # Wait for a program marker, so SIGINT cannot race compiler startup.
        sleeper = work / 'interrupt.sol'
        sleeper.write_text('> u = print "ready"; Sys.sleepUs 10000000.\n')
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            proc = subprocess.Popen([str(FPR), 'sol', str(sleeper)], stdout=out, stderr=err, env=ENV)
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    out.seek(0)
                    if out.read() == b'ready\n':
                        break
                    if proc.poll() is not None:
                        err.seek(0)
                        raise AssertionError(('interrupt before ready', err.read()))
                    time.sleep(.02)
                else:
                    raise AssertionError('interrupt readiness timeout')
                proc.send_signal(signal.SIGINT)
                assert proc.wait(timeout=5) == 130
                out.seek(0); err.seek(0)
                assert out.read() == b'ready\n'
                assert b'[sol] interrupted' in err.read()
                count += 1
            finally:
                if proc.poll() is None:
                    proc.kill(); proc.wait()
    print(f'sol output contract: {count} checks passed')


if __name__ == '__main__':
    main()
