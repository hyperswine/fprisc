#!/usr/bin/env python3
"""Live reader must retain its socket until its delayed writer stops.

The fixture uses Live.reading itself, a delayed close writer, and a writer that
never finishes. No production network or authentication material is used.
Usage: python3 tests/check_live_writer_lifetime.py /path/to/livewriterlifetime
"""
import argparse
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time


def check(binary, harts):
    with tempfile.TemporaryFile(mode='w+') as log:
        child = subprocess.Popen([str(binary)], env={**os.environ, 'FPR_HARTS': str(harts)},
                                 stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            deadline = time.monotonic() + 15
            port = None
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise AssertionError('fixture exited before listening')
                if select.select([child.stdout], [], [], .1)[0]:
                    line = child.stdout.readline()
                    if line.startswith('ready '):
                        port = int(line.split()[1])
                        break
            assert port, 'fixture startup timed out'
            for path in ('/delayed', '/stuck'):
                with socket.create_connection(('127.0.0.1', port), timeout=5) as sock:
                    sock.sendall(f'GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode())
                    response = b''
                    while b'\r\n\r\n' not in response:
                        data = sock.recv(4096)
                        assert data, 'closed before upgrade'
                        response += data
                    assert response.startswith(b'HTTP/1.1 101 ')
                    # Masked empty client close, after HTTP parsing has finished.
                    began = time.monotonic()
                    sock.sendall(b'\x88\x80abcd')
                    closing = response.split(b'\r\n\r\n', 1)[1]
                    while True:
                        data = sock.recv(4096)
                        if not data:
                            break
                        closing += data
                    elapsed = time.monotonic() - began
                    if path == '/delayed':
                        assert closing == b'\x88\x02\x03\xe9', (
                            'reader closed before its writer finished', closing)
                        assert elapsed >= .15, 'delayed writer was not awaited'
                    else:
                        assert not closing, 'stuck writer unexpectedly wrote data'
                        assert 1.5 <= elapsed < 4, ('writer shutdown was not bounded', elapsed)
                # New connections must remain clean after teardown/descriptor reuse.
                for _ in range(10):
                    with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
                        sock.sendall(b'GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n')
                        response = b''
                        while True:
                            data = sock.recv(4096)
                            if not data:
                                break
                            response += data
                        assert response.startswith(b'HTTP/1.1 200 '), response[:100]
                        assert response.endswith(b'ok\n')
            print(f'PASS harts={harts}: delayed writer finishes before close; stuck writer retires within budget; fresh HTTP clean')
        finally:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path, nargs='?')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='live-writer-build-') as temporary:
        root = Path(__file__).resolve().parents[1]
        binary = args.binary.resolve() if args.binary else Path(temporary) / 'livewriterlifetime'
        if not args.binary:
            subprocess.run([str(root / 'fpr'), 'build', 'tests/std/livewriterlifetime.fpr', '-o', str(binary)],
                           cwd=root, check=True, timeout=240)
        for harts in (1, 4):
            check(binary, harts)
