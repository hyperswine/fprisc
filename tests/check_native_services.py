#!/usr/bin/env python3
"""Bounded DNS, checked lifetime, native TLS and optional real-broker MQTT.

All sockets are loopback. TLS uses openly published OpenSSL test identities.
Python/Docker are test drivers, never application runtime dependencies.
Use --broker after pulling the pinned image named below.
"""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/fixtures/tls'
IMAGE = 'eclipse-mosquitto@sha256:199ea8ef2e35ec2b1b37e59cfd1dbae538ed4dfa4a2251a121a52215a6248a21'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def openssl_flags(prefix):
    if not prefix:
        prefix = os.environ.get('FPR_OPENSSL_PREFIX')
    if not prefix and shutil.which('brew'):
        result = subprocess.run(['brew', '--prefix', 'openssl@3'], capture_output=True, text=True)
        if result.returncode == 0:
            prefix = result.stdout.strip()
    if prefix:
        flags = ['--cflag', '-I' + str(Path(prefix) / 'include'),
                 '--link', '-L' + str(Path(prefix) / 'lib'), '--link', '-lssl', '--link', '-lcrypto']
        binary = Path(prefix) / 'bin/openssl'
    else:
        version = subprocess.check_output(['pkg-config', '--modversion', 'openssl'], text=True).strip()
        assert version.startswith('3.'), 'This adapter is tested with OpenSSL 3; select its prefix explicitly'
        cflags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'openssl'], text=True))
        links = shlex.split(subprocess.check_output(['pkg-config', '--libs', 'openssl'], text=True))
        flags = [arg for f in cflags for arg in ('--cflag', f)]
        flags += [arg for f in links for arg in ('--link', f)]
        binary = shutil.which('openssl')
    print(subprocess.check_output([str(binary), 'version'], text=True).strip(), flush=True)
    return flags, binary


def tls_case(binary, harts, mode, roots, certificate=None, peer='server.example', maximum=None):
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    port = listener.getsockname()[1]
    failures = []

    def serve():
        try:
            raw, _ = listener.accept()
            raw.settimeout(5)
            if mode in ('stall', 'unsupported'):
                with raw:
                    time.sleep(.15)
                return
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            if maximum:
                context.maximum_version = maximum
            context.load_cert_chain(certificate or FIXTURES / 'servercert.pem', FIXTURES / 'serverkey.pem')
            with context.wrap_socket(raw, server_side=True) as conn:
                expected = 262144 if mode == 'large' else 9
                data = bytearray()
                while len(data) < expected:
                    part = conn.recv(min(8192, expected - len(data)))
                    assert part, 'client ended before sending payload'
                    data.extend(part)
                if mode == 'readstall':
                    time.sleep(.15)
                else:
                    for at in range(0, len(data), 4093):
                        conn.sendall(data[at:at + 4093])
                    conn.unwrap().close()
        except Exception as exc:
            if mode not in ('reject', 'reject13', 'readstall'):
                failures.append(repr(exc))
        finally:
            listener.close()

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    result = subprocess.run([str(binary), str(port), str(roots), peer, mode],
                            env={**os.environ, 'FPR_HARTS': harts}, capture_output=True, text=True, timeout=10)
    worker.join(6)
    assert not worker.is_alive(), 'TLS test server did not stop'
    assert result.returncode == 0 and result.stdout == f'TLS {mode}: PASS\n', result.stdout + result.stderr
    assert not failures, failures
    print(f'{harts} hart(s): TLS {mode} PASS', flush=True)


def capacity_case(binary, roots, directory, harts):
    fifo = directory / f'roots-{harts}.fifo'
    os.mkfifo(fifo)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    port = listener.getsockname()[1]
    errors = []

    def writer():
        # The reader blocks off-hart until this public trust data arrives.
        with fifo.open('wb') as stream:
            # Start the stall after the engine has opened the FIFO. A delay
            # before open races process startup and may not stall the engine.
            time.sleep(.5)
            stream.write(roots.read_bytes())

    def serve_one(raw, final):
        raw.settimeout(3)
        if not final:
            with raw:
                while raw.recv(1024):
                    pass
            return
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(FIXTURES / 'servercert.pem', FIXTURES / 'serverkey.pem')
        try:
            with context.wrap_socket(raw, server_side=True):
                pass
        except ssl.SSLError as exc:
            errors.append(repr(exc))

    def serve():
        threads = []
        try:
            for index in range(3):
                raw, _ = listener.accept()
                thread = threading.Thread(target=serve_one, args=(raw, index == 2), daemon=True)
                thread.start()
                threads.append(thread)
            for thread in threads:
                thread.join(4)
        finally:
            listener.close()

    server = threading.Thread(target=serve, daemon=True)
    source = threading.Thread(target=writer, daemon=True)
    server.start()
    source.start()
    result = subprocess.run([str(binary), str(port), str(fifo), str(roots)],
                            env={**os.environ, 'FPR_HARTS': harts}, capture_output=True, text=True, timeout=8)
    source.join(4)
    server.join(5)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not source.is_alive() and not server.is_alive() and not errors, errors
    print(f'{harts} hart(s): {result.stdout.strip()}', flush=True)


def broker_case(binary, directory, host):
    if not host:
        host = os.environ.get('DOCKER_HOST') or subprocess.check_output(
            ['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], text=True).strip()
    config = directory / 'docker-client'
    config.mkdir()
    docker = ['docker', '--config', str(config), '--host', host]
    broker_files = directory / 'broker'
    broker_files.mkdir()
    for name in ('rootcert.pem', 'servercert.pem', 'serverkey.pem'):
        shutil.copyfile(FIXTURES / name, broker_files / name)
    (broker_files / 'mosquitto.conf').write_text(
        'per_listener_settings true\nlistener 1883\nallow_anonymous true\nlistener 8883\nallow_anonymous true\n'
        'cafile /mosquitto/config/rootcert.pem\ncertfile /mosquitto/config/servercert.pem\n'
        'keyfile /mosquitto/config/serverkey.pem\n'
        'listener 1884\nallow_anonymous false\npassword_file /mosquitto/config/passwords\n'
        'listener 8884\nallow_anonymous false\npassword_file /mosquitto/config/passwords\n'
        'cafile /mosquitto/config/rootcert.pem\ncertfile /mosquitto/config/servercert.pem\n'
        'keyfile /mosquitto/config/serverkey.pem\n')
    container = subprocess.check_output(docker + ['create', '-p', '127.0.0.1::1883',
                                               '-p', '127.0.0.1::8883', '-p', '127.0.0.1::1884', '-p', '127.0.0.1::8884', '--user', '0:0', IMAGE, '/bin/sh', '-c', 'mosquitto_passwd -b -c /mosquitto/config/passwords fpr-test test-only && chmod 644 /mosquitto/config/passwords && exec /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf'], text=True).strip()
    try:
        # Docker file copy works even when a VM does not share the host's /tmp.
        run(docker + ['cp', str(broker_files) + '/.', container + ':/mosquitto/config/'])
        run(docker + ['start', container], stdout=subprocess.DEVNULL)
        ports = {}
        for mode, internal in [('tcp', '1883/tcp'), ('tls', '8883/tcp'), ('tcp-auth', '1884/tcp'), ('tls-auth', '8884/tcp'), ('tls-reject', '8884/tcp')]:
            port = int(subprocess.check_output(docker + ['port', container, internal], text=True).strip().rsplit(':', 1)[1])
            ports[mode] = port
        for _ in range(50):
            try:
                with socket.create_connection(('127.0.0.1', ports['tcp']), timeout=.1):
                    break
            except OSError:
                time.sleep(.05)
        else:
            raise AssertionError('broker did not become ready')
        for harts in ('1', '4'):
            for mode, port in ports.items():
                result = subprocess.run([str(binary), str(port), str(FIXTURES / 'rootcert.pem'), mode],
                                        env={**os.environ, 'FPR_HARTS': harts}, capture_output=True, text=True, timeout=15)
                assert result.returncode == 0, result.stdout + result.stderr
                assert ('' if mode == 'tls-reject' else f'MQTT {mode}: broker subscribe/publish/QoS1 echo and idle keepalive PASS\n') == result.stdout
                print(f'{harts} hart(s): {result.stdout.strip() or mode + " authentication refusal PASS"}', flush=True)
    except BaseException:
        print(subprocess.check_output(docker + ['logs', container], stderr=subprocess.STDOUT, text=True)[-4000:])
        raise
    finally:
        run(docker + ['rm', '-f', container], stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--openssl-prefix')
    parser.add_argument('--broker', action='store_true')
    parser.add_argument('--docker-host')
    options = parser.parse_args()
    flags, openssl = openssl_flags(options.openssl_prefix)
    with tempfile.TemporaryDirectory(prefix='fpr-native-services-') as tmp:
        directory = Path(tmp)
        env = {**os.environ, 'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(directory / 'cache')), 'FPR_HOME': str(ROOT)}

        def build(source, name, extra=()):
            binary = directory / name
            result = subprocess.run([str(ROOT / 'fpr'), 'build', str(ROOT / source), '-o', str(binary), *extra],
                                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
            assert result.returncode == 0, result.stdout + result.stderr
            return binary

        adapter = ['--with', str(ROOT / 'machine/unix/tls_openssl.c'), *flags]
        connection = build('tests/connection.fpr', 'connection', ['--with', str(ROOT / 'tests/slow_dns.c')])
        tls = build('tests/tlsclient.fpr', 'tls', adapter)
        absent = build('tests/tlsclient.fpr', 'absent')
        capacity = build('tests/tlscapacity.fpr', 'capacity', adapter)
        mqtt = build('tests/std/mqtt.fpr', 'mqtt')
        pump = build('tests/std/mqttpump.fpr', 'pump')
        client = build('tests/mqttclient.fpr', 'client', adapter) if options.broker else None
        roots = FIXTURES / 'rootcert.pem'
        unrelated = directory / 'unrelated.pem'
        run([openssl, 'req', '-new', '-x509', '-key', FIXTURES / 'serverkey.pem', '-subj', '/CN=Unrelated Test CA',
             '-days', '365', '-out', unrelated], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        request = directory / 'expired.csr'
        expired = directory / 'expired.pem'
        run([openssl, 'req', '-new', '-key', FIXTURES / 'serverkey.pem', '-subj', '/CN=server.example', '-out', request],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        index = directory / 'ca-index'
        index.write_text('')
        serial = directory / 'ca-serial'
        serial.write_text('01\n')
        ca_config = directory / 'expired-ca.cnf'
        ca_config.write_text('[ca]\ndefault_ca=test\n[test]\n' +
                             f'database={index}\nserial={serial}\nnew_certs_dir={directory}\n' +
                             f'private_key={FIXTURES / "serverkey.pem"}\ncertificate={FIXTURES / "servercert.pem"}\n' +
                             'default_md=sha256\npolicy=names\n[names]\ncommonName=supplied\n')
        run([openssl, 'ca', '-selfsign', '-batch', '-notext', '-config', ca_config,
             '-startdate', '20200101000000Z', '-enddate', '20210101000000Z', '-in', request, '-out', expired],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for harts in ('1', '4'):
            for binary in (connection, mqtt, pump):
                result = subprocess.run([str(binary)], cwd=directory, env={**env, 'FPR_HARTS': harts},
                                        capture_output=True, text=True, timeout=20)
                assert result.returncode == 0, result.stdout + result.stderr
                print(f'{harts} hart(s): {result.stdout.strip() or mode + " authentication refusal PASS"}', flush=True)
            tls_case(tls, harts, 'echo', roots)
            tls_case(tls, harts, 'large', roots)
            tls_case(tls, harts, 'reject', roots, peer='wrong.example')
            tls_case(tls, harts, 'reject', unrelated)
            tls_case(tls, harts, 'reject', expired, certificate=expired)
            tls_case(tls, harts, 'reject13', roots, maximum=ssl.TLSVersion.TLSv1_2)
            tls_case(tls, harts, 'stall', roots)
            tls_case(tls, harts, 'readstall', roots)
            tls_case(absent, harts, 'unsupported', roots)
            capacity_case(capacity, roots, directory, harts)
        if client:
            broker_case(client, directory, options.docker_host)


if __name__ == '__main__':
    main()
