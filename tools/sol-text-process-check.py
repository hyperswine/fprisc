#!/usr/bin/env python3
"""Unicode indexing, live process I/O, terminal handoff and owned-child cleanup."""
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()


def quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('{', '\\{').replace('}', '\\}').replace('\n', '\\n') + '"'


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-text-process-') as tmp:
        w = Path(tmp)
        env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
        env.update(SOL_CACHE_DIR=str(w / 'cache'), SOL_JIT='0', SOL_GPU='0', SOL_TABLE='0')
        def run(src, out=b'', code=0, error=None, input=None):
            nonlocal count
            path = w / 'test.sol'
            path.write_text(src)
            p = subprocess.run([str(FPR), 'sol', str(path)], input=input, env=env, capture_output=True, timeout=15)
            assert p.returncode == code and p.stdout == out, p
            if error:
                assert error in p.stderr, p
            count += 1
            return p
        text = 'aλ😀e\u0301\x00z'
        data = w / 'text.txt'
        data.write_text(text)
        prefix = f's = readPath @{data}.\n'
        expressions = ['strlen s', 'Str.at s 2', 'Str.at s 3', 'Str.at s 5', 'Str.at s 6']
        source = prefix + ''.join(f'> print "{{{e}}}".\n' for e in expressions)
        run(source, b'7\n955\n128512\n769\n0\n')
        for start, length in [(-2, 3), (3, 2), (8, 4), (2, -1), (10**40, 2), (2, 10**40), (-10**40, 2)]:
            first = max(1, start) - 1
            expected = text[first:first + max(0, length)]
            run(prefix + f'> print (substr s {start} {length}).\n', (expected + '\n').encode())
        for index in (0, -1, 8, 10**40, -10**40):
            run(prefix + f'> charAt s {index}.\n', code=1, error=b'index out of range')
        run('> print "{strlen \"\"}".\n> print (substr "" 1 10).\n', b'0\n\n')
        run(prefix + '> print "{s == (substr s 1 7)}".\n> print (Str.join "|" (Str.lines "a\\nλ\\n")).\n', 'True\na|λ\n'.encode())
        run(f'J = use "{ROOT}/sol/lib/json.sol".\n> print (J.parse "[true,42,\\\"λ😀\\\"]" |>? (fn j -> Ok (J.render j))).\n', 'Ok [true,42,"λ😀"]\n'.encode())

        def spec(argv, timeout=0, stdin='', cwd=''):
            return 'ProcessSpec [' + ', '.join(map(quote, argv)) + '] ' + quote(cwd) + ' [] ' + quote(stdin) + f' {timeout}'
        def invoke(mode, argv, timeout=0, stdin='', cwd=''):
            return f'> r = Proc.{mode} ({spec(argv, timeout, stdin, cwd)}); print "{{r}}".\n'
        py = str(Path(sys.executable).resolve())
        # No shell interpretation of arguments; two channels remain distinct.
        p = run(invoke('streamNow', [py, '-c', 'import sys; print(sys.argv[1]); sys.stderr.write("child-error\\n")', 'a; $x " b']), b'a; $x " b\nOk 0\n', error=b'child-error')
        run(invoke('streamNow', [py, '-c', 'import sys; sys.stdout.buffer.write(bytes([0,255,10])); sys.exit(7)']), b'\x00\xff\nOk 7\n')
        run(invoke('streamNow', ['/bin/cat'], stdin='λ\n'), 'λ\nOk 0\n'.encode())
        run(invoke('inheritNow', ['/bin/cat']), b'inherited\x00\xff\nOk 0\n', input=b'inherited\x00\xff\n')
        p = run(invoke('inheritNow', ['/bin/cat'], stdin='rejected'), b'Err process \"/bin/cat\": inherited stdin cannot be combined with ProcessSpec stdin text\n')
        run(invoke('streamNow', ['/bin/pwd'], cwd=str(w)), (str(w.resolve()) + '\nOk 0\n').encode())
        bulk = w / 'bulk.txt'
        bulk.write_text('i' * 200000)
        # Both captured output pipes exceed OS capacity, concurrently with stdin.
        helper = 'import sys,threading; t=threading.Thread(target=lambda:sys.stderr.write("e"*200000)); t.start(); sys.stdout.write("o"*200000); sys.stdin.read(); t.join()'
        src = f'> r = Proc.query ({spec([py, "-c", helper], 5000, "BULK")}); case r of Ok (ProcessResult c o e) -> print "{{c}} {{strlen o}} {{strlen e}}" | Err e -> print e.\n'
        src = src.replace(quote('BULK'), f'(readPath @{bulk})')
        run(src, b'0 200000 200000\n')
        # A decoding failure cancels the sibling workers and the sleeping child.
        invalid = 'import os,sys,time; sys.stdout.buffer.write(bytes([255])*8192); sys.stdout.flush(); os.close(1); time.sleep(20)'
        src = f'> r = Proc.query ({spec([py, "-c", invalid])}); case r of Err _ -> print "decode-error" | _ -> print "unexpected".\n'
        run(src, b'decode-error\n')
        # An early successful child exit must not turn a broken stdin pipe into failure.
        src = f'> r = Proc.query ({spec(["/usr/bin/true"], 3000, "BULK")}); case r of Ok (ProcessResult c _ _) -> print "{{c}}" | Err e -> print e.\n'
        src = src.replace(quote('BULK'), f'(readPath @{bulk})')
        run(src, b'0\n')
        target = w / 'pending.txt'
        src = f'> u = writePath @{target} "saved"; r = Proc.streamNow ({spec(["/bin/echo", "FORBIDDEN"])}); print "{{r}}".\n'
        (w / 'pending.sol').write_text(src)
        p = subprocess.run([str(FPR), 'sol', str(w / 'pending.sol')], env=env, capture_output=True, timeout=10)
        assert p.returncode == 0 and b'FORBIDDEN\n' not in p.stdout and b'Err' in p.stdout and target.read_text() == 'saved', p
        count += 1

        # Live output is visible before child completion, without newline buffering.
        live = w / 'live.sol'
        live.write_text(invoke('streamNow', [py, '-c', 'import sys,time; sys.stdout.write("READY"); sys.stdout.flush(); time.sleep(1); print("DONE")']))
        with subprocess.Popen([str(FPR), 'sol', str(live)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as p:
            assert select.select([p.stdout], [], [], 5)[0]
            assert os.read(p.stdout.fileno(), 5) == b'READY' and p.poll() is None
            out, err = p.communicate(timeout=5)
            assert out == b'DONE\nOk 0\n' and p.returncode == 0, (out, err)
        count += 1

        # A consumer that does not drain stdout backpressures the child; Sol
        # must not eagerly capture the stream and let the child finish.
        ready = w / 'producer-ready'
        finished = w / 'producer-finished'
        producer = 'import sys; from pathlib import Path; Path(sys.argv[1]).touch(); sys.stdout.buffer.write(b"x"*2097152); sys.stdout.flush(); Path(sys.argv[2]).touch()'
        live.write_text(invoke('streamNow', [py, '-c', producer, str(ready), str(finished)]))
        with subprocess.Popen([str(FPR), 'sol', str(live)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as p:
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline: time.sleep(.02)
                assert ready.exists()
                time.sleep(.2)
                assert not finished.exists() and p.poll() is None
                out, err = p.communicate(timeout=5)
                assert p.returncode == 0 and out == b'x'*2097152 + b'Ok 0\n' and finished.exists(), (len(out), err)
            finally:
                if p.poll() is None: p.send_signal(signal.SIGINT); p.communicate(timeout=3)
        count += 1

        # TERM-ignoring leader and grandchild: timeout or SIGINT cannot leave a
        # running descendant behind. The leader can also exit while pipes stay open.
        worker = w / 'worker.py'
        marker = w / 'late'
        ids = w / 'pids'
        worker.write_text('import os,signal,time,sys\nfrom pathlib import Path\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\np=os.fork()\nif p==0:\n time.sleep(1.5)\n Path(sys.argv[2]).write_text("LEAK")\n time.sleep(20)\nelse:\n Path(sys.argv[1]).write_text(str(os.getpid())+" "+str(p))\n if len(sys.argv)>3: sys.exit(0)\n time.sleep(20)\n')
        def terminate_remaining():
            if ids.exists():
                for pid in ids.read_text().split():
                    try: os.kill(int(pid), signal.SIGKILL)
                    except ProcessLookupError: pass
        try:
            for mode, exits in [('query', False), ('query', True), ('streamNow', False), ('inheritNow', False)]:
                argv = [py, str(worker), str(ids), str(marker)] + (['exit'] if exits else [])
                src = invoke(mode, argv, timeout=250)
                path = w / 'timeout.sol'; path.write_text(src)
                start = time.monotonic()
                p = subprocess.run([str(FPR), 'sol', str(path)], env=env, capture_output=True, timeout=5)
                assert p.returncode == 0 and b'timed out after 250ms' in p.stdout and time.monotonic()-start < 3, p
                time.sleep(1.6)
                assert not marker.exists(), (mode, 'descendant survived')
                count += 1
            ids.unlink()
            path = w / 'interrupt.sol'; path.write_text(invoke('streamNow', [py, str(worker), str(ids), str(marker)]))
            p = subprocess.Popen([str(FPR), 'sol', str(path)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not ids.exists() and time.monotonic() < deadline: time.sleep(.02)
                assert ids.exists()
                p.send_signal(signal.SIGINT)
                out, err = p.communicate(timeout=3)
                assert p.returncode == 130 and b'interrupted' in err, (out, err, p.returncode)
                time.sleep(1.6)
                assert not marker.exists()
            finally:
                if p.poll() is None: p.kill(); p.wait()
            count += 1
        finally:
            terminate_remaining()

        # A real controlling PTY catches background-read SIGTTIN mistakes.
        path = w / 'terminal.sol'
        path.write_text(invoke('inheritNow', [py, '-c', 'import sys; print("TTYREADY",flush=True); print("GOT:"+input(),flush=True)']) + '> u = print "PARENTREADY"; s = readLineNow Unit; print "PARENTGOT:{s}".\n')
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(str(FPR), [str(FPR), 'sol', str(path)], env)
        output = b''
        try:
            deadline = time.monotonic() + 8
            sent = False
            parent_sent = False
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try: chunk = os.read(fd, 65536)
                    except OSError: break
                    if not chunk: break
                    output += chunk
                    if b'TTYREADY' in output and not sent:
                        os.write(fd, b'hello-terminal\n'); sent = True
                    if b'PARENTREADY' in output and not parent_sent:
                        os.write(fd, b'parent-terminal\n'); parent_sent = True
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    pid = None
                    assert os.waitstatus_to_exitcode(status) == 0, output
                    break
            assert b'GOT:hello-terminal' in output and b'Ok 0' in output and b'PARENTGOT:parent-terminal' in output, output
            if pid:
                end = time.monotonic() + 2
                while time.monotonic() < end:
                    done, status = os.waitpid(pid, os.WNOHANG)
                    if done:
                        pid = None
                        assert os.waitstatus_to_exitcode(status) == 0, output
                        break
                    time.sleep(.02)
                assert pid is None, ('terminal session did not exit', output)
            count += 1
        finally:
            if pid:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
                os.waitpid(pid, 0)
            os.close(fd)
    print(f'sol text/process: {count} checks passed')


if __name__ == '__main__':
    main()
