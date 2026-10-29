#!/usr/bin/env python3
"""Native HTTP/TLS acceptance; Python is only a loopback simulator/test driver."""
import argparse
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/fixtures/tls'


def case(binary, harts, mode, tls=True, peer='server.example', roots=None):
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(6)
    port = listener.getsockname()[1]
    errors = []

    def serve():
        try:
            for _ in range(2 if mode == 'public' else 1):
                raw, _ = listener.accept()
                raw.settimeout(4)
                try:
                    if tls:
                        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                        context.load_cert_chain(FIXTURES / 'servercert.pem', FIXTURES / 'serverkey.pem')
                        conn = context.wrap_socket(raw, server_side=True)
                    else:
                        conn = raw
                    with conn:
                        data = bytearray()
                        while b'\r\n\r\n' not in data:
                            part = conn.recv(4096)
                            assert part
                            data.extend(part)
                        head, body = data.split(b'\r\n\r\n', 1)
                        assert f'host: {peer}:{port}\r\n'.encode() in head + b'\r\n', head
                        length = int(next(h.split(b':', 1)[1] for h in head.split(b'\r\n') if h.startswith(b'content-length:')))
                        while len(body) < length:
                            part = conn.recv(4096)
                            assert part
                            body.extend(part)
                        assert body == b'binary\0' * 4096
                        if mode == 'stall':
                            time.sleep(.25)
                        elif mode == 'slow':
                            for byte in b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok':
                                conn.sendall(bytes([byte]))
                                time.sleep(.015)
                        elif mode == 'oversize':
                            conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 262145\r\n\r\n')
                        elif mode == 'chunked':
                            wire = b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6;x=y\r\nhello \r\nb\r\nnative HTTP\r\n0\r\nX-Trace: test\r\n\r\n'
                            for at in range(0, len(wire), 3):
                                conn.sendall(wire[at:at + 3])
                        else:
                            wire = b'HTTP/1.1 201 Created\r\nContent-Length: 24576\r\n\r\n' + b'reply\0' * 4096
                            for at in range(0, len(wire), 4093):
                                conn.sendall(wire[at:at + 4093])
                            # Content-Length ends the response without waiting for
                            # a peer close, even if that peer ignores Connection.
                            conn.settimeout(1)
                            assert conn.recv(1) == b''
                except (ssl.SSLError, ConnectionError, OSError) as exc:
                    if mode not in ('reject', 'unsupported', 'slow', 'stall'):
                        raise exc
                finally:
                    raw.close()
        except Exception as exc:
            errors.append(repr(exc))
        finally:
            listener.close()

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    scheme = 'https' if tls else 'http'
    result = subprocess.run([str(binary), f'{scheme}://{peer}:{port}/binary?test=1', str(roots or FIXTURES / 'rootcert.pem'), mode],
                            capture_output=True, text=True, timeout=10, env={**os.environ, 'FPR_HARTS': str(harts), 'PATH': '/nonexistent'})
    worker.join(7)
    assert not worker.is_alive(), 'simulator did not stop'
    assert result.returncode == 0 and result.stdout == f'native HTTP {mode}: PASS\n', result.stdout + result.stderr
    assert not errors, errors
    print(f'{harts} harts: {scheme} {mode} PASS', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--openssl-prefix', default='/opt/homebrew/opt/openssl@3')
    args = parser.parse_args()
    for module in ('std/http.fpr', 'std/httpclient.fpr'):
        source = (ROOT / module).read_text()
        assert 'use "proc"' not in source and 'viaCurl' not in source and 'P.spawn' not in source
    with tempfile.TemporaryDirectory(prefix='fpr-http-native-') as temp:
        temp = Path(temp)
        env = {**os.environ, 'FPR_HOME': str(ROOT), 'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(temp / 'cache'))}
        def build(source, name, tls=False):
            binary = temp / name
            cmd = [str(ROOT / 'fpr'), 'build', source, '-o', str(binary), '--with', 'tests/http_dns.c']
            if tls:
                prefix = Path(args.openssl_prefix)
                cmd += ['--with', 'machine/unix/tls_openssl.c', '--cflag', '-I' + str(prefix / 'include'),
                        '--link', '-L' + str(prefix / 'lib'), '--link', '-lssl', '--link', '-lcrypto']
            result = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
            assert result.returncode == 0, result.stdout + result.stderr
            return binary
        plain = build('tests/httpclient_native.fpr', 'plain')
        native = build('tests/httpclient_native.fpr', 'tls', True)
        pure = build('tests/std/httpclient.fpr', 'pure')
        compatibility = build('tests/std/http.fpr', 'compatibility')
        for harts in (1, 4):
            for binary, expected in ((pure, 'httpclient.expected'), (compatibility, 'http.expected')):
                result = subprocess.run([str(binary)], env={**env, 'FPR_HARTS': str(harts)}, capture_output=True, text=True, timeout=15)
                assert result.returncode == 0 and result.stdout == (ROOT / 'tests/std' / expected).read_text(), result.stdout + result.stderr
            case(plain, harts, 'success', tls=False)
            case(plain, harts, 'unsupported')
            for mode in ('success', 'chunked', 'public', 'oversize', 'stall', 'slow'):
                case(native, harts, mode)
            case(native, harts, 'reject', peer='wrong.example')
            case(native, harts, 'reject', roots=FIXTURES / 'servercert.pem')
        print('PASS native HTTP: empty tool PATH, binary bodies, verified TLS, no backend fallback, strict bounds and absolute deadlines')


if __name__ == '__main__':
    main()
